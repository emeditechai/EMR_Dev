-- ============================================================================
-- Migration: 101_users_profile_demographics_and_geography.sql
-- Description: Add DateOfJoining, DateOfBirth, Address, Pincode, CountryId, 
--              StateId, and CityId to dbo.Users
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'DateOfJoining'
)
BEGIN
    ALTER TABLE dbo.Users ADD DateOfJoining DATETIME NULL;
    PRINT 'Added column DateOfJoining to Users table.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'DateOfBirth'
)
BEGIN
    ALTER TABLE dbo.Users ADD DateOfBirth DATETIME NULL;
    PRINT 'Added column DateOfBirth to Users table.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'Address'
)
BEGIN
    ALTER TABLE dbo.Users ADD Address NVARCHAR(500) NULL;
    PRINT 'Added column Address to Users table.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'Pincode'
)
BEGIN
    ALTER TABLE dbo.Users ADD Pincode NVARCHAR(20) NULL;
    PRINT 'Added column Pincode to Users table.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'CountryId'
)
BEGIN
    ALTER TABLE dbo.Users ADD CountryId INT NULL;
    PRINT 'Added column CountryId to Users table.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'StateId'
)
BEGIN
    ALTER TABLE dbo.Users ADD StateId INT NULL;
    PRINT 'Added column StateId to Users table.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'CityId'
)
BEGIN
    ALTER TABLE dbo.Users ADD CityId INT NULL;
    PRINT 'Added column CityId to Users table.';
END
GO

-- Add foreign key constraints if matching tables exist and constraints do not yet exist
IF OBJECT_ID('dbo.CountryMaster', 'U') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Users_CountryMaster' AND parent_object_id = OBJECT_ID('dbo.Users')
)
BEGIN
    ALTER TABLE dbo.Users ADD CONSTRAINT FK_Users_CountryMaster FOREIGN KEY (CountryId) REFERENCES dbo.CountryMaster(CountryId);
    PRINT 'Added FK_Users_CountryMaster.';
END
GO

IF OBJECT_ID('dbo.StateMaster', 'U') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Users_StateMaster' AND parent_object_id = OBJECT_ID('dbo.Users')
)
BEGIN
    ALTER TABLE dbo.Users ADD CONSTRAINT FK_Users_StateMaster FOREIGN KEY (StateId) REFERENCES dbo.StateMaster(StateId);
    PRINT 'Added FK_Users_StateMaster.';
END
GO

IF OBJECT_ID('dbo.CityMaster', 'U') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Users_CityMaster' AND parent_object_id = OBJECT_ID('dbo.Users')
)
BEGIN
    ALTER TABLE dbo.Users ADD CONSTRAINT FK_Users_CityMaster FOREIGN KEY (CityId) REFERENCES dbo.CityMaster(CityId);
    PRINT 'Added FK_Users_CityMaster.';
END
GO
