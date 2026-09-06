USE [Dev_EMR]
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. usp_Api_DoctorSchedule_GetAvailableSlots
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_GetAvailableSlots]
    @DoctorId INT,
    @BranchId INT,
    @Date DATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DayOfWeek TINYINT;
    -- Map to 1=Mon, 7=Sun regardless of @@DATEFIRST
    SET @DayOfWeek = (DATEPART(WEEKDAY, @Date) + @@DATEFIRST - 2) % 7 + 1;
    IF @DayOfWeek = 7 SET @DayOfWeek = 0;
                     
    -- Check Exception
    DECLARE @ExceptionReason NVARCHAR(500);
    IF EXISTS (SELECT 1 FROM DoctorScheduleException WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND ExceptionDate = @Date AND IsActive = 1)
    BEGIN
        SELECT TOP 1 @ExceptionReason = Reason FROM DoctorScheduleException WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND ExceptionDate = @Date AND IsActive = 1;
        
        -- Return Exception state
        SELECT 1 AS HasException, @ExceptionReason AS ExceptionReason;
        -- Empty slots
        SELECT TOP 0 0 AS ScheduleId, '' AS SlotTime, 0 AS BookedCount, 0 AS MaxPerSlot, 0 AS IsAvailable;
        RETURN;
    END

    -- Ensure PatientOPDService ScheduleId exists
    DECLARE @PatientColExists BIT = 0;
    IF EXISTS (SELECT 1 FROM sys.columns WHERE Name = N'ScheduleId' AND Object_ID = Object_ID(N'dbo.PatientOPDService'))
        SET @PatientColExists = 1;

    -- Generate Slots
    CREATE TABLE #AvailableSlots (
        ScheduleId INT,
        SlotTime TIME,
        BookedCount INT,
        MaxPerSlot INT,
        IsAvailable BIT,
        MaxPatientsPerSession INT
    );

    DECLARE @CurScheduleId INT, @CurStartTime TIME, @CurEndTime TIME, @CurDuration INT, @CurMaxPerSlot INT, @CurMaxSession INT;
    
    DECLARE curSchedules CURSOR FOR
    SELECT ScheduleId, StartTime, EndTime, SlotDurationMinutes, MaxPatientsPerSlot, MaxPatientsPerSession
    FROM DoctorScheduleMaster
    WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND DayOfWeek = @DayOfWeek AND IsActive = 1
      AND EffectiveFrom <= @Date AND (EffectiveTo IS NULL OR EffectiveTo >= @Date);

    OPEN curSchedules;
    FETCH NEXT FROM curSchedules INTO @CurScheduleId, @CurStartTime, @CurEndTime, @CurDuration, @CurMaxPerSlot, @CurMaxSession;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @SlotTime TIME = @CurStartTime;
        
        WHILE DATEADD(MINUTE, @CurDuration, @SlotTime) <= @CurEndTime
        BEGIN
            DECLARE @Booked INT = 0;
            
            IF @PatientColExists = 1
            BEGIN
                DECLARE @CountSql NVARCHAR(MAX) = N'SELECT @cnt = COUNT(*) FROM PatientOPDService WHERE ScheduleId = @sid AND CAST(VisitDate AS DATE) = @d AND AppointmentTime = @st AND Status <> ''Cancelled''';
                EXEC sp_executesql @CountSql, N'@sid INT, @d DATE, @st TIME, @cnt INT OUTPUT', @CurScheduleId, @Date, @SlotTime, @Booked OUTPUT;
            END

            INSERT INTO #AvailableSlots (ScheduleId, SlotTime, BookedCount, MaxPerSlot, IsAvailable, MaxPatientsPerSession)
            VALUES (@CurScheduleId, @SlotTime, @Booked, @CurMaxPerSlot, CASE WHEN @Booked < @CurMaxPerSlot THEN 1 ELSE 0 END, @CurMaxSession);

            SET @SlotTime = DATEADD(MINUTE, @CurDuration, @SlotTime);
        END

        FETCH NEXT FROM curSchedules INTO @CurScheduleId, @CurStartTime, @CurEndTime, @CurDuration, @CurMaxPerSlot, @CurMaxSession;
    END
    CLOSE curSchedules;
    DEALLOCATE curSchedules;

    -- Handle MaxPatientsPerSession
    -- If total booked for a schedule >= MaxPatientsPerSession, mark remaining slots IsAvailable = 0
    IF @PatientColExists = 1
    BEGIN
        UPDATE s
        SET s.IsAvailable = 0
        FROM #AvailableSlots s
        INNER JOIN (
            SELECT ScheduleId, COUNT(*) as TotalBookedSession
            FROM PatientOPDService
            WHERE CAST(VisitDate AS DATE) = @Date AND Status <> 'Cancelled'
            GROUP BY ScheduleId
        ) b ON s.ScheduleId = b.ScheduleId
        WHERE s.MaxPatientsPerSession IS NOT NULL AND b.TotalBookedSession >= s.MaxPatientsPerSession AND s.IsAvailable = 1;
    END

    -- Return normal state
    SELECT 0 AS HasException, CAST(NULL AS NVARCHAR(500)) AS ExceptionReason;
    -- Slots
    SELECT ScheduleId, SlotTime, BookedCount, MaxPerSlot, IsAvailable FROM #AvailableSlots ORDER BY SlotTime;

    DROP TABLE #AvailableSlots;
END
GO


-- 2. usp_Api_OPD_Dashboard_GetStats
CREATE OR ALTER PROCEDURE dbo.usp_Api_OPD_Dashboard_GetStats
    @BranchId INT,
    @Date     DATE
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Date variables
    DECLARE @DayOfWeek TINYINT;
    -- Map to 1=Mon, 7=Sun regardless of @@DATEFIRST
    SET @DayOfWeek = (DATEPART(WEEKDAY, @Date) + @@DATEFIRST - 2) % 7 + 1;
    IF @DayOfWeek = 7 SET @DayOfWeek = 0;

    -- Summary statistics calculations
    DECLARE @TotalPatients INT;
    SELECT @TotalPatients = COUNT(*) 
    FROM dbo.PatientMaster 
    WHERE BranchId = @BranchId AND IsActive = 1;

    DECLARE @TodayNewPatients INT;
    SELECT @TodayNewPatients = COUNT(*) 
    FROM dbo.PatientMaster 
    WHERE BranchId = @BranchId 
      AND IsActive = 1 
      AND CAST(CreatedDate AS DATE) = @Date;

    DECLARE @TodayBookings INT;
    DECLARE @TodayRevenue DECIMAL(10,2);
    DECLARE @TodayRegistered INT;
    DECLARE @TodayCompleted INT;
    DECLARE @TodayCancelled INT;

    SELECT 
        @TodayBookings = COUNT(*),
        @TodayRevenue = ISNULL(SUM(TotalAmount), 0),
        @TodayRegistered = SUM(CASE WHEN Status = 'Registered' THEN 1 ELSE 0 END),
        @TodayCompleted = SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END),
        @TodayCancelled = SUM(CASE WHEN Status = 'Cancelled' THEN 1 ELSE 0 END)
    FROM dbo.PatientOPDService
    WHERE BranchId = @BranchId 
      AND CAST(VisitDate AS DATE) = @Date 
      AND IsActive = 1;

    -- Return ResultSet 1: Summary Stats
    SELECT 
        @TotalPatients AS TotalPatientsCount,
        @TodayNewPatients AS TodayNewRegistrations,
        ISNULL(@TodayBookings, 0) AS TodayTotalBookings,
        ISNULL(@TodayRevenue, 0) AS TodayTotalRevenue,
        ISNULL(@TodayRegistered, 0) AS TodayRegisteredCount,
        ISNULL(@TodayCompleted, 0) AS TodayCompletedCount,
        ISNULL(@TodayCancelled, 0) AS TodayCancelledCount;

    -- Return ResultSet 2: Bookings by Status
    SELECT 
        Status, 
        COUNT(*) AS Count
    FROM dbo.PatientOPDService
    WHERE BranchId = @BranchId 
      AND CAST(VisitDate AS DATE) = @Date 
      AND IsActive = 1
    GROUP BY Status;

    -- Return ResultSet 3: Bookings by Service Type
    SELECT 
        ISNULL(si.ServiceType, 'Other') AS ServiceType, 
        COUNT(*) AS Count, 
        SUM(ISNULL(si.ServiceCharges, 0)) AS Revenue
    FROM dbo.PatientOPDServiceItem si 
    INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = si.OPDServiceId 
    WHERE s.BranchId = @BranchId 
      AND CAST(s.VisitDate AS DATE) = @Date 
      AND s.IsActive = 1 
      AND si.IsActive = 1 
    GROUP BY si.ServiceType;

    -- Return ResultSet 4: Today's Doctor Roster Status / Summary
    SELECT 
        d.DoctorId,
        d.FullName AS DoctorName,
        dsm.ScheduleId,
        dsm.StartTime,
        dsm.EndTime,
        drm.RoomName,
        fm.FloorName,
        (SELECT TOP 1 ds.SpecialityName 
         FROM dbo.DoctorSpecialityMaster ds 
         WHERE ds.SpecialityId = d.PrimarySpecialityId AND ds.IsActive = 1) AS Speciality,
        
        (SELECT COUNT(*) 
         FROM dbo.PatientOPDService s 
         WHERE s.ConsultingDoctorId = d.DoctorId 
           AND CAST(s.VisitDate AS DATE) = @Date 
           AND s.IsActive = 1 
           AND s.Status <> 'Cancelled') AS TotalVisits,
        
        (SELECT COUNT(*) 
         FROM dbo.PatientOPDService s 
         WHERE s.ConsultingDoctorId = d.DoctorId 
           AND CAST(s.VisitDate AS DATE) = @Date 
           AND s.IsActive = 1 
           AND s.Status = 'Completed') AS CompletedVisits,
        
        (SELECT COUNT(*) 
         FROM dbo.PatientOPDService s 
         WHERE s.ConsultingDoctorId = d.DoctorId 
           AND CAST(s.VisitDate AS DATE) = @Date 
           AND s.IsActive = 1 
           AND s.Status = 'Registered') AS PendingVisits
    FROM dbo.DoctorScheduleMaster dsm
    INNER JOIN dbo.DoctorMaster d ON dsm.DoctorId = d.DoctorId
    LEFT JOIN dbo.DoctorRoomMapping drmapping ON drmapping.DoctorId = d.DoctorId
    LEFT JOIN dbo.DoctorRoomMaster drm ON drm.RoomId = drmapping.RoomId
    LEFT JOIN dbo.FloorMaster fm ON fm.FloorId = drm.FloorId
    WHERE dsm.BranchId = @BranchId
      AND dsm.DayOfWeek = @DayOfWeek
      AND dsm.IsActive = 1
      AND dsm.EffectiveFrom <= @Date
      AND (dsm.EffectiveTo IS NULL OR dsm.EffectiveTo >= @Date)
      AND NOT EXISTS (
          SELECT 1 FROM dbo.DoctorScheduleException de 
          WHERE de.DoctorId = dsm.DoctorId 
            AND de.BranchId = dsm.BranchId 
            AND de.ExceptionDate = @Date 
            AND de.IsActive = 1
      )
    ORDER BY dsm.StartTime;

    -- Return ResultSet 5: Today's Recent Bookings (Limit 10)
    SELECT TOP 10
        s.OPDServiceId,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        )) AS PatientName,
        s.TokenNo,
        s.OPDBillNo,
        d.FullName AS ConsultingDoctorName,
        ISNULL(s.TotalAmount, 0) AS TotalAmount,
        ISNULL(ph.TotalPaid, 0) AS TotalPaid,
        s.Status,
        s.VisitDate,
        s.AppointmentTime
    FROM dbo.PatientOPDService s
    INNER JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    LEFT JOIN dbo.PaymentHeader ph ON ph.OPDServiceId = s.OPDServiceId AND ph.ModuleCode = 'OPD' AND ph.IsActive = 1
    WHERE s.BranchId = @BranchId
      AND CAST(s.VisitDate AS DATE) = @Date
    ORDER BY s.OPDServiceId DESC;

    -- Return ResultSet 6: Today's Scheduled Appointments (Future Bookings)
    SELECT 
        s.OPDServiceId,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        )) AS PatientName,
        s.TokenNo,
        s.OPDBillNo,
        d.FullName AS ConsultingDoctorName,
        ISNULL(s.TotalAmount, 0) AS TotalAmount,
        ISNULL(ph.TotalPaid, 0) AS TotalPaid,
        s.Status,
        s.VisitDate,
        s.AppointmentTime
    FROM dbo.PatientOPDService s
    INNER JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    LEFT JOIN dbo.PaymentHeader ph ON ph.OPDServiceId = s.OPDServiceId AND ph.ModuleCode = 'OPD' AND ph.IsActive = 1
    WHERE s.BranchId = @BranchId
      AND CAST(s.VisitDate AS DATE) = @Date
      AND s.AppointmentTime IS NOT NULL
      AND s.IsActive = 1
      AND p.IsActive = 1
    ORDER BY s.AppointmentTime ASC;
END
GO
