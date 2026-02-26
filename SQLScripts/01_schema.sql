-- EMR System Schema Script
-- Database: Dev_EMR

IF OBJECT_ID('dbo.AuditLogs', 'U') IS NOT NULL DROP TABLE dbo.AuditLogs;
IF OBJECT_ID('dbo.Userroles', 'U') IS NOT NULL DROP TABLE dbo.Userroles;
IF OBJECT_ID('dbo.UserBranches', 'U') IS NOT NULL DROP TABLE dbo.UserBranches;
IF OBJECT_ID('dbo.roles', 'U') IS NOT NULL DROP TABLE dbo.roles;
IF OBJECT_ID('dbo.Branchmaster', 'U') IS NOT NULL DROP TABLE dbo.Branchmaster;
IF OBJECT_ID('dbo.Users', 'U') IS NOT NULL DROP TABLE dbo.Users;
GO

CREATE TABLE dbo.Users
(
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Username NVARCHAR(100) NOT NULL UNIQUE,
    Email NVARCHAR(200) NULL,
    PasswordHash NVARCHAR(255) NOT NULL,
    Salt NVARCHAR(255) NULL,
    FirstName NVARCHAR(100) NULL,
    LastName NVARCHAR(100) NULL,
    PhoneNumber NVARCHAR(20) NULL,
    Phone NVARCHAR(20) NULL,
    FullName NVARCHAR(200) NULL,
    Role NVARCHAR(100) NULL,
    IsActive BIT NOT NULL CONSTRAINT DF_Users_IsActive DEFAULT(1),
    IsLockedOut BIT NOT NULL CONSTRAINT DF_Users_IsLockedOut DEFAULT(0),
    FailedLoginAttempts INT NOT NULL CONSTRAINT DF_Users_FailedLoginAttempts DEFAULT(0),
    LastLoginDate DATETIME2 NULL,
    CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_Users_CreatedDate DEFAULT(SYSUTCDATETIME()),
    LastModifiedDate DATETIME2 NULL,
    MustChangePassword BIT NOT NULL CONSTRAINT DF_Users_MustChangePassword DEFAULT(0),
    PasswordLastChanged DATETIME2 NULL,
    RequiresMFA BIT NOT NULL CONSTRAINT DF_Users_RequiresMFA DEFAULT(0)
);
GO

CREATE TABLE dbo.Branchmaster
(
    BranchID INT IDENTITY(1,1) PRIMARY KEY,
    BranchName NVARCHAR(150) NOT NULL,
    BranchCode NVARCHAR(50) NOT NULL UNIQUE,
    Country NVARCHAR(100) NULL,
    State NVARCHAR(100) NULL,
    City NVARCHAR(100) NULL,
    Address NVARCHAR(250) NULL,
    Pincode NVARCHAR(20) NULL,
    IsHOBranch BIT NOT NULL CONSTRAINT DF_Branchmaster_IsHOBranch DEFAULT(0),
    IsActive BIT NOT NULL CONSTRAINT DF_Branchmaster_IsActive DEFAULT(1),
    CreatedBy INT NULL,
    CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_Branchmaster_CreatedDate DEFAULT(SYSUTCDATETIME()),
    ModifiedBy INT NULL,
    ModifiedDate DATETIME2 NULL
);
GO

CREATE TABLE dbo.roles
(
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Name NVARCHAR(100) NOT NULL,
    Description NVARCHAR(255) NULL,
    IsSystemRole BIT NOT NULL CONSTRAINT DF_roles_IsSystemRole DEFAULT(0),
    CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_roles_CreatedDate DEFAULT(SYSUTCDATETIME()),
    LastModifiedDate DATETIME2 NULL,
    BranchID INT NULL,
    IconClass NVARCHAR(100) NULL,
    CONSTRAINT FK_roles_Branchmaster FOREIGN KEY (BranchID) REFERENCES dbo.Branchmaster(BranchID)
);
GO

CREATE TABLE dbo.UserBranches
(
    Id INT IDENTITY(1,1) PRIMARY KEY,
    UserId INT NOT NULL,
    BranchID INT NOT NULL,
    IsActive BIT NOT NULL CONSTRAINT DF_UserBranches_IsActive DEFAULT(1),
    CreatedBy INT NULL,
    CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_UserBranches_CreatedDate DEFAULT(SYSUTCDATETIME()),
    ModifiedBy INT NULL,
    ModifiedDate DATETIME2 NULL,
    CONSTRAINT FK_UserBranches_Users FOREIGN KEY (UserId) REFERENCES dbo.Users(Id),
    CONSTRAINT FK_UserBranches_Branchmaster FOREIGN KEY (BranchID) REFERENCES dbo.Branchmaster(BranchID)
);
GO

CREATE TABLE dbo.Userroles
(
    Id INT IDENTITY(1,1) PRIMARY KEY,
    UserId INT NOT NULL,
    RoleId INT NOT NULL,
    IsActive BIT NOT NULL CONSTRAINT DF_Userroles_IsActive DEFAULT(1),
    AssignedDate DATETIME2 NOT NULL CONSTRAINT DF_Userroles_AssignedDate DEFAULT(SYSUTCDATETIME()),
    AssignedBy INT NULL,
    CreatedBy INT NULL,
    CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_Userroles_CreatedDate DEFAULT(SYSUTCDATETIME()),
    ModifiedBy INT NULL,
    ModifiedDate DATETIME2 NULL,
    CONSTRAINT FK_Userroles_Users FOREIGN KEY (UserId) REFERENCES dbo.Users(Id),
    CONSTRAINT FK_Userroles_roles FOREIGN KEY (RoleId) REFERENCES dbo.roles(Id)
);
GO

CREATE INDEX IX_UserBranches_User_Branch ON dbo.UserBranches(UserId, BranchID);
CREATE INDEX IX_Userroles_User_Role ON dbo.Userroles(UserId, RoleId);
CREATE INDEX IX_roles_BranchID ON dbo.roles(BranchID);
GO

CREATE TABLE dbo.AuditLogs
(
    Id BIGINT IDENTITY(1,1) PRIMARY KEY,
    UserId INT NULL,
    BranchId INT NULL,
    EventType NVARCHAR(100) NOT NULL,
    ActionName NVARCHAR(250) NOT NULL,
    ControllerName NVARCHAR(100) NULL,
    RoutePath NVARCHAR(500) NULL,
    HttpMethod NVARCHAR(50) NULL,
    IpAddress NVARCHAR(64) NULL,
    UserAgent NVARCHAR(500) NULL,
    Description NVARCHAR(2000) NULL,
    CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_AuditLogs_CreatedDate DEFAULT(SYSUTCDATETIME()),
    CONSTRAINT FK_AuditLogs_Users FOREIGN KEY (UserId) REFERENCES dbo.Users(Id),
    CONSTRAINT FK_AuditLogs_Branchmaster FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID)
);
GO

CREATE INDEX IX_AuditLogs_CreatedDate ON dbo.AuditLogs(CreatedDate);
CREATE INDEX IX_AuditLogs_User_Branch_CreatedDate ON dbo.AuditLogs(UserId, BranchId, CreatedDate);
GO
