-- ============================================================================================================
-- 2416  LAB > Home Collection Dispatch: a home collection booked without a phlebotomist (B2C bill page) is listed as
--   "Not assigned" and can be assigned here.
--   usp_Lab_HomeDispatch_List (live definition + 2416): such bookings come back with VisitId = minus the LabOrderId,
--     Status UNASSIGNED, group ACTION (Needs action).
--   usp_Lab_HomeDispatch_Assign (live definition + 2416): a minus VisitId sets the booking's phlebotomist and makes its
--     visit (usp_Lab_HomeDispatch_Sync), so it reaches the phlebotomist's app.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
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
           CAST(CASE WHEN v.Status IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'UNAVAILABLE', 'RESCHEDULED', 'CLOSED') THEN 1 ELSE 0 END AS BIT) AS CanReschedule,
           CASE WHEN v.Status IN ('UNAVAILABLE', 'RESCHEDULED') THEN 0 ELSE 1 END AS SortKey
      FROM dbo.LabHomeVisit v
      JOIN dbo.LabOrder o ON o.LabOrderId = v.LabOrderId
      JOIN dbo.PatientMaster p ON p.PatientId = v.PatientId
      LEFT JOIN dbo.Users u ON u.Id = v.PhlebotomistId
      LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
     WHERE v.BranchId = @BranchId
       AND (CAST(v.SlotAt AS DATE) = @Date OR CAST(v.ModifiedDate AS DATE) = @Date
            OR v.Status IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'REACHED', 'IN_PROGRESS', 'UNAVAILABLE', 'RESCHEDULED', 'COLLECTED'))
       AND (@Search IS NULL OR o.BillNo LIKE N'%' + @Search + N'%' OR p.FirstName LIKE N'%' + @Search + N'%' OR p.LastName LIKE N'%' + @Search + N'%' OR p.PhoneNumber LIKE N'%' + @Search + N'%')
    -- 2416: a home collection booked without a phlebotomist has no visit yet; it is listed as Not assigned (VisitId =
    -- minus the LabOrderId) so the office can assign it here; Assign then makes the visit
    UNION ALL
    SELECT -o.LabOrderId, o.LabOrderId, o.BillNo, 'UNASSIGNED', o.BookingDate, LEFT(COALESCE(NULLIF(p.HomeCollectionAddress, N''), p.Address), 500),
           NULL, NULL, CAST(0 AS BIT), NULL, N'Not assigned', o.IsUrgent,
           LTRIM(RTRIM(CONCAT(p.Salutation, N' ', p.FirstName, N' ', p.LastName))), p.PhoneNumber,
           (SELECT COUNT(*) FROM dbo.SampleCollection sc WHERE sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0),
           CASE WHEN ISNULL(o.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(ph.BalanceDue, dbo.ufn_Phlebo_BillAmount(o.LabOrderId)) END,
           'ACTION', CAST(CASE WHEN o.BookingDate < GETDATE() THEN 1 ELSE 0 END AS BIT), CAST(1 AS BIT), CAST(0 AS BIT), 0
      FROM dbo.LabOrder o
      JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
      LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
     WHERE o.BranchId = @BranchId AND o.CollectionType = 'Home Collection' AND o.IsActive = 1 AND o.PhlebotomistId IS NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.LabHomeVisit v WHERE v.LabOrderId = o.LabOrderId)
       AND EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0
                      AND ISNULL(sc.CollectionstatusID, 1) IN (1, 3))
       AND (@Search IS NULL OR o.BillNo LIKE N'%' + @Search + N'%' OR p.FirstName LIKE N'%' + @Search + N'%' OR p.LastName LIKE N'%' + @Search + N'%' OR p.PhoneNumber LIKE N'%' + @Search + N'%')
     ORDER BY SortKey, IsUrgent DESC, SlotAt;
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

    -- 2416: a booking without a phlebotomist (listed with VisitId = minus its LabOrderId) gets one, and its visit is made
    IF @VisitId < 0
    BEGIN
        DECLARE @NewOrder INT = -@VisitId;
        IF NOT EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @NewOrder AND BranchId = @BranchId AND CollectionType = 'Home Collection' AND IsActive = 1)
        BEGIN RAISERROR('This booking is not an open home collection of your branch.', 16, 1); RETURN; END
        IF EXISTS (SELECT 1 FROM dbo.LabHomeVisit WHERE LabOrderId = @NewOrder) BEGIN RAISERROR('This booking already has a visit. Refresh the list.', 16, 1); RETURN; END
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL BEGIN RAISERROR('Give a reason.', 16, 1); RETURN; END
        IF NOT EXISTS (SELECT 1 FROM dbo.Users u JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1
                        WHERE u.Id = @PhlebotomistId AND u.IsPhlebotomist = 1 AND u.IsActive = 1)
        BEGIN RAISERROR('Choose an active phlebotomist of this branch.', 16, 1); RETURN; END

        BEGIN TRANSACTION;
            UPDATE dbo.LabOrder SET PhlebotomistId = @PhlebotomistId, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE LabOrderId = @NewOrder;
            EXEC dbo.usp_Lab_HomeDispatch_Sync @BranchId = @BranchId;
            INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, Reason, CreatedBy)
            SELECT VisitId, 'REASSIGNED', CONCAT('WEB-', NEWID()), @Reason, @UserId FROM dbo.LabHomeVisit WHERE LabOrderId = @NewOrder AND ParentVisitId IS NULL;
        COMMIT;
        RETURN;
    END

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
PRINT 'Script 2416 applied: unassigned home collections on Dispatch.';
GO
