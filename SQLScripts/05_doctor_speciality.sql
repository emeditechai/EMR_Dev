-- ============================================================
-- 05_doctor_speciality.sql
-- Creates DoctorSpecialityMaster table
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_NAME = 'DoctorSpecialityMaster'
)
BEGIN
    CREATE TABLE DoctorSpecialityMaster (
        SpecialityId    INT IDENTITY(1,1) PRIMARY KEY,
        SpecialityName  NVARCHAR(100) NOT NULL,
        IsActive        BIT           NOT NULL DEFAULT 1,
        CreatedBy       INT           NULL,
        CreatedDate     DATETIME2     NOT NULL DEFAULT GETUTCDATE(),
        ModifiedBy      INT           NULL,
        ModifiedDate    DATETIME2     NULL
    );

    PRINT 'DoctorSpecialityMaster table created.';
END
ELSE
BEGIN
    PRINT 'DoctorSpecialityMaster table already exists — skipped.';
END
GO

-- Optional seed data
IF NOT EXISTS (SELECT 1 FROM DoctorSpecialityMaster)
BEGIN
    INSERT INTO DoctorSpecialityMaster (SpecialityName, IsActive) VALUES
    ('General Medicine',        1),
    ('Cardiology',              1),
    ('Neurology',               1),
    ('Orthopaedics',            1),
    ('Dermatology',             1),
    ('Gynaecology',             1),
    ('Paediatrics',             1),
    ('Ophthalmology',           1),
    ('ENT (Ear, Nose & Throat)',1),
    ('Urology',                 1),
    ('Gastroenterology',        1),
    ('Pulmonology',             1),
    ('Psychiatry',              1),
    ('Oncology',                1),
    ('Radiology',               1),
    ('Anaesthesiology',         1),
    ('Nephrology',              1),
    ('Endocrinology',           1),
    ('Rheumatology',            1),
    ('General Surgery',         1);

    PRINT 'DoctorSpecialityMaster seeded with 20 specialities.';
END
GO
