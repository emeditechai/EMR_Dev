-- ============================================================
-- Script: 60_patient_login_columns.sql
-- Description: Adds login credential columns to PatientMaster
-- ============================================================

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'PatientMaster' AND COLUMN_NAME = 'IsLoginGenerated'
)
BEGIN
    ALTER TABLE PatientMaster ADD IsLoginGenerated BIT NOT NULL DEFAULT 0;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'PatientMaster' AND COLUMN_NAME = 'Password'
)
BEGIN
    ALTER TABLE PatientMaster ADD [Password] NVARCHAR(255) NULL;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'PatientMaster' AND COLUMN_NAME = 'IsPasswordchanged'
)
BEGIN
    ALTER TABLE PatientMaster ADD IsPasswordchanged BIT NOT NULL DEFAULT 0;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'PatientMaster' AND COLUMN_NAME = 'Lastlogin'
)
BEGIN
    ALTER TABLE PatientMaster ADD Lastlogin DATETIME NULL;
END
GO
