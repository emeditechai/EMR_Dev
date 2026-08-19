-- ============================================================================
-- Script: 71_ipd_ward_nursing_station_master.sql
-- Description: Create WardMaster and NursingStationMaster for IPD Module
-- ============================================================================

-- 1. Create WardMaster Table
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_NAME = 'WardMaster'
)
BEGIN
    CREATE TABLE dbo.WardMaster (
        WardId          INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId       INT           NOT NULL CONSTRAINT DF_WardMaster_CompanyId DEFAULT(1),
        BranchId        INT           NULL,
        FloorId         INT           NOT NULL,
        DepartmentId    INT           NOT NULL,
        WardCode        NVARCHAR(5)   NOT NULL,
        WardName        NVARCHAR(150) NOT NULL,
        WardType        NVARCHAR(50)  NOT NULL,
        Gender          NVARCHAR(20)  NOT NULL CONSTRAINT DF_WardMaster_Gender DEFAULT('Unisex / All'),
        Capacity        INT           NOT NULL CONSTRAINT DF_WardMaster_Capacity DEFAULT(1),
        IsIsolationWard BIT           NOT NULL CONSTRAINT DF_WardMaster_IsIsolation DEFAULT(0),
        Description     NVARCHAR(500) NULL,
        IsActive        BIT           NOT NULL CONSTRAINT DF_WardMaster_IsActive DEFAULT(1),
        CreatedBy       INT           NULL,
        CreatedDate     DATETIME2     NOT NULL CONSTRAINT DF_WardMaster_CreatedDate DEFAULT(GETDATE()),
        ModifiedBy      INT           NULL,
        ModifiedDate    DATETIME2     NULL,
        CONSTRAINT FK_WardMaster_Floor 
            FOREIGN KEY (FloorId) REFERENCES dbo.FloorMaster(FloorId),
        CONSTRAINT FK_WardMaster_Department 
            FOREIGN KEY (DepartmentId) REFERENCES dbo.DepartmentMaster(DeptId),
        CONSTRAINT FK_WardMaster_Company 
            FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId),
        CONSTRAINT UQ_WardMaster_Code 
            UNIQUE (CompanyId, WardCode)
    );

    CREATE INDEX IX_WardMaster_FloorId ON dbo.WardMaster(FloorId);
    CREATE INDEX IX_WardMaster_DepartmentId ON dbo.WardMaster(DepartmentId);
    CREATE INDEX IX_WardMaster_CompanyId ON dbo.WardMaster(CompanyId);
    CREATE INDEX IX_WardMaster_BranchId ON dbo.WardMaster(BranchId);

    PRINT 'WardMaster table created.';
END
ELSE
BEGIN
    PRINT 'WardMaster table already exists.';
END
GO

-- 2. Create NursingStationMaster Table
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_NAME = 'NursingStationMaster'
)
BEGIN
    CREATE TABLE dbo.NursingStationMaster (
        NursingStationId INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId        INT           NOT NULL CONSTRAINT DF_NursingStationMaster_CompanyId DEFAULT(1),
        BranchId         INT           NULL,
        WardId           INT           NOT NULL,
        StationCode      NVARCHAR(50)  NOT NULL,
        StationName      NVARCHAR(150) NOT NULL,
        ResponsibleNurse NVARCHAR(150) NULL,
        Description      NVARCHAR(500) NULL,
        IsActive         BIT           NOT NULL CONSTRAINT DF_NursingStationMaster_IsActive DEFAULT(1),
        CreatedBy        INT           NULL,
        CreatedDate      DATETIME2     NOT NULL CONSTRAINT DF_NursingStationMaster_CreatedDate DEFAULT(GETDATE()),
        ModifiedBy       INT           NULL,
        ModifiedDate     DATETIME2     NULL,
        CONSTRAINT FK_NursingStationMaster_Ward 
            FOREIGN KEY (WardId) REFERENCES dbo.WardMaster(WardId) ON DELETE CASCADE,
        CONSTRAINT FK_NursingStationMaster_Company 
            FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId),
        CONSTRAINT UQ_NursingStationMaster_Code 
            UNIQUE (CompanyId, StationCode)
    );

    CREATE INDEX IX_NursingStationMaster_WardId ON dbo.NursingStationMaster(WardId);
    CREATE INDEX IX_NursingStationMaster_CompanyId ON dbo.NursingStationMaster(CompanyId);
    CREATE INDEX IX_NursingStationMaster_BranchId ON dbo.NursingStationMaster(BranchId);

    PRINT 'NursingStationMaster table created.';
END
ELSE
BEGIN
    PRINT 'NursingStationMaster table already exists.';
END
GO

-- Seed sample Wards and Nursing Stations
IF NOT EXISTS (SELECT 1 FROM dbo.WardMaster)
BEGIN
    DECLARE @Floor1 INT = (SELECT TOP 1 FloorId FROM dbo.FloorMaster WHERE FloorCode = 'F1' OR FloorName LIKE '%First%');
    DECLARE @FloorG INT = (SELECT TOP 1 FloorId FROM dbo.FloorMaster WHERE FloorCode = 'GF' OR FloorName LIKE '%Ground%');
    DECLARE @Floor2 INT = (SELECT TOP 1 FloorId FROM dbo.FloorMaster WHERE FloorCode = 'F2' OR FloorName LIKE '%Second%');
    IF @Floor1 IS NULL SET @Floor1 = (SELECT TOP 1 FloorId FROM dbo.FloorMaster ORDER BY FloorId);
    IF @FloorG IS NULL SET @FloorG = @Floor1;
    IF @Floor2 IS NULL SET @Floor2 = @Floor1;

    DECLARE @DeptGenIpd INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptType = 'IPD' AND DeptCode LIKE '%GEN%');
    DECLARE @DeptIcu INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptType = 'IPD' AND DeptCode LIKE '%ICU%');
    DECLARE @DeptSurg INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptType = 'IPD' AND DeptCode LIKE '%SURG%');
    DECLARE @DeptMatn INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptType = 'IPD' AND DeptCode LIKE '%MATN%');

    IF @DeptGenIpd IS NULL SET @DeptGenIpd = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptType = 'IPD');
    IF @DeptIcu IS NULL SET @DeptIcu = @DeptGenIpd;
    IF @DeptSurg IS NULL SET @DeptSurg = @DeptGenIpd;
    IF @DeptMatn IS NULL SET @DeptMatn = @DeptGenIpd;

    INSERT INTO dbo.WardMaster (
        CompanyId, BranchId, FloorId, DepartmentId, WardCode, WardName, WardType, Gender, Capacity, IsIsolationWard, Description, IsActive, CreatedDate
    ) VALUES
    (1, 1, @Floor1, @DeptGenIpd, 'GW001', 'General Medical Ward A', 'General Ward', 'Male', 20, 0, 'Male inpatient acute medical care unit', 1, GETDATE()),
    (1, 1, @Floor1, @DeptGenIpd, 'GW002', 'General Medical Ward B', 'General Ward', 'Female', 20, 0, 'Female inpatient acute medical care unit', 1, GETDATE()),
    (1, 1, @Floor2, @DeptIcu,    'ICU01', 'Main Intensive Care Unit', 'ICU (Intensive Care)', 'Unisex / All', 12, 1, 'Critical care monitoring unit equipped with negative pressure pods', 1, GETDATE()),
    (1, 1, @Floor2, @DeptSurg,   'SW001', 'Post-Surgical Ward', 'Post-Operative Recovery', 'Unisex / All', 16, 0, 'Step-down recovery and post-op rehabilitation', 1, GETDATE()),
    (1, 1, @FloorG, @DeptMatn,   'MW001', 'Maternity Care Ward', 'Deluxe Ward', 'Female', 10, 0, 'Labor, delivery, and postpartum inpatient suites', 1, GETDATE());

    PRINT 'WardMaster seeded successfully.';
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.NursingStationMaster)
BEGIN
    DECLARE @WardGwA INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'GW001');
    DECLARE @WardIcu INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'ICU01');
    DECLARE @WardSurg INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'SW001');

    IF @WardGwA IS NOT NULL
    BEGIN
        INSERT INTO dbo.NursingStationMaster (CompanyId, BranchId, WardId, StationCode, StationName, ResponsibleNurse, Description, IsActive, CreatedDate) VALUES
        (1, 1, @WardGwA, 'NS-GW1', 'Nursing Station 1 - Med Ward A', 'Sr. Nurse Priya Sharma', 'Main nursing counter for General Medical Ward A', 1, GETDATE());
    END

    IF @WardIcu IS NOT NULL
    BEGIN
        INSERT INTO dbo.NursingStationMaster (CompanyId, BranchId, WardId, StationCode, StationName, ResponsibleNurse, Description, IsActive, CreatedDate) VALUES
        (1, 1, @WardIcu, 'NS-ICU', 'ICU Central Nursing Command', 'Sr. Nurse Anjali Menon', 'Central telemetry and vital monitoring nursing desk', 1, GETDATE());
    END

    IF @WardSurg IS NOT NULL
    BEGIN
        INSERT INTO dbo.NursingStationMaster (CompanyId, BranchId, WardId, StationCode, StationName, ResponsibleNurse, Description, IsActive, CreatedDate) VALUES
        (1, 1, @WardSurg, 'NS-SW1', 'Surgical Ward Nurse Station', 'Nurse Sunita Paul', 'Post-surgical round & medication distribution station', 1, GETDATE());
    END

    PRINT 'NursingStationMaster seeded successfully.';
END
GO
