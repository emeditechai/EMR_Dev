-- ============================================================================
-- Migration: 2160_authorization_procedures.sql
-- Description:
--   Server-Side Authorization Blueprint - Phase 1 continued: the resolution
--   engine and the CRUD/upsert procedures needed to build and maintain the tree.
--
--   usp_Auth_GetEffectivePermissions returns, for one user + branch, every
--   (Page_Code, Control_Code) with its effective Permission, resolved exactly
--   per the seven-row priority table in the blueprint:
--     1 Control  User    2 Control  Role
--     3 Page     User    4 Page     Role
--     5 Sub-menu User, then role
--     6 Menu     User, then role
--     7 Nav item User, then role
--     0 nothing anywhere -> Denied
--   Only Super Admin (Users.IsSuperAdmin) bypasses this model: those accounts skip it
--   entirely and are answered Allow before any of it is read.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ────────────────────────────────────────────────────────────────────────────
-- MenuMaster upsert (matched by Menu_Code + CompanyId) - used by the seed script
-- and, later, the Menu & Page Master admin screen.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_MenuMaster_Upsert
    @CompanyId      INT,
    @Parent_Menu_ID INT = NULL,
    @Menu_Type      VARCHAR(10),
    @Menu_Code      NVARCHAR(100),
    @Title          NVARCHAR(150),
    @Icon           NVARCHAR(100) = NULL,
    @Sort_Order     INT = 0,
    @UserId         INT = NULL,
    @Menu_ID        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @Menu_ID = NULL;
    SELECT @Menu_ID = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = @Menu_Code AND CompanyId = @CompanyId;

    IF @Menu_ID IS NULL
    BEGIN
        INSERT INTO dbo.MenuMaster (CompanyId, Parent_Menu_ID, Menu_Type, Menu_Code, Title, Icon, Sort_Order, CreatedBy)
        VALUES (@CompanyId, @Parent_Menu_ID, @Menu_Type, @Menu_Code, @Title, @Icon, @Sort_Order, @UserId);
        SET @Menu_ID = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.MenuMaster
           SET Parent_Menu_ID = @Parent_Menu_ID, Menu_Type = @Menu_Type, Title = @Title,
               Icon = @Icon, Sort_Order = @Sort_Order, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE Menu_ID = @Menu_ID;
    END
END;
GO

-- ────────────────────────────────────────────────────────────────────────────
-- PageMaster upsert (matched by Page_Code + CompanyId)
-- ────────────────────────────────────────────────────────────────────────────
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
    @UserId       INT = NULL,
    @Page_ID      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @Page_ID = NULL;
    SELECT @Page_ID = Page_ID FROM dbo.PageMaster WHERE Page_Code = @Page_Code AND CompanyId = @CompanyId;

    IF @Page_ID IS NULL
    BEGIN
        INSERT INTO dbo.PageMaster (CompanyId, Menu_ID, Page_Code, Title, Controller, Action, Area, Show_In_Menu, Sort_Order, CreatedBy)
        VALUES (@CompanyId, @Menu_ID, @Page_Code, @Title, @Controller, @Action, @Area, @Show_In_Menu, @Sort_Order, @UserId);
        SET @Page_ID = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.PageMaster
           SET Menu_ID = @Menu_ID, Title = @Title, Controller = @Controller, Action = @Action,
               Area = @Area, Show_In_Menu = @Show_In_Menu, Sort_Order = @Sort_Order,
               ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE Page_ID = @Page_ID;
    END

    -- Every page always has a VIEW control - how the screen is opened.
    IF NOT EXISTS (SELECT 1 FROM dbo.PageControlMaster WHERE Page_ID = @Page_ID AND Control_Code = 'VIEW')
        INSERT INTO dbo.PageControlMaster (Page_ID, Control_Code, Title, Sort_Order, CreatedBy)
        VALUES (@Page_ID, 'VIEW', 'View / open this page', 0, @UserId);
END;
GO

-- ────────────────────────────────────────────────────────────────────────────
-- PageControlMaster upsert (matched by Page_ID + Control_Code)
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_PageControlMaster_Upsert
    @Page_ID      INT,
    @Control_Code VARCHAR(30),
    @Title        NVARCHAR(150),
    @Sort_Order   INT = 0,
    @UserId       INT = NULL,
    @Control_ID   INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @Control_ID = NULL;
    SELECT @Control_ID = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @Page_ID AND Control_Code = @Control_Code;

    IF @Control_ID IS NULL
    BEGIN
        INSERT INTO dbo.PageControlMaster (Page_ID, Control_Code, Title, Sort_Order, CreatedBy)
        VALUES (@Page_ID, @Control_Code, @Title, @Sort_Order, @UserId);
        SET @Control_ID = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.PageControlMaster
           SET Title = @Title, Sort_Order = @Sort_Order, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE Control_ID = @Control_ID;
    END
END;
GO

-- ────────────────────────────────────────────────────────────────────────────
-- PageEndpointMap upsert (matched by App + Http_Method + Controller + Action -
-- "one endpoint, one meaning"). Used by the discovery scanner and by hand for
-- the endpoints mapped ahead of it.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_PageEndpointMap_Upsert
    @Page_ID     INT,
    @Control_ID  INT = NULL,
    @App         VARCHAR(10),
    @Http_Method VARCHAR(10),
    @Controller  NVARCHAR(150),
    @Action      NVARCHAR(150),
    @Route       NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.PageEndpointMap WHERE App = @App AND Http_Method = @Http_Method AND Controller = @Controller AND Action = @Action)
    BEGIN
        UPDATE dbo.PageEndpointMap
           SET Page_ID = @Page_ID, Control_ID = @Control_ID, Route = @Route, IsActive = 1
         WHERE App = @App AND Http_Method = @Http_Method AND Controller = @Controller AND Action = @Action;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.PageEndpointMap (Page_ID, Control_ID, App, Http_Method, Controller, Action, Route)
        VALUES (@Page_ID, @Control_ID, @App, @Http_Method, @Controller, @Action, @Route);
    END
END;
GO

-- ────────────────────────────────────────────────────────────────────────────
-- RolePermission upsert - writes the grant and its audit row together.
-- Set exactly one of @Menu_ID / @Page_ID; @Control_ID only with @Page_ID.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_RolePermission_Upsert
    @Role_ID     INT,
    @Menu_ID     INT = NULL,
    @Page_ID     INT = NULL,
    @Control_ID  INT = NULL,
    @Branch_ID   INT = NULL,
    @Permission  CHAR(1),
    @CompanyId   INT,
    @Reason      NVARCHAR(500) = NULL,
    @ChangedBy   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Permission NOT IN ('A', 'D')
    BEGIN
        RAISERROR('Permission must be A (Allow) or D (Deny).', 16, 1);
        RETURN;
    END
    IF (@Menu_ID IS NULL AND @Page_ID IS NULL) OR (@Menu_ID IS NOT NULL AND @Page_ID IS NOT NULL)
    BEGIN
        RAISERROR('A permission applies to one thing: a menu item (nav/menu/sub-menu) or a page.', 16, 1);
        RETURN;
    END
    IF @Menu_ID IS NOT NULL AND @Control_ID IS NOT NULL
    BEGIN
        RAISERROR('Controls belong to a page, not a menu item.', 16, 1);
        RETURN;
    END

    DECLARE @MenuKey INT = ISNULL(@Menu_ID, 0), @PageKey INT = ISNULL(@Page_ID, 0),
            @ControlKey INT = ISNULL(@Control_ID, 0), @BranchKey INT = ISNULL(@Branch_ID, 0);
    DECLARE @OldValue CHAR(1);

    SELECT @OldValue = Permission FROM dbo.RolePermission
     WHERE Role_ID = @Role_ID AND Menu_Key = @MenuKey AND Page_Key = @PageKey AND Control_Key = @ControlKey AND Branch_Key = @BranchKey;

    IF @OldValue IS NULL
    BEGIN
        INSERT INTO dbo.RolePermission (Role_ID, Menu_ID, Page_ID, Control_ID, Branch_ID, Permission, CompanyId, Reason, CreatedBy)
        VALUES (@Role_ID, @Menu_ID, @Page_ID, @Control_ID, @Branch_ID, @Permission, @CompanyId, @Reason, @ChangedBy);
    END
    ELSE IF @OldValue <> @Permission
    BEGIN
        UPDATE dbo.RolePermission
           SET Permission = @Permission, Reason = @Reason, ModifiedBy = @ChangedBy, ModifiedDate = GETDATE()
         WHERE Role_ID = @Role_ID AND Menu_Key = @MenuKey AND Page_Key = @PageKey AND Control_Key = @ControlKey AND Branch_Key = @BranchKey;
    END

    IF @OldValue IS NULL OR @OldValue <> @Permission
    BEGIN
        INSERT INTO dbo.PermissionAuditLog (Entity, Target_ID, Menu_ID, Page_ID, Control_ID, Branch_ID, Old_Value, New_Value, Changed_By, Reason)
        VALUES ('ROLE', @Role_ID, @Menu_ID, @Page_ID, @Control_ID, @Branch_ID, @OldValue, @Permission, @ChangedBy, @Reason);

        -- Everyone holding this role sees the change on their very next request.
        UPDATE u SET u.Permission_Version = u.Permission_Version + 1
        FROM dbo.Users u
        INNER JOIN dbo.Userroles ur ON ur.UserId = u.Id AND ur.RoleId = @Role_ID AND ur.IsActive = 1;
    END
END;
GO

-- ────────────────────────────────────────────────────────────────────────────
-- UserPermission upsert - one person's exception, same rules, own audit trail.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_UserPermission_Upsert
    @User_ID     INT,
    @Menu_ID     INT = NULL,
    @Page_ID     INT = NULL,
    @Control_ID  INT = NULL,
    @Branch_ID   INT = NULL,
    @Permission  CHAR(1),
    @Reason      NVARCHAR(500) = NULL,
    @ChangedBy   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Permission NOT IN ('A', 'D')
    BEGIN
        RAISERROR('Permission must be A (Allow) or D (Deny).', 16, 1);
        RETURN;
    END
    IF (@Menu_ID IS NULL AND @Page_ID IS NULL) OR (@Menu_ID IS NOT NULL AND @Page_ID IS NOT NULL)
    BEGIN
        RAISERROR('A permission applies to one thing: a menu item (nav/menu/sub-menu) or a page.', 16, 1);
        RETURN;
    END
    IF @Menu_ID IS NOT NULL AND @Control_ID IS NOT NULL
    BEGIN
        RAISERROR('Controls belong to a page, not a menu item.', 16, 1);
        RETURN;
    END
    IF @Permission = 'D' AND (LEN(ISNULL(@Reason, '')) < 10)
    BEGIN
        RAISERROR('Give a short reason (at least 10 characters) for this deny.', 16, 1);
        RETURN;
    END

    DECLARE @MenuKey INT = ISNULL(@Menu_ID, 0), @PageKey INT = ISNULL(@Page_ID, 0),
            @ControlKey INT = ISNULL(@Control_ID, 0), @BranchKey INT = ISNULL(@Branch_ID, 0);
    DECLARE @OldValue CHAR(1);

    SELECT @OldValue = Permission FROM dbo.UserPermission
     WHERE User_ID = @User_ID AND Menu_Key = @MenuKey AND Page_Key = @PageKey AND Control_Key = @ControlKey AND Branch_Key = @BranchKey;

    IF @OldValue IS NULL
    BEGIN
        INSERT INTO dbo.UserPermission (User_ID, Menu_ID, Page_ID, Control_ID, Branch_ID, Permission, Reason, CreatedBy)
        VALUES (@User_ID, @Menu_ID, @Page_ID, @Control_ID, @Branch_ID, @Permission, @Reason, @ChangedBy);
    END
    ELSE IF @OldValue <> @Permission
    BEGIN
        UPDATE dbo.UserPermission
           SET Permission = @Permission, Reason = @Reason, ModifiedBy = @ChangedBy, ModifiedDate = GETDATE()
         WHERE User_ID = @User_ID AND Menu_Key = @MenuKey AND Page_Key = @PageKey AND Control_Key = @ControlKey AND Branch_Key = @BranchKey;
    END

    IF @OldValue IS NULL OR @OldValue <> @Permission
    BEGIN
        INSERT INTO dbo.PermissionAuditLog (Entity, Target_ID, Menu_ID, Page_ID, Control_ID, Branch_ID, Old_Value, New_Value, Changed_By, Reason)
        VALUES ('USER', @User_ID, @Menu_ID, @Page_ID, @Control_ID, @Branch_ID, @OldValue, @Permission, @ChangedBy, @Reason);

        UPDATE dbo.Users SET Permission_Version = Permission_Version + 1 WHERE Id = @User_ID;
    END
END;
GO

-- ────────────────────────────────────────────────────────────────────────────
-- Remove a user override (back to "Inherit" from the role).
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_UserPermission_Clear
    @User_ID    INT,
    @Menu_ID    INT = NULL,
    @Page_ID    INT = NULL,
    @Control_ID INT = NULL,
    @Branch_ID  INT = NULL,
    @ChangedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @MenuKey INT = ISNULL(@Menu_ID, 0), @PageKey INT = ISNULL(@Page_ID, 0),
            @ControlKey INT = ISNULL(@Control_ID, 0), @BranchKey INT = ISNULL(@Branch_ID, 0);
    DECLARE @OldValue CHAR(1);

    SELECT @OldValue = Permission FROM dbo.UserPermission
     WHERE User_ID = @User_ID AND Menu_Key = @MenuKey AND Page_Key = @PageKey AND Control_Key = @ControlKey AND Branch_Key = @BranchKey;

    IF @OldValue IS NOT NULL
    BEGIN
        DELETE FROM dbo.UserPermission
         WHERE User_ID = @User_ID AND Menu_Key = @MenuKey AND Page_Key = @PageKey AND Control_Key = @ControlKey AND Branch_Key = @BranchKey;

        INSERT INTO dbo.PermissionAuditLog (Entity, Target_ID, Menu_ID, Page_ID, Control_ID, Branch_ID, Old_Value, New_Value, Changed_By, Reason)
        VALUES ('USER', @User_ID, @Menu_ID, @Page_ID, @Control_ID, @Branch_ID, @OldValue, NULL, @ChangedBy, 'Reverted to inherit from role');

        UPDATE dbo.Users SET Permission_Version = Permission_Version + 1 WHERE Id = @User_ID;
    END
END;
GO

-- ────────────────────────────────────────────────────────────────────────────
-- The resolution engine.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_GetEffectivePermissions
    @UserId    INT,
    @BranchId  INT,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IsBypass BIT = 0;
    DECLARE @Company INT;

    SELECT @IsBypass = CASE WHEN u.IsSuperAdmin = 1 THEN 1 ELSE 0 END,
           @Company = ISNULL(@CompanyId, u.CompanyId)
    FROM dbo.Users u WHERE u.Id = @UserId;

    -- ── Super Admin (Users.IsSuperAdmin) only: allow everything, before anything else is read ──
    IF @IsBypass = 1
    BEGIN
        SELECT
            pg.Page_Code, pg.Page_ID, pc.Control_Code, pc.Control_ID,
            'A' AS Permission, 99 AS Decided_At_Scope, 'BYPASS' AS Decided_By
        FROM dbo.PageMaster pg
        INNER JOIN dbo.PageControlMaster pc ON pc.Page_ID = pg.Page_ID AND pc.IsActive = 1
        WHERE pg.IsActive = 1 AND pg.CompanyId = @Company;
        RETURN;
    END

    -- ── Ancestor chain for every page: submenu / menu / nav item it sits under ──
    IF OBJECT_ID('tempdb..#Chain') IS NOT NULL DROP TABLE #Chain;
    SELECT
        pg.Page_ID,
        CASE WHEN m1.Menu_Type = 'SUBMENU' THEN m1.Menu_ID END AS Submenu_ID,
        CASE WHEN m1.Menu_Type = 'MENU' THEN m1.Menu_ID
             WHEN m1.Menu_Type = 'SUBMENU' THEN m2.Menu_ID END AS Menu_ID2,
        CASE WHEN m1.Menu_Type = 'NAV' THEN m1.Menu_ID
             WHEN m1.Menu_Type = 'MENU' THEN m2.Menu_ID
             WHEN m1.Menu_Type = 'SUBMENU' THEN m3.Menu_ID END AS Nav_ID
    INTO #Chain
    FROM dbo.PageMaster pg
    LEFT JOIN dbo.MenuMaster m1 ON m1.Menu_ID = pg.Menu_ID
    LEFT JOIN dbo.MenuMaster m2 ON m2.Menu_ID = m1.Parent_Menu_ID
    LEFT JOIN dbo.MenuMaster m3 ON m3.Menu_ID = m2.Parent_Menu_ID
    WHERE pg.IsActive = 1 AND pg.CompanyId = @Company;

    -- ── The user's roles for this branch (their own branch grant, or an all-branch grant) ──
    IF OBJECT_ID('tempdb..#MyRoles') IS NOT NULL DROP TABLE #MyRoles;
    SELECT DISTINCT ur.RoleId
    INTO #MyRoles
    FROM dbo.Userroles ur
    WHERE ur.UserId = @UserId AND ur.IsActive = 1 AND (ur.Branch_ID IS NULL OR ur.Branch_ID = @BranchId);

    -- ── Every (page, control) this company has, seeded with "no answer yet" ──
    IF OBJECT_ID('tempdb..#Result') IS NOT NULL DROP TABLE #Result;
    SELECT
        pg.Page_ID, pg.Page_Code, pc.Control_ID, pc.Control_Code,
        c.Submenu_ID, c.Menu_ID2 AS Menu_ID, c.Nav_ID,
        CAST(NULL AS CHAR(1)) AS Permission,
        CAST(NULL AS TINYINT) AS Decided_At_Scope,
        CAST(NULL AS VARCHAR(10)) AS Decided_By
    INTO #Result
    FROM dbo.PageMaster pg
    INNER JOIN dbo.PageControlMaster pc ON pc.Page_ID = pg.Page_ID AND pc.IsActive = 1
    INNER JOIN #Chain c ON c.Page_ID = pg.Page_ID
    WHERE pg.IsActive = 1 AND pg.CompanyId = @Company;

    -- Scope 1: control - user
    UPDATE r SET r.Permission = up.Permission, r.Decided_At_Scope = 1, r.Decided_By = 'USER'
    FROM #Result r
    CROSS APPLY (
        SELECT TOP 1 up.Permission FROM dbo.UserPermission up
        WHERE up.User_ID = @UserId AND up.Page_ID = r.Page_ID AND up.Control_ID = r.Control_ID
          AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END
    ) up
    WHERE r.Permission IS NULL;

    -- Scope 2: control - role (deny beats allow across the user's roles at this scope)
    UPDATE r SET r.Permission = x.Permission, r.Decided_At_Scope = 2, r.Decided_By = 'ROLE'
    FROM #Result r
    CROSS APPLY (
        SELECT TOP 1 CASE WHEN MIN(CASE WHEN rp.Permission = 'D' THEN 0 ELSE 1 END) = 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp
        INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Page_ID = r.Page_ID AND rp.Control_ID = r.Control_ID
          AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0
    ) x
    WHERE r.Permission IS NULL;

    -- Scope 3: page - user (Control_ID IS NULL row = the page itself)
    UPDATE r SET r.Permission = up.Permission, r.Decided_At_Scope = 3, r.Decided_By = 'USER'
    FROM #Result r
    CROSS APPLY (
        SELECT TOP 1 up.Permission FROM dbo.UserPermission up
        WHERE up.User_ID = @UserId AND up.Page_ID = r.Page_ID AND up.Control_ID IS NULL
          AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END
    ) up
    WHERE r.Permission IS NULL;

    -- Scope 4: page - role
    UPDATE r SET r.Permission = x.Permission, r.Decided_At_Scope = 4, r.Decided_By = 'ROLE'
    FROM #Result r
    CROSS APPLY (
        SELECT TOP 1 CASE WHEN MIN(CASE WHEN rp.Permission = 'D' THEN 0 ELSE 1 END) = 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp
        INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Page_ID = r.Page_ID AND rp.Control_ID IS NULL
          AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0
    ) x
    WHERE r.Permission IS NULL;

    -- Scope 5: sub-menu - user, then role
    UPDATE r SET r.Permission = up.Permission, r.Decided_At_Scope = 5, r.Decided_By = 'USER'
    FROM #Result r
    CROSS APPLY (
        SELECT TOP 1 up.Permission FROM dbo.UserPermission up
        WHERE up.User_ID = @UserId AND up.Menu_ID = r.Submenu_ID
          AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END
    ) up
    WHERE r.Permission IS NULL AND r.Submenu_ID IS NOT NULL;

    UPDATE r SET r.Permission = x.Permission, r.Decided_At_Scope = 5, r.Decided_By = 'ROLE'
    FROM #Result r
    CROSS APPLY (
        SELECT TOP 1 CASE WHEN MIN(CASE WHEN rp.Permission = 'D' THEN 0 ELSE 1 END) = 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp
        INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Menu_ID = r.Submenu_ID
          AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0
    ) x
    WHERE r.Permission IS NULL AND r.Submenu_ID IS NOT NULL;

    -- Scope 6: menu - user, then role
    UPDATE r SET r.Permission = up.Permission, r.Decided_At_Scope = 6, r.Decided_By = 'USER'
    FROM #Result r
    CROSS APPLY (
        SELECT TOP 1 up.Permission FROM dbo.UserPermission up
        WHERE up.User_ID = @UserId AND up.Menu_ID = r.Menu_ID
          AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END
    ) up
    WHERE r.Permission IS NULL AND r.Menu_ID IS NOT NULL;

    UPDATE r SET r.Permission = x.Permission, r.Decided_At_Scope = 6, r.Decided_By = 'ROLE'
    FROM #Result r
    CROSS APPLY (
        SELECT TOP 1 CASE WHEN MIN(CASE WHEN rp.Permission = 'D' THEN 0 ELSE 1 END) = 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp
        INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Menu_ID = r.Menu_ID
          AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0
    ) x
    WHERE r.Permission IS NULL AND r.Menu_ID IS NOT NULL;

    -- Scope 7: nav bar item - user, then role
    UPDATE r SET r.Permission = up.Permission, r.Decided_At_Scope = 7, r.Decided_By = 'USER'
    FROM #Result r
    CROSS APPLY (
        SELECT TOP 1 up.Permission FROM dbo.UserPermission up
        WHERE up.User_ID = @UserId AND up.Menu_ID = r.Nav_ID
          AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END
    ) up
    WHERE r.Permission IS NULL AND r.Nav_ID IS NOT NULL;

    UPDATE r SET r.Permission = x.Permission, r.Decided_At_Scope = 7, r.Decided_By = 'ROLE'
    FROM #Result r
    CROSS APPLY (
        SELECT TOP 1 CASE WHEN MIN(CASE WHEN rp.Permission = 'D' THEN 0 ELSE 1 END) = 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp
        INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Menu_ID = r.Nav_ID
          AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0
    ) x
    WHERE r.Permission IS NULL AND r.Nav_ID IS NOT NULL;

    -- Nothing anywhere = denied.
    UPDATE #Result SET Permission = 'D', Decided_At_Scope = 0, Decided_By = 'NONE' WHERE Permission IS NULL;

    SELECT Page_Code, Page_ID, Control_Code, Control_ID, Permission, Decided_At_Scope, Decided_By
    FROM #Result
    ORDER BY Page_Code, Control_Code;

    DROP TABLE #Chain;
    DROP TABLE #MyRoles;
    DROP TABLE #Result;
END;
GO

PRINT 'Script 2160 applied: authorization upsert procedures + usp_Auth_GetEffectivePermissions ready.';
GO
