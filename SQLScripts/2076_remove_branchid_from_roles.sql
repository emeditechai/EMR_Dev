-- Migration Script: 2073_remove_branchid_from_roles.sql
-- Description: Drop BranchID column and its FK/Index from dbo.roles; link roles to dbo.CompanyMaster

-- 1. Drop Foreign Key on BranchID
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_roles_Branchmaster' AND parent_object_id = OBJECT_ID('dbo.roles'))
BEGIN
    ALTER TABLE dbo.roles DROP CONSTRAINT FK_roles_Branchmaster;
    PRINT 'Dropped foreign key FK_roles_Branchmaster.';
END;

-- 2. Drop Index on BranchID
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_roles_BranchID' AND object_id = OBJECT_ID('dbo.roles'))
BEGIN
    DROP INDEX IX_roles_BranchID ON dbo.roles;
    PRINT 'Dropped index IX_roles_BranchID.';
END;

-- 3. Ensure CompanyId column exists and is populated
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'roles' AND COLUMN_NAME = 'CompanyId')
BEGIN
    ALTER TABLE dbo.roles ADD CompanyId INT NOT NULL CONSTRAINT DF_roles_CompanyId DEFAULT (1);
    PRINT 'Added CompanyId column to dbo.roles.';
END
ELSE
BEGIN
    UPDATE dbo.roles SET CompanyId = 1 WHERE CompanyId IS NULL OR CompanyId = 0;
END;

-- 4. Drop Column BranchID
IF EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'roles' AND COLUMN_NAME = 'BranchID')
BEGIN
    ALTER TABLE dbo.roles DROP COLUMN BranchID;
    PRINT 'Dropped column BranchID from dbo.roles.';
END;

-- 5. Add Foreign Key on CompanyId
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_roles_CompanyMaster' AND parent_object_id = OBJECT_ID('dbo.roles'))
BEGIN
    ALTER TABLE dbo.roles ADD CONSTRAINT FK_roles_CompanyMaster FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId);
    PRINT 'Added foreign key FK_roles_CompanyMaster.';
END;

-- 6. Add Index on CompanyId
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_roles_CompanyId' AND object_id = OBJECT_ID('dbo.roles'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_roles_CompanyId ON dbo.roles (CompanyId);
    PRINT 'Created index IX_roles_CompanyId.';
END;
GO

-- Verification query
SELECT Id, Name, Description, IsSystemRole, CompanyId, IconClass, CreatedDate
FROM dbo.roles
ORDER BY Id;
GO
