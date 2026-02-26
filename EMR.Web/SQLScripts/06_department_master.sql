-- ============================================================
-- Department Master
-- Run on: Dev_EMR (198.38.81.123)
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_NAME = 'DepartmentMaster'
)
BEGIN
    CREATE TABLE DepartmentMaster (
        DeptId       INT IDENTITY(1,1) PRIMARY KEY,
        DeptCode     NVARCHAR(20)  NOT NULL,
        DeptName     NVARCHAR(150) NOT NULL,
        DeptType     NVARCHAR(20)  NOT NULL,   -- OPD | IPD | Lab | Med
        IsActive     BIT           NOT NULL DEFAULT 1,
        CreatedBy    INT           NULL,
        CreatedDate  DATETIME      NOT NULL DEFAULT GETUTCDATE(),
        ModifiedBy   INT           NULL,
        ModifiedDate DATETIME      NULL,

        CONSTRAINT UQ_DepartmentMaster_DeptCode UNIQUE (DeptCode)
    );

    PRINT 'DepartmentMaster table created.';
END
ELSE
    PRINT 'DepartmentMaster table already exists.';
GO

-- ── Seed Data ─────────────────────────────────────────────────
SET IDENTITY_INSERT DepartmentMaster ON;

MERGE DepartmentMaster AS target
USING (VALUES
    (1,  'OPD-GEN',  'General OPD',               'OPD'),
    (2,  'OPD-CARD', 'Cardiology OPD',             'OPD'),
    (3,  'OPD-ORTH', 'Orthopaedics OPD',           'OPD'),
    (4,  'OPD-PEDI', 'Paediatrics OPD',            'OPD'),
    (5,  'OPD-GYNE', 'Gynaecology OPD',            'OPD'),
    (6,  'IPD-GEN',  'General Ward (IPD)',          'IPD'),
    (7,  'IPD-ICU',  'Intensive Care Unit',         'IPD'),
    (8,  'IPD-NICU', 'Neonatal ICU',                'IPD'),
    (9,  'IPD-SURG', 'Surgical Ward',               'IPD'),
    (10, 'IPD-MATN', 'Maternity Ward',              'IPD'),
    (11, 'LAB-BIOL', 'Biochemistry Lab',            'Lab'),
    (12, 'LAB-MICR', 'Microbiology Lab',            'Lab'),
    (13, 'LAB-PATH', 'Pathology Lab',               'Lab'),
    (14, 'LAB-RADI', 'Radiology',                   'Lab'),
    (15, 'LAB-SONO', 'Sonography',                  'Lab'),
    (16, 'MED-PHAR', 'Pharmacy',                    'Med'),
    (17, 'MED-STOR', 'Medical Store',               'Med'),
    (18, 'MED-EMER', 'Emergency Medicine',          'Med'),
    (19, 'MED-ANES', 'Anaesthesia',                 'Med'),
    (20, 'MED-BLDG', 'Blood Bank',                  'Med')
) AS source (DeptId, DeptCode, DeptName, DeptType)
ON target.DeptId = source.DeptId
WHEN NOT MATCHED THEN
    INSERT (DeptId, DeptCode, DeptName, DeptType, IsActive, CreatedDate)
    VALUES (source.DeptId, source.DeptCode, source.DeptName, source.DeptType, 1, GETUTCDATE());

SET IDENTITY_INSERT DepartmentMaster OFF;
GO

PRINT 'DepartmentMaster seed complete.';
