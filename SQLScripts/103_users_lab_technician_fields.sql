-- Migration script: 103_users_lab_technician_fields.sql
-- Purpose: Add Lab Technician specific columns to dbo.Users table

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID(N'dbo.Users') AND name = 'LabTechnicianShiftSlotId'
)
BEGIN
    ALTER TABLE dbo.Users ADD LabTechnicianShiftSlotId INT NULL;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID(N'dbo.Users') AND name = 'AnalyzerTrainedOn'
)
BEGIN
    ALTER TABLE dbo.Users ADD AnalyzerTrainedOn NVARCHAR(250) NULL;
END
GO
