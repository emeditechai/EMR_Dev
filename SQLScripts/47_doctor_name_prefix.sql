USE [Dev_EMR];
GO

-- ============================================================
-- 47_doctor_name_prefix.sql
-- Adds NamePrefix column to DoctorMaster so each doctor can
-- have a prefix like 'Dr.', 'Prof.', 'Mr.', 'Ms.'.
-- ============================================================

-- 1. Add NamePrefix column to DoctorMaster (nullable, default to NULL initially)
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.DoctorMaster')
      AND name = 'NamePrefix'
)
BEGIN
    ALTER TABLE dbo.DoctorMaster
    ADD NamePrefix NVARCHAR(20) NULL;
    PRINT 'Column NamePrefix added to DoctorMaster.';
END
ELSE
BEGIN
    PRINT 'Column NamePrefix already exists in DoctorMaster. Skipped.';
END
GO

-- 2. Backfill existing records to 'Dr.'
UPDATE dbo.DoctorMaster
SET NamePrefix = 'Dr.'
WHERE NamePrefix IS NULL;
PRINT 'Existing DoctorMaster records updated with default NamePrefix (Dr.).';
GO
