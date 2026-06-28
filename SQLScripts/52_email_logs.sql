-- Script: 52_email_logs.sql
-- Description: Create EmailLogs table for tracking all emails sent by the SMTP engine

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[EmailLogs]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[EmailLogs] (
        [Id] INT IDENTITY(1,1) NOT NULL,
        [BranchId] INT NOT NULL,
        [ConfigId] INT NOT NULL,
        [RecipientEmail] NVARCHAR(250) NOT NULL,
        [Subject] NVARCHAR(500) NULL,
        [SentDate] DATETIME2(7) NOT NULL,
        [Status] NVARCHAR(50) NOT NULL, -- e.g., 'Success', 'Failed'
        [ErrorMessage] NVARCHAR(MAX) NULL,
        
        CONSTRAINT [PK_EmailLogs] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_EmailLogs_Branchmaster_BranchId] FOREIGN KEY ([BranchId]) REFERENCES [dbo].[Branchmaster] ([BranchID]),
        CONSTRAINT [FK_EmailLogs_SmtpEmailConfiguration_ConfigId] FOREIGN KEY ([ConfigId]) REFERENCES [dbo].[SmtpEmailConfiguration] ([Id])
    );

    CREATE NONCLUSTERED INDEX [IX_EmailLogs_BranchId] ON [dbo].[EmailLogs] ([BranchId]);
    CREATE NONCLUSTERED INDEX [IX_EmailLogs_ConfigId] ON [dbo].[EmailLogs] ([ConfigId]);
    CREATE NONCLUSTERED INDEX [IX_EmailLogs_SentDate] ON [dbo].[EmailLogs] ([SentDate] DESC);
    CREATE NONCLUSTERED INDEX [IX_EmailLogs_Status] ON [dbo].[EmailLogs] ([Status]);

    PRINT 'Table EmailLogs created successfully.'
END
ELSE
BEGIN
    PRINT 'Table EmailLogs already exists.'
END
GO
