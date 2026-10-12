-- ============================================================================================================
-- Migration: 2263_user_notifications.sql
-- In-app notifications (the bell in the top bar), pushed live to the signed-in user (SignalR) with a 60-second
-- fallback check when the live connection is down.
--   dbo.UserNotification          one row per recipient; EventKey makes an event notify a user once only
--   usp_Notification_List         a user's notifications (newest first, paged) + unread count
--   usp_Notification_MarkRead     one / all of a user's notifications read
--   usp_Notification_Dismiss      removes one from the user's list (kept for audit)
--   usp_Notification_DiscountApproval
--                                 first event: a bill saved with a discount notifies the user chosen as
--                                 "Approved by" (not when the person billing approved it themselves)
-- Every read / change is limited to the user's own rows (@UserId comes from the login, never from the page).
-- Run after 2262. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.UserNotification', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserNotification
    (
        NotificationId BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_UserNotification PRIMARY KEY,
        CompanyId      INT            NULL,
        BranchId       INT            NULL,
        UserId         INT            NOT NULL,                 -- recipient
        Category       VARCHAR(30)    NOT NULL,                 -- DISCOUNT_APPROVAL, ...
        Severity       VARCHAR(10)    NOT NULL CONSTRAINT DF_UserNotification_Severity DEFAULT ('INFO'),   -- INFO / WARNING / CRITICAL
        Title          NVARCHAR(200)  NOT NULL,
        Message        NVARCHAR(1000) NOT NULL,
        Link           NVARCHAR(500)  NULL,
        RefModule      VARCHAR(20)    NULL,
        RefId          BIGINT         NULL,
        EventKey       VARCHAR(120)   NULL,                     -- one notification per event and user
        CreatedBy      INT            NULL,
        CreatedOn      DATETIME2(0)   NOT NULL CONSTRAINT DF_UserNotification_CreatedOn DEFAULT (SYSDATETIME()),
        IsRead         BIT            NOT NULL CONSTRAINT DF_UserNotification_IsRead DEFAULT (0),
        ReadOn         DATETIME2(0)   NULL,
        IsDismissed    BIT            NOT NULL CONSTRAINT DF_UserNotification_IsDismissed DEFAULT (0),
        DismissedOn    DATETIME2(0)   NULL,
        CONSTRAINT CK_UserNotification_Severity CHECK (Severity IN ('INFO', 'WARNING', 'CRITICAL'))
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_UserNotification_Inbox' AND object_id = OBJECT_ID('dbo.UserNotification'))
    CREATE INDEX IX_UserNotification_Inbox ON dbo.UserNotification (UserId, IsDismissed, NotificationId DESC) INCLUDE (IsRead);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_UserNotification_Event' AND object_id = OBJECT_ID('dbo.UserNotification'))
    CREATE UNIQUE INDEX UX_UserNotification_Event ON dbo.UserNotification (UserId, EventKey) WHERE EventKey IS NOT NULL;
GO

-- ── a user's notifications: newest first, @BeforeId pages back; RS1 rows, RS2 unread count ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Notification_List
    @UserId     INT,
    @Top        INT    = 15,
    @BeforeId   BIGINT = NULL,
    @UnreadOnly BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @Top IS NULL OR @Top < 1 SET @Top = 15;
    IF @Top > 100 SET @Top = 100;

    SELECT TOP (@Top) n.NotificationId, n.Category, n.Severity, n.Title, n.Message, n.Link, n.RefModule, n.RefId,
           n.CreatedOn, n.IsRead, n.ReadOn,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS CreatedByName
    FROM dbo.UserNotification n
    LEFT JOIN dbo.Users u ON u.Id = n.CreatedBy
    WHERE n.UserId = @UserId AND n.IsDismissed = 0
      AND (@BeforeId IS NULL OR n.NotificationId < @BeforeId)
      AND (ISNULL(@UnreadOnly, 0) = 0 OR n.IsRead = 0)
    ORDER BY n.NotificationId DESC;

    SELECT COUNT(1) AS UnreadCount FROM dbo.UserNotification WHERE UserId = @UserId AND IsDismissed = 0 AND IsRead = 0;
END;
GO

-- ── read: one (@NotificationId) or all of the user's; returns the unread count left ────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Notification_MarkRead
    @UserId         INT,
    @NotificationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.UserNotification SET IsRead = 1, ReadOn = SYSDATETIME()
    WHERE UserId = @UserId AND IsRead = 0 AND IsDismissed = 0
      AND (@NotificationId IS NULL OR NotificationId = @NotificationId);

    SELECT COUNT(1) AS UnreadCount FROM dbo.UserNotification WHERE UserId = @UserId AND IsDismissed = 0 AND IsRead = 0;
END;
GO

-- ── dismiss: off the user's list (the row stays for audit); returns the unread count left ──────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Notification_Dismiss
    @UserId         INT,
    @NotificationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.UserNotification SET IsDismissed = 1, DismissedOn = SYSDATETIME(),
           IsRead = 1, ReadOn = ISNULL(ReadOn, SYSDATETIME())
    WHERE UserId = @UserId AND NotificationId = @NotificationId AND IsDismissed = 0;

    SELECT COUNT(1) AS UnreadCount FROM dbo.UserNotification WHERE UserId = @UserId AND IsDismissed = 0 AND IsRead = 0;
END;
GO

-- ── event: a bill with a discount -> the user chosen as "Approved by" ─────────────────────────────────────────
-- Returns the new notification (to push live), or nothing when there is nothing to send: no discount / approver,
-- the approver is the person who billed, the approver is inactive, or this bill already notified this approver.
CREATE OR ALTER PROCEDURE dbo.usp_Notification_DiscountApproval
    @PaymentHeaderId INT,
    @ActorUserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Module VARCHAR(10), @RefId INT, @BranchId INT, @PatientId INT, @Approver INT,
            @Discount DECIMAL(18, 2), @SubTotal DECIMAL(18, 2), @Net DECIMAL(18, 2), @Reason NVARCHAR(500);

    SELECT @Module = ph.ModuleCode, @RefId = COALESCE(CASE WHEN ph.ModuleCode = 'OPD' THEN ph.OPDServiceId END, ph.ModuleRefId),
           @BranchId = ph.BranchId, @PatientId = ph.PatientId, @Approver = ph.DiscountApprovedBy,
           @Discount = ph.HeaderDiscountAmount, @SubTotal = ph.SubTotal, @Net = ph.NetAmount, @Reason = ph.DiscountReason
    FROM dbo.PaymentHeader ph
    WHERE ph.PaymentHeaderId = @PaymentHeaderId AND ph.IsActive = 1;

    IF @Approver IS NULL OR ISNULL(@Discount, 0) <= 0 RETURN;
    IF @Approver = ISNULL(@ActorUserId, -1) RETURN;   -- approved by the person billing: nobody else to tell
    IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @Approver AND IsActive = 1) RETURN;

    DECLARE @EventKey VARCHAR(120) = 'DISCOUNT_APPROVAL:' + CAST(@PaymentHeaderId AS VARCHAR(20));
    IF EXISTS (SELECT 1 FROM dbo.UserNotification WHERE UserId = @Approver AND EventKey = @EventKey) RETURN;

    DECLARE @BillNo NVARCHAR(50), @Link NVARCHAR(500);
    IF @Module = 'LAB'
        SELECT @BillNo = lo.BillNo, @Link = N'/LabOrderBooking/PrintBill?labOrderId=' + CAST(lo.LabOrderId AS NVARCHAR(20))
        FROM dbo.LabOrder lo WHERE lo.LabOrderId = @RefId;
    ELSE IF @Module = 'OPD'
        SELECT @BillNo = s.OPDBillNo, @Link = N'/OPD/PrintBill/' + CAST(s.OPDServiceId AS NVARCHAR(20))
        FROM dbo.PatientOPDService s WHERE s.OPDServiceId = @RefId;

    DECLARE @Patient NVARCHAR(300) = (
        SELECT LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, '')))
               + ISNULL(N' (' + NULLIF(p.PatientCode, '') + N')', N'')
        FROM dbo.PatientMaster p WHERE p.PatientId = @PatientId);
    DECLARE @Actor NVARCHAR(200) = (SELECT ISNULL(NULLIF(LTRIM(RTRIM(FullName)), ''), Username) FROM dbo.Users WHERE Id = @ActorUserId);
    DECLARE @Pct DECIMAL(9, 1) = CASE WHEN @SubTotal > 0 THEN @Discount * 100.0 / @SubTotal END;

    DECLARE @Title NVARCHAR(200) = N'Discount approved in your name' + ISNULL(N' · ' + @BillNo, N'');
    DECLARE @Message NVARCHAR(1000) = LEFT(
          N'₹' + FORMAT(@Discount, 'N2') + ISNULL(N' (' + FORMAT(@Pct, '0.#') + N'%)', N'') + N' discount on '
        + ISNULL(@Module + N' bill ' + @BillNo, N'a ' + ISNULL(@Module, N'') + N' bill')
        + ISNULL(N' for ' + NULLIF(@Patient, N''), N'')
        + N'. Bill ₹' + FORMAT(ISNULL(@SubTotal, 0), 'N2') + N', net ₹' + FORMAT(ISNULL(@Net, 0), 'N2') + N'.'
        + ISNULL(N' Reason: ' + NULLIF(LTRIM(RTRIM(@Reason)), N'') + N'.', N'')
        + ISNULL(N' Billed by ' + @Actor + N'.', N''), 1000);

    DECLARE @Out TABLE (NotificationId BIGINT, UserId INT, Category VARCHAR(30), Severity VARCHAR(10), Title NVARCHAR(200),
                        Message NVARCHAR(1000), Link NVARCHAR(500), RefModule VARCHAR(20), RefId BIGINT, CreatedOn DATETIME2(0));
    BEGIN TRY
        INSERT INTO dbo.UserNotification (CompanyId, BranchId, UserId, Category, Severity, Title, Message, Link, RefModule, RefId, EventKey, CreatedBy)
        OUTPUT inserted.NotificationId, inserted.UserId, inserted.Category, inserted.Severity, inserted.Title, inserted.Message,
               inserted.Link, inserted.RefModule, inserted.RefId, inserted.CreatedOn INTO @Out
        SELECT u.CompanyId, @BranchId, @Approver, 'DISCOUNT_APPROVAL', 'WARNING', @Title, @Message, @Link, @Module, @RefId, @EventKey, @ActorUserId
        FROM dbo.Users u WHERE u.Id = @Approver;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() IN (2601, 2627) RETURN;   -- the same event raced in from another request: already notified
        THROW;
    END CATCH

    SELECT o.*, (SELECT COUNT(1) FROM dbo.UserNotification WHERE UserId = @Approver AND IsDismissed = 0 AND IsRead = 0) AS UnreadCount
    FROM @Out o;
END;
GO

PRINT 'Script 2263 applied: user notifications (bell) and the discount-approval notification.';
GO
