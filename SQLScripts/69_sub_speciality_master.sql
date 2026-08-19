-- ============================================================================
-- Script: 69_sub_speciality_master.sql
-- Description: Create DoctorSubSpecialityMaster table linked to DoctorSpecialityMaster
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_NAME = 'DoctorSubSpecialityMaster'
)
BEGIN
    CREATE TABLE dbo.DoctorSubSpecialityMaster (
        SubSpecialityId   INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId         INT           NOT NULL CONSTRAINT DF_DoctorSubSpecialityMaster_CompanyId DEFAULT(1),
        BranchId          INT           NULL,
        SpecialityId      INT           NOT NULL,
        SubSpecialityCode NVARCHAR(50)  NOT NULL,
        SubSpecialityName NVARCHAR(150) NOT NULL,
        Description       NVARCHAR(500) NULL,
        IsActive          BIT           NOT NULL CONSTRAINT DF_DoctorSubSpecialityMaster_IsActive DEFAULT(1),
        CreatedBy         INT           NULL,
        CreatedDate       DATETIME2     NOT NULL CONSTRAINT DF_DoctorSubSpecialityMaster_CreatedDate DEFAULT(GETDATE()),
        ModifiedBy        INT           NULL,
        ModifiedDate      DATETIME2     NULL,
        CONSTRAINT FK_DoctorSubSpecialityMaster_Speciality 
            FOREIGN KEY (SpecialityId) REFERENCES dbo.DoctorSpecialityMaster(SpecialityId) ON DELETE CASCADE,
        CONSTRAINT FK_DoctorSubSpecialityMaster_Company 
            FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId),
        CONSTRAINT UQ_DoctorSubSpecialityMaster_Code 
            UNIQUE (CompanyId, SubSpecialityCode)
    );

    CREATE INDEX IX_DoctorSubSpecialityMaster_SpecialityId ON dbo.DoctorSubSpecialityMaster(SpecialityId);
    CREATE INDEX IX_DoctorSubSpecialityMaster_CompanyId ON dbo.DoctorSubSpecialityMaster(CompanyId);
    CREATE INDEX IX_DoctorSubSpecialityMaster_BranchId ON dbo.DoctorSubSpecialityMaster(BranchId);

    PRINT 'DoctorSubSpecialityMaster table created.';
END
ELSE
BEGIN
    PRINT 'DoctorSubSpecialityMaster table already exists.';
END
GO

-- Seed standard Sub-Specialities for existing Specialities if empty
IF NOT EXISTS (SELECT 1 FROM dbo.DoctorSubSpecialityMaster)
BEGIN
    -- Get some existing Speciality IDs
    DECLARE @OphthId INT = (SELECT TOP 1 SpecialityId FROM dbo.DoctorSpecialityMaster WHERE SpecialityName LIKE '%Ophthal%' OR SpecialityCode LIKE '%OPH%');
    DECLARE @CardioId INT = (SELECT TOP 1 SpecialityId FROM dbo.DoctorSpecialityMaster WHERE SpecialityName LIKE '%Cardio%' OR SpecialityCode LIKE '%CARD%');
    DECLARE @OrthoId INT = (SELECT TOP 1 SpecialityId FROM dbo.DoctorSpecialityMaster WHERE SpecialityName LIKE '%Ortho%' OR SpecialityCode LIKE '%ORT%');
    DECLARE @DefaultSpecId INT = (SELECT TOP 1 SpecialityId FROM dbo.DoctorSpecialityMaster ORDER BY SpecialityId);

    IF @OphthId IS NOT NULL
    BEGIN
        INSERT INTO dbo.DoctorSubSpecialityMaster (CompanyId, SpecialityId, SubSpecialityCode, SubSpecialityName, Description, IsActive, CreatedDate) VALUES
        (1, @OphthId, 'RETINA', 'Retina & Vitreous Services', 'Diagnosis and surgical treatment of retinal disorders', 1, GETDATE()),
        (1, @OphthId, 'CORNEA', 'Cornea & Refractive Surgery', 'Corneal transplants, LASIK, and anterior segment care', 1, GETDATE()),
        (1, @OphthId, 'GLAUCOMA', 'Glaucoma & Optic Nerve Care', 'Medical and laser treatment for elevated intraocular pressure', 1, GETDATE()),
        (1, @OphthId, 'PAED-OPH', 'Pediatric Ophthalmology & Strabismus', 'Childhood eye care and squints', 1, GETDATE());
    END

    IF @CardioId IS NOT NULL
    BEGIN
        INSERT INTO dbo.DoctorSubSpecialityMaster (CompanyId, SpecialityId, SubSpecialityCode, SubSpecialityName, Description, IsActive, CreatedDate) VALUES
        (1, @CardioId, 'INT-CARD', 'Interventional Cardiology', 'Angioplasty, catheterization, and stent procedures', 1, GETDATE()),
        (1, @CardioId, 'EP-CARD', 'Cardiac Electrophysiology', 'Arrhythmia management and pacemaker implantation', 1, GETDATE()),
        (1, @CardioId, 'PED-CARD', 'Pediatric Cardiology', 'Congenital heart defect assessment and management', 1, GETDATE());
    END

    IF @OrthoId IS NOT NULL
    BEGIN
        INSERT INTO dbo.DoctorSubSpecialityMaster (CompanyId, SpecialityId, SubSpecialityCode, SubSpecialityName, Description, IsActive, CreatedDate) VALUES
        (1, @OrthoId, 'JOINT-REP', 'Joint Replacement & Arthroplasty', 'Total knee and hip replacements', 1, GETDATE()),
        (1, @OrthoId, 'SPINE-SURG', 'Spine Surgery', 'Scoliosis, disc prolapse, and spinal decompression', 1, GETDATE()),
        (1, @OrthoId, 'SPORTS-MED', 'Sports Medicine & Arthroscopy', 'Ligament reconstruction and minimally invasive joint repairs', 1, GETDATE());
    END

    IF @OphthId IS NULL AND @CardioId IS NULL AND @DefaultSpecId IS NOT NULL
    BEGIN
        INSERT INTO dbo.DoctorSubSpecialityMaster (CompanyId, SpecialityId, SubSpecialityCode, SubSpecialityName, Description, IsActive, CreatedDate) VALUES
        (1, @DefaultSpecId, 'GEN-SUB1', 'General Sub-Speciality A', 'Clinical sub-speciality practice unit', 1, GETDATE()),
        (1, @DefaultSpecId, 'GEN-SUB2', 'General Sub-Speciality B', 'Advanced consultative care unit', 1, GETDATE());
    END

    PRINT 'DoctorSubSpecialityMaster seeded successfully.';
END
GO
