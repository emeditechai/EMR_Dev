-- ============================================================================
-- Migration: 2226_membership_renewal_reminder.sql
-- Description:
--   Membership card - renewal reminder e-mails, sent by a background service of EMR.Web
--   (MembershipRenewalReminderBackgroundService; EMR.Web owns the SMTP configuration and the mail log).
--   1. Hospital Settings (per branch, applies to the cards the branch issued):
--        MembershipRenewalReminderEnabled   send reminders (default Yes)
--        MembershipRenewalReminderDays      days before expiry, comma separated (default '30,15,1'; 0 = on the last day)
--        MembershipRenewalReminderTime      time of day from which the day's reminders go out (default 10:00)
--        MembershipRenewalReminderTemplate  message text
--   2. No new table: every reminder is a REMINDER row in MembershipLedger, so it shows on the card and
--      is the record that stops a second mail for the same stage.
--        usp_MembershipRenewalReminder_GetDue    cards whose current reminder stage has not been handled
--        usp_MembershipRenewalReminder_Claim     takes one card's reminder (safe when two servers run)
--        usp_MembershipRenewalReminder_Complete  records Sent / Skipped / Failed
--      A stage is handled once it was sent or skipped (no e-mail address); a failed send is tried again
--      the next day. If the service was down across several stages only the latest one is sent.
--      Active, non-lifetime cards only; a renewed, blocked, cancelled or expired card gets nothing.
--   Run after 2225.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Hospital Settings parameters ---------------------------------------------
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipRenewalReminderEnabled') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipRenewalReminderEnabled BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipRenewalReminderEnabled DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipRenewalReminderDays') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipRenewalReminderDays VARCHAR(50) NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipRenewalReminderDays DEFAULT ('30,15,1');
GO
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipRenewalReminderTime') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipRenewalReminderTime TIME(0) NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipRenewalReminderTime DEFAULT ('10:00');
GO
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipRenewalReminderTemplate') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipRenewalReminderTemplate NVARCHAR(1000) NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipRenewalReminderTemplate
        DEFAULT N'Dear {PatientName}, your {PlanName} membership card {CardNo} at {HospitalName} expires {DaysLeft}, on {ValidTo}. Renew it at any of our centres to keep your benefits and carry your {Points} points forward to the new card.';
GO

-- 2. Ledger type REMINDER -------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_MembershipLedger_TxnType' AND definition NOT LIKE '%REMINDER%')
    ALTER TABLE dbo.MembershipLedger DROP CONSTRAINT CK_MembershipLedger_TxnType;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_MembershipLedger_TxnType')
    ALTER TABLE dbo.MembershipLedger WITH CHECK ADD CONSTRAINT CK_MembershipLedger_TxnType
        CHECK (TxnType IN ('ISSUE', 'RENEW', 'EARN', 'REDEEM', 'EXPIRE', 'REVERSE', 'ADJUST', 'DISCOUNT', 'MEMBER', 'STATUS', 'REMINDER'));
GO

-- 3. Procedures ----------------------------------------------------------------
-- The reminder stage of a card = the smallest configured "days before expiry" that the card has reached
-- (30,15,1 with 12 days left -> stage 15). One row per card whose stage is not handled yet.
CREATE OR ALTER PROCEDURE dbo.usp_MembershipRenewalReminder_GetDue
    @Now DATETIME
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(@Now AS DATE);

    SELECT c.CardId, c.CompanyId, c.IssueBranchId AS BranchId, c.CardNo, p.PlanName,
           LTRIM(RTRIM(CONCAT(pm.Salutation + ' ', pm.FirstName, ' ', pm.LastName))) AS PatientName,
           NULLIF(LTRIM(RTRIM(pm.EmailId)), '') AS EmailId,
           c.ValidTo, DATEDIFF(DAY, @Today, c.ValidTo) AS DaysLeft, st.StageDays, c.PointsBalance,
           hs.HotelName AS HospitalName,   -- the hospital name column is HotelName
           hs.MembershipRenewalReminderTemplate AS Template
    FROM dbo.MembershipCard c
    INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
    INNER JOIN dbo.PatientMaster pm ON pm.PatientId = c.PrimaryPatientId
    INNER JOIN dbo.HospitalSettings hs ON hs.BranchID = c.IssueBranchId AND hs.IsActive = 1
    CROSS APPLY (SELECT MIN(v.Days) AS StageDays
                 FROM (SELECT TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) AS Days FROM STRING_SPLIT(hs.MembershipRenewalReminderDays, ',') s) v
                 WHERE v.Days BETWEEN 0 AND 365 AND v.Days >= DATEDIFF(DAY, @Today, c.ValidTo)) st
    WHERE c.Status = 'Active'
      AND c.ValidTo < '99990101'                       -- lifetime cards are never renewed
      AND c.ValidTo >= @Today                          -- nothing after expiry
      AND hs.MembershipRenewalReminderEnabled = 1
      AND CAST(@Now AS TIME(0)) >= hs.MembershipRenewalReminderTime
      AND st.StageDays IS NOT NULL
      -- this stage already sent / skipped / being sent
      AND NOT EXISTS (SELECT 1 FROM dbo.MembershipLedger l
                      WHERE l.CardId = c.CardId AND l.TxnType = 'REMINDER' AND l.Narration NOT LIKE '%: failed%'
                        AND CAST(l.CreatedDate AS DATE) >= DATEADD(DAY, -st.StageDays, c.ValidTo))
      -- a failed send is tried again the next day, not the same day
      AND NOT EXISTS (SELECT 1 FROM dbo.MembershipLedger l
                      WHERE l.CardId = c.CardId AND l.TxnType = 'REMINDER' AND CAST(l.CreatedDate AS DATE) = @Today)
    ORDER BY c.ValidTo, c.CardId;
END
GO

-- Takes the reminder of one card for this stage. Returns LedgerId, or NULL when it is no longer due
-- (another server took it, or the card was renewed / blocked in the meantime).
CREATE OR ALTER PROCEDURE dbo.usp_MembershipRenewalReminder_Claim
    @CardId    INT,
    @StageDays INT,
    @Now       DATETIME
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Today DATE = CAST(@Now AS DATE), @ValidTo DATE, @Status VARCHAR(15), @Balance DECIMAL(12,2), @BranchId INT, @PatientId INT;

    BEGIN TRANSACTION;
    SELECT @ValidTo = ValidTo, @Status = Status, @Balance = PointsBalance, @BranchId = IssueBranchId, @PatientId = PrimaryPatientId
    FROM dbo.MembershipCard WITH (UPDLOCK, HOLDLOCK) WHERE CardId = @CardId;

    IF @Status <> 'Active' OR @ValidTo IS NULL OR @ValidTo < @Today OR @ValidTo >= '99990101'
       OR EXISTS (SELECT 1 FROM dbo.MembershipLedger l
                  WHERE l.CardId = @CardId AND l.TxnType = 'REMINDER'
                    AND (CAST(l.CreatedDate AS DATE) = @Today
                         OR (l.Narration NOT LIKE '%: failed%' AND CAST(l.CreatedDate AS DATE) >= DATEADD(DAY, -@StageDays, @ValidTo))))
    BEGIN
        COMMIT TRANSACTION;
        SELECT CAST(NULL AS BIGINT) AS LedgerId;
        RETURN;
    END

    INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, TxnType, Points, Amount, BalanceAfter, Narration, CreatedDate)
    VALUES (@CardId, @PatientId, @BranchId, 'REMINDER', 0, 0, @Balance,
            CONCAT('Renewal reminder (', @StageDays, ' day(s) before expiry): sending'), @Now);
    DECLARE @Id BIGINT = SCOPE_IDENTITY();
    COMMIT TRANSACTION;
    SELECT @Id AS LedgerId;
END
GO

-- @Outcome: sent | skipped | failed. The text after the colon is what GetDue / Claim read.
CREATE OR ALTER PROCEDURE dbo.usp_MembershipRenewalReminder_Complete
    @LedgerId BIGINT,
    @Outcome  VARCHAR(10),
    @Detail   NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Outcome NOT IN ('sent', 'skipped', 'failed') SET @Outcome = 'failed';
    UPDATE dbo.MembershipLedger
    SET Narration = LEFT(CONCAT(LEFT(Narration, CHARINDEX(':', Narration)), ' ', @Outcome,
                                CASE WHEN NULLIF(LTRIM(RTRIM(@Detail)), '') IS NULL THEN '' ELSE ' - ' + LTRIM(RTRIM(@Detail)) END), 300)
    WHERE LedgerId = @LedgerId AND TxnType = 'REMINDER';
END
GO

PRINT '2226_membership_renewal_reminder.sql applied.';
GO
