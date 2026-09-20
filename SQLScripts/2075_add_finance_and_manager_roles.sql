-- Migration Script: 2072_add_finance_and_manager_roles.sql
-- Description: Add Finance and Manager roles to dbo.roles table

IF NOT EXISTS (SELECT 1 FROM dbo.roles WHERE Name = 'Finance')
BEGIN
    INSERT INTO dbo.roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, BranchID, IconClass)
    VALUES ('Finance', 'Financial operations, billing and settlement access', 0, SYSUTCDATETIME(), SYSUTCDATETIME(), 1, 'fas fa-file-invoice-dollar');
    PRINT 'Role "Finance" added successfully.';
END
ELSE
BEGIN
    PRINT 'Role "Finance" already exists.';
END;

IF NOT EXISTS (SELECT 1 FROM dbo.roles WHERE Name = 'Manager')
BEGIN
    INSERT INTO dbo.roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, BranchID, IconClass)
    VALUES ('Manager', 'Branch and operations management access', 0, SYSUTCDATETIME(), SYSUTCDATETIME(), 1, 'fas fa-user-tie');
    PRINT 'Role "Manager" added successfully.';
END
ELSE
BEGIN
    PRINT 'Role "Manager" already exists.';
END;
GO

-- Verification query
SELECT Id, Name, Description, IsSystemRole, BranchID, IconClass, CreatedDate
FROM dbo.roles
ORDER BY Id;
GO
