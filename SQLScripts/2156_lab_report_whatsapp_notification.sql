-- ============================================================================
-- Migration: 2156_lab_report_whatsapp_notification.sql
-- Description:
--   Adds "B2C Approved Report Notification" to WhatsAppConfig > Notification Trigger Settings:
--   when enabled, a B2C patient is sent a WhatsApp message (with the approved report PDF
--   attached) as soon as every reportable test on the bill (LAB Report or Image Report) is
--   approved. B2B orders are never notified this way - the franchise/agent handles delivery.
--
--   dbo.WhatsAppConfiguration.LabReportApprovedNotificationEnabled / LabReportApprovedMessageTemplate
--                                          new toggle + template columns, same pattern as Opd/Lab/Video.
--   dbo.LabReportWhatsAppLog              one row per bill per final approval (LabOrderId + FinalApprovedOn
--                                          is unique), so the same final report is never WhatsApp'd twice,
--                                          while a report that is un-approved and approved again sends once more.
--   dbo.usp_LabReportWhatsApp_GetState    is the bill final, who / where to send (phone), B2C or B2B
--   dbo.usp_LabReportWhatsApp_Claim       takes the send for this final approval (safe when two approvals race)
--   dbo.usp_LabReportWhatsApp_Complete    records Sent / Failed / Skipped
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'WhatsAppConfiguration' AND COLUMN_NAME = 'LabReportApprovedNotificationEnabled')
BEGIN
    ALTER TABLE dbo.WhatsAppConfiguration ADD LabReportApprovedNotificationEnabled BIT NOT NULL CONSTRAINT DF_WhatsAppConfiguration_LabReportApprovedNotificationEnabled DEFAULT 1;
    PRINT 'Added WhatsAppConfiguration.LabReportApprovedNotificationEnabled.';
END
ELSE PRINT 'WhatsAppConfiguration.LabReportApprovedNotificationEnabled already exists.';
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'WhatsAppConfiguration' AND COLUMN_NAME = 'LabReportApprovedMessageTemplate')
BEGIN
    ALTER TABLE dbo.WhatsAppConfiguration ADD LabReportApprovedMessageTemplate NVARCHAR(1000) NOT NULL
        CONSTRAINT DF_WhatsAppConfiguration_LabReportApprovedMessageTemplate
        DEFAULT 'Dear {PatientName}, your report for Bill {BillNo} at {HospitalName} has been approved. Please find your report attached. Thank you for choosing us!';
    PRINT 'Added WhatsAppConfiguration.LabReportApprovedMessageTemplate.';
END
ELSE PRINT 'WhatsAppConfiguration.LabReportApprovedMessageTemplate already exists.';
GO

IF OBJECT_ID(N'dbo.LabReportWhatsAppLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabReportWhatsAppLog
    (
        LabReportWhatsAppLogId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabReportWhatsAppLog PRIMARY KEY,
        LabOrderId          INT            NOT NULL,
        BranchId            INT            NOT NULL,
        BillNo              NVARCHAR(50)   NULL,
        FinalApprovedOn     DATETIME2(0)   NOT NULL,   -- latest approval time of the bill = which "final" this row is for
        RecipientPhone      NVARCHAR(50)   NULL,
        Status              VARCHAR(20)    NOT NULL,   -- Sending | Sent | Failed | Skipped
        Message             NVARCHAR(500)  NULL,
        IsRevised           BIT            NOT NULL CONSTRAINT DF_LabReportWhatsAppLog_IsRevised DEFAULT 0,
        AttemptCount        INT            NOT NULL CONSTRAINT DF_LabReportWhatsAppLog_AttemptCount DEFAULT 0,
        TriggeredBy         VARCHAR(30)    NULL,       -- EntryApproval | PathologistApproval
        TriggeredByUserId   INT            NULL,
        CreatedDate         DATETIME2(0)   NOT NULL CONSTRAINT DF_LabReportWhatsAppLog_CreatedDate DEFAULT SYSDATETIME(),
        LastAttemptDate     DATETIME2(0)   NULL,
        SentDate            DATETIME2(0)   NULL
    );
    CREATE UNIQUE INDEX UX_LabReportWhatsAppLog_Order_Final ON dbo.LabReportWhatsAppLog (LabOrderId, FinalApprovedOn);
    PRINT 'Created dbo.LabReportWhatsAppLog.';
END
ELSE PRINT 'dbo.LabReportWhatsAppLog already exists.';
GO

-- Final = every reportable test of the bill is approved: active, not cancelled, not outsourced;
-- mirrors dbo.usp_LabReportEmail_GetState, plus the patient's phone number and the B2B/B2C flag.
CREATE OR ALTER PROCEDURE dbo.usp_LabReportWhatsApp_GetState
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Total INT, @Approved INT, @FinalApprovedOn DATETIME2(0);

    SELECT
        @Total    = COUNT(1),
        @Approved = SUM(CASE WHEN led.ReportStatusId = 5 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN 1 ELSE 0 END),
        @FinalApprovedOn = MAX(CASE WHEN led.ReportStatusId = 5 THEN COALESCE(led.Approved_Date, led.ModifiedDate) END)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND ISNULL(sc.Iscancelled, 0) = 0
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND sc.CollectionstatusID <> 4;

    SELECT
        lo.LabOrderId,
        lo.BranchId,
        lo.BillNo,
        lo.TokenNo,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        NULLIF(LTRIM(RTRIM(p.PhoneNumber)), '') AS PatientPhone,
        CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B,
        ISNULL(@Total, 0)    AS TotalTests,
        ISNULL(@Approved, 0) AS ApprovedTests,
        CAST(CASE WHEN ISNULL(@Total, 0) > 0 AND @Approved = @Total AND @FinalApprovedOn IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsFinal,
        @FinalApprovedOn AS FinalApprovedOn
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    WHERE lo.LabOrderId = @LabOrderId AND lo.IsActive = 1;
END;
GO

-- Proceed = 1 when this caller should send now. A row already Sent, or being sent by another request
-- (Sending, less than 10 minutes old), is left alone; a Failed / Skipped / stale row is taken again.
CREATE OR ALTER PROCEDURE dbo.usp_LabReportWhatsApp_Claim
    @LabOrderId      INT,
    @BranchId        INT,
    @BillNo          NVARCHAR(50)  = NULL,
    @FinalApprovedOn DATETIME2(0),
    @RecipientPhone  NVARCHAR(50)  = NULL,
    @TriggeredBy     VARCHAR(30)   = NULL,
    @UserId          INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Id INT, @Status VARCHAR(20), @Last DATETIME2(0), @Proceed BIT = 0;
    DECLARE @IsRevised BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.LabReportWhatsAppLog
                                                WHERE LabOrderId = @LabOrderId AND Status = 'Sent'
                                                  AND FinalApprovedOn <> @FinalApprovedOn) THEN 1 ELSE 0 END;

    SELECT @Id = LabReportWhatsAppLogId, @Status = Status, @Last = LastAttemptDate
    FROM dbo.LabReportWhatsAppLog WITH (UPDLOCK, HOLDLOCK)
    WHERE LabOrderId = @LabOrderId AND FinalApprovedOn = @FinalApprovedOn;

    IF @Id IS NULL
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.LabReportWhatsAppLog (LabOrderId, BranchId, BillNo, FinalApprovedOn, RecipientPhone, Status,
                                                   IsRevised, AttemptCount, TriggeredBy, TriggeredByUserId, LastAttemptDate)
            VALUES (@LabOrderId, @BranchId, @BillNo, @FinalApprovedOn, @RecipientPhone, 'Sending',
                    @IsRevised, 1, @TriggeredBy, @UserId, SYSDATETIME());
            SET @Id = SCOPE_IDENTITY();
            SET @Proceed = 1;
        END TRY
        BEGIN CATCH
            SET @Proceed = 0;   -- another request claimed it first (unique index)
        END CATCH
    END
    ELSE IF @Status IN ('Failed', 'Skipped')
         OR (@Status = 'Sending' AND (@Last IS NULL OR @Last < DATEADD(MINUTE, -10, SYSDATETIME())))
    BEGIN
        UPDATE dbo.LabReportWhatsAppLog
           SET Status = 'Sending', RecipientPhone = @RecipientPhone, IsRevised = @IsRevised,
               AttemptCount = AttemptCount + 1, TriggeredBy = @TriggeredBy, TriggeredByUserId = @UserId,
               LastAttemptDate = SYSDATETIME(), Message = NULL
         WHERE LabReportWhatsAppLogId = @Id;
        SET @Proceed = 1;
    END

    SELECT @Id AS LabReportWhatsAppLogId, @Proceed AS Proceed, @IsRevised AS IsRevised, @Status AS PreviousStatus;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReportWhatsApp_Complete
    @LabReportWhatsAppLogId INT,
    @Status                 VARCHAR(20),
    @Message                NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.LabReportWhatsAppLog
       SET Status   = @Status,
           Message  = LEFT(@Message, 500),
           SentDate = CASE WHEN @Status = 'Sent' THEN SYSDATETIME() ELSE SentDate END
     WHERE LabReportWhatsAppLogId = @LabReportWhatsAppLogId;
END;
GO

PRINT 'Script 2156 applied: Lab report WhatsApp notification objects ready.';
GO
