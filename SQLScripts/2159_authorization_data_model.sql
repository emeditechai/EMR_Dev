-- ============================================================================
-- Migration: 2159_authorization_data_model.sql
-- Description:
--   Server-Side Authorization Blueprint - Phase 1 (Model & inventory).
--   Seven tables that hold the entire navigation tree and every grant made against
--   it, resolved by one stored procedure (usp_Auth_GetEffectivePermissions).
--
--   The rule: a nav bar item holds menu items, a menu item holds sub-menu items,
--   a sub-menu item opens a page, and a page has its controls. A permission can be
--   set at any of those five scopes, for a role or for one user. The innermost
--   scope with a row wins; within a scope a user row beats a role row; when two of
--   a user's roles disagree at the same scope, Deny wins. No row anywhere = denied.
--
--   Decisions taken for this build (confirmed 27 Sep 2026):
--     - Roles are branch-scoped: Userroles.Branch_ID (NULL = every branch the user has).
--     - Deny beats Allow within a scope.
--     - Administrator bypasses authorization entirely, the same as Super Admin
--       (Users.IsSuperAdmin, or membership of the 'Administrator' role).
--     - No 2FA scaffolding in this phase.
--
--   Tables: MenuMaster, PageMaster, PageControlMaster, PageEndpointMap,
--           RolePermission, UserPermission, PermissionAuditLog.
--   Also:   Users.Permission_Version, Users.IsSuperAdmin, Userroles.Branch_ID.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ────────────────────────────────────────────────────────────────────────────
-- 0. Two small changes to existing tables
-- ────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'Permission_Version')
    ALTER TABLE dbo.Users ADD Permission_Version INT NOT NULL CONSTRAINT DF_Users_Permission_Version DEFAULT 1;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'IsSuperAdmin')
    ALTER TABLE dbo.Users ADD IsSuperAdmin BIT NOT NULL CONSTRAINT DF_Users_IsSuperAdmin DEFAULT 0;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Userroles') AND name = 'Branch_ID')
    ALTER TABLE dbo.Userroles ADD Branch_ID INT NULL; -- NULL = every branch this user is mapped to
GO
PRINT 'Users.Permission_Version, Users.IsSuperAdmin, Userroles.Branch_ID ready.';
GO

-- ────────────────────────────────────────────────────────────────────────────
-- 1. MenuMaster - the navigation tree: nav bar item -> menu item -> sub-menu item
-- ────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'MenuMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.MenuMaster
    (
        Menu_ID        INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId      INT NOT NULL DEFAULT 1,
        Parent_Menu_ID INT NULL REFERENCES dbo.MenuMaster(Menu_ID),
        Menu_Type      VARCHAR(10) NOT NULL, -- NAV | MENU | SUBMENU
        Menu_Code      NVARCHAR(100) NOT NULL,
        Title          NVARCHAR(150) NOT NULL,
        Icon           NVARCHAR(100) NULL,
        Sort_Order     INT NOT NULL DEFAULT 0,
        IsActive       BIT NOT NULL DEFAULT 1,
        CreatedBy      INT NULL,
        CreatedDate    DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy     INT NULL,
        ModifiedDate   DATETIME2 NULL,
        CONSTRAINT CK_MenuMaster_Type CHECK (Menu_Type IN ('NAV', 'MENU', 'SUBMENU'))
    );
    CREATE UNIQUE INDEX UX_MenuMaster_Code ON dbo.MenuMaster(Menu_Code, CompanyId);
    CREATE INDEX IX_MenuMaster_Parent ON dbo.MenuMaster(Parent_Menu_ID);
    PRINT 'Created table dbo.MenuMaster';
END
ELSE PRINT 'dbo.MenuMaster already exists.';
GO

-- ────────────────────────────────────────────────────────────────────────────
-- 2. PageMaster - one row per screen, whether or not it appears in the menu
-- ────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PageMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.PageMaster
    (
        Page_ID       INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId     INT NOT NULL DEFAULT 1,
        Menu_ID       INT NULL REFERENCES dbo.MenuMaster(Menu_ID),
        Page_Code     NVARCHAR(150) NOT NULL,   -- stable name used in code, e.g. LAB.REPORTING.ENTRY
        Title         NVARCHAR(150) NOT NULL,
        Controller    NVARCHAR(100) NOT NULL,
        Action        NVARCHAR(100) NOT NULL,
        Area          NVARCHAR(100) NULL,
        Show_In_Menu  BIT NOT NULL DEFAULT 1,
        Sort_Order    INT NOT NULL DEFAULT 0,
        IsActive      BIT NOT NULL DEFAULT 1,
        CreatedBy     INT NULL,
        CreatedDate   DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy    INT NULL,
        ModifiedDate  DATETIME2 NULL
    );
    CREATE UNIQUE INDEX UX_PageMaster_Code ON dbo.PageMaster(Page_Code, CompanyId);
    CREATE INDEX IX_PageMaster_Menu ON dbo.PageMaster(Menu_ID);
    CREATE INDEX IX_PageMaster_ControllerAction ON dbo.PageMaster(Controller, Action);
    PRINT 'Created table dbo.PageMaster';
END
ELSE PRINT 'dbo.PageMaster already exists.';
GO

-- ────────────────────────────────────────────────────────────────────────────
-- 3. PageControlMaster - the named actions of a page. Every page gets VIEW.
-- ────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PageControlMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.PageControlMaster
    (
        Control_ID    INT IDENTITY(1,1) PRIMARY KEY,
        Page_ID       INT NOT NULL REFERENCES dbo.PageMaster(Page_ID),
        Control_Code  VARCHAR(30) NOT NULL,     -- VIEW, CREATE, EDIT, DELETE, PRINT, EXPORT, APPROVE, CANCEL,
                                                  -- SETTLE, DISCOUNT, UNAUTHORIZE, or a page-specific one (ENTRY, VALIDATE, RECOLLECT...)
        Title         NVARCHAR(150) NOT NULL,
        Sort_Order    INT NOT NULL DEFAULT 0,
        IsActive      BIT NOT NULL DEFAULT 1,
        CreatedBy     INT NULL,
        CreatedDate   DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy    INT NULL,
        ModifiedDate  DATETIME2 NULL
    );
    CREATE UNIQUE INDEX UX_PageControlMaster_PageCode ON dbo.PageControlMaster(Page_ID, Control_Code);
    PRINT 'Created table dbo.PageControlMaster';
END
ELSE PRINT 'dbo.PageControlMaster already exists.';
GO

-- ────────────────────────────────────────────────────────────────────────────
-- 4. PageEndpointMap - which controller action (WEB or API) belongs to which
--    page and control. The bridge between the ~788 MVC actions / API routes
--    and the permission model.
-- ────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PageEndpointMap' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.PageEndpointMap
    (
        Endpoint_ID   INT IDENTITY(1,1) PRIMARY KEY,
        Page_ID       INT NOT NULL REFERENCES dbo.PageMaster(Page_ID),
        Control_ID    INT NULL REFERENCES dbo.PageControlMaster(Control_ID),
        App           VARCHAR(10) NOT NULL DEFAULT 'WEB',  -- WEB | API
        Http_Method   VARCHAR(10) NOT NULL DEFAULT 'GET',
        Controller    NVARCHAR(150) NOT NULL,
        Action        NVARCHAR(150) NOT NULL,
        Route         NVARCHAR(300) NULL,
        IsActive      BIT NOT NULL DEFAULT 1,
        CreatedDate   DATETIME2 NOT NULL DEFAULT GETDATE()
    );
    -- One endpoint, one meaning: an action can only ever map to one page/control.
    CREATE UNIQUE INDEX UX_PageEndpointMap_Endpoint ON dbo.PageEndpointMap(App, Http_Method, Controller, Action);
    CREATE INDEX IX_PageEndpointMap_Page ON dbo.PageEndpointMap(Page_ID);
    PRINT 'Created table dbo.PageEndpointMap';
END
ELSE PRINT 'dbo.PageEndpointMap already exists.';
GO

-- ────────────────────────────────────────────────────────────────────────────
-- 5. RolePermission - what a role may reach, at any of the five scopes.
--    Exactly one of Menu_ID / Page_ID is set; Control_ID only ever accompanies
--    a page. Branch_ID NULL = every branch the role covers.
-- ────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RolePermission' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.RolePermission
    (
        RolePermission_ID INT IDENTITY(1,1) PRIMARY KEY,
        Role_ID       INT NOT NULL REFERENCES dbo.roles(Id),
        Menu_ID       INT NULL REFERENCES dbo.MenuMaster(Menu_ID),
        Page_ID       INT NULL REFERENCES dbo.PageMaster(Page_ID),
        Control_ID    INT NULL REFERENCES dbo.PageControlMaster(Control_ID),
        Branch_ID     INT NULL,                 -- NULL = every branch
        Permission    CHAR(1) NOT NULL,          -- A | D
        CompanyId     INT NOT NULL DEFAULT 1,
        Reason        NVARCHAR(500) NULL,
        CreatedBy     INT NULL,
        CreatedDate   DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy    INT NULL,
        ModifiedDate  DATETIME2 NULL,
        -- computed sentinels so the unique index also catches "duplicate NULL" grants
        Menu_Key      AS (ISNULL(Menu_ID, 0)) PERSISTED,
        Page_Key      AS (ISNULL(Page_ID, 0)) PERSISTED,
        Control_Key   AS (ISNULL(Control_ID, 0)) PERSISTED,
        Branch_Key    AS (ISNULL(Branch_ID, 0)) PERSISTED,
        CONSTRAINT CK_RolePermission_Scope CHECK (
            (Menu_ID IS NOT NULL AND Page_ID IS NULL AND Control_ID IS NULL) OR
            (Menu_ID IS NULL AND Page_ID IS NOT NULL)
        ),
        CONSTRAINT CK_RolePermission_Value CHECK (Permission IN ('A', 'D'))
    );
    CREATE UNIQUE INDEX UX_RolePermission_Grant ON dbo.RolePermission(Role_ID, Menu_Key, Page_Key, Control_Key, Branch_Key);
    CREATE INDEX IX_RolePermission_Page ON dbo.RolePermission(Page_ID);
    CREATE INDEX IX_RolePermission_Menu ON dbo.RolePermission(Menu_ID);
    PRINT 'Created table dbo.RolePermission';
END
ELSE PRINT 'dbo.RolePermission already exists.';
GO

-- ────────────────────────────────────────────────────────────────────────────
-- 6. UserPermission - one person's exceptions, same shape as RolePermission.
--    A control row here is the innermost scope and therefore the final answer.
-- ────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'UserPermission' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.UserPermission
    (
        UserPermission_ID INT IDENTITY(1,1) PRIMARY KEY,
        User_ID       INT NOT NULL REFERENCES dbo.Users(Id),
        Menu_ID       INT NULL REFERENCES dbo.MenuMaster(Menu_ID),
        Page_ID       INT NULL REFERENCES dbo.PageMaster(Page_ID),
        Control_ID    INT NULL REFERENCES dbo.PageControlMaster(Control_ID),
        Branch_ID     INT NULL,                 -- NULL = every branch
        Permission    CHAR(1) NOT NULL,          -- A | D
        Reason        NVARCHAR(500) NULL,        -- required for a Deny, kept with the history
        CreatedBy     INT NULL,
        CreatedDate   DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy    INT NULL,
        ModifiedDate  DATETIME2 NULL,
        Menu_Key      AS (ISNULL(Menu_ID, 0)) PERSISTED,
        Page_Key      AS (ISNULL(Page_ID, 0)) PERSISTED,
        Control_Key   AS (ISNULL(Control_ID, 0)) PERSISTED,
        Branch_Key    AS (ISNULL(Branch_ID, 0)) PERSISTED,
        CONSTRAINT CK_UserPermission_Scope CHECK (
            (Menu_ID IS NOT NULL AND Page_ID IS NULL AND Control_ID IS NULL) OR
            (Menu_ID IS NULL AND Page_ID IS NOT NULL)
        ),
        CONSTRAINT CK_UserPermission_Value CHECK (Permission IN ('A', 'D'))
    );
    CREATE UNIQUE INDEX UX_UserPermission_Grant ON dbo.UserPermission(User_ID, Menu_Key, Page_Key, Control_Key, Branch_Key);
    CREATE INDEX IX_UserPermission_Page ON dbo.UserPermission(Page_ID);
    CREATE INDEX IX_UserPermission_Menu ON dbo.UserPermission(Menu_ID);
    PRINT 'Created table dbo.UserPermission';
END
ELSE PRINT 'dbo.UserPermission already exists.';
GO

-- ────────────────────────────────────────────────────────────────────────────
-- 7. PermissionAuditLog - who changed which grant, when, from what to what.
-- ────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PermissionAuditLog' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.PermissionAuditLog
    (
        Log_ID      INT IDENTITY(1,1) PRIMARY KEY,
        Entity      VARCHAR(10) NOT NULL,        -- ROLE | USER
        Target_ID   INT NOT NULL,                -- Role_ID or User_ID
        Menu_ID     INT NULL,
        Page_ID     INT NULL,
        Control_ID  INT NULL,
        Branch_ID   INT NULL,
        Old_Value   CHAR(1) NULL,
        New_Value   CHAR(1) NULL,
        Changed_By  INT NULL,
        Changed_On  DATETIME2 NOT NULL DEFAULT GETDATE(),
        Reason      NVARCHAR(500) NULL
    );
    CREATE INDEX IX_PermissionAuditLog_Target ON dbo.PermissionAuditLog(Entity, Target_ID);
    PRINT 'Created table dbo.PermissionAuditLog';
END
ELSE PRINT 'dbo.PermissionAuditLog already exists.';
GO

PRINT 'Script 2159 applied: authorization data model (7 tables + 3 column additions) ready.';
GO
