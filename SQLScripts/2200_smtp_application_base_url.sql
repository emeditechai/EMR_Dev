-- Adds ApplicationBaseUrl to SMTP configuration: the public URL of the app,
-- used to build links (e.g. the login page) in outgoing emails.
IF COL_LENGTH('dbo.SmtpEmailConfiguration', 'ApplicationBaseUrl') IS NULL
BEGIN
    ALTER TABLE dbo.SmtpEmailConfiguration ADD ApplicationBaseUrl NVARCHAR(300) NULL;
END
GO
