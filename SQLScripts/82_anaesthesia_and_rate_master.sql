-- ====================================================================================================
-- Script: 82_anaesthesia_and_rate_master.sql
-- Description: Creates AnaesthesiaTypeMaster and AnaesthesiaRateMaster tables, Stored Procedures for API list data,
--              and seeds standard Anaesthesia types and initial procedure rates.
-- ====================================================================================================

-- 1. Create dbo.AnaesthesiaTypeMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'AnaesthesiaTypeMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.AnaesthesiaTypeMaster
    (
        AnaesthesiaTypeId    INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        BranchId             INT NOT NULL,
        TypeCode             NVARCHAR(50) NOT NULL,
        TypeName             NVARCHAR(100) NOT NULL,
        Description          NVARCHAR(500) NULL,
        IsActive             BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_AnaesthesiaTypeMaster_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT UQ_AnaesthesiaTypeMaster_Branch_Code UNIQUE (BranchId, TypeCode)
    );
    PRINT 'Created table dbo.AnaesthesiaTypeMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.AnaesthesiaTypeMaster already exists';
END
GO

-- 2. Create dbo.AnaesthesiaRateMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'AnaesthesiaRateMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.AnaesthesiaRateMaster
    (
        AnaesthesiaRateId    INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        BranchId             INT NOT NULL,
        ProcedureId          INT NOT NULL,
        AnaesthesiaTypeId    INT NOT NULL,
        AnaesthetistFee      DECIMAL(18,2) NOT NULL DEFAULT 0,
        ConsumableCharge     DECIMAL(18,2) NOT NULL DEFAULT 0,
        TotalRate            DECIMAL(18,2) NOT NULL DEFAULT 0,
        EffectiveFrom        DATETIME2 NOT NULL DEFAULT GETDATE(),
        EffectiveTo          DATETIME2 NULL,
        Description          NVARCHAR(500) NULL,
        IsActive             BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_AnaesthesiaRateMaster_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_AnaesthesiaRateMaster_Procedure FOREIGN KEY (ProcedureId) REFERENCES dbo.ProcedureMaster(ProcedureId),
        CONSTRAINT FK_AnaesthesiaRateMaster_Type FOREIGN KEY (AnaesthesiaTypeId) REFERENCES dbo.AnaesthesiaTypeMaster(AnaesthesiaTypeId)
    );
    PRINT 'Created table dbo.AnaesthesiaRateMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.AnaesthesiaRateMaster already exists';
END
GO

-- 3. Stored Procedure for Anaesthesia Types API List
CREATE OR ALTER PROCEDURE dbo.usp_Api_AnaesthesiaType_GetList
    @BranchId INT = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        a.AnaesthesiaTypeId,
        a.CompanyId,
        a.BranchId,
        b.BranchName,
        b.BranchCode,
        a.TypeCode,
        a.TypeName,
        a.Description,
        a.IsActive,
        a.CreatedDate,
        (SELECT COUNT(1) FROM dbo.AnaesthesiaRateMaster r WHERE r.AnaesthesiaTypeId = a.AnaesthesiaTypeId) AS TotalRatesConfigured
    FROM dbo.AnaesthesiaTypeMaster a
    INNER JOIN dbo.Branchmaster b ON a.BranchId = b.BranchID
    WHERE (@BranchId IS NULL OR a.BranchId = @BranchId)
      AND (@CompanyId IS NULL OR a.CompanyId = @CompanyId)
    ORDER BY a.TypeName;
END
GO

-- 4. Stored Procedure for Anaesthesia Rates API List
CREATE OR ALTER PROCEDURE dbo.usp_Api_AnaesthesiaRate_GetList
    @BranchId INT = NULL,
    @ProcedureId INT = NULL,
    @AnaesthesiaTypeId INT = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        r.AnaesthesiaRateId,
        r.CompanyId,
        r.BranchId,
        b.BranchName,
        b.BranchCode,
        r.ProcedureId,
        p.ProcedureCode,
        p.ProcedureName,
        p.ProcedureCategory,
        d.DeptName AS DepartmentName,
        r.AnaesthesiaTypeId,
        t.TypeCode AS AnaesthesiaTypeCode,
        t.TypeName AS AnaesthesiaTypeName,
        r.AnaesthetistFee,
        r.ConsumableCharge,
        r.TotalRate,
        r.EffectiveFrom,
        r.EffectiveTo,
        r.Description,
        r.IsActive,
        r.CreatedDate
    FROM dbo.AnaesthesiaRateMaster r
    INNER JOIN dbo.Branchmaster b ON r.BranchId = b.BranchID
    INNER JOIN dbo.ProcedureMaster p ON r.ProcedureId = p.ProcedureId
    INNER JOIN dbo.AnaesthesiaTypeMaster t ON r.AnaesthesiaTypeId = t.AnaesthesiaTypeId
    LEFT JOIN dbo.DepartmentMaster d ON p.DepartmentId = d.DeptId
    WHERE (@BranchId IS NULL OR r.BranchId = @BranchId)
      AND (@ProcedureId IS NULL OR r.ProcedureId = @ProcedureId)
      AND (@AnaesthesiaTypeId IS NULL OR r.AnaesthesiaTypeId = @AnaesthesiaTypeId)
      AND (@CompanyId IS NULL OR r.CompanyId = @CompanyId)
    ORDER BY p.ProcedureName, t.TypeName, r.EffectiveFrom DESC;
END
GO

-- 5. Seed Initial Standard Types & Rates
DECLARE @BranchId INT = 1;
DECLARE @CompanyId INT = 1;

-- Seed Standard Types
IF NOT EXISTS (SELECT 1 FROM dbo.AnaesthesiaTypeMaster WHERE BranchId = @BranchId AND TypeCode = 'GEN')
BEGIN
    INSERT INTO dbo.AnaesthesiaTypeMaster (CompanyId, BranchId, TypeCode, TypeName, Description, IsActive, CreatedDate)
    VALUES (@CompanyId, @BranchId, 'GEN', 'General Anaesthesia', 'Complete state of unconsciousness with intubation and mechanical ventilation', 1, GETDATE());
END

IF NOT EXISTS (SELECT 1 FROM dbo.AnaesthesiaTypeMaster WHERE BranchId = @BranchId AND TypeCode = 'REG')
BEGIN
    INSERT INTO dbo.AnaesthesiaTypeMaster (CompanyId, BranchId, TypeCode, TypeName, Description, IsActive, CreatedDate)
    VALUES (@CompanyId, @BranchId, 'REG', 'Regional Anaesthesia', 'Peripheral nerve blocks for limbs and localized anatomical surgical fields', 1, GETDATE());
END

IF NOT EXISTS (SELECT 1 FROM dbo.AnaesthesiaTypeMaster WHERE BranchId = @BranchId AND TypeCode = 'SPN')
BEGIN
    INSERT INTO dbo.AnaesthesiaTypeMaster (CompanyId, BranchId, TypeCode, TypeName, Description, IsActive, CreatedDate)
    VALUES (@CompanyId, @BranchId, 'SPN', 'Spinal Anaesthesia', 'Subarachnoid block for lower abdominal, pelvic, and lower extremity procedures', 1, GETDATE());
END

IF NOT EXISTS (SELECT 1 FROM dbo.AnaesthesiaTypeMaster WHERE BranchId = @BranchId AND TypeCode = 'EPI')
BEGIN
    INSERT INTO dbo.AnaesthesiaTypeMaster (CompanyId, BranchId, TypeCode, TypeName, Description, IsActive, CreatedDate)
    VALUES (@CompanyId, @BranchId, 'EPI', 'Epidural Anaesthesia', 'Epidural space catheterization for surgical anesthesia and post-operative pain relief', 1, GETDATE());
END

IF NOT EXISTS (SELECT 1 FROM dbo.AnaesthesiaTypeMaster WHERE BranchId = @BranchId AND TypeCode = 'LOC')
BEGIN
    INSERT INTO dbo.AnaesthesiaTypeMaster (CompanyId, BranchId, TypeCode, TypeName, Description, IsActive, CreatedDate)
    VALUES (@CompanyId, @BranchId, 'LOC', 'Local Anaesthesia', 'Targeted local infiltration / topical anaesthesia for minor bedside or daycare procedures', 1, GETDATE());
END

IF NOT EXISTS (SELECT 1 FROM dbo.AnaesthesiaTypeMaster WHERE BranchId = @BranchId AND TypeCode = 'SED')
BEGIN
    INSERT INTO dbo.AnaesthesiaTypeMaster (CompanyId, BranchId, TypeCode, TypeName, Description, IsActive, CreatedDate)
    VALUES (@CompanyId, @BranchId, 'SED', 'Sedation / MAC', 'Monitored Anesthesia Care (MAC) with conscious sedation and continuous vitals monitoring', 1, GETDATE());
END

-- Seed Initial Rates for Procedures
DECLARE @ProcId INT = (SELECT TOP 1 ProcedureId FROM dbo.ProcedureMaster WHERE BranchId = @BranchId AND IsActive = 1 ORDER BY ProcedureId);
DECLARE @GenTypeId INT = (SELECT AnaesthesiaTypeId FROM dbo.AnaesthesiaTypeMaster WHERE BranchId = @BranchId AND TypeCode = 'GEN');
DECLARE @SpnTypeId INT = (SELECT AnaesthesiaTypeId FROM dbo.AnaesthesiaTypeMaster WHERE BranchId = @BranchId AND TypeCode = 'SPN');

IF @ProcId IS NOT NULL AND @GenTypeId IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.AnaesthesiaRateMaster WHERE BranchId = @BranchId AND ProcedureId = @ProcId AND AnaesthesiaTypeId = @GenTypeId)
    BEGIN
        INSERT INTO dbo.AnaesthesiaRateMaster (CompanyId, BranchId, ProcedureId, AnaesthesiaTypeId, AnaesthetistFee, ConsumableCharge, TotalRate, EffectiveFrom, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @ProcId, @GenTypeId, 3500.00, 1500.00, 5000.00, GETDATE(), 'Standard General Anaesthesia Rate Package', 1, GETDATE());
    END
END

IF @ProcId IS NOT NULL AND @SpnTypeId IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.AnaesthesiaRateMaster WHERE BranchId = @BranchId AND ProcedureId = @ProcId AND AnaesthesiaTypeId = @SpnTypeId)
    BEGIN
        INSERT INTO dbo.AnaesthesiaRateMaster (CompanyId, BranchId, ProcedureId, AnaesthesiaTypeId, AnaesthetistFee, ConsumableCharge, TotalRate, EffectiveFrom, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @ProcId, @SpnTypeId, 2500.00, 1000.00, 3500.00, GETDATE(), 'Standard Spinal Anaesthesia Rate Package', 1, GETDATE());
    END
END
GO
