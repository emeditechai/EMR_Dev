-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2431  IPD Phase 2 · Bed Management
--   Bed status log (every change, by whom, why) through one writer, usp_Ipd_SetBedStatus
--   Transfer (bed / ward / ICU) and swap: the bed movements already drive the daily bed charge (fn_Ipd_BedDays)
--   Reservation of a bed for a planned admission (expires; only that patient can be admitted to it)
--   Block / maintenance with a reason; housekeeping cleaning job when a bed is vacated (HK masters, SLA)
--   Census by day and ward (occupied at midnight, admissions, discharges, transfers, occupancy %)
--   Hospital Settings > IPD: where a vacated bed goes (Cleaning / Available), reservation hold hours
-- Needs 2422-2430 (2423 calls usp_Ipd_SetBedStatus / usp_Ipd_ReleaseBed defined here). Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'IpdReleaseBedTo') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD
        IpdReleaseBedTo          VARCHAR(10) NOT NULL CONSTRAINT DF_HS_IpdReleaseBedTo DEFAULT ('CLEANING'),
        IpdReservationHoldHours  INT         NOT NULL CONSTRAINT DF_HS_IpdResHold      DEFAULT (24);
GO

IF OBJECT_ID('dbo.IpdBedStatusLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdBedStatusLog
    (
        LogId        BIGINT IDENTITY(1,1) CONSTRAINT PK_IpdBedStatusLog PRIMARY KEY,
        BedId        INT           NOT NULL,
        FromStatus   NVARCHAR(30)  NULL,
        ToStatus     NVARCHAR(30)  NOT NULL,
        Reason       NVARCHAR(300) NULL,
        AdmissionId  INT           NULL,
        RefType      VARCHAR(20)   NULL,   -- ADMIT TRANSFER SWAP CANCEL DISCHARGE RESERVE RELEASE CLEANING BLOCK MANUAL
        RefId        INT           NULL,
        CreatedBy    INT           NULL,
        CreatedDate  DATETIME      NOT NULL CONSTRAINT DF_IpdBedStatusLog_Created DEFAULT (GETDATE())
    );
    CREATE INDEX IX_IpdBedStatusLog_Bed ON dbo.IpdBedStatusLog (BedId, LogId);
END
GO

IF OBJECT_ID('dbo.IpdBedReservation', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdBedReservation
    (
        ReservationId    INT IDENTITY(1,1) CONSTRAINT PK_IpdBedReservation PRIMARY KEY,
        CompanyId        INT            NOT NULL,
        BranchId         INT            NOT NULL,
        BedId            INT            NOT NULL CONSTRAINT FK_IpdBedReservation_Bed REFERENCES dbo.BedMaster (BedId),
        PatientId        INT            NULL,
        PatientName      NVARCHAR(200)  NOT NULL,
        Phone            NVARCHAR(20)   NULL,
        ExpectedAdmitAt  DATETIME       NOT NULL,
        ReservedUntil    DATETIME       NOT NULL,
        EstimateId       INT            NULL,
        DoctorId         INT            NULL,
        Remarks          NVARCHAR(300)  NULL,
        Status           VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdBedReservation_Status DEFAULT ('ACTIVE'),   -- ACTIVE USED RELEASED EXPIRED
        AdmissionId      INT            NULL,
        CloseReason      NVARCHAR(300)  NULL,
        CreatedBy        INT            NULL,
        CreatedDate      DATETIME       NOT NULL CONSTRAINT DF_IpdBedReservation_Created DEFAULT (GETDATE()),
        ModifiedBy       INT            NULL,
        ModifiedDate     DATETIME       NULL
    );
    CREATE UNIQUE INDEX UX_IpdBedReservation_ActiveBed ON dbo.IpdBedReservation (BedId) WHERE Status = 'ACTIVE';
    CREATE INDEX IX_IpdBedReservation_Branch ON dbo.IpdBedReservation (BranchId, Status, ExpectedAdmitAt);
END
GO

IF OBJECT_ID('dbo.IpdBedCleaning', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdBedCleaning
    (
        CleaningTaskId    INT IDENTITY(1,1) CONSTRAINT PK_IpdBedCleaning PRIMARY KEY,
        CompanyId         INT           NOT NULL,
        BranchId          INT           NOT NULL,
        BedId             INT           NOT NULL CONSTRAINT FK_IpdBedCleaning_Bed REFERENCES dbo.BedMaster (BedId),
        AdmissionId       INT           NULL,
        Reason            VARCHAR(20)   NOT NULL,   -- TRANSFER DISCHARGE CANCEL MANUAL
        CleaningId        INT           NULL,       -- Master > Housekeeping > Cleaning type
        CleaningType      NVARCHAR(100) NULL,
        SlaMinutes        INT           NOT NULL CONSTRAINT DF_IpdBedCleaning_Sla DEFAULT (45),
        RequestedAt       DATETIME      NOT NULL CONSTRAINT DF_IpdBedCleaning_Req DEFAULT (GETDATE()),
        AssignedUserId    INT           NULL,
        StartedAt         DATETIME      NULL,
        CompletedAt       DATETIME      NULL,
        CompletedBy       INT           NULL,
        Status            VARCHAR(12)   NOT NULL CONSTRAINT DF_IpdBedCleaning_Status DEFAULT ('OPEN'),   -- OPEN IN_PROGRESS DONE CANCELLED
        IsOpen            BIT           NOT NULL CONSTRAINT DF_IpdBedCleaning_IsOpen DEFAULT (1),
        Remarks           NVARCHAR(300) NULL,
        CreatedBy         INT           NULL
    );
    CREATE UNIQUE INDEX UX_IpdBedCleaning_OpenBed ON dbo.IpdBedCleaning (BedId) WHERE IsOpen = 1;
    CREATE INDEX IX_IpdBedCleaning_Branch ON dbo.IpdBedCleaning (BranchId, IsOpen, RequestedAt);
END
GO

-- ── the only writer of BedMaster.BedStatus from IPD: the change and its reason go to the log ─────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_SetBedStatus
    @BedId INT, @ToStatus NVARCHAR(30), @Reason NVARCHAR(300) = NULL, @AdmissionId INT = NULL, @UserId INT = NULL,
    @RefType VARCHAR(20) = NULL, @RefId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from NVARCHAR(30) = (SELECT BedStatus FROM dbo.BedMaster WHERE BedId = @BedId);
    UPDATE dbo.BedMaster SET BedStatus = @ToStatus, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE BedId = @BedId;
    INSERT dbo.IpdBedStatusLog (BedId, FromStatus, ToStatus, Reason, AdmissionId, RefType, RefId, CreatedBy)
    VALUES (@BedId, @from, @ToStatus, NULLIF(LTRIM(RTRIM(@Reason)), N''), @AdmissionId, @RefType, @RefId, @UserId);
END;
GO

-- A bed a patient left: to housekeeping (Cleaning + a cleaning job) or straight back to Available (Hospital Settings > IPD).
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_ReleaseBed @BedId INT, @AdmissionId INT = NULL, @Reason VARCHAR(20), @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM dbo.IpdBedMovement WHERE BedId = @BedId AND ToAt IS NULL) RETURN;   -- someone else is in it (swap)
    DECLARE @br INT, @co INT, @to VARCHAR(10);
    SELECT @br = b.BranchId, @co = b.CompanyId FROM dbo.BedMaster b WHERE b.BedId = @BedId;
    SELECT @to = ISNULL(IpdReleaseBedTo, 'CLEANING') FROM dbo.HospitalSettings WHERE BranchID = @br;
    SET @to = ISNULL(@to, 'CLEANING');
    DECLARE @label NVARCHAR(100) = CASE @Reason WHEN 'TRANSFER' THEN N'Patient transferred out' WHEN 'DISCHARGE' THEN N'Patient discharged'
                                                WHEN 'CANCEL' THEN N'Admission cancelled' ELSE N'Bed vacated' END;
    IF @to = 'AVAILABLE'
    BEGIN
        EXEC dbo.usp_Ipd_SetBedStatus @BedId = @BedId, @ToStatus = N'Available', @Reason = @label, @AdmissionId = @AdmissionId, @UserId = @UserId, @RefType = @Reason;
        RETURN;
    END;
    DECLARE @cid INT, @ctype NVARCHAR(100), @sla INT;
    SELECT TOP 1 @cid = Cleaning_ID, @ctype = CleaningType, @sla = SLA_Minutes FROM dbo.HKCleaningMaster
    WHERE Branch_ID = @br AND Status = 1 ORDER BY CASE WHEN Frequency LIKE N'%Discharge%' OR CleaningType LIKE N'%Terminal%' THEN 0 ELSE 1 END, Cleaning_ID;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdBedCleaning WHERE BedId = @BedId AND IsOpen = 1)
        INSERT dbo.IpdBedCleaning (CompanyId, BranchId, BedId, AdmissionId, Reason, CleaningId, CleaningType, SlaMinutes, CreatedBy)
        VALUES (ISNULL(@co, 1), @br, @BedId, @AdmissionId, @Reason, @cid, ISNULL(@ctype, N'Terminal cleaning'), ISNULL(@sla, 45), @UserId);
    DECLARE @task INT = (SELECT CleaningTaskId FROM dbo.IpdBedCleaning WHERE BedId = @BedId AND IsOpen = 1);
    EXEC dbo.usp_Ipd_SetBedStatus @BedId = @BedId, @ToStatus = N'Cleaning', @Reason = @label, @AdmissionId = @AdmissionId, @UserId = @UserId, @RefType = @Reason, @RefId = @task;
END;
GO

-- Reservations past their hold time are expired and their beds freed (run by the board and the bed lists).
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_ExpireReservations @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (ReservationId INT, BedId INT);
    UPDATE dbo.IpdBedReservation SET Status = 'EXPIRED', CloseReason = N'Not admitted before the hold time', ModifiedDate = GETDATE()
    OUTPUT inserted.ReservationId, inserted.BedId INTO @r
    WHERE BranchId = @BranchId AND Status = 'ACTIVE' AND ReservedUntil < GETDATE();
    DECLARE @id INT = (SELECT MIN(ReservationId) FROM @r), @bed INT;
    WHILE @id IS NOT NULL
    BEGIN
        SELECT @bed = BedId FROM @r WHERE ReservationId = @id;
        IF (SELECT BedStatus FROM dbo.BedMaster WHERE BedId = @bed) = N'Reserved'
            EXEC dbo.usp_Ipd_SetBedStatus @BedId = @bed, @ToStatus = N'Available', @Reason = N'Reservation expired', @RefType = 'RELEASE', @RefId = @id;
        SET @id = (SELECT MIN(ReservationId) FROM @r WHERE ReservationId > @id);
    END
END;
GO

-- ── the bed board ───────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_Board @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_Ipd_ExpireReservations @BranchId = @BranchId;
    DECLARE @now DATETIME = GETDATE();
    -- 1 every active bed with its occupant / reservation / cleaning job
    SELECT b.BedId, b.BedNumber, b.BedCategoryId, bc.CategoryName AS BedCategoryName, r.RoomId, r.RoomNumber, r.RoomType,
           w.WardId, w.WardName, w.WardType, w.Gender AS WardGender, dep.DeptName AS WardDepartment, f.FloorId, f.FloorName, bl.BuildingId, bl.BuildingName,
           CAST(ISNULL(b.IsICU, 0) AS BIT) AS IsIcu, CAST(CASE WHEN b.IsIsolation = 1 OR r.IsIsolation = 1 THEN 1 ELSE 0 END AS BIT) AS IsIsolation,
           CAST(ISNULL(b.IsVentilatorCapable, 0) AS BIT) AS IsVentilator,
           CASE WHEN occ.AdmissionId IS NOT NULL THEN N'Occupied' ELSE b.BedStatus END AS Status,
           lg.Reason AS StatusReason, lg.CreatedDate AS StatusSince,
           occ.AdmissionId, occ.IpNo, occ.PatientId, occ.PatientCode, occ.PatientName, occ.Gender, occ.AgeText, occ.AdmissionAt, occ.OccupiedSince,
           occ.ConsultantName, occ.PayerType, occ.ExpectedDischargeAt, occ.KnownAllergies, occ.IsMlc, occ.AdmStatus,
           CASE WHEN occ.AdmissionId IS NULL THEN NULL ELSE DATEDIFF(DAY, occ.AdmissionAt, @now) + 1 END AS DayCount,
           lt.Net AS BillNow, mo.NetAdvance, CAST(lt.Net - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceDue,
           res.ReservationId, res.PatientName AS ResPatientName, res.Phone AS ResPhone, res.PatientId AS ResPatientId, res.ExpectedAdmitAt, res.ReservedUntil,
           cl.CleaningTaskId, cl.Status AS CleaningStatus, cl.CleaningType, cl.RequestedAt AS CleaningRequestedAt, cl.StartedAt AS CleaningStartedAt,
           cl.SlaMinutes, cu.FullName AS CleaningStaff, DATEDIFF(MINUTE, cl.RequestedAt, @now) AS CleaningMinutes
    FROM dbo.BedMaster b
    JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = w.DepartmentId
    LEFT JOIN dbo.FloorMaster f ON f.FloorId = r.FloorId
    LEFT JOIN dbo.BuildingMaster bl ON bl.BuildingId = b.BuildingId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = b.BedCategoryId
    OUTER APPLY (SELECT TOP 1 a.AdmissionId, a.IpNo, a.PatientId, p.PatientCode, a.AdmissionAt, m.FromAt AS OccupiedSince, a.PayerType, a.ExpectedDischargeAt, a.IsMlc, a.Status AS AdmStatus,
                        LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, p.Gender, p.KnownAllergies,
                        dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(@now AS DATE)) AS AgeText, d.FullName AS ConsultantName
                 FROM dbo.IpdBedMovement m JOIN dbo.IpdAdmission a ON a.AdmissionId = m.AdmissionId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
                 LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
                 WHERE m.BedId = b.BedId AND m.ToAt IS NULL) occ
    OUTER APPLY (SELECT TOP 1 Reason, CreatedDate FROM dbo.IpdBedStatusLog WHERE BedId = b.BedId ORDER BY LogId DESC) lg
    OUTER APPLY (SELECT TOP 1 * FROM dbo.IpdBedReservation x WHERE x.BedId = b.BedId AND x.Status = 'ACTIVE') res
    OUTER APPLY (SELECT TOP 1 * FROM dbo.IpdBedCleaning x WHERE x.BedId = b.BedId AND x.IsOpen = 1) cl
    LEFT JOIN dbo.Users cu ON cu.Id = cl.AssignedUserId
    OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(occ.AdmissionId, @now) WHERE occ.AdmissionId IS NOT NULL) lt
    OUTER APPLY (SELECT NetAdvance FROM dbo.fn_Ipd_Money(occ.AdmissionId) WHERE occ.AdmissionId IS NOT NULL) mo
    WHERE b.IsActive = 1 AND b.BranchId = @BranchId AND w.IsActive = 1 AND r.IsActive = 1
    ORDER BY bl.BuildingName, f.FloorName, w.WardName, r.RoomNumber, b.BedNumber;
    -- 2 housekeeping staff of the branch (Master > Housekeeping > Staff)
    SELECT DISTINCT u.Id AS UserId, COALESCE(u.FullName, u.Username) AS Name
    FROM dbo.HKStaffMaster s JOIN dbo.Users u ON u.Id = s.Staff_ID AND u.IsActive = 1
    WHERE s.Branch_ID = @BranchId AND s.Status = 1 ORDER BY Name;
    -- 3 reservations of the last 7 days and the coming ones
    SELECT x.ReservationId, x.BedId, b.BedNumber, w.WardName, x.PatientId, x.PatientName, x.Phone, x.ExpectedAdmitAt, x.ReservedUntil, x.Status, x.Remarks,
           x.CloseReason, a.IpNo, d.FullName AS DoctorName, u.FullName AS CreatedByName, x.CreatedDate
    FROM dbo.IpdBedReservation x JOIN dbo.BedMaster b ON b.BedId = x.BedId JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.IpdAdmission a ON a.AdmissionId = x.AdmissionId LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = x.DoctorId LEFT JOIN dbo.Users u ON u.Id = x.CreatedBy
    WHERE x.BranchId = @BranchId AND (x.Status = 'ACTIVE' OR x.CreatedDate >= DATEADD(DAY, -7, @now))
    ORDER BY CASE WHEN x.Status = 'ACTIVE' THEN 0 ELSE 1 END, x.ExpectedAdmitAt DESC;
    -- 4 cleaning jobs: open ones and those finished today
    SELECT c.CleaningTaskId, c.BedId, b.BedNumber, w.WardName, r.RoomNumber, c.Reason, c.CleaningType, c.SlaMinutes, c.RequestedAt, c.StartedAt, c.CompletedAt, c.Status,
           u.FullName AS StaffName, cb.FullName AS CompletedByName, DATEDIFF(MINUTE, c.RequestedAt, ISNULL(c.CompletedAt, @now)) AS Minutes,
           CAST(CASE WHEN DATEDIFF(MINUTE, c.RequestedAt, ISNULL(c.CompletedAt, @now)) > c.SlaMinutes THEN 1 ELSE 0 END AS BIT) AS Overdue
    FROM dbo.IpdBedCleaning c JOIN dbo.BedMaster b ON b.BedId = c.BedId JOIN dbo.WardMaster w ON w.WardId = b.WardId JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    LEFT JOIN dbo.Users u ON u.Id = c.AssignedUserId LEFT JOIN dbo.Users cb ON cb.Id = c.CompletedBy
    WHERE c.BranchId = @BranchId AND (c.IsOpen = 1 OR c.CompletedAt >= CAST(@now AS DATE))
    ORDER BY c.IsOpen DESC, c.RequestedAt;
END;
GO

-- History of one bed: status changes and the patients who used it.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_History @CompanyId INT, @BranchId INT, @BedId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 100 l.LogId, l.FromStatus, l.ToStatus, l.Reason, l.RefType, a.IpNo, l.CreatedDate, u.FullName AS CreatedByName
    FROM dbo.IpdBedStatusLog l JOIN dbo.BedMaster b ON b.BedId = l.BedId AND b.BranchId = @BranchId
    LEFT JOIN dbo.IpdAdmission a ON a.AdmissionId = l.AdmissionId LEFT JOIN dbo.Users u ON u.Id = l.CreatedBy
    WHERE l.BedId = @BedId ORDER BY l.LogId DESC;
    SELECT TOP 50 m.MovementId, a.AdmissionId, a.IpNo, LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName))) AS PatientName, m.MoveType, m.EndType, m.FromAt, m.ToAt, m.Reason
    FROM dbo.IpdBedMovement m JOIN dbo.IpdAdmission a ON a.AdmissionId = m.AdmissionId AND a.BranchId = @BranchId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    WHERE m.BedId = @BedId ORDER BY m.FromAt DESC;
END;
GO

-- ── transfer: bed / ward / ICU ──────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_Transfer
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @ToBedId INT, @TransferAt DATETIME = NULL, @Reason NVARCHAR(300),
    @UpdateDepartment BIT = 0, @CanBackdate BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        SET @TransferAt = ISNULL(@TransferAt, @now);
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54801, 'Enter the reason for the transfer (e.g. needs ICU care, patient request, isolation).', 1;
        IF @TransferAt > DATEADD(MINUTE, 5, @now) THROW 54802, 'The transfer time cannot be in the future.', 1;
        IF @TransferAt < DATEADD(MINUTE, -30, @now) AND ISNULL(@CanBackdate, 0) = 0 THROW 54803, 'You are not allowed to enter an earlier transfer time (more than 30 minutes back).', 1;
        DECLARE @open BIT, @gender NVARCHAR(20), @patient INT, @fromBed INT, @mv INT, @mvFrom DATETIME;
        SELECT @open = a.IsOpen, @gender = p.Gender, @patient = a.PatientId FROM dbo.IpdAdmission a WITH (UPDLOCK) JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        WHERE a.AdmissionId = @AdmissionId AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId;
        IF @open IS NULL THROW 54804, 'The admission was not found in this branch.', 1;
        IF @open = 0 THROW 54805, 'The admission is closed: the patient cannot be transferred.', 1;
        SELECT @mv = MovementId, @fromBed = BedId, @mvFrom = FromAt FROM dbo.IpdBedMovement WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND ToAt IS NULL;
        IF @mv IS NULL THROW 54806, 'The patient has no current bed.', 1;
        IF @fromBed = @ToBedId THROW 54807, 'Choose a different bed.', 1;
        IF @TransferAt <= @mvFrom THROW 54808, 'The transfer time must be after the patient moved into the current bed.', 1;

        DECLARE @ward INT, @room INT, @cat INT, @bStatus NVARCHAR(30), @bNo NVARCHAR(50), @wGender NVARCHAR(20), @wName NVARCHAR(150), @wDept INT, @toIcu BIT;
        SELECT @ward = b.WardId, @room = b.RoomId, @cat = b.BedCategoryId, @bStatus = b.BedStatus, @bNo = b.BedNumber, @wGender = w.Gender, @wName = w.WardName,
               @wDept = w.DepartmentId, @toIcu = ISNULL(b.IsICU, 0)
        FROM dbo.BedMaster b WITH (UPDLOCK, HOLDLOCK) JOIN dbo.WardMaster w ON w.WardId = b.WardId
        WHERE b.BedId = @ToBedId AND b.BranchId = @BranchId AND b.IsActive = 1;
        IF @ward IS NULL THROW 54809, 'Choose an active bed of this branch.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdBedMovement WITH (UPDLOCK, HOLDLOCK) WHERE BedId = @ToBedId AND ToAt IS NULL)
        BEGIN SET @msg = N'Bed ' + @bNo + N' is occupied. Use Swap to exchange the beds of two patients.'; THROW 54810, @msg, 1; END;
        DECLARE @resId INT = (SELECT ReservationId FROM dbo.IpdBedReservation WHERE BedId = @ToBedId AND Status = 'ACTIVE' AND (PatientId = @patient));
        IF @bStatus <> N'Available' AND NOT (@bStatus = N'Reserved' AND @resId IS NOT NULL)
        BEGIN SET @msg = N'Bed ' + @bNo + N' is ' + @bStatus + N'. Choose an available bed.'; THROW 54811, @msg, 1; END;
        IF ISNULL((SELECT IpdBlockWardGenderMismatch FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 1) = 1
           AND @wGender IN (N'Male', N'Female') AND ISNULL(@gender, N'') IN (N'Male', N'Female') AND @wGender <> @gender
        BEGIN SET @msg = @wName + N' is a ' + LOWER(@wGender) + N' ward; the patient is ' + LOWER(@gender) + N'.'; THROW 54812, @msg, 1; END;

        DECLARE @fromNo NVARCHAR(50), @fromWard NVARCHAR(150), @fromIcu BIT;
        SELECT @fromNo = b.BedNumber, @fromWard = w.WardName, @fromIcu = ISNULL(b.IsICU, 0) FROM dbo.BedMaster b JOIN dbo.WardMaster w ON w.WardId = b.WardId WHERE b.BedId = @fromBed;
        DECLARE @kind VARCHAR(12) = CASE WHEN @toIcu = 1 AND @fromIcu = 0 THEN 'ICU_IN' WHEN @toIcu = 0 AND @fromIcu = 1 THEN 'ICU_OUT' ELSE 'TRANSFER' END;

        UPDATE dbo.IpdBedMovement SET ToAt = @TransferAt, EndType = 'TRANSFER' WHERE MovementId = @mv;
        INSERT dbo.IpdBedMovement (AdmissionId, BedId, WardId, RoomId, BedCategoryId, FromAt, MoveType, Reason, CreatedBy)
        VALUES (@AdmissionId, @ToBedId, @ward, @room, @cat, @TransferAt, @kind, LTRIM(RTRIM(@Reason)), @UserId);
        UPDATE dbo.IpdAdmission SET CurrentBedId = @ToBedId, ModifiedBy = @UserId, ModifiedDate = @now,
               DepartmentId = CASE WHEN ISNULL(@UpdateDepartment, 0) = 1 AND @wDept IS NOT NULL THEN @wDept ELSE DepartmentId END
        WHERE AdmissionId = @AdmissionId;
        IF @resId IS NOT NULL UPDATE dbo.IpdBedReservation SET Status = 'USED', AdmissionId = @AdmissionId, ModifiedBy = @UserId, ModifiedDate = @now WHERE ReservationId = @resId;
        EXEC dbo.usp_Ipd_SetBedStatus @BedId = @ToBedId, @ToStatus = N'Occupied', @Reason = N'Patient transferred in', @AdmissionId = @AdmissionId, @UserId = @UserId, @RefType = 'TRANSFER';
        EXEC dbo.usp_Ipd_ReleaseBed @BedId = @fromBed, @AdmissionId = @AdmissionId, @Reason = 'TRANSFER', @UserId = @UserId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, CASE @kind WHEN 'ICU_IN' THEN 'ICU_SHIFT' WHEN 'ICU_OUT' THEN 'ICU_OUT' ELSE 'TRANSFER' END,
                CONCAT(N'Bed ', @fromNo, N' (', @fromWard, N') → ', @bNo, N' (', @wName, N') at ', FORMAT(@TransferAt, 'dd-MMM HH:mm', 'en-US'), N': ', LTRIM(RTRIM(@Reason))), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @AdmissionId AS AdmissionId, @bNo AS BedNumber, @kind AS MoveType;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() IN (2601, 2627) SELECT CAST(0 AS BIT) AS Success, N'The bed was just taken by another patient. Refresh and choose again.' AS Error;
        ELSE IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── swap the beds of two admitted patients ──────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_Swap @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @OtherAdmissionId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54821, 'Enter the reason for the swap.', 1;
        IF @AdmissionId = @OtherAdmissionId THROW 54822, 'Choose another patient to swap with.', 1;
        DECLARE @A TABLE (Seq INT, AdmissionId INT, Gender NVARCHAR(20), Mv INT, BedId INT, BedNo NVARCHAR(50), WardId INT, RoomId INT, CatId INT, WGender NVARCHAR(20), WName NVARCHAR(150), IpNo NVARCHAR(40));
        INSERT @A
        SELECT CASE WHEN a.AdmissionId = @AdmissionId THEN 1 ELSE 2 END, a.AdmissionId, p.Gender, m.MovementId, m.BedId, b.BedNumber, b.WardId, b.RoomId, b.BedCategoryId, w.Gender, w.WardName, a.IpNo
        FROM dbo.IpdAdmission a WITH (UPDLOCK) JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        JOIN dbo.IpdBedMovement m WITH (UPDLOCK) ON m.AdmissionId = a.AdmissionId AND m.ToAt IS NULL
        JOIN dbo.BedMaster b ON b.BedId = m.BedId JOIN dbo.WardMaster w ON w.WardId = b.WardId
        WHERE a.AdmissionId IN (@AdmissionId, @OtherAdmissionId) AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId AND a.IsOpen = 1;
        IF (SELECT COUNT(*) FROM @A) <> 2 THROW 54823, 'Both patients must be admitted in this branch with a current bed.', 1;
        IF ISNULL((SELECT IpdBlockWardGenderMismatch FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 1) = 1
           AND EXISTS (SELECT 1 FROM @A x JOIN @A y ON y.Seq <> x.Seq WHERE y.WGender IN (N'Male', N'Female') AND x.Gender IN (N'Male', N'Female') AND y.WGender <> x.Gender)
            THROW 54824, 'A patient would move into a ward of the other gender.', 1;
        UPDATE m SET ToAt = @now, EndType = 'SWAP' FROM dbo.IpdBedMovement m JOIN @A x ON x.Mv = m.MovementId;
        INSERT dbo.IpdBedMovement (AdmissionId, BedId, WardId, RoomId, BedCategoryId, FromAt, MoveType, Reason, CreatedBy)
        SELECT x.AdmissionId, y.BedId, y.WardId, y.RoomId, y.CatId, @now, 'SWAP', LTRIM(RTRIM(@Reason)), @UserId FROM @A x JOIN @A y ON y.Seq <> x.Seq;
        UPDATE a SET CurrentBedId = y.BedId, ModifiedBy = @UserId, ModifiedDate = @now
        FROM dbo.IpdAdmission a JOIN @A x ON x.AdmissionId = a.AdmissionId JOIN @A y ON y.Seq <> x.Seq;
        INSERT dbo.IpdBedStatusLog (BedId, FromStatus, ToStatus, Reason, AdmissionId, RefType, CreatedBy)
        SELECT y.BedId, N'Occupied', N'Occupied', N'Beds swapped with ' + x.IpNo, x.AdmissionId, 'SWAP', @UserId FROM @A x JOIN @A y ON y.Seq <> x.Seq;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT x.AdmissionId, 'SWAP', CONCAT(N'Bed ', x.BedNo, N' (', x.WName, N') swapped with ', y.IpNo, N' → ', y.BedNo, N' (', y.WName, N'): ', LTRIM(RTRIM(@Reason))), @UserId
        FROM @A x JOIN @A y ON y.Seq <> x.Seq;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── block / maintenance / back to available (a free bed only) ───────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_SetStatus @CompanyId INT, @BranchId INT, @UserId INT, @BedId INT, @Status NVARCHAR(30), @Reason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    DECLARE @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF @Status NOT IN (N'Available', N'Blocked', N'Maintenance') THROW 54831, 'Choose Available, Blocked or Maintenance.', 1;
        IF @Status <> N'Available' AND NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54832, 'Enter the reason (e.g. broken bed, pest control, staff shortage).', 1;
        DECLARE @cur NVARCHAR(30) = (SELECT BedStatus FROM dbo.BedMaster WITH (UPDLOCK) WHERE BedId = @BedId AND BranchId = @BranchId AND IsActive = 1);
        IF @cur IS NULL THROW 54833, 'The bed was not found in this branch.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdBedMovement WHERE BedId = @BedId AND ToAt IS NULL) THROW 54834, 'A patient is in this bed: transfer the patient first.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdBedReservation WHERE BedId = @BedId AND Status = 'ACTIVE') THROW 54835, 'The bed is reserved: release the reservation first.', 1;
        IF @cur = @Status BEGIN SET @msg = N'The bed is already ' + @Status + N'.'; THROW 54836, @msg, 1; END;
        -- an open cleaning job ends when the bed is made available or taken out of use
        UPDATE dbo.IpdBedCleaning SET Status = CASE WHEN @Status = N'Available' THEN 'DONE' ELSE 'CANCELLED' END, IsOpen = 0, CompletedAt = GETDATE(), CompletedBy = @UserId,
               Remarks = ISNULL(Remarks + N'; ', N'') + CASE WHEN @Status = N'Available' THEN N'Made available from the bed board' ELSE N'Bed ' + LOWER(@Status) END
        WHERE BedId = @BedId AND IsOpen = 1;
        DECLARE @ref VARCHAR(20) = CASE WHEN @Status = N'Available' THEN 'MANUAL' ELSE 'BLOCK' END;
        EXEC dbo.usp_Ipd_SetBedStatus @BedId = @BedId, @ToStatus = @Status, @Reason = @Reason, @UserId = @UserId, @RefType = @ref;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── reservations ────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_Reserve
    @CompanyId INT, @BranchId INT, @UserId INT, @BedId INT, @PatientId INT = NULL, @PatientName NVARCHAR(200) = NULL, @Phone NVARCHAR(20) = NULL,
    @ExpectedAdmitAt DATETIME, @HoldHours INT = NULL, @DoctorId INT = NULL, @EstimateId INT = NULL, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF @PatientId IS NOT NULL
            SELECT @PatientName = LTRIM(RTRIM(CONCAT(NULLIF(Salutation, '') + ' ', FirstName, ' ', LastName))), @Phone = ISNULL(NULLIF(@Phone, N''), PhoneNumber)
            FROM dbo.PatientMaster WHERE PatientId = @PatientId AND CompanyId = @CompanyId;
        IF NULLIF(LTRIM(RTRIM(@PatientName)), N'') IS NULL THROW 54841, 'Choose the patient or enter the name.', 1;
        IF @ExpectedAdmitAt IS NULL OR @ExpectedAdmitAt < DATEADD(HOUR, -1, @now) THROW 54842, 'Enter the expected admission time (now or later).', 1;
        SET @HoldHours = ISNULL(NULLIF(@HoldHours, 0), ISNULL((SELECT IpdReservationHoldHours FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 24));
        IF @HoldHours < 1 OR @HoldHours > 168 THROW 54843, 'The bed can be held for 1 to 168 hours after the expected admission time.', 1;
        DECLARE @st NVARCHAR(30), @no NVARCHAR(50);
        SELECT @st = BedStatus, @no = BedNumber FROM dbo.BedMaster WITH (UPDLOCK, HOLDLOCK) WHERE BedId = @BedId AND BranchId = @BranchId AND IsActive = 1;
        IF @st IS NULL THROW 54844, 'The bed was not found in this branch.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdBedMovement WHERE BedId = @BedId AND ToAt IS NULL) OR @st <> N'Available'
        BEGIN SET @msg = N'Bed ' + @no + N' is ' + CASE WHEN @st = N'Available' THEN N'Occupied' ELSE @st END + N': only an available bed can be reserved.'; THROW 54845, @msg, 1; END;
        IF @PatientId IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE PatientId = @PatientId AND IsOpen = 1) THROW 54846, 'The patient is already admitted.', 1;
        IF @PatientId IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.IpdBedReservation WHERE PatientId = @PatientId AND Status = 'ACTIVE')
            THROW 54847, 'The patient already has an active bed reservation: release it first.', 1;
        INSERT dbo.IpdBedReservation (CompanyId, BranchId, BedId, PatientId, PatientName, Phone, ExpectedAdmitAt, ReservedUntil, EstimateId, DoctorId, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @BedId, @PatientId, LTRIM(RTRIM(@PatientName)), NULLIF(LTRIM(RTRIM(@Phone)), N''), @ExpectedAdmitAt,
                DATEADD(HOUR, @HoldHours, @ExpectedAdmitAt), @EstimateId, NULLIF(@DoctorId, 0), NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
        DECLARE @rid INT = CAST(SCOPE_IDENTITY() AS INT);
        DECLARE @why NVARCHAR(300) = CONCAT(N'Reserved for ', LTRIM(RTRIM(@PatientName)), N', expected ', FORMAT(@ExpectedAdmitAt, 'dd-MMM HH:mm', 'en-US'));
        EXEC dbo.usp_Ipd_SetBedStatus @BedId = @BedId, @ToStatus = N'Reserved', @Reason = @why, @UserId = @UserId, @RefType = 'RESERVE', @RefId = @rid;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @rid AS ReservationId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() IN (2601, 2627) SELECT CAST(0 AS BIT) AS Success, N'The bed was just reserved by someone else.' AS Error;
        ELSE IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_ReleaseReservation @CompanyId INT, @BranchId INT, @UserId INT, @ReservationId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54851, 'Enter the reason for releasing the bed.', 1;
        DECLARE @bed INT = (SELECT BedId FROM dbo.IpdBedReservation WITH (UPDLOCK) WHERE ReservationId = @ReservationId AND BranchId = @BranchId AND Status = 'ACTIVE');
        IF @bed IS NULL THROW 54852, 'Only an active reservation of this branch can be released.', 1;
        UPDATE dbo.IpdBedReservation SET Status = 'RELEASED', CloseReason = LTRIM(RTRIM(@Reason)), ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE ReservationId = @ReservationId;
        IF (SELECT BedStatus FROM dbo.BedMaster WHERE BedId = @bed) = N'Reserved'
            EXEC dbo.usp_Ipd_SetBedStatus @BedId = @bed, @ToStatus = N'Available', @Reason = @Reason, @UserId = @UserId, @RefType = 'RELEASE', @RefId = @ReservationId;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── housekeeping: assign / start and finish the cleaning of a vacated bed ───────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_Cleaning
    @CompanyId INT, @BranchId INT, @UserId INT, @CleaningTaskId INT, @Action VARCHAR(10), @StaffUserId INT = NULL, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    DECLARE @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @bed INT, @st VARCHAR(12);
        SELECT @bed = BedId, @st = Status FROM dbo.IpdBedCleaning WITH (UPDLOCK) WHERE CleaningTaskId = @CleaningTaskId AND BranchId = @BranchId AND IsOpen = 1;
        IF @bed IS NULL THROW 54861, 'The cleaning job is not open any more.', 1;
        IF @Action = 'START'
        BEGIN
            UPDATE dbo.IpdBedCleaning SET Status = 'IN_PROGRESS', StartedAt = ISNULL(StartedAt, @now), AssignedUserId = ISNULL(NULLIF(@StaffUserId, 0), AssignedUserId)
            WHERE CleaningTaskId = @CleaningTaskId;
        END
        ELSE IF @Action = 'DONE'
        BEGIN
            UPDATE dbo.IpdBedCleaning SET Status = 'DONE', IsOpen = 0, StartedAt = ISNULL(StartedAt, @now), CompletedAt = @now, CompletedBy = @UserId,
                   AssignedUserId = ISNULL(NULLIF(@StaffUserId, 0), AssignedUserId), Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'')
            WHERE CleaningTaskId = @CleaningTaskId;
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdBedMovement WHERE BedId = @bed AND ToAt IS NULL) AND (SELECT BedStatus FROM dbo.BedMaster WHERE BedId = @bed) = N'Cleaning'
                EXEC dbo.usp_Ipd_SetBedStatus @BedId = @bed, @ToStatus = N'Available', @Reason = N'Cleaning done', @UserId = @UserId, @RefType = 'CLEANING', @RefId = @CleaningTaskId;
        END
        ELSE THROW 54862, 'Unknown cleaning action.', 1;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── census by day and ward (midnight census, from the bed movements) ────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_Ipd_Census @CompanyId INT, @BranchId INT, @FromDate DATE, @ToDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    IF @ToDate < @FromDate OR DATEDIFF(DAY, @FromDate, @ToDate) > 92 SET @FromDate = DATEADD(DAY, -30, @ToDate);
    DECLARE @now DATETIME = GETDATE();
    ;WITH days AS (SELECT TOP (DATEDIFF(DAY, @FromDate, @ToDate) + 1) DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1, @FromDate) AS D FROM sys.all_columns),
    wards AS (SELECT w.WardId, w.WardName, (SELECT COUNT(*) FROM dbo.BedMaster b WHERE b.WardId = w.WardId AND b.IsActive = 1) AS Beds
              FROM dbo.WardMaster w WHERE w.BranchId = @BranchId AND w.IsActive = 1)
    SELECT d.D AS CensusDate, w.WardId, w.WardName, w.Beds,
           -- patients in a bed of the ward at midnight (end of the day; now for today)
           (SELECT COUNT(DISTINCT m.AdmissionId) FROM dbo.IpdBedMovement m JOIN dbo.IpdAdmission a ON a.AdmissionId = m.AdmissionId AND a.Status <> 'CANCELLED'
             WHERE m.WardId = w.WardId AND m.FromAt <= CASE WHEN d.D = CAST(@now AS DATE) THEN @now ELSE DATEADD(SECOND, -1, CAST(DATEADD(DAY, 1, d.D) AS DATETIME)) END
               AND (m.ToAt IS NULL OR m.ToAt > CASE WHEN d.D = CAST(@now AS DATE) THEN @now ELSE DATEADD(SECOND, -1, CAST(DATEADD(DAY, 1, d.D) AS DATETIME)) END)) AS Occupied,
           (SELECT COUNT(*) FROM dbo.IpdBedMovement m JOIN dbo.IpdAdmission a ON a.AdmissionId = m.AdmissionId AND a.Status <> 'CANCELLED'
             WHERE m.WardId = w.WardId AND m.MoveType = 'ADMIT' AND CAST(m.FromAt AS DATE) = d.D) AS Admissions,
           (SELECT COUNT(*) FROM dbo.IpdBedMovement m WHERE m.WardId = w.WardId AND m.EndType = 'DISCHARGE' AND CAST(m.ToAt AS DATE) = d.D) AS Discharges,
           (SELECT COUNT(*) FROM dbo.IpdBedMovement m WHERE m.WardId = w.WardId AND m.MoveType IN ('TRANSFER', 'ICU_IN', 'ICU_OUT', 'SWAP') AND CAST(m.FromAt AS DATE) = d.D) AS TransfersIn,
           (SELECT COUNT(*) FROM dbo.IpdBedMovement m WHERE m.WardId = w.WardId AND m.EndType IN ('TRANSFER', 'SWAP') AND CAST(m.ToAt AS DATE) = d.D) AS TransfersOut
    FROM days d CROSS JOIN wards w
    ORDER BY d.D DESC, w.WardName;
END;
GO

-- beds for the transfer picker: like usp_Api_Ipd_Beds, plus the patient's own reservation
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_ForTransfer @CompanyId INT, @BranchId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_Ipd_ExpireReservations @BranchId = @BranchId;
    DECLARE @tc INT, @patient INT, @cur INT;
    SELECT @tc = TariffCategoryId, @patient = PatientId, @cur = CurrentBedId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    SELECT b.BedId, b.BedNumber, bc.CategoryName AS BedCategoryName, r.RoomNumber, w.WardId, w.WardName, w.Gender AS WardGender, dep.DeptName AS WardDepartment,
           f.FloorName, CAST(ISNULL(b.IsICU, 0) AS BIT) AS IsIcu, CAST(CASE WHEN b.IsIsolation = 1 OR r.IsIsolation = 1 THEN 1 ELSE 0 END AS BIT) AS IsIsolation,
           CASE WHEN b.BedId = @cur THEN N'Current' WHEN occ.x = 1 THEN N'Occupied' ELSE b.BedStatus END AS Status,
           CAST(CASE WHEN b.BedId <> @cur AND occ.x IS NULL AND (b.BedStatus = N'Available' OR (b.BedStatus = N'Reserved' AND res.PatientId = @patient)) THEN 1 ELSE 0 END AS BIT) AS Selectable,
           rt.RoomCharge + rt.BedCharge + rt.NursingCharge + rt.AttendantCharge + rt.IsolationCharge AS DailyRate, CAST(CASE WHEN rt.BedRateId IS NULL THEN 1 ELSE 0 END AS BIT) AS NoTariff
    FROM dbo.BedMaster b JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = w.DepartmentId LEFT JOIN dbo.FloorMaster f ON f.FloorId = r.FloorId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = b.BedCategoryId
    OUTER APPLY (SELECT TOP 1 1 AS x FROM dbo.IpdBedMovement m WHERE m.BedId = b.BedId AND m.ToAt IS NULL) occ
    OUTER APPLY (SELECT TOP 1 PatientId FROM dbo.IpdBedReservation x WHERE x.BedId = b.BedId AND x.Status = 'ACTIVE') res
    OUTER APPLY dbo.fn_Ipd_BedRate(@BranchId, b.BedId, ISNULL(@tc, 0), @today) rt
    WHERE b.IsActive = 1 AND b.BranchId = @BranchId AND w.IsActive = 1 AND r.IsActive = 1
    ORDER BY w.WardName, r.RoomNumber, b.BedNumber;
END;
GO

-- ── navbar IPD > Bed Board, controls ────────────────────────────────────────────────────────────────────────
SET NOCOUNT ON;
DECLARE @co INT = 1, @nav INT, @page INT, @view INT, @ctl INT;
SELECT @nav = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'IPD' AND CompanyId = 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @nav, @Page_Code = N'IPD.BEDBOARD', @Title = N'Bed Board', @Controller = N'IpdBeds', @Action = N'Index',
     @Show_In_Menu = 1, @Sort_Order = 25, @Icon = N'bi bi-grid-3x3-gap-fill me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
DECLARE @a NVARCHAR(60);
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'Index,BoardData,History,CensusData,TransferBeds', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdBeds', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
CLOSE v; DEALLOCATE v;
DECLARE @c TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT, Acts NVARCHAR(200));
INSERT @c VALUES ('TRANSFER', N'Transfer a patient to another bed / ward / ICU', 20, N'Transfer'), ('BACKDATE', N'Enter an earlier transfer time', 25, N''),
                 ('SWAP', N'Swap the beds of two patients', 30, N'Swap'), ('RESERVE', N'Reserve a bed for a planned admission', 40, N'Reserve'),
                 ('RELEASE', N'Release a bed reservation', 50, N'ReleaseReservation'), ('BLOCK', N'Block / maintenance / make available', 60, N'SetStatus'),
                 ('HOUSEKEEPING', N'Start / finish bed cleaning', 70, N'Cleaning');
DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @ca NVARCHAR(200);
DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort, Acts FROM @c;
OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
    IF @ca <> N'' EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdBeds', @Action = @ca, @Source = 'SEED';
    FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
END
CLOSE k; DEALLOCATE k;
-- the IPD Patient screen transfers too (same endpoints, its own TRANSFER control)
DECLARE @pp INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT' AND CompanyId = 1), @pv INT, @pt INT;
SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'VIEW';
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @pp, @Control_Code = 'TRANSFER', @Title = N'Transfer the patient to another bed / ward / ICU', @Sort_Order = 35, @Control_ID = @pt OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdBeds', @Action = N'TransferBeds', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pt, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdBeds', @Action = N'Transfer', @Source = 'SEED';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2431 IPD bed management - done.';
GO
