-- ============================================================
--  Geography Master Tables
--  Run this script against Dev_EMR to create all 5 tables
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CountryMaster')
CREATE TABLE CountryMaster (
    CountryId    INT IDENTITY(1,1) PRIMARY KEY,
    CountryCode  NVARCHAR(20)  NOT NULL,
    CountryName  NVARCHAR(100) NOT NULL,
    Currency     NVARCHAR(10)  NULL,
    IsActive     BIT           NOT NULL DEFAULT 1,
    CreatedBy    INT           NULL,
    CreatedDate  DATETIME      NOT NULL DEFAULT GETDATE(),
    ModifiedBy   INT           NULL,
    ModifiedDate DATETIME      NULL,
    CONSTRAINT UQ_CountryCode UNIQUE (CountryCode)
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'StateMaster')
CREATE TABLE StateMaster (
    StateId      INT IDENTITY(1,1) PRIMARY KEY,
    StateCode    NVARCHAR(20)  NOT NULL,
    StateName    NVARCHAR(100) NOT NULL,
    CountryId    INT           NOT NULL REFERENCES CountryMaster(CountryId),
    IsActive     BIT           NOT NULL DEFAULT 1,
    CreatedBy    INT           NULL,
    CreatedDate  DATETIME      NOT NULL DEFAULT GETDATE(),
    ModifiedBy   INT           NULL,
    ModifiedDate DATETIME      NULL,
    CONSTRAINT UQ_StateCode UNIQUE (StateCode)
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DistrictMaster')
CREATE TABLE DistrictMaster (
    DistrictId   INT IDENTITY(1,1) PRIMARY KEY,
    DistrictCode NVARCHAR(20)  NOT NULL,
    DistrictName NVARCHAR(100) NOT NULL,
    StateId      INT           NOT NULL REFERENCES StateMaster(StateId),
    IsActive     BIT           NOT NULL DEFAULT 1,
    CreatedBy    INT           NULL,
    CreatedDate  DATETIME      NOT NULL DEFAULT GETDATE(),
    ModifiedBy   INT           NULL,
    ModifiedDate DATETIME      NULL,
    CONSTRAINT UQ_DistrictCode UNIQUE (DistrictCode)
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CityMaster')
CREATE TABLE CityMaster (
    CityId       INT IDENTITY(1,1) PRIMARY KEY,
    CityCode     NVARCHAR(20)  NOT NULL,
    CityName     NVARCHAR(100) NOT NULL,
    DistrictId   INT           NOT NULL REFERENCES DistrictMaster(DistrictId),
    IsActive     BIT           NOT NULL DEFAULT 1,
    CreatedBy    INT           NULL,
    CreatedDate  DATETIME      NOT NULL DEFAULT GETDATE(),
    ModifiedBy   INT           NULL,
    ModifiedDate DATETIME      NULL,
    CONSTRAINT UQ_CityCode UNIQUE (CityCode)
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'AreaMaster')
CREATE TABLE AreaMaster (
    AreaId       INT IDENTITY(1,1) PRIMARY KEY,
    AreaCode     NVARCHAR(20)  NOT NULL,
    AreaName     NVARCHAR(100) NOT NULL,
    CityId       INT           NOT NULL REFERENCES CityMaster(CityId),
    IsActive     BIT           NOT NULL DEFAULT 1,
    CreatedBy    INT           NULL,
    CreatedDate  DATETIME      NOT NULL DEFAULT GETDATE(),
    ModifiedBy   INT           NULL,
    ModifiedDate DATETIME      NULL,
    CONSTRAINT UQ_AreaCode UNIQUE (AreaCode)
);

PRINT 'Geography master tables created successfully.';
