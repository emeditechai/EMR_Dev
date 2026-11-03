-- ============================================================================================================
-- Migration: 2397_audit_notification_setup.sql
-- Settings > Audit Notification Setup: WhatsApp alerts of sensitive actions to chosen users (their User Master mobile),
-- event by event, per BRANCH: each branch switches its own alerts on and chooses its own users (from the users of the
-- branch); an alert goes to the users of the branch of the bill.
--   AuditNotifyEvent          : the events (seeded) - LAB bill cancelled, LAB refund, OPD bill cancelled, OPD refund,
--                               LAB report un-authorised (un-approved)
--   AuditNotifyEventSetting   : per branch, an event switched on / off
--   AuditNotifyRecipient      : per branch and event, the users who get the alert
--   AuditNotifyLog            : every alert sent / failed / skipped (no mobile)
--   Procedures: usp_AuditNotify_GetSetup / usp_AuditNotify_SaveEvent (the page), usp_AuditNotify_GetRecipients,
--   usp_AuditNotify_Context (bill, patient, branch of a LAB / OPD bill), usp_AuditNotify_Log (the sender).
--   Page SETTINGS.AUDITNOTIFICATION (VIEW = the page, EDIT = save / test). No role is granted here.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.AuditNotifyEvent', 'U') IS NULL
CREATE TABLE dbo.AuditNotifyEvent
(
    EventCode   VARCHAR(40)    NOT NULL CONSTRAINT PK_AuditNotifyEvent PRIMARY KEY,
    Module      VARCHAR(10)    NOT NULL,
    Title       NVARCHAR(100)  NOT NULL,
    Description NVARCHAR(400)  NULL,
    Icon        VARCHAR(60)    NULL,
    SortOrder   INT            NOT NULL CONSTRAINT DF_AuditNotifyEvent_Sort DEFAULT (0),
    IsActive    BIT            NOT NULL CONSTRAINT DF_AuditNotifyEvent_Active DEFAULT (1)
);
GO
IF OBJECT_ID('dbo.AuditNotifyEventSetting', 'U') IS NULL
CREATE TABLE dbo.AuditNotifyEventSetting
(
    CompanyId    INT          NOT NULL,
    BranchId     INT          NOT NULL,
    EventCode    VARCHAR(40)  NOT NULL CONSTRAINT FK_AuditNotifyEventSetting_Event REFERENCES dbo.AuditNotifyEvent (EventCode),
    IsEnabled    BIT          NOT NULL CONSTRAINT DF_AuditNotifyEventSetting_Enabled DEFAULT (1),
    ModifiedBy   INT          NULL,
    ModifiedDate DATETIME     NOT NULL CONSTRAINT DF_AuditNotifyEventSetting_Modified DEFAULT (GETDATE()),
    CONSTRAINT PK_AuditNotifyEventSetting PRIMARY KEY (BranchId, EventCode)
);
GO
IF OBJECT_ID('dbo.AuditNotifyRecipient', 'U') IS NULL
CREATE TABLE dbo.AuditNotifyRecipient
(
    RecipientId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditNotifyRecipient PRIMARY KEY,
    CompanyId   INT          NOT NULL,
    BranchId    INT          NOT NULL,
    EventCode   VARCHAR(40)  NOT NULL CONSTRAINT FK_AuditNotifyRecipient_Event REFERENCES dbo.AuditNotifyEvent (EventCode),
    UserId      INT          NOT NULL,
    CreatedBy   INT          NULL,
    CreatedDate DATETIME     NOT NULL CONSTRAINT DF_AuditNotifyRecipient_Created DEFAULT (GETDATE()),
    CONSTRAINT UQ_AuditNotifyRecipient UNIQUE (BranchId, EventCode, UserId)
);
GO
IF OBJECT_ID('dbo.AuditNotifyLog', 'U') IS NULL
CREATE TABLE dbo.AuditNotifyLog
(
    LogId       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditNotifyLog PRIMARY KEY,
    CompanyId   INT            NOT NULL,
    BranchId    INT            NULL,
    EventCode   VARCHAR(40)    NOT NULL,
    RefNo       NVARCHAR(60)   NULL,
    UserId      INT            NULL,
    Phone       NVARCHAR(30)   NULL,
    Status      VARCHAR(20)    NOT NULL,   -- Sent / Failed / Skipped
    Detail      NVARCHAR(500)  NULL,
    Message     NVARCHAR(MAX)  NULL,
    TriggeredBy INT            NULL,
    CreatedDate DATETIME       NOT NULL CONSTRAINT DF_AuditNotifyLog_Created DEFAULT (GETDATE())
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AuditNotifyLog_Company_Date')
    CREATE INDEX IX_AuditNotifyLog_Company_Date ON dbo.AuditNotifyLog (CompanyId, BranchId, CreatedDate DESC);
GO

MERGE dbo.AuditNotifyEvent AS t
USING (VALUES
    ('LAB_BILL_CANCEL',  'LAB', N'LAB bill cancelled',        N'A LAB bill is cancelled, in full or some of its tests.',                 'bi-x-octagon',        10),
    ('LAB_REFUND',       'LAB', N'LAB refund',                N'Money is refunded against a cancelled LAB bill / tests.',                'bi-cash-coin',        20),
    ('OPD_BILL_CANCEL',  'OPD', N'OPD bill cancelled',        N'An OPD bill is cancelled, in full or some of its services.',            'bi-x-octagon',        30),
    ('OPD_REFUND',       'OPD', N'OPD refund',                N'Money is refunded against a cancelled OPD bill.',                       'bi-cash-coin',        40),
    ('LAB_REPORT_UNAUTH','LAB', N'LAB report un-authorised',  N'Approved test results are withdrawn (un-approved) for re-test or re-collection.', 'bi-shield-x', 50)
) AS s (EventCode, Module, Title, Description, Icon, SortOrder) ON t.EventCode = s.EventCode
WHEN MATCHED THEN UPDATE SET Module = s.Module, Title = s.Title, Description = s.Description, Icon = s.Icon, SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT (EventCode, Module, Title, Description, Icon, SortOrder) VALUES (s.EventCode, s.Module, s.Title, s.Description, s.Icon, s.SortOrder);
GO

-- the page, for one branch: RS1 events (switch + recipient count), RS2 recipients, RS3 users of the branch to choose from
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_GetSetup
    @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.EventCode, e.Module, e.Title, e.Description, e.Icon, e.SortOrder,
           CAST(ISNULL(s.IsEnabled, 0) AS BIT) AS IsEnabled,
           (SELECT COUNT(*) FROM dbo.AuditNotifyRecipient r JOIN dbo.Users u ON u.Id = r.UserId AND u.IsActive = 1
             WHERE r.BranchId = @BranchId AND r.EventCode = e.EventCode) AS RecipientCount,
           s.ModifiedDate
      FROM dbo.AuditNotifyEvent e
      LEFT JOIN dbo.AuditNotifyEventSetting s ON s.BranchId = @BranchId AND s.EventCode = e.EventCode
     WHERE e.IsActive = 1
     ORDER BY e.SortOrder;

    SELECT r.EventCode, r.UserId
      FROM dbo.AuditNotifyRecipient r JOIN dbo.Users u ON u.Id = r.UserId AND u.IsActive = 1
     WHERE r.BranchId = @BranchId;

    SELECT u.Id AS UserId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Name, u.Username,
           COALESCE(NULLIF(LTRIM(RTRIM(u.PhoneNumber)), ''), NULLIF(LTRIM(RTRIM(u.Phone)), '')) AS Mobile,
           (SELECT b.BranchName FROM dbo.Branchmaster b WHERE b.BranchID = @BranchId) AS BranchName
      FROM dbo.Users u
     WHERE u.IsActive = 1 AND ISNULL(u.CompanyId, @CompanyId) = @CompanyId
       AND EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1)
     ORDER BY Name;
END
GO

-- saves one event: its switch and its recipients (the list replaces the old one)
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_SaveEvent
    @CompanyId INT, @BranchId INT, @EventCode VARCHAR(40), @IsEnabled BIT, @UserIds VARCHAR(MAX) = NULL, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.AuditNotifyEvent WHERE EventCode = @EventCode AND IsActive = 1)
    BEGIN RAISERROR('Unknown event.', 16, 1); RETURN; END

    DECLARE @Ids TABLE (UserId INT PRIMARY KEY);
    INSERT @Ids (UserId)
    SELECT DISTINCT u.Id FROM STRING_SPLIT(ISNULL(@UserIds, ''), ',') x
      JOIN dbo.Users u ON u.Id = TRY_CAST(LTRIM(RTRIM(x.value)) AS INT) AND u.IsActive = 1
      JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1;

    IF @IsEnabled = 1 AND NOT EXISTS (SELECT 1 FROM @Ids)
    BEGIN RAISERROR('Choose at least one user to switch this alert on.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
        MERGE dbo.AuditNotifyEventSetting AS t
        USING (SELECT @BranchId AS BranchId, @EventCode AS EventCode) AS s ON t.BranchId = s.BranchId AND t.EventCode = s.EventCode
        WHEN MATCHED THEN UPDATE SET IsEnabled = @IsEnabled, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHEN NOT MATCHED THEN INSERT (CompanyId, BranchId, EventCode, IsEnabled, ModifiedBy) VALUES (@CompanyId, @BranchId, @EventCode, @IsEnabled, @UserId);

        DELETE r FROM dbo.AuditNotifyRecipient r
         WHERE r.BranchId = @BranchId AND r.EventCode = @EventCode AND r.UserId NOT IN (SELECT UserId FROM @Ids);
        INSERT dbo.AuditNotifyRecipient (CompanyId, BranchId, EventCode, UserId, CreatedBy)
        SELECT @CompanyId, @BranchId, @EventCode, i.UserId, @UserId FROM @Ids i
         WHERE NOT EXISTS (SELECT 1 FROM dbo.AuditNotifyRecipient r WHERE r.BranchId = @BranchId AND r.EventCode = @EventCode AND r.UserId = i.UserId);
    COMMIT;
END
GO

-- who gets an alert now: the event is on for the bill's branch and the user is active (Mobile NULL = skipped, logged)
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_GetRecipients
    @BranchId INT, @EventCode VARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id AS UserId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Name,
           COALESCE(NULLIF(LTRIM(RTRIM(u.PhoneNumber)), ''), NULLIF(LTRIM(RTRIM(u.Phone)), '')) AS Mobile
      FROM dbo.AuditNotifyEventSetting s
      JOIN dbo.AuditNotifyRecipient r ON r.BranchId = s.BranchId AND r.EventCode = s.EventCode
      JOIN dbo.Users u ON u.Id = r.UserId AND u.IsActive = 1
     WHERE s.BranchId = @BranchId AND s.EventCode = @EventCode AND s.IsEnabled = 1;
END
GO

-- the bill an alert is about: LAB order or OPD service - bill no, patient, branch, company
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_Context
    @ModuleCode VARCHAR(10), @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @ModuleCode = 'LAB'
        SELECT lo.BillNo, lo.TokenNo, p.PatientCode,
               LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
               lo.BranchId, b.BranchName, b.CompanyId,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType
          FROM dbo.LabOrder lo
          JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
          LEFT JOIN dbo.Branchmaster b ON b.BranchID = lo.BranchId
         WHERE lo.LabOrderId = @ModuleRefId;
    ELSE
        SELECT s.OPDBillNo AS BillNo, s.TokenNo, p.PatientCode,
               LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
               s.BranchId, b.BranchName, b.CompanyId, 'OPD' AS BillingType
          FROM dbo.PatientOPDService s
          JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
          LEFT JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId
         WHERE s.OPDServiceId = @ModuleRefId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_Log
    @CompanyId INT, @BranchId INT = NULL, @EventCode VARCHAR(40), @RefNo NVARCHAR(60) = NULL, @UserId INT = NULL,
    @Phone NVARCHAR(30) = NULL, @Status VARCHAR(20), @Detail NVARCHAR(500) = NULL, @Message NVARCHAR(MAX) = NULL, @TriggeredBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.AuditNotifyLog (CompanyId, BranchId, EventCode, RefNo, UserId, Phone, Status, Detail, Message, TriggeredBy)
    VALUES (@CompanyId, @BranchId, @EventCode, @RefNo, @UserId, @Phone, @Status, LEFT(@Detail, 500), @Message, @TriggeredBy);
END
GO

-- a cancellation, for its alert: type, number, amounts, reason and the names of the cancelled items (LAB tests /
-- packages / misc charges, OPD services)
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_Cancellation
    @CancellationId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT bc.CancellationId, bc.CancellationNo, bc.ModuleCode, bc.ModuleRefId,
           CASE WHEN bc.CancellationType LIKE 'F%' THEN 'Full' ELSE 'Partial' END AS CancellationType,
           CAST(bc.CancelledAmount AS DECIMAL(18, 2)) AS CancelledAmount, CAST(ISNULL(bc.DiscountAdjusted, 0) AS DECIMAL(18, 2)) AS DiscountAdjusted,
           NULLIF(LTRIM(RTRIM(bc.Reason)), '') AS Reason,
           (SELECT STRING_AGG(CAST(x.Name AS NVARCHAR(MAX)), ', ') FROM (
                SELECT COALESCE(h.Profile_Name, m.Test_Name, mc.ChargeName, sm.ItemName, si.ServiceType, N'item') AS Name
                  FROM dbo.BillCancellationItem ci
                  LEFT JOIN dbo.LabOrderItem li ON bc.ModuleCode = 'LAB' AND ci.LineRefId > 0 AND li.LabOrderItemId = ci.LineRefId
                  LEFT JOIN dbo.LabInvestigationMaster m ON li.[Type] <> 'P' AND m.Test_ID = li.InvestigationId
                  LEFT JOIN dbo.LabInvestigationProfileHeader h ON li.[Type] = 'P' AND h.Profile_ID = li.InvestigationId
                  LEFT JOIN dbo.LabOrderMiscCharge mc ON bc.ModuleCode = 'LAB' AND ci.LineRefId < 0 AND mc.LabOrderMiscChargeId = -ci.LineRefId
                  LEFT JOIN dbo.PatientOPDServiceItem si ON bc.ModuleCode = 'OPD' AND si.ItemId = ci.LineRefId
                  LEFT JOIN dbo.ServiceMaster sm ON sm.ServiceId = si.ServiceId
                 WHERE ci.CancellationId = bc.CancellationId AND ISNULL(ci.IsActive, 1) = 1) x) AS ItemNames
      FROM dbo.BillCancellation bc
     WHERE bc.CancellationId = @CancellationId;
END
GO

-- the last alerts, for the page
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_RecentLog
    @CompanyId INT, @BranchId INT, @Top INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) l.LogId, l.EventCode, e.Title AS EventTitle, l.RefNo, l.Status, l.Detail, l.Phone, l.CreatedDate,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS RecipientName, br.BranchName
      FROM dbo.AuditNotifyLog l
      LEFT JOIN dbo.AuditNotifyEvent e ON e.EventCode = l.EventCode
      LEFT JOIN dbo.Users u ON u.Id = l.UserId
      LEFT JOIN dbo.Branchmaster br ON br.BranchID = l.BranchId
     WHERE l.CompanyId = @CompanyId AND l.BranchId = @BranchId
     ORDER BY l.CreatedDate DESC, l.LogId DESC;
END
GO

-- Page under Settings
DECLARE @co INT, @menu INT, @page INT, @view INT, @edit INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'SETTINGS' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'SETTINGS.AUDITNOTIFICATION',
             @Title = N'Audit Notification Setup', @Controller = N'AuditNotificationSetup', @Action = N'Index',
             @Show_In_Menu = 1, @Sort_Order = 60, @Icon = N'bi bi-bell me-2', @Page_ID = @page OUTPUT;
        SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        SET @edit = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Save alerts / send test', @Sort_Order = 20, @Control_ID = @edit OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'AuditNotificationSetup', @Action = N'Index',    @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'AuditNotificationSetup', @Action = N'Data',     @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @edit, @App = 'WEB', @Http_Method = 'POST', @Controller = N'AuditNotificationSetup', @Action = N'Save',     @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @edit, @App = 'WEB', @Http_Method = 'POST', @Controller = N'AuditNotificationSetup', @Action = N'SendTest', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2397 applied: Settings > Audit Notification Setup (WhatsApp alerts of cancellations, refunds, report un-authorisation).';
GO
