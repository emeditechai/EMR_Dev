-- ============================================================================
-- Script: 75_ipd_tariff_category_master.sql
-- Description: Create TariffCategoryMaster for IPD Module
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_NAME = 'TariffCategoryMaster'
)
BEGIN
    CREATE TABLE dbo.TariffCategoryMaster (
        TariffCategoryId INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId        INT           NOT NULL CONSTRAINT DF_TariffCategoryMaster_CompanyId DEFAULT(1),
        BranchId         INT           NULL,
        Code             NVARCHAR(10)  NOT NULL,
        Name             NVARCHAR(150) NOT NULL,
        PatientCategory  NVARCHAR(100) NOT NULL,
        Description      NVARCHAR(500) NULL,
        IsActive         BIT           NOT NULL CONSTRAINT DF_TariffCategoryMaster_IsActive DEFAULT(1),
        CreatedBy        INT           NULL,
        CreatedDate      DATETIME2     NOT NULL CONSTRAINT DF_TariffCategoryMaster_CreatedDate DEFAULT(GETDATE()),
        ModifiedBy       INT           NULL,
        ModifiedDate     DATETIME2     NULL,
        CONSTRAINT FK_TariffCategoryMaster_Company 
            FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId),
        CONSTRAINT UQ_TariffCategoryMaster_Company_Code 
            UNIQUE (CompanyId, Code),
        CONSTRAINT UQ_TariffCategoryMaster_Company_Name 
            UNIQUE (CompanyId, Name)
    );

    CREATE INDEX IX_TariffCategoryMaster_CompanyId ON dbo.TariffCategoryMaster(CompanyId);
    CREATE INDEX IX_TariffCategoryMaster_BranchId ON dbo.TariffCategoryMaster(BranchId);
    CREATE INDEX IX_TariffCategoryMaster_PatientCategory ON dbo.TariffCategoryMaster(PatientCategory);

    PRINT 'TariffCategoryMaster table created.';
END
ELSE
BEGIN
    PRINT 'TariffCategoryMaster table already exists.';
END
GO

-- Seed requested standard Tariff Categories
IF NOT EXISTS (SELECT 1 FROM dbo.TariffCategoryMaster)
BEGIN
    INSERT INTO dbo.TariffCategoryMaster (
        CompanyId, BranchId, Code, Name, PatientCategory, Description, IsActive, CreatedDate
    ) VALUES
    (1, 1, 'GEN',      'General',          'Cash / Self Pay',             'Standard rack rates for walk-in cash and private patients', 1, GETDATE()),
    (1, 1, 'B2C',      'B2C',              'Cash / Self Pay',             'Direct retail customer pricing and outpatient packages', 1, GETDATE()),
    (1, 1, 'CORP',     'Corporate',        'Corporate',                   'Corporate institutional tied-up tariffs with contracted discount tiers', 1, GETDATE()),
    (1, 1, 'INS',      'Insurance',        'Insurance / TPA',             'Pre-authorized private health insurance indemnity rate schedule', 1, GETDATE()),
    (1, 1, 'TPA',      'TPA',              'Insurance / TPA',             'Third Party Administrator cashless claims tariff', 1, GETDATE()),
    (1, 1, 'GOVT',     'Government',       'Government / Public Scheme',  'Government health schemes (CGHS / PMJAY / State health insurance)', 1, GETDATE()),
    (1, 1, 'PSU',      'PSU',              'Corporate',                   'Public Sector Undertakings and statutory enterprise agreements', 1, GETDATE()),
    (1, 1, 'EMP',      'Employee',         'Staff / Employee',            'Hospital employees, consultants, and dependent family benefit rates', 1, GETDATE()),
    (1, 1, 'SPCL',     'Special Contract', 'Corporate',                   'Custom negotiated VIP and institutional rate agreements', 1, GETDATE());

    PRINT 'TariffCategoryMaster seeded successfully.';
END
GO
