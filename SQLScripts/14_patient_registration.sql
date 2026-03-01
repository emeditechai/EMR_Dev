-- =============================================================================
-- Script : 14_patient_registration.sql
-- Purpose: Create master tables (Religion, IdentificationType, Occupation,
--          MaritalStatus) and the PatientMaster table with a PatientCode
--          sequence.  Safe to re-run (uses IF NOT EXISTS guards).
-- =============================================================================

-- ─── Religion Master ─────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.ReligionMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReligionMaster
    (
        ReligionId      INT IDENTITY(1,1)  PRIMARY KEY,
        ReligionName    NVARCHAR(100)      NOT NULL,
        IsActive        BIT                NOT NULL CONSTRAINT DF_ReligionMaster_IsActive    DEFAULT 1,
        CreatedBy       INT                NULL,
        CreatedDate     DATETIME2          NOT NULL CONSTRAINT DF_ReligionMaster_CreatedDate DEFAULT SYSUTCDATETIME(),
        ModifiedBy      INT                NULL,
        ModifiedDate    DATETIME2          NULL
    );
    PRINT 'Created table: ReligionMaster';
END
GO

-- Seed religion data
IF NOT EXISTS (SELECT 1 FROM dbo.ReligionMaster WHERE ReligionName = 'Hindu')
BEGIN
    INSERT INTO dbo.ReligionMaster (ReligionName) VALUES
        ('Hindu'),
        ('Muslim'),
        ('Christian'),
        ('Sikh'),
        ('Buddhist'),
        ('Jain'),
        ('Parsi'),
        ('Other');
    PRINT 'Seeded: ReligionMaster';
END
GO

-- ─── Identification Type Master ──────────────────────────────────────────────
IF OBJECT_ID('dbo.IdentificationTypeMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IdentificationTypeMaster
    (
        IdentificationTypeId    INT IDENTITY(1,1)  PRIMARY KEY,
        IdentificationTypeName  NVARCHAR(100)      NOT NULL,
        IsActive                BIT                NOT NULL CONSTRAINT DF_IdTypeMaster_IsActive    DEFAULT 1,
        CreatedBy               INT                NULL,
        CreatedDate             DATETIME2          NOT NULL CONSTRAINT DF_IdTypeMaster_CreatedDate DEFAULT SYSUTCDATETIME(),
        ModifiedBy              INT                NULL,
        ModifiedDate            DATETIME2          NULL
    );
    PRINT 'Created table: IdentificationTypeMaster';
END
GO

-- Seed identification types
IF NOT EXISTS (SELECT 1 FROM dbo.IdentificationTypeMaster WHERE IdentificationTypeName = 'Aadhaar Card')
BEGIN
    INSERT INTO dbo.IdentificationTypeMaster (IdentificationTypeName) VALUES
        ('Aadhaar Card'),
        ('PAN Card'),
        ('Voter ID Card'),
        ('Passport'),
        ('Driving Licence'),
        ('Ration Card'),
        ('Other');
    PRINT 'Seeded: IdentificationTypeMaster';
END
GO

-- ─── Occupation Master ───────────────────────────────────────────────────────
IF OBJECT_ID('dbo.OccupationMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.OccupationMaster
    (
        OccupationId    INT IDENTITY(1,1)  PRIMARY KEY,
        OccupationName  NVARCHAR(100)      NOT NULL,
        IsActive        BIT                NOT NULL CONSTRAINT DF_OccupationMaster_IsActive    DEFAULT 1,
        CreatedBy       INT                NULL,
        CreatedDate     DATETIME2          NOT NULL CONSTRAINT DF_OccupationMaster_CreatedDate DEFAULT SYSUTCDATETIME(),
        ModifiedBy      INT                NULL,
        ModifiedDate    DATETIME2          NULL
    );
    PRINT 'Created table: OccupationMaster';
END
GO

-- Seed occupation data
IF NOT EXISTS (SELECT 1 FROM dbo.OccupationMaster WHERE OccupationName = 'Service')
BEGIN
    INSERT INTO dbo.OccupationMaster (OccupationName) VALUES
        ('Service'),
        ('Business'),
        ('Self Employed'),
        ('Farmer'),
        ('Student'),
        ('Homemaker'),
        ('Retired'),
        ('Labour'),
        ('Government Employee'),
        ('Professional'),
        ('Other');
    PRINT 'Seeded: OccupationMaster';
END
GO

-- ─── Marital Status Master ───────────────────────────────────────────────────
IF OBJECT_ID('dbo.MaritalStatusMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MaritalStatusMaster
    (
        MaritalStatusId INT IDENTITY(1,1)  PRIMARY KEY,
        StatusName      NVARCHAR(50)       NOT NULL,
        IsActive        BIT                NOT NULL CONSTRAINT DF_MaritalStatusMaster_IsActive    DEFAULT 1,
        CreatedBy       INT                NULL,
        CreatedDate     DATETIME2          NOT NULL CONSTRAINT DF_MaritalStatusMaster_CreatedDate DEFAULT SYSUTCDATETIME(),
        ModifiedBy      INT                NULL,
        ModifiedDate    DATETIME2          NULL
    );
    PRINT 'Created table: MaritalStatusMaster';
END
GO

-- Seed marital status
IF NOT EXISTS (SELECT 1 FROM dbo.MaritalStatusMaster WHERE StatusName = 'Single')
BEGIN
    INSERT INTO dbo.MaritalStatusMaster (StatusName) VALUES
        ('Single'),
        ('Married'),
        ('Divorced'),
        ('Widowed'),
        ('Separated'),
        ('Other');
    PRINT 'Seeded: MaritalStatusMaster';
END
GO

-- ─── Patient Master ──────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PatientMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PatientMaster
    (
        PatientId               INT IDENTITY(1,1)   PRIMARY KEY,
        PatientCode             NVARCHAR(20)         NOT NULL,
        PhoneNumber             NVARCHAR(15)         NOT NULL,
        SecondaryPhoneNumber    NVARCHAR(15)         NULL,
        Salutation              NVARCHAR(10)         NULL,
        FirstName               NVARCHAR(100)        NOT NULL,
        MiddleName              NVARCHAR(100)        NULL,
        LastName                NVARCHAR(100)        NOT NULL,
        Gender                  NVARCHAR(10)         NOT NULL,
        ReligionId              INT                  NULL,
        EmailId                 NVARCHAR(150)        NULL,
        GuardianName            NVARCHAR(200)        NULL,
        CountryId               INT                  NULL,
        StateId                 INT                  NULL,
        DistrictId              INT                  NULL,
        CityId                  INT                  NULL,
        AreaId                  INT                  NULL,
        IdentificationTypeId    INT                  NULL,
        IdentificationNumber    NVARCHAR(100)        NULL,
        IdentificationFilePath  NVARCHAR(500)        NULL,
        OccupationId            INT                  NULL,
        MaritalStatusId         INT                  NULL,
        BloodGroup              NVARCHAR(10)         NULL,
        KnownAllergies          NVARCHAR(500)        NULL,
        Remarks                 NVARCHAR(1000)       NULL,
        ConsultingDoctorId      INT                  NULL,
        ServiceType             NVARCHAR(20)         NULL,
        ServiceId               INT                  NULL,
        BranchId                INT                  NULL,
        IsActive                BIT NOT NULL         CONSTRAINT DF_PatientMaster_IsActive    DEFAULT 1,
        CreatedBy               INT                  NULL,
        CreatedDate             DATETIME2 NOT NULL   CONSTRAINT DF_PatientMaster_CreatedDate DEFAULT SYSUTCDATETIME(),
        ModifiedBy              INT                  NULL,
        ModifiedDate            DATETIME2            NULL,

        CONSTRAINT UQ_PatientMaster_PatientCode UNIQUE (PatientCode),
        CONSTRAINT FK_PatientMaster_Religion
            FOREIGN KEY (ReligionId)           REFERENCES dbo.ReligionMaster(ReligionId),
        CONSTRAINT FK_PatientMaster_IdType
            FOREIGN KEY (IdentificationTypeId) REFERENCES dbo.IdentificationTypeMaster(IdentificationTypeId),
        CONSTRAINT FK_PatientMaster_Occupation
            FOREIGN KEY (OccupationId)         REFERENCES dbo.OccupationMaster(OccupationId),
        CONSTRAINT FK_PatientMaster_MaritalStatus
            FOREIGN KEY (MaritalStatusId)      REFERENCES dbo.MaritalStatusMaster(MaritalStatusId)
    );

    -- Indexes for common lookups
    CREATE INDEX IX_PatientMaster_PhoneNumber  ON dbo.PatientMaster (PhoneNumber);
    CREATE INDEX IX_PatientMaster_PatientCode  ON dbo.PatientMaster (PatientCode);
    CREATE INDEX IX_PatientMaster_BranchId     ON dbo.PatientMaster (BranchId);

    PRINT 'Created table: PatientMaster';
END
GO

-- ─── Sequence for PatientCode ────────────────────────────────────────────────
-- PatientCode format: P000001, P000002, …
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = 'PatientCodeSeq' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE SEQUENCE dbo.PatientCodeSeq
        AS INT
        START WITH 1
        INCREMENT BY 1
        MINVALUE 1
        NO MAXVALUE
        NO CYCLE
        CACHE 50;
    PRINT 'Created sequence: PatientCodeSeq';
END
GO
