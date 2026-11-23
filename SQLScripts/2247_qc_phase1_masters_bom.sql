-- ============================================================================
-- Migration: 2247_qc_phase1_masters_bom.sql
-- Description: Quality & Compliance module - Phase 1 (Masters and Bill of Material), per the plan
--   "Quality & Compliance Module Plan - BOM & Costing".
--   * Top menu QUALITY ("Quality & Compliance", between Utility and Reports) with sub-menus Masters and
--     Bill of Material; pages with VIEW / ADD / EDIT / STATUS / DELETE controls. No role is granted here.
--   * Masters: InvUnit, InvItemCategory (seeded), InvItem, InvSupplier, InvStore (a Main Store per branch seeded).
--   * BOM: BomTest (versioned per test, optional analyzer) + BomTestLine; BomSampleKit (per sample type).
--   * Costing basis: dbo.ufn_Qc_ItemUnitCost = weighted average cost once stock exists (InvItem.AvgUnitCost,
--     Phase 2), else the purchase rate / pack size; dbo.ufn_Qc_TestMaterialCost = BOM qty x unit cost x
--     (1 + reruns % + dead volume %).
--   Business-rule failures: THROW 53000-53099 (shown as is). Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Tables --------------------------------------------------------------------
IF OBJECT_ID(N'dbo.InvUnit', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvUnit
    (
        UnitId    INT IDENTITY(1,1) CONSTRAINT PK_InvUnit PRIMARY KEY,
        UnitCode  NVARCHAR(20) NOT NULL CONSTRAINT UQ_InvUnit_Code UNIQUE,
        UnitName  NVARCHAR(60) NOT NULL,
        IsActive  BIT NOT NULL CONSTRAINT DF_InvUnit_Active DEFAULT 1
    );
    INSERT INTO dbo.InvUnit (UnitCode, UnitName) VALUES
        (N'TEST', N'Test'), (N'ML', N'mL'), (N'UL', N'uL (microlitre)'), (N'L', N'Litre'), (N'G', N'Gram'), (N'PCS', N'Piece'),
        (N'TUBE', N'Tube'), (N'VIAL', N'Vial'), (N'BTL', N'Bottle'), (N'BOX', N'Box'), (N'KIT', N'Kit'), (N'PACK', N'Pack'),
        (N'STRIP', N'Strip'), (N'SLIDE', N'Slide'), (N'ROLL', N'Roll'), (N'CART', N'Cartridge');
END
GO

IF OBJECT_ID(N'dbo.InvItemCategory', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvItemCategory
    (
        CategoryId      INT IDENTITY(1,1) CONSTRAINT PK_InvItemCategory PRIMARY KEY,
        CategoryName    NVARCHAR(80) NOT NULL CONSTRAINT UQ_InvItemCategory_Name UNIQUE,
        IsLotTracked    BIT NOT NULL,       -- default for its items
        IsExpiryTracked BIT NOT NULL,
        IsQcMaterial    BIT NOT NULL CONSTRAINT DF_InvItemCategory_Qc DEFAULT 0,
        SortOrder       INT NOT NULL CONSTRAINT DF_InvItemCategory_Sort DEFAULT 0,
        IsActive        BIT NOT NULL CONSTRAINT DF_InvItemCategory_Active DEFAULT 1
    );
    INSERT INTO dbo.InvItemCategory (CategoryName, IsLotTracked, IsExpiryTracked, IsQcMaterial, SortOrder) VALUES
        (N'Reagent', 1, 1, 0, 10), (N'Kit', 1, 1, 0, 20), (N'Control / Calibrator', 1, 1, 1, 30),
        (N'Container / Tube', 1, 1, 0, 40), (N'Consumable', 0, 0, 0, 50), (N'Stationery', 0, 0, 0, 60);
END
GO

IF OBJECT_ID(N'dbo.InvItem', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvItem
    (
        ItemId             INT IDENTITY(1,1) CONSTRAINT PK_InvItem PRIMARY KEY,
        CompanyId          INT NOT NULL,
        ItemCode           NVARCHAR(20) NOT NULL,
        ItemName           NVARCHAR(200) NOT NULL,
        CategoryId         INT NOT NULL CONSTRAINT FK_InvItem_Category REFERENCES dbo.InvItemCategory(CategoryId),
        PurchaseUnitId     INT NOT NULL CONSTRAINT FK_InvItem_PUnit REFERENCES dbo.InvUnit(UnitId),
        ConsumptionUnitId  INT NOT NULL CONSTRAINT FK_InvItem_CUnit REFERENCES dbo.InvUnit(UnitId),
        PackSize           DECIMAL(14,3) NOT NULL,          -- consumption units in one purchase unit
        PurchaseRate       DECIMAL(14,2) NOT NULL CONSTRAINT DF_InvItem_Rate DEFAULT 0,   -- per purchase unit, before GST
        GstPercent         DECIMAL(5,2) NULL,
        HsnCode            NVARCHAR(20) NULL,
        Manufacturer       NVARCHAR(150) NULL,
        StorageTemp        NVARCHAR(50) NULL,
        OpenStabilityDays  INT NULL,
        MinShelfLifeDays   INT NULL,                        -- a GRN lot must have at least this many days left
        ReorderLevel       DECIMAL(14,3) NULL,              -- in purchase units
        MinStock           DECIMAL(14,3) NULL,
        MaxStock           DECIMAL(14,3) NULL,
        IsLotTracked       BIT NOT NULL,
        IsExpiryTracked    BIT NOT NULL,
        AvgUnitCost        DECIMAL(14,4) NULL,              -- per consumption unit, weighted average (Phase 2)
        Remarks            NVARCHAR(500) NULL,
        Status             BIT NOT NULL CONSTRAINT DF_InvItem_Status DEFAULT 1,
        IsDeleted          BIT NOT NULL CONSTRAINT DF_InvItem_Deleted DEFAULT 0,
        CreatedBy          INT NULL,
        CreatedDate        DATETIME NOT NULL CONSTRAINT DF_InvItem_Created DEFAULT GETDATE(),
        ModifiedBy         INT NULL,
        ModifiedDate       DATETIME NULL,
        CONSTRAINT CK_InvItem_Pack CHECK (PackSize > 0),
        CONSTRAINT CK_InvItem_Rate CHECK (PurchaseRate >= 0)
    );
    CREATE UNIQUE INDEX UX_InvItem_Code ON dbo.InvItem(CompanyId, ItemCode);
END
GO

IF OBJECT_ID(N'dbo.InvSupplier', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvSupplier
    (
        SupplierId       INT IDENTITY(1,1) CONSTRAINT PK_InvSupplier PRIMARY KEY,
        CompanyId        INT NOT NULL,
        SupplierCode     NVARCHAR(20) NOT NULL,
        SupplierName     NVARCHAR(200) NOT NULL,
        ContactPerson    NVARCHAR(150) NULL,
        Phone            NVARCHAR(20) NULL,
        Email            NVARCHAR(150) NULL,
        Address          NVARCHAR(500) NULL,
        Gstin            NVARCHAR(15) NULL,
        Pan              NVARCHAR(10) NULL,
        PaymentTermsDays INT NULL,
        IsApproved       BIT NOT NULL CONSTRAINT DF_InvSupplier_Approved DEFAULT 0,   -- approved supplier list (ISO 15189 6.8)
        ApprovedBy       INT NULL,
        ApprovedOn       DATETIME NULL,
        Remarks          NVARCHAR(500) NULL,
        Status           BIT NOT NULL CONSTRAINT DF_InvSupplier_Status DEFAULT 1,
        IsDeleted        BIT NOT NULL CONSTRAINT DF_InvSupplier_Deleted DEFAULT 0,
        CreatedBy        INT NULL,
        CreatedDate      DATETIME NOT NULL CONSTRAINT DF_InvSupplier_Created DEFAULT GETDATE(),
        ModifiedBy       INT NULL,
        ModifiedDate     DATETIME NULL
    );
    CREATE UNIQUE INDEX UX_InvSupplier_Code ON dbo.InvSupplier(CompanyId, SupplierCode);
END
GO

IF OBJECT_ID(N'dbo.InvStore', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvStore
    (
        StoreId      INT IDENTITY(1,1) CONSTRAINT PK_InvStore PRIMARY KEY,
        CompanyId    INT NOT NULL,
        BranchId     INT NOT NULL,
        StoreCode    NVARCHAR(20) NOT NULL,
        StoreName    NVARCHAR(150) NOT NULL,
        StoreType    VARCHAR(10) NOT NULL,        -- Main | Bench
        DepartmentId INT NULL,                    -- a bench store belongs to a LAB department
        Remarks      NVARCHAR(500) NULL,
        Status       BIT NOT NULL CONSTRAINT DF_InvStore_Status DEFAULT 1,
        IsDeleted    BIT NOT NULL CONSTRAINT DF_InvStore_Deleted DEFAULT 0,
        CreatedBy    INT NULL,
        CreatedDate  DATETIME NOT NULL CONSTRAINT DF_InvStore_Created DEFAULT GETDATE(),
        ModifiedBy   INT NULL,
        ModifiedDate DATETIME NULL,
        CONSTRAINT CK_InvStore_Type CHECK (StoreType IN ('Main', 'Bench'))
    );
    CREATE UNIQUE INDEX UX_InvStore_Code ON dbo.InvStore(CompanyId, StoreCode);
END
GO

IF OBJECT_ID(N'dbo.BomTest', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.BomTest
    (
        BomId          INT IDENTITY(1,1) CONSTRAINT PK_BomTest PRIMARY KEY,
        CompanyId      INT NOT NULL,
        TestId         INT NOT NULL,              -- LabInvestigationMaster.Test_ID (a billable test or profile test)
        AnalyzerId     INT NULL,                  -- tbl_mst_analyzer; NULL = the default BOM of the test
        VersionNo      INT NOT NULL,
        EffectiveFrom  DATETIME NOT NULL,
        EffectiveTo    DATETIME NULL,
        RerunPct       DECIMAL(5,2) NOT NULL CONSTRAINT DF_BomTest_Rerun DEFAULT 0,
        DeadVolumePct  DECIMAL(5,2) NOT NULL CONSTRAINT DF_BomTest_Dead DEFAULT 0,
        Remarks        NVARCHAR(500) NULL,
        IsActive       BIT NOT NULL,              -- the current version
        CreatedBy      INT NULL,
        CreatedDate    DATETIME NOT NULL CONSTRAINT DF_BomTest_Created DEFAULT GETDATE(),
        ClosedBy       INT NULL
    );
    CREATE INDEX IX_BomTest_Test ON dbo.BomTest(TestId, AnalyzerId, IsActive);
END
GO

IF OBJECT_ID(N'dbo.BomTestLine', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.BomTestLine
    (
        BomLineId INT IDENTITY(1,1) CONSTRAINT PK_BomTestLine PRIMARY KEY,
        BomId     INT NOT NULL CONSTRAINT FK_BomTestLine_Bom REFERENCES dbo.BomTest(BomId),
        ItemId    INT NOT NULL CONSTRAINT FK_BomTestLine_Item REFERENCES dbo.InvItem(ItemId),
        Qty       DECIMAL(14,4) NOT NULL,         -- consumption units for one test
        Remarks   NVARCHAR(200) NULL,
        CONSTRAINT CK_BomTestLine_Qty CHECK (Qty > 0)
    );
    CREATE INDEX IX_BomTestLine_Bom ON dbo.BomTestLine(BomId);
END
GO

IF OBJECT_ID(N'dbo.BomSampleKit', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.BomSampleKit
    (
        KitLineId    INT IDENTITY(1,1) CONSTRAINT PK_BomSampleKit PRIMARY KEY,
        CompanyId    INT NOT NULL,
        SampleTypeId INT NOT NULL,                -- LabSampleTypeMaster.Sample_Type_ID
        ItemId       INT NOT NULL CONSTRAINT FK_BomSampleKit_Item REFERENCES dbo.InvItem(ItemId),
        Qty          DECIMAL(14,4) NOT NULL,      -- consumption units per collected sample
        IsActive     BIT NOT NULL CONSTRAINT DF_BomSampleKit_Active DEFAULT 1,
        CreatedBy    INT NULL,
        CreatedDate  DATETIME NOT NULL CONSTRAINT DF_BomSampleKit_Created DEFAULT GETDATE(),
        CONSTRAINT CK_BomSampleKit_Qty CHECK (Qty > 0)
    );
    CREATE INDEX IX_BomSampleKit_Type ON dbo.BomSampleKit(SampleTypeId, IsActive);
END
GO

-- a Main Store for every branch
INSERT INTO dbo.InvStore (CompanyId, BranchId, StoreCode, StoreName, StoreType, CreatedBy)
SELECT b.CompanyId, b.BranchID, CONCAT('MS', RIGHT('000' + CAST(b.BranchID AS VARCHAR(10)), 3)), CONCAT(b.BranchName, ' - Main Store'), 'Main', 1
FROM dbo.Branchmaster b
WHERE ISNULL(b.IsActive, 1) = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.InvStore s WHERE s.BranchId = b.BranchID AND s.StoreType = 'Main' AND s.IsDeleted = 0);
GO

-- 2. Cost functions --------------------------------------------------------------
-- cost of one consumption unit: the weighted average once stock exists, else the purchase rate / pack size
CREATE OR ALTER FUNCTION dbo.ufn_Qc_ItemUnitCost (@ItemId INT)
RETURNS DECIMAL(14,4)
AS
BEGIN
    RETURN (SELECT CAST(COALESCE(AvgUnitCost, PurchaseRate / NULLIF(PackSize, 0), 0) AS DECIMAL(14,4)) FROM dbo.InvItem WHERE ItemId = @ItemId);
END;
GO

-- material cost of one run of a test from its current BOM (analyzer BOM when given and present, else the default)
CREATE OR ALTER FUNCTION dbo.ufn_Qc_TestMaterialCost (@TestId INT, @AnalyzerId INT)
RETURNS DECIMAL(14,2)
AS
BEGIN
    DECLARE @BomId INT = (SELECT TOP 1 BomId FROM dbo.BomTest
                          WHERE TestId = @TestId AND IsActive = 1 AND (AnalyzerId = @AnalyzerId OR AnalyzerId IS NULL)
                          ORDER BY CASE WHEN AnalyzerId = @AnalyzerId THEN 0 ELSE 1 END);
    IF @BomId IS NULL RETURN NULL;
    RETURN (SELECT CAST(ROUND(SUM(l.Qty * dbo.ufn_Qc_ItemUnitCost(l.ItemId)) * (1 + (b.RerunPct + b.DeadVolumePct) / 100.0), 2) AS DECIMAL(14,2))
            FROM dbo.BomTest b INNER JOIN dbo.BomTestLine l ON l.BomId = b.BomId WHERE b.BomId = @BomId GROUP BY b.RerunPct, b.DeadVolumePct);
END;
GO

-- collection kit cost of one sample of this type
CREATE OR ALTER FUNCTION dbo.ufn_Qc_SampleKitCost (@SampleTypeId INT)
RETURNS DECIMAL(14,2)
AS
BEGIN
    RETURN (SELECT CAST(ROUND(SUM(k.Qty * dbo.ufn_Qc_ItemUnitCost(k.ItemId)), 2) AS DECIMAL(14,2))
            FROM dbo.BomSampleKit k WHERE k.SampleTypeId = @SampleTypeId AND k.IsActive = 1);
END;
GO

-- 3. Lookups ------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Lookups
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT UnitId AS Id, UnitName AS Name, UnitCode AS Code FROM dbo.InvUnit WHERE IsActive = 1 ORDER BY UnitName;
    SELECT CategoryId AS Id, CategoryName AS Name, IsLotTracked, IsExpiryTracked, IsQcMaterial FROM dbo.InvItemCategory WHERE IsActive = 1 ORDER BY SortOrder;
    SELECT DeptId AS Id, DeptName AS Name FROM dbo.DepartmentMaster WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%') ORDER BY DeptName;
    SELECT Analyzer_ID AS Id, Analyzer_Name AS Name, Department_ID AS DepartmentId FROM dbo.tbl_mst_analyzer
    WHERE ISNULL(IsDeleted, 0) = 0 AND ISNULL(Status, 1) = 1 AND (CompanyId = @CompanyId OR CompanyId IS NULL) ORDER BY Analyzer_Name;
    SELECT BranchID AS Id, BranchName AS Name FROM dbo.Branchmaster WHERE ISNULL(IsActive, 1) = 1 AND (CompanyId = @CompanyId OR CompanyId IS NULL) ORDER BY BranchName;
    SELECT Sample_Type_ID AS Id, Sample_Name AS Name, Container_Type AS Container FROM dbo.LabSampleTypeMaster WHERE ISNULL(IsDeleted, 0) = 0 AND Status = 1 ORDER BY Sample_Name;
END;
GO

-- 4. Item Master --------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Item_List
    @CompanyId  INT,
    @Search     NVARCHAR(100) = NULL,
    @CategoryId INT = NULL,
    @Status     BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SELECT i.ItemId, i.ItemCode, i.ItemName, i.CategoryId, c.CategoryName, i.PurchaseUnitId, pu.UnitName AS PurchaseUnit,
           i.ConsumptionUnitId, cu.UnitName AS ConsumptionUnit, i.PackSize, i.PurchaseRate, i.GstPercent, i.HsnCode, i.Manufacturer,
           i.StorageTemp, i.OpenStabilityDays, i.MinShelfLifeDays, i.ReorderLevel, i.MinStock, i.MaxStock, i.IsLotTracked, i.IsExpiryTracked,
           i.AvgUnitCost, dbo.ufn_Qc_ItemUnitCost(i.ItemId) AS UnitCost, i.Remarks, i.Status,
           (SELECT COUNT(DISTINCT b.TestId) FROM dbo.BomTestLine l INNER JOIN dbo.BomTest b ON b.BomId = l.BomId AND b.IsActive = 1 WHERE l.ItemId = i.ItemId) AS UsedInTests
    FROM dbo.InvItem i
    INNER JOIN dbo.InvItemCategory c ON c.CategoryId = i.CategoryId
    INNER JOIN dbo.InvUnit pu ON pu.UnitId = i.PurchaseUnitId
    INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    WHERE i.CompanyId = @CompanyId AND i.IsDeleted = 0
      AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
      AND (@Status IS NULL OR i.Status = @Status)
      AND (@Search IS NULL OR i.ItemName LIKE '%' + @Search + '%' OR i.ItemCode LIKE '%' + @Search + '%' OR i.Manufacturer LIKE '%' + @Search + '%')
    ORDER BY i.ItemName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Item_Save
    @ItemId            INT = NULL,
    @CompanyId         INT,
    @ItemName          NVARCHAR(200),
    @CategoryId        INT,
    @PurchaseUnitId    INT,
    @ConsumptionUnitId INT,
    @PackSize          DECIMAL(14,3),
    @PurchaseRate      DECIMAL(14,2) = 0,
    @GstPercent        DECIMAL(5,2) = NULL,
    @HsnCode           NVARCHAR(20) = NULL,
    @Manufacturer      NVARCHAR(150) = NULL,
    @StorageTemp       NVARCHAR(50) = NULL,
    @OpenStabilityDays INT = NULL,
    @MinShelfLifeDays  INT = NULL,
    @ReorderLevel      DECIMAL(14,3) = NULL,
    @MinStock          DECIMAL(14,3) = NULL,
    @MaxStock          DECIMAL(14,3) = NULL,
    @IsLotTracked      BIT = NULL,
    @IsExpiryTracked   BIT = NULL,
    @Remarks           NVARCHAR(500) = NULL,
    @Status            BIT = 1,
    @UserId            INT = NULL,
    @NewId             INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @ItemName = NULLIF(LTRIM(RTRIM(@ItemName)), '');
    IF @ItemName IS NULL THROW 53001, 'Item name is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.InvItemCategory WHERE CategoryId = @CategoryId AND IsActive = 1) THROW 53002, 'Choose the item category.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.InvUnit WHERE UnitId = @PurchaseUnitId AND IsActive = 1) THROW 53003, 'Choose the purchase unit.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.InvUnit WHERE UnitId = @ConsumptionUnitId AND IsActive = 1) THROW 53004, 'Choose the consumption unit.', 1;
    IF ISNULL(@PackSize, 0) <= 0 THROW 53005, 'Pack size must be more than 0 (consumption units in one purchase unit).', 1;
    IF @PurchaseUnitId = @ConsumptionUnitId AND @PackSize <> 1 THROW 53006, 'When the purchase and consumption units are the same, the pack size must be 1.', 1;
    IF ISNULL(@PurchaseRate, 0) < 0 THROW 53007, 'Purchase rate cannot be negative.', 1;
    IF @GstPercent IS NOT NULL AND (@GstPercent < 0 OR @GstPercent > 28) THROW 53008, 'GST must be between 0 and 28 percent.', 1;
    IF @OpenStabilityDays IS NOT NULL AND (@OpenStabilityDays < 0 OR @OpenStabilityDays > 3650) THROW 53009, 'Open-vial stability must be 0 to 3650 days.', 1;
    IF @MinShelfLifeDays IS NOT NULL AND (@MinShelfLifeDays < 0 OR @MinShelfLifeDays > 3650) THROW 53010, 'Minimum shelf life must be 0 to 3650 days.', 1;
    IF @ReorderLevel < 0 OR @MinStock < 0 OR @MaxStock < 0 THROW 53011, 'Stock levels cannot be negative.', 1;
    IF @MinStock IS NOT NULL AND @MaxStock IS NOT NULL AND @MinStock > @MaxStock THROW 53012, 'Minimum stock cannot be more than maximum stock.', 1;
    IF @ReorderLevel IS NOT NULL AND @MaxStock IS NOT NULL AND @ReorderLevel > @MaxStock THROW 53013, 'Reorder level cannot be more than maximum stock.', 1;
    IF EXISTS (SELECT 1 FROM dbo.InvItem WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND LOWER(ItemName) = LOWER(@ItemName) AND ItemId <> ISNULL(@ItemId, 0))
        THROW 53014, 'An item with this name already exists.', 1;

    -- lot / expiry tracking: the category's default unless set; expiry tracking needs lot tracking
    DECLARE @CatLot BIT, @CatExp BIT;
    SELECT @CatLot = IsLotTracked, @CatExp = IsExpiryTracked FROM dbo.InvItemCategory WHERE CategoryId = @CategoryId;
    SET @IsLotTracked = ISNULL(@IsLotTracked, @CatLot);
    SET @IsExpiryTracked = ISNULL(@IsExpiryTracked, @CatExp);
    IF @IsExpiryTracked = 1 AND @IsLotTracked = 0 THROW 53015, 'An expiry-tracked item must also be lot-tracked.', 1;

    IF ISNULL(@ItemId, 0) = 0
    BEGIN
        DECLARE @Next INT = (SELECT ISNULL(MAX(TRY_CAST(SUBSTRING(ItemCode, 3, 18) AS INT)), 0) + 1 FROM dbo.InvItem WITH (UPDLOCK, HOLDLOCK) WHERE CompanyId = @CompanyId AND ItemCode LIKE 'IT%');
        INSERT INTO dbo.InvItem (CompanyId, ItemCode, ItemName, CategoryId, PurchaseUnitId, ConsumptionUnitId, PackSize, PurchaseRate, GstPercent, HsnCode,
                                 Manufacturer, StorageTemp, OpenStabilityDays, MinShelfLifeDays, ReorderLevel, MinStock, MaxStock, IsLotTracked, IsExpiryTracked,
                                 Remarks, Status, CreatedBy)
        VALUES (@CompanyId, 'IT' + RIGHT('0000' + CAST(@Next AS VARCHAR(10)), 4), @ItemName, @CategoryId, @PurchaseUnitId, @ConsumptionUnitId, @PackSize,
                ISNULL(@PurchaseRate, 0), NULLIF(@GstPercent, 0), NULLIF(LTRIM(RTRIM(@HsnCode)), ''), NULLIF(LTRIM(RTRIM(@Manufacturer)), ''),
                NULLIF(LTRIM(RTRIM(@StorageTemp)), ''), @OpenStabilityDays, @MinShelfLifeDays, @ReorderLevel, @MinStock, @MaxStock, @IsLotTracked, @IsExpiryTracked,
                NULLIF(LTRIM(RTRIM(@Remarks)), ''), ISNULL(@Status, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.InvItem WHERE ItemId = @ItemId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 53016, 'Item not found.', 1;
        -- the consumption unit and pack size fix every BOM quantity and stock figure: they cannot change once used
        IF EXISTS (SELECT 1 FROM dbo.InvItem WHERE ItemId = @ItemId AND (ConsumptionUnitId <> @ConsumptionUnitId OR PackSize <> @PackSize))
           AND (EXISTS (SELECT 1 FROM dbo.BomTestLine WHERE ItemId = @ItemId) OR EXISTS (SELECT 1 FROM dbo.BomSampleKit WHERE ItemId = @ItemId))
            THROW 53017, 'The consumption unit and pack size cannot change once the item is used in a BOM or stock.', 1;
        UPDATE dbo.InvItem SET ItemName = @ItemName, CategoryId = @CategoryId, PurchaseUnitId = @PurchaseUnitId, ConsumptionUnitId = @ConsumptionUnitId,
               PackSize = @PackSize, PurchaseRate = ISNULL(@PurchaseRate, 0), GstPercent = NULLIF(@GstPercent, 0), HsnCode = NULLIF(LTRIM(RTRIM(@HsnCode)), ''),
               Manufacturer = NULLIF(LTRIM(RTRIM(@Manufacturer)), ''), StorageTemp = NULLIF(LTRIM(RTRIM(@StorageTemp)), ''), OpenStabilityDays = @OpenStabilityDays,
               MinShelfLifeDays = @MinShelfLifeDays, ReorderLevel = @ReorderLevel, MinStock = @MinStock, MaxStock = @MaxStock, IsLotTracked = @IsLotTracked,
               IsExpiryTracked = @IsExpiryTracked, Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''), Status = ISNULL(@Status, 1), ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE ItemId = @ItemId;
        SET @NewId = @ItemId;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Item_SetStatus
    @ItemId INT, @CompanyId INT, @Status BIT, @Delete BIT = 0, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.InvItem WHERE ItemId = @ItemId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 53016, 'Item not found.', 1;
    IF (@Delete = 1 OR @Status = 0)
       AND (EXISTS (SELECT 1 FROM dbo.BomTestLine l INNER JOIN dbo.BomTest b ON b.BomId = l.BomId AND b.IsActive = 1 WHERE l.ItemId = @ItemId)
            OR EXISTS (SELECT 1 FROM dbo.BomSampleKit WHERE ItemId = @ItemId AND IsActive = 1))
        THROW 53018, 'This item is used in a current BOM or sample kit. Remove it there first.', 1;
    UPDATE dbo.InvItem SET Status = CASE WHEN @Delete = 1 THEN 0 ELSE @Status END, IsDeleted = CASE WHEN @Delete = 1 THEN 1 ELSE 0 END,
           ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE ItemId = @ItemId;
END;
GO

-- 5. Supplier Master --------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Supplier_List
    @CompanyId INT, @Search NVARCHAR(100) = NULL, @Status BIT = NULL, @Approved BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SELECT s.SupplierId, s.SupplierCode, s.SupplierName, s.ContactPerson, s.Phone, s.Email, s.Address, s.Gstin, s.Pan, s.PaymentTermsDays,
           s.IsApproved, s.ApprovedOn, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS ApprovedByName, s.Remarks, s.Status
    FROM dbo.InvSupplier s LEFT JOIN dbo.Users u ON u.Id = s.ApprovedBy
    WHERE s.CompanyId = @CompanyId AND s.IsDeleted = 0
      AND (@Status IS NULL OR s.Status = @Status) AND (@Approved IS NULL OR s.IsApproved = @Approved)
      AND (@Search IS NULL OR s.SupplierName LIKE '%' + @Search + '%' OR s.SupplierCode LIKE '%' + @Search + '%' OR s.Gstin LIKE '%' + @Search + '%' OR s.Phone LIKE '%' + @Search + '%')
    ORDER BY s.SupplierName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Supplier_Save
    @SupplierId INT = NULL, @CompanyId INT, @SupplierName NVARCHAR(200), @ContactPerson NVARCHAR(150) = NULL, @Phone NVARCHAR(20) = NULL,
    @Email NVARCHAR(150) = NULL, @Address NVARCHAR(500) = NULL, @Gstin NVARCHAR(15) = NULL, @Pan NVARCHAR(10) = NULL, @PaymentTermsDays INT = NULL,
    @IsApproved BIT = 0, @Remarks NVARCHAR(500) = NULL, @Status BIT = 1, @UserId INT = NULL, @NewId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @SupplierName = NULLIF(LTRIM(RTRIM(@SupplierName)), '');
    SET @Phone = NULLIF(LTRIM(RTRIM(@Phone)), ''); SET @Email = NULLIF(LTRIM(RTRIM(@Email)), '');
    SET @Gstin = UPPER(NULLIF(LTRIM(RTRIM(@Gstin)), '')); SET @Pan = UPPER(NULLIF(LTRIM(RTRIM(@Pan)), ''));
    IF @SupplierName IS NULL THROW 53021, 'Supplier name is required.', 1;
    IF @Phone IS NOT NULL AND (LEN(@Phone) <> 10 OR @Phone LIKE '%[^0-9]%') THROW 53022, 'Phone must be a 10-digit mobile number.', 1;
    IF @Email IS NOT NULL AND @Email NOT LIKE '%_@_%._%' THROW 53023, 'E-mail is not valid.', 1;
    IF @Gstin IS NOT NULL AND (LEN(@Gstin) <> 15 OR @Gstin NOT LIKE '[0-9][0-9][A-Z][A-Z][A-Z][A-Z][A-Z][0-9][0-9][0-9][0-9][A-Z][1-9A-Z]Z[0-9A-Z]')
        THROW 53024, 'GSTIN must be 15 characters in the GST format (e.g. 19ABCDE1234F1Z5).', 1;
    IF @Pan IS NOT NULL AND (LEN(@Pan) <> 10 OR @Pan NOT LIKE '[A-Z][A-Z][A-Z][A-Z][A-Z][0-9][0-9][0-9][0-9][A-Z]') THROW 53025, 'PAN must be 10 characters (e.g. ABCDE1234F).', 1;
    IF @Gstin IS NOT NULL AND @Pan IS NOT NULL AND SUBSTRING(@Gstin, 3, 10) <> @Pan THROW 53026, 'The PAN does not match the PAN inside the GSTIN.', 1;
    IF @PaymentTermsDays IS NOT NULL AND (@PaymentTermsDays < 0 OR @PaymentTermsDays > 365) THROW 53027, 'Payment terms must be 0 to 365 days.', 1;
    IF EXISTS (SELECT 1 FROM dbo.InvSupplier WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND LOWER(SupplierName) = LOWER(@SupplierName) AND SupplierId <> ISNULL(@SupplierId, 0))
        THROW 53028, 'A supplier with this name already exists.', 1;
    IF @Gstin IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.InvSupplier WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND Gstin = @Gstin AND SupplierId <> ISNULL(@SupplierId, 0))
        THROW 53029, 'Another supplier already has this GSTIN.', 1;

    IF ISNULL(@SupplierId, 0) = 0
    BEGIN
        DECLARE @Next INT = (SELECT ISNULL(MAX(TRY_CAST(SUBSTRING(SupplierCode, 4, 17) AS INT)), 0) + 1 FROM dbo.InvSupplier WITH (UPDLOCK, HOLDLOCK) WHERE CompanyId = @CompanyId AND SupplierCode LIKE 'SUP%');
        INSERT INTO dbo.InvSupplier (CompanyId, SupplierCode, SupplierName, ContactPerson, Phone, Email, Address, Gstin, Pan, PaymentTermsDays, IsApproved, ApprovedBy, ApprovedOn, Remarks, Status, CreatedBy)
        VALUES (@CompanyId, 'SUP' + RIGHT('0000' + CAST(@Next AS VARCHAR(10)), 4), @SupplierName, NULLIF(LTRIM(RTRIM(@ContactPerson)), ''), @Phone, @Email,
                NULLIF(LTRIM(RTRIM(@Address)), ''), @Gstin, @Pan, @PaymentTermsDays, ISNULL(@IsApproved, 0),
                CASE WHEN @IsApproved = 1 THEN @UserId END, CASE WHEN @IsApproved = 1 THEN GETDATE() END, NULLIF(LTRIM(RTRIM(@Remarks)), ''), ISNULL(@Status, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.InvSupplier WHERE SupplierId = @SupplierId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 53030, 'Supplier not found.', 1;
        UPDATE dbo.InvSupplier SET SupplierName = @SupplierName, ContactPerson = NULLIF(LTRIM(RTRIM(@ContactPerson)), ''), Phone = @Phone, Email = @Email,
               Address = NULLIF(LTRIM(RTRIM(@Address)), ''), Gstin = @Gstin, Pan = @Pan, PaymentTermsDays = @PaymentTermsDays,
               ApprovedBy = CASE WHEN ISNULL(@IsApproved, 0) = 1 AND IsApproved = 0 THEN @UserId WHEN ISNULL(@IsApproved, 0) = 0 THEN NULL ELSE ApprovedBy END,
               ApprovedOn = CASE WHEN ISNULL(@IsApproved, 0) = 1 AND IsApproved = 0 THEN GETDATE() WHEN ISNULL(@IsApproved, 0) = 0 THEN NULL ELSE ApprovedOn END,
               IsApproved = ISNULL(@IsApproved, 0), Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''), Status = ISNULL(@Status, 1), ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE SupplierId = @SupplierId;
        SET @NewId = @SupplierId;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Supplier_SetStatus
    @SupplierId INT, @CompanyId INT, @Status BIT, @Delete BIT = 0, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.InvSupplier WHERE SupplierId = @SupplierId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 53030, 'Supplier not found.', 1;
    UPDATE dbo.InvSupplier SET Status = CASE WHEN @Delete = 1 THEN 0 ELSE @Status END, IsDeleted = CASE WHEN @Delete = 1 THEN 1 ELSE 0 END, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE SupplierId = @SupplierId;
END;
GO

-- 6. Store / Location -----------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Store_List
    @CompanyId INT, @BranchId INT = NULL, @Search NVARCHAR(100) = NULL, @Status BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SELECT s.StoreId, s.StoreCode, s.StoreName, s.StoreType, s.BranchId, b.BranchName, s.DepartmentId, d.DeptName AS DepartmentName, s.Remarks, s.Status
    FROM dbo.InvStore s
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = s.DepartmentId
    WHERE s.CompanyId = @CompanyId AND s.IsDeleted = 0 AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND (@Status IS NULL OR s.Status = @Status)
      AND (@Search IS NULL OR s.StoreName LIKE '%' + @Search + '%' OR s.StoreCode LIKE '%' + @Search + '%')
    ORDER BY b.BranchName, CASE s.StoreType WHEN 'Main' THEN 0 ELSE 1 END, s.StoreName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Store_Save
    @StoreId INT = NULL, @CompanyId INT, @BranchId INT, @StoreName NVARCHAR(150), @StoreType VARCHAR(10), @DepartmentId INT = NULL,
    @Remarks NVARCHAR(500) = NULL, @Status BIT = 1, @UserId INT = NULL, @NewId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @StoreName = NULLIF(LTRIM(RTRIM(@StoreName)), '');
    IF @StoreName IS NULL THROW 53041, 'Store name is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId) THROW 53042, 'Choose the branch.', 1;
    IF @StoreType NOT IN ('Main', 'Bench') THROW 53043, 'Store type must be Main or Bench.', 1;
    IF @StoreType = 'Bench' AND NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE DeptId = @DepartmentId AND IsActive = 1)
        THROW 53044, 'A bench store needs its LAB department.', 1;
    IF @StoreType = 'Main' SET @DepartmentId = NULL;
    IF @StoreType = 'Main' AND EXISTS (SELECT 1 FROM dbo.InvStore WHERE BranchId = @BranchId AND StoreType = 'Main' AND IsDeleted = 0 AND StoreId <> ISNULL(@StoreId, 0))
        THROW 53045, 'This branch already has its Main Store.', 1;
    IF @StoreType = 'Bench' AND EXISTS (SELECT 1 FROM dbo.InvStore WHERE BranchId = @BranchId AND StoreType = 'Bench' AND DepartmentId = @DepartmentId AND IsDeleted = 0 AND StoreId <> ISNULL(@StoreId, 0))
        THROW 53046, 'This department already has a bench store in this branch.', 1;
    IF EXISTS (SELECT 1 FROM dbo.InvStore WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND IsDeleted = 0 AND LOWER(StoreName) = LOWER(@StoreName) AND StoreId <> ISNULL(@StoreId, 0))
        THROW 53047, 'A store with this name already exists in this branch.', 1;

    IF ISNULL(@StoreId, 0) = 0
    BEGIN
        DECLARE @Next INT = (SELECT ISNULL(MAX(StoreId), 0) + 1 FROM dbo.InvStore WITH (UPDLOCK, HOLDLOCK));
        INSERT INTO dbo.InvStore (CompanyId, BranchId, StoreCode, StoreName, StoreType, DepartmentId, Remarks, Status, CreatedBy)
        VALUES (@CompanyId, @BranchId, CONCAT(CASE @StoreType WHEN 'Main' THEN 'MS' ELSE 'BS' END, RIGHT('0000' + CAST(@Next AS VARCHAR(10)), 4)), @StoreName, @StoreType,
                @DepartmentId, NULLIF(LTRIM(RTRIM(@Remarks)), ''), ISNULL(@Status, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.InvStore WHERE StoreId = @StoreId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 53048, 'Store not found.', 1;
        IF EXISTS (SELECT 1 FROM dbo.InvStore WHERE StoreId = @StoreId AND (BranchId <> @BranchId OR StoreType <> @StoreType))
           AND OBJECT_ID('dbo.InvStockLedger') IS NOT NULL
           AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.InvStockLedger') AND name = 'StoreId')
        BEGIN
            DECLARE @Used BIT = 0;
            EXEC sp_executesql N'SELECT @u = CASE WHEN EXISTS (SELECT 1 FROM dbo.InvStockLedger WHERE StoreId = @s) THEN 1 ELSE 0 END', N'@s INT, @u BIT OUTPUT', @s = @StoreId, @u = @Used OUTPUT;
            IF @Used = 1 THROW 53049, 'The branch and type of a store with stock movements cannot change.', 1;
        END
        UPDATE dbo.InvStore SET BranchId = @BranchId, StoreName = @StoreName, StoreType = @StoreType, DepartmentId = @DepartmentId,
               Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''), Status = ISNULL(@Status, 1), ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE StoreId = @StoreId;
        SET @NewId = @StoreId;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Store_SetStatus
    @StoreId INT, @CompanyId INT, @Status BIT, @Delete BIT = 0, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.InvStore WHERE StoreId = @StoreId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 53048, 'Store not found.', 1;
    IF (@Delete = 1 OR @Status = 0) AND EXISTS (SELECT 1 FROM dbo.InvStore WHERE StoreId = @StoreId AND StoreType = 'Main')
        THROW 53050, 'A branch''s Main Store cannot be switched off or deleted.', 1;
    UPDATE dbo.InvStore SET Status = CASE WHEN @Delete = 1 THEN 0 ELSE @Status END, IsDeleted = CASE WHEN @Delete = 1 THEN 1 ELSE 0 END, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE StoreId = @StoreId;
END;
GO

-- 7. Test BOM ------------------------------------------------------------------------------------
-- tests with their BOM status and standard material cost (billable tests and profile tests; parameters are not billed)
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Bom_TestList
    @CompanyId INT, @BranchId INT, @Search NVARCHAR(100) = NULL, @DepartmentId INT = NULL, @BomStatus VARCHAR(10) = NULL   -- WITH | WITHOUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @BomStatus = NULLIF(UPPER(LTRIM(RTRIM(@BomStatus))), '');
    ;WITH t AS (
        SELECT m.Test_ID AS TestId, m.Test_Code AS TestCode, m.Test_Name AS TestName, d.DeptName AS DepartmentName, m.Department_ID AS DepartmentId,
               st.Sample_Name AS SampleType, m.Sample_Type_ID AS SampleTypeId, CAST(ISNULL(m.Is_Profile_Test, 0) AS BIT) AS IsProfileTest,
               CAST(ISNULL(m.Is_Outsourced, 0) AS BIT) AS IsOutsourced,
               (SELECT TOP 1 b.BomId FROM dbo.BomTest b WHERE b.TestId = m.Test_ID AND b.IsActive = 1 AND b.AnalyzerId IS NULL) AS BomId,
               (SELECT COUNT(1) FROM dbo.BomTest b WHERE b.TestId = m.Test_ID AND b.IsActive = 1) AS ActiveBoms
        FROM dbo.LabInvestigationMaster m
        LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = m.Department_ID
        LEFT JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = m.Sample_Type_ID
        WHERE ISNULL(m.IsDeleted, 0) = 0 AND m.Status = 1 AND (m.CompanyId = @CompanyId OR m.CompanyId IS NULL)
          AND (ISNULL(m.Is_Billable, 1) = 1 OR ISNULL(m.Is_Profile_Test, 0) = 1)
          AND (@DepartmentId IS NULL OR m.Department_ID = @DepartmentId)
          AND (@Search IS NULL OR m.Test_Name LIKE '%' + @Search + '%' OR m.Test_Code LIKE '%' + @Search + '%'))
    SELECT t.*, b.VersionNo, b.EffectiveFrom, b.RerunPct, b.DeadVolumePct,
           (SELECT COUNT(1) FROM dbo.BomTestLine l WHERE l.BomId = t.BomId) AS LineCount,
           dbo.ufn_Qc_TestMaterialCost(t.TestId, NULL) AS MaterialCost,
           dbo.ufn_Qc_SampleKitCost(t.SampleTypeId) AS SampleKitCost,
           r.B2CRate
    FROM t
    LEFT JOIN dbo.BomTest b ON b.BomId = t.BomId
    OUTER APPLY (SELECT TOP 1 x.B2CRate FROM dbo.fn_LabBookableItems(@BranchId, 'B2C', NULL) x
                 WHERE x.Item_ID = t.TestId AND x.Item_Type = CASE WHEN t.IsProfileTest = 1 THEN 'Profile' ELSE 'Test' END) r
    WHERE (@BomStatus IS NULL OR (@BomStatus = 'WITH' AND t.ActiveBoms > 0) OR (@BomStatus = 'WITHOUT' AND t.ActiveBoms = 0))
    ORDER BY t.DepartmentName, t.TestName;
END;
GO

-- one test's BOM: the test, its current version (default or the analyzer's), the lines, the version history
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Bom_Get
    @TestId INT, @AnalyzerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.Test_ID AS TestId, m.Test_Code AS TestCode, m.Test_Name AS TestName, d.DeptName AS DepartmentName, m.Department_ID AS DepartmentId,
           st.Sample_Name AS SampleType, CAST(ISNULL(m.Is_Profile_Test, 0) AS BIT) AS IsProfileTest, CAST(ISNULL(m.Is_Outsourced, 0) AS BIT) AS IsOutsourced
    FROM dbo.LabInvestigationMaster m
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = m.Department_ID
    LEFT JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = m.Sample_Type_ID
    WHERE m.Test_ID = @TestId;

    DECLARE @BomId INT = (SELECT TOP 1 BomId FROM dbo.BomTest WHERE TestId = @TestId AND IsActive = 1
                          AND ((@AnalyzerId IS NULL AND AnalyzerId IS NULL) OR AnalyzerId = @AnalyzerId));
    SELECT b.BomId, b.AnalyzerId, b.VersionNo, b.EffectiveFrom, b.RerunPct, b.DeadVolumePct, b.Remarks FROM dbo.BomTest b WHERE b.BomId = @BomId;

    SELECT l.BomLineId, l.ItemId, i.ItemCode, i.ItemName, cu.UnitName AS ConsumptionUnit, l.Qty, l.Remarks, dbo.ufn_Qc_ItemUnitCost(l.ItemId) AS UnitCost,
           CAST(ROUND(l.Qty * dbo.ufn_Qc_ItemUnitCost(l.ItemId), 4) AS DECIMAL(14,4)) AS LineCost, i.Status AS ItemActive
    FROM dbo.BomTestLine l INNER JOIN dbo.InvItem i ON i.ItemId = l.ItemId INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    WHERE l.BomId = @BomId ORDER BY l.BomLineId;

    SELECT b.BomId, b.AnalyzerId, a.Analyzer_Name AS AnalyzerName, b.VersionNo, b.EffectiveFrom, b.EffectiveTo, b.IsActive,
           (SELECT COUNT(1) FROM dbo.BomTestLine l WHERE l.BomId = b.BomId) AS LineCount,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS CreatedByName, b.RerunPct, b.DeadVolumePct
    FROM dbo.BomTest b LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = b.AnalyzerId LEFT JOIN dbo.Users u ON u.Id = b.CreatedBy
    WHERE b.TestId = @TestId ORDER BY b.IsActive DESC, b.AnalyzerId, b.VersionNo DESC;
END;
GO

-- save a test's BOM: an unchanged BOM is kept; a changed one closes the current version and starts the next
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Bom_Save
    @CompanyId INT, @TestId INT, @AnalyzerId INT = NULL, @RerunPct DECIMAL(5,2) = 0, @DeadVolumePct DECIMAL(5,2) = 0,
    @Remarks NVARCHAR(500) = NULL, @LinesJson NVARCHAR(MAX), @UserId INT = NULL, @BomId INT = NULL OUTPUT, @Changed BIT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_ID = @TestId AND ISNULL(IsDeleted, 0) = 0) THROW 53061, 'Test not found.', 1;
    IF @AnalyzerId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.tbl_mst_analyzer WHERE Analyzer_ID = @AnalyzerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 53062, 'The analyzer is not valid.', 1;
    IF @RerunPct < 0 OR @RerunPct > 100 OR @DeadVolumePct < 0 OR @DeadVolumePct > 100 THROW 53063, 'Reruns and dead volume must be 0 to 100 percent.', 1;

    DECLARE @L TABLE (ItemId INT, Qty DECIMAL(14,4), Remarks NVARCHAR(200));
    INSERT INTO @L (ItemId, Qty, Remarks)
    SELECT j.itemId, j.qty, NULLIF(LTRIM(RTRIM(j.remarks)), '')
    FROM OPENJSON(ISNULL(@LinesJson, '[]')) WITH (itemId INT '$.itemId', qty DECIMAL(14,4) '$.qty', remarks NVARCHAR(200) '$.remarks') j;
    IF NOT EXISTS (SELECT 1 FROM @L) THROW 53064, 'Add at least one item to the BOM.', 1;
    IF EXISTS (SELECT 1 FROM @L WHERE ISNULL(Qty, 0) <= 0) THROW 53065, 'Every BOM line needs a quantity more than 0.', 1;
    IF EXISTS (SELECT 1 FROM @L GROUP BY ItemId HAVING COUNT(1) > 1) THROW 53066, 'An item appears more than once in the BOM.', 1;
    IF EXISTS (SELECT 1 FROM @L l WHERE NOT EXISTS (SELECT 1 FROM dbo.InvItem i WHERE i.ItemId = l.ItemId AND i.CompanyId = @CompanyId AND i.IsDeleted = 0 AND i.Status = 1))
        THROW 53067, 'A BOM item is not an active item of the Item Master.', 1;

    DECLARE @Cur INT = (SELECT TOP 1 BomId FROM dbo.BomTest WHERE TestId = @TestId AND IsActive = 1
                        AND ((@AnalyzerId IS NULL AND AnalyzerId IS NULL) OR AnalyzerId = @AnalyzerId));
    -- unchanged (same lines, quantities and percentages) = nothing to version
    IF @Cur IS NOT NULL
       AND EXISTS (SELECT 1 FROM dbo.BomTest WHERE BomId = @Cur AND RerunPct = @RerunPct AND DeadVolumePct = @DeadVolumePct)
       AND NOT EXISTS (SELECT ItemId, Qty FROM @L EXCEPT SELECT ItemId, Qty FROM dbo.BomTestLine WHERE BomId = @Cur)
       AND NOT EXISTS (SELECT ItemId, Qty FROM dbo.BomTestLine WHERE BomId = @Cur EXCEPT SELECT ItemId, Qty FROM @L)
    BEGIN
        UPDATE dbo.BomTest SET Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), '') WHERE BomId = @Cur;
        UPDATE bl SET Remarks = l.Remarks FROM dbo.BomTestLine bl INNER JOIN @L l ON l.ItemId = bl.ItemId WHERE bl.BomId = @Cur;
        SET @BomId = @Cur; SET @Changed = 0;
        RETURN;
    END

    BEGIN TRANSACTION;
        DECLARE @Ver INT = ISNULL((SELECT MAX(VersionNo) FROM dbo.BomTest WHERE TestId = @TestId AND ((@AnalyzerId IS NULL AND AnalyzerId IS NULL) OR AnalyzerId = @AnalyzerId)), 0) + 1;
        DECLARE @Now DATETIME = GETDATE();
        UPDATE dbo.BomTest SET IsActive = 0, EffectiveTo = @Now, ClosedBy = @UserId WHERE BomId = @Cur;
        INSERT INTO dbo.BomTest (CompanyId, TestId, AnalyzerId, VersionNo, EffectiveFrom, RerunPct, DeadVolumePct, Remarks, IsActive, CreatedBy)
        VALUES (@CompanyId, @TestId, @AnalyzerId, @Ver, @Now, @RerunPct, @DeadVolumePct, NULLIF(LTRIM(RTRIM(@Remarks)), ''), 1, @UserId);
        SET @BomId = SCOPE_IDENTITY();
        INSERT INTO dbo.BomTestLine (BomId, ItemId, Qty, Remarks) SELECT @BomId, ItemId, Qty, Remarks FROM @L;
    COMMIT TRANSACTION;
    SET @Changed = 1;
END;
GO

-- stop using a test's BOM (the version is closed, kept for history)
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Bom_Remove
    @TestId INT, @AnalyzerId INT = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.BomTest SET IsActive = 0, EffectiveTo = GETDATE(), ClosedBy = @UserId
    WHERE TestId = @TestId AND IsActive = 1 AND ((@AnalyzerId IS NULL AND AnalyzerId IS NULL) OR AnalyzerId = @AnalyzerId);
    IF @@ROWCOUNT = 0 THROW 53068, 'This test has no current BOM.', 1;
END;
GO

-- 8. Sample collection kits ------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Qc_SampleKit_List
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT st.Sample_Type_ID AS SampleTypeId, st.Sample_Name AS SampleType, st.Container_Type AS Container,
           (SELECT COUNT(1) FROM dbo.BomSampleKit k WHERE k.SampleTypeId = st.Sample_Type_ID AND k.IsActive = 1) AS LineCount,
           dbo.ufn_Qc_SampleKitCost(st.Sample_Type_ID) AS KitCost,
           (SELECT COUNT(1) FROM dbo.LabInvestigationMaster m WHERE m.Sample_Type_ID = st.Sample_Type_ID AND ISNULL(m.IsDeleted, 0) = 0 AND m.Status = 1) AS Tests
    FROM dbo.LabSampleTypeMaster st
    WHERE ISNULL(st.IsDeleted, 0) = 0 AND st.Status = 1
    ORDER BY st.Sample_Name;

    SELECT k.KitLineId, k.SampleTypeId, k.ItemId, i.ItemCode, i.ItemName, cu.UnitName AS ConsumptionUnit, k.Qty, dbo.ufn_Qc_ItemUnitCost(k.ItemId) AS UnitCost,
           CAST(ROUND(k.Qty * dbo.ufn_Qc_ItemUnitCost(k.ItemId), 4) AS DECIMAL(14,4)) AS LineCost
    FROM dbo.BomSampleKit k INNER JOIN dbo.InvItem i ON i.ItemId = k.ItemId INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    WHERE k.IsActive = 1 AND k.CompanyId = @CompanyId
    ORDER BY k.SampleTypeId, k.KitLineId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_SampleKit_Save
    @CompanyId INT, @SampleTypeId INT, @LinesJson NVARCHAR(MAX), @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @SampleTypeId) THROW 53071, 'Sample type not found.', 1;
    DECLARE @L TABLE (ItemId INT, Qty DECIMAL(14,4));
    INSERT INTO @L SELECT j.itemId, j.qty FROM OPENJSON(ISNULL(@LinesJson, '[]')) WITH (itemId INT '$.itemId', qty DECIMAL(14,4) '$.qty') j;
    IF EXISTS (SELECT 1 FROM @L WHERE ISNULL(Qty, 0) <= 0) THROW 53072, 'Every kit line needs a quantity more than 0.', 1;
    IF EXISTS (SELECT 1 FROM @L GROUP BY ItemId HAVING COUNT(1) > 1) THROW 53073, 'An item appears more than once in the kit.', 1;
    IF EXISTS (SELECT 1 FROM @L l WHERE NOT EXISTS (SELECT 1 FROM dbo.InvItem i WHERE i.ItemId = l.ItemId AND i.CompanyId = @CompanyId AND i.IsDeleted = 0 AND i.Status = 1))
        THROW 53074, 'A kit item is not an active item of the Item Master.', 1;
    BEGIN TRANSACTION;
        UPDATE dbo.BomSampleKit SET IsActive = 0 WHERE SampleTypeId = @SampleTypeId AND CompanyId = @CompanyId AND IsActive = 1;
        INSERT INTO dbo.BomSampleKit (CompanyId, SampleTypeId, ItemId, Qty, CreatedBy) SELECT @CompanyId, @SampleTypeId, ItemId, Qty, @UserId FROM @L;
    COMMIT TRANSACTION;
END;
GO

-- 9. BOM cost preview: tests, profile tests and packages with material, kit, total cost and margin at the B2C rate --
CREATE OR ALTER PROCEDURE dbo.usp_Qc_CostPreview
    @CompanyId INT, @BranchId INT, @Kind VARCHAR(10) = NULL, @DepartmentId INT = NULL, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @Kind = NULLIF(@Kind, '');
    DECLARE @R TABLE (Kind VARCHAR(10), ItemId INT, Code NVARCHAR(50), Name NVARCHAR(300), DepartmentName NVARCHAR(150), Tests INT, MissingBom INT,
                      MaterialCost DECIMAL(14,2), KitCost DECIMAL(14,2), Rate DECIMAL(14,2));
    INSERT INTO @R
    SELECT CASE WHEN ISNULL(m.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END, m.Test_ID, m.Test_Code, m.Test_Name, d.DeptName, 1,
           CASE WHEN dbo.ufn_Qc_TestMaterialCost(m.Test_ID, NULL) IS NULL THEN 1 ELSE 0 END,
           dbo.ufn_Qc_TestMaterialCost(m.Test_ID, NULL), dbo.ufn_Qc_SampleKitCost(m.Sample_Type_ID), r.B2CRate
    FROM dbo.LabInvestigationMaster m
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = m.Department_ID
    OUTER APPLY (SELECT TOP 1 x.B2CRate FROM dbo.fn_LabBookableItems(@BranchId, 'B2C', NULL) x
                 WHERE x.Item_ID = m.Test_ID AND x.Item_Type = CASE WHEN ISNULL(m.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END) r
    WHERE ISNULL(m.IsDeleted, 0) = 0 AND m.Status = 1 AND (ISNULL(m.Is_Billable, 1) = 1 OR ISNULL(m.Is_Profile_Test, 0) = 1)
      AND (m.CompanyId = @CompanyId OR m.CompanyId IS NULL)
      AND (@DepartmentId IS NULL OR m.Department_ID = @DepartmentId);

    -- packages: the sum of their member tests, one kit per distinct sample type
    INSERT INTO @R
    SELECT 'Package', h.Profile_ID, h.Profile_Code, h.Profile_Name, 'Packages', COUNT(pd.Test_ID),
           SUM(CASE WHEN dbo.ufn_Qc_TestMaterialCost(pd.Test_ID, NULL) IS NULL THEN 1 ELSE 0 END),
           SUM(ISNULL(dbo.ufn_Qc_TestMaterialCost(pd.Test_ID, NULL), 0)),
           (SELECT SUM(ISNULL(dbo.ufn_Qc_SampleKitCost(s.Sample_Type_ID), 0)) FROM (SELECT DISTINCT m2.Sample_Type_ID FROM dbo.LabInvestigationProfileDetail p2
               INNER JOIN dbo.LabInvestigationMaster m2 ON m2.Test_ID = p2.Test_ID WHERE p2.Profile_ID = h.Profile_ID AND ISNULL(p2.IsDeleted, 0) = 0) s),
           (SELECT TOP 1 x.B2CRate FROM dbo.fn_LabBookableItems(@BranchId, 'B2C', NULL) x WHERE x.Item_ID = h.Profile_ID AND x.Item_Type = 'Package')
    FROM dbo.LabInvestigationProfileHeader h
    INNER JOIN dbo.LabInvestigationProfileDetail pd ON pd.Profile_ID = h.Profile_ID AND ISNULL(pd.IsDeleted, 0) = 0
    WHERE ISNULL(h.IsDeleted, 0) = 0 AND h.Status = 1 AND h.Profile_Type = 2   -- 2 = package; 1 = a profile test's parameter list (costed as its own test)
      AND (h.CompanyId = @CompanyId OR h.CompanyId IS NULL) AND @DepartmentId IS NULL
    GROUP BY h.Profile_ID, h.Profile_Code, h.Profile_Name;

    SELECT Kind, ItemId, Code, Name, DepartmentName, Tests, MissingBom, MaterialCost, KitCost,
           CAST(ISNULL(MaterialCost, 0) + ISNULL(KitCost, 0) AS DECIMAL(14,2)) AS TotalCost, Rate,
           CAST(CASE WHEN Rate IS NULL THEN NULL ELSE Rate - (ISNULL(MaterialCost, 0) + ISNULL(KitCost, 0)) END AS DECIMAL(14,2)) AS Margin,
           CAST(CASE WHEN ISNULL(Rate, 0) = 0 THEN NULL ELSE (Rate - (ISNULL(MaterialCost, 0) + ISNULL(KitCost, 0))) * 100.0 / Rate END AS DECIMAL(7,2)) AS MarginPct
    FROM @R
    WHERE (@Kind IS NULL OR Kind = @Kind) AND (@Search IS NULL OR Name LIKE '%' + @Search + '%' OR Code LIKE '%' + @Search + '%')
    ORDER BY CASE Kind WHEN 'Test' THEN 0 WHEN 'Profile' THEN 1 ELSE 2 END, DepartmentName, Name;
END;
GO

-- 10. Menu and pages -----------------------------------------------------------------------------------
DECLARE @co INT, @top INT, @mMast INT, @mBom INT, @page INT, @ctl INT, @code NVARCHAR(150), @title NVARCHAR(150), @ctrl NVARCHAR(100),
        @action NVARCHAR(100), @sort INT, @icon NVARCHAR(100), @menu NVARCHAR(30);
DECLARE @Pages TABLE (Menu NVARCHAR(30), Code NVARCHAR(150), Title NVARCHAR(150), Ctrl NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
 (N'MASTERS', N'QC.MASTER.ITEMS',      N'Item Master',           N'QcItems',      10, N'bi bi-box-seam me-2'),
 (N'MASTERS', N'QC.MASTER.SUPPLIERS',  N'Supplier Master',       N'QcSuppliers',  20, N'bi bi-truck me-2'),
 (N'MASTERS', N'QC.MASTER.STORES',     N'Store / Location',      N'QcStores',     30, N'bi bi-building me-2'),
 (N'BOM',     N'QC.BOM.TEST',          N'Test BOM',              N'QcBom',        10, N'bi bi-diagram-3 me-2'),
 (N'BOM',     N'QC.BOM.SAMPLEKIT',     N'Sample Collection Kit', N'QcSampleKits', 20, N'bi bi-droplet me-2'),
 (N'BOM',     N'QC.BOM.COSTPREVIEW',   N'BOM Cost Preview',      N'QcCostPreview',30, N'bi bi-calculator me-2');
-- controller actions and the control each needs
DECLARE @Ep TABLE (Ctrl NVARCHAR(100), Method VARCHAR(10), Action NVARCHAR(100), Code VARCHAR(30));
INSERT INTO @Ep VALUES
 (N'QcItems','GET',N'Index','VIEW'),(N'QcItems','GET',N'List','VIEW'),(N'QcItems','POST',N'Save','ADD'),(N'QcItems','POST',N'SetStatus','STATUS'),(N'QcItems','POST',N'Delete','DELETE'),
 (N'QcSuppliers','GET',N'Index','VIEW'),(N'QcSuppliers','GET',N'List','VIEW'),(N'QcSuppliers','POST',N'Save','ADD'),(N'QcSuppliers','POST',N'SetStatus','STATUS'),(N'QcSuppliers','POST',N'Delete','DELETE'),
 (N'QcStores','GET',N'Index','VIEW'),(N'QcStores','GET',N'List','VIEW'),(N'QcStores','POST',N'Save','ADD'),(N'QcStores','POST',N'SetStatus','STATUS'),(N'QcStores','POST',N'Delete','DELETE'),
 (N'QcBom','GET',N'Index','VIEW'),(N'QcBom','GET',N'List','VIEW'),(N'QcBom','GET',N'Get','VIEW'),(N'QcBom','GET',N'Items','VIEW'),(N'QcBom','POST',N'Save','EDIT'),(N'QcBom','POST',N'Remove','DELETE'),
 (N'QcSampleKits','GET',N'Index','VIEW'),(N'QcSampleKits','GET',N'List','VIEW'),(N'QcSampleKits','GET',N'Items','VIEW'),(N'QcSampleKits','POST',N'Save','EDIT'),
 (N'QcCostPreview','GET',N'Index','VIEW'),(N'QcCostPreview','GET',N'List','VIEW');
DECLARE @Controls TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES ('ADD', N'Add / edit', 20), ('EDIT', N'Edit', 30), ('STATUS', N'Activate / Deactivate', 40), ('DELETE', N'Delete', 50);

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = NULL, @Menu_Type = 'NAV', @Menu_Code = N'QUALITY',
         @Title = N'Quality & Compliance', @Icon = N'bi bi-patch-check-fill me-2', @Sort_Order = 75, @Menu_ID = @top OUTPUT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @top, @Menu_Type = 'MENU', @Menu_Code = N'QUALITY.MASTERS',
         @Title = N'Masters', @Icon = N'bi bi-database me-2', @Sort_Order = 10, @Menu_ID = @mMast OUTPUT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @top, @Menu_Type = 'MENU', @Menu_Code = N'QUALITY.BOM',
         @Title = N'Bill of Material', @Icon = N'bi bi-diagram-3 me-2', @Sort_Order = 20, @Menu_ID = @mBom OUTPUT;

    DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Menu, Code, Title, Ctrl, Sort, Icon FROM @Pages;
    OPEN pg; FETCH NEXT FROM pg INTO @menu, @code, @title, @ctrl, @sort, @icon;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @mid INT = CASE @menu WHEN N'MASTERS' THEN @mMast ELSE @mBom END;
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @mid, @Page_Code = @code, @Title = @title, @Controller = @ctrl, @Action = N'Index',
             @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Page_ID = @page OUTPUT;
        DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls;
        DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT;
        OPEN c1; FETCH NEXT FROM c1 INTO @cc, @ct, @cs;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
            FETCH NEXT FROM c1 INTO @cc, @ct, @cs;
        END
        CLOSE c1; DEALLOCATE c1;
        DECLARE e1 CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Action, Code FROM @Ep WHERE Ctrl = @ctrl;
        DECLARE @em VARCHAR(10), @ea NVARCHAR(100), @ec VARCHAR(30);
        OPEN e1; FETCH NEXT FROM e1 INTO @em, @ea, @ec;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ctl = NULL;
            SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @ec;
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @em,
                 @Controller = @ctrl, @Action = @ea, @Source = 'SEED';
            FETCH NEXT FROM e1 INTO @em, @ea, @ec;
        END
        CLOSE e1; DEALLOCATE e1;
        FETCH NEXT FROM pg INTO @menu, @code, @title, @ctrl, @sort, @icon;
    END
    CLOSE pg; DEALLOCATE pg;
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2247 applied: Quality & Compliance Phase 1 (masters, Test BOM, sample kits, BOM cost preview, menu).';
GO
