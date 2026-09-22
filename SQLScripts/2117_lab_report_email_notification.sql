-- ============================================================================
-- Migration: 2117_lab_report_email_notification.sql
-- Description:
--   Hospital Settings > LAB > "Email Notification to Patient (LAB Reports)" (HospitalSettings.LabReportEmailNotificationRequired):
--   when YES, the patient is emailed the final approved lab report (PDF attached) through the booking
--   branch's SMTP configuration, as soon as the whole bill is approved.
--
--   dbo.LabReportEmailLog                 one row per bill per final approval (LabOrderId + FinalApprovedOn is unique),
--                                          so the same final report is never mailed twice, while a report that is
--                                          un-approved and approved again is mailed once more as a revised report.
--   dbo.usp_LabReportEmail_GetState       is the bill final, who / where to send, is the setting on
--   dbo.usp_LabReportEmail_Claim          takes the send for this final approval (safe when two approvals race)
--   dbo.usp_LabReportEmail_Complete       records Sent / Failed / Skipped
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.LabReportEmailLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabReportEmailLog
    (
        LabReportEmailLogId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabReportEmailLog PRIMARY KEY,
        LabOrderId          INT            NOT NULL,
        BranchId            INT            NOT NULL,
        BillNo              NVARCHAR(50)   NULL,
        FinalApprovedOn     DATETIME2(0)   NOT NULL,   -- latest approval time of the bill = which "final" this row is for
        RecipientEmail      NVARCHAR(200)  NULL,
        Status              VARCHAR(20)    NOT NULL,   -- Sending | Sent | Failed | Skipped
        Message             NVARCHAR(500)  NULL,
        IsRevised           BIT            NOT NULL CONSTRAINT DF_LabReportEmailLog_IsRevised DEFAULT 0,
        AttemptCount        INT            NOT NULL CONSTRAINT DF_LabReportEmailLog_AttemptCount DEFAULT 0,
        TriggeredBy         VARCHAR(30)    NULL,       -- EntryApproval | PathologistApproval | PaymentCleared
        TriggeredByUserId   INT            NULL,
        CreatedDate         DATETIME2(0)   NOT NULL CONSTRAINT DF_LabReportEmailLog_CreatedDate DEFAULT SYSDATETIME(),
        LastAttemptDate     DATETIME2(0)   NULL,
        SentDate            DATETIME2(0)   NULL
    );
    CREATE UNIQUE INDEX UX_LabReportEmailLog_Order_Final ON dbo.LabReportEmailLog (LabOrderId, FinalApprovedOn);
    PRINT 'Created dbo.LabReportEmailLog.';
END
ELSE PRINT 'dbo.LabReportEmailLog already exists.';
GO

-- Final = every reportable test of the bill is approved: active, not cancelled, not outsourced;
-- a rejected sample (status 4) is left out, while one still to be collected / re-collected keeps the bill open.
CREATE OR ALTER PROCEDURE dbo.usp_LabReportEmail_GetState
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
        NULLIF(LTRIM(RTRIM(p.EmailId)), '') AS PatientEmail,
        ISNULL(@Total, 0)    AS TotalTests,
        ISNULL(@Approved, 0) AS ApprovedTests,
        CAST(CASE WHEN ISNULL(@Total, 0) > 0 AND @Approved = @Total AND @FinalApprovedOn IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsFinal,
        @FinalApprovedOn AS FinalApprovedOn,
        CAST(ISNULL(hs.LabReportEmailNotificationRequired, 0) AS BIT) AS EmailEnabled
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    OUTER APPLY (SELECT TOP 1 h.LabReportEmailNotificationRequired
                   FROM dbo.HospitalSettings h
                  WHERE h.BranchID = lo.BranchId AND h.IsActive = 1
                  ORDER BY h.Id DESC) hs
    WHERE lo.LabOrderId = @LabOrderId AND lo.IsActive = 1;
END;
GO

-- Proceed = 1 when this caller should send now. A row already Sent, or being sent by another request
-- (Sending, less than 10 minutes old), is left alone; a Failed / Skipped / stale row is taken again.
CREATE OR ALTER PROCEDURE dbo.usp_LabReportEmail_Claim
    @LabOrderId      INT,
    @BranchId        INT,
    @BillNo          NVARCHAR(50)  = NULL,
    @FinalApprovedOn DATETIME2(0),
    @RecipientEmail  NVARCHAR(200) = NULL,
    @TriggeredBy     VARCHAR(30)   = NULL,
    @UserId          INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Id INT, @Status VARCHAR(20), @Last DATETIME2(0), @Proceed BIT = 0;
    DECLARE @IsRevised BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.LabReportEmailLog
                                                WHERE LabOrderId = @LabOrderId AND Status = 'Sent'
                                                  AND FinalApprovedOn <> @FinalApprovedOn) THEN 1 ELSE 0 END;

    SELECT @Id = LabReportEmailLogId, @Status = Status, @Last = LastAttemptDate
    FROM dbo.LabReportEmailLog WITH (UPDLOCK, HOLDLOCK)
    WHERE LabOrderId = @LabOrderId AND FinalApprovedOn = @FinalApprovedOn;

    IF @Id IS NULL
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.LabReportEmailLog (LabOrderId, BranchId, BillNo, FinalApprovedOn, RecipientEmail, Status,
                                               IsRevised, AttemptCount, TriggeredBy, TriggeredByUserId, LastAttemptDate)
            VALUES (@LabOrderId, @BranchId, @BillNo, @FinalApprovedOn, @RecipientEmail, 'Sending',
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
        UPDATE dbo.LabReportEmailLog
           SET Status = 'Sending', RecipientEmail = @RecipientEmail, IsRevised = @IsRevised,
               AttemptCount = AttemptCount + 1, TriggeredBy = @TriggeredBy, TriggeredByUserId = @UserId,
               LastAttemptDate = SYSDATETIME(), Message = NULL
         WHERE LabReportEmailLogId = @Id;
        SET @Proceed = 1;
    END

    SELECT @Id AS LabReportEmailLogId, @Proceed AS Proceed, @IsRevised AS IsRevised, @Status AS PreviousStatus;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReportEmail_Complete
    @LabReportEmailLogId INT,
    @Status              VARCHAR(20),
    @Message             NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.LabReportEmailLog
       SET Status   = @Status,
           Message  = LEFT(@Message, 500),
           SentDate = CASE WHEN @Status = 'Sent' THEN SYSDATETIME() ELSE SentDate END
     WHERE LabReportEmailLogId = @LabReportEmailLogId;
END;
GO

PRINT 'Lab report email notification objects ready.';
GO
