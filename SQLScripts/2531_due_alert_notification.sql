-- ============================================================================================================
-- Migration: 2531_due_alert_notification.sql   (application database; needs 2397, 2528 and 2529)
-- Settings > Audit Notification Setup > Due Alert: a new area with two events -
--   OPD_DUE_ALERT  Due Alert for OPD      : OPD bills that still have a due
--   LAB_DUE_ALERT  Due Alert for B2C LAB  : LAB B2C bills that still have a due (B2B bills never)
-- Every day at the branch's send time (or "Send now" on the page) the users chosen for the event get, by WhatsApp and /
-- or e-mail, the bills of the branch whose due AS ON THAT DATE has reached the amount set on the page ("due of ₹ N or
-- more"): bill no, bill date, patient, due amount of each bill, and the total due. Due = net - paid (as the Outstanding
-- Dues reports count it).
-- Company wise and branch wise: the setting, its users and the bills are those of the branch signed in to; a branch is
-- saved only under its own company, and the due list reads only that company's branch.
--   AuditNotifyArea DUE_ALERT; AuditNotifyEvent (+ HasAmountThreshold) OPD_DUE_ALERT / LAB_DUE_ALERT;
--   AuditNotifyEventSetting (+ ThresholdAmount).
--   Procedures: usp_AuditNotify_GetSetup / usp_AuditNotify_SaveEvent (+ due amount, company check), usp_AuditNotify_DueList.
-- Scheduled sends, ALL areas (NotificationScheduleWorker, every minute): every daily event (AuditNotifyEvent.IsDaily) is
-- sent at its branch's send time - usp_AuditNotify_DailyEvents lists them, usp_AuditNotify_DailyDue (2528) claims the
-- branches due. Changing the send time to a later time today clears today's claim, so it goes at the new time. A run that
-- has nothing to send (no bill reached the amount, no doctor today) is written to the log (usp_AuditNotify_LogRun).
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('dbo.AuditNotifyArea', 'U') IS NULL OR COL_LENGTH('dbo.AuditNotifyEvent', 'HasThreshold') IS NULL
BEGIN
    RAISERROR('Script 2531 needs scripts 2397, 2528 and 2529 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('dbo.AuditNotifyEvent', 'HasAmountThreshold') IS NULL
    ALTER TABLE dbo.AuditNotifyEvent ADD HasAmountThreshold BIT NOT NULL CONSTRAINT DF_AuditNotifyEvent_AmountThreshold DEFAULT (0);
IF COL_LENGTH('dbo.AuditNotifyEventSetting', 'ThresholdAmount') IS NULL
    ALTER TABLE dbo.AuditNotifyEventSetting ADD ThresholdAmount DECIMAL(18, 2) NULL;
GO

MERGE dbo.AuditNotifyArea AS t
USING (VALUES ('DUE_ALERT', N'Due Alert',
               N'Every day at the send time: the OPD / LAB B2C bills whose due has reached the amount you set - bill no, patient and due amount as on that date - to the users you choose, by WhatsApp and e-mail.',
               'bi-cash-coin', 40)) AS s (AreaCode, Title, Description, Icon, SortOrder) ON t.AreaCode = s.AreaCode
WHEN MATCHED THEN UPDATE SET Title = s.Title, Description = s.Description, Icon = s.Icon, SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT (AreaCode, Title, Description, Icon, SortOrder) VALUES (s.AreaCode, s.Title, s.Description, s.Icon, s.SortOrder);
GO
MERGE dbo.AuditNotifyEvent AS t
USING (VALUES
    ('OPD_DUE_ALERT', 'OPD', 'DUE_ALERT', N'Due Alert for OPD',
     N'Every day at the send time: the OPD bills of this branch whose due has reached the amount set here - bill no, patient and due amount as on that date, with the total due.',
     'bi-cash-coin', 410, 1, 0, 1, 0, 1),
    ('LAB_DUE_ALERT', 'LAB', 'DUE_ALERT', N'Due Alert for B2C LAB',
     N'Every day at the send time: the LAB B2C bills of this branch whose due has reached the amount set here - bill no, patient and due amount as on that date, with the total due.',
     'bi-cash-coin', 420, 1, 0, 1, 0, 1)
) AS s (EventCode, Module, AreaCode, Title, Description, Icon, SortOrder, SupportsEmail, SupportsDoctor, IsDaily, HasThreshold, HasAmountThreshold)
ON t.EventCode = s.EventCode
WHEN MATCHED THEN UPDATE SET Module = s.Module, AreaCode = s.AreaCode, Title = s.Title, Description = s.Description, Icon = s.Icon, SortOrder = s.SortOrder,
     SupportsEmail = s.SupportsEmail, SupportsDoctor = s.SupportsDoctor, IsDaily = s.IsDaily, HasThreshold = s.HasThreshold, HasAmountThreshold = s.HasAmountThreshold
WHEN NOT MATCHED THEN INSERT (EventCode, Module, AreaCode, Title, Description, Icon, SortOrder, SupportsEmail, SupportsDoctor, IsDaily, HasThreshold, HasAmountThreshold)
     VALUES (s.EventCode, s.Module, s.AreaCode, s.Title, s.Description, s.Icon, s.SortOrder, s.SupportsEmail, s.SupportsDoctor, s.IsDaily, s.HasThreshold, s.HasAmountThreshold);
GO

-- ── the page: + the due amount ──
-- RS1 events, RS2 recipients, RS3 users of the branch (of its company), RS4 areas
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_GetSetup
    @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    -- company wise: a branch of another company shows nothing
    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster b WHERE b.BranchID = @BranchId AND ISNULL(b.CompanyId, @CompanyId) = @CompanyId)
        SET @BranchId = -1;

    SELECT e.EventCode, e.Module, e.AreaCode, e.Title, e.Description, e.Icon, e.SortOrder,
           e.SupportsEmail, e.SupportsDoctor, e.IsDaily, e.HasThreshold, e.HasAmountThreshold,
           CAST(ISNULL(s.IsEnabled, 0) AS BIT) AS IsEnabled,
           CAST(ISNULL(s.SendWhatsApp, 1) AS BIT) AS SendWhatsApp,
           CAST(CASE WHEN e.SupportsEmail = 1 THEN ISNULL(s.SendEmail, 1) ELSE 0 END AS BIT) AS SendEmail,
           CAST(CASE WHEN e.SupportsDoctor = 1 THEN ISNULL(s.NotifyDoctor, 1) ELSE 0 END AS BIT) AS NotifyDoctor,
           CASE WHEN e.IsDaily = 1 THEN CONVERT(VARCHAR(5), ISNULL(s.SendTime, '07:00'), 108) END AS SendTime,
           CASE WHEN e.HasThreshold = 1 THEN ISNULL(s.ThresholdPct, 10) END AS ThresholdPct,
           CASE WHEN e.HasAmountThreshold = 1 THEN ISNULL(s.ThresholdAmount, 1000) END AS ThresholdAmount,
           (SELECT COUNT(*) FROM dbo.AuditNotifyRecipient r JOIN dbo.Users u ON u.Id = r.UserId AND u.IsActive = 1
             WHERE r.BranchId = @BranchId AND r.EventCode = e.EventCode) AS RecipientCount,
           s.ModifiedDate,
           (SELECT MAX(d.StartedAt) FROM dbo.AuditNotifyDailyRun d WHERE d.BranchId = @BranchId AND d.EventCode = e.EventCode) AS LastRunAt
      FROM dbo.AuditNotifyEvent e
      JOIN dbo.AuditNotifyArea a ON a.AreaCode = e.AreaCode AND a.IsActive = 1
      LEFT JOIN dbo.AuditNotifyEventSetting s ON s.BranchId = @BranchId AND s.EventCode = e.EventCode
     WHERE e.IsActive = 1
     ORDER BY a.SortOrder, e.SortOrder;

    SELECT r.EventCode, r.UserId
      FROM dbo.AuditNotifyRecipient r JOIN dbo.Users u ON u.Id = r.UserId AND u.IsActive = 1
     WHERE r.BranchId = @BranchId;

    SELECT u.Id AS UserId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Name, u.Username,
           COALESCE(NULLIF(LTRIM(RTRIM(u.PhoneNumber)), ''), NULLIF(LTRIM(RTRIM(u.Phone)), '')) AS Mobile,
           NULLIF(LTRIM(RTRIM(u.Email)), '') AS Email,
           (SELECT b.BranchName FROM dbo.Branchmaster b WHERE b.BranchID = @BranchId) AS BranchName
      FROM dbo.Users u
     WHERE u.IsActive = 1 AND ISNULL(u.CompanyId, @CompanyId) = @CompanyId
       AND EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1)
     ORDER BY Name;

    SELECT a.AreaCode, a.Title, a.Description, a.Icon, a.SortOrder
      FROM dbo.AuditNotifyArea a
     WHERE a.IsActive = 1 AND EXISTS (SELECT 1 FROM dbo.AuditNotifyEvent e WHERE e.AreaCode = a.AreaCode AND e.IsActive = 1)
     ORDER BY a.SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_SaveEvent
    @CompanyId INT, @BranchId INT, @EventCode VARCHAR(40), @IsEnabled BIT, @UserIds VARCHAR(MAX) = NULL, @UserId INT,
    @SendWhatsApp BIT = NULL, @SendEmail BIT = NULL, @NotifyDoctor BIT = NULL, @SendTime VARCHAR(5) = NULL,
    @ThresholdPct DECIMAL(5, 2) = NULL, @ThresholdAmount DECIMAL(18, 2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- 2531: company wise - the branch must belong to the signed-in company
    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster b WHERE b.BranchID = @BranchId AND ISNULL(b.CompanyId, @CompanyId) = @CompanyId)
    BEGIN RAISERROR('This branch does not belong to your company - sign in to the branch to set up its notifications.', 16, 1); RETURN; END

    DECLARE @email BIT, @doctor BIT, @daily BIT, @threshold BIT, @amount BIT;
    SELECT @email = SupportsEmail, @doctor = SupportsDoctor, @daily = IsDaily, @threshold = HasThreshold, @amount = HasAmountThreshold
      FROM dbo.AuditNotifyEvent WHERE EventCode = @EventCode AND IsActive = 1;
    IF @email IS NULL BEGIN RAISERROR('Unknown event.', 16, 1); RETURN; END
    -- 2529: an event with a threshold (Discount Given Alert) keeps its percentage, above 0 and below 100
    IF @threshold = 1 AND (@ThresholdPct IS NULL OR @ThresholdPct <= 0 OR @ThresholdPct >= 100)
    BEGIN RAISERROR('Enter the discount percentage above which the alert is sent (more than 0, less than 100).', 16, 1); RETURN; END
    IF @threshold = 0 SET @ThresholdPct = NULL;
    -- 2531: an event with a due amount (Due Alert) keeps it, more than 0
    IF @amount = 1 AND (@ThresholdAmount IS NULL OR @ThresholdAmount <= 0 OR @ThresholdAmount > 99999999)
    BEGIN RAISERROR('Enter the due amount from which a bill is listed (more than 0).', 16, 1); RETURN; END
    IF @amount = 0 SET @ThresholdAmount = NULL;

    SET @SendWhatsApp = ISNULL(@SendWhatsApp, 1);
    SET @SendEmail = CASE WHEN @email = 1 THEN ISNULL(@SendEmail, 1) ELSE 0 END;
    SET @NotifyDoctor = CASE WHEN @doctor = 1 THEN ISNULL(@NotifyDoctor, 1) ELSE 0 END;
    DECLARE @time TIME(0) = CASE WHEN @daily = 1 THEN TRY_CAST(NULLIF(LTRIM(RTRIM(@SendTime)), '') AS TIME(0)) END;
    IF @daily = 1 AND @time IS NULL SET @time = '07:00';
    DECLARE @oldTime TIME(0) = (SELECT SendTime FROM dbo.AuditNotifyEventSetting WHERE BranchId = @BranchId AND EventCode = @EventCode);

    -- users of the branch and of the company
    DECLARE @Ids TABLE (UserId INT PRIMARY KEY);
    INSERT @Ids (UserId)
    SELECT DISTINCT u.Id FROM STRING_SPLIT(ISNULL(@UserIds, ''), ',') x
      JOIN dbo.Users u ON u.Id = TRY_CAST(LTRIM(RTRIM(x.value)) AS INT) AND u.IsActive = 1 AND ISNULL(u.CompanyId, @CompanyId) = @CompanyId
      JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1;

    IF @IsEnabled = 1 AND @SendWhatsApp = 0 AND @SendEmail = 0
    BEGIN RAISERROR('Choose WhatsApp, e-mail or both to switch this alert on.', 16, 1); RETURN; END
    IF @IsEnabled = 1 AND NOT EXISTS (SELECT 1 FROM @Ids) AND @NotifyDoctor = 0
    BEGIN RAISERROR('Choose at least one user (or send it to the doctor) to switch this alert on.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
        MERGE dbo.AuditNotifyEventSetting AS t
        USING (SELECT @BranchId AS BranchId, @EventCode AS EventCode) AS s ON t.BranchId = s.BranchId AND t.EventCode = s.EventCode
        WHEN MATCHED THEN UPDATE SET CompanyId = @CompanyId, IsEnabled = @IsEnabled, SendWhatsApp = @SendWhatsApp, SendEmail = @SendEmail,
             NotifyDoctor = @NotifyDoctor, SendTime = @time, ThresholdPct = @ThresholdPct, ThresholdAmount = @ThresholdAmount,
             ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHEN NOT MATCHED THEN INSERT (CompanyId, BranchId, EventCode, IsEnabled, SendWhatsApp, SendEmail, NotifyDoctor, SendTime, ThresholdPct, ThresholdAmount, ModifiedBy)
             VALUES (@CompanyId, @BranchId, @EventCode, @IsEnabled, @SendWhatsApp, @SendEmail, @NotifyDoctor, @time, @ThresholdPct, @ThresholdAmount, @UserId);

        DELETE r FROM dbo.AuditNotifyRecipient r
         WHERE r.BranchId = @BranchId AND r.EventCode = @EventCode AND r.UserId NOT IN (SELECT UserId FROM @Ids);
        INSERT dbo.AuditNotifyRecipient (CompanyId, BranchId, EventCode, UserId, CreatedBy)
        SELECT @CompanyId, @BranchId, @EventCode, i.UserId, @UserId FROM @Ids i
         WHERE NOT EXISTS (SELECT 1 FROM dbo.AuditNotifyRecipient r WHERE r.BranchId = @BranchId AND r.EventCode = @EventCode AND r.UserId = i.UserId);

        -- a daily event moved to a later time today: today's run is cleared, so the scheduler sends it at the new time
        IF @daily = 1 AND @IsEnabled = 1 AND @time > CAST(GETDATE() AS TIME(0)) AND (@oldTime IS NULL OR @oldTime <> @time)
            DELETE dbo.AuditNotifyDailyRun WHERE BranchId = @BranchId AND EventCode = @EventCode AND RunDate = CAST(GETDATE() AS DATE);
    COMMIT;
END
GO

-- ── scheduled sends, all areas ──
-- the daily events (any area): the scheduler asks usp_AuditNotify_DailyDue for each
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_DailyEvents
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.EventCode FROM dbo.AuditNotifyEvent e JOIN dbo.AuditNotifyArea a ON a.AreaCode = e.AreaCode AND a.IsActive = 1
     WHERE e.IsActive = 1 AND e.IsDaily = 1
     ORDER BY a.SortOrder, e.SortOrder;
END
GO

-- a scheduled run that sent nothing (nothing to send, or it failed): one line in the page's log, so the run is visible
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_LogRun
    @BranchId INT, @EventCode VARCHAR(40), @Status VARCHAR(20), @Detail NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.AuditNotifyLog (CompanyId, BranchId, EventCode, RefNo, UserId, Phone, Status, Detail, Message, TriggeredBy, CreatedDate, Channel, RecipientName)
    SELECT s.CompanyId, s.BranchId, s.EventCode, N'Scheduled ' + CONVERT(VARCHAR(5), s.SendTime, 108), NULL, NULL, @Status, @Detail, @Detail, NULL, GETDATE(), 'SYSTEM', N'Scheduler'
      FROM dbo.AuditNotifyEventSetting s
     WHERE s.BranchId = @BranchId AND s.EventCode = @EventCode;
END
GO

-- ── the due list of a branch, as on now ──
-- RS1 the setting and totals (no row = the event is not set up for the branch, or the branch is not of the setting's
-- company); RS2 the bills whose due (net - paid) has reached the set amount, largest due first (at most @Top).
-- OPD_DUE_ALERT: OPD bills; LAB_DUE_ALERT: LAB B2C bills (B2B never).
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_DueList
    @BranchId INT, @EventCode VARCHAR(40), @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;
    IF @EventCode NOT IN ('OPD_DUE_ALERT', 'LAB_DUE_ALERT') RETURN;
    DECLARE @company INT, @min DECIMAL(18, 2), @branchName NVARCHAR(200);
    SELECT @company = s.CompanyId, @min = ISNULL(s.ThresholdAmount, 1000), @branchName = b.BranchName
      FROM dbo.AuditNotifyEventSetting s
      JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId AND ISNULL(b.CompanyId, s.CompanyId) = s.CompanyId
     WHERE s.BranchId = @BranchId AND s.EventCode = @EventCode;
    IF @company IS NULL RETURN;
    IF ISNULL(@Top, 0) <= 0 SET @Top = 500;

    CREATE TABLE #R
    (
        RefId INT, BillNo NVARCHAR(60), BillDate DATETIME, PatientCode NVARCHAR(60), PatientName NVARCHAR(300), Mobile NVARCHAR(40),
        NetAmount DECIMAL(18, 2), PaidAmount DECIMAL(18, 2), DueAmount DECIMAL(18, 2)
    );

    IF @EventCode = 'OPD_DUE_ALERT'
        INSERT #R (RefId, BillNo, BillDate, PatientCode, PatientName, Mobile, NetAmount, PaidAmount, DueAmount)
        SELECT x.OPDServiceId, x.OPDBillNo, x.CreatedDate, x.PatientCode, x.PatientName, x.PhoneNumber, x.NetAmount, x.PaidAmount, x.NetAmount - x.PaidAmount
          FROM (SELECT s.OPDServiceId, s.OPDBillNo, s.CreatedDate, p.PatientCode, p.PhoneNumber,
                       LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
                       CAST(ISNULL(ph.NetAmount, s.TotalAmount) AS DECIMAL(18, 2)) AS NetAmount,
                       CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount
                  FROM dbo.PatientOPDService s
                  JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
                  LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
                 WHERE s.BranchId = @BranchId AND s.IsActive = 1 AND ISNULL(s.CompanyId, @company) = @company) x
         WHERE x.NetAmount - x.PaidAmount > 0 AND x.NetAmount - x.PaidAmount >= @min;
    ELSE
        INSERT #R (RefId, BillNo, BillDate, PatientCode, PatientName, Mobile, NetAmount, PaidAmount, DueAmount)
        SELECT x.LabOrderId, x.BillNo, x.OrderDate, x.PatientCode, x.PatientName, x.PhoneNumber, x.NetAmount, x.PaidAmount, x.NetAmount - x.PaidAmount
          FROM (SELECT lo.LabOrderId, lo.BillNo, lo.OrderDate, p.PatientCode, p.PhoneNumber,
                       LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
                       CAST(ISNULL(ph.NetAmount, lo.TotalAmount) AS DECIMAL(18, 2)) AS NetAmount,
                       CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount
                  FROM dbo.LabOrder lo
                  JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
                  LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
                 WHERE lo.BranchId = @BranchId AND lo.IsActive = 1 AND ISNULL(lo.IsB2B, 0) = 0) x
         WHERE x.NetAmount - x.PaidAmount > 0 AND x.NetAmount - x.PaidAmount >= @min;

    SELECT @company AS CompanyId, @BranchId AS BranchId, @branchName AS BranchName, s.IsEnabled, s.SendWhatsApp,
           CAST(s.SendEmail & e.SupportsEmail AS BIT) AS SendEmail, @min AS ThresholdAmount, e.Module, e.Title,
           (SELECT COUNT(1) FROM #R) AS BillCount, (SELECT COUNT(DISTINCT PatientCode) FROM #R) AS PatientCount,
           (SELECT ISNULL(SUM(DueAmount), 0) FROM #R) AS TotalDue, GETDATE() AS AsOn
      FROM dbo.AuditNotifyEventSetting s
      JOIN dbo.AuditNotifyEvent e ON e.EventCode = s.EventCode
     WHERE s.BranchId = @BranchId AND s.EventCode = @EventCode;

    SELECT TOP (@Top) RefId, BillNo, BillDate, DATEDIFF(DAY, BillDate, GETDATE()) AS AgeDays, PatientCode, PatientName, Mobile,
           NetAmount, PaidAmount, DueAmount
      FROM #R
     ORDER BY DueAmount DESC, BillDate;

    DROP TABLE #R;
END
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2531 applied: Due Alert (OPD / LAB B2C dues as on date, company and branch wise).';
GO
SET NOEXEC OFF;
GO
