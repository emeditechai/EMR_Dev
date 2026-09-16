-- ============================================================================
-- Migration 2062: Permanently ensure QUOTED_IDENTIFIER and ANSI_NULLS are ON
-- for the database and recompile all 30 stored procedures with QUOTED_IDENTIFIER ON
-- ============================================================================

ALTER DATABASE Dev_EMR SET QUOTED_IDENTIFIER ON;
ALTER DATABASE Dev_EMR SET ANSI_NULLS ON;
GO

-- ── usp_Api_DoctorDashboard_GetQueue ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorDashboard_GetQueue
    @CompanyId INT = NULL,
    @BranchId INT,
    @DoctorId INT,
    @QueueDate DATE
AS
BEGIN
    SET NOCOUNT ON;

    IF @QueueDate IS NULL SET @QueueDate = CAST(GETDATE() AS DATE);

    SELECT
        pos.OPDServiceId,
        pos.PatientId,
        p.PatientCode,
        ISNULL(p.FirstName + ' ', '') + ISNULL(p.MiddleName + ' ', '') + ISNULL(p.LastName, '') AS PatientName,
        p.PhoneNumber,
        p.Gender,
        CASE
            WHEN p.DateOfBirth IS NULL THEN NULL
            ELSE DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
               - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
        END AS Age,
        p.DateOfBirth,
        pos.TokenNo,
        pos.OPDBillNo,
        pos.VisitDate,
        pos.Status,
        pos.ServiceType,
        pos.AppointmentTime,
        (SELECT TOP 1 PaymentStatus FROM PaymentHeader
         WHERE ModuleCode = 'OPD' AND ModuleRefId = pos.OPDServiceId AND IsActive = 1) AS PaymentStatus,
        CAST(
            CASE WHEN EXISTS (SELECT 1 FROM EmrPatientConsultation e WHERE e.OPDServiceId = pos.OPDServiceId)
            THEN 1 ELSE 0 END
        AS BIT) AS IsEmrDone,
        pos.ConsultingDoctorId,
        d.FullName AS ConsultingDoctorName,
        p.PhotoPath,
        -- Video consultation fields
        ISNULL(
            (SELECT TOP 1 sm.ConsultingType
             FROM PatientOPDServiceItem i
             JOIN ServiceMaster sm ON sm.ServiceId = i.ServiceId
             WHERE i.OPDServiceId = pos.OPDServiceId AND sm.ConsultingType = 'Video' AND i.IsActive = 1),
            'Walk-In'
        ) AS ConsultingType,
        (SELECT TOP 1 vc.DoctorHostUrl
         FROM tbl_VideoConsultation vc
         WHERE vc.OPDServiceId = pos.OPDServiceId AND vc.Status = 'Scheduled') AS VideoHostUrl,
        (SELECT TOP 1 vc.PatientRoomUrl
         FROM tbl_VideoConsultation vc
         WHERE vc.OPDServiceId = pos.OPDServiceId AND vc.Status = 'Scheduled') AS VideoPatientUrl
    FROM PatientOPDService pos
    INNER JOIN PatientMaster p ON p.PatientId = pos.PatientId
    LEFT JOIN DoctorMaster d ON d.DoctorId = pos.ConsultingDoctorId
    WHERE pos.BranchId = @BranchId
      AND CAST(pos.VisitDate AS DATE) = @QueueDate
      AND pos.IsActive = 1
      AND p.IsActive = 1
      AND pos.Status IN ('Consulting', 'Completed', 'Skipped')
      AND (@DoctorId IS NULL OR @DoctorId = 0 OR pos.ConsultingDoctorId = @DoctorId)
      AND (@CompanyId IS NULL OR p.CompanyId = @CompanyId)
    ORDER BY
        CASE
            WHEN pos.Status = 'Consulting' THEN 0
            WHEN pos.Status = 'Skipped' THEN 1
            ELSE 2
        END ASC,
        pos.TokenNo ASC;

    -- ResultSet 2: Stats
    SELECT
        (SELECT COUNT(*) FROM PatientOPDService
         WHERE BranchId = @BranchId
           AND CAST(VisitDate AS DATE) = @QueueDate
           AND IsActive = 1
           AND Status IN ('Consulting', 'Skipped')
           AND (@DoctorId IS NULL OR @DoctorId = 0 OR ConsultingDoctorId = @DoctorId)) AS TotalWaiting,
        (SELECT COUNT(*) FROM PatientOPDService
         WHERE BranchId = @BranchId
           AND CAST(VisitDate AS DATE) = @QueueDate
           AND IsActive = 1
           AND Status = 'Completed'
           AND (@DoctorId IS NULL OR @DoctorId = 0 OR ConsultingDoctorId = @DoctorId)) AS TotalCompleted;
END
GO

-- ── usp_Api_DoctorSchedule_Delete ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- 4. usp_Api_DoctorSchedule_Delete
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_Delete]
    @ScheduleId INT,
    @DeletedBy INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @WarningMessage NVARCHAR(500) = NULL;

    -- Soft delete
    UPDATE DoctorScheduleMaster
    SET IsActive = 0, ModifiedBy = @DeletedBy, ModifiedDate = getutcdate()
    WHERE ScheduleId = @ScheduleId;

    -- Check future bookings (if PatientOPDService has ScheduleId)
    -- We use dynamic sql check if table altered yet or we can just safely join if we create the other script too.
    -- Assuming Phase 2 alters the table, we do:
    IF EXISTS (
        SELECT 1 FROM sys.columns 
        WHERE Name = N'ScheduleId' AND Object_ID = Object_ID(N'dbo.PatientOPDService')
    )
    BEGIN
        DECLARE @Sql NVARCHAR(MAX) = N'
        IF EXISTS (SELECT 1 FROM PatientOPDService WHERE ScheduleId = @p_ScheduleId AND VisitDate > GETDATE() AND Status <> ''Cancelled'')
        BEGIN
            SET @p_Warning = ''Warning: There are future patient bookings associated with this deleted schedule.''
        END';
        
        EXEC sp_executesql @Sql, N'@p_ScheduleId INT, @p_Warning NVARCHAR(500) OUTPUT', @ScheduleId, @WarningMessage OUTPUT;
    END

    SELECT 1 AS Success, @WarningMessage AS Warning;
END
GO

-- ── usp_Api_DoctorSchedule_GetAvailableSlots ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_GetAvailableSlots]
    @DoctorId INT,
    @BranchId INT,
    @Date DATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Map weekday: 1=Mon .. 6=Sat, 0=Sun
    DECLARE @DayOfWeek TINYINT;
    SET @DayOfWeek = (DATEPART(WEEKDAY, @Date) + @@DATEFIRST - 2) % 7 + 1;
    IF @DayOfWeek = 7 SET @DayOfWeek = 0;

    -- Check Exception
    DECLARE @ExceptionReason NVARCHAR(500) = NULL;
    IF EXISTS (SELECT 1 FROM DoctorScheduleException WHERE DoctorId=@DoctorId AND BranchId=@BranchId AND ExceptionDate=@Date AND IsActive=1)
    BEGIN
        SELECT TOP 1 @ExceptionReason = Reason FROM DoctorScheduleException WHERE DoctorId=@DoctorId AND BranchId=@BranchId AND ExceptionDate=@Date AND IsActive=1;
        SELECT 1 AS HasException, @ExceptionReason AS ExceptionReason;
        SELECT TOP 0 0 AS ScheduleId, '' AS SlotTime, 0 AS BookedCount, 0 AS MaxPerSlot, CAST(0 AS BIT) AS IsAvailable;
        RETURN;
    END

    -- ── Build all slots using INTEGER minute arithmetic (avoids TIME overflow at midnight) ──
    CREATE TABLE #Slots (
        ScheduleId          INT,
        SlotMinutes         INT,   -- minutes from 00:00
        MaxPerSlot          INT,
        MaxPatientsPerSession INT
    );

    DECLARE @CurId INT, @CurStart TIME, @CurEnd TIME, @CurDur INT, @CurMaxSlot INT, @CurMaxSess INT;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT ScheduleId, StartTime, EndTime, SlotDurationMinutes, MaxPatientsPerSlot, MaxPatientsPerSession
        FROM DoctorScheduleMaster
        WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND DayOfWeek = @DayOfWeek AND IsActive = 1
          AND EffectiveFrom <= @Date AND (EffectiveTo IS NULL OR EffectiveTo >= @Date);

    OPEN cur;
    FETCH NEXT FROM cur INTO @CurId, @CurStart, @CurEnd, @CurDur, @CurMaxSlot, @CurMaxSess;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @StartMin INT = DATEDIFF(MINUTE, '00:00:00', @CurStart);
        DECLARE @EndMin   INT = DATEDIFF(MINUTE, '00:00:00', @CurEnd);
        DECLARE @CurMin   INT = @StartMin;

        -- Use integer loop: no TIME type overflow possible
        WHILE (@CurMin + @CurDur) <= @EndMin
        BEGIN
            INSERT INTO #Slots (ScheduleId, SlotMinutes, MaxPerSlot, MaxPatientsPerSession)
            VALUES (@CurId, @CurMin, @CurMaxSlot, @CurMaxSess);
            SET @CurMin = @CurMin + @CurDur;
        END

        FETCH NEXT FROM cur INTO @CurId, @CurStart, @CurEnd, @CurDur, @CurMaxSlot, @CurMaxSess;
    END
    CLOSE cur; DEALLOCATE cur;

    -- ── Count bookings per slot in ONE set-based query (no sp_executesql per slot) ──
    CREATE TABLE #Bookings (ScheduleId INT, SlotMinutes INT, BookedCount INT);

    IF EXISTS (SELECT 1 FROM sys.columns WHERE Name = N'ScheduleId' AND Object_ID = Object_ID(N'dbo.PatientOPDService'))
    BEGIN
        INSERT INTO #Bookings (ScheduleId, SlotMinutes, BookedCount)
        SELECT
            pos.ScheduleId,
            DATEDIFF(MINUTE, '00:00:00', pos.AppointmentTime) AS SlotMinutes,
            COUNT(*) AS BookedCount
        FROM PatientOPDService pos
        WHERE CAST(pos.VisitDate AS DATE) = @Date
          AND pos.Status <> 'Cancelled'
          AND pos.ScheduleId IN (SELECT DISTINCT ScheduleId FROM #Slots)
        GROUP BY pos.ScheduleId, pos.AppointmentTime;

        -- Mark full session: if total booked >= MaxPatientsPerSession, set MaxPerSlot = 0 (all slots unavailable)
        UPDATE s SET s.MaxPerSlot = 0
        FROM #Slots s
        INNER JOIN (
            SELECT ScheduleId, COUNT(*) AS TotalBooked
            FROM PatientOPDService
            WHERE CAST(VisitDate AS DATE) = @Date AND Status <> 'Cancelled'
            GROUP BY ScheduleId
        ) b ON s.ScheduleId = b.ScheduleId
        WHERE s.MaxPatientsPerSession IS NOT NULL AND b.TotalBooked >= s.MaxPatientsPerSession;
    END

    -- ── Return header row ──
    SELECT 0 AS HasException, CAST(NULL AS NVARCHAR(500)) AS ExceptionReason;

    -- ── Return slots ──
    SELECT
        s.ScheduleId,
        CONVERT(VARCHAR(5), DATEADD(MINUTE, s.SlotMinutes, '00:00:00'), 108) AS SlotTime,
        ISNULL(b.BookedCount, 0) AS BookedCount,
        s.MaxPerSlot,
        CAST(CASE WHEN ISNULL(b.BookedCount, 0) < s.MaxPerSlot THEN 1 ELSE 0 END AS BIT) AS IsAvailable
    FROM #Slots s
    LEFT JOIN #Bookings b ON b.ScheduleId = s.ScheduleId AND b.SlotMinutes = s.SlotMinutes
    ORDER BY s.ScheduleId, s.SlotMinutes;

    DROP TABLE #Slots;
    DROP TABLE #Bookings;
END
GO

-- ── usp_Api_DoctorSchedule_GetByDoctor ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- 1. usp_Api_DoctorSchedule_GetByDoctor
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_GetByDoctor]
    @DoctorId INT = NULL,
    @BranchId INT = NULL,
    @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        dsm.ScheduleId,
        dsm.DoctorId,
        d.FullName AS DoctorName,
        dsm.BranchId,
        dsm.RoomId,
        drm.RoomName,
        dsm.DayOfWeek,
        dsm.StartTime,
        dsm.EndTime,
        dsm.SlotDurationMinutes,
        dsm.MaxPatientsPerSlot,
        dsm.MaxPatientsPerSession,
        dsm.ScheduleType,
        dsm.EffectiveFrom,
        dsm.EffectiveTo,
        dsm.IsActive,
        CASE dsm.DayOfWeek
            WHEN 1 THEN 'Monday'
            WHEN 2 THEN 'Tuesday'
            WHEN 3 THEN 'Wednesday'
            WHEN 4 THEN 'Thursday'
            WHEN 5 THEN 'Friday'
            WHEN 6 THEN 'Saturday'
            WHEN 0 THEN 'Sunday'
        END AS DayName
    FROM DoctorScheduleMaster dsm
    INNER JOIN DoctorMaster d ON dsm.DoctorId = d.DoctorId
    LEFT JOIN DoctorRoomMaster drm ON dsm.RoomId = drm.RoomId
    WHERE (@DoctorId IS NULL OR dsm.DoctorId = @DoctorId)
      AND (@BranchId IS NULL OR dsm.BranchId = @BranchId)
      AND (@DepartmentId IS NULL OR EXISTS (
          SELECT 1 FROM DoctorDepartmentMap ddm
          WHERE ddm.DoctorId = dsm.DoctorId AND ddm.DeptId = @DepartmentId AND ddm.IsActive = 1
      ))
      AND dsm.IsActive = 1
    ORDER BY dsm.DayOfWeek, dsm.StartTime;
END
GO

-- ── usp_Api_DoctorSchedule_GetById ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- 2. usp_Api_DoctorSchedule_GetById
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_GetById]
    @ScheduleId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        dsm.ScheduleId,
        dsm.DoctorId,
        dsm.BranchId,
        dsm.RoomId,
        drm.RoomName,
        dsm.DayOfWeek,
        dsm.StartTime,
        dsm.EndTime,
        dsm.SlotDurationMinutes,
        dsm.MaxPatientsPerSlot,
        dsm.MaxPatientsPerSession,
        dsm.ScheduleType,
        dsm.EffectiveFrom,
        dsm.EffectiveTo,
        dsm.IsActive,
        CASE dsm.DayOfWeek
            WHEN 1 THEN 'Monday'
            WHEN 2 THEN 'Tuesday'
            WHEN 3 THEN 'Wednesday'
            WHEN 4 THEN 'Thursday'
            WHEN 5 THEN 'Friday'
            WHEN 6 THEN 'Saturday'
            WHEN 0 THEN 'Sunday'
        END AS DayName
    FROM DoctorScheduleMaster dsm
    LEFT JOIN DoctorRoomMaster drm ON dsm.RoomId = drm.RoomId
    WHERE dsm.ScheduleId = @ScheduleId;
END
GO

-- ── usp_Api_DoctorSchedule_Upsert ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- 3. usp_Api_DoctorSchedule_Upsert
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_Upsert]
    @ScheduleId INT,
    @DoctorId INT,
    @BranchId INT,
    @RoomId INT = NULL,
    @DayOfWeek TINYINT,
    @StartTime TIME,
    @EndTime TIME,
    @SlotDurationMinutes INT,
    @MaxPatientsPerSlot INT,
    @MaxPatientsPerSession INT = NULL,
    @ScheduleType VARCHAR(20),
    @EffectiveFrom DATE,
    @EffectiveTo DATE = NULL,
    @RequestedByUserId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Validation
    IF @StartTime >= @EndTime
    BEGIN
        RAISERROR('StartTime must be less than EndTime.', 16, 1);
        RETURN;
    END

    -- Check overlap
    IF EXISTS (
        SELECT 1 FROM DoctorScheduleMaster
        WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND DayOfWeek = @DayOfWeek AND IsActive = 1
          AND ScheduleId <> @ScheduleId
          AND (
                (@StartTime >= StartTime AND @StartTime < EndTime) OR
                (@EndTime > StartTime AND @EndTime <= EndTime) OR
                (@StartTime <= StartTime AND @EndTime >= EndTime)
          )
          AND (EffectiveTo IS NULL OR EffectiveTo >= @EffectiveFrom)
          AND (@EffectiveTo IS NULL OR EffectiveFrom <= @EffectiveTo)
    )
    BEGIN
        RAISERROR('Schedule overlaps with an existing active schedule for this day and time period.', 16, 1);
        RETURN;
    END

    IF @ScheduleId = 0
    BEGIN
        INSERT INTO DoctorScheduleMaster (
            DoctorId, BranchId, RoomId, DayOfWeek, StartTime, EndTime, SlotDurationMinutes, MaxPatientsPerSlot, MaxPatientsPerSession, ScheduleType, EffectiveFrom, EffectiveTo, CreatedBy
        )
        VALUES (
            @DoctorId, @BranchId, @RoomId, @DayOfWeek, @StartTime, @EndTime, @SlotDurationMinutes, @MaxPatientsPerSlot, @MaxPatientsPerSession, @ScheduleType, @EffectiveFrom, @EffectiveTo, @RequestedByUserId
        );
        SELECT SCOPE_IDENTITY() AS ScheduleId;
    END
    ELSE
    BEGIN
        UPDATE DoctorScheduleMaster
        SET 
            DoctorId = @DoctorId,
            BranchId = @BranchId,
            RoomId = @RoomId,
            DayOfWeek = @DayOfWeek,
            StartTime = @StartTime,
            EndTime = @EndTime,
            SlotDurationMinutes = @SlotDurationMinutes,
            MaxPatientsPerSlot = @MaxPatientsPerSlot,
            MaxPatientsPerSession = @MaxPatientsPerSession,
            ScheduleType = @ScheduleType,
            EffectiveFrom = @EffectiveFrom,
            EffectiveTo = @EffectiveTo,
            ModifiedBy = @RequestedByUserId,
            ModifiedDate = getutcdate()
        WHERE ScheduleId = @ScheduleId;
        
        SELECT @ScheduleId AS ScheduleId;
    END
END
GO

-- ── usp_Api_DoctorScheduleException_Delete ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- 8. usp_Api_DoctorScheduleException_Delete
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorScheduleException_Delete]
    @ExceptionId INT,
    @DeletedBy INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE DoctorScheduleException
    SET IsActive = 0
    WHERE ExceptionId = @ExceptionId;

    SELECT 1 AS Success;
END
GO

-- ── usp_Api_DoctorScheduleException_GetByDoctor ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- 2. usp_Api_DoctorScheduleException_GetByDoctor
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorScheduleException_GetByDoctor]
    @DoctorId INT = NULL,
    @BranchId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        e.ExceptionId,
        e.DoctorId,
        ISNULL(doc.NamePrefix + ' ', '') + doc.FullName AS DoctorName,
        e.BranchId,
        e.ExceptionDate,
        e.Reason,
        e.ExceptionType,
        e.IsActive,
        e.CreatedBy,
        e.CreatedDate
    FROM DoctorScheduleException e
    INNER JOIN DoctorMaster doc ON doc.DoctorId = e.DoctorId
    WHERE (@DoctorId IS NULL OR e.DoctorId = @DoctorId)
      AND (@BranchId IS NULL OR e.BranchId = @BranchId)
      AND (@FromDate IS NULL OR e.ExceptionDate >= @FromDate)
      AND (@ToDate IS NULL OR e.ExceptionDate <= @ToDate)
      AND (@DepartmentId IS NULL OR EXISTS (
            SELECT 1 FROM DoctorDepartmentMap ddm 
            WHERE ddm.DoctorId = e.DoctorId AND ddm.DeptId = @DepartmentId AND ddm.IsActive = 1
          ))
      AND e.IsActive = 1
    ORDER BY e.ExceptionDate DESC;
END
GO

-- ── usp_Api_DoctorScheduleException_Upsert ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- 7. usp_Api_DoctorScheduleException_Upsert
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorScheduleException_Upsert]
    @ExceptionId INT = 0,
    @DoctorId INT,
    @BranchId INT,
    @ExceptionDate DATE,
    @Reason NVARCHAR(500),
    @ExceptionType VARCHAR(20),
    @RequestedByUserId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1 FROM DoctorScheduleException 
        WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND ExceptionDate = @ExceptionDate AND IsActive = 1 AND ExceptionId <> @ExceptionId
    )
    BEGIN
        RAISERROR('Exception already exists for this date.', 16, 1);
        RETURN;
    END

    IF @ExceptionId = 0
    BEGIN
        INSERT INTO DoctorScheduleException (DoctorId, BranchId, ExceptionDate, Reason, ExceptionType, CreatedBy)
        VALUES (@DoctorId, @BranchId, @ExceptionDate, @Reason, @ExceptionType, @RequestedByUserId);
        
        SELECT SCOPE_IDENTITY() AS ExceptionId;
    END
    ELSE
    BEGIN
        UPDATE DoctorScheduleException
        SET ExceptionDate = @ExceptionDate,
            Reason = @Reason,
            ExceptionType = @ExceptionType
        WHERE ExceptionId = @ExceptionId;
        
        SELECT @ExceptionId AS ExceptionId;
    END
END
GO

-- ── usp_Api_PaymentSummary_GetByBill ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- ── 5. Update dbo.usp_Api_PaymentSummary_GetByBill ───────────────────────────
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_PaymentSummary_GetByBill]
    @ModuleCode  NVARCHAR(20),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    IF @ModuleCode = 'OPD'
    BEGIN
        SELECT
            s.OPDServiceId          AS ModuleRefId,
            'OPD'                   AS ModuleCode,
            s.OPDServiceId,
            s.OPDBillNo,
            s.TokenNo,
            p.PatientId,
            p.PatientCode,
            (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
            p.PhoneNumber           AS PatientPhone,
            ISNULL(s.BranchId, 0)  AS BranchId,
            ISNULL(s.TotalAmount, 0) AS SubTotal
        FROM PatientOPDService s
        INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
        WHERE s.OPDServiceId = @ModuleRefId;

        DECLARE @PaymentHeaderId_OPD INT;
        SELECT @PaymentHeaderId_OPD = PaymentHeaderId 
        FROM PaymentHeader 
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        SELECT
            si.ItemId                        AS LineRefId,
            si.ServiceType,
            ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
            ISNULL(si.ServiceCharges, 0)     AS OriginalAmount,
            ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
            ISNULL(pli.NetLineAmount, ISNULL(si.ServiceCharges, 0)) AS NetLineAmount,
            ISNULL(sm.IsGstRequired, 0)      AS IsGstRequired,
            sm.GstPercentage                 AS GstPercentage,
            ISNULL(pli.CgstAmount, 0)        AS CgstAmount,
            ISNULL(pli.SgstAmount, 0)        AS SgstAmount,
            ISNULL(pli.IgstAmount, 0)        AS IgstAmount
        FROM PatientOPDServiceItem si
        LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
        LEFT JOIN PaymentLineItem pli ON pli.PaymentHeaderId = @PaymentHeaderId_OPD AND pli.ModuleLineRefId = si.ItemId AND pli.IsActive = 1
        WHERE si.OPDServiceId = @ModuleRefId AND si.IsActive = 1
        ORDER BY si.ItemId;

        SELECT
            PaymentHeaderId,
            ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
            HeaderDiscountType,
            HeaderDiscountValue,
            ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
            ISNULL(NetAmount, 0)              AS NetAmount,
            ISNULL(TotalPaid, 0)              AS TotalPaid,
            ISNULL(BalanceDue, 0)             AS BalanceDue,
            ISNULL(PaymentStatus, 'U')        AS PaymentStatus
        FROM PaymentHeader
        WHERE PaymentHeaderId = @PaymentHeaderId_OPD;
    END
    ELSE IF @ModuleCode = 'LAB'
    BEGIN
        SELECT
            s.LabOrderId            AS ModuleRefId,
            'LAB'                   AS ModuleCode,
            s.LabOrderId            AS OPDServiceId, 
            s.BillNo                AS OPDBillNo,
            s.TokenNo               AS TokenNo,
            p.PatientId,
            p.PatientCode,
            (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
            p.PhoneNumber           AS PatientPhone,
            ISNULL(s.BranchId, 0)   AS BranchId,
            ISNULL(s.TotalAmount, 0) AS SubTotal
        FROM LabOrder s
        INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
        WHERE s.LabOrderId = @ModuleRefId;

        DECLARE @PaymentHeaderId_LAB INT;
        SELECT @PaymentHeaderId_LAB = PaymentHeaderId 
        FROM PaymentHeader 
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        SELECT
            si.LabOrderItemId                AS LineRefId,
            CASE WHEN si.Type = 'P' THEN 'Package' ELSE 'Test' END AS ServiceType,
            CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, '(Unknown Package)') ELSE ISNULL(im.Test_Name, '(Unknown)') END AS ItemName,
            ISNULL(si.Price, 0)              AS OriginalAmount,
            ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
            ISNULL(pli.NetLineAmount, ISNULL(si.Price, 0)) AS NetLineAmount,
            0                                AS IsGstRequired,
            0                                AS GstPercentage,
            0                                AS CgstAmount,
            0                                AS SgstAmount,
            0                                AS IgstAmount
        FROM LabOrderItem si
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
        LEFT JOIN dbo.LabInvestigationMaster im ON im.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
        LEFT JOIN PaymentLineItem pli ON pli.PaymentHeaderId = @PaymentHeaderId_LAB AND pli.ModuleLineRefId = si.LabOrderItemId AND pli.IsActive = 1
        WHERE si.LabOrderId = @ModuleRefId AND si.IsActive = 1
        ORDER BY si.LabOrderItemId;

        SELECT
            PaymentHeaderId,
            ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
            HeaderDiscountType,
            HeaderDiscountValue,
            ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
            ISNULL(NetAmount, 0)              AS NetAmount,
            ISNULL(TotalPaid, 0)              AS TotalPaid,
            ISNULL(BalanceDue, 0)             AS BalanceDue,
            ISNULL(PaymentStatus, 'U')        AS PaymentStatus
        FROM PaymentHeader
        WHERE PaymentHeaderId = @PaymentHeaderId_LAB;
    END
END;
GO

-- ── usp_Api_ServiceBooking_GetById ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_ServiceBooking_GetById
    @OPDServiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: Header
    SELECT
        s.OPDServiceId,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        ))                        AS PatientName,
        p.PhoneNumber,
        p.Gender,
        p.DateOfBirth,
        d.FullName                AS ConsultingDoctorName,
        s.VisitDate,
        ISNULL(s.TotalAmount, 0)  AS TotalAmount,
        s.Status,
        s.AppointmentTime,
        s.CreatedDate
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN DoctorMaster  d ON d.DoctorId  = s.ConsultingDoctorId
    WHERE s.OPDServiceId = @OPDServiceId;

    -- RS2: Line items
    SELECT
        si.ItemId,
        si.ServiceType,
        ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
        ISNULL(si.ServiceCharges, 0)     AS ServiceCharges,
        ISNULL(sm.IsGstRequired, 0)      AS IsGstRequired,
        sm.GstPercentage                 AS GstPercentage
    FROM PatientOPDServiceItem si
    LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
    WHERE si.OPDServiceId = @OPDServiceId AND si.IsActive = 1
    ORDER BY si.ItemId;
END
GO

-- ── usp_B2B_GetSettlementReceipt ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetSettlementReceipt
(
    @ReceiptNo NVARCHAR(50)
)
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    -- RS1: Receipt Header & Partner Information
    SELECT TOP 1
        pd.ReceiptNo,
        pd.PaymentDate,
        pd.CreatedDate,
        SUM(pd.PaidAmount) OVER() AS TotalAmount,
        COUNT(pd.PaymentDetailId) OVER() AS SettledBillCount,
        ISNULL(pm.MethodName, 'Cash') AS PaymentMethod,
        pd.TransactionRef,
        pd.BankName,
        pd.ChequeNo,
        pd.Notes,
        u.FullName AS CreatedByName,
        lo.AgentType,
        lo.B2BAgentID AS AgentId,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Franchise_Name
            WHEN lo.AgentType = 'C' THEN corp.Corporate_Name
            ELSE 'B2B Partner'
        END AS PartnerName,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Franchise_Code
            WHEN lo.AgentType = 'C' THEN corp.Corporate_Code
            ELSE '—'
        END AS PartnerCode,
        CASE 
            WHEN lo.AgentType = 'F' THEN 
                CASE WHEN f.Franchise_Type = 1 THEN 'Franchise Partner (Prepaid Wallet)' ELSE 'Franchise Partner (Postpaid Credit)' END
            WHEN lo.AgentType = 'C' THEN ISNULL(corp.Corporate_Type, 'Corporate Partner')
            ELSE 'B2B Client'
        END AS PartnerType,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Mobile_No
            WHEN lo.AgentType = 'C' THEN corp.Contact_No
            ELSE NULL
        END AS PartnerPhone,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Email
            WHEN lo.AgentType = 'C' THEN corp.Email
            ELSE NULL
        END AS PartnerEmail,
        CASE 
            WHEN lo.AgentType = 'C' THEN corp.Address
            ELSE NULL
        END AS PartnerAddress,
        lo.BranchId,
        b.BranchName,
        CASE 
            WHEN pm.MethodCode = 'CASH' OR pm.MethodName = 'Cash' THEN 'Cash Account'
            ELSE 'Bank Account'
        END AS DebitLedgerName,
        CASE 
            WHEN lo.AgentType = 'C' THEN 'Corporate Receivable'
            ELSE 'Franchise Receivable'
        END AS CreditLedgerName
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = ph.ModuleRefId
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    LEFT JOIN dbo.Users u ON u.Id = pd.CreatedBy
    LEFT JOIN dbo.BranchMaster b ON b.BranchID = lo.BranchId
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE pd.ReceiptNo = @ReceiptNo AND pd.IsActive = 1;

    -- RS2: Settled Bills Breakdown
    SELECT 
        lo.LabOrderId,
        lo.BillNo,
        lo.TokenNo,
        lo.OrderDate,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.Gender,
        DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
            CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END AS Age,
        ISNULL(lo.B2BTotal, lo.TotalAmount) AS B2BTotal,
        pd.PaidAmount AS SettledAmount,
        ph.TotalPaid,
        ph.BalanceDue,
        ph.PaymentStatus,
        tests.TestNames
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = ph.ModuleRefId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    OUTER APPLY (
        SELECT STRING_AGG(CASE WHEN loi.Type = 'P' THEN pkg.Profile_Name ELSE lim.Test_Name END, ', ') AS TestNames
        FROM dbo.LabOrderItem loi
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
        WHERE loi.LabOrderId = lo.LabOrderId AND loi.IsActive = 1
    ) tests
    WHERE pd.ReceiptNo = @ReceiptNo AND pd.IsActive = 1
    ORDER BY lo.OrderDate ASC, lo.LabOrderId ASC;
END;
GO

-- ── usp_B2B_LAB_GetNextTokenNo ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- 1. Create B2B Token Generator Procedure
CREATE OR ALTER PROCEDURE dbo.usp_B2B_LAB_GetNextTokenNo
    @BranchId  INT,
    @TokenDate DATE          = NULL,
    @TokenNo   NVARCHAR(50)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    SET @TokenDate = ISNULL(@TokenDate, CAST(GETDATE() AS DATE));

    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode))) FROM dbo.BranchMaster WHERE BranchID = @BranchId;
    IF @BranchCode IS NULL SET @BranchCode = 'HO';

    DECLARE @NewSeq INT = 0;

    UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'B2B_LAB';

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDTokenSequence (BranchId, TokenDate, ModuleCode, LastSeq, CompanyId)
            VALUES (@BranchId, @TokenDate, 'B2B_LAB', 1, 1);
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
            BEGIN
                UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'B2B_LAB';
            END
            ELSE THROW;
        END CATCH
    END

    SET @TokenNo = 'B2B-LAB-' + @BranchCode + '-' + RIGHT('0000' + CAST(@NewSeq AS VARCHAR(10)), 4);
END;
GO

-- ── usp_Bill_Cancel ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- ── 4. Update dbo.usp_Bill_Cancel ─────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Bill_Cancel
    @ModuleCode          CHAR(3),
    @ModuleRefId         INT,
    @BranchId            INT,
    @LineItemsJson       NVARCHAR(MAX),
    @Reason              NVARCHAR(500),
    @DiscountAdjusted    DECIMAL(10,2),
    @UserId              INT,
    @CancellationId      INT OUTPUT,
    @CancellationNo      NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate cancellation number
        EXEC dbo.usp_Bill_GetNextCancellationNo @ModuleCode, @BranchId, @CancellationNo OUTPUT;

        -- Parse line items from JSON
        DECLARE @Items TABLE (LineRefId INT, Amount DECIMAL(10,2));
        INSERT INTO @Items (LineRefId, Amount)
        SELECT 
            CAST(JSON_VALUE(j.value, '$.lineRefId') AS INT),
            CAST(JSON_VALUE(j.value, '$.amount') AS DECIMAL(10,2))
        FROM OPENJSON(@LineItemsJson) j;

        DECLARE @TotalItems INT = (SELECT COUNT(*) FROM @Items);
        IF @TotalItems = 0
            THROW 50001, 'No items selected for cancellation.', 1;

        -- Validate: check items are not already cancelled
        IF EXISTS (
            SELECT 1 FROM @Items i
            INNER JOIN dbo.BillCancellationItem bci ON bci.LineRefId = i.LineRefId
            INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
            WHERE bc.ModuleCode = @ModuleCode AND bc.IsActive = 1
        )
            THROW 50002, 'One or more selected items are already cancelled.', 1;

        DECLARE @CancelledAmount DECIMAL(10,2) = (SELECT SUM(Amount) FROM @Items);

        -- Determine full or partial
        DECLARE @TotalBillItems INT;
        DECLARE @CancellationType CHAR(1);

        IF @ModuleCode = 'LAB'
        BEGIN
            SELECT @TotalBillItems = COUNT(*) FROM dbo.LabOrderItem 
            WHERE LabOrderId = @ModuleRefId AND IsActive = 1;
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            SELECT @TotalBillItems = COUNT(*) FROM dbo.PatientOPDServiceItem 
            WHERE OPDServiceId = @ModuleRefId AND IsActive = 1;
        END

        SET @CancellationType = CASE WHEN @TotalItems >= @TotalBillItems THEN 'F' ELSE 'P' END;

        -- Insert BillCancellation header
        INSERT INTO dbo.BillCancellation 
            (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate,
             CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@ModuleCode, @ModuleRefId, @CancellationNo, @CancellationType, GETDATE(),
             @CancelledAmount, ISNULL(@DiscountAdjusted, 0), @Reason, 'C', @UserId, GETDATE(), 1);

        SET @CancellationId = SCOPE_IDENTITY();

        -- Insert BillCancellationItem rows
        INSERT INTO dbo.BillCancellationItem (CancellationId, LineRefId, OriginalAmount, CancelledAmount, IsActive)
        SELECT @CancellationId, LineRefId, Amount, Amount, 1
        FROM @Items;

        -- Mark items as inactive in source table
        IF @ModuleCode = 'LAB'
        BEGIN
            UPDATE dbo.LabOrderItem 
            SET IsActive = 0
            WHERE LabOrderItemId IN (SELECT LineRefId FROM @Items);
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            UPDATE dbo.PatientOPDServiceItem 
            SET IsActive = 0
            WHERE ItemId IN (SELECT LineRefId FROM @Items);
        END

        -- Update PaymentHeader
        IF @CancellationType = 'F'
        BEGIN
            -- Full cancellation: NetAmount and BalanceDue become 0
            UPDATE dbo.PaymentHeader
            SET NetAmount            = 0,
                BalanceDue           = 0,
                HeaderDiscountAmount = 0,
                RoundOffAmount       = 0,
                LineDiscountTotal    = 0,
                LastModifiedDate     = GETDATE(),
                LastModifiedBy       = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END
        ELSE
        BEGIN
            -- Partial cancellation: reduce NetAmount by (CancelledAmount - DiscountAdjusted)
            UPDATE dbo.PaymentHeader
            SET NetAmount    = CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0 ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END,
                BalanceDue   = CASE 
                                 WHEN (BalanceDue - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 
                                 THEN 0 
                                 ELSE (BalanceDue - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0)))
                               END,
                HeaderDiscountAmount = CASE WHEN (HeaderDiscountAmount - ISNULL(@DiscountAdjusted, 0)) < 0 THEN 0 ELSE (HeaderDiscountAmount - ISNULL(@DiscountAdjusted, 0)) END,
                LastModifiedDate = GETDATE(),
                LastModifiedBy   = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END

        -- If full cancellation, mark LabOrder/OPDService as inactive
        IF @CancellationType = 'F'
        BEGIN
            IF @ModuleCode = 'LAB'
                UPDATE dbo.LabOrder SET IsActive = 0 WHERE LabOrderId = @ModuleRefId;
            IF @ModuleCode = 'OPD'
                UPDATE dbo.PatientOPDService SET IsActive = 0 WHERE OPDServiceId = @ModuleRefId;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── usp_Bill_GetDetailForCancellation ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- ── 4. Update dbo.usp_Bill_GetDetailForCancellation ──────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Bill_GetDetailForCancellation
    @ModuleCode  NVARCHAR(20),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ModuleCode = 'LAB'
    BEGIN
        SELECT
            lo.LabOrderId        AS ModuleRefId,
            'LAB'                AS ModuleCode,
            lo.BillNo,
            lo.OrderDate         AS BillDate,
            lo.TotalAmount,
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.EmailId,
            p.Address,
            CASE WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentHeaderId, 0)   AS PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U')   AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)         AS TotalPaid,
            ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, lo.TotalAmount)  AS NetAmount,
            ISNULL(ph.HeaderDiscountAmount, 0)    AS TotalDiscountAmount,
            ISNULL(ph.LineDiscountTotal, 0)       AS LineDiscountTotal,
            ISNULL(ph.RoundOffAmount, 0)          AS RoundOffAmount,
            b.BranchName
        FROM dbo.LabOrder lo
        INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = lo.BranchId
        WHERE lo.LabOrderId = @ModuleRefId;

        SELECT
            loi.LabOrderItemId   AS LineRefId,
            loi.LabOrderId       AS ModuleRefId,
            ISNULL(pkg.Profile_Name, lm.Test_Name) AS ItemName,
            ISNULL(pkg.Profile_Code, lm.Test_Code) AS ItemCode,
            loi.Price            AS OriginalAmount,
            ISNULL(pli.NetLineAmount, loi.Price) AS NetAmount,
            ISNULL(pli.LineDiscountAmount, 0)    AS DiscountAmount,
            loi.IsActive,
            ISNULL(
                (SELECT SUM(bci.CancelledAmount) 
                 FROM dbo.BillCancellationItem bci
                 INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                 WHERE bci.LineRefId = loi.LabOrderItemId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1)
            , 0) AS CancelledAmount,
            CASE WHEN loi.IsActive = 0 THEN 1
                 WHEN EXISTS (SELECT 1 FROM dbo.BillCancellationItem bci
                              INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                              WHERE bci.LineRefId = loi.LabOrderItemId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS IsCancelled,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE lst.Sample_Name END AS SampleTypeName,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE dm.DeptName END AS DepartmentName,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE lc.Category_Name END AS CategoryName
        FROM dbo.LabOrderItem loi
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
        LEFT JOIN dbo.LabInvestigationMaster lm ON lm.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
        LEFT JOIN dbo.LabSampleTypeMaster lst ON lst.Sample_Type_ID = lm.Sample_Type_ID
        LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lm.Department_ID
        LEFT JOIN dbo.LabTestCategoryMaster lc ON lc.Category_ID = lm.Category_ID
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = loi.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId 
            AND (pli.ModuleLineRefId = loi.LabOrderItemId OR pli.ModuleLineRefId = loi.InvestigationId)
            AND pli.IsActive = 1
        WHERE loi.LabOrderId = @ModuleRefId
        ORDER BY loi.LabOrderItemId;

        SELECT
            pd.PaymentDetailId,
            pm.MethodName,
            pm.MethodCode,
            pd.PaidAmount,
            pd.PaymentDate,
            pd.ReceiptNo,
            pd.TransactionRef
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @ModuleRefId AND pd.IsActive = 1;
    END

    IF @ModuleCode = 'OPD'
    BEGIN
        SELECT
            os.OPDServiceId         AS ModuleRefId,
            'OPD'                   AS ModuleCode,
            os.OPDBillNo            AS BillNo,
            os.VisitDate            AS BillDate,
            os.TotalAmount,
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.EmailId,
            p.Address,
            CASE WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentHeaderId, 0)   AS PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U')   AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)         AS TotalPaid,
            ISNULL(ph.BalanceDue, os.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, os.TotalAmount)  AS NetAmount,
            ISNULL(ph.HeaderDiscountAmount, 0)    AS TotalDiscountAmount,
            ISNULL(ph.LineDiscountTotal, 0)       AS LineDiscountTotal,
            ISNULL(ph.RoundOffAmount, 0)          AS RoundOffAmount,
            b.BranchName
        FROM dbo.PatientOPDService os
        INNER JOIN dbo.PatientMaster p ON p.PatientId = os.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = os.OPDServiceId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = os.BranchId
        WHERE os.OPDServiceId = @ModuleRefId;

        SELECT
            si.ItemId             AS LineRefId,
            si.OPDServiceId       AS ModuleRefId,
            ISNULL(sm.ItemName, si.ServiceType) AS ItemName,
            si.ServiceType        AS ItemCode,
            si.ServiceCharges     AS OriginalAmount,
            ISNULL(pli.NetLineAmount, si.ServiceCharges) AS NetAmount,
            ISNULL(pli.LineDiscountAmount, 0)           AS DiscountAmount,
            si.IsActive,
            ISNULL(
                (SELECT SUM(bci.CancelledAmount) 
                 FROM dbo.BillCancellationItem bci
                 INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                 WHERE bci.LineRefId = si.ItemId AND bc.ModuleCode = 'OPD' AND bc.IsActive = 1)
            , 0) AS CancelledAmount,
            CASE WHEN si.IsActive = 0 THEN 1
                 WHEN EXISTS (SELECT 1 FROM dbo.BillCancellationItem bci
                              INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                              WHERE bci.LineRefId = si.ItemId AND bc.ModuleCode = 'OPD' AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS IsCancelled,
            NULL AS SampleTypeName,
            NULL AS DepartmentName,
            NULL AS CategoryName
        FROM dbo.PatientOPDServiceItem si
        LEFT JOIN dbo.ServiceMaster sm    ON sm.ServiceId = si.ServiceId
        LEFT JOIN dbo.PaymentHeader ph     ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = si.OPDServiceId AND ph.IsActive = 1
        LEFT JOIN dbo.PaymentLineItem pli  ON pli.PaymentHeaderId = ph.PaymentHeaderId 
                                           AND pli.ModuleLineRefId = si.ItemId 
                                           AND pli.IsActive = 1
        WHERE si.OPDServiceId = @ModuleRefId
        ORDER BY si.ItemId;

        SELECT
            pd.PaymentDetailId,
            pm.MethodName,
            pm.MethodCode,
            pd.PaidAmount,
            pd.PaymentDate,
            pd.ReceiptNo,
            pd.TransactionRef
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE ph.ModuleCode = 'OPD' AND ph.ModuleRefId = @ModuleRefId AND pd.IsActive = 1;
    END
END;
GO

-- ── usp_CreateLabOrder ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- 2. Update usp_CreateLabOrder to generate B2B token immediately
CREATE OR ALTER PROCEDURE dbo.usp_CreateLabOrder
    @PatientId        INT,
    @BranchId         INT,
    @CreatedBy        INT,
    @TotalAmount      DECIMAL(10,2),
    @Items            dbo.udt_LabOrderItem READONLY,
    @CollectionType   NVARCHAR(50) = 'Lab',
    @PhlebotomistId   INT          = NULL,
    @BookingDate      DATETIME     = NULL,
    @IsB2B            BIT          = 0,
    @B2BAgentID       INT          = NULL,
    @AgentType        VARCHAR(10)  = NULL,
    @B2BTotal         DECIMAL(18,2)= NULL,
    @LabOrderId       INT          OUTPUT,
    @BillNo           NVARCHAR(50) OUTPUT,
    @TokenNo          NVARCHAR(50) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Strict validation: Cannot create lab order without at least one valid test investigation
    IF NOT EXISTS (SELECT 1 FROM @Items WHERE ISNULL(InvestigationId, 0) > 0)
    BEGIN
        RAISERROR('Cannot create a laboratory bill without at least one valid test investigation (InvestigationId > 0).', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM @Items WHERE ISNULL(InvestigationId, 0) <= 0)
    BEGIN
        RAISERROR('One or more test items have an invalid Investigation ID (InvestigationId <= 0). Billing cannot proceed.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Set effective booking date
        DECLARE @EffectiveDate DATETIME = ISNULL(@BookingDate, GETDATE());

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Generate Token immediately for B2B billing
        IF ISNULL(@IsB2B, 0) = 1
        BEGIN
            DECLARE @DateOnly DATE = CAST(@EffectiveDate AS DATE);
            EXEC dbo.usp_B2B_LAB_GetNextTokenNo 
                @BranchId  = @BranchId, 
                @TokenDate = @DateOnly, 
                @TokenNo   = @TokenNo OUTPUT;
        END
        ELSE
        BEGIN
            SET @TokenNo = NULL; -- B2C tokens are assigned upon payment
        END

        -- Check if any item is marked urgent
        DECLARE @HasUrgent BIT = 0;
        IF EXISTS (SELECT 1 FROM @Items WHERE IsUrgent = 1)
            SET @HasUrgent = 1;

        -- Insert Header
        INSERT INTO dbo.LabOrder 
            (PatientId, BranchId, OrderDate, BillNo, TokenNo, TotalAmount, CollectionType, PhlebotomistId, BookingDate, IsUrgent, CreatedBy, CreatedDate, IsActive, IsB2B, B2BAgentID, AgentType, B2BTotal)
        VALUES 
            (@PatientId, @BranchId, @EffectiveDate, @BillNo, @TokenNo, @TotalAmount, ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @EffectiveDate, @HasUrgent, @CreatedBy, GETDATE(), 1, ISNULL(@IsB2B, 0), @B2BAgentID, @AgentType, @B2BTotal);
        
        SET @LabOrderId = SCOPE_IDENTITY();

        -- Insert Items (include Type, IsUrgent, and B2BRate from @Items)
        INSERT INTO dbo.LabOrderItem (LabOrderId, InvestigationId, [Type], Price, IsUrgent, CreatedBy, CreatedDate, IsActive, B2BRate)
        SELECT 
            @LabOrderId, 
            InvestigationId, 
            ISNULL(NULLIF([Type], ''), 'I'), 
            Price, 
            ISNULL(IsUrgent, 0), 
            @CreatedBy, 
            GETDATE(), 
            1,
            B2BRate
        FROM @Items
        WHERE InvestigationId > 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── usp_GetPatientListPaged ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- ============================================================
-- Stored Procedure: usp_GetPatientListPaged
-- Description : Server-side paginated patient list for OPD Index.
--               Returns matched rows + TotalCount via window function.
-- ============================================================
CREATE OR ALTER PROCEDURE [dbo].[usp_GetPatientListPaged]
    @BranchId   INT          = NULL,
    @PageNumber  INT          = 1,
    @PageSize    INT          = 10,
    @SearchTerm  NVARCHAR(100)= NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Normalise inputs
    SET @PageNumber = ISNULL(@PageNumber, 1);
    SET @PageSize   = ISNULL(@PageSize,  10);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   < 1 SET @PageSize   = 10;
    IF @SearchTerm = '' SET @SearchTerm = NULL;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        )) AS FullName,
        p.PhoneNumber,
        p.Gender,
        p.BloodGroup,
        p.DateOfBirth,
        p.CreatedDate,
        p.IsActive,
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS ConsultingDoctorName,
        COUNT(*) OVER() AS TotalCount
    FROM PatientMaster p
    OUTER APPLY (
        SELECT TOP 1 ConsultingDoctorId
        FROM PatientOPDService
        WHERE PatientId = p.PatientId AND IsActive = 1
        ORDER BY OPDServiceId DESC
    ) latest
    LEFT JOIN DoctorMaster d ON d.DoctorId = latest.ConsultingDoctorId
    WHERE p.IsActive = 1
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
      AND (
            @SearchTerm IS NULL
            OR p.PatientCode   LIKE '%' + @SearchTerm + '%'
            OR p.FirstName     LIKE '%' + @SearchTerm + '%'
            OR p.LastName      LIKE '%' + @SearchTerm + '%'
            OR p.PhoneNumber   LIKE '%' + @SearchTerm + '%'
          )
    ORDER BY p.CreatedDate DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- ── usp_GetServiceBookingsPaged ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE [dbo].[usp_GetServiceBookingsPaged]
    @BranchId       INT            = NULL,
    @FromDate       DATE           = NULL,
    @ToDate         DATE           = NULL,
    @PageNumber     INT            = 1,
    @PageSize       INT            = 10,
    @SearchTerm     NVARCHAR(100)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @PageNumber = ISNULL(@PageNumber, 1);
    SET @PageSize   = ISNULL(@PageSize,  10);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   < 1 SET @PageSize   = 10;
    IF @SearchTerm = '' SET @SearchTerm = NULL;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT
        s.OPDServiceId,
        s.VisitDate,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientCode,
        p.PatientId,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        ))                          AS PatientName,
        p.Gender,
        p.DateOfBirth,
        CASE
            WHEN p.DateOfBirth IS NULL THEN NULL
            ELSE DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                 - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
        END                         AS Age,
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS ConsultingDoctorName,
        ISNULL(s.TotalAmount, 0)    AS TotalAmount,
        s.Status,
        ISNULL(
            STUFF((
                SELECT DISTINCT ', ' + ISNULL(si.ServiceType, '')
                FROM PatientOPDServiceItem si
                WHERE si.OPDServiceId = s.OPDServiceId AND si.IsActive = 1
                FOR XML PATH(''), TYPE
            ).value('.','NVARCHAR(MAX)'), 1, 2, ''), ''
        )                           AS ServiceTypesSummary,
        COUNT(*)                    OVER()  AS TotalCount,
        SUM(ISNULL(s.TotalAmount,0)) OVER() AS TotalFeesAll,
        SUM(CASE WHEN s.Status = 'Registered'  THEN 1 ELSE 0 END) OVER() AS RegisteredCount,
        SUM(CASE WHEN s.Status = 'Completed'   THEN 1 ELSE 0 END) OVER() AS CompletedCount
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN DoctorMaster  d ON d.DoctorId  = s.ConsultingDoctorId
    WHERE s.IsActive  = 1
      AND p.IsActive  = 1
      AND (@BranchId  IS NULL OR s.BranchId = @BranchId)
      AND (@FromDate  IS NULL OR CAST(s.VisitDate AS DATE) >= @FromDate)
      AND (@ToDate    IS NULL OR CAST(s.VisitDate AS DATE) <= @ToDate)
      AND (
            @SearchTerm IS NULL
            OR p.PatientCode LIKE '%' + @SearchTerm + '%'
            OR p.FirstName   LIKE '%' + @SearchTerm + '%'
            OR p.LastName    LIKE '%' + @SearchTerm + '%'
            OR p.PhoneNumber LIKE '%' + @SearchTerm + '%'
            OR s.OPDBillNo   LIKE '%' + @SearchTerm + '%'
          )
    ORDER BY s.OPDServiceId DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- ── usp_LAB_AssignTokenOnPayment ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- 3. Update usp_LAB_AssignTokenOnPayment
CREATE OR ALTER PROCEDURE dbo.usp_LAB_AssignTokenOnPayment
    @LabOrderId     INT,
    @TokenNo        NVARCHAR(50)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchId        INT;
    DECLARE @AppointmentDate DATE;
    DECLARE @ExistingToken   NVARCHAR(50);
    DECLARE @IsB2B           BIT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT  @BranchId        = BranchId,
                @AppointmentDate = CAST(ISNULL(BookingDate, OrderDate) AS DATE),
                @ExistingToken   = TokenNo,
                @IsB2B           = ISNULL(IsB2B, 0)
        FROM    dbo.LabOrder WITH (UPDLOCK, ROWLOCK)
        WHERE   LabOrderId = @LabOrderId;

        IF @ExistingToken IS NOT NULL
        BEGIN
            SET @TokenNo = @ExistingToken;

            -- Sync SampleCollection TokenNo
            UPDATE dbo.SampleCollection
            SET TokenNo = @ExistingToken
            WHERE Laborderid = @LabOrderId AND (TokenNo IS NULL OR TokenNo <> @ExistingToken);

            COMMIT TRANSACTION;
            RETURN;
        END

        -- Generate new token
        IF @IsB2B = 1
        BEGIN
            EXEC dbo.usp_B2B_LAB_GetNextTokenNo @BranchId, @AppointmentDate, @TokenNo OUTPUT;
        END
        ELSE
        BEGIN
            EXEC dbo.usp_LAB_GetNextTokenNo @BranchId, @AppointmentDate, @TokenNo OUTPUT;
        END

        UPDATE dbo.LabOrder
        SET    TokenNo = @TokenNo
        WHERE  LabOrderId = @LabOrderId;

        -- Sync SampleCollection TokenNo
        UPDATE dbo.SampleCollection
        SET TokenNo = @TokenNo
        WHERE Laborderid = @LabOrderId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

-- ── usp_Lab_GetNextBarcodeNo ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- ── 3. Stored Procedure: usp_Lab_GetNextBarcodeNo ──────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Lab_GetNextBarcodeNo
    @BranchId    INT,
    @BarcodeNo   NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @BranchId IS NULL OR @BranchId <= 0
        SET @BranchId = 1;

    DECLARE @CompanyId  INT = 1;
    DECLARE @BranchCode NVARCHAR(20) = 'HO';

    SELECT TOP 1 
        @BranchCode = ISNULL(NULLIF(RTRIM(LTRIM(BranchCode)), ''), 'HO'),
        @CompanyId  = ISNULL(CompanyId, 1)
    FROM dbo.Branchmaster 
    WHERE BranchId = @BranchId;

    -- Fetch config (branch override first, else global fallback where BranchId IS NULL)
    DECLARE @PrefixFormat NVARCHAR(50) = '<BranchCode><FY2>';
    DECLARE @DigitCount   INT = 6;
    DECLARE @ConfigFY     NVARCHAR(10) = NULL;

    SELECT TOP 1
        @PrefixFormat = ISNULL(PrefixFormat, '<BranchCode><FY2>'),
        @DigitCount   = ISNULL(DigitCount, 6),
        @ConfigFY     = NULLIF(RTRIM(LTRIM(CurrentFinancialYear)), '')
    FROM dbo.LabBarcodeConfig
    WHERE (BranchId = @BranchId OR BranchId IS NULL)
      AND IsActive = 1
    ORDER BY CASE WHEN BranchId = @BranchId THEN 0 ELSE 1 END;

    -- Determine 2-digit Financial Year (e.g. '26')
    DECLARE @FY2 NVARCHAR(10);
    IF @ConfigFY IS NOT NULL
    BEGIN
        SET @FY2 = @ConfigFY;
    END
    ELSE
    BEGIN
        DECLARE @Today   DATE = CAST(GETDATE() AS DATE);
        DECLARE @CalYear INT  = YEAR(@Today);
        DECLARE @Month   INT  = MONTH(@Today);
        -- Indian FY starts in April (Month >= 4):
        -- e.g. Sep 2026: FY 2026-2027 => start year is 2026 => '26'
        -- e.g. Feb 2026: FY 2025-2026 (2526) => user requirement: 'If 2526 then only show 26' => '26'
        DECLARE @FYStart INT = CASE WHEN @Month >= 4 THEN @CalYear ELSE @CalYear - 1 END;
        SET @FY2 = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2);
    END

    -- Atomically increment sequence for (BranchId, FinancialYear)
    DECLARE @NewSeq BIGINT = 0;

    UPDATE dbo.LabBarcodeSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND FinancialYear = @FY2;

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.LabBarcodeSequence (BranchId, FinancialYear, LastSeq, CompanyId)
            VALUES (@BranchId, @FY2, 1, @CompanyId);
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
            BEGIN
                UPDATE dbo.LabBarcodeSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND FinancialYear = @FY2;
            END
            ELSE THROW;
        END CATCH
    END

    -- Format sequence number with padded digits
    DECLARE @SeqStr NVARCHAR(20) = RIGHT(REPLICATE('0', @DigitCount) + CAST(@NewSeq AS NVARCHAR(20)), @DigitCount);

    -- Format Prefix: replace <BranchCode> and <FY2> tokens
    DECLARE @Prefix NVARCHAR(50) = @PrefixFormat;
    SET @Prefix = REPLACE(@Prefix, '<BranchCode>', @BranchCode);
    SET @Prefix = REPLACE(@Prefix, '<FY2>', @FY2);
    SET @Prefix = REPLACE(@Prefix, '<FY>', @FY2);

    SET @BarcodeNo = @Prefix + @SeqStr;
END
GO

-- ── usp_LabOrder_GetDetail ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetDetail
(
    @LabOrderId INT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    -- RS1: Order Header & Patient Info
    SELECT 
        o.LabOrderId,
        o.PatientId,
        o.BranchId,
        b.BranchName,
        o.OrderDate,
        o.BillNo,
        o.TokenNo,
        o.TotalAmount,
        o.CollectionType,
        o.PhlebotomistId,
        o.IsUrgent,
        phleb.FullName AS PhlebotomistName,
        o.BookingDate,
        o.IsActive,
        o.CreatedDate,
        u.FullName AS CreatedByName,
        o.IsB2B,
        o.B2BAgentID,
        o.AgentType,
        o.B2BTotal,
        CASE 
            WHEN o.AgentType = 'F' THEN f.Franchise_Name
            WHEN o.AgentType = 'C' THEN corp.Corporate_Name
            ELSE NULL
        END AS AgentName,
        CASE 
            WHEN o.AgentType = 'F' THEN f.Franchise_Code
            WHEN o.AgentType = 'C' THEN corp.Corporate_Code
            ELSE NULL
        END AS AgentCode,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        p.EmailId,
        p.Gender,
        p.DateOfBirth,
        DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
            CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END AS Age,
        p.Address,
        ph.PaymentHeaderId,
        CASE 
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 'P'
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'R'
            WHEN o.IsB2B = 1 THEN 'U'
            ELSE ISNULL(ph.PaymentStatus, 'U')
        END AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0)       AS TotalPaid,
        CASE 
            WHEN o.IsB2B = 1 THEN 
                CASE WHEN ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) < 0 THEN 0.00 
                     ELSE ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) END
            ELSE ISNULL(ph.BalanceDue, o.TotalAmount)
        END AS BalanceDue,
        ISNULL(ph.NetAmount, o.TotalAmount)  AS NetAmount,
        ISNULL(ph.HeaderDiscountAmount, 0)   AS DiscountAmount,
        ISNULL(ph.RoundOffAmount, 0)         AS RoundOffAmount
    FROM dbo.LabOrder o
    INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
    LEFT JOIN dbo.BranchMaster b ON b.BranchID = o.BranchId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
    LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = o.B2BAgentID AND o.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
    WHERE o.LabOrderId = @LabOrderId;

    -- RS2: Line Items
    SELECT 
        loi.LabOrderItemId,
        loi.LabOrderId,
        loi.InvestigationId,
        ISNULL(loi.Type, 'I') AS Type,
        CASE WHEN loi.Type = 'P' THEN pkg.Profile_Code ELSE lim.Test_Code END AS TestCode,
        CASE WHEN loi.Type = 'P' THEN pkg.Profile_Name ELSE lim.Test_Name END AS TestName,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE stm.Sample_Name END AS SampleType,
        CASE WHEN loi.Type = 'P' THEN CAST(ISNULL(pkg.Profile_TAT_Hours, 24) AS NVARCHAR(50)) ELSE CAST(lim.TAT_Hours AS NVARCHAR(50)) END AS TATHours,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE dm.DeptName END AS DepartmentName,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE cm.Category_Name END AS CategoryName,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE scm.SubCategory_Name END AS SubCategoryName,
        loi.Price,
        loi.B2BRate,
        loi.IsUrgent,
        ISNULL(pli.LineDiscountAmount, 0) AS DiscountAmount,
        ISNULL(pli.NetLineAmount, loi.Price) AS NetAmount,
        loi.IsActive
    FROM dbo.LabOrderItem loi
    LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    LEFT JOIN dbo.LabTestCategoryMaster cm ON cm.Category_ID = lim.Category_ID
    LEFT JOIN dbo.LabTestSubCategoryMaster scm ON scm.SubCategory_ID = lim.SubCategory_ID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = loi.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId 
        AND (pli.ModuleLineRefId = loi.LabOrderItemId OR pli.ModuleLineRefId = loi.InvestigationId)
        AND pli.IsActive = 1
    WHERE loi.LabOrderId = @LabOrderId
    ORDER BY loi.LabOrderItemId;

    -- RS3: Payments Recorded
    SELECT 
        pd.PaymentDetailId,
        pm.MethodName,
        pm.MethodCode,
        pd.PaidAmount,
        pd.PaymentDate,
        pd.ReceiptNo,
        pd.TransactionRef,
        pd.ChequeNo,
        pd.BankName,
        pd.UPIRefNo,
        pd.CardLast4,
        pd.Notes
    FROM dbo.PaymentHeader ph
    INNER JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @LabOrderId AND ph.IsActive = 1;
END;
GO

-- ── usp_LabOrder_GetPagedList ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetPagedList
    @BranchId INT,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @Search NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10,
    @IsB2B BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL SET @FromDate = CAST(GETDATE() AS DATE);
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize < 1 SET @PageSize = 10;

    -- Stats
    SELECT 
        COUNT(1) AS TotalOrders,
        ISNULL(SUM(o.TotalAmount), 0.00) AS TotalAmount,
        ISNULL(SUM(CASE 
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 1 
            WHEN ISNULL(o.IsB2B, 0) = 0 AND ph.PaymentStatus = 'P' THEN 1 
            ELSE 0 
        END), 0) AS PaidCount,
        ISNULL(SUM(CASE 
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) < ISNULL(o.B2BTotal, o.TotalAmount) THEN 1 
            WHEN ISNULL(o.IsB2B, 0) = 0 AND ISNULL(ph.PaymentStatus, 'U') <> 'P' THEN 1 
            ELSE 0 
        END), 0) AS UnpaidCount,
        ISNULL(SUM(CASE WHEN o.IsB2B = 1 THEN ISNULL(o.B2BTotal, 0.00) ELSE 0.00 END), 0.00) AS B2BTotalAmount
    FROM dbo.LabOrder o
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
      AND (@IsB2B IS NULL OR (@IsB2B = 1 AND o.IsB2B = 1) OR (@IsB2B = 0 AND ISNULL(o.IsB2B, 0) = 0))
      AND (
          @Search IS NULL 
          OR o.BillNo LIKE '%' + @Search + '%' 
          OR o.TokenNo LIKE '%' + @Search + '%'
          OR EXISTS (
              SELECT 1 FROM dbo.PatientMaster p 
              WHERE p.PatientId = o.PatientId 
                AND (p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%' OR p.PatientCode LIKE '%' + @Search + '%')
          )
      );

    -- Paged Items
    WITH PagedOrders AS (
        SELECT 
            o.LabOrderId,
            o.PatientId,
            o.BranchId,
            o.OrderDate,
            o.BillNo,
            o.TokenNo,
            o.TotalAmount,
            o.CollectionType,
            o.PhlebotomistId,
            o.IsUrgent,
            phleb.FullName AS PhlebotomistName,
            o.BookingDate,
            o.IsActive,
            o.CreatedDate,
            o.CreatedBy,
            o.IsB2B,
            o.B2BAgentID,
            o.AgentType,
            o.B2BTotal,
            CASE 
                WHEN o.AgentType = 'F' THEN f.Franchise_Name
                WHEN o.AgentType = 'C' THEN corp.Corporate_Name
                ELSE NULL
            END AS AgentName,
            CASE 
                WHEN o.AgentType = 'F' THEN f.Franchise_Code
                WHEN o.AgentType = 'C' THEN corp.Corporate_Code
                ELSE NULL
            END AS AgentCode,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.MiddleName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            CASE 
                WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                ELSE NULL 
            END AS Age,
            ph.PaymentHeaderId,
            CASE 
                WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 'P'
                WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'R'
                WHEN o.IsB2B = 1 THEN 'U'
                ELSE ISNULL(ph.PaymentStatus, 'U')
            END AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
            CASE 
                WHEN o.IsB2B = 1 THEN 
                    CASE WHEN ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) < 0 THEN 0.00 
                         ELSE ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) END
                ELSE ISNULL(ph.BalanceDue, o.TotalAmount)
            END AS BalanceDue,
            u.FullName AS CreatedByName,
            (
                SELECT COUNT(1) 
                FROM dbo.LabOrderItem loi 
                WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
            ) AS ItemCount,
            (
                SELECT STRING_AGG(
                    CASE 
                        WHEN loi.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Package #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                        ELSE ISNULL(lim.Test_Name, 'Test #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                    END, ', ')
                FROM dbo.LabOrderItem loi
                LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND (loi.Type = 'I' OR loi.Type IS NULL)
                LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
            ) AS TestNamesSummary,
            ROW_NUMBER() OVER (ORDER BY o.LabOrderId DESC) AS RowNum,
            COUNT(1) OVER() AS TotalCount
        FROM dbo.LabOrder o
        INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
        LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
        LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = o.B2BAgentID AND o.AgentType = 'F'
        LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
        WHERE o.BranchId = @BranchId
          AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
          AND (@IsB2B IS NULL OR (@IsB2B = 1 AND o.IsB2B = 1) OR (@IsB2B = 0 AND ISNULL(o.IsB2B, 0) = 0))
          AND (
              @Search IS NULL 
              OR o.BillNo LIKE '%' + @Search + '%' 
              OR o.TokenNo LIKE '%' + @Search + '%'
              OR p.FirstName LIKE '%' + @Search + '%'
              OR p.LastName LIKE '%' + @Search + '%'
              OR p.PhoneNumber LIKE '%' + @Search + '%'
              OR p.PatientCode LIKE '%' + @Search + '%'
              OR (o.AgentType = 'F' AND (f.Franchise_Name LIKE '%' + @Search + '%' OR f.Franchise_Code LIKE '%' + @Search + '%'))
              OR (o.AgentType = 'C' AND (corp.Corporate_Name LIKE '%' + @Search + '%' OR corp.Corporate_Code LIKE '%' + @Search + '%'))
          )
    )
    SELECT * FROM PagedOrders
    WHERE RowNum BETWEEN ((@PageNumber - 1) * @PageSize + 1) AND (@PageNumber * @PageSize)
    ORDER BY RowNum;
END;
GO

-- ── usp_OPD_AssignTokenOnPayment ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- ── 2. Create usp_OPD_AssignTokenOnPayment ────────────────────────────────────

CREATE OR ALTER PROCEDURE dbo.usp_OPD_AssignTokenOnPayment
    @OPDServiceId   INT,
    @TokenNo        NVARCHAR(20)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchId        INT;
    DECLARE @AppointmentDate DATE;
    DECLARE @ExistingToken   NVARCHAR(20);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT  @BranchId        = BranchId,
                @AppointmentDate = CAST(VisitDate AS DATE),
                @ExistingToken   = TokenNo
        FROM    dbo.PatientOPDService WITH (UPDLOCK, ROWLOCK)
        WHERE   OPDServiceId = @OPDServiceId;

        IF @ExistingToken IS NOT NULL
        BEGIN
            SET @TokenNo = @ExistingToken;
            COMMIT TRANSACTION;
            RETURN;
        END

        EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @AppointmentDate, @TokenNo OUTPUT;

        UPDATE dbo.PatientOPDService
        SET    TokenNo = @TokenNo
        WHERE  OPDServiceId = @OPDServiceId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO

-- ── usp_Patient_Create ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- Update usp_Patient_Create
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Create
(
    @PhoneNumber            NVARCHAR(20),
    @SecondaryPhoneNumber   NVARCHAR(20)    = NULL,
    @Salutation             NVARCHAR(10)    = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)   = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @DateOfBirth            DATE            = NULL,
    @ReligionId             INT             = NULL,
    @EmailId                NVARCHAR(200)   = NULL,
    @GuardianName           NVARCHAR(200)   = NULL,
    @CountryId              INT             = NULL,
    @StateId                INT             = NULL,
    @DistrictId             INT             = NULL,
    @CityId                 INT             = NULL,
    @AreaId                 INT             = NULL,
    @Address                NVARCHAR(500)   = NULL,
    @HomeCollectionAddress  NVARCHAR(500)   = NULL,
    @Latitude               DECIMAL(10, 8)  = NULL,
    @Longitude              DECIMAL(11, 8)  = NULL,
    @RelationId             INT             = NULL,
    @IdentificationTypeId   INT             = NULL,
    @IdentificationNumber   NVARCHAR(100)   = NULL,
    @IdentificationFilePath NVARCHAR(500)   = NULL,
    @PhotoPath              NVARCHAR(500)   = NULL,
    @OccupationId           INT             = NULL,
    @MaritalStatusId        INT             = NULL,
    @BloodGroup             NVARCHAR(10)    = NULL,
    @KnownAllergies         NVARCHAR(500)   = NULL,
    @Remarks                NVARCHAR(500)   = NULL,
    @LanguageId             INT             = NULL,
    @BranchId               INT             = NULL,
    @UserId                 INT             = NULL,
    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,
    @ScheduleId             INT             = NULL,
    @AppointmentDate        DATE            = NULL,
    @AppointmentTime        TIME            = NULL,
    @PatientCode            NVARCHAR(50)    OUTPUT,
    @OPDBillNo              NVARCHAR(50)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT,
    @NewPatientId           INT             OUTPUT,
    @NewOPDServiceId        INT             OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RelName NVARCHAR(100);
    DECLARE @Now DATETIME2;
    DECLARE @TotalAmount DECIMAL(10,2);
    DECLARE @TokenDate DATE;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @RelationId IS NOT NULL AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE PhoneNumber = @PhoneNumber AND RelationId = @RelationId AND IsActive = 1
        )
        BEGIN
            SELECT @RelName = RelationName FROM dbo.RelationMaster WHERE RelationId = @RelationId;
            RAISERROR(N'A patient with relation "%s" is already registered for phone number %s.', 16, 1, @RelName, @PhoneNumber);
        END

        SET @Now = SYSUTCDATETIME();
        EXEC dbo.usp_Patient_GetNextCode @BranchId, @PatientCode OUTPUT;
        EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;
        SET @TokenNo = NULL;

        IF (@Address IS NULL OR LTRIM(RTRIM(@Address)) = '') AND (@HomeCollectionAddress IS NOT NULL AND LTRIM(RTRIM(@HomeCollectionAddress)) <> '')
            SET @Address = @HomeCollectionAddress;

        INSERT INTO dbo.PatientMaster
        (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, DateOfBirth, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId, Address,
            HomeCollectionAddress, Latitude, Longitude, RelationId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath, PhotoPath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            LanguageId, BranchId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId, @Address,
            @HomeCollectionAddress, @Latitude, @Longitude, @RelationId,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath, @PhotoPath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @LanguageId, @BranchId, 1, @UserId, @Now
        );
        SET @NewPatientId = SCOPE_IDENTITY();

        SET @TotalAmount = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        IF @TotalAmount = 0
        BEGIN
            SET @TokenDate = ISNULL(@AppointmentDate, CAST(GETDATE() AS DATE));
            EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenDate, @TokenNo OUTPUT;
        END

        INSERT INTO dbo.PatientOPDService (
            PatientId, BranchId, ConsultingDoctorId, OPDBillNo, TokenNo, TotalAmount,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate, ScheduleId, AppointmentTime
        ) VALUES (
            @NewPatientId, @BranchId, @ConsultingDoctorId, @OPDBillNo, @TokenNo, @TotalAmount,
            ISNULL(@AppointmentDate, GETDATE()), 'Registered', 1, @UserId, GETDATE(),
            @ScheduleId, @AppointmentTime
        );
        SET @NewOPDServiceId = SCOPE_IDENTITY();

        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem
                (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT @NewOPDServiceId,
                JSON_VALUE(j.value,'$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value,'$.serviceId') AS INT),
                TRY_CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2)),
                1, @UserId, GETDATE()
            FROM OPENJSON(@LineItemsJson) j;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO

-- ── usp_PatientMaster_Insert ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE [dbo].[usp_PatientMaster_Insert]
(
    @PhoneNumber            NVARCHAR(20),
    @SecondaryPhoneNumber   NVARCHAR(20)    = NULL,
    @Salutation             NVARCHAR(10)    = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)   = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @DateOfBirth            DATE            = NULL,
    @ReligionId             INT             = NULL,
    @EmailId                NVARCHAR(200)   = NULL,
    @GuardianName           NVARCHAR(200)   = NULL,
    @CountryId              INT             = NULL,
    @StateId                INT             = NULL,
    @DistrictId             INT             = NULL,
    @CityId                 INT             = NULL,
    @AreaId                 INT             = NULL,
    @Address                NVARCHAR(500)   = NULL,
    @HomeCollectionAddress  NVARCHAR(500)   = NULL,
    @Latitude               DECIMAL(10, 8)  = NULL,
    @Longitude              DECIMAL(11, 8)  = NULL,
    @RelationId             INT             = NULL,
    @IdentificationTypeId   INT             = NULL,
    @IdentificationNumber   NVARCHAR(100)   = NULL,
    @IdentificationFilePath NVARCHAR(500)   = NULL,
    @PhotoPath              NVARCHAR(500)   = NULL,
    @OccupationId           INT             = NULL,
    @MaritalStatusId        INT             = NULL,
    @BloodGroup             NVARCHAR(10)    = NULL,
    @KnownAllergies         NVARCHAR(500)   = NULL,
    @Remarks                NVARCHAR(500)   = NULL,
    @LanguageId             INT             = NULL,
    @BranchId               INT             = NULL,
    @CompanyId              INT             = NULL,
    @CreatedBy              INT             = NULL,
    @PatientCode            NVARCHAR(50)    OUTPUT,
    @NewPatientId           INT             OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RelName NVARCHAR(100);
    DECLARE @Now DATETIME2 = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @RelationId IS NOT NULL AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE PhoneNumber = @PhoneNumber AND RelationId = @RelationId AND IsActive = 1
        )
        BEGIN
            SELECT @RelName = RelationName FROM dbo.RelationMaster WHERE RelationId = @RelationId;
            RAISERROR(N'A patient with relation "%s" is already registered for phone number %s.', 16, 1, @RelName, @PhoneNumber);
        END

        EXEC dbo.usp_Patient_GetNextCode @BranchId, @PatientCode OUTPUT;

        INSERT INTO dbo.PatientMaster
        (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, DateOfBirth, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId, Address,
            HomeCollectionAddress, Latitude, Longitude, RelationId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath, PhotoPath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            LanguageId, BranchId, CompanyId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId, @Address,
            @HomeCollectionAddress, @Latitude, @Longitude, @RelationId,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath, @PhotoPath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @LanguageId, @BranchId, ISNULL(@CompanyId, 1), 1, @CreatedBy, @Now
        );
        SET @NewPatientId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrSt  INT = ERROR_STATE();
        RAISERROR(@ErrMsg, @ErrSev, @ErrSt);
    END CATCH
END
GO

-- ── usp_PatientVital_GetByPatient ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_PatientVital_GetByPatient
    @PatientId INT,
    @CompanyId INT = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        v.PatientVitalId,
        v.CompanyId,
        v.PatientId,
        v.Height,
        v.Weight,
        v.BMI,
        v.BMICategory,
        v.BPSystolic,
        v.BPDiastolic,
        v.PulseRate,
        v.SpO2,
        v.Temperature,
        v.RespiratoryRate,
        v.BloodGlucose,
        v.GlucoseType,
        v.PainScore,
        v.Notes,
        v.RecordedOn,
        v.RecordedByUserId,
        u.FullName AS RecordedByUsername,
        v.IsActive,
        v.CreatedOn,
        COUNT(*) OVER() AS TotalCount,
        -- Edit/Delete allowed for 2 minutes after recording (DB-server clock)
        CAST(CASE WHEN DATEDIFF(MINUTE, v.RecordedOn, GETDATE()) <= 2
                  THEN 1 ELSE 0 END AS BIT) AS CanModify
    FROM PatientVitals v
    LEFT JOIN Users u ON u.Id = v.RecordedByUserId
    WHERE v.PatientId = @PatientId
      AND (@CompanyId IS NULL OR v.CompanyId = @CompanyId)
      AND v.IsActive = 1
    ORDER BY v.RecordedOn DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- ── usp_SampleCollection_AutoCollectIfNoMandatory ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_AutoCollectIfNoMandatory
    @LabOrderId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        SELECT 0 AS RowsUpdated;
        RETURN;
    END

    DECLARE @BranchId INT;
    DECLARE @BookingDate DATE;
    DECLARE @BookingTime TIME(0);

    SELECT TOP 1 
        @BranchId    = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDate = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS DATE),
        @BookingTime = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS TIME(0))
    FROM dbo.LabOrder lo
    LEFT JOIN dbo.SampleCollection sc ON sc.Laborderid = lo.LabOrderId
    WHERE lo.LabOrderId = @LabOrderId;

    IF @BranchId IS NULL
    BEGIN
        SELECT 0 AS RowsUpdated;
        RETURN;
    END

    -- Check HospitalSettings for this branch
    DECLARE @IsMandatory BIT = 1;
    SELECT TOP 1 @IsMandatory = ISNULL(IsSampleCollectionMandatory, 1)
    FROM dbo.HospitalSettings
    WHERE BranchID = @BranchId AND IsActive = 1;

    -- If Sample Collection IS Mandatory (1 / YES), do nothing!
    IF @IsMandatory = 1
    BEGIN
        SELECT 0 AS RowsUpdated;
        RETURN;
    END

    -- If NOT Mandatory (0 / NO), auto-collect all samples!
    -- Collection date & time MUST be same as Booking date & time
    IF @BookingDate IS NULL
        SET @BookingDate = CAST(GETDATE() AS DATE);
    IF @BookingTime IS NULL
        SET @BookingTime = CAST(GETDATE() AS TIME(0));

    -- 1. Process Profiles: Each profile shares a single barcode
    DECLARE @CurProfileId INT, @CurProfileName NVARCHAR(200);
    DECLARE prof_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT sc.ProfileId, sc.ProfileName
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL)
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID = 1);

    OPEN prof_cur;
    FETCH NEXT FROM prof_cur INTO @CurProfileId, @CurProfileName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @ProfBarcode NVARCHAR(50) = NULL;
        SELECT TOP 1 @ProfBarcode = sc.BarcodeNo
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@CurProfileId IS NOT NULL AND sc.ProfileId = @CurProfileId)
              OR (@CurProfileId IS NULL AND @CurProfileName IS NOT NULL AND sc.ProfileName = @CurProfileName)
          )
          AND sc.BarcodeNo IS NOT NULL;

        IF @ProfBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ProfBarcode OUTPUT;
        END

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @BookingDate,
            Samplecollectiontime = @BookingTime,
            BarcodeNo            = ISNULL(sc.BarcodeNo, @ProfBarcode),
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (
              (@CurProfileId IS NOT NULL AND sc.ProfileId = @CurProfileId)
              OR (@CurProfileId IS NULL AND @CurProfileName IS NOT NULL AND sc.ProfileName = @CurProfileName)
          )
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID = 1);

        FETCH NEXT FROM prof_cur INTO @CurProfileId, @CurProfileName;
    END
    CLOSE prof_cur;
    DEALLOCATE prof_cur;

    -- 2. Process Standalone Investigations: Each gets its own unique sequential barcode
    DECLARE @CurSampleCollectionId BIGINT;
    DECLARE item_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT sc.samplecollectionID
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND sc.ProfileId IS NULL AND sc.ProfileName IS NULL
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID = 1);

    OPEN item_cur;
    FETCH NEXT FROM item_cur INTO @CurSampleCollectionId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @ItemBarcode NVARCHAR(50) = NULL;
        SELECT @ItemBarcode = BarcodeNo FROM dbo.SampleCollection WHERE samplecollectionID = @CurSampleCollectionId;

        IF @ItemBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ItemBarcode OUTPUT;
        END

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @BookingDate,
            Samplecollectiontime = @BookingTime,
            BarcodeNo            = @ItemBarcode,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @CurSampleCollectionId;

        FETCH NEXT FROM item_cur INTO @CurSampleCollectionId;
    END
    CLOSE item_cur;
    DEALLOCATE item_cur;

    -- Return number of collected items
    SELECT COUNT(*) AS RowsUpdated
    FROM dbo.SampleCollection
    WHERE Laborderid = @LabOrderId AND CollectionstatusID = 2;
END
GO

-- ── usp_SampleCollection_CollectAll ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- ── 3. Update usp_SampleCollection_CollectAll ─────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_CollectAll
    @LabOrderId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    DECLARE @CurrentDate DATE    = CAST(GETDATE() AS DATE);
    DECLARE @CurrentTime TIME(0) = CAST(GETDATE() AS TIME(0));

    DECLARE @BranchId    INT = 1;
    DECLARE @BookingDate DATE;

    SELECT TOP 1 
        @BranchId    = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDate = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS DATE)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.Laborderid = @LabOrderId;

    -- Validation: Sample Collection only possible if Booking Date equals Current Date
    IF @BookingDate IS NOT NULL AND @BookingDate <> @CurrentDate
    BEGIN
        DECLARE @BDateStr3 VARCHAR(10) = CONVERT(VARCHAR(10), @BookingDate, 120);
        RAISERROR('Sample collection is only permitted on the booking date (%s).', 16, 1, @BDateStr3);
        RETURN;
    END

    -- 1. Process Profiles: Each profile shares a single barcode
    DECLARE @CurProfileId INT, @CurProfileName NVARCHAR(200);
    DECLARE prof_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT sc.ProfileId, sc.ProfileName
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL)
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID IN (1, 3));

    OPEN prof_cur;
    FETCH NEXT FROM prof_cur INTO @CurProfileId, @CurProfileName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @ProfBarcode NVARCHAR(50) = NULL;
        SELECT TOP 1 @ProfBarcode = sc.BarcodeNo
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@CurProfileId IS NOT NULL AND sc.ProfileId = @CurProfileId)
              OR (@CurProfileId IS NULL AND @CurProfileName IS NOT NULL AND sc.ProfileName = @CurProfileName)
          )
          AND sc.BarcodeNo IS NOT NULL;

        IF @ProfBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ProfBarcode OUTPUT;
        END

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = ISNULL(sc.Samplecollectiondate, @CurrentDate),
            Samplecollectiontime = ISNULL(sc.Samplecollectiontime, @CurrentTime),
            BarcodeNo            = ISNULL(sc.BarcodeNo, @ProfBarcode),
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (
              (@CurProfileId IS NOT NULL AND sc.ProfileId = @CurProfileId)
              OR (@CurProfileId IS NULL AND @CurProfileName IS NOT NULL AND sc.ProfileName = @CurProfileName)
          )
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID IN (1, 3));

        FETCH NEXT FROM prof_cur INTO @CurProfileId, @CurProfileName;
    END
    CLOSE prof_cur;
    DEALLOCATE prof_cur;

    -- 2. Process Standalone Investigations: Each gets its own unique sequential barcode
    DECLARE @CurSampleCollectionId BIGINT;
    DECLARE item_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT sc.samplecollectionID
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND sc.ProfileId IS NULL AND sc.ProfileName IS NULL
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID IN (1, 3));

    OPEN item_cur;
    FETCH NEXT FROM item_cur INTO @CurSampleCollectionId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @ItemBarcode NVARCHAR(50) = NULL;
        SELECT @ItemBarcode = BarcodeNo FROM dbo.SampleCollection WHERE samplecollectionID = @CurSampleCollectionId;

        IF @ItemBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ItemBarcode OUTPUT;
        END

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = ISNULL(sc.Samplecollectiondate, @CurrentDate),
            Samplecollectiontime = ISNULL(sc.Samplecollectiontime, @CurrentTime),
            BarcodeNo            = @ItemBarcode,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @CurSampleCollectionId;

        FETCH NEXT FROM item_cur INTO @CurSampleCollectionId;
    END
    CLOSE item_cur;
    DEALLOCATE item_cur;

    -- Return count of collected items for this order
    SELECT COUNT(*) AS RowsUpdated
    FROM dbo.SampleCollection
    WHERE Laborderid = @LabOrderId AND CollectionstatusID = 2;
END
GO

-- ── usp_SampleCollection_UpdateProfileStatus ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- ── 2. Update usp_SampleCollection_UpdateProfileStatus ─────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateProfileStatus
    @LabOrderId          INT,
    @ProfileId           INT = NULL,
    @ProfileName         NVARCHAR(200) = NULL,
    @CollectionstatusID  INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId              INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    IF @CollectionstatusID IS NULL OR @CollectionstatusID <= 0
    BEGIN
        RAISERROR('Valid CollectionstatusID is required.', 16, 1);
        RETURN;
    END

    DECLARE @BranchId    INT = 1;
    DECLARE @BookingDate DATE;

    SELECT TOP 1 
        @BranchId    = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDate = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS DATE)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.Laborderid = @LabOrderId;

    -- Validation: Sample Collection only possible if Booking Date equals Current Date
    IF @CollectionstatusID = 2 AND @BookingDate IS NOT NULL AND @BookingDate <> CAST(GETDATE() AS DATE)
    BEGIN
        DECLARE @BDateStr2 VARCHAR(10) = CONVERT(VARCHAR(10), @BookingDate, 120);
        RAISERROR('Sample collection is only permitted on the booking date (%s).', 16, 1, @BDateStr2);
        RETURN;
    END

    -- If Collected (2)
    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        -- 1. Check if any test in this profile already has a barcode generated
        DECLARE @ExistingBarcode NVARCHAR(50);
        SELECT TOP 1 @ExistingBarcode = sc.BarcodeNo
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          )
          AND sc.BarcodeNo IS NOT NULL;

        -- 2. If none, generate a single barcode for the entire profile
        IF @ExistingBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ExistingBarcode OUTPUT;
        END

        -- 3. Update all tests in this profile
        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            BarcodeNo            = ISNULL(sc.BarcodeNo, @ExistingBarcode),
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END
    ELSE IF @CollectionstatusID = 1 -- Revert to Pending: clear collection date, time, and BarcodeNo
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = 1,
            Samplecollectiondate = NULL,
            Samplecollectiontime = NULL,
            BarcodeNo            = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END
    ELSE -- Other statuses (Re Collect = 3, Rejected = 4)
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = @CollectionstatusID,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END

    SELECT @@ROWCOUNT AS RowsUpdated;
END
GO

-- ── usp_SampleCollection_UpdateStatus ─────────────────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- ── 1. Update usp_SampleCollection_UpdateStatus ───────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateStatus
    @SampleCollectionId   BIGINT,
    @CollectionstatusID   INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId               INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LabOrderId       INT;
    DECLARE @ProfileId        INT;
    DECLARE @ProfileName      NVARCHAR(200);
    DECLARE @BranchId         INT = 1;
    DECLARE @BookingDate      DATE;
    DECLARE @GeneratedBarcode NVARCHAR(50);

    SELECT 
        @LabOrderId   = sc.Laborderid,
        @ProfileId    = sc.ProfileId,
        @ProfileName  = sc.ProfileName,
        @BranchId     = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDate  = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS DATE)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.samplecollectionID = @SampleCollectionId;

    IF @LabOrderId IS NULL
    BEGIN
        RAISERROR('SampleCollection record with ID %I64d does not exist.', 16, 1, @SampleCollectionId);
        RETURN;
    END

    -- Validation: Sample Collection only possible if Booking Date equals Current Date
    IF @CollectionstatusID = 2 AND @BookingDate IS NOT NULL AND @BookingDate <> CAST(GETDATE() AS DATE)
    BEGIN
        DECLARE @BDateStr1 VARCHAR(10) = CONVERT(VARCHAR(10), @BookingDate, 120);
        RAISERROR('Sample collection is only permitted on the booking date (%s).', 16, 1, @BDateStr1);
        RETURN;
    END

    -- If Collected (StatusID = 2)
    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        -- Profile-wise: Check if any sibling test in the same profile already has a barcode
        IF @ProfileId IS NOT NULL OR @ProfileName IS NOT NULL
        BEGIN
            SELECT TOP 1 @GeneratedBarcode = BarcodeNo 
            FROM dbo.SampleCollection 
            WHERE Laborderid = @LabOrderId 
              AND (
                  (@ProfileId IS NOT NULL AND ProfileId = @ProfileId)
                  OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND ProfileName = @ProfileName)
              )
              AND BarcodeNo IS NOT NULL;

            IF @GeneratedBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GeneratedBarcode OUTPUT;
            END

            UPDATE sc
            SET 
                CollectionstatusID   = 2,
                Samplecollectiondate = @SampleCollectionDate,
                Samplecollectiontime = @SampleCollectionTime,
                BarcodeNo            = ISNULL(sc.BarcodeNo, @GeneratedBarcode),
                ModifiedBy           = @UserId,
                ModifiedDate         = GETDATE()
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @SampleCollectionId;
        END
        ELSE
        BEGIN
            -- Standalone investigation
            SELECT @GeneratedBarcode = BarcodeNo FROM dbo.SampleCollection WHERE samplecollectionID = @SampleCollectionId;

            IF @GeneratedBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GeneratedBarcode OUTPUT;
            END

            UPDATE sc
            SET 
                CollectionstatusID   = 2,
                Samplecollectiondate = @SampleCollectionDate,
                Samplecollectiontime = @SampleCollectionTime,
                BarcodeNo            = @GeneratedBarcode,
                ModifiedBy           = @UserId,
                ModifiedDate         = GETDATE()
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @SampleCollectionId;
        END
    END
    ELSE IF @CollectionstatusID = 1 -- Revert to Pending: clear collection date, time, and BarcodeNo
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = 1,
            Samplecollectiondate = NULL,
            Samplecollectiontime = NULL,
            BarcodeNo            = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @SampleCollectionId;
    END
    ELSE -- Other statuses (Re Collect = 3, Rejected = 4)
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = @CollectionstatusID,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @SampleCollectionId;
    END

    SELECT @@ROWCOUNT AS RowsUpdated;
END
GO
