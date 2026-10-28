-- ============================================================================================================
-- 2342  OPD > Certificates: WhatsApp / e-mail to the patient when a certificate is issued (after 2341)
--   * Hospital Settings > OPD Configuration > "Notification Required for Issue Certificate" (default No)
--   * CertificateNotificationLog: one row per send attempt and channel (shown on the certificate page)
--   * POST Certificates/Notify ("Send to patient" again) under the ISSUE control of OPD.CERTIFICATES
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'OpdCertificateNotificationRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD OpdCertificateNotificationRequired BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_OpdCertificateNotificationRequired DEFAULT (0);
GO

IF OBJECT_ID('dbo.CertificateNotificationLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CertificateNotificationLog (
        LogId          INT            NOT NULL IDENTITY(1,1) CONSTRAINT PK_CertificateNotificationLog PRIMARY KEY,
        CertificateId  INT            NOT NULL CONSTRAINT FK_CertificateNotificationLog_Certificate REFERENCES dbo.PatientCertificate (CertificateId),
        BranchId       INT            NOT NULL,
        Channel        VARCHAR(10)    NOT NULL,          -- WhatsApp | Email
        Recipient      NVARCHAR(200)  NULL,
        Status         VARCHAR(10)    NOT NULL,          -- Sent | Skipped | Failed
        Message        NVARCHAR(500)  NULL,
        SentBy         INT            NULL,
        SentOn         DATETIME       NOT NULL CONSTRAINT DF_CertificateNotificationLog_SentOn DEFAULT (GETDATE())
    );
    CREATE INDEX IX_CertificateNotificationLog_Certificate ON dbo.CertificateNotificationLog (CertificateId, SentOn DESC);
END
GO

DECLARE @page INT, @ctl INT;
SELECT TOP 1 @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = N'OPD.CERTIFICATES' ORDER BY Page_ID;
SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'ISSUE';
IF @page IS NOT NULL AND @ctl IS NOT NULL
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'Certificates', @Action = N'Notify', @Source = 'SEED';
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2342 applied: certificate WhatsApp / e-mail notification (Hospital Settings switch, send log).';
GO
