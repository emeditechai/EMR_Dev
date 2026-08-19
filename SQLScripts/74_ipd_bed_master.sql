-- ============================================================================
-- Script: 74_ipd_bed_master.sql
-- Description: Create BedMaster for IPD Module with Building, Ward, Room, and Category hierarchy
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_NAME = 'BedMaster'
)
BEGIN
    CREATE TABLE dbo.BedMaster (
        BedId               INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId           INT           NOT NULL CONSTRAINT DF_BedMaster_CompanyId DEFAULT(1),
        BranchId            INT           NULL,
        BuildingId          INT           NOT NULL,
        WardId              INT           NOT NULL,
        RoomId              INT           NOT NULL,
        BedNumber           NVARCHAR(50)  NOT NULL,
        BedCategoryId       INT           NOT NULL,
        BedStatus           NVARCHAR(30)  NOT NULL CONSTRAINT DF_BedMaster_BedStatus DEFAULT('Available'),
        IsIsolation         BIT           NOT NULL CONSTRAINT DF_BedMaster_IsIsolation DEFAULT(0),
        IsICU               BIT           NOT NULL CONSTRAINT DF_BedMaster_IsICU DEFAULT(0),
        IsVentilatorCapable BIT           NOT NULL CONSTRAINT DF_BedMaster_IsVentilator DEFAULT(0),
        Description         NVARCHAR(500) NULL,
        IsActive            BIT           NOT NULL CONSTRAINT DF_BedMaster_IsActive DEFAULT(1),
        CreatedBy           INT           NULL,
        CreatedDate         DATETIME2     NOT NULL CONSTRAINT DF_BedMaster_CreatedDate DEFAULT(GETDATE()),
        ModifiedBy          INT           NULL,
        ModifiedDate        DATETIME2     NULL,
        CONSTRAINT FK_BedMaster_Building 
            FOREIGN KEY (BuildingId) REFERENCES dbo.BuildingMaster(BuildingId),
        CONSTRAINT FK_BedMaster_Ward 
            FOREIGN KEY (WardId) REFERENCES dbo.WardMaster(WardId),
        CONSTRAINT FK_BedMaster_Room 
            FOREIGN KEY (RoomId) REFERENCES dbo.RoomMaster(RoomId),
        CONSTRAINT FK_BedMaster_BedCategory 
            FOREIGN KEY (BedCategoryId) REFERENCES dbo.BedCategoryMaster(BedCategoryId),
        CONSTRAINT FK_BedMaster_Company 
            FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId),
        CONSTRAINT UQ_BedMaster_Company_BedNumber 
            UNIQUE (CompanyId, BedNumber)
    );

    CREATE INDEX IX_BedMaster_BuildingId ON dbo.BedMaster(BuildingId);
    CREATE INDEX IX_BedMaster_WardId ON dbo.BedMaster(WardId);
    CREATE INDEX IX_BedMaster_RoomId ON dbo.BedMaster(RoomId);
    CREATE INDEX IX_BedMaster_BedCategoryId ON dbo.BedMaster(BedCategoryId);
    CREATE INDEX IX_BedMaster_BedStatus ON dbo.BedMaster(BedStatus);
    CREATE INDEX IX_BedMaster_CompanyId ON dbo.BedMaster(CompanyId);
    CREATE INDEX IX_BedMaster_BranchId ON dbo.BedMaster(BranchId);

    PRINT 'BedMaster table created.';
END
ELSE
BEGIN
    PRINT 'BedMaster table already exists.';
END
GO

-- Seed sample Beds for existing seeded Rooms
IF NOT EXISTS (SELECT 1 FROM dbo.BedMaster)
BEGIN
    DECLARE @Bld1 INT = (SELECT TOP 1 BuildingId FROM dbo.BuildingMaster WHERE BuildingCode = 'MAIN' OR BuildingName LIKE '%Main%');
    IF @Bld1 IS NULL SET @Bld1 = (SELECT TOP 1 BuildingId FROM dbo.BuildingMaster ORDER BY BuildingId);

    DECLARE @WardGwA INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'GW001');
    DECLARE @WardGwB INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'GW002');
    DECLARE @WardIcu INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'ICU01');
    DECLARE @WardMatn INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'MW001');

    IF @WardGwA IS NULL SET @WardGwA = (SELECT TOP 1 WardId FROM dbo.WardMaster);
    IF @WardGwB IS NULL SET @WardGwB = @WardGwA;
    IF @WardIcu IS NULL SET @WardIcu = @WardGwA;
    IF @WardMatn IS NULL SET @WardMatn = @WardGwA;

    DECLARE @Room101A INT = (SELECT TOP 1 RoomId FROM dbo.RoomMaster WHERE RoomNumber = '101-A');
    DECLARE @Room102B INT = (SELECT TOP 1 RoomId FROM dbo.RoomMaster WHERE RoomNumber = '102-B');
    DECLARE @Room105A INT = (SELECT TOP 1 RoomId FROM dbo.RoomMaster WHERE RoomNumber = '105-A');
    DECLARE @Room201Iso INT = (SELECT TOP 1 RoomId FROM dbo.RoomMaster WHERE RoomNumber = '201-ISO');
    DECLARE @Room001Dlx INT = (SELECT TOP 1 RoomId FROM dbo.RoomMaster WHERE RoomNumber = '001-DLX');

    IF @Room101A IS NULL SET @Room101A = (SELECT TOP 1 RoomId FROM dbo.RoomMaster);
    IF @Room102B IS NULL SET @Room102B = @Room101A;
    IF @Room105A IS NULL SET @Room105A = @Room101A;
    IF @Room201Iso IS NULL SET @Room201Iso = @Room101A;
    IF @Room001Dlx IS NULL SET @Room001Dlx = @Room101A;

    DECLARE @CatGen INT = (SELECT TOP 1 BedCategoryId FROM dbo.BedCategoryMaster WHERE CategoryName = 'General' OR CategoryCode = 'GEN');
    DECLARE @CatSemi INT = (SELECT TOP 1 BedCategoryId FROM dbo.BedCategoryMaster WHERE CategoryName LIKE '%Semi%' OR CategoryCode = 'SPRV');
    DECLARE @CatPriv INT = (SELECT TOP 1 BedCategoryId FROM dbo.BedCategoryMaster WHERE CategoryName = 'Private' OR CategoryCode = 'PRV');
    DECLARE @CatIcu INT = (SELECT TOP 1 BedCategoryId FROM dbo.BedCategoryMaster WHERE CategoryName = 'ICU' OR CategoryCode = 'ICU');
    DECLARE @CatDlx INT = (SELECT TOP 1 BedCategoryId FROM dbo.BedCategoryMaster WHERE CategoryName = 'Deluxe' OR CategoryCode = 'DLX');

    IF @CatGen IS NULL SET @CatGen = (SELECT TOP 1 BedCategoryId FROM dbo.BedCategoryMaster);
    IF @CatSemi IS NULL SET @CatSemi = @CatGen;
    IF @CatPriv IS NULL SET @CatPriv = @CatGen;
    IF @CatIcu IS NULL SET @CatIcu = @CatGen;
    IF @CatDlx IS NULL SET @CatDlx = @CatGen;

    INSERT INTO dbo.BedMaster (
        CompanyId, BranchId, BuildingId, WardId, RoomId, BedNumber, BedCategoryId, BedStatus,
        IsIsolation, IsICU, IsVentilatorCapable, Description, IsActive, CreatedDate
    ) VALUES
    (1, 1, @Bld1, @WardGwA, @Room101A, 'BED-101-A1', @CatGen, 'Available', 0, 0, 0, 'General standard multi-function hospital bed with central oxygen', 1, GETDATE()),
    (1, 1, @Bld1, @WardGwA, @Room101A, 'BED-101-A2', @CatGen, 'Occupied',  0, 0, 0, 'General standard multi-function hospital bed with central oxygen', 1, GETDATE()),
    (1, 1, @Bld1, @WardGwA, @Room102B, 'BED-102-B1', @CatSemi, 'Available', 0, 0, 0, 'Semi-private electric Fowler bed with bedside cardiac monitor', 1, GETDATE()),
    (1, 1, @Bld1, @WardGwB, @Room105A, 'BED-105-A1', @CatPriv, 'Reserved',  0, 0, 0, 'Private suite motorized 5-function ICU-grade bed', 1, GETDATE()),
    (1, 1, @Bld1, @WardIcu, @Room201Iso, 'BED-ICU-01', @CatIcu, 'Available', 1, 1, 1, 'Critical Care ICU bed equipped with invasive ventilator pipeline and multiparameter monitor', 1, GETDATE()),
    (1, 1, @Bld1, @WardMatn, @Room001Dlx, 'BED-MAT-01', @CatDlx, 'Cleaning',  0, 0, 0, 'Deluxe motorized birthing/postpartum bed', 1, GETDATE());

    PRINT 'BedMaster seeded successfully.';
END
GO
