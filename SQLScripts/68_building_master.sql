-- ============================================================================
-- Script: 68_building_master.sql
-- Description: Create BuildingMaster table and link FloorMaster to BuildingMaster
-- ============================================================================

-- 1. Create BuildingMaster Table
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_NAME = 'BuildingMaster'
)
BEGIN
    CREATE TABLE dbo.BuildingMaster (
        BuildingId       INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId        INT           NOT NULL CONSTRAINT DF_BuildingMaster_CompanyId DEFAULT(1),
        BranchId         INT           NULL,
        BuildingCode     NVARCHAR(4)   NOT NULL,
        BuildingName     NVARCHAR(150) NOT NULL,
        Description      NVARCHAR(500) NULL,
        NumberOfFloors   INT           NOT NULL CONSTRAINT DF_BuildingMaster_NumberOfFloors DEFAULT(1),
        IsActive         BIT           NOT NULL CONSTRAINT DF_BuildingMaster_IsActive DEFAULT(1),
        CreatedBy        INT           NULL,
        CreatedDate      DATETIME2     NOT NULL CONSTRAINT DF_BuildingMaster_CreatedDate DEFAULT(GETDATE()),
        ModifiedBy       INT           NULL,
        ModifiedDate     DATETIME2     NULL,
        CONSTRAINT UQ_BuildingMaster_Code UNIQUE (CompanyId, BuildingCode)
    );

    CREATE INDEX IX_BuildingMaster_CompanyId ON dbo.BuildingMaster(CompanyId);
    CREATE INDEX IX_BuildingMaster_BranchId ON dbo.BuildingMaster(BranchId);

    PRINT 'BuildingMaster table created.';
END
ELSE
BEGIN
    PRINT 'BuildingMaster table already exists — checking columns.';
END
GO

-- 2. Seed Default Building if empty
IF NOT EXISTS (SELECT 1 FROM dbo.BuildingMaster WHERE BuildingId = 1)
BEGIN
    SET IDENTITY_INSERT dbo.BuildingMaster ON;
    INSERT INTO dbo.BuildingMaster (
        BuildingId, CompanyId, BranchId, BuildingCode, BuildingName, Description, NumberOfFloors, IsActive, CreatedDate
    ) VALUES (
        1, 1, 1, 'MAIN', 'Main Hospital Block', 'Primary clinical and OPD multi-story complex', 4, 1, GETDATE()
    );
    SET IDENTITY_INSERT dbo.BuildingMaster OFF;

    PRINT 'BuildingMaster seeded with default building (MAIN).';
END
GO

-- 3. Add BuildingId to FloorMaster
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'FloorMaster' AND COLUMN_NAME = 'BuildingId'
)
BEGIN
    ALTER TABLE dbo.FloorMaster ADD BuildingId INT NULL;
    PRINT 'Added BuildingId to FloorMaster.';
END
GO

-- 4. Backfill existing FloorMaster records with BuildingId = 1
UPDATE dbo.FloorMaster
SET BuildingId = 1
WHERE BuildingId IS NULL OR BuildingId = 0;
GO

-- 5. Add Foreign Key and Index from FloorMaster to BuildingMaster
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys 
    WHERE name = 'FK_FloorMaster_BuildingMaster' AND parent_object_id = OBJECT_ID('dbo.FloorMaster')
)
BEGIN
    ALTER TABLE dbo.FloorMaster 
    ADD CONSTRAINT FK_FloorMaster_BuildingMaster FOREIGN KEY (BuildingId) REFERENCES dbo.BuildingMaster(BuildingId);
    PRINT 'Added FK_FloorMaster_BuildingMaster.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes 
    WHERE name = 'IX_FloorMaster_BuildingId' AND object_id = OBJECT_ID('dbo.FloorMaster')
)
BEGIN
    CREATE INDEX IX_FloorMaster_BuildingId ON dbo.FloorMaster(BuildingId);
    PRINT 'Added index IX_FloorMaster_BuildingId.';
END
GO
