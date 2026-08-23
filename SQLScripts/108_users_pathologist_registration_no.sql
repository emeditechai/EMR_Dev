-- Migration script: 104_users_pathologist_registration_no.sql
-- Purpose: Add RegistrationNo column to dbo.Users table for Pathologist credentials

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID(N'dbo.Users') AND name = 'RegistrationNo'
)
BEGIN
    ALTER TABLE dbo.Users ADD RegistrationNo NVARCHAR(100) NULL;
END
GO
