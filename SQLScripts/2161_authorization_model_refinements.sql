-- ============================================================================
-- Migration: 2161_authorization_model_refinements.sql
-- Description:
--   Server-Side Authorization - Phase 1, refinements found while converting the
--   hard-coded nav bar (_Layout.cshtml) into data:
--
--   PageMaster        + Icon, Route_Values, Link_Target: the bar must render identically
--                       from the database (icons with their colour class, the moduleCode
--                       route value on Bill Cancellation, target="_blank" on Patient Login).
--   PageEndpointMap   Page_ID becomes nullable: the endpoint scanner records every action
--                       it finds, mapped or not. Page_ID NULL = unmapped. Adds Source,
--                       Discovered_On, Last_Seen_On, Is_Orphaned for the curation workflow.
--   Users.IsSuperAdmin backfilled from today's hard-coded rule (username 'admin' or
--                       Users.Role 'Super Admin'/'SuperAdmin'), so nobody's access changes.
--   trg_Userroles_BumpPermissionVersion - any role assignment change, from any screen,
--                       moves the user's Permission_Version on, so it applies at once.
--
--   Procedures (re)created:
--     usp_Auth_PageMaster_Upsert             + @Icon, @Route_Values, @Link_Target
--     usp_Auth_GetEndpointMap                every active endpoint row (cached by the app)
--     usp_Auth_GetNavTree                    menus + pages to render the bar
--     usp_Auth_GetPermissionVersion          cheap per-request staleness check
--     usp_Auth_GetEffectivePermissions       + @RoleId: the session's active role
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── PageMaster: icon / route values / link target ──────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PageMaster') AND name = 'Icon')
    ALTER TABLE dbo.PageMaster ADD Icon NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PageMaster') AND name = 'Route_Values')
    ALTER TABLE dbo.PageMaster ADD Route_Values NVARCHAR(200) NULL;   -- query string, e.g. moduleCode=OPD
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PageMaster') AND name = 'Link_Target')
    ALTER TABLE dbo.PageMaster ADD Link_Target NVARCHAR(20) NULL;     -- e.g. _blank
GO

-- ── PageEndpointMap: Page_ID nullable (unmapped endpoints) + scan bookkeeping ──
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PageEndpointMap') AND name = 'Page_ID' AND is_nullable = 0)
BEGIN
    DECLARE @fk SYSNAME = (
        SELECT fk.name FROM sys.foreign_keys fk
        INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
        WHERE fk.parent_object_id = OBJECT_ID('dbo.PageEndpointMap') AND c.name = 'Page_ID');
    IF @fk IS NOT NULL EXEC('ALTER TABLE dbo.PageEndpointMap DROP CONSTRAINT [' + @fk + ']');
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PageEndpointMap_Page' AND object_id = OBJECT_ID('dbo.PageEndpointMap'))
        DROP INDEX IX_PageEndpointMap_Page ON dbo.PageEndpointMap;

    ALTER TABLE dbo.PageEndpointMap ALTER COLUMN Page_ID INT NULL;

    ALTER TABLE dbo.PageEndpointMap ADD CONSTRAINT FK_PageEndpointMap_Page FOREIGN KEY (Page_ID) REFERENCES dbo.PageMaster(Page_ID);
    CREATE INDEX IX_PageEndpointMap_Page ON dbo.PageEndpointMap(Page_ID);
    PRINT 'PageEndpointMap.Page_ID is now nullable (NULL = unmapped).';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PageEndpointMap') AND name = 'Source')
    ALTER TABLE dbo.PageEndpointMap ADD Source VARCHAR(10) NOT NULL CONSTRAINT DF_PageEndpointMap_Source DEFAULT 'MANUAL'; -- SEED | SCAN | MANUAL
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PageEndpointMap') AND name = 'Discovered_On')
    ALTER TABLE dbo.PageEndpointMap ADD Discovered_On DATETIME2 NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PageEndpointMap') AND name = 'Last_Seen_On')
    ALTER TABLE dbo.PageEndpointMap ADD Last_Seen_On DATETIME2 NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PageEndpointMap') AND name = 'Is_Orphaned')
    ALTER TABLE dbo.PageEndpointMap ADD Is_Orphaned BIT NOT NULL CONSTRAINT DF_PageEndpointMap_Is_Orphaned DEFAULT 0;
GO

-- ── Super admin flag: exactly today's hard-coded rule, now as data ─────────
UPDATE dbo.Users
   SET IsSuperAdmin = 1
 WHERE IsSuperAdmin = 0
   AND (Username = 'admin' OR Role IN ('Super Admin', 'SuperAdmin'));
PRINT 'Users.IsSuperAdmin backfilled from the existing super admin rule.';
GO

-- ── Role assignment changes take effect at once, whichever screen made them ──
CREATE OR ALTER TRIGGER dbo.trg_Userroles_BumpPermissionVersion
ON dbo.Userroles
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE u SET u.Permission_Version = u.Permission_Version + 1
    FROM dbo.Users u
    WHERE u.Id IN (SELECT UserId FROM inserted UNION SELECT UserId FROM deleted);
END;
GO

-- ── PageMaster upsert, now with icon / route values / target ───────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_PageMaster_Upsert
    @CompanyId    INT,
    @Menu_ID      INT = NULL,
    @Page_Code    NVARCHAR(150),
    @Title        NVARCHAR(150),
    @Controller   NVARCHAR(100),
    @Action       NVARCHAR(100),
    @Area         NVARCHAR(100) = NULL,
    @Show_In_Menu BIT = 1,
    @Sort_Order   INT = 0,
    @Icon         NVARCHAR(100) = NULL,
    @Route_Values NVARCHAR(200) = NULL,
    @Link_Target  NVARCHAR(20) = NULL,
    @UserId       INT = NULL,
    @Page_ID      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @Page_ID = NULL;
    SELECT @Page_ID = Page_ID FROM dbo.PageMaster WHERE Page_Code = @Page_Code AND CompanyId = @CompanyId;

    IF @Page_ID IS NULL
    BEGIN
        INSERT INTO dbo.PageMaster (CompanyId, Menu_ID, Page_Code, Title, Controller, Action, Area, Show_In_Menu, Sort_Order,
                                    Icon, Route_Values, Link_Target, CreatedBy)
        VALUES (@CompanyId, @Menu_ID, @Page_Code, @Title, @Controller, @Action, @Area, @Show_In_Menu, @Sort_Order,
                @Icon, @Route_Values, @Link_Target, @UserId);
        SET @Page_ID = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.PageMaster
           SET Menu_ID = @Menu_ID, Title = @Title, Controller = @Controller, Action = @Action, Area = @Area,
               Show_In_Menu = @Show_In_Menu, Sort_Order = @Sort_Order, Icon = @Icon,
               Route_Values = @Route_Values, Link_Target = @Link_Target,
               ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE Page_ID = @Page_ID;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.PageControlMaster WHERE Page_ID = @Page_ID AND Control_Code = 'VIEW')
        INSERT INTO dbo.PageControlMaster (Page_ID, Control_Code, Title, Sort_Order, CreatedBy)
        VALUES (@Page_ID, 'VIEW', 'Open the screen and its list', 0, @UserId);
END;
GO

-- ── Every active endpoint row, with its page / control codes (app-side cache) ──
CREATE OR ALTER PROCEDURE dbo.usp_Auth_GetEndpointMap
    @App VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.Endpoint_ID, e.App, e.Http_Method, e.Controller, e.Action, e.Route,
           e.Page_ID, p.Page_Code, e.Control_ID, c.Control_Code
    FROM dbo.PageEndpointMap e
    LEFT JOIN dbo.PageMaster p ON p.Page_ID = e.Page_ID AND p.IsActive = 1
    LEFT JOIN dbo.PageControlMaster c ON c.Control_ID = e.Control_ID AND c.IsActive = 1
    WHERE e.IsActive = 1 AND (@App IS NULL OR e.App = @App);
END;
GO

-- ── The navigation tree to render (RS1 menus, RS2 pages) ────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_GetNavTree
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Menu_ID, Parent_Menu_ID, Menu_Type, Menu_Code, Title, Icon, Sort_Order
    FROM dbo.MenuMaster
    WHERE CompanyId = @CompanyId AND IsActive = 1
    ORDER BY Sort_Order, Menu_ID;

    SELECT Page_ID, Menu_ID, Page_Code, Title, Controller, Action, Area, Icon, Route_Values, Link_Target, Sort_Order
    FROM dbo.PageMaster
    WHERE CompanyId = @CompanyId AND IsActive = 1 AND Show_In_Menu = 1
    ORDER BY Sort_Order, Page_ID;
END;
GO

-- ── Cheap staleness check: one indexed row per call ────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_GetPermissionVersion
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Permission_Version, IsSuperAdmin, IsActive FROM dbo.Users WHERE Id = @UserId;
END;
GO

-- ── The resolution engine, now aware of the session's active role ──────────
--   @RoleId set  -> only that role counts (it must be one the user holds for the branch);
--                   Only Super Admin bypasses; the Administrator role is granted like any other role.
--   @RoleId NULL -> every role the user holds for the branch, Deny winning on conflict.
--   Users.IsSuperAdmin always bypasses.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_GetEffectivePermissions
    @UserId    INT,
    @BranchId  INT,
    @CompanyId INT = NULL,
    @RoleId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IsBypass BIT = 0, @Company INT;

    SELECT @IsBypass = CASE WHEN u.IsSuperAdmin = 1 THEN 1 ELSE 0 END,
           @Company  = ISNULL(@CompanyId, ISNULL(u.CompanyId, 1))
    FROM dbo.Users u WHERE u.Id = @UserId AND u.IsActive = 1;

    IF @Company IS NULL
    BEGIN
        -- unknown or inactive user: nothing at all
        SELECT CAST(NULL AS NVARCHAR(150)) AS Page_Code, CAST(NULL AS INT) AS Page_ID, CAST(NULL AS VARCHAR(30)) AS Control_Code,
               CAST(NULL AS INT) AS Control_ID, CAST(NULL AS CHAR(1)) AS Permission, CAST(NULL AS INT) AS Decided_At_Scope,
               CAST(NULL AS VARCHAR(10)) AS Decided_By
        WHERE 1 = 0;
        RETURN;
    END

    -- The roles that count for this request.
    IF OBJECT_ID('tempdb..#MyRoles') IS NOT NULL DROP TABLE #MyRoles;
    SELECT DISTINCT ur.RoleId
    INTO #MyRoles
    FROM dbo.Userroles ur
    WHERE ur.UserId = @UserId AND ur.IsActive = 1
      AND (ur.Branch_ID IS NULL OR ur.Branch_ID = @BranchId)
      AND (@RoleId IS NULL OR ur.RoleId = @RoleId);


    IF @IsBypass = 1
    BEGIN
        SELECT pg.Page_Code, pg.Page_ID, pc.Control_Code, pc.Control_ID,
               CAST('A' AS CHAR(1)) AS Permission, 99 AS Decided_At_Scope, CAST('BYPASS' AS VARCHAR(10)) AS Decided_By
        FROM dbo.PageMaster pg
        INNER JOIN dbo.PageControlMaster pc ON pc.Page_ID = pg.Page_ID AND pc.IsActive = 1
        WHERE pg.IsActive = 1 AND pg.CompanyId = @Company;
        DROP TABLE #MyRoles;
        RETURN;
    END

    -- Ancestor chain: the sub-menu / menu / nav item each page sits under.
    IF OBJECT_ID('tempdb..#Result') IS NOT NULL DROP TABLE #Result;
    SELECT
        pg.Page_ID, pg.Page_Code, pc.Control_ID, pc.Control_Code,
        CASE WHEN m1.Menu_Type = 'SUBMENU' THEN m1.Menu_ID END AS Submenu_ID,
        CASE WHEN m1.Menu_Type = 'MENU' THEN m1.Menu_ID
             WHEN m1.Menu_Type = 'SUBMENU' THEN m2.Menu_ID END AS Menu_ID,
        CASE WHEN m1.Menu_Type = 'NAV' THEN m1.Menu_ID
             WHEN m1.Menu_Type = 'MENU' THEN m2.Menu_ID
             WHEN m1.Menu_Type = 'SUBMENU' THEN m3.Menu_ID END AS Nav_ID,
        CAST(NULL AS CHAR(1)) AS Permission,
        CAST(NULL AS INT) AS Decided_At_Scope,
        CAST(NULL AS VARCHAR(10)) AS Decided_By
    INTO #Result
    FROM dbo.PageMaster pg
    INNER JOIN dbo.PageControlMaster pc ON pc.Page_ID = pg.Page_ID AND pc.IsActive = 1
    LEFT JOIN dbo.MenuMaster m1 ON m1.Menu_ID = pg.Menu_ID AND m1.IsActive = 1
    LEFT JOIN dbo.MenuMaster m2 ON m2.Menu_ID = m1.Parent_Menu_ID AND m2.IsActive = 1
    LEFT JOIN dbo.MenuMaster m3 ON m3.Menu_ID = m2.Parent_Menu_ID AND m3.IsActive = 1
    WHERE pg.IsActive = 1 AND pg.CompanyId = @Company;

    -- Scope ladder, innermost first; a row already answered is never touched again.
    -- A user row beats a role row at the same scope; across the user's roles, Deny wins.
    -- Scopes 3-7 answer VIEW only: sensitive controls are granted by their own row, never by a broad stroke.

    -- 1. control - user
    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 5, Decided_By = 'USER'
    FROM #Result r CROSS APPLY (
        SELECT TOP 1 up.Permission FROM dbo.UserPermission up
        WHERE up.User_ID = @UserId AND up.Page_ID = r.Page_ID AND up.Control_ID = r.Control_ID
          AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END) x
    WHERE r.Permission IS NULL;

    -- 2. control - role
    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 5, Decided_By = 'ROLE'
    FROM #Result r CROSS APPLY (
        SELECT CASE WHEN SUM(CASE WHEN rp.Permission = 'D' THEN 1 ELSE 0 END) > 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Page_ID = r.Page_ID AND rp.Control_ID = r.Control_ID
          AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0) x
    WHERE r.Permission IS NULL;

    -- A control other than VIEW that no control row decided is denied here: broad grants never hand out actions.
    UPDATE #Result SET Permission = 'D', Decided_At_Scope = 0, Decided_By = 'NONE'
    WHERE Permission IS NULL AND Control_Code <> 'VIEW';

    -- 3. page - user
    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 4, Decided_By = 'USER'
    FROM #Result r CROSS APPLY (
        SELECT TOP 1 up.Permission FROM dbo.UserPermission up
        WHERE up.User_ID = @UserId AND up.Page_ID = r.Page_ID AND up.Control_ID IS NULL
          AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END) x
    WHERE r.Permission IS NULL;

    -- 4. page - role
    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 4, Decided_By = 'ROLE'
    FROM #Result r CROSS APPLY (
        SELECT CASE WHEN SUM(CASE WHEN rp.Permission = 'D' THEN 1 ELSE 0 END) > 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Page_ID = r.Page_ID AND rp.Control_ID IS NULL
          AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0) x
    WHERE r.Permission IS NULL;

    -- 5. sub-menu - user, then role
    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 3, Decided_By = 'USER'
    FROM #Result r CROSS APPLY (
        SELECT TOP 1 up.Permission FROM dbo.UserPermission up
        WHERE up.User_ID = @UserId AND up.Menu_ID = r.Submenu_ID
          AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END) x
    WHERE r.Permission IS NULL AND r.Submenu_ID IS NOT NULL;

    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 3, Decided_By = 'ROLE'
    FROM #Result r CROSS APPLY (
        SELECT CASE WHEN SUM(CASE WHEN rp.Permission = 'D' THEN 1 ELSE 0 END) > 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Menu_ID = r.Submenu_ID
          AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0) x
    WHERE r.Permission IS NULL AND r.Submenu_ID IS NOT NULL;

    -- 6. menu - user, then role
    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 2, Decided_By = 'USER'
    FROM #Result r CROSS APPLY (
        SELECT TOP 1 up.Permission FROM dbo.UserPermission up
        WHERE up.User_ID = @UserId AND up.Menu_ID = r.Menu_ID
          AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END) x
    WHERE r.Permission IS NULL AND r.Menu_ID IS NOT NULL;

    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 2, Decided_By = 'ROLE'
    FROM #Result r CROSS APPLY (
        SELECT CASE WHEN SUM(CASE WHEN rp.Permission = 'D' THEN 1 ELSE 0 END) > 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Menu_ID = r.Menu_ID
          AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0) x
    WHERE r.Permission IS NULL AND r.Menu_ID IS NOT NULL;

    -- 7. nav bar item - user, then role
    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 1, Decided_By = 'USER'
    FROM #Result r CROSS APPLY (
        SELECT TOP 1 up.Permission FROM dbo.UserPermission up
        WHERE up.User_ID = @UserId AND up.Menu_ID = r.Nav_ID
          AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END) x
    WHERE r.Permission IS NULL AND r.Nav_ID IS NOT NULL;

    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 1, Decided_By = 'ROLE'
    FROM #Result r CROSS APPLY (
        SELECT CASE WHEN SUM(CASE WHEN rp.Permission = 'D' THEN 1 ELSE 0 END) > 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Menu_ID = r.Nav_ID
          AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0) x
    WHERE r.Permission IS NULL AND r.Nav_ID IS NOT NULL;

    -- Nothing anywhere = denied.
    UPDATE #Result SET Permission = 'D', Decided_At_Scope = 0, Decided_By = 'NONE' WHERE Permission IS NULL;

    -- Controls still need their page: an allowed action on a page the user cannot open does nothing.
    UPDATE r SET Permission = 'D', Decided_At_Scope = 4, Decided_By = 'PAGE'
    FROM #Result r
    INNER JOIN #Result v ON v.Page_ID = r.Page_ID AND v.Control_Code = 'VIEW'
    WHERE r.Control_Code <> 'VIEW' AND r.Permission = 'A' AND v.Permission = 'D';

    SELECT Page_Code, Page_ID, Control_Code, Control_ID, Permission, Decided_At_Scope, Decided_By
    FROM #Result
    ORDER BY Page_Code, Control_Code;

    DROP TABLE #MyRoles;
    DROP TABLE #Result;
END;
GO

PRINT 'Script 2161 applied: authorization model refinements ready.';
GO
