-- ============================================================================
-- Migration: 2243_membership_points_whatsapp.sql
-- Description: WhatsAppConfig > Notification Trigger Settings > "Membership Points Earned Notification":
--   when a B2C LAB bill earns membership points (usp_Membership_SyncBill, SQLScripts/2236), the card holder is sent a
--   WhatsApp message from a configurable template.
--   * dbo.WhatsAppConfiguration.MembershipPointsNotificationEnabled / MembershipPointsMessageTemplate - per branch,
--     same pattern as the other triggers.
--   * dbo.MembershipPointsWhatsAppLog - one row per EARN entry of the card ledger (unique), so the same points are never
--     WhatsApp'd twice (a retried payment, two screens).
--   * usp_MembershipPointsWhatsApp_Pending - a bill's EARN entries not yet handled (last 2 days only: switching the
--     trigger on never messages old earnings), with everything the template needs.
--   * usp_MembershipPointsWhatsApp_Claim / _Complete - take the send, record Sent / Failed / Skipped.
--   Placeholders: {CardHolderName} {PatientName} {HospitalName} {CardNo} {PlanName} {BillNo} {PointsEarned}
--                 {PointsValue} {PointsBalance} {BalanceValue} {ExpiryDate}
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.WhatsAppConfiguration', 'MembershipPointsNotificationEnabled') IS NULL
    ALTER TABLE dbo.WhatsAppConfiguration ADD MembershipPointsNotificationEnabled BIT NOT NULL
        CONSTRAINT DF_WhatsAppConfiguration_MembershipPointsNotificationEnabled DEFAULT 1;
GO
IF COL_LENGTH('dbo.WhatsAppConfiguration', 'MembershipPointsMessageTemplate') IS NULL
    ALTER TABLE dbo.WhatsAppConfiguration ADD MembershipPointsMessageTemplate NVARCHAR(1000) NOT NULL
        CONSTRAINT DF_WhatsAppConfiguration_MembershipPointsMessageTemplate
        DEFAULT 'Dear {CardHolderName}, {PointsEarned} points (worth Rs. {PointsValue}) have been added to your {HospitalName} membership card {CardNo} for Bill {BillNo}. Your balance is now {PointsBalance} points (Rs. {BalanceValue}). These points are valid till {ExpiryDate}. Thank you!';
GO

IF OBJECT_ID(N'dbo.MembershipPointsWhatsAppLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MembershipPointsWhatsAppLog
    (
        LogId            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MembershipPointsWhatsAppLog PRIMARY KEY,
        LedgerId         BIGINT        NOT NULL,          -- the EARN entry of dbo.MembershipLedger
        CardId           INT           NOT NULL,
        PaymentHeaderId  INT           NULL,
        BranchId         INT           NULL,
        RecipientPhone   NVARCHAR(50)  NULL,
        Status           VARCHAR(20)   NOT NULL,          -- Sending | Sent | Failed | Skipped
        Message          NVARCHAR(500) NULL,
        CreatedBy        INT           NULL,
        CreatedDate      DATETIME2(0)  NOT NULL CONSTRAINT DF_MembershipPointsWhatsAppLog_Created DEFAULT SYSDATETIME(),
        CompletedDate    DATETIME2(0)  NULL
    );
    CREATE UNIQUE INDEX UX_MembershipPointsWhatsAppLog_Ledger ON dbo.MembershipPointsWhatsAppLog (LedgerId);
END
GO

-- a bill's points earnings not yet WhatsApp'd, with what the message needs
CREATE OR ALTER PROCEDURE dbo.usp_MembershipPointsWhatsApp_Pending
    @PaymentHeaderId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT l.LedgerId, l.CardId, l.PaymentHeaderId, COALESCE(lo.BranchId, l.BranchId, c.IssueBranchId) AS BranchId,
           c.CardNo, pl.PlanName,
           CAST(l.Points AS DECIMAL(12,2)) AS PointsEarned,
           CAST(ROUND(l.Points * ISNULL(pl.PointValue, 1), 2) AS DECIMAL(12,2)) AS PointsValue,
           CAST(c.PointsBalance AS DECIMAL(12,2)) AS PointsBalance,
           CAST(ROUND(c.PointsBalance * ISNULL(pl.PointValue, 1), 2) AS DECIMAL(12,2)) AS BalanceValue,
           l.ExpiresOn,
           lo.BillNo,
           LTRIM(RTRIM(ISNULL(bp.FirstName, '') + ' ' + ISNULL(bp.LastName, ''))) AS PatientName,
           LTRIM(RTRIM(ISNULL(hp.FirstName, '') + ' ' + ISNULL(hp.LastName, ''))) AS CardHolderName,
           -- the points belong to the card: its holder (primary member) is told; else the bill's patient
           COALESCE(NULLIF(LTRIM(RTRIM(hp.PhoneNumber)), ''), NULLIF(LTRIM(RTRIM(bp.PhoneNumber)), '')) AS Phone
    FROM dbo.MembershipLedger l
    INNER JOIN dbo.MembershipCard c ON c.CardId = l.CardId
    INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId
    LEFT JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = l.PaymentHeaderId
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = ph.ModuleRefId AND ph.ModuleCode = 'LAB'
    LEFT JOIN dbo.PatientMaster bp ON bp.PatientId = ISNULL(l.PatientId, lo.PatientId)
    LEFT JOIN dbo.PatientMaster hp ON hp.PatientId = c.PrimaryPatientId
    WHERE l.PaymentHeaderId = @PaymentHeaderId AND l.TxnType = 'EARN' AND l.Points > 0
      AND l.CreatedDate >= DATEADD(DAY, -2, GETDATE())
      AND NOT EXISTS (SELECT 1 FROM dbo.MembershipPointsWhatsAppLog w WHERE w.LedgerId = l.LedgerId)
    ORDER BY l.LedgerId;
END;
GO

-- takes the send of one EARN entry (safe when two sends race: the unique index lets one in)
CREATE OR ALTER PROCEDURE dbo.usp_MembershipPointsWhatsApp_Claim
    @LedgerId        BIGINT,
    @CardId          INT,
    @PaymentHeaderId INT = NULL,
    @BranchId        INT = NULL,
    @RecipientPhone  NVARCHAR(50) = NULL,
    @UserId          INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        INSERT INTO dbo.MembershipPointsWhatsAppLog (LedgerId, CardId, PaymentHeaderId, BranchId, RecipientPhone, Status, CreatedBy)
        VALUES (@LedgerId, @CardId, @PaymentHeaderId, @BranchId, @RecipientPhone, 'Sending', @UserId);
        SELECT CAST(SCOPE_IDENTITY() AS INT) AS LogId;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() IN (2601, 2627) SELECT CAST(NULL AS INT) AS LogId;   -- already taken
        ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_MembershipPointsWhatsApp_Complete
    @LogId   INT,
    @Status  VARCHAR(20),
    @Message NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.MembershipPointsWhatsAppLog SET Status = @Status, Message = LEFT(@Message, 500), CompletedDate = SYSDATETIME()
    WHERE LogId = @LogId;
END;
GO

PRINT 'Script 2243 applied: Membership Points Earned WhatsApp notification (trigger, template, send log).';
GO
