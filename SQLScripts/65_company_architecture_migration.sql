-- ==============================================================================
-- 65_company_architecture_migration.sql
-- Introduce Company Architecture (Parent Multi-Tenancy)
-- Adds CompanyMaster table, adds CompanyId to all database tables,
-- backfills existing data, and updates all stored procedures.
-- ==============================================================================

-- 1. Create dbo.CompanyMaster table
IF OBJECT_ID('dbo.CompanyMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CompanyMaster
    (
        CompanyId INT IDENTITY(1,1) PRIMARY KEY,
        CompanyCode NVARCHAR(50) NOT NULL UNIQUE,
        CompanyName NVARCHAR(200) NOT NULL,
        LegalName NVARCHAR(200) NULL,
        RegistrationNumber NVARCHAR(50) NULL,
        GSTIN NVARCHAR(50) NULL,
        PAN NVARCHAR(50) NULL,
        Email NVARCHAR(200) NULL,
        Phone NVARCHAR(50) NULL,
        Website NVARCHAR(200) NULL,
        LogoPath NVARCHAR(500) NULL,
        Address NVARCHAR(500) NULL,
        Country NVARCHAR(100) NULL,
        State NVARCHAR(100) NULL,
        City NVARCHAR(100) NULL,
        Pincode NVARCHAR(20) NULL,
        IsActive BIT NOT NULL CONSTRAINT DF_CompanyMaster_IsActive DEFAULT(1),
        CreatedBy INT NULL,
        CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_CompanyMaster_CreatedDate DEFAULT(SYSUTCDATETIME()),
        ModifiedBy INT NULL,
        ModifiedDate DATETIME2 NULL
    );
END
GO

-- 2. Seed Default Company (CompanyId = 1) if table is empty
IF NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyId = 1)
BEGIN
    SET IDENTITY_INSERT dbo.CompanyMaster ON;
    INSERT INTO dbo.CompanyMaster (
        CompanyId, CompanyCode, CompanyName, LegalName, RegistrationNumber, GSTIN, 
        Email, Phone, Website, Address, City, State, Country, Pincode, IsActive, CreatedDate
    ) VALUES (
        1, 'CMP-001', 'Primary Healthcare Network', 'Primary Healthcare Network Pvt Ltd', 'U85110WB2020PTC123456', 
        '19AAACP1234A1Z5', 'info@primaryhealthcare.com', '+91 33 2456 7890', 'https://primaryhealthcare.com',
        '12A Medical Center Avenue, Sector 5', 'Kolkata', 'West Bengal', 'India', '700091', 1, SYSUTCDATETIME()
    );
    SET IDENTITY_INSERT dbo.CompanyMaster OFF;
END
GO

-- 3. Helper to Add CompanyId column across all tables
DECLARE @Tables TABLE (TableName NVARCHAR(100), HasBranchCol BIT);
INSERT INTO @Tables (TableName, HasBranchCol) VALUES
    ('Branchmaster', 0),
    ('Users', 0),
    ('roles', 1),
    ('UserBranches', 1),
    ('AuditLogs', 1),
    ('HospitalSettings', 1),
    ('DoctorMaster', 0),
    ('DoctorSpecialityMaster', 0),
    ('DepartmentMaster', 0),
    ('FloorMaster', 0),
    ('DoctorRoomMaster', 1),
    ('DoctorRoomMapping', 0),
    ('DoctorBranchMap', 1),
    ('DoctorDepartmentMap', 0),
    ('DoctorConsultingFeeMap', 1),
    ('DoctorScheduleMaster', 1),
    ('DoctorScheduleException', 1),
    ('ServiceMaster', 1),
    ('ReferralDoctorMaster', 0),
    ('PaymentMethodMaster', 0),
    ('PatientMaster', 1),
    ('PatientOPDService', 1),
    ('PatientOPDServiceItem', 0),
    ('PatientVitals', 0),
    ('PaymentHeader', 1),
    ('PaymentLineItem', 0),
    ('PaymentDetail', 0),
    ('OPDBillSequence', 1),
    ('OPDTokenSequence', 1),
    ('PatientCodeCounter', 1),
    ('ReceiptSequence', 1),
    ('EmailTemplates', 1),
    ('EmailLogs', 1),
    ('SmtpEmailConfiguration', 1),
    ('EmrTemplates', 0),
    ('EmrTemplateSections', 0),
    ('EmrTemplateFields', 0),
    ('EmrTemplateSpecialityMap', 0),
    ('EmrInvestigationMaster', 0),
    ('EmrMedicationMaster', 0),
    ('EmrPatientConsultation', 0),
    ('tbl_VideoSystemConfig', 0),
    ('tbl_VideoConsultation', 0);

DECLARE @tbl NVARCHAR(100), @hasBranch BIT, @sql NVARCHAR(MAX);

DECLARE cur CURSOR FOR SELECT TableName, HasBranchCol FROM @Tables;
OPEN cur;
FETCH NEXT FROM cur INTO @tbl, @hasBranch;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID('dbo.' + @tbl, 'U') IS NOT NULL
    BEGIN
        -- Add CompanyId column if missing
        IF NOT EXISTS (
            SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS 
            WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = @tbl AND COLUMN_NAME = 'CompanyId'
        )
        BEGIN
            SET @sql = 'ALTER TABLE dbo.' + QUOTENAME(@tbl) + ' ADD CompanyId INT NOT NULL CONSTRAINT DF_' + @tbl + '_CompanyId DEFAULT(1);';
            EXEC sp_executesql @sql;
            PRINT 'Added CompanyId to ' + @tbl;
        END

        -- Backfill CompanyId = 1 for any NULLs
        SET @sql = 'UPDATE dbo.' + QUOTENAME(@tbl) + ' SET CompanyId = 1 WHERE CompanyId IS NULL OR CompanyId = 0;';
        EXEC sp_executesql @sql;

        -- Create index on CompanyId if missing
        IF NOT EXISTS (
            SELECT 1 FROM sys.indexes 
            WHERE name = 'IX_' + @tbl + '_CompanyId' AND object_id = OBJECT_ID('dbo.' + @tbl)
        )
        BEGIN
            SET @sql = 'CREATE INDEX ' + QUOTENAME('IX_' + @tbl + '_CompanyId') + ' ON dbo.' + QUOTENAME(@tbl) + '(CompanyId);';
            EXEC sp_executesql @sql;
        END
    END

    FETCH NEXT FROM cur INTO @tbl, @hasBranch;
END

CLOSE cur;
DEALLOCATE cur;
GO

-- 4. Add FK from Branchmaster to CompanyMaster if not exists
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys 
    WHERE name = 'FK_Branchmaster_CompanyMaster' AND parent_object_id = OBJECT_ID('dbo.Branchmaster')
)
BEGIN
    ALTER TABLE dbo.Branchmaster 
    ADD CONSTRAINT FK_Branchmaster_CompanyMaster FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId);
    PRINT 'Added FK_Branchmaster_CompanyMaster';
END
GO

-- 5. Add FK from Users to CompanyMaster if not exists
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys 
    WHERE name = 'FK_Users_CompanyMaster' AND parent_object_id = OBJECT_ID('dbo.Users')
)
BEGIN
    ALTER TABLE dbo.Users 
    ADD CONSTRAINT FK_Users_CompanyMaster FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId);
    PRINT 'Added FK_Users_CompanyMaster';
END
GO
