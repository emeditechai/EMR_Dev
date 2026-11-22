-- ============================================================================================================
-- Migration: 2529_discount_given_alert.sql   (application database; needs 2397 and 2528)
-- Settings > Audit Notification Setup > Discount Given Alert: a WhatsApp alert to the chosen users when an OPD bill or a
-- LAB B2C bill is saved with a discount above the branch's percentage (set on the page - "alert above N %").
--   Discount = the discount GIVEN on the bill, as the payment screen counts it: MAX(bill discount, line discounts less the
--   membership discount) - a bill discount is spread over the lines, so it is counted once. Given by % or by amount (₹),
--   it is an amount on the bill, and its percentage of the bill amount (before discount) is compared with the threshold.
--   Membership discounts (membership card / test discounts) are never counted - a membership-only bill is not alerted. A bill is alerted again only when its discount grows past what was already alerted, so
--   collecting a due later does not repeat it (dbo.AuditNotifyDiscountAlert).
--   The alert: patient, bill no, bill amount, discount %, discount amount, net amount, reason, given by, approved by.
--   AuditNotifyArea DISCOUNT, AuditNotifyEvent DISCOUNT_GIVEN (+ HasThreshold), AuditNotifyEventSetting (+ ThresholdPct).
--   Procedures: usp_AuditNotify_GetSetup / usp_AuditNotify_SaveEvent (+ threshold), usp_AuditNotify_DiscountCheck.
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('dbo.AuditNotifyArea', 'U') IS NULL
BEGIN
    RAISERROR('Script 2529 needs scripts 2397 and 2528 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('dbo.AuditNotifyEvent', 'HasThreshold') IS NULL
    ALTER TABLE dbo.AuditNotifyEvent ADD HasThreshold BIT NOT NULL CONSTRAINT DF_AuditNotifyEvent_Threshold DEFAULT (0);
IF COL_LENGTH('dbo.AuditNotifyEventSetting', 'ThresholdPct') IS NULL
    ALTER TABLE dbo.AuditNotifyEventSetting ADD ThresholdPct DECIMAL(5, 2) NULL;
GO
MERGE dbo.AuditNotifyArea AS t
USING (VALUES ('DISCOUNT', N'Discount Given Alert',
               N'A WhatsApp alert to the users you choose when an OPD bill or a LAB B2C bill is given a discount above the percentage you set.',
               'bi-percent', 30)) AS s (AreaCode, Title, Description, Icon, SortOrder) ON t.AreaCode = s.AreaCode
WHEN MATCHED THEN UPDATE SET Title = s.Title, Description = s.Description, Icon = s.Icon, SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT (AreaCode, Title, Description, Icon, SortOrder) VALUES (s.AreaCode, s.Title, s.Description, s.Icon, s.SortOrder);
GO
MERGE dbo.AuditNotifyEvent AS t
USING (VALUES ('DISCOUNT_GIVEN', 'OPD / LAB', 'DISCOUNT', N'Discount above the set percentage',
               N'An OPD bill or a LAB B2C bill is saved with a discount above the percentage set here - patient, bill, amount, discount % and amount, and who gave it.',
               'bi-percent', 210, 0, 0, 0, 1)) AS s (EventCode, Module, AreaCode, Title, Description, Icon, SortOrder, SupportsEmail, SupportsDoctor, IsDaily, HasThreshold)
ON t.EventCode = s.EventCode
WHEN MATCHED THEN UPDATE SET Module = s.Module, AreaCode = s.AreaCode, Title = s.Title, Description = s.Description, Icon = s.Icon, SortOrder = s.SortOrder,
     SupportsEmail = s.SupportsEmail, SupportsDoctor = s.SupportsDoctor, IsDaily = s.IsDaily, HasThreshold = s.HasThreshold
WHEN NOT MATCHED THEN INSERT (EventCode, Module, AreaCode, Title, Description, Icon, SortOrder, SupportsEmail, SupportsDoctor, IsDaily, HasThreshold)
     VALUES (s.EventCode, s.Module, s.AreaCode, s.Title, s.Description, s.Icon, s.SortOrder, s.SupportsEmail, s.SupportsDoctor, s.IsDaily, s.HasThreshold);
GO

-- the discount already alerted on each bill (a bill is alerted again only when its discount grows past it)
IF OBJECT_ID('dbo.AuditNotifyDiscountAlert', 'U') IS NULL
CREATE TABLE dbo.AuditNotifyDiscountAlert
(
    ModuleCode     VARCHAR(10)    NOT NULL,
    ModuleRefId    INT            NOT NULL,
    DiscountAmount DECIMAL(18, 2) NOT NULL,
    DiscountPct    DECIMAL(9, 2)  NOT NULL,
    AlertedAt      DATETIME       NOT NULL CONSTRAINT DF_AuditNotifyDiscountAlert_At DEFAULT (GETDATE()),
    CONSTRAINT PK_AuditNotifyDiscountAlert PRIMARY KEY (ModuleCode, ModuleRefId)
);
GO

-- ── the page: + the threshold ──
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_GetSetup
    @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.EventCode, e.Module, e.AreaCode, e.Title, e.Description, e.Icon, e.SortOrder,
           e.SupportsEmail, e.SupportsDoctor, e.IsDaily, e.HasThreshold,
           CAST(ISNULL(s.IsEnabled, 0) AS BIT) AS IsEnabled,
           CAST(ISNULL(s.SendWhatsApp, 1) AS BIT) AS SendWhatsApp,
           CAST(CASE WHEN e.SupportsEmail = 1 THEN ISNULL(s.SendEmail, 1) ELSE 0 END AS BIT) AS SendEmail,
           CAST(CASE WHEN e.SupportsDoctor = 1 THEN ISNULL(s.NotifyDoctor, 1) ELSE 0 END AS BIT) AS NotifyDoctor,
           CASE WHEN e.IsDaily = 1 THEN CONVERT(VARCHAR(5), ISNULL(s.SendTime, '07:00'), 108) END AS SendTime,
           CASE WHEN e.HasThreshold = 1 THEN ISNULL(s.ThresholdPct, 10) END AS ThresholdPct,
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
    @ThresholdPct DECIMAL(5, 2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @email BIT, @doctor BIT, @daily BIT, @threshold BIT;
    SELECT @email = SupportsEmail, @doctor = SupportsDoctor, @daily = IsDaily, @threshold = HasThreshold FROM dbo.AuditNotifyEvent WHERE EventCode = @EventCode AND IsActive = 1;
    IF @email IS NULL BEGIN RAISERROR('Unknown event.', 16, 1); RETURN; END
    -- 2529: an event with a threshold (Discount Given Alert) keeps its percentage, above 0 and below 100
    IF @threshold = 1 AND (@ThresholdPct IS NULL OR @ThresholdPct <= 0 OR @ThresholdPct >= 100)
    BEGIN RAISERROR('Enter the discount percentage above which the alert is sent (more than 0, less than 100).', 16, 1); RETURN; END
    IF @threshold = 0 SET @ThresholdPct = NULL;

    SET @SendWhatsApp = ISNULL(@SendWhatsApp, 1);
    SET @SendEmail = CASE WHEN @email = 1 THEN ISNULL(@SendEmail, 1) ELSE 0 END;
    SET @NotifyDoctor = CASE WHEN @doctor = 1 THEN ISNULL(@NotifyDoctor, 1) ELSE 0 END;
    DECLARE @time TIME(0) = CASE WHEN @daily = 1 THEN TRY_CAST(NULLIF(LTRIM(RTRIM(@SendTime)), '') AS TIME(0)) END;
    IF @daily = 1 AND @time IS NULL SET @time = '07:00';

    DECLARE @Ids TABLE (UserId INT PRIMARY KEY);
    INSERT @Ids (UserId)
    SELECT DISTINCT u.Id FROM STRING_SPLIT(ISNULL(@UserIds, ''), ',') x
      JOIN dbo.Users u ON u.Id = TRY_CAST(LTRIM(RTRIM(x.value)) AS INT) AND u.IsActive = 1
      JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1;

    IF @IsEnabled = 1 AND @SendWhatsApp = 0 AND @SendEmail = 0
    BEGIN RAISERROR('Choose WhatsApp, e-mail or both to switch this alert on.', 16, 1); RETURN; END
    IF @IsEnabled = 1 AND NOT EXISTS (SELECT 1 FROM @Ids) AND @NotifyDoctor = 0
    BEGIN RAISERROR('Choose at least one user (or send it to the doctor) to switch this alert on.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
        MERGE dbo.AuditNotifyEventSetting AS t
        USING (SELECT @BranchId AS BranchId, @EventCode AS EventCode) AS s ON t.BranchId = s.BranchId AND t.EventCode = s.EventCode
        WHEN MATCHED THEN UPDATE SET IsEnabled = @IsEnabled, SendWhatsApp = @SendWhatsApp, SendEmail = @SendEmail, NotifyDoctor = @NotifyDoctor,
             SendTime = @time, ThresholdPct = @ThresholdPct, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHEN NOT MATCHED THEN INSERT (CompanyId, BranchId, EventCode, IsEnabled, SendWhatsApp, SendEmail, NotifyDoctor, SendTime, ThresholdPct, ModifiedBy)
             VALUES (@CompanyId, @BranchId, @EventCode, @IsEnabled, @SendWhatsApp, @SendEmail, @NotifyDoctor, @time, @ThresholdPct, @UserId);

        DELETE r FROM dbo.AuditNotifyRecipient r
         WHERE r.BranchId = @BranchId AND r.EventCode = @EventCode AND r.UserId NOT IN (SELECT UserId FROM @Ids);
        INSERT dbo.AuditNotifyRecipient (CompanyId, BranchId, EventCode, UserId, CreatedBy)
        SELECT @CompanyId, @BranchId, @EventCode, i.UserId, @UserId FROM @Ids i
         WHERE NOT EXISTS (SELECT 1 FROM dbo.AuditNotifyRecipient r WHERE r.BranchId = @BranchId AND r.EventCode = @EventCode AND r.UserId = i.UserId);
    COMMIT;
END
GO

-- after a bill's payment is saved: the alert to send, if any - the event is on for the bill's branch, the bill is OPD or
-- LAB B2C, its discount (line + bill discounts, not membership) is above the branch's percentage and above what was
-- already alerted on it. The bill is claimed here (one alert per discount rise). No row = nothing to send.
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_DiscountCheck
    @ModuleCode VARCHAR(10), @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @ModuleCode NOT IN ('OPD', 'LAB') RETURN;
    DECLARE @branch INT, @gross DECIMAL(18, 2), @disc DECIMAL(18, 2), @net DECIMAL(18, 2), @reason NVARCHAR(500), @by INT, @appr INT, @b2b BIT = 0,
            @type VARCHAR(5), @typed DECIMAL(18, 2), @mem DECIMAL(18, 2);
    -- the discount given (not membership): the bill discount is spread over the lines (LineDiscountTotal holds it and the
    -- membership discount), so: MAX(bill discount, line discounts - membership) - as PaymentService counts it
    SELECT TOP 1 @branch = ph.BranchId, @gross = ISNULL(ph.SubTotal, 0),
           @mem = ISNULL(ph.MembershipDiscountAmount, 0),
           @disc = CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) > ISNULL(ph.LineDiscountTotal, 0) - ISNULL(ph.MembershipDiscountAmount, 0)
                        THEN ISNULL(ph.HeaderDiscountAmount, 0)
                        ELSE ISNULL(ph.LineDiscountTotal, 0) - ISNULL(ph.MembershipDiscountAmount, 0) END,
           @type = ph.HeaderDiscountType, @typed = ph.HeaderDiscountValue,
           @net = ph.NetAmount, @reason = NULLIF(LTRIM(RTRIM(ph.DiscountReason)), ''),
           @by = COALESCE(ph.DiscountEnteredBy, ph.LastModifiedBy, ph.CreatedBy), @appr = ph.DiscountApprovedBy
      FROM dbo.PaymentHeader ph
     WHERE ph.ModuleCode = @ModuleCode AND ph.ModuleRefId = @ModuleRefId AND ph.IsActive = 1
     ORDER BY ph.PaymentHeaderId DESC;
    IF @branch IS NULL OR @gross <= 0 OR @disc <= 0 RETURN;
    IF @ModuleCode = 'LAB' SELECT @b2b = CAST(ISNULL(IsB2B, 0) AS BIT) FROM dbo.LabOrder WHERE LabOrderId = @ModuleRefId;
    IF @b2b = 1 RETURN;                                                       -- LAB B2B bills are not alerted

    DECLARE @threshold DECIMAL(5, 2);
    SELECT @threshold = ISNULL(ThresholdPct, 10) FROM dbo.AuditNotifyEventSetting
     WHERE BranchId = @branch AND EventCode = 'DISCOUNT_GIVEN' AND IsEnabled = 1;
    IF @threshold IS NULL RETURN;                                             -- off for the branch
    DECLARE @pct DECIMAL(9, 2) = ROUND(@disc * 100.0 / @gross, 2);
    IF @pct <= @threshold RETURN;

    BEGIN TRANSACTION;
    DECLARE @last DECIMAL(18, 2) = (SELECT DiscountAmount FROM dbo.AuditNotifyDiscountAlert WITH (UPDLOCK, HOLDLOCK)
                                     WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId);
    IF @last IS NOT NULL AND @disc <= @last BEGIN COMMIT; RETURN; END         -- already alerted at this discount
    IF @last IS NULL
        INSERT dbo.AuditNotifyDiscountAlert (ModuleCode, ModuleRefId, DiscountAmount, DiscountPct) VALUES (@ModuleCode, @ModuleRefId, @disc, @pct);
    ELSE
        UPDATE dbo.AuditNotifyDiscountAlert SET DiscountAmount = @disc, DiscountPct = @pct, AlertedAt = GETDATE()
         WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId;
    COMMIT;

    SELECT @gross AS BillAmount, @disc AS DiscountAmount, @pct AS DiscountPct, @threshold AS ThresholdPct, @net AS NetAmount, @reason AS Reason,
           CASE @type WHEN 'D' THEN 'Amount' WHEN 'P' THEN 'Percentage' END AS DiscountMode,
           CASE WHEN @type IN ('D', 'P') THEN @typed END AS DiscountEntered, @mem AS MembershipDiscount,
           @by AS GivenByUserId,
           (SELECT ISNULL(NULLIF(LTRIM(RTRIM(FullName)), ''), Username) FROM dbo.Users WHERE Id = @by) AS GivenBy,
           (SELECT ISNULL(NULLIF(LTRIM(RTRIM(FullName)), ''), Username) FROM dbo.Users WHERE Id = @appr) AS ApprovedBy,
           CAST(CASE WHEN @last IS NULL THEN 0 ELSE 1 END AS BIT) AS IsIncrease, @last AS PreviousDiscount;
END
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2529 applied: Discount Given Alert (OPD / LAB B2C bills above the set percentage).';
GO
SET NOEXEC OFF;
GO
