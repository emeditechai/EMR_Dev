-- ============================================================================================================
-- Migration: 2305_user_reports_to.sql
-- Settings > User Master: "Reports To" - the user this user reports to (any user of the same company).
-- Users.ReportsToUserId -> Users.Id (NULL = reports to nobody). User Master also checks, on save, that e-mail and
-- phone number are unique within the company (no index here: existing data may already hold duplicates; new and
-- changed values are checked by the application). Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.Users', 'ReportsToUserId') IS NULL
    ALTER TABLE dbo.Users ADD ReportsToUserId INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Users_ReportsToUser')
    ALTER TABLE dbo.Users ADD CONSTRAINT FK_Users_ReportsToUser FOREIGN KEY (ReportsToUserId) REFERENCES dbo.Users (Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Users_ReportsToUserId' AND object_id = OBJECT_ID(N'dbo.Users'))
    CREATE INDEX IX_Users_ReportsToUserId ON dbo.Users (ReportsToUserId) WHERE ReportsToUserId IS NOT NULL;
GO
PRINT 'Script 2305 applied: User Master - Reports To.';
GO
