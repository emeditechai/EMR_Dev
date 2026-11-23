-- ============================================================================================================
-- Migration: 2392_lab_report_dispatch_send_report.sql
-- LAB > Report Dispatch: Action menu (Report Print / Bill / Send Report). "Send Report" sends the approved (final)
-- report by WhatsApp and e-mail through the existing senders, only when the bill has no due.
--   usp_LabReportWhatsApp_Claim / usp_LabReportEmail_Claim: @Resend = 1 lets a report that was already Sent go out again
--   (the automatic send after approval passes nothing and is unchanged). Live definitions + @Resend.
--   Permission: control SEND_REPORT on LAB.LABREPORTDISPATCH (LabReportDispatch/SendReport). No role is granted here.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReportWhatsApp_Claim
    @LabOrderId      INT,
    @BranchId        INT,
    @BillNo          NVARCHAR(50)  = NULL,
    @FinalApprovedOn DATETIME2(0),
    @RecipientPhone  NVARCHAR(50)  = NULL,
    @TriggeredBy     VARCHAR(30)   = NULL,
    @UserId          INT           = NULL,
    @Resend          BIT           = 0      -- 2392: Report Dispatch > Send Report - a report already Sent is sent again
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
    ELSE IF @Status IN ('Failed', 'Skipped') OR (@Resend = 1 AND @Status = 'Sent')
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

CREATE OR ALTER PROCEDURE dbo.usp_LabReportEmail_Claim
    @LabOrderId      INT,
    @BranchId        INT,
    @BillNo          NVARCHAR(50)  = NULL,
    @FinalApprovedOn DATETIME2(0),
    @RecipientEmail  NVARCHAR(200) = NULL,
    @TriggeredBy     VARCHAR(30)   = NULL,
    @UserId          INT           = NULL,
    @Resend          BIT           = 0      -- 2392: Report Dispatch > Send Report - a report already Sent is sent again
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
    ELSE IF @Status IN ('Failed', 'Skipped') OR (@Resend = 1 AND @Status = 'Sent')
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

DECLARE @page INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABREPORTDISPATCH';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'SEND_REPORT', @Title = N'Send report (WhatsApp / e-mail)', @Sort_Order = 30, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabReportDispatch', @Action = N'SendReport', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2392 applied: Report Dispatch - Send Report (resend allowed), SEND_REPORT control.';
GO
