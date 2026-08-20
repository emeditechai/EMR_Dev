-- ====================================================================================================
-- Script: 80_procedure_and_tariff_master.sql
-- Description: Creates ProcedureMaster and ProcedureTariffMaster tables, Stored Procedures for API list data,
--              and seeds standard procedure categories and initial master data.
-- ====================================================================================================

-- 1. Create dbo.ProcedureMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ProcedureMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.ProcedureMaster
    (
        ProcedureId          INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        BranchId             INT NOT NULL,
        DepartmentId         INT NOT NULL,
        SpecialityId         INT NOT NULL,
        ProcedureCode        NVARCHAR(50) NOT NULL,
        ProcedureName        NVARCHAR(200) NOT NULL,
        ProcedureCategory    NVARCHAR(100) NOT NULL,
        DurationHours        INT NOT NULL DEFAULT 0,
        DurationMinutes      INT NOT NULL DEFAULT 0,
        DurationSeconds      INT NOT NULL DEFAULT 0,
        AnaesthesiaRequired  BIT NOT NULL DEFAULT 0,
        ConsentRequired      BIT NOT NULL DEFAULT 1,
        Description          NVARCHAR(500) NULL,
        IsActive             BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_ProcedureMaster_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_ProcedureMaster_Department FOREIGN KEY (DepartmentId) REFERENCES dbo.DepartmentMaster(DeptId),
        CONSTRAINT FK_ProcedureMaster_Speciality FOREIGN KEY (SpecialityId) REFERENCES dbo.DoctorSpecialityMaster(SpecialityId),
        CONSTRAINT UQ_ProcedureMaster_Branch_Code UNIQUE (BranchId, ProcedureCode)
    );
    PRINT 'Created table dbo.ProcedureMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.ProcedureMaster already exists';
END
GO

-- 2. Create dbo.ProcedureTariffMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ProcedureTariffMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.ProcedureTariffMaster
    (
        ProcedureTariffId    INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        BranchId             INT NOT NULL,
        TariffCategoryId     INT NOT NULL,
        ProcedureId          INT NOT NULL,
        SurgeonFee           DECIMAL(18,2) NOT NULL DEFAULT 0,
        AssistantFee         DECIMAL(18,2) NOT NULL DEFAULT 0,
        AnaesthetistFee      DECIMAL(18,2) NOT NULL DEFAULT 0,
        OtCharges            DECIMAL(18,2) NOT NULL DEFAULT 0,
        EquipmentCharges     DECIMAL(18,2) NOT NULL DEFAULT 0,
        ConsumableCharges    DECIMAL(18,2) NOT NULL DEFAULT 0,
        NursingCharges       DECIMAL(18,2) NOT NULL DEFAULT 0,
        TotalRate            DECIMAL(18,2) NOT NULL DEFAULT 0,
        EffectiveFrom        DATETIME2 NOT NULL DEFAULT GETDATE(),
        EffectiveTo          DATETIME2 NULL,
        Description          NVARCHAR(500) NULL,
        IsActive             BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_ProcedureTariffMaster_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_ProcedureTariffMaster_TariffCategory FOREIGN KEY (TariffCategoryId) REFERENCES dbo.TariffCategoryMaster(TariffCategoryId),
        CONSTRAINT FK_ProcedureTariffMaster_Procedure FOREIGN KEY (ProcedureId) REFERENCES dbo.ProcedureMaster(ProcedureId)
    );
    PRINT 'Created table dbo.ProcedureTariffMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.ProcedureTariffMaster already exists';
END
GO

-- 3. Stored Procedure for Procedure Master API List
CREATE OR ALTER PROCEDURE dbo.usp_Api_Procedure_GetList
    @BranchId INT = NULL,
    @DepartmentId INT = NULL,
    @SpecialityId INT = NULL,
    @ProcedureCategory NVARCHAR(100) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        p.ProcedureId,
        p.CompanyId,
        p.BranchId,
        b.BranchName,
        b.BranchCode,
        p.DepartmentId,
        d.DeptName AS DepartmentName,
        d.DeptCode AS DepartmentCode,
        p.SpecialityId,
        s.SpecialityName,
        s.SpecialityCode,
        p.ProcedureCode,
        p.ProcedureName,
        p.ProcedureCategory,
        p.DurationHours,
        p.DurationMinutes,
        p.DurationSeconds,
        p.AnaesthesiaRequired,
        p.ConsentRequired,
        p.Description,
        p.IsActive,
        p.CreatedDate
    FROM dbo.ProcedureMaster p
    INNER JOIN dbo.Branchmaster b ON p.BranchId = b.BranchID
    INNER JOIN dbo.DepartmentMaster d ON p.DepartmentId = d.DeptId
    INNER JOIN dbo.DoctorSpecialityMaster s ON p.SpecialityId = s.SpecialityId
    WHERE (@BranchId IS NULL OR p.BranchId = @BranchId)
      AND (@DepartmentId IS NULL OR p.DepartmentId = @DepartmentId)
      AND (@SpecialityId IS NULL OR p.SpecialityId = @SpecialityId)
      AND (@ProcedureCategory IS NULL OR p.ProcedureCategory = @ProcedureCategory)
      AND (@CompanyId IS NULL OR p.CompanyId = @CompanyId)
    ORDER BY p.ProcedureCategory, p.ProcedureName;
END
GO

-- 4. Stored Procedure for Procedure Tariff Master API List
CREATE OR ALTER PROCEDURE dbo.usp_Api_ProcedureTariff_GetList
    @BranchId INT = NULL,
    @TariffCategoryId INT = NULL,
    @ProcedureId INT = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        t.ProcedureTariffId,
        t.CompanyId,
        t.BranchId,
        b.BranchName,
        b.BranchCode,
        t.TariffCategoryId,
        tc.Name AS TariffCategoryName,
        tc.Code AS TariffCategoryCode,
        tc.PatientCategory,
        t.ProcedureId,
        p.ProcedureCode,
        p.ProcedureName,
        p.ProcedureCategory,
        d.DeptName AS DepartmentName,
        s.SpecialityName,
        t.SurgeonFee,
        t.AssistantFee,
        t.AnaesthetistFee,
        t.OtCharges,
        t.EquipmentCharges,
        t.ConsumableCharges,
        t.NursingCharges,
        t.TotalRate,
        t.EffectiveFrom,
        t.EffectiveTo,
        t.Description,
        t.IsActive,
        t.CreatedDate
    FROM dbo.ProcedureTariffMaster t
    INNER JOIN dbo.Branchmaster b ON t.BranchId = b.BranchID
    INNER JOIN dbo.TariffCategoryMaster tc ON t.TariffCategoryId = tc.TariffCategoryId
    INNER JOIN dbo.ProcedureMaster p ON t.ProcedureId = p.ProcedureId
    INNER JOIN dbo.DepartmentMaster d ON p.DepartmentId = d.DeptId
    INNER JOIN dbo.DoctorSpecialityMaster s ON p.SpecialityId = s.SpecialityId
    WHERE (@BranchId IS NULL OR t.BranchId = @BranchId)
      AND (@TariffCategoryId IS NULL OR t.TariffCategoryId = @TariffCategoryId)
      AND (@ProcedureId IS NULL OR t.ProcedureId = @ProcedureId)
      AND (@CompanyId IS NULL OR t.CompanyId = @CompanyId)
    ORDER BY tc.Name, p.ProcedureName, t.EffectiveFrom DESC;
END
GO

-- 5. Seed Initial Sample Data
DECLARE @BranchId INT = 1;
DECLARE @CompanyId INT = 1;

DECLARE @IpdDeptId INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptType = 'IPD' AND IsActive = 1 ORDER BY DeptId);
IF @IpdDeptId IS NULL SET @IpdDeptId = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE IsActive = 1 ORDER BY DeptId);

DECLARE @SpecId INT = (SELECT TOP 1 SpecialityId FROM dbo.DoctorSpecialityMaster WHERE IsActive = 1 ORDER BY SpecialityId);
DECLARE @TariffCatId INT = (SELECT TOP 1 TariffCategoryId FROM dbo.TariffCategoryMaster WHERE IsActive = 1 ORDER BY TariffCategoryId);

IF @IpdDeptId IS NOT NULL AND @SpecId IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.ProcedureMaster WHERE BranchId = @BranchId AND ProcedureCode = 'PROC-DIAL-01')
    BEGIN
        INSERT INTO dbo.ProcedureMaster (CompanyId, BranchId, DepartmentId, SpecialityId, ProcedureCode, ProcedureName, ProcedureCategory, DurationHours, DurationMinutes, DurationSeconds, AnaesthesiaRequired, ConsentRequired, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @IpdDeptId, @SpecId, 'PROC-DIAL-01', 'Hemodialysis Standard Session', 'Dialysis', 4, 0, 0, 0, 1, 'Standard 4-hour hemodialysis procedure', 1, GETDATE());
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.ProcedureMaster WHERE BranchId = @BranchId AND ProcedureCode = 'PROC-ENDO-01')
    BEGIN
        INSERT INTO dbo.ProcedureMaster (CompanyId, BranchId, DepartmentId, SpecialityId, ProcedureCode, ProcedureName, ProcedureCategory, DurationHours, DurationMinutes, DurationSeconds, AnaesthesiaRequired, ConsentRequired, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @IpdDeptId, @SpecId, 'PROC-ENDO-01', 'Upper Gastrointestinal Endoscopy', 'Endoscopic Procedure', 0, 45, 0, 1, 1, 'Diagnostic upper GI endoscopy with biopsy if required', 1, GETDATE());
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.ProcedureMaster WHERE BranchId = @BranchId AND ProcedureCode = 'PROC-COLON-01')
    BEGIN
        INSERT INTO dbo.ProcedureMaster (CompanyId, BranchId, DepartmentId, SpecialityId, ProcedureCode, ProcedureName, ProcedureCategory, DurationHours, DurationMinutes, DurationSeconds, AnaesthesiaRequired, ConsentRequired, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @IpdDeptId, @SpecId, 'PROC-COLON-01', 'Diagnostic Colonoscopy', 'Endoscopic Procedure', 1, 0, 0, 1, 1, 'Full diagnostic colonoscopy procedure', 1, GETDATE());
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.ProcedureMaster WHERE BranchId = @BranchId AND ProcedureCode = 'PROC-BIOPSY-01')
    BEGIN
        INSERT INTO dbo.ProcedureMaster (CompanyId, BranchId, DepartmentId, SpecialityId, ProcedureCode, ProcedureName, ProcedureCategory, DurationHours, DurationMinutes, DurationSeconds, AnaesthesiaRequired, ConsentRequired, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @IpdDeptId, @SpecId, 'PROC-BIOPSY-01', 'Ultrasound Guided Core Needle Biopsy', 'Diagnostic Procedure', 0, 30, 0, 1, 1, 'USG guided core needle tissue biopsy', 1, GETDATE());
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.ProcedureMaster WHERE BranchId = @BranchId AND ProcedureCode = 'PROC-SURG-01')
    BEGIN
        INSERT INTO dbo.ProcedureMaster (CompanyId, BranchId, DepartmentId, SpecialityId, ProcedureCode, ProcedureName, ProcedureCategory, DurationHours, DurationMinutes, DurationSeconds, AnaesthesiaRequired, ConsentRequired, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @IpdDeptId, @SpecId, 'PROC-SURG-01', 'Laparoscopic Appendectomy', 'Major Surgery', 2, 0, 0, 1, 1, 'Minimally invasive laparoscopic removal of appendix', 1, GETDATE());
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.ProcedureMaster WHERE BranchId = @BranchId AND ProcedureCode = 'PROC-CATH-01')
    BEGIN
        INSERT INTO dbo.ProcedureMaster (CompanyId, BranchId, DepartmentId, SpecialityId, ProcedureCode, ProcedureName, ProcedureCategory, DurationHours, DurationMinutes, DurationSeconds, AnaesthesiaRequired, ConsentRequired, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @IpdDeptId, @SpecId, 'PROC-CATH-01', 'Foley Urinary Catheterization', 'Bedside / Nursing Procedure', 0, 20, 0, 0, 0, 'Insertion of indwelling Foley urinary catheter', 1, GETDATE());
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.ProcedureMaster WHERE BranchId = @BranchId AND ProcedureCode = 'PROC-ICU-01')
    BEGIN
        INSERT INTO dbo.ProcedureMaster (CompanyId, BranchId, DepartmentId, SpecialityId, ProcedureCode, ProcedureName, ProcedureCategory, DurationHours, DurationMinutes, DurationSeconds, AnaesthesiaRequired, ConsentRequired, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @IpdDeptId, @SpecId, 'PROC-ICU-01', 'Central Venous Line Placement (CVC)', 'ICU Procedure', 0, 45, 0, 1, 1, 'Ultrasound-guided central venous catheter placement in ICU', 1, GETDATE());
    END
END

-- Seed sample tariff for Dialysis and Lap Appendectomy
IF @TariffCatId IS NOT NULL
BEGIN
    DECLARE @DialProcId INT = (SELECT ProcedureId FROM dbo.ProcedureMaster WHERE BranchId = @BranchId AND ProcedureCode = 'PROC-DIAL-01');
    IF @DialProcId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.ProcedureTariffMaster WHERE BranchId = @BranchId AND TariffCategoryId = @TariffCatId AND ProcedureId = @DialProcId)
    BEGIN
        INSERT INTO dbo.ProcedureTariffMaster (CompanyId, BranchId, TariffCategoryId, ProcedureId, SurgeonFee, AssistantFee, AnaesthetistFee, OtCharges, EquipmentCharges, ConsumableCharges, NursingCharges, TotalRate, EffectiveFrom, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @TariffCatId, @DialProcId, 500.00, 0.00, 0.00, 0.00, 1200.00, 800.00, 300.00, 2800.00, GETDATE(), 'Standard Hemodialysis Tariff', 1, GETDATE());
    END

    DECLARE @SurgProcId INT = (SELECT ProcedureId FROM dbo.ProcedureMaster WHERE BranchId = @BranchId AND ProcedureCode = 'PROC-SURG-01');
    IF @SurgProcId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.ProcedureTariffMaster WHERE BranchId = @BranchId AND TariffCategoryId = @TariffCatId AND ProcedureId = @SurgProcId)
    BEGIN
        INSERT INTO dbo.ProcedureTariffMaster (CompanyId, BranchId, TariffCategoryId, ProcedureId, SurgeonFee, AssistantFee, AnaesthetistFee, OtCharges, EquipmentCharges, ConsumableCharges, NursingCharges, TotalRate, EffectiveFrom, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @TariffCatId, @SurgProcId, 15000.00, 4000.00, 5000.00, 8000.00, 4500.00, 3500.00, 2000.00, 42000.00, GETDATE(), 'Laparoscopic Appendectomy Comprehensive Package', 1, GETDATE());
    END
END
GO
