-- ============================================================================
-- Script: 70_clinical_unit_master.sql
-- Description: Create ClinicalUnitMaster table with Department, Speciality, and Consultant links
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_NAME = 'ClinicalUnitMaster'
)
BEGIN
    CREATE TABLE dbo.ClinicalUnitMaster (
        UnitId                     INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId                  INT           NOT NULL CONSTRAINT DF_ClinicalUnitMaster_CompanyId DEFAULT(1),
        BranchId                   INT           NULL,
        DepartmentId               INT           NOT NULL,
        SpecialityId               INT           NOT NULL,
        UnitCode                   NVARCHAR(50)  NOT NULL,
        UnitName                   NVARCHAR(150) NOT NULL,
        ConsultantInChargeDoctorId INT           NULL,
        Description                NVARCHAR(500) NULL,
        IsActive                   BIT           NOT NULL CONSTRAINT DF_ClinicalUnitMaster_IsActive DEFAULT(1),
        CreatedBy                  INT           NULL,
        CreatedDate                DATETIME2     NOT NULL CONSTRAINT DF_ClinicalUnitMaster_CreatedDate DEFAULT(GETDATE()),
        ModifiedBy                 INT           NULL,
        ModifiedDate               DATETIME2     NULL,
        CONSTRAINT FK_ClinicalUnitMaster_Department 
            FOREIGN KEY (DepartmentId) REFERENCES dbo.DepartmentMaster(DeptId),
        CONSTRAINT FK_ClinicalUnitMaster_Speciality 
            FOREIGN KEY (SpecialityId) REFERENCES dbo.DoctorSpecialityMaster(SpecialityId),
        CONSTRAINT FK_ClinicalUnitMaster_Consultant 
            FOREIGN KEY (ConsultantInChargeDoctorId) REFERENCES dbo.DoctorMaster(DoctorId),
        CONSTRAINT FK_ClinicalUnitMaster_Company 
            FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId),
        CONSTRAINT UQ_ClinicalUnitMaster_Code 
            UNIQUE (CompanyId, UnitCode)
    );

    CREATE INDEX IX_ClinicalUnitMaster_DepartmentId ON dbo.ClinicalUnitMaster(DepartmentId);
    CREATE INDEX IX_ClinicalUnitMaster_SpecialityId ON dbo.ClinicalUnitMaster(SpecialityId);
    CREATE INDEX IX_ClinicalUnitMaster_ConsultantId ON dbo.ClinicalUnitMaster(ConsultantInChargeDoctorId);
    CREATE INDEX IX_ClinicalUnitMaster_CompanyId ON dbo.ClinicalUnitMaster(CompanyId);
    CREATE INDEX IX_ClinicalUnitMaster_BranchId ON dbo.ClinicalUnitMaster(BranchId);

    PRINT 'ClinicalUnitMaster table created.';
END
ELSE
BEGIN
    PRINT 'ClinicalUnitMaster table already exists.';
END
GO

-- Seed sample clinical units if table is empty
IF NOT EXISTS (SELECT 1 FROM dbo.ClinicalUnitMaster)
BEGIN
    DECLARE @DeptOpdCard INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptCode = 'OPD-CARD');
    DECLARE @DeptOpdSurg INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptCode = 'IPD-SURG' OR DeptType = 'IPD');
    DECLARE @DeptOpdGen INT  = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptCode = 'OPD-GEN' OR DeptType = 'OPD');

    DECLARE @SpecCardio INT = (SELECT TOP 1 SpecialityId FROM dbo.DoctorSpecialityMaster WHERE SpecialityName LIKE '%Cardio%' OR SpecialityCode LIKE '%CARD%');
    DECLARE @SpecGeneral INT = (SELECT TOP 1 SpecialityId FROM dbo.DoctorSpecialityMaster WHERE SpecialityName LIKE '%General%' OR SpecialityCode LIKE '%GEN%');
    DECLARE @SpecOrtho INT = (SELECT TOP 1 SpecialityId FROM dbo.DoctorSpecialityMaster WHERE SpecialityName LIKE '%Ortho%' OR SpecialityCode LIKE '%ORT%');

    -- Fallback default IDs if specific ones not found
    IF @DeptOpdGen IS NULL SET @DeptOpdGen = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster ORDER BY DeptId);
    IF @DeptOpdCard IS NULL SET @DeptOpdCard = @DeptOpdGen;
    IF @DeptOpdSurg IS NULL SET @DeptOpdSurg = @DeptOpdGen;

    IF @SpecGeneral IS NULL SET @SpecGeneral = (SELECT TOP 1 SpecialityId FROM dbo.DoctorSpecialityMaster ORDER BY SpecialityId);
    IF @SpecCardio IS NULL SET @SpecCardio = @SpecGeneral;
    IF @SpecOrtho IS NULL SET @SpecOrtho = @SpecGeneral;

    DECLARE @DocCardio INT = (SELECT TOP 1 DoctorId FROM dbo.DoctorMaster WHERE PrimarySpecialityId = @SpecCardio AND IsActive = 1);
    DECLARE @DocGeneral INT = (SELECT TOP 1 DoctorId FROM dbo.DoctorMaster WHERE PrimarySpecialityId = @SpecGeneral AND IsActive = 1);
    IF @DocCardio IS NULL SET @DocCardio = @DocGeneral;

    INSERT INTO dbo.ClinicalUnitMaster (
        CompanyId, BranchId, DepartmentId, SpecialityId, UnitCode, UnitName, ConsultantInChargeDoctorId, Description, IsActive, CreatedDate
    ) VALUES
    (1, 1, @DeptOpdCard, @SpecCardio, 'CARD-U1', 'Cardiology Unit 1', @DocCardio, 'Clinical Unit 1 for invasive and non-invasive adult cardiology consultations', 1, GETDATE()),
    (1, 1, @DeptOpdCard, @SpecCardio, 'CARD-U2', 'Cardiology Unit 2', @DocCardio, 'Clinical Unit 2 specializing in heart failure management and electrophysiology', 1, GETDATE()),
    (1, 1, @DeptOpdSurg, @SpecGeneral, 'SURG-U1', 'Surgical Unit 1', @DocGeneral, 'General and laparoscopic surgery clinical unit', 1, GETDATE()),
    (1, 1, @DeptOpdGen, @SpecGeneral, 'MED-U1', 'General Medicine Unit', @DocGeneral, 'Comprehensive adult internal medicine unit', 1, GETDATE());

    PRINT 'ClinicalUnitMaster seeded successfully.';
END
GO
