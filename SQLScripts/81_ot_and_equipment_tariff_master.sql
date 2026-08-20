-- ====================================================================================================
-- Script: 81_ot_and_equipment_tariff_master.sql
-- Description: Creates OtMaster, OtEquipmentMaster, and OtTariffMaster tables, Stored Procedures for API list data,
--              and seeds standard OT types, equipments, and tariff configurations.
-- ====================================================================================================

-- 1. Create dbo.OtMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'OtMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.OtMaster
    (
        OtId                 INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        BranchId             INT NOT NULL,
        FloorId              INT NOT NULL,
        OtCode               NVARCHAR(50) NOT NULL,
        OtName               NVARCHAR(200) NOT NULL,
        OtType               NVARCHAR(100) NOT NULL,
        Capacity             NVARCHAR(100) NOT NULL,
        EmergencyAvailable   BIT NOT NULL DEFAULT 0,
        Description          NVARCHAR(500) NULL,
        IsActive             BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_OtMaster_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_OtMaster_Floor FOREIGN KEY (FloorId) REFERENCES dbo.FloorMaster(FloorId),
        CONSTRAINT UQ_OtMaster_Branch_Code UNIQUE (BranchId, OtCode)
    );
    PRINT 'Created table dbo.OtMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.OtMaster already exists';
END
GO

-- 2. Create dbo.OtEquipmentMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'OtEquipmentMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.OtEquipmentMaster
    (
        EquipmentId          INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        BranchId             INT NOT NULL,
        OtId                 INT NOT NULL,
        EquipmentCode        NVARCHAR(50) NOT NULL,
        EquipmentName        NVARCHAR(200) NOT NULL,
        EquipmentType        NVARCHAR(100) NULL,
        SerialNo             NVARCHAR(100) NULL,
        CalibrationRequired  BIT NOT NULL DEFAULT 0,
        LastCalibrationDate  DATETIME2 NULL,
        CalibrationDueDate   DATETIME2 NULL,
        Description          NVARCHAR(500) NULL,
        IsActive             BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_OtEquipmentMaster_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_OtEquipmentMaster_Ot FOREIGN KEY (OtId) REFERENCES dbo.OtMaster(OtId),
        CONSTRAINT UQ_OtEquipmentMaster_Branch_Code UNIQUE (BranchId, EquipmentCode)
    );
    PRINT 'Created table dbo.OtEquipmentMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.OtEquipmentMaster already exists';
END
GO

-- 3. Create dbo.OtTariffMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'OtTariffMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.OtTariffMaster
    (
        OtTariffId              INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId               INT NOT NULL DEFAULT 1,
        BranchId                INT NOT NULL,
        TariffCategoryId        INT NOT NULL,
        OtId                    INT NOT NULL,
        OtUsageRate             DECIMAL(18,2) NOT NULL DEFAULT 0,
        NursingCharges          DECIMAL(18,2) NOT NULL DEFAULT 0,
        EquipmentCharges        DECIMAL(18,2) NOT NULL DEFAULT 0,
        RecoveryCharges         DECIMAL(18,2) NOT NULL DEFAULT 0,
        ConsumableCharges       DECIMAL(18,2) NOT NULL DEFAULT 0,
        SpecialEquipmentCharges DECIMAL(18,2) NOT NULL DEFAULT 0,
        TotalRate               DECIMAL(18,2) NOT NULL DEFAULT 0,
        EffectiveFrom           DATETIME2 NOT NULL DEFAULT GETDATE(),
        EffectiveTo             DATETIME2 NULL,
        Description             NVARCHAR(500) NULL,
        IsActive                BIT NOT NULL DEFAULT 1,
        CreatedBy               INT NULL,
        CreatedDate             DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy              INT NULL,
        ModifiedDate            DATETIME2 NULL,
        CONSTRAINT FK_OtTariffMaster_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_OtTariffMaster_TariffCategory FOREIGN KEY (TariffCategoryId) REFERENCES dbo.TariffCategoryMaster(TariffCategoryId),
        CONSTRAINT FK_OtTariffMaster_Ot FOREIGN KEY (OtId) REFERENCES dbo.OtMaster(OtId)
    );
    PRINT 'Created table dbo.OtTariffMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.OtTariffMaster already exists';
END
GO

-- 4. Stored Procedure for OT Master API List
CREATE OR ALTER PROCEDURE dbo.usp_Api_Ot_GetList
    @BranchId INT = NULL,
    @FloorId INT = NULL,
    @OtType NVARCHAR(100) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        o.OtId,
        o.CompanyId,
        o.BranchId,
        b.BranchName,
        b.BranchCode,
        o.FloorId,
        f.FloorName,
        f.FloorCode,
        bm.BuildingId,
        bm.BuildingName,
        bm.BuildingCode,
        o.OtCode,
        o.OtName,
        o.OtType,
        o.Capacity,
        o.EmergencyAvailable,
        o.Description,
        o.IsActive,
        o.CreatedDate
    FROM dbo.OtMaster o
    INNER JOIN dbo.Branchmaster b ON o.BranchId = b.BranchID
    INNER JOIN dbo.FloorMaster f ON o.FloorId = f.FloorId
    LEFT JOIN dbo.BuildingMaster bm ON f.BuildingId = bm.BuildingId
    WHERE (@BranchId IS NULL OR o.BranchId = @BranchId)
      AND (@FloorId IS NULL OR o.FloorId = @FloorId)
      AND (@OtType IS NULL OR o.OtType = @OtType)
      AND (@CompanyId IS NULL OR o.CompanyId = @CompanyId)
    ORDER BY o.OtType, o.OtName;
END
GO

-- 5. Stored Procedure for OT Equipment Master API List
CREATE OR ALTER PROCEDURE dbo.usp_Api_OtEquipment_GetList
    @BranchId INT = NULL,
    @OtId INT = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        e.EquipmentId,
        e.CompanyId,
        e.BranchId,
        b.BranchName,
        b.BranchCode,
        e.OtId,
        o.OtCode,
        o.OtName,
        o.OtType,
        f.FloorName,
        bm.BuildingName,
        e.EquipmentCode,
        e.EquipmentName,
        e.EquipmentType,
        e.SerialNo,
        e.CalibrationRequired,
        e.LastCalibrationDate,
        e.CalibrationDueDate,
        e.Description,
        e.IsActive,
        e.CreatedDate
    FROM dbo.OtEquipmentMaster e
    INNER JOIN dbo.Branchmaster b ON e.BranchId = b.BranchID
    INNER JOIN dbo.OtMaster o ON e.OtId = o.OtId
    INNER JOIN dbo.FloorMaster f ON o.FloorId = f.FloorId
    LEFT JOIN dbo.BuildingMaster bm ON f.BuildingId = bm.BuildingId
    WHERE (@BranchId IS NULL OR e.BranchId = @BranchId)
      AND (@OtId IS NULL OR e.OtId = @OtId)
      AND (@CompanyId IS NULL OR e.CompanyId = @CompanyId)
    ORDER BY o.OtName, e.EquipmentName;
END
GO

-- 6. Stored Procedure for OT Tariff Master API List
CREATE OR ALTER PROCEDURE dbo.usp_Api_OtTariff_GetList
    @BranchId INT = NULL,
    @TariffCategoryId INT = NULL,
    @OtId INT = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        t.OtTariffId,
        t.CompanyId,
        t.BranchId,
        b.BranchName,
        b.BranchCode,
        t.TariffCategoryId,
        tc.Name AS TariffCategoryName,
        tc.Code AS TariffCategoryCode,
        tc.PatientCategory,
        t.OtId,
        o.OtCode,
        o.OtName,
        o.OtType,
        f.FloorName,
        bm.BuildingName,
        t.OtUsageRate,
        t.NursingCharges,
        t.EquipmentCharges,
        t.RecoveryCharges,
        t.ConsumableCharges,
        t.SpecialEquipmentCharges,
        t.TotalRate,
        t.EffectiveFrom,
        t.EffectiveTo,
        t.Description,
        t.IsActive,
        t.CreatedDate
    FROM dbo.OtTariffMaster t
    INNER JOIN dbo.Branchmaster b ON t.BranchId = b.BranchID
    INNER JOIN dbo.TariffCategoryMaster tc ON t.TariffCategoryId = tc.TariffCategoryId
    INNER JOIN dbo.OtMaster o ON t.OtId = o.OtId
    INNER JOIN dbo.FloorMaster f ON o.FloorId = f.FloorId
    LEFT JOIN dbo.BuildingMaster bm ON f.BuildingId = bm.BuildingId
    WHERE (@BranchId IS NULL OR t.BranchId = @BranchId)
      AND (@TariffCategoryId IS NULL OR t.TariffCategoryId = @TariffCategoryId)
      AND (@OtId IS NULL OR t.OtId = @OtId)
      AND (@CompanyId IS NULL OR t.CompanyId = @CompanyId)
    ORDER BY tc.Name, o.OtName, t.EffectiveFrom DESC;
END
GO

-- 7. Seed Initial Sample Data
DECLARE @BranchId INT = 1;
DECLARE @CompanyId INT = 1;

DECLARE @FloorId INT = (SELECT TOP 1 FloorId FROM dbo.FloorMaster WHERE IsActive = 1 ORDER BY FloorId);
DECLARE @TariffCatId INT = (SELECT TOP 1 TariffCategoryId FROM dbo.TariffCategoryMaster WHERE IsActive = 1 ORDER BY TariffCategoryId);

IF @FloorId IS NOT NULL
BEGIN
    -- Seed OTs
    IF NOT EXISTS (SELECT 1 FROM dbo.OtMaster WHERE BranchId = @BranchId AND OtCode = 'OT-MAJ-01')
    BEGIN
        INSERT INTO dbo.OtMaster (CompanyId, BranchId, FloorId, OtCode, OtName, OtType, Capacity, EmergencyAvailable, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @FloorId, 'OT-MAJ-01', 'Main Major Surgery OT 1', 'Major OT', '1 Table (Modular)', 1, 'Modular sterile major operation theatre equipped with laminar airflow', 1, GETDATE());
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.OtMaster WHERE BranchId = @BranchId AND OtCode = 'OT-LAP-02')
    BEGIN
        INSERT INTO dbo.OtMaster (CompanyId, BranchId, FloorId, OtCode, OtName, OtType, Capacity, EmergencyAvailable, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @FloorId, 'OT-LAP-02', 'Laparoscopic & Endoscopy OT 2', 'Laparoscopic / Endoscopic OT', '1 Table + Endoscopy Station', 0, 'Advanced minimally invasive and endoscopic surgery theatre', 1, GETDATE());
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.OtMaster WHERE BranchId = @BranchId AND OtCode = 'OT-EMG-03')
    BEGIN
        INSERT INTO dbo.OtMaster (CompanyId, BranchId, FloorId, OtCode, OtName, OtType, Capacity, EmergencyAvailable, Description, IsActive, CreatedDate)
        VALUES (@CompanyId, @BranchId, @FloorId, 'OT-EMG-03', 'Emergency Trauma OT', 'Emergency / Trauma OT', '2 Tables / Multi-Station', 1, '24x7 Dedicated emergency trauma resuscitation and operation theatre', 1, GETDATE());
    END

    -- Seed OT Equipments
    DECLARE @MajorOtId INT = (SELECT OtId FROM dbo.OtMaster WHERE BranchId = @BranchId AND OtCode = 'OT-MAJ-01');
    DECLARE @LapOtId INT = (SELECT OtId FROM dbo.OtMaster WHERE BranchId = @BranchId AND OtCode = 'OT-LAP-02');

    IF @MajorOtId IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.OtEquipmentMaster WHERE BranchId = @BranchId AND EquipmentCode = 'EQ-CARM-01')
        BEGIN
            INSERT INTO dbo.OtEquipmentMaster (CompanyId, BranchId, OtId, EquipmentCode, EquipmentName, EquipmentType, SerialNo, CalibrationRequired, LastCalibrationDate, CalibrationDueDate, Description, IsActive, CreatedDate)
            VALUES (@CompanyId, @BranchId, @MajorOtId, 'EQ-CARM-01', 'C-Arm Image Intensifier', 'Imaging / Radiology', 'CARM-GE-9800-441', 1, DATEADD(month, -2, GETDATE()), DATEADD(month, 4, GETDATE()), 'High resolution mobile digital fluoroscopy C-Arm system', 1, GETDATE());
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.OtEquipmentMaster WHERE BranchId = @BranchId AND EquipmentCode = 'EQ-MICR-01')
        BEGIN
            INSERT INTO dbo.OtEquipmentMaster (CompanyId, BranchId, OtId, EquipmentCode, EquipmentName, EquipmentType, SerialNo, CalibrationRequired, LastCalibrationDate, CalibrationDueDate, Description, IsActive, CreatedDate)
            VALUES (@CompanyId, @BranchId, @MajorOtId, 'EQ-MICR-01', 'Operating Microscope', 'Surgical Microscope', 'ZEISS-OPMI-7721', 1, DATEADD(month, -1, GETDATE()), DATEADD(month, 5, GETDATE()), 'High magnification neuro and ophthalmic operating microscope', 1, GETDATE());
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.OtEquipmentMaster WHERE BranchId = @BranchId AND EquipmentCode = 'EQ-ANAE-01')
        BEGIN
            INSERT INTO dbo.OtEquipmentMaster (CompanyId, BranchId, OtId, EquipmentCode, EquipmentName, EquipmentType, SerialNo, CalibrationRequired, LastCalibrationDate, CalibrationDueDate, Description, IsActive, CreatedDate)
            VALUES (@CompanyId, @BranchId, @MajorOtId, 'EQ-ANAE-01', 'Anaesthesia Workstation Machine', 'Anaesthesia & Ventilation', 'DRAGER-FAB-551', 1, DATEADD(month, -1, GETDATE()), DATEADD(month, 2, GETDATE()), 'Multi-gas anaesthesia delivery system with ventilator', 1, GETDATE());
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.OtEquipmentMaster WHERE BranchId = @BranchId AND EquipmentCode = 'EQ-CAUT-01')
        BEGIN
            INSERT INTO dbo.OtEquipmentMaster (CompanyId, BranchId, OtId, EquipmentCode, EquipmentName, EquipmentType, SerialNo, CalibrationRequired, LastCalibrationDate, CalibrationDueDate, Description, IsActive, CreatedDate)
            VALUES (@CompanyId, @BranchId, @MajorOtId, 'EQ-CAUT-01', 'Electrocautery Unit (Monopolar/Bipolar)', 'Electrosurgical', 'VALLEYLAB-FT10-88', 1, DATEADD(month, -3, GETDATE()), DATEADD(month, 3, GETDATE()), 'High frequency energy electrosurgical generator', 1, GETDATE());
        END
    END

    IF @LapOtId IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.OtEquipmentMaster WHERE BranchId = @BranchId AND EquipmentCode = 'EQ-LASER-01')
        BEGIN
            INSERT INTO dbo.OtEquipmentMaster (CompanyId, BranchId, OtId, EquipmentCode, EquipmentName, EquipmentType, SerialNo, CalibrationRequired, LastCalibrationDate, CalibrationDueDate, Description, IsActive, CreatedDate)
            VALUES (@CompanyId, @BranchId, @LapOtId, 'EQ-LASER-01', 'Holmium Surgical Laser Unit', 'Laser', 'LUMENIS-PULSE-100', 1, DATEADD(month, -2, GETDATE()), DATEADD(month, 4, GETDATE()), 'High power Holmium:YAG laser for urology and soft tissue', 1, GETDATE());
        END
    END

    -- Seed OT Tariffs
    IF @TariffCatId IS NOT NULL AND @MajorOtId IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.OtTariffMaster WHERE BranchId = @BranchId AND TariffCategoryId = @TariffCatId AND OtId = @MajorOtId)
        BEGIN
            INSERT INTO dbo.OtTariffMaster (CompanyId, BranchId, TariffCategoryId, OtId, OtUsageRate, NursingCharges, EquipmentCharges, RecoveryCharges, ConsumableCharges, SpecialEquipmentCharges, TotalRate, EffectiveFrom, Description, IsActive, CreatedDate)
            VALUES (@CompanyId, @BranchId, @TariffCatId, @MajorOtId, 6000.00, 2000.00, 2500.00, 1500.00, 2000.00, 4000.00, 18000.00, GETDATE(), 'Standard Major OT Comprehensive Tariff', 1, GETDATE());
        END
    END
END
GO
