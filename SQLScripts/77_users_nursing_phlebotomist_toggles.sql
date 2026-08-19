-- ============================================================================
-- Migration: 77_users_nursing_phlebotomist_toggles.sql
-- Description: Add IsNursingStaff and IsPhlebotomist toggle columns to Users table
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'IsNursingStaff'
)
BEGIN
    ALTER TABLE dbo.Users 
    ADD IsNursingStaff BIT NOT NULL CONSTRAINT DF_Users_IsNursingStaff DEFAULT (0);
    PRINT 'Added column IsNursingStaff to Users table.';
END
ELSE
BEGIN
    PRINT 'Column IsNursingStaff already exists in Users table.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'IsPhlebotomist'
)
BEGIN
    ALTER TABLE dbo.Users 
    ADD IsPhlebotomist BIT NOT NULL CONSTRAINT DF_Users_IsPhlebotomist DEFAULT (0);
    PRINT 'Added column IsPhlebotomist to Users table.';
END
ELSE
BEGIN
    PRINT 'Column IsPhlebotomist already exists in Users table.';
END
GO

-- Seed / Update sample nurse and phlebotomist flags if appropriate
IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username LIKE '%nurse%' OR Role LIKE '%Nurse%')
BEGIN
    UPDATE dbo.Users 
    SET IsNursingStaff = 1 
    WHERE (Username LIKE '%nurse%' OR Role LIKE '%Nurse%') AND IsNursingStaff = 0;
END
GO
