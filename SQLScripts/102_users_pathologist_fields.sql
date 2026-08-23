-- Migration script: 102_users_pathologist_fields.sql
-- Purpose: Add Pathologist specific columns to dbo.Users table

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID(N'dbo.Users') AND name = 'CertificationNo'
)
BEGIN
    ALTER TABLE dbo.Users ADD CertificationNo NVARCHAR(100) NULL;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID(N'dbo.Users') AND name = 'ShiftSlotId'
)
BEGIN
    ALTER TABLE dbo.Users ADD ShiftSlotId INT NULL;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID(N'dbo.Users') AND name = 'AssignedZoneId'
)
BEGIN
    ALTER TABLE dbo.Users ADD AssignedZoneId INT NULL;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID(N'dbo.Users') AND name = 'DailyCollectionTarget'
)
BEGIN
    ALTER TABLE dbo.Users ADD DailyCollectionTarget DECIMAL(18,2) NULL;
END
GO
