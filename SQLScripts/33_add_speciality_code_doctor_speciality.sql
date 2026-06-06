-- ============================================================
-- 33_add_speciality_code_doctor_speciality.sql
-- Adds SpecialityCode to DoctorSpecialityMaster
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'DoctorSpecialityMaster' AND COLUMN_NAME = 'SpecialityCode'
)
BEGIN
    -- Add the column allowing NULLs initially
    ALTER TABLE DoctorSpecialityMaster ADD SpecialityCode NVARCHAR(50) NULL;

    -- Update existing records to have SpecialityCode = SpecialityName (truncated to 50 chars if needed)
    EXEC('UPDATE DoctorSpecialityMaster SET SpecialityCode = LEFT(SpecialityName, 50)');

    -- Now alter column to NOT NULL
    ALTER TABLE DoctorSpecialityMaster ALTER COLUMN SpecialityCode NVARCHAR(50) NOT NULL;

    -- Add UNIQUE constraint
    ALTER TABLE DoctorSpecialityMaster ADD CONSTRAINT UQ_DoctorSpecialityMaster_SpecialityCode UNIQUE (SpecialityCode);

    PRINT 'Added SpecialityCode to DoctorSpecialityMaster and populated existing data.';
END
ELSE
BEGIN
    PRINT 'SpecialityCode already exists in DoctorSpecialityMaster.';
END
GO
