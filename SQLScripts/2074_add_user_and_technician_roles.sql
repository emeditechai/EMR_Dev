-- Migration Script: 2071_add_user_and_technician_roles.sql
-- Description: Add User, Senior Technician, and Junior Technician roles to dbo.roles table

IF NOT EXISTS (SELECT 1 FROM dbo.roles WHERE Name = 'User')
BEGIN
    INSERT INTO dbo.roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, BranchID, IconClass)
    VALUES ('User', 'Standard user access', 0, SYSUTCDATETIME(), SYSUTCDATETIME(), 1, 'fas fa-user');
    PRINT 'Role "User" added successfully.';
END
ELSE
BEGIN
    PRINT 'Role "User" already exists.';
END;

IF NOT EXISTS (SELECT 1 FROM dbo.roles WHERE Name = 'Senior Technician')
BEGIN
    INSERT INTO dbo.roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, BranchID, IconClass)
    VALUES ('Senior Technician', 'Senior laboratory technician access', 0, SYSUTCDATETIME(), SYSUTCDATETIME(), 1, 'fas fa-microscope');
    PRINT 'Role "Senior Technician" added successfully.';
END
ELSE
BEGIN
    PRINT 'Role "Senior Technician" already exists.';
END;

IF NOT EXISTS (SELECT 1 FROM dbo.roles WHERE Name = 'Junior Technician')
BEGIN
    INSERT INTO dbo.roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, BranchID, IconClass)
    VALUES ('Junior Technician', 'Junior laboratory technician access', 0, SYSUTCDATETIME(), SYSUTCDATETIME(), 1, 'fas fa-vial');
    PRINT 'Role "Junior Technician" added successfully.';
END
ELSE
BEGIN
    PRINT 'Role "Junior Technician" already exists.';
END;
GO

-- Verification query
SELECT Id, Name, Description, IsSystemRole, BranchID, IconClass, CreatedDate
FROM dbo.roles
ORDER BY Id;
GO
