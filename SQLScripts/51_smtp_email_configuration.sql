-- ============================================================================
-- 51_smtp_email_configuration.sql
-- Creates the SmtpEmailConfiguration table for SMTP email engine settings
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'SmtpEmailConfiguration')
BEGIN
    CREATE TABLE [dbo].[SmtpEmailConfiguration]
    (
        [Id]                    INT             IDENTITY(1,1)   NOT NULL,
        [BranchId]              INT             NOT NULL,
        [ConfigName]            NVARCHAR(100)   NOT NULL,           -- Friendly name e.g. "Hospital Gmail"
        [ProviderType]          NVARCHAR(50)    NOT NULL DEFAULT 'Custom', -- Gmail, Outlook, Yahoo, Custom
        [SmtpHost]              NVARCHAR(200)   NOT NULL,
        [SmtpPort]              INT             NOT NULL DEFAULT 587,
        [UseSsl]                BIT             NOT NULL DEFAULT 1,
        [UseStartTls]           BIT             NOT NULL DEFAULT 1,
        [SenderEmail]           NVARCHAR(200)   NOT NULL,
        [SenderDisplayName]     NVARCHAR(200)   NULL,
        [Username]              NVARCHAR(200)   NOT NULL,
        [PasswordEncrypted]     NVARCHAR(500)   NOT NULL,           -- Encrypted via DataProtection API
        [IsDefault]             BIT             NOT NULL DEFAULT 0,
        [IsActive]              BIT             NOT NULL DEFAULT 1,
        [LastTestedDate]        DATETIME        NULL,               -- Last successful test email
        [LastTestResult]        NVARCHAR(500)   NULL,               -- Success / Error message
        [CreatedBy]             INT             NOT NULL,
        [CreatedDate]           DATETIME        NOT NULL DEFAULT GETDATE(),
        [ModifiedBy]            INT             NULL,
        [ModifiedDate]          DATETIME        NULL,

        CONSTRAINT [PK_SmtpEmailConfiguration] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_SmtpEmailConfiguration_BranchMaster] FOREIGN KEY ([BranchId])
            REFERENCES [dbo].[Branchmaster] ([BranchID])
    );

    PRINT 'Table SmtpEmailConfiguration created successfully.';
END
ELSE
BEGIN
    PRINT 'Table SmtpEmailConfiguration already exists — skipping.';
END
GO
