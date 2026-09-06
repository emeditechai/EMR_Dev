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
    SELECT 
        ScheduleId, 
        CONVERT(varchar(5), SlotTime, 108) AS SlotTime, 
        BookedCount, 
        MaxPerSlot, 
        IsAvailable 
    FROM #AvailableSlots ORDER BY SlotTime;

    DROP TABLE #AvailableSlots;
END
GO
