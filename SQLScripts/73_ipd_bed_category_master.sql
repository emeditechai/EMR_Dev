-- ============================================================================
-- Script: 73_ipd_bed_category_master.sql
-- Description: Create BedCategoryMaster for IPD Module
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_NAME = 'BedCategoryMaster'
)
BEGIN
    CREATE TABLE dbo.BedCategoryMaster (
        BedCategoryId INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId     INT           NOT NULL CONSTRAINT DF_BedCategoryMaster_CompanyId DEFAULT(1),
        BranchId      INT           NULL,
        CategoryCode  NVARCHAR(50)  NULL,
        CategoryName  NVARCHAR(150) NOT NULL,
        Description   NVARCHAR(500) NULL,
        IsActive      BIT           NOT NULL CONSTRAINT DF_BedCategoryMaster_IsActive DEFAULT(1),
        CreatedBy     INT           NULL,
        CreatedDate   DATETIME2     NOT NULL CONSTRAINT DF_BedCategoryMaster_CreatedDate DEFAULT(GETDATE()),
        ModifiedBy    INT           NULL,
        ModifiedDate  DATETIME2     NULL,
        CONSTRAINT FK_BedCategoryMaster_Company 
            FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId),
        CONSTRAINT UQ_BedCategoryMaster_Company_Name 
            UNIQUE (CompanyId, CategoryName)
    );

    CREATE INDEX IX_BedCategoryMaster_CompanyId ON dbo.BedCategoryMaster(CompanyId);
    CREATE INDEX IX_BedCategoryMaster_BranchId ON dbo.BedCategoryMaster(BranchId);

    PRINT 'BedCategoryMaster table created.';
END
ELSE
BEGIN
    PRINT 'BedCategoryMaster table already exists.';
END
GO

-- Seed requested standard Bed Categories
IF NOT EXISTS (SELECT 1 FROM dbo.BedCategoryMaster)
BEGIN
    INSERT INTO dbo.BedCategoryMaster (
        CompanyId, BranchId, CategoryCode, CategoryName, Description, IsActive, CreatedDate
    ) VALUES
    (1, 1, 'GEN',  'General',       'Standard shared multi-bed ward accommodations', 1, GETDATE()),
    (1, 1, 'SPRV', 'Semi Private',  'Twin sharing inpatient rooms with partitioned privacy', 1, GETDATE()),
    (1, 1, 'PRV',  'Private',       'Single occupancy private room with attached facilities', 1, GETDATE()),
    (1, 1, 'DLX',  'Deluxe',        'Spacious private room with electric bed and attendant couch', 1, GETDATE()),
    (1, 1, 'SUT',  'Suite',         'Executive suite with separate visitor lounge and kitchenette', 1, GETDATE()),
    (1, 1, 'ICU',  'ICU',           'Intensive Care Unit bed with advanced life-support systems', 1, GETDATE()),
    (1, 1, 'HDU',  'HDU',           'High Dependency Unit for close step-down monitoring', 1, GETDATE()),
    (1, 1, 'NICU', 'NICU',          'Neonatal Intensive Care Unit incubator/warmer bed', 1, GETDATE()),
    (1, 1, 'PICU', 'PICU',          'Pediatric Intensive Care Unit bed', 1, GETDATE()),
    (1, 1, 'ISO',  'Isolation',     'Negative pressure airborne infection isolation bed', 1, GETDATE()),
    (1, 1, 'EMG',  'Emergency',     'Emergency triaging and acute resuscitation bed', 1, GETDATE()),
    (1, 1, 'OBS',  'Observation',   'Short-stay observation and monitoring bed', 1, GETDATE()),
    (1, 1, 'DC',   'Day Care',      'Same-day procedural and chemotherapy infusion bed', 1, GETDATE());

    PRINT 'BedCategoryMaster seeded successfully.';
END
GO
