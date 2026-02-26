-- EMR System Seed Data Script
-- Notes:
-- 1) Uses the sample admin hash from your reference row.
-- 2) Default seed user: admin

SET IDENTITY_INSERT dbo.Branchmaster ON;
INSERT INTO dbo.Branchmaster (BranchID, BranchName, BranchCode, Country, State, City, Address, Pincode, IsHOBranch, IsActive, CreatedBy, CreatedDate, ModifiedBy, ModifiedDate)
VALUES
(1, 'Head Office', 'HO', 'India', 'Maharashtra', 'Mumbai', 'Head Office Address', '400001', 1, 1, NULL, '2025-12-02 12:22:55.750', NULL, NULL),
(2, 'Kolkata', 'KOL', 'India', 'West Bengal', 'Kolkata', 'Kolkata Branch Address', '700001', 0, 1, NULL, SYSUTCDATETIME(), NULL, NULL);
SET IDENTITY_INSERT dbo.Branchmaster OFF;
GO

SET IDENTITY_INSERT dbo.Users ON;
INSERT INTO dbo.Users
(
    Id, Username, Email, PasswordHash, Salt, FirstName, LastName, PhoneNumber, Phone, FullName,
    Role, IsActive, IsLockedOut, FailedLoginAttempts, LastLoginDate, CreatedDate, LastModifiedDate,
    MustChangePassword, PasswordLastChanged, RequiresMFA
)
VALUES
(
    1, 'admin', 'admin@restaurant.com',
    '$2a$12$3py6CatAJTlZ0SOOmSWaxOfHEruPDLYgrPxvoK5SA/gHlk8Brk7du',
    '$2a$12$3py6CatAJTlZ0SOOmSWaxO',
    'Super', 'Admin', '8617280732', '8617280732', 'Super Admin',
    'Super Admin', 1, 0, 0, '2026-02-08 10:07:15.4500000', '2025-09-03 20:56:45.1830000', '2025-12-02 14:38:10.3233333',
    0, '2025-12-02 14:38:10.3233333', 0
);
SET IDENTITY_INSERT dbo.Users OFF;
GO

SET IDENTITY_INSERT dbo.roles ON;
INSERT INTO dbo.roles (Id, Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, BranchID, IconClass)
VALUES
(1, 'Administrator', 'Full system access', 1, '2025-09-03 20:56:42.3700000', '2025-09-03 20:56:42.3700000', 1, 'fas fa-user-shield'),
(2, 'Doctor', 'Doctor-level access', 0, SYSUTCDATETIME(), SYSUTCDATETIME(), 1, 'fas fa-user-md'),
(3, 'Nurse', 'Nurse-level access', 0, SYSUTCDATETIME(), SYSUTCDATETIME(), 1, 'fas fa-user-nurse'),
(4, 'Receptionist', 'Front desk access', 0, SYSUTCDATETIME(), SYSUTCDATETIME(), 2, 'fas fa-id-card');
SET IDENTITY_INSERT dbo.roles OFF;
GO

SET IDENTITY_INSERT dbo.UserBranches ON;
INSERT INTO dbo.UserBranches (Id, UserId, BranchID, IsActive, CreatedBy, CreatedDate, ModifiedBy, ModifiedDate)
VALUES
(1, 1, 1, 1, NULL, '2025-12-02 13:49:18.317', 1, '2025-12-02 14:38:10.543'),
(2, 1, 2, 1, NULL, '2025-12-02 14:00:40.473', 1, '2026-02-01 11:05:34.533');
SET IDENTITY_INSERT dbo.UserBranches OFF;
GO

SET IDENTITY_INSERT dbo.Userroles ON;
INSERT INTO dbo.Userroles (Id, UserId, RoleId, IsActive, AssignedDate, AssignedBy, CreatedBy, CreatedDate, ModifiedBy, ModifiedDate)
VALUES
(1, 1, 1, 1, SYSUTCDATETIME(), 1, 1, SYSUTCDATETIME(), 1, SYSUTCDATETIME());
SET IDENTITY_INSERT dbo.Userroles OFF;
GO

INSERT INTO dbo.AuditLogs (UserId, BranchId, EventType, ActionName, ControllerName, RoutePath, HttpMethod, IpAddress, UserAgent, Description, CreatedDate)
VALUES
(1, 1, 'System', 'SeedData', 'Database', '/SQLScripts/02_seed_data.sql', 'SQL', '127.0.0.1', 'SQL Script', 'Initial audit seed row', SYSUTCDATETIME());
GO
