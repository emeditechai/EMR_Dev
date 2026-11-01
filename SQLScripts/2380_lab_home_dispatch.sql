-- ============================================================================================================
-- 2380  LAB > Home Collection Dispatch: after the bill is saved the office sees the branch's home visits and reassigns, reschedules
--       and closes them. Run after 2373, 2374. Re-runnable.
--   Page LAB.HOMEDISPATCH (LAB menu). No role is granted here: give it from Settings > Security.
--   A visit can be changed until the phlebotomist reaches the patient; REACHED and later belong to the phone.
--   Reassigning also updates LabOrder.PhlebotomistId, so the booking and the visit agree.
--   Closing ends the visit only. The bill and its samples stay; cancelling a bill stays in Bill Cancellation.
--   A closed visit can be brought back by rescheduling it.
-- ============================================================================================================
SET NOCOUNT ON;
GO

-- Every open home collection of the branch has a visit, without waiting for the phlebotomist to open the app.
CREATE OR ALTER PROCEDURE dbo.usp_Lab_HomeDispatch_Sync
    @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE v SET Status = 'CANCELLED', OutcomeReason = N'Booking cancelled', ModifiedDate = GETDATE()
      FROM dbo.LabHomeVisit v JOIN dbo.LabOrder o ON o.LabOrderId = v.LabOrderId
     WHERE v.BranchId = @BranchId AND o.IsActive = 0
       AND v.Status IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'REACHED', 'IN_PROGRESS', 'UNAVAILABLE', 'RESCHEDULED');

    -- the booking was given to someone else from the booking screen
    UPDATE v SET PhlebotomistId = o.PhlebotomistId, Status = 'ASSIGNED', ModifiedDate = GETDATE()
      FROM dbo.LabHomeVisit v JOIN dbo.LabOrder o ON o.LabOrderId = v.LabOrderId
     WHERE v.BranchId = @BranchId AND v.ParentVisitId IS NULL AND o.PhlebotomistId IS NOT NULL
       AND v.PhlebotomistId <> o.PhlebotomistId AND v.Status IN ('ASSIGNED', 'ACCEPTED');

    INSERT dbo.LabHomeVisit (CompanyId, BranchId, LabOrderId, PatientId, PhlebotomistId, SlotAt, AddressSnapshot, Latitude, Longitude)
    SELECT b.CompanyId, o.BranchId, o.LabOrderId, o.PatientId, o.PhlebotomistId, o.BookingDate,
           LEFT(COALESCE(NULLIF(p.HomeCollectionAddress, N''), p.Address), 500), p.Latitude, p.Longitude
      FROM dbo.LabOrder o
      JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
      JOIN dbo.Branchmaster b ON b.BranchID = o.BranchId
     WHERE o.BranchId = @BranchId AND o.CollectionType = 'Home Collection' AND o.IsActive = 1 AND o.PhlebotomistId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.LabHomeVisit v WHERE v.LabOrderId = o.LabOrderId AND v.ParentVisitId IS NULL)
       AND EXISTS (SELECT 1 FROM dbo.SampleCollection sc
                    WHERE sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0
                      AND ISNULL(sc.CollectionstatusID, 1) IN (1, 3));
END
GO

-- The day's visits plus everything still open from earlier days; requests from the field come first.
CREATE OR ALTER PROCEDURE dbo.usp_Lab_HomeDispatch_List
    @BranchId INT,
    @Date     DATE = NULL,
    @Search   NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_Lab_HomeDispatch_Sync @BranchId = @BranchId;

    SET @Date = ISNULL(@Date, CAST(GETDATE() AS DATE));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');

    SELECT v.VisitId, v.LabOrderId, o.BillNo, v.Status, v.SlotAt, v.AddressSnapshot, v.PhlebotomistId, v.ParentVisitId, v.NeedsReview, v.OutcomeReason,
           ISNULL(u.FullName, u.Username) AS PhlebotomistName, o.IsUrgent,
           LTRIM(RTRIM(CONCAT(p.Salutation, N' ', p.FirstName, N' ', p.LastName))) AS PatientName, p.PhoneNumber,
           (SELECT COUNT(*) FROM dbo.SampleCollection sc WHERE sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0) AS Tests,
           CASE WHEN ISNULL(o.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(ph.BalanceDue, dbo.ufn_Phlebo_BillAmount(o.LabOrderId)) END AS BalanceDue,
           CASE WHEN v.Status IN ('UNAVAILABLE', 'RESCHEDULED') THEN 'ACTION'
                WHEN v.Status IN ('ASSIGNED', 'ACCEPTED') THEN 'WAITING'
                WHEN v.Status IN ('ON_THE_WAY', 'REACHED', 'IN_PROGRESS') THEN 'FIELD'
                WHEN v.Status IN ('COLLECTED', 'HANDED_OVER') THEN 'COLLECTED'
                ELSE 'DONE' END AS Grp,
           CAST(CASE WHEN v.Status IN ('ASSIGNED', 'ACCEPTED') AND v.SlotAt < GETDATE() THEN 1 ELSE 0 END AS BIT) AS IsLate,
           CAST(CASE WHEN v.Status IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'UNAVAILABLE', 'RESCHEDULED') THEN 1 ELSE 0 END AS BIT) AS CanChange,
           CAST(CASE WHEN v.Status IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'UNAVAILABLE', 'RESCHEDULED', 'CLOSED') THEN 1 ELSE 0 END AS BIT) AS CanReschedule
      FROM dbo.LabHomeVisit v
      JOIN dbo.LabOrder o ON o.LabOrderId = v.LabOrderId
      JOIN dbo.PatientMaster p ON p.PatientId = v.PatientId
      LEFT JOIN dbo.Users u ON u.Id = v.PhlebotomistId
      LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
     WHERE v.BranchId = @BranchId
       AND (CAST(v.SlotAt AS DATE) = @Date OR CAST(v.ModifiedDate AS DATE) = @Date
            OR v.Status IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'REACHED', 'IN_PROGRESS', 'UNAVAILABLE', 'RESCHEDULED', 'COLLECTED'))
       AND (@Search IS NULL OR o.BillNo LIKE N'%' + @Search + N'%' OR p.FirstName LIKE N'%' + @Search + N'%' OR p.LastName LIKE N'%' + @Search + N'%' OR p.PhoneNumber LIKE N'%' + @Search + N'%')
     ORDER BY CASE WHEN v.Status IN ('UNAVAILABLE', 'RESCHEDULED') THEN 0 ELSE 1 END, o.IsUrgent DESC, v.SlotAt;
END
GO

-- Who can take a visit: active phlebotomists of the branch, with their duty state today and open work.
CREATE OR ALTER PROCEDURE dbo.usp_Lab_HomeDispatch_Phlebotomists
    @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    SELECT u.Id AS UserId, ISNULL(u.FullName, u.Username) AS Name, sm.ShiftName,
           CAST(CASE WHEN a.AttendanceId IS NOT NULL AND a.PunchOutAt IS NULL THEN 1 ELSE 0 END AS BIT) AS OnDuty,
           (SELECT COUNT(*) FROM dbo.LabHomeVisit v WHERE v.PhlebotomistId = u.Id AND v.Status IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'REACHED', 'IN_PROGRESS')) AS OpenVisits
      FROM dbo.Users u
      JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1
      LEFT JOIN dbo.ShiftMaster sm ON sm.ShiftMaster_ID = u.ShiftSlotId
      LEFT JOIN dbo.PhleboAttendance a ON a.UserId = u.Id AND a.DutyDate = @Today
     WHERE u.IsPhlebotomist = 1 AND u.IsActive = 1
     ORDER BY OnDuty DESC, Name;
END
GO

-- Assign or reassign. A new phlebotomist starts the door checks again.
CREATE OR ALTER PROCEDURE dbo.usp_Lab_HomeDispatch_Assign
    @VisitId        INT,
    @BranchId       INT,
    @PhlebotomistId INT,
    @Reason         NVARCHAR(300) = NULL,
    @UserId         INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Cur VARCHAR(15), @Old INT, @Order INT, @Parent INT;
    SELECT @Cur = Status, @Old = PhlebotomistId, @Order = LabOrderId, @Parent = ParentVisitId
      FROM dbo.LabHomeVisit WITH (UPDLOCK) WHERE VisitId = @VisitId AND BranchId = @BranchId;

    IF @Cur IS NULL BEGIN RAISERROR('This visit is not of your branch.', 16, 1); RETURN; END
    IF @Cur NOT IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'UNAVAILABLE', 'RESCHEDULED')
    BEGIN RAISERROR('This visit can no longer be reassigned.', 16, 1); RETURN; END
    IF @Old = @PhlebotomistId AND @Cur IN ('ASSIGNED', 'ACCEPTED') BEGIN RAISERROR('This phlebotomist already has the visit.', 16, 1); RETURN; END
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL BEGIN RAISERROR('Give a reason.', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.Users u JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1
                    WHERE u.Id = @PhlebotomistId AND u.IsPhlebotomist = 1 AND u.IsActive = 1)
    BEGIN RAISERROR('Choose an active phlebotomist of this branch.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
        UPDATE dbo.LabHomeVisit
           SET PhlebotomistId = @PhlebotomistId, Status = 'ASSIGNED', OutcomeReason = NULL, OtpHash = NULL, OtpExpiresOn = NULL, OtpVerifiedOn = NULL,
               VerifyMethod = NULL, ConsentTaken = 0, ModifiedDate = GETDATE()
         WHERE VisitId = @VisitId;
        IF @Parent IS NULL
            UPDATE dbo.LabOrder SET PhlebotomistId = @PhlebotomistId, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE LabOrderId = @Order;
        INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, Reason, CreatedBy)
        VALUES (@VisitId, 'REASSIGNED', CONCAT('WEB-', NEWID()), @Reason, @UserId);
    COMMIT;
END
GO

-- A new slot, and optionally a new phlebotomist. Also brings a closed visit back.
CREATE OR ALTER PROCEDURE dbo.usp_Lab_HomeDispatch_Reschedule
    @VisitId        INT,
    @BranchId       INT,
    @SlotAt         DATETIME,
    @PhlebotomistId INT = NULL,
    @Reason         NVARCHAR(300) = NULL,
    @UserId         INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Cur VARCHAR(15), @Order INT, @Parent INT;
    SELECT @Cur = Status, @Order = LabOrderId, @Parent = ParentVisitId
      FROM dbo.LabHomeVisit WITH (UPDLOCK) WHERE VisitId = @VisitId AND BranchId = @BranchId;

    IF @Cur IS NULL BEGIN RAISERROR('This visit is not of your branch.', 16, 1); RETURN; END
    IF @Cur NOT IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'UNAVAILABLE', 'RESCHEDULED', 'CLOSED')
    BEGIN RAISERROR('This visit can no longer be rescheduled.', 16, 1); RETURN; END
    IF @SlotAt IS NULL OR @SlotAt < DATEADD(MINUTE, -5, GETDATE()) BEGIN RAISERROR('Choose a slot in the future.', 16, 1); RETURN; END
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL BEGIN RAISERROR('Give a reason.', 16, 1); RETURN; END
    IF @PhlebotomistId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dbo.Users u JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1
         WHERE u.Id = @PhlebotomistId AND u.IsPhlebotomist = 1 AND u.IsActive = 1)
    BEGIN RAISERROR('Choose an active phlebotomist of this branch.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
        UPDATE dbo.LabHomeVisit
           SET SlotAt = @SlotAt, PhlebotomistId = ISNULL(@PhlebotomistId, PhlebotomistId), Status = 'ASSIGNED', OutcomeReason = NULL,
               OtpHash = NULL, OtpExpiresOn = NULL, OtpVerifiedOn = NULL, VerifyMethod = NULL, ConsentTaken = 0, ModifiedDate = GETDATE()
         WHERE VisitId = @VisitId;
        IF @PhlebotomistId IS NOT NULL AND @Parent IS NULL
            UPDATE dbo.LabOrder SET PhlebotomistId = @PhlebotomistId, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE LabOrderId = @Order;
        INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, Reason, CreatedBy)
        VALUES (@VisitId, 'RESCHEDULED', CONCAT('WEB-', NEWID()), @Reason, @UserId);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Lab_HomeDispatch_Close
    @VisitId  INT,
    @BranchId INT,
    @Reason   NVARCHAR(300) = NULL,
    @UserId   INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Cur VARCHAR(15);
    SELECT @Cur = Status FROM dbo.LabHomeVisit WITH (UPDLOCK) WHERE VisitId = @VisitId AND BranchId = @BranchId;

    IF @Cur IS NULL BEGIN RAISERROR('This visit is not of your branch.', 16, 1); RETURN; END
    IF @Cur NOT IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'UNAVAILABLE', 'RESCHEDULED')
    BEGIN RAISERROR('This visit can no longer be closed.', 16, 1); RETURN; END
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL BEGIN RAISERROR('Give a reason.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
        UPDATE dbo.LabHomeVisit SET Status = 'CLOSED', OutcomeReason = @Reason, ModifiedDate = GETDATE() WHERE VisitId = @VisitId;
        INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, Reason, CreatedBy)
        VALUES (@VisitId, 'CLOSED', CONCAT('WEB-', NEWID()), @Reason, @UserId);
    COMMIT;
END
GO

-- ── page and endpoints ──────────────────────────────────────────────────────────────────────────────
DECLARE @co INT, @lab INT, @page INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @lab = NULL;
    SELECT @lab = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'LAB' AND CompanyId = @co;
    IF @lab IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @lab, @Page_Code = N'LAB.HOMEDISPATCH', @Title = N'Home Collection Dispatch',
             @Controller = N'LabHomeDispatch', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 35, @Icon = N'bi bi-truck me-2 text-primary',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabHomeDispatch', @Action = N'Index',      @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabHomeDispatch', @Action = N'Visits',     @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabHomeDispatch', @Action = N'Assign',     @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabHomeDispatch', @Action = N'Reschedule', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabHomeDispatch', @Action = N'Close',      @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
