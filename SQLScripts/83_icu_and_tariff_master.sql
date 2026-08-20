-- ====================================================================================================
-- Script: 83_icu_and_tariff_master.sql
-- Description: Creates IcuMaster, IcuTariffMaster, and IcuTariffDetail tables, Stored Procedures for API list data,
--              and seeds standard ICU configurations and dynamic tariff packages.
-- ====================================================================================================

-- 1. Create dbo.IcuMaster Table (ICU Configuration Header)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'IcuMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.IcuMaster
    (
        IcuId                INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        BranchId             INT NOT NULL,
        WardId               INT NOT NULL,
        IcuCode              NVARCHAR(50) NOT NULL,
        IcuName              NVARCHAR(100) NOT NULL,
        IcuType              NVARCHAR(50) NOT NULL DEFAULT 'ICU', -- ICU, HDU, NICU, PICU, CCU, etc.
        BedCapacity          INT NOT NULL DEFAULT 1,
        VentilatorCapacity   INT NOT NULL DEFAULT 0,
        IsolationCapacity    INT NOT NULL DEFAULT 0,
        Description          NVARCHAR(500) NULL,
        IsActive             BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_IcuMaster_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_IcuMaster_Ward FOREIGN KEY (WardId) REFERENCES dbo.WardMaster(WardId),
        CONSTRAINT UQ_IcuMaster_Branch_Code UNIQUE (BranchId, IcuCode)
    );
    PRINT 'Created table dbo.IcuMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.IcuMaster already exists';
END
GO

-- 2. Create dbo.IcuTariffMaster Table (Tariff Header)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'IcuTariffMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.IcuTariffMaster
    (
        IcuTariffId          INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        BranchId             INT NOT NULL,
        IcuId                INT NOT NULL,
        TariffCategoryId     INT NOT NULL,
        TotalRate            DECIMAL(18,2) NOT NULL DEFAULT 0,
        EffectiveFrom        DATETIME2 NOT NULL DEFAULT GETDATE(),
        EffectiveTo          DATETIME2 NULL,
        Description          NVARCHAR(500) NULL,
        IsActive             BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_IcuTariffMaster_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_IcuTariffMaster_Icu FOREIGN KEY (IcuId) REFERENCES dbo.IcuMaster(IcuId),
        CONSTRAINT FK_IcuTariffMaster_TariffCategory FOREIGN KEY (TariffCategoryId) REFERENCES dbo.TariffCategoryMaster(TariffCategoryId)
    );
    PRINT 'Created table dbo.IcuTariffMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.IcuTariffMaster already exists';
END
GO

-- 3. Create dbo.IcuTariffDetail Table (Dynamic Rate Heads / Details)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'IcuTariffDetail' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.IcuTariffDetail
    (
        IcuTariffDetailId    INT IDENTITY(1,1) PRIMARY KEY,
        IcuTariffId          INT NOT NULL,
        RateHeadName         NVARCHAR(100) NOT NULL,
        RateHeadCode         NVARCHAR(50) NULL,
        RateAmount           DECIMAL(18,2) NOT NULL DEFAULT 0,
        BillingFrequency     NVARCHAR(50) NOT NULL DEFAULT 'Per Day', -- Per Day, Per Hour, Per Usage, Fixed
        IsMandatory          BIT NOT NULL DEFAULT 1,
        Remarks              NVARCHAR(200) NULL,
        DisplayOrder         INT NOT NULL DEFAULT 0,
        CONSTRAINT FK_IcuTariffDetail_Tariff FOREIGN KEY (IcuTariffId) REFERENCES dbo.IcuTariffMaster(IcuTariffId) ON DELETE CASCADE
    );
    PRINT 'Created table dbo.IcuTariffDetail';
END
ELSE
BEGIN
    PRINT 'Table dbo.IcuTariffDetail already exists';
END
GO

-- 4. Stored Procedure for ICU Configurations API List
CREATE OR ALTER PROCEDURE dbo.usp_Api_Icu_GetList
    @BranchId INT = NULL,
    @WardId INT = NULL,
    @IcuType NVARCHAR(50) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        i.IcuId,
        i.CompanyId,
        i.BranchId,
        b.BranchName,
        b.BranchCode,
        i.WardId,
        w.WardCode,
        w.WardName,
        w.FloorId,
        f.FloorName,
        f.FloorCode,
        bl.BuildingName,
        i.IcuCode,
        i.IcuName,
        i.IcuType,
        i.BedCapacity,
        i.VentilatorCapacity,
        i.IsolationCapacity,
        i.Description,
        i.IsActive,
        i.CreatedDate,
        (SELECT COUNT(1) FROM dbo.IcuTariffMaster t WHERE t.IcuId = i.IcuId AND t.IsActive = 1) AS ActiveTariffsCount,
        (SELECT COUNT(1) FROM dbo.IcuTariffMaster t WHERE t.IcuId = i.IcuId) AS TotalTariffsCount
    FROM dbo.IcuMaster i
    INNER JOIN dbo.Branchmaster b ON i.BranchId = b.BranchID
    INNER JOIN dbo.WardMaster w ON i.WardId = w.WardId
    LEFT JOIN dbo.FloorMaster f ON w.FloorId = f.FloorId
    LEFT JOIN dbo.BuildingMaster bl ON f.BuildingId = bl.BuildingId
    WHERE (@BranchId IS NULL OR i.BranchId = @BranchId)
      AND (@WardId IS NULL OR i.WardId = @WardId)
      AND (@IcuType IS NULL OR i.IcuType = @IcuType)
      AND (@CompanyId IS NULL OR i.CompanyId = @CompanyId)
    ORDER BY i.IcuType, i.IcuName;
END
GO

-- 5. Stored Procedure for ICU Tariffs API List
CREATE OR ALTER PROCEDURE dbo.usp_Api_IcuTariff_GetList
    @BranchId INT = NULL,
    @IcuId INT = NULL,
    @TariffCategoryId INT = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        t.IcuTariffId,
        t.CompanyId,
        t.BranchId,
        b.BranchName,
        b.BranchCode,
        t.IcuId,
        i.IcuCode,
        i.IcuName,
        i.IcuType,
        w.WardName,
        t.TariffCategoryId,
        tc.Name AS TariffCategoryName,
        tc.PatientCategory,
        t.TotalRate,
        t.EffectiveFrom,
        t.EffectiveTo,
        t.Description,
        t.IsActive,
        t.CreatedDate,
        (SELECT COUNT(1) FROM dbo.IcuTariffDetail d WHERE d.IcuTariffId = t.IcuTariffId) AS TotalRateHeadsCount,
        -- Comma separated summary of dynamic rate heads
        (
            SELECT STRING_AGG(d.RateHeadName + ': ' + FORMAT(d.RateAmount, 'C', 'en-IN') + ' (' + d.BillingFrequency + ')', ', ')
            FROM dbo.IcuTariffDetail d
            WHERE d.IcuTariffId = t.IcuTariffId
        ) AS RateHeadsSummary
    FROM dbo.IcuTariffMaster t
    INNER JOIN dbo.Branchmaster b ON t.BranchId = b.BranchID
    INNER JOIN dbo.IcuMaster i ON t.IcuId = i.IcuId
    INNER JOIN dbo.WardMaster w ON i.WardId = w.WardId
    INNER JOIN dbo.TariffCategoryMaster tc ON t.TariffCategoryId = tc.TariffCategoryId
    WHERE (@BranchId IS NULL OR t.BranchId = @BranchId)
      AND (@IcuId IS NULL OR t.IcuId = @IcuId)
      AND (@TariffCategoryId IS NULL OR t.TariffCategoryId = @TariffCategoryId)
      AND (@CompanyId IS NULL OR t.CompanyId = @CompanyId)
    ORDER BY i.IcuType, i.IcuName, tc.Name, t.EffectiveFrom DESC;
END
GO

-- 6. Stored Procedure for ICU Tariff Details API List
CREATE OR ALTER PROCEDURE dbo.usp_Api_IcuTariffDetail_GetList
    @IcuTariffId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        d.IcuTariffDetailId,
        d.IcuTariffId,
        d.RateHeadName,
        d.RateHeadCode,
        d.RateAmount,
        d.BillingFrequency,
        d.IsMandatory,
        d.Remarks,
        d.DisplayOrder
    FROM dbo.IcuTariffDetail d
    WHERE d.IcuTariffId = @IcuTariffId
    ORDER BY d.DisplayOrder, d.IcuTariffDetailId;
END
GO

-- 7. Seed Initial Standard ICU Configurations & Dynamic Tariffs
DECLARE @BranchId INT = 1;
DECLARE @CompanyId INT = 1;
DECLARE @WardId INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE BranchId = @BranchId AND IsActive = 1 ORDER BY WardId);

IF @WardId IS NOT NULL
BEGIN
    -- 1. Main ICU
    IF NOT EXISTS (SELECT 1 FROM dbo.IcuMaster WHERE BranchId = @BranchId AND IcuCode = 'ICU-MAIN-01')
    BEGIN
        INSERT INTO dbo.IcuMaster (CompanyId, BranchId, WardId, IcuCode, IcuName, IcuType, BedCapacity, VentilatorCapacity, IsolationCapacity, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @WardId, 'ICU-MAIN-01', 'Main Intensive Care Unit (MICU/SICU)', 'ICU', 12, 8, 2, 'Tertiary level adult multi-disciplinary intensive care unit', 1, GETDATE());
    END

    -- 2. HDU
    IF NOT EXISTS (SELECT 1 FROM dbo.IcuMaster WHERE BranchId = @BranchId AND IcuCode = 'HDU-01')
    BEGIN
        INSERT INTO dbo.IcuMaster (CompanyId, BranchId, WardId, IcuCode, IcuName, IcuType, BedCapacity, VentilatorCapacity, IsolationCapacity, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @WardId, 'HDU-01', 'High Dependency Unit (Step-down)', 'HDU', 8, 2, 1, 'Step-down critical care monitoring unit', 1, GETDATE());
    END

    -- 3. NICU
    IF NOT EXISTS (SELECT 1 FROM dbo.IcuMaster WHERE BranchId = @BranchId AND IcuCode = 'NICU-01')
    BEGIN
        INSERT INTO dbo.IcuMaster (CompanyId, BranchId, WardId, IcuCode, IcuName, IcuType, BedCapacity, VentilatorCapacity, IsolationCapacity, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @WardId, 'NICU-01', 'Neonatal Intensive Care Unit (Level III)', 'NICU', 10, 6, 2, 'Advanced neonatal life support and radiant warmers unit', 1, GETDATE());
    END

    -- 4. PICU
    IF NOT EXISTS (SELECT 1 FROM dbo.IcuMaster WHERE BranchId = @BranchId AND IcuCode = 'PICU-01')
    BEGIN
        INSERT INTO dbo.IcuMaster (CompanyId, BranchId, WardId, IcuCode, IcuName, IcuType, BedCapacity, VentilatorCapacity, IsolationCapacity, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @WardId, 'PICU-01', 'Paediatric Intensive Care Unit', 'PICU', 6, 4, 1, 'Specialized paediatric resuscitation and critical care', 1, GETDATE());
    END

    -- 5. CCU
    IF NOT EXISTS (SELECT 1 FROM dbo.IcuMaster WHERE BranchId = @BranchId AND IcuCode = 'CCU-01')
    BEGIN
        INSERT INTO dbo.IcuMaster (CompanyId, BranchId, WardId, IcuCode, IcuName, IcuType, BedCapacity, VentilatorCapacity, IsolationCapacity, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @WardId, 'CCU-01', 'Coronary Care Unit (Cardiovascular ICU)', 'CCU', 8, 4, 1, 'Acute cardiac care and telemetry monitoring unit', 1, GETDATE());
    END

    -- Seed Initial Dynamic Tariff for Main ICU
    DECLARE @IcuId INT = (SELECT IcuId FROM dbo.IcuMaster WHERE BranchId = @BranchId AND IcuCode = 'ICU-MAIN-01');
    DECLARE @TariffCatId INT = (SELECT TOP 1 TariffCategoryId FROM dbo.TariffCategoryMaster WHERE (BranchId = @BranchId OR BranchId IS NULL) AND IsActive = 1 ORDER BY TariffCategoryId);

    IF @IcuId IS NOT NULL AND @TariffCatId IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.IcuTariffMaster WHERE BranchId = @BranchId AND IcuId = @IcuId AND TariffCategoryId = @TariffCatId)
        BEGIN
            INSERT INTO dbo.IcuTariffMaster (CompanyId, BranchId, IcuId, TariffCategoryId, TotalRate, EffectiveFrom, Description, IsActive, CreatedDate)
            VALUES (@CompanyId, @BranchId, @IcuId, @TariffCatId, 18500.00, GETDATE(), 'Standard Comprehensive Adult ICU Package', 1, GETDATE());

            DECLARE @TariffId INT = SCOPE_IDENTITY();

            -- Dynamic Rate Heads
            INSERT INTO dbo.IcuTariffDetail (IcuTariffId, RateHeadName, RateHeadCode, RateAmount, BillingFrequency, IsMandatory, DisplayOrder)
            VALUES 
                (@TariffId, 'ICU Bed & Accommodation', 'BED', 4500.00, 'Per Day', 1, 1),
                (@TariffId, 'Critical Care 1:1 Nursing', 'NUR', 3000.00, 'Per Day', 1, 2),
                (@TariffId, 'Advanced Mechanical Ventilator', 'VENT', 3500.00, 'Per Day', 0, 3),
                (@TariffId, 'Continuous Multi-para Monitoring', 'MON', 1500.00, 'Per Day', 1, 4),
                (@TariffId, 'Infusion Pump Charges', 'INF', 1000.00, 'Per Day', 0, 5),
                (@TariffId, 'Syringe Pump Charges', 'SYR', 1000.00, 'Per Day', 0, 6),
                (@TariffId, 'Central High-flow Oxygen Support', 'O2', 2000.00, 'Per Day', 1, 7),
                (@TariffId, 'Negative Pressure Isolation', 'ISO', 1000.00, 'Per Day', 0, 8),
                (@TariffId, 'Critical-care Bedside Procedures', 'PROC', 1000.00, 'Per Day', 0, 9);
        END
    END
END
GO
