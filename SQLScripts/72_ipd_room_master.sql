-- ============================================================================
-- Script: 72_ipd_room_master.sql
-- Description: Create RoomMaster for IPD Module with Building, Floor, and Ward hierarchy
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_NAME = 'RoomMaster'
)
BEGIN
    CREATE TABLE dbo.RoomMaster (
        RoomId        INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId     INT           NOT NULL CONSTRAINT DF_RoomMaster_CompanyId DEFAULT(1),
        BranchId      INT           NULL,
        BuildingId    INT           NOT NULL,
        FloorId       INT           NOT NULL,
        WardId        INT           NOT NULL,
        RoomNumber    NVARCHAR(50)  NOT NULL,
        RoomType      NVARCHAR(50)  NOT NULL,
        RoomCategory  NVARCHAR(50)  NOT NULL,
        IsIsolation   BIT           NOT NULL CONSTRAINT DF_RoomMaster_IsIsolation DEFAULT(0),
        BedCapacity   INT           NOT NULL CONSTRAINT DF_RoomMaster_BedCapacity DEFAULT(1),
        Description   NVARCHAR(500) NULL,
        IsActive      BIT           NOT NULL CONSTRAINT DF_RoomMaster_IsActive DEFAULT(1),
        CreatedBy     INT           NULL,
        CreatedDate   DATETIME2     NOT NULL CONSTRAINT DF_RoomMaster_CreatedDate DEFAULT(GETDATE()),
        ModifiedBy    INT           NULL,
        ModifiedDate  DATETIME2     NULL,
        CONSTRAINT FK_RoomMaster_Building 
            FOREIGN KEY (BuildingId) REFERENCES dbo.BuildingMaster(BuildingId),
        CONSTRAINT FK_RoomMaster_Floor 
            FOREIGN KEY (FloorId) REFERENCES dbo.FloorMaster(FloorId),
        CONSTRAINT FK_RoomMaster_Ward 
            FOREIGN KEY (WardId) REFERENCES dbo.WardMaster(WardId),
        CONSTRAINT FK_RoomMaster_Company 
            FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId),
        CONSTRAINT UQ_RoomMaster_Company_RoomNumber 
            UNIQUE (CompanyId, RoomNumber)
    );

    CREATE INDEX IX_RoomMaster_BuildingId ON dbo.RoomMaster(BuildingId);
    CREATE INDEX IX_RoomMaster_FloorId ON dbo.RoomMaster(FloorId);
    CREATE INDEX IX_RoomMaster_WardId ON dbo.RoomMaster(WardId);
    CREATE INDEX IX_RoomMaster_CompanyId ON dbo.RoomMaster(CompanyId);
    CREATE INDEX IX_RoomMaster_BranchId ON dbo.RoomMaster(BranchId);

    PRINT 'RoomMaster table created.';
END
ELSE
BEGIN
    PRINT 'RoomMaster table already exists.';
END
GO

-- Seed sample Rooms for existing Wards
IF NOT EXISTS (SELECT 1 FROM dbo.RoomMaster)
BEGIN
    DECLARE @Bld1 INT = (SELECT TOP 1 BuildingId FROM dbo.BuildingMaster WHERE BuildingCode = 'MAIN' OR BuildingName LIKE '%Main%');
    IF @Bld1 IS NULL SET @Bld1 = (SELECT TOP 1 BuildingId FROM dbo.BuildingMaster ORDER BY BuildingId);

    DECLARE @Floor1 INT = (SELECT TOP 1 FloorId FROM dbo.FloorMaster WHERE FloorCode = 'F1' OR FloorName LIKE '%First%');
    DECLARE @FloorG INT = (SELECT TOP 1 FloorId FROM dbo.FloorMaster WHERE FloorCode = 'GF' OR FloorName LIKE '%Ground%');
    DECLARE @Floor2 INT = (SELECT TOP 1 FloorId FROM dbo.FloorMaster WHERE FloorCode = 'F2' OR FloorName LIKE '%Second%');
    IF @Floor1 IS NULL SET @Floor1 = (SELECT TOP 1 FloorId FROM dbo.FloorMaster ORDER BY FloorId);
    IF @FloorG IS NULL SET @FloorG = @Floor1;
    IF @Floor2 IS NULL SET @Floor2 = @Floor1;

    DECLARE @WardGwA INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'GW001');
    DECLARE @WardGwB INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'GW002');
    DECLARE @WardIcu INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'ICU01');
    DECLARE @WardMatn INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'MW001');

    IF @WardGwA IS NULL SET @WardGwA = (SELECT TOP 1 WardId FROM dbo.WardMaster);
    IF @WardGwB IS NULL SET @WardGwB = @WardGwA;
    IF @WardIcu IS NULL SET @WardIcu = @WardGwA;
    IF @WardMatn IS NULL SET @WardMatn = @WardGwA;

    INSERT INTO dbo.RoomMaster (
        CompanyId, BranchId, BuildingId, FloorId, WardId, RoomNumber, RoomType, RoomCategory, IsIsolation, BedCapacity, Description, IsActive, CreatedDate
    ) VALUES
    (1, 1, @Bld1, @Floor1, @WardGwA, '101-A', 'Four Bedded Room', 'General', 0, 4, 'Male general medical room with oxygen supply', 1, GETDATE()),
    (1, 1, @Bld1, @Floor1, @WardGwA, '102-B', 'Double Sharing Room', 'Semi-Private', 0, 2, 'Semi-private twin sharing room with attached washroom', 1, GETDATE()),
    (1, 1, @Bld1, @Floor1, @WardGwB, '105-A', 'Single Room', 'Private', 0, 1, 'Private single occupancy room with electric recliner bed and TV', 1, GETDATE()),
    (1, 1, @Bld1, @Floor2, @WardIcu, '201-ISO', 'ICU Isolation Room', 'Isolation / Negative Pressure', 1, 1, 'Negative pressure airborne infection isolation room with dedicated HEPA filtration', 1, GETDATE()),
    (1, 1, @Bld1, @FloorG, @WardMatn, '001-DLX', 'Suite Room', 'Deluxe', 0, 1, 'Deluxe maternity suite with attendant sofa-cum-bed and kitchenette', 1, GETDATE());

    PRINT 'RoomMaster seeded successfully.';
END
GO
