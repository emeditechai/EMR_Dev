-- ============================================================================
-- Migration: 100_users_department_and_lab_toggles.sql
-- Description: Add DepartmentIds, IsPathologist, and IsLabTechnician to Users table
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'DepartmentIds'
)
BEGIN
    ALTER TABLE dbo.Users 
    ADD DepartmentIds NVARCHAR(250) NULL;
    PRINT 'Added column DepartmentIds to Users table.';
END
ELSE
BEGIN
    PRINT 'Column DepartmentIds already exists in Users table.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'IsPathologist'
)
BEGIN
    ALTER TABLE dbo.Users 
    ADD IsPathologist BIT NOT NULL CONSTRAINT DF_Users_IsPathologist DEFAULT (0);
    PRINT 'Added column IsPathologist to Users table.';
END
ELSE
BEGIN
    PRINT 'Column IsPathologist already exists in Users table.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'IsLabTechnician'
)
BEGIN
    ALTER TABLE dbo.Users 
    ADD IsLabTechnician BIT NOT NULL CONSTRAINT DF_Users_IsLabTechnician DEFAULT (0);
    PRINT 'Added column IsLabTechnician to Users table.';
END
ELSE
BEGIN
    PRINT 'Column IsLabTechnician already exists in Users table.';
END
GO

-- Seed / Update sample flags for existing users if matching pathologist / technician keywords
IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username LIKE '%patholog%' OR FullName LIKE '%Patholog%')
BEGIN
    UPDATE dbo.Users 
    SET IsPathologist = 1 
    WHERE (Username LIKE '%patholog%' OR FullName LIKE '%Patholog%') AND IsPathologist = 0;
END
GO

IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username LIKE '%labtech%' OR Username LIKE '%technician%' OR FullName LIKE '%Technician%')
BEGIN
    UPDATE dbo.Users 
    SET IsLabTechnician = 1 
    WHERE (Username LIKE '%labtech%' OR Username LIKE '%technician%' OR FullName LIKE '%Technician%') AND IsLabTechnician = 0;
END
GO
