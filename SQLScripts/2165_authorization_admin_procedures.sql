-- ============================================================================
-- Migration: 2165_authorization_admin_procedures.sql
-- Description:
--   Server-Side Authorization - Phase 4: everything the four Settings > Security
--   screens need. Every rule is enforced here (the browser is a courtesy only):
--
--   Menu & Page Master      tree CRUD (3-level sanity, codes unique and stable), page
--                           controls (standard vocabulary, VIEW always kept), endpoint
--                           mapping, bulk acceptance of proposed mappings.
--   Role -> Page mapping    staged changes saved in one transaction with audit rows,
--                           optimistic concurrency (version = last audit id), bulk-change
--                           confirmation, "control needs its page", copy / clear role.
--   User Permissions        same, per user + branch (NULL = all branches), branch must be
--                           the user's, a deny needs a reason.
--   Effective viewer        usp_Auth_Admin_Explain replays the five scopes for one page/control.
--   All saves               no self-lockout: the saver must still be able to open the screen
--                           they are saving from, checked inside the transaction.
--
--   Also: PermissionControlVocabulary (the agreed control list, in plain words),
--         usp_Auth_GetEffectivePermissions gains @IgnoreUserRows ("what the role gives"),
--         bulk endpoint discovery auto-maps actions that declare [RequiresPermission].
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ────────────────────────────────────────────────────────────────────────────
-- The agreed control vocabulary
-- ────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID(N'dbo.PermissionControlVocabulary', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PermissionControlVocabulary
    (
        Control_Code VARCHAR(30) NOT NULL PRIMARY KEY,
        Title        NVARCHAR(100) NOT NULL,
        Description  NVARCHAR(250) NOT NULL,
        Sort_Order   INT NOT NULL,
        Is_Sensitive BIT NOT NULL DEFAULT 0     -- money / report-integrity actions: enforce first
    );
    PRINT 'Created dbo.PermissionControlVocabulary';
END
GO
MERGE dbo.PermissionControlVocabulary AS t
USING (VALUES
    ('VIEW',        N'View',        N'Open the screen and its list',                    10, 0),
    ('CREATE',      N'Create',      N'Add a new record',                                20, 0),
    ('EDIT',        N'Edit',        N'Change an existing record or its status',         30, 0),
    ('DELETE',      N'Delete',      N'Remove a record',                                 40, 1),
    ('ENTRY',       N'Result entry',N'Type and save results',                           50, 0),
    ('VALIDATE',    N'Validate',    N'Mark results validated',                          60, 0),
    ('APPROVE',     N'Approve',     N'Approve the report for release',                  70, 1),
    ('UNAUTHORIZE', N'Un-authorize',N'Withdraw an approved report',                     80, 1),
    ('RECOLLECT',   N'Re-collect',  N'Send a sample back for re-collection',            90, 0),
    ('PRINT',       N'Print',       N'Print or download',                              100, 0),
    ('EXPORT',      N'Export',      N'Export to Excel / CSV',                          110, 0),
    ('DISCOUNT',    N'Discount',    N'Give a discount on a bill',                      120, 1),
    ('CANCEL',      N'Cancel',      N'Cancel a bill, booking or invoice',              130, 1),
    ('REFUND',      N'Refund',      N'Refund money to the patient',                    140, 1),
    ('SETTLE',      N'Settle',      N'Settle dues or partner bills',                   150, 1)
) AS s (Control_Code, Title, Description, Sort_Order, Is_Sensitive)
ON t.Control_Code = s.Control_Code
WHEN MATCHED THEN UPDATE SET Title = s.Title, Description = s.Description, Sort_Order = s.Sort_Order, Is_Sensitive = s.Is_Sensitive
WHEN NOT MATCHED THEN INSERT (Control_Code, Title, Description, Sort_Order, Is_Sensitive) VALUES (s.Control_Code, s.Title, s.Description, s.Sort_Order, s.Is_Sensitive);
GO

-- ────────────────────────────────────────────────────────────────────────────
-- Resolution engine: + @IgnoreUserRows (what the roles alone give - the
-- "From role" column on the User Permissions screen). Otherwise unchanged.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_GetEffectivePermissions
    @UserId         INT,
    @BranchId       INT,
    @CompanyId      INT = NULL,
    @RoleId         INT = NULL,
    @IgnoreUserRows BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IsBypass BIT = 0, @Company INT;

    SELECT @IsBypass = CASE WHEN u.IsSuperAdmin = 1 THEN 1 ELSE 0 END,
           @Company  = ISNULL(@CompanyId, ISNULL(u.CompanyId, 1))
    FROM dbo.Users u WHERE u.Id = @UserId AND u.IsActive = 1;

    IF @Company IS NULL
    BEGIN
        SELECT CAST(NULL AS NVARCHAR(150)) AS Page_Code, CAST(NULL AS INT) AS Page_ID, CAST(NULL AS VARCHAR(30)) AS Control_Code,
               CAST(NULL AS INT) AS Control_ID, CAST(NULL AS CHAR(1)) AS Permission, CAST(NULL AS INT) AS Decided_At_Scope,
               CAST(NULL AS VARCHAR(10)) AS Decided_By
        WHERE 1 = 0;
        RETURN;
    END

    IF OBJECT_ID('tempdb..#MyRoles') IS NOT NULL DROP TABLE #MyRoles;
    SELECT DISTINCT ur.RoleId
    INTO #MyRoles
    FROM dbo.Userroles ur
    WHERE ur.UserId = @UserId AND ur.IsActive = 1
      AND (ur.Branch_ID IS NULL OR ur.Branch_ID = @BranchId)
      AND (@RoleId IS NULL OR ur.RoleId = @RoleId);

    -- Only Super Admin (Users.IsSuperAdmin) bypasses. The Administrator role is granted like any other role.
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

    -- User rows considered (none when only the roles' answer is wanted).
    IF OBJECT_ID('tempdb..#UP') IS NOT NULL DROP TABLE #UP;
    SELECT up.Menu_ID, up.Page_ID, up.Control_ID, up.Branch_ID, up.Permission
    INTO #UP
    FROM dbo.UserPermission up
    WHERE @IgnoreUserRows = 0 AND up.User_ID = @UserId AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId);

    -- 5. control: user, then role
    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 5, Decided_By = 'USER'
    FROM #Result r CROSS APPLY (SELECT TOP 1 up.Permission FROM #UP up
        WHERE up.Page_ID = r.Page_ID AND up.Control_ID = r.Control_ID ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END) x
    WHERE r.Permission IS NULL;
    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 5, Decided_By = 'ROLE'
    FROM #Result r CROSS APPLY (
        SELECT CASE WHEN SUM(CASE WHEN rp.Permission = 'D' THEN 1 ELSE 0 END) > 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Page_ID = r.Page_ID AND rp.Control_ID = r.Control_ID AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0) x
    WHERE r.Permission IS NULL;

    -- A control with no row of its own follows its page (and the page its menu): allowed with the page unless denied.

    -- 4. page: user, then role
    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 4, Decided_By = 'USER'
    FROM #Result r CROSS APPLY (SELECT TOP 1 up.Permission FROM #UP up
        WHERE up.Page_ID = r.Page_ID AND up.Control_ID IS NULL ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END) x
    WHERE r.Permission IS NULL;
    UPDATE r SET Permission = x.Permission, Decided_At_Scope = 4, Decided_By = 'ROLE'
    FROM #Result r CROSS APPLY (
        SELECT CASE WHEN SUM(CASE WHEN rp.Permission = 'D' THEN 1 ELSE 0 END) > 0 THEN 'D' ELSE 'A' END AS Permission
        FROM dbo.RolePermission rp INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
        WHERE rp.Page_ID = r.Page_ID AND rp.Control_ID IS NULL AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        HAVING COUNT(1) > 0) x
    WHERE r.Permission IS NULL;

    -- 3. sub-menu, 2. menu, 1. nav bar item: user, then role
    DECLARE @s INT = 3;
    WHILE @s >= 1
    BEGIN
        UPDATE r SET Permission = x.Permission, Decided_At_Scope = @s, Decided_By = 'USER'
        FROM #Result r CROSS APPLY (SELECT TOP 1 up.Permission FROM #UP up
            WHERE up.Menu_ID = CASE @s WHEN 3 THEN r.Submenu_ID WHEN 2 THEN r.Menu_ID ELSE r.Nav_ID END
            ORDER BY CASE WHEN up.Branch_ID IS NULL THEN 1 ELSE 0 END) x
        WHERE r.Permission IS NULL;

        UPDATE r SET Permission = x.Permission, Decided_At_Scope = @s, Decided_By = 'ROLE'
        FROM #Result r CROSS APPLY (
            SELECT CASE WHEN SUM(CASE WHEN rp.Permission = 'D' THEN 1 ELSE 0 END) > 0 THEN 'D' ELSE 'A' END AS Permission
            FROM dbo.RolePermission rp INNER JOIN #MyRoles mr ON mr.RoleId = rp.Role_ID
            WHERE rp.Menu_ID = CASE @s WHEN 3 THEN r.Submenu_ID WHEN 2 THEN r.Menu_ID ELSE r.Nav_ID END
              AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
            HAVING COUNT(1) > 0) x
        WHERE r.Permission IS NULL;
        SET @s -= 1;
    END

    UPDATE #Result SET Permission = 'D', Decided_At_Scope = 0, Decided_By = 'NONE' WHERE Permission IS NULL;

    -- Controls still need their page.
    UPDATE r SET Permission = 'D', Decided_At_Scope = 4, Decided_By = 'PAGE'
    FROM #Result r
    INNER JOIN #Result v ON v.Page_ID = r.Page_ID AND v.Control_Code = 'VIEW'
    WHERE r.Control_Code <> 'VIEW' AND r.Permission = 'A' AND v.Permission = 'D';

    SELECT Page_Code, Page_ID, Control_Code, Control_ID, Permission, Decided_At_Scope, Decided_By
    FROM #Result ORDER BY Page_Code, Control_Code;

    DROP TABLE #MyRoles; DROP TABLE #UP; DROP TABLE #Result;
END;
GO

-- ────────────────────────────────────────────────────────────────────────────
-- Discovery: actions that declare [RequiresPermission] are mapped automatically
-- (the attribute in code is the source of truth for them).
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_PageEndpointMap_RegisterDiscoveredBulk
    @App  VARCHAR(10),
    @Json NVARCHAR(MAX)  -- [{"m":"GET","c":"Security","a":"Index","r":"...","p":0,"pc":"SETTINGS.SECURITY.MENUPAGES","cc":"EDIT"}]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ScanStart DATETIME2 = SYSDATETIME();

    SELECT DISTINCT
        CAST(j.m AS VARCHAR(10)) AS Http_Method, CAST(j.c AS NVARCHAR(150)) AS Controller, CAST(j.a AS NVARCHAR(150)) AS Action,
        CAST(j.r AS NVARCHAR(300)) AS Route, CAST(ISNULL(j.p, 0) AS BIT) AS Is_Public,
        CAST(j.pc AS NVARCHAR(150)) AS Page_Code, CAST(j.cc AS VARCHAR(30)) AS Control_Code
    INTO #Found
    FROM OPENJSON(@Json) WITH (m VARCHAR(10), c NVARCHAR(150), a NVARCHAR(150), r NVARCHAR(300), p BIT, pc NVARCHAR(150), cc VARCHAR(30)) j;

    BEGIN TRANSACTION;

    UPDATE e SET e.Last_Seen_On = @ScanStart, e.Is_Orphaned = 0, e.Is_Public = f.Is_Public, e.Route = ISNULL(e.Route, f.Route)
    FROM dbo.PageEndpointMap e
    INNER JOIN #Found f ON f.Http_Method = e.Http_Method AND f.Controller = e.Controller AND f.Action = e.Action
    WHERE e.App = @App;

    INSERT INTO dbo.PageEndpointMap (Page_ID, Control_ID, App, Http_Method, Controller, Action, Route, Source, Discovered_On, Last_Seen_On, Is_Public)
    SELECT NULL, NULL, @App, f.Http_Method, f.Controller, f.Action, f.Route, 'SCAN', @ScanStart, @ScanStart, f.Is_Public
    FROM #Found f
    WHERE NOT EXISTS (SELECT 1 FROM dbo.PageEndpointMap e
                      WHERE e.App = @App AND e.Http_Method = f.Http_Method AND e.Controller = f.Controller AND e.Action = f.Action);

    -- Declared in code: map the unmapped row to the declared page/control (every company's page with that code).
    UPDATE e SET e.Page_ID = pg.Page_ID, e.Control_ID = pc.Control_ID, e.Source = 'CODE'
    FROM dbo.PageEndpointMap e
    INNER JOIN #Found f ON f.Http_Method = e.Http_Method AND f.Controller = e.Controller AND f.Action = e.Action AND f.Page_Code IS NOT NULL
    CROSS APPLY (SELECT TOP 1 Page_ID FROM dbo.PageMaster WHERE Page_Code = f.Page_Code AND IsActive = 1 ORDER BY CompanyId) pg
    LEFT JOIN dbo.PageControlMaster pc ON pc.Page_ID = pg.Page_ID AND pc.Control_Code = ISNULL(f.Control_Code, 'VIEW') AND pc.IsActive = 1
    WHERE e.App = @App AND e.Page_ID IS NULL;

    UPDATE dbo.PageEndpointMap SET Is_Orphaned = 1
    WHERE App = @App AND IsActive = 1 AND (Last_Seen_On IS NULL OR Last_Seen_On < @ScanStart);

    COMMIT TRANSACTION;

    SELECT
        (SELECT COUNT(*) FROM #Found) AS Found,
        (SELECT COUNT(*) FROM dbo.PageEndpointMap WHERE App = @App AND IsActive = 1 AND Is_Orphaned = 0 AND Is_Public = 0 AND Page_ID IS NULL) AS Unmapped,
        (SELECT COUNT(*) FROM dbo.PageEndpointMap WHERE App = @App AND IsActive = 1 AND Is_Orphaned = 1) AS Orphaned,
        (SELECT COUNT(*) FROM dbo.PageEndpointMap WHERE App = @App AND IsActive = 1 AND Is_Public = 1 AND Is_Orphaned = 0) AS PublicEndpoints;
    DROP TABLE #Found;
END;
GO

-- ════════════════════════════════════════════════════════════════════════════
-- SCREEN 1 · Menu & Page Master
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_GetTree
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.Menu_ID, m.Parent_Menu_ID, m.Menu_Type, m.Menu_Code, m.Title, m.Icon, m.Sort_Order, m.IsActive
    FROM dbo.MenuMaster m WHERE m.CompanyId = @CompanyId
    ORDER BY m.Sort_Order, m.Menu_ID;

    SELECT p.Page_ID, p.Menu_ID, p.Page_Code, p.Title, p.Controller, p.Action, p.Area, p.Show_In_Menu, p.Sort_Order,
           p.Icon, p.Route_Values, p.Link_Target, p.IsActive,
           (SELECT COUNT(*) FROM dbo.PageEndpointMap e WHERE e.Page_ID = p.Page_ID AND e.IsActive = 1) AS EndpointCount,
           (SELECT COUNT(*) FROM dbo.RolePermission r WHERE r.Page_ID = p.Page_ID) + (SELECT COUNT(*) FROM dbo.UserPermission u WHERE u.Page_ID = p.Page_ID) AS GrantCount
    FROM dbo.PageMaster p WHERE p.CompanyId = @CompanyId
    ORDER BY p.Sort_Order, p.Page_ID;

    SELECT c.Control_ID, c.Page_ID, c.Control_Code, c.Title, c.Sort_Order, c.IsActive, ISNULL(v.Is_Sensitive, 0) AS Is_Sensitive
    FROM dbo.PageControlMaster c
    INNER JOIN dbo.PageMaster p ON p.Page_ID = c.Page_ID AND p.CompanyId = @CompanyId
    LEFT JOIN dbo.PermissionControlVocabulary v ON v.Control_Code = c.Control_Code
    ORDER BY c.Page_ID, c.Sort_Order, c.Control_ID;

    SELECT Control_Code, Title, Description, Sort_Order, Is_Sensitive FROM dbo.PermissionControlVocabulary ORDER BY Sort_Order;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SaveMenu
    @Menu_ID        INT = NULL,
    @CompanyId      INT,
    @Parent_Menu_ID INT = NULL,
    @Menu_Code      NVARCHAR(100),
    @Title          NVARCHAR(150),
    @Icon           NVARCHAR(100) = NULL,
    @Sort_Order     INT = 0,
    @UserId         INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Menu_Code = UPPER(LTRIM(RTRIM(@Menu_Code)));
    SET @Title = LTRIM(RTRIM(@Title));
    IF @Menu_ID = 0 SET @Menu_ID = NULL;

    IF LEN(ISNULL(@Title, '')) = 0 BEGIN RAISERROR('Enter a title for the menu item.', 16, 1); RETURN; END
    IF LEN(ISNULL(@Menu_Code, '')) = 0 OR @Menu_Code LIKE '%[^A-Z0-9_.]%'
    BEGIN RAISERROR('The code may only use letters, digits, "_" and ".", e.g. LAB.REPORTING.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.MenuMaster WHERE Menu_Code = @Menu_Code AND CompanyId = @CompanyId AND Menu_ID <> ISNULL(@Menu_ID, 0))
    BEGIN RAISERROR('%s is already used by another menu item.', 16, 1, @Menu_Code); RETURN; END

    DECLARE @ParentType VARCHAR(10), @Type VARCHAR(10);
    IF @Parent_Menu_ID IS NOT NULL
    BEGIN
        SELECT @ParentType = Menu_Type FROM dbo.MenuMaster WHERE Menu_ID = @Parent_Menu_ID AND CompanyId = @CompanyId;
        IF @ParentType IS NULL BEGIN RAISERROR('That parent belongs to another company and cannot be used here.', 16, 1); RETURN; END
        IF @Parent_Menu_ID = @Menu_ID BEGIN RAISERROR('A menu cannot sit inside itself.', 16, 1); RETURN; END
        -- no cycles: the new parent may not be one of this menu's descendants
        IF @Menu_ID IS NOT NULL AND EXISTS (
            SELECT 1 FROM dbo.MenuMaster c1 WHERE c1.Parent_Menu_ID = @Menu_ID AND (c1.Menu_ID = @Parent_Menu_ID
               OR EXISTS (SELECT 1 FROM dbo.MenuMaster c2 WHERE c2.Parent_Menu_ID = c1.Menu_ID AND c2.Menu_ID = @Parent_Menu_ID)))
        BEGIN RAISERROR('A menu cannot sit inside itself.', 16, 1); RETURN; END
    END

    SET @Type = CASE WHEN @Parent_Menu_ID IS NULL THEN 'NAV' WHEN @ParentType = 'NAV' THEN 'MENU' WHEN @ParentType = 'MENU' THEN 'SUBMENU' ELSE 'TOO_DEEP' END;
    IF @Type = 'TOO_DEEP'
    BEGIN RAISERROR('The navigation bar supports three levels: nav bar item, menu item, sub-menu item.', 16, 1); RETURN; END

    -- moving a menu that has sub-menus must keep them within three levels
    IF @Menu_ID IS NOT NULL AND @Type <> 'NAV'
       AND EXISTS (SELECT 1 FROM dbo.MenuMaster WHERE Parent_Menu_ID = @Menu_ID)
       AND (@Type = 'SUBMENU' OR EXISTS (SELECT 1 FROM dbo.MenuMaster c WHERE c.Parent_Menu_ID IN (SELECT Menu_ID FROM dbo.MenuMaster WHERE Parent_Menu_ID = @Menu_ID)))
    BEGIN RAISERROR('The navigation bar supports three levels: nav bar item, menu item, sub-menu item.', 16, 1); RETURN; END

    IF @Menu_ID IS NULL
    BEGIN
        INSERT INTO dbo.MenuMaster (CompanyId, Parent_Menu_ID, Menu_Type, Menu_Code, Title, Icon, Sort_Order, CreatedBy)
        VALUES (@CompanyId, @Parent_Menu_ID, @Type, @Menu_Code, @Title, NULLIF(LTRIM(RTRIM(@Icon)), ''), @Sort_Order, @UserId);
        SET @Menu_ID = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.MenuMaster WHERE Menu_ID = @Menu_ID AND CompanyId = @CompanyId)
        BEGIN RAISERROR('That menu item belongs to another company.', 16, 1); RETURN; END
        UPDATE dbo.MenuMaster SET Parent_Menu_ID = @Parent_Menu_ID, Menu_Type = @Type, Menu_Code = @Menu_Code, Title = @Title,
               Icon = NULLIF(LTRIM(RTRIM(@Icon)), ''), Sort_Order = @Sort_Order, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE Menu_ID = @Menu_ID;
        -- children follow the new depth
        UPDATE dbo.MenuMaster SET Menu_Type = CASE @Type WHEN 'NAV' THEN 'MENU' ELSE 'SUBMENU' END WHERE Parent_Menu_ID = @Menu_ID;
        UPDATE g SET g.Menu_Type = 'SUBMENU' FROM dbo.MenuMaster g INNER JOIN dbo.MenuMaster c ON c.Menu_ID = g.Parent_Menu_ID WHERE c.Parent_Menu_ID = @Menu_ID;
    END
    SELECT @Menu_ID AS Menu_ID, @Type AS Menu_Type;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SetMenuActive
    @Menu_ID INT, @CompanyId INT, @IsActive BIT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.MenuMaster SET IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE Menu_ID = @Menu_ID AND CompanyId = @CompanyId;
    IF @@ROWCOUNT = 0 RAISERROR('Menu item not found.', 16, 1);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SavePage
    @Page_ID           INT = NULL,
    @CompanyId         INT,
    @Menu_ID           INT = NULL,
    @Page_Code         NVARCHAR(150),
    @Title             NVARCHAR(150),
    @Controller        NVARCHAR(100),
    @Action            NVARCHAR(100),
    @Area              NVARCHAR(100) = NULL,
    @Show_In_Menu      BIT = 1,
    @Sort_Order        INT = 0,
    @Icon              NVARCHAR(100) = NULL,
    @Route_Values      NVARCHAR(200) = NULL,
    @Link_Target       NVARCHAR(20) = NULL,
    @ConfirmCodeChange BIT = 0,
    @UserId            INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Page_Code = UPPER(LTRIM(RTRIM(@Page_Code)));
    IF @Page_ID = 0 SET @Page_ID = NULL;

    IF LEN(ISNULL(LTRIM(RTRIM(@Title)), '')) = 0 BEGIN RAISERROR('Enter a title for the page.', 16, 1); RETURN; END
    IF LEN(ISNULL(LTRIM(RTRIM(@Controller)), '')) = 0 OR LEN(ISNULL(LTRIM(RTRIM(@Action)), '')) = 0
    BEGIN RAISERROR('Enter the controller and action the page opens.', 16, 1); RETURN; END
    IF LEN(ISNULL(@Page_Code, '')) = 0 OR @Page_Code LIKE '%[^A-Z0-9_.]%'
    BEGIN RAISERROR('The page code may only use letters, digits, "_" and ".", e.g. LAB.REPORTING.ENTRY.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.PageMaster WHERE Page_Code = @Page_Code AND CompanyId = @CompanyId AND Page_ID <> ISNULL(@Page_ID, 0))
    BEGIN RAISERROR('%s is already used. Codes are referenced in the application - change it only with a developer.', 16, 1, @Page_Code); RETURN; END
    IF @Menu_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.MenuMaster WHERE Menu_ID = @Menu_ID AND CompanyId = @CompanyId)
    BEGIN RAISERROR('That menu belongs to another company and cannot be mapped here.', 16, 1); RETURN; END
    IF @Show_In_Menu = 1 AND @Menu_ID IS NULL
    BEGIN RAISERROR('Choose the menu this page appears under, or turn off "Show in menu".', 16, 1); RETURN; END

    IF @Page_ID IS NOT NULL
    BEGIN
        DECLARE @OldCode NVARCHAR(150);
        SELECT @OldCode = Page_Code FROM dbo.PageMaster WHERE Page_ID = @Page_ID AND CompanyId = @CompanyId;
        IF @OldCode IS NULL BEGIN RAISERROR('That page belongs to another company.', 16, 1); RETURN; END
        IF @OldCode <> @Page_Code AND @ConfirmCodeChange = 0
        BEGIN RAISERROR('CONFIRM_CODE|%s is referenced in the application code ([RequiresPermission], asp-permission). Change it only together with a developer.', 16, 1, @OldCode); RETURN; END
    END

    -- The upsert matches by code, so an existing page is renamed first.
    IF @Page_ID IS NOT NULL
        UPDATE dbo.PageMaster SET Page_Code = @Page_Code WHERE Page_ID = @Page_ID AND Page_Code <> @Page_Code;

    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @CompanyId, @Menu_ID = @Menu_ID, @Page_Code = @Page_Code, @Title = @Title,
         @Controller = @Controller, @Action = @Action, @Area = @Area, @Show_In_Menu = @Show_In_Menu, @Sort_Order = @Sort_Order,
         @Icon = @Icon, @Route_Values = @Route_Values, @Link_Target = @Link_Target, @UserId = @UserId, @Page_ID = @Page_ID OUTPUT;

    -- The page's own GET endpoint is mapped to its VIEW when nothing maps it yet.
    DECLARE @View INT = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @Page_ID AND Control_Code = 'VIEW');
    IF NOT EXISTS (SELECT 1 FROM dbo.PageEndpointMap WHERE App = 'WEB' AND Http_Method = 'GET' AND Controller = @Controller AND Action = @Action AND Page_ID = @Page_ID)
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @Page_ID, @Control_ID = @View, @App = 'WEB', @Http_Method = 'GET',
             @Controller = @Controller, @Action = @Action, @Source = 'MANUAL';

    SELECT @Page_ID AS Page_ID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SetPageActive
    @Page_ID INT, @CompanyId INT, @IsActive BIT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PageMaster SET IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE Page_ID = @Page_ID AND CompanyId = @CompanyId;
    IF @@ROWCOUNT = 0 RAISERROR('Page not found.', 16, 1);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SaveControl
    @Control_ID   INT = NULL,
    @Page_ID      INT,
    @CompanyId    INT,
    @Control_Code VARCHAR(30),
    @Title        NVARCHAR(150) = NULL,
    @Sort_Order   INT = NULL,
    @UserId       INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Control_Code = UPPER(LTRIM(RTRIM(@Control_Code)));
    IF @Control_ID = 0 SET @Control_ID = NULL;

    IF NOT EXISTS (SELECT 1 FROM dbo.PageMaster WHERE Page_ID = @Page_ID AND CompanyId = @CompanyId)
    BEGIN RAISERROR('That page belongs to another company.', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.PermissionControlVocabulary WHERE Control_Code = @Control_Code)
    BEGIN RAISERROR('Use one of the standard controls so the permission means the same on every screen.', 16, 1); RETURN; END
    IF @Control_ID IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.PageControlMaster WHERE Control_ID = @Control_ID AND Control_Code = 'VIEW' AND @Control_Code <> 'VIEW')
    BEGIN RAISERROR('VIEW cannot be removed - it is how the screen is opened.', 16, 1); RETURN; END

    SELECT @Title = ISNULL(NULLIF(LTRIM(RTRIM(@Title)), ''), Description), @Sort_Order = ISNULL(@Sort_Order, Sort_Order)
    FROM dbo.PermissionControlVocabulary WHERE Control_Code = @Control_Code;

    IF @Control_ID IS NULL
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @Page_ID, @Control_Code = @Control_Code, @Title = @Title,
             @Sort_Order = @Sort_Order, @UserId = @UserId, @Control_ID = @Control_ID OUTPUT;
    ELSE
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.PageControlMaster WHERE Page_ID = @Page_ID AND Control_Code = @Control_Code AND Control_ID <> @Control_ID)
        BEGIN RAISERROR('This page already has %s.', 16, 1, @Control_Code); RETURN; END
        UPDATE dbo.PageControlMaster SET Control_Code = @Control_Code, Title = @Title, Sort_Order = @Sort_Order, IsActive = 1,
               ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE Control_ID = @Control_ID AND Page_ID = @Page_ID;
    END
    UPDATE dbo.PageControlMaster SET IsActive = 1 WHERE Control_ID = @Control_ID;
    SELECT @Control_ID AS Control_ID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SetControlActive
    @Control_ID INT, @CompanyId INT, @IsActive BIT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM dbo.PageControlMaster WHERE Control_ID = @Control_ID AND Control_Code = 'VIEW')
    BEGIN RAISERROR('VIEW cannot be removed - it is how the screen is opened.', 16, 1); RETURN; END
    UPDATE c SET c.IsActive = @IsActive, c.ModifiedBy = @UserId, c.ModifiedDate = GETDATE()
    FROM dbo.PageControlMaster c INNER JOIN dbo.PageMaster p ON p.Page_ID = c.Page_ID AND p.CompanyId = @CompanyId
    WHERE c.Control_ID = @Control_ID;
    IF @@ROWCOUNT = 0 RAISERROR('Control not found.', 16, 1);
END;
GO

-- Endpoints: of one page, unmapped, orphaned, or all - with how often audit mode saw each refused (7 days).
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_GetEndpoints
    @App     VARCHAR(10) = 'WEB',
    @Filter  VARCHAR(10) = 'UNMAPPED',   -- UNMAPPED | ORPHANED | PAGE | ALL
    @Page_ID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.Endpoint_ID, e.App, e.Http_Method, e.Controller, e.Action, e.Route, e.Source, e.Is_Public, e.Is_Orphaned,
           e.Page_ID, p.Page_Code, p.Title AS Page_Title, e.Control_ID, c.Control_Code, e.Last_Seen_On,
           (SELECT COUNT(*) FROM dbo.AuthorizationDecisionLog l
             WHERE l.App = e.App AND l.Http_Method = e.Http_Method AND l.Controller = e.Controller AND l.Action = e.Action
               AND l.Logged_On >= DATEADD(DAY, -7, SYSDATETIME())) AS Refusals7d
    FROM dbo.PageEndpointMap e
    LEFT JOIN dbo.PageMaster p ON p.Page_ID = e.Page_ID
    LEFT JOIN dbo.PageControlMaster c ON c.Control_ID = e.Control_ID
    WHERE e.IsActive = 1 AND e.App = @App
      AND (   (@Filter = 'UNMAPPED' AND e.Page_ID IS NULL AND e.Is_Public = 0 AND e.Is_Orphaned = 0)
           OR (@Filter = 'ORPHANED' AND e.Is_Orphaned = 1)
           OR (@Filter = 'PAGE' AND e.Page_ID = @Page_ID)
           OR (@Filter = 'ALL'))
    ORDER BY e.Controller, e.Action, e.Http_Method;

    SELECT
        SUM(CASE WHEN Page_ID IS NULL AND Is_Public = 0 AND Is_Orphaned = 0 THEN 1 ELSE 0 END) AS Unmapped,
        SUM(CASE WHEN Is_Orphaned = 1 THEN 1 ELSE 0 END) AS Orphaned,
        SUM(CASE WHEN Is_Public = 1 AND Is_Orphaned = 0 THEN 1 ELSE 0 END) AS PublicEndpoints,
        SUM(CASE WHEN Page_ID IS NOT NULL AND Is_Orphaned = 0 THEN 1 ELSE 0 END) AS Mapped
    FROM dbo.PageEndpointMap WHERE IsActive = 1 AND App = @App;
END;
GO

-- Map endpoints in bulk: [{"e":123,"p":45,"c":"EDIT"}]. Creates the control on the page if the vocabulary allows it.
-- An endpoint already mapped to another page gains an extra placement; mapped to the same page, its control changes.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_MapEndpoints
    @CompanyId INT,
    @Json      NVARCHAR(MAX),
    @UserId    INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT j.e AS Endpoint_ID, j.p AS Page_ID, UPPER(ISNULL(NULLIF(j.c, ''), 'VIEW')) AS Control_Code
    INTO #M FROM OPENJSON(@Json) WITH (e INT, p INT, c VARCHAR(30)) j;

    IF EXISTS (SELECT 1 FROM #M m WHERE NOT EXISTS (SELECT 1 FROM dbo.PageMaster p WHERE p.Page_ID = m.Page_ID AND p.CompanyId = @CompanyId))
    BEGIN RAISERROR('That page belongs to another company and cannot be mapped here.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM #M m WHERE NOT EXISTS (SELECT 1 FROM dbo.PermissionControlVocabulary v WHERE v.Control_Code = m.Control_Code))
    BEGIN RAISERROR('Use one of the standard controls so the permission means the same on every screen.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM #M m WHERE NOT EXISTS (SELECT 1 FROM dbo.PageEndpointMap e WHERE e.Endpoint_ID = m.Endpoint_ID))
    BEGIN RAISERROR('An endpoint in the list no longer exists. Refresh and try again.', 16, 1); RETURN; END

    BEGIN TRANSACTION;

    -- controls the mapping needs
    INSERT INTO dbo.PageControlMaster (Page_ID, Control_Code, Title, Sort_Order, CreatedBy)
    SELECT DISTINCT m.Page_ID, m.Control_Code, v.Description, v.Sort_Order, @UserId
    FROM #M m INNER JOIN dbo.PermissionControlVocabulary v ON v.Control_Code = m.Control_Code
    WHERE NOT EXISTS (SELECT 1 FROM dbo.PageControlMaster c WHERE c.Page_ID = m.Page_ID AND c.Control_Code = m.Control_Code);
    UPDATE c SET c.IsActive = 1 FROM dbo.PageControlMaster c INNER JOIN #M m ON m.Page_ID = c.Page_ID AND m.Control_Code = c.Control_Code;

    DECLARE @e INT, @p INT, @code VARCHAR(30), @ctl INT, @app VARCHAR(10), @meth VARCHAR(10), @con NVARCHAR(150), @act NVARCHAR(150);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Endpoint_ID, Page_ID, Control_Code FROM #M;
    OPEN cur; FETCH NEXT FROM cur INTO @e, @p, @code;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @p AND Control_Code = @code;
        SELECT @app = App, @meth = Http_Method, @con = Controller, @act = Action FROM dbo.PageEndpointMap WHERE Endpoint_ID = @e;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @p, @Control_ID = @ctl, @App = @app, @Http_Method = @meth,
             @Controller = @con, @Action = @act, @Source = 'MANUAL';
        FETCH NEXT FROM cur INTO @e, @p, @code;
    END
    CLOSE cur; DEALLOCATE cur;

    COMMIT TRANSACTION;
    SELECT COUNT(*) AS Mapped FROM #M;
END;
GO

-- Remove one mapping: the extra placement row goes; the last placement falls back to unmapped.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_UnmapEndpoint
    @Endpoint_ID INT, @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @app VARCHAR(10), @meth VARCHAR(10), @con NVARCHAR(150), @act NVARCHAR(150);
    SELECT @app = e.App, @meth = e.Http_Method, @con = e.Controller, @act = e.Action
    FROM dbo.PageEndpointMap e INNER JOIN dbo.PageMaster p ON p.Page_ID = e.Page_ID AND p.CompanyId = @CompanyId
    WHERE e.Endpoint_ID = @Endpoint_ID;
    IF @app IS NULL BEGIN RAISERROR('Mapping not found.', 16, 1); RETURN; END

    IF (SELECT COUNT(*) FROM dbo.PageEndpointMap WHERE App = @app AND Http_Method = @meth AND Controller = @con AND Action = @act) > 1
        DELETE FROM dbo.PageEndpointMap WHERE Endpoint_ID = @Endpoint_ID;
    ELSE
        UPDATE dbo.PageEndpointMap SET Page_ID = NULL, Control_ID = NULL WHERE Endpoint_ID = @Endpoint_ID;
END;
GO

-- ════════════════════════════════════════════════════════════════════════════
-- Shared helpers for the two grant screens
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Auth_RolePermission_Clear
    @Role_ID INT, @Menu_ID INT = NULL, @Page_ID INT = NULL, @Control_ID INT = NULL, @Branch_ID INT = NULL, @ChangedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @MenuKey INT = ISNULL(@Menu_ID, 0), @PageKey INT = ISNULL(@Page_ID, 0),
            @ControlKey INT = ISNULL(@Control_ID, 0), @BranchKey INT = ISNULL(@Branch_ID, 0), @Old CHAR(1);
    SELECT @Old = Permission FROM dbo.RolePermission
    WHERE Role_ID = @Role_ID AND Menu_Key = @MenuKey AND Page_Key = @PageKey AND Control_Key = @ControlKey AND Branch_Key = @BranchKey;
    IF @Old IS NULL RETURN;

    DELETE FROM dbo.RolePermission
    WHERE Role_ID = @Role_ID AND Menu_Key = @MenuKey AND Page_Key = @PageKey AND Control_Key = @ControlKey AND Branch_Key = @BranchKey;
    INSERT INTO dbo.PermissionAuditLog (Entity, Target_ID, Menu_ID, Page_ID, Control_ID, Branch_ID, Old_Value, New_Value, Changed_By, Reason)
    VALUES ('ROLE', @Role_ID, @Menu_ID, @Page_ID, @Control_ID, @Branch_ID, @Old, NULL, @ChangedBy, 'Grant removed');
    UPDATE u SET u.Permission_Version = u.Permission_Version + 1
    FROM dbo.Users u INNER JOIN dbo.Userroles ur ON ur.UserId = u.Id AND ur.RoleId = @Role_ID AND ur.IsActive = 1;
END;
GO

-- The no-self-lockout guard: after the change, may the saver still open @GuardPageCode?
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_AssertCanStillOpen
    @UserId INT, @BranchId INT, @RoleId INT = NULL, @GuardPageCode NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #Eff (Page_Code NVARCHAR(150), Page_ID INT, Control_Code VARCHAR(30), Control_ID INT, Permission CHAR(1), Decided_At_Scope INT, Decided_By VARCHAR(10));
    INSERT INTO #Eff EXEC dbo.usp_Auth_GetEffectivePermissions @UserId = @UserId, @BranchId = @BranchId, @RoleId = @RoleId;
    IF NOT EXISTS (SELECT 1 FROM #Eff WHERE Page_Code = @GuardPageCode AND Control_Code = 'VIEW' AND Permission = 'A')
        THROW 50001, 'You cannot remove your own access to Security. Ask another administrator to make this change.', 1;
END;
GO

-- Validates staged grant changes held in #G (Menu_ID, Page_ID, Control_ID, Permission ''=clear, Reason).
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_ValidateGrantRows
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM #G WHERE (Menu_ID IS NULL AND Page_ID IS NULL) OR (Menu_ID IS NOT NULL AND Page_ID IS NOT NULL))
    THROW 50002, 'A permission applies to one thing: a nav bar item, a menu item, a sub-menu item, a page, or one control of a page.', 1;
    IF EXISTS (SELECT 1 FROM #G WHERE Menu_ID IS NOT NULL AND Control_ID IS NOT NULL)
    THROW 50002, 'Controls belong to a page. Choose the page beneath this menu, then its control.', 1;
    IF EXISTS (SELECT 1 FROM #G WHERE Permission NOT IN ('A', 'D', ''))
    THROW 50002, 'Permission must be Allow or Deny.', 1;
    IF EXISTS (SELECT 1 FROM #G g WHERE g.Menu_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.MenuMaster m WHERE m.Menu_ID = g.Menu_ID AND m.CompanyId = @CompanyId))
       OR EXISTS (SELECT 1 FROM #G g WHERE g.Page_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PageMaster p WHERE p.Page_ID = g.Page_ID AND p.CompanyId = @CompanyId))
    THROW 50002, 'That page belongs to another company and cannot be mapped here.', 1;
    IF EXISTS (SELECT 1 FROM #G g WHERE g.Control_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PageControlMaster c WHERE c.Control_ID = g.Control_ID AND c.Page_ID = g.Page_ID))
    THROW 50002, 'A control in the list does not belong to its page. Refresh and try again.', 1;
END;
GO

-- ════════════════════════════════════════════════════════════════════════════
-- SCREEN 2 · Role -> Page mapping
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_GetRoleGrants
    @Role_ID INT, @CompanyId INT, @Branch_ID INT = NULL   -- NULL = the all-branches rows
AS
BEGIN
    SET NOCOUNT ON;
    SELECT rp.Menu_ID, rp.Page_ID, rp.Control_ID, rp.Permission, rp.Reason
    FROM dbo.RolePermission rp
    WHERE rp.Role_ID = @Role_ID AND rp.CompanyId = @CompanyId AND ISNULL(rp.Branch_ID, 0) = ISNULL(@Branch_ID, 0);

    SELECT ISNULL(MAX(l.Log_ID), 0) AS Version,
           (SELECT TOP 1 ISNULL(NULLIF(u.FullName, ''), u.Username) FROM dbo.PermissionAuditLog l2 LEFT JOIN dbo.Users u ON u.Id = l2.Changed_By
             WHERE l2.Entity = 'ROLE' AND l2.Target_ID = @Role_ID ORDER BY l2.Log_ID DESC) AS LastChangedBy,
           MAX(l.Changed_On) AS LastChangedOn,
           (SELECT COUNT(DISTINCT ur.UserId) FROM dbo.Userroles ur INNER JOIN dbo.Users u ON u.Id = ur.UserId AND u.IsActive = 1
             WHERE ur.RoleId = @Role_ID AND ur.IsActive = 1 AND (@Branch_ID IS NULL OR ur.Branch_ID IS NULL OR ur.Branch_ID = @Branch_ID)) AS UsersHoldingRole
    FROM dbo.PermissionAuditLog l WHERE l.Entity = 'ROLE' AND l.Target_ID = @Role_ID;
END;
GO

-- @Json: [{"m":1,"p":null,"c":null,"v":"A","r":"reason"}, ...]  v '' = remove the grant.
-- Returns Status OK | CONFIRM (bulk change not yet confirmed), the new version and the affected user ids.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SaveRoleGrants
    @Role_ID         INT,
    @CompanyId       INT,
    @Branch_ID       INT = NULL,
    @Json            NVARCHAR(MAX),
    @ExpectedVersion INT,
    @Confirmed       BIT = 0,
    @ChangedBy       INT,
    @ActorBranchId   INT,
    @ActorRoleId     INT = NULL,
    @GuardPageCode   NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.roles WHERE Id = @Role_ID AND (CompanyId = @CompanyId OR CompanyId IS NULL))
    BEGIN RAISERROR('That role belongs to another company.', 16, 1); RETURN; END

    CREATE TABLE #G (Menu_ID INT NULL, Page_ID INT NULL, Control_ID INT NULL, Permission VARCHAR(1) NOT NULL, Reason NVARCHAR(500) NULL);
    INSERT INTO #G SELECT j.m, j.p, j.c, ISNULL(j.v, ''), NULLIF(LTRIM(RTRIM(j.r)), '')
    FROM OPENJSON(@Json) WITH (m INT, p INT, c INT, v VARCHAR(1), r NVARCHAR(500)) j;
    EXEC dbo.usp_Auth_Admin_ValidateGrantRows @CompanyId = @CompanyId;

    BEGIN TRANSACTION;

    DECLARE @Current INT = (SELECT ISNULL(MAX(Log_ID), 0) FROM dbo.PermissionAuditLog WITH (UPDLOCK, HOLDLOCK) WHERE Entity = 'ROLE' AND Target_ID = @Role_ID);
    IF @Current <> @ExpectedVersion
    BEGIN
        DECLARE @who NVARCHAR(150), @when VARCHAR(30);
        SELECT TOP 1 @who = ISNULL(NULLIF(u.FullName, ''), u.Username), @when = CONVERT(VARCHAR(30), l.Changed_On, 106) + ' ' + CONVERT(VARCHAR(5), l.Changed_On, 108)
        FROM dbo.PermissionAuditLog l LEFT JOIN dbo.Users u ON u.Id = l.Changed_By
        WHERE l.Entity = 'ROLE' AND l.Target_ID = @Role_ID ORDER BY l.Log_ID DESC;
        ROLLBACK TRANSACTION;
        RAISERROR('CONCURRENT|%s saved changes to this role on %s. Reload to review what changed, then save again.', 16, 1, @who, @when);
        RETURN;
    END

    DECLARE @Changes INT = (SELECT COUNT(*) FROM #G);
    DECLARE @Users INT = (SELECT COUNT(DISTINCT ur.UserId) FROM dbo.Userroles ur WHERE ur.RoleId = @Role_ID AND ur.IsActive = 1);
    IF @Confirmed = 0 AND (@Changes > 25 OR @Users > 10)
    BEGIN
        ROLLBACK TRANSACTION;
        SELECT 'CONFIRM' AS Status, @Changes AS Changes, @Users AS AffectedUsers, @Current AS Version;
        RETURN;
    END

    DECLARE @m INT, @p INT, @c INT, @v VARCHAR(1), @r NVARCHAR(500);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Menu_ID, Page_ID, Control_ID, Permission, Reason FROM #G;
    OPEN cur; FETCH NEXT FROM cur INTO @m, @p, @c, @v, @r;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @v = ''
            EXEC dbo.usp_Auth_RolePermission_Clear @Role_ID = @Role_ID, @Menu_ID = @m, @Page_ID = @p, @Control_ID = @c, @Branch_ID = @Branch_ID, @ChangedBy = @ChangedBy;
        ELSE
            EXEC dbo.usp_Auth_RolePermission_Upsert @Role_ID = @Role_ID, @Menu_ID = @m, @Page_ID = @p, @Control_ID = @c, @Branch_ID = @Branch_ID,
                 @Permission = @v, @CompanyId = @CompanyId, @Reason = @r, @ChangedBy = @ChangedBy;
        FETCH NEXT FROM cur INTO @m, @p, @c, @v, @r;
    END
    CLOSE cur; DEALLOCATE cur;

    -- Control needs its page: an allowed control on a page this role cannot open does nothing.
    IF EXISTS (
        SELECT 1 FROM #G g
        INNER JOIN dbo.PageMaster pg ON pg.Page_ID = g.Page_ID
        LEFT JOIN dbo.MenuMaster m1 ON m1.Menu_ID = pg.Menu_ID
        LEFT JOIN dbo.MenuMaster m2 ON m2.Menu_ID = m1.Parent_Menu_ID
        LEFT JOIN dbo.MenuMaster m3 ON m3.Menu_ID = m2.Parent_Menu_ID
        WHERE g.Control_ID IS NOT NULL AND g.Permission = 'A'
          AND ISNULL((SELECT TOP 1 x.Permission FROM (
                SELECT 1 AS o, rp.Permission FROM dbo.RolePermission rp WHERE rp.Role_ID = @Role_ID AND rp.Page_ID = g.Page_ID AND rp.Control_ID IS NULL AND ISNULL(rp.Branch_ID, 0) IN (0, ISNULL(@Branch_ID, 0))
                UNION ALL SELECT 2, rp.Permission FROM dbo.RolePermission rp WHERE rp.Role_ID = @Role_ID AND rp.Menu_ID = m1.Menu_ID AND ISNULL(rp.Branch_ID, 0) IN (0, ISNULL(@Branch_ID, 0))
                UNION ALL SELECT 3, rp.Permission FROM dbo.RolePermission rp WHERE rp.Role_ID = @Role_ID AND rp.Menu_ID = m2.Menu_ID AND ISNULL(rp.Branch_ID, 0) IN (0, ISNULL(@Branch_ID, 0))
                UNION ALL SELECT 4, rp.Permission FROM dbo.RolePermission rp WHERE rp.Role_ID = @Role_ID AND rp.Menu_ID = m3.Menu_ID AND ISNULL(rp.Branch_ID, 0) IN (0, ISNULL(@Branch_ID, 0))
              ) x ORDER BY x.o), 'D') <> 'A')
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR('Allow the page first - a control on a page the user cannot open does nothing.', 16, 1);
        RETURN;
    END

    -- No self-lockout.
    EXEC dbo.usp_Auth_Admin_AssertCanStillOpen @UserId = @ChangedBy, @BranchId = @ActorBranchId, @RoleId = @ActorRoleId, @GuardPageCode = @GuardPageCode;

    COMMIT TRANSACTION;

    SELECT 'OK' AS Status, @Changes AS Changes, @Users AS AffectedUsers,
           (SELECT ISNULL(MAX(Log_ID), 0) FROM dbo.PermissionAuditLog WHERE Entity = 'ROLE' AND Target_ID = @Role_ID) AS Version;
    SELECT DISTINCT ur.UserId FROM dbo.Userroles ur WHERE ur.RoleId = @Role_ID AND ur.IsActive = 1;
END;
GO

-- Copy (replace) every grant of one role onto another, all branches, with audit rows.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_CopyRoleGrants
    @FromRole_ID INT, @ToRole_ID INT, @CompanyId INT, @ChangedBy INT,
    @ActorBranchId INT, @ActorRoleId INT = NULL, @GuardPageCode NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @FromRole_ID = @ToRole_ID BEGIN RAISERROR('Choose a different role to copy from.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
    DECLARE @m INT, @p INT, @c INT, @b INT, @v CHAR(1), @r NVARCHAR(500);

    DECLARE del CURSOR LOCAL FAST_FORWARD FOR
        SELECT t.Menu_ID, t.Page_ID, t.Control_ID, t.Branch_ID FROM dbo.RolePermission t
        WHERE t.Role_ID = @ToRole_ID AND NOT EXISTS (SELECT 1 FROM dbo.RolePermission s WHERE s.Role_ID = @FromRole_ID
              AND s.Menu_Key = t.Menu_Key AND s.Page_Key = t.Page_Key AND s.Control_Key = t.Control_Key AND s.Branch_Key = t.Branch_Key);
    OPEN del; FETCH NEXT FROM del INTO @m, @p, @c, @b;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Auth_RolePermission_Clear @Role_ID = @ToRole_ID, @Menu_ID = @m, @Page_ID = @p, @Control_ID = @c, @Branch_ID = @b, @ChangedBy = @ChangedBy;
        FETCH NEXT FROM del INTO @m, @p, @c, @b;
    END
    CLOSE del; DEALLOCATE del;

    DECLARE cp CURSOR LOCAL FAST_FORWARD FOR
        SELECT Menu_ID, Page_ID, Control_ID, Branch_ID, Permission, Reason FROM dbo.RolePermission WHERE Role_ID = @FromRole_ID;
    OPEN cp; FETCH NEXT FROM cp INTO @m, @p, @c, @b, @v, @r;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Auth_RolePermission_Upsert @Role_ID = @ToRole_ID, @Menu_ID = @m, @Page_ID = @p, @Control_ID = @c, @Branch_ID = @b,
             @Permission = @v, @CompanyId = @CompanyId, @Reason = @r, @ChangedBy = @ChangedBy;
        FETCH NEXT FROM cp INTO @m, @p, @c, @b, @v, @r;
    END
    CLOSE cp; DEALLOCATE cp;

    EXEC dbo.usp_Auth_Admin_AssertCanStillOpen @UserId = @ChangedBy, @BranchId = @ActorBranchId, @RoleId = @ActorRoleId, @GuardPageCode = @GuardPageCode;
    COMMIT TRANSACTION;

    SELECT DISTINCT ur.UserId FROM dbo.Userroles ur WHERE ur.RoleId = @ToRole_ID AND ur.IsActive = 1;
END;
GO

-- ════════════════════════════════════════════════════════════════════════════
-- SCREEN 3 · User Permissions (both tabs, one save)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_GetUserGrants
    @User_ID INT, @CompanyId INT, @Branch_ID INT = NULL   -- NULL = the all-branches rows
AS
BEGIN
    SET NOCOUNT ON;
    SELECT up.Menu_ID, up.Page_ID, up.Control_ID, up.Permission, up.Reason
    FROM dbo.UserPermission up
    WHERE up.User_ID = @User_ID AND ISNULL(up.Branch_ID, 0) = ISNULL(@Branch_ID, 0);

    SELECT ISNULL(MAX(Log_ID), 0) AS Version FROM dbo.PermissionAuditLog WHERE Entity = 'USER' AND Target_ID = @User_ID;

    SELECT b.BranchID AS BranchId, b.BranchName
    FROM dbo.UserBranches ub INNER JOIN dbo.Branchmaster b ON b.BranchID = ub.BranchId
    WHERE ub.UserId = @User_ID AND ub.IsActive = 1 AND b.IsActive = 1 ORDER BY b.BranchName;

    SELECT DISTINCT r.Id AS RoleId, r.Name AS RoleName, ur.Branch_ID
    FROM dbo.Userroles ur INNER JOIN dbo.roles r ON r.Id = ur.RoleId
    WHERE ur.UserId = @User_ID AND ur.IsActive = 1 AND (@Branch_ID IS NULL OR ur.Branch_ID IS NULL OR ur.Branch_ID = @Branch_ID)
    ORDER BY r.Name;

    SELECT u.Id, u.Username, ISNULL(NULLIF(u.FullName, ''), u.Username) AS DisplayName, u.IsSuperAdmin, u.IsActive, u.CompanyId
    FROM dbo.Users u WHERE u.Id = @User_ID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SaveUserGrants
    @User_ID         INT,
    @CompanyId       INT,
    @Branch_ID       INT = NULL,
    @Json            NVARCHAR(MAX),
    @ExpectedVersion INT,
    @Confirmed       BIT = 0,
    @ChangedBy       INT,
    @ActorBranchId   INT,
    @ActorRoleId     INT = NULL,
    @GuardPageCode   NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @User_ID AND ISNULL(CompanyId, @CompanyId) = @CompanyId)
    BEGIN RAISERROR('That user belongs to another company.', 16, 1); RETURN; END
    IF @Branch_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.UserBranches WHERE UserId = @User_ID AND BranchId = @Branch_ID AND IsActive = 1)
    BEGIN
        DECLARE @bn NVARCHAR(150) = (SELECT BranchName FROM dbo.Branchmaster WHERE BranchID = @Branch_ID);
        RAISERROR('This user is not assigned to %s. Add the branch in User Master first.', 16, 1, @bn);
        RETURN;
    END

    CREATE TABLE #G (Menu_ID INT NULL, Page_ID INT NULL, Control_ID INT NULL, Permission VARCHAR(1) NOT NULL, Reason NVARCHAR(500) NULL);
    INSERT INTO #G SELECT j.m, j.p, j.c, ISNULL(j.v, ''), NULLIF(LTRIM(RTRIM(j.r)), '')
    FROM OPENJSON(@Json) WITH (m INT, p INT, c INT, v VARCHAR(1), r NVARCHAR(500)) j;
    EXEC dbo.usp_Auth_Admin_ValidateGrantRows @CompanyId = @CompanyId;
    IF EXISTS (SELECT 1 FROM #G WHERE Permission = 'D' AND LEN(ISNULL(Reason, '')) < 10)
    BEGIN RAISERROR('Give a short reason for this deny. It is kept with the change history.', 16, 1); RETURN; END

    BEGIN TRANSACTION;

    DECLARE @Current INT = (SELECT ISNULL(MAX(Log_ID), 0) FROM dbo.PermissionAuditLog WITH (UPDLOCK, HOLDLOCK) WHERE Entity = 'USER' AND Target_ID = @User_ID);
    IF @Current <> @ExpectedVersion
    BEGIN
        DECLARE @who NVARCHAR(150), @when VARCHAR(30);
        SELECT TOP 1 @who = ISNULL(NULLIF(u.FullName, ''), u.Username), @when = CONVERT(VARCHAR(30), l.Changed_On, 106) + ' ' + CONVERT(VARCHAR(5), l.Changed_On, 108)
        FROM dbo.PermissionAuditLog l LEFT JOIN dbo.Users u ON u.Id = l.Changed_By
        WHERE l.Entity = 'USER' AND l.Target_ID = @User_ID ORDER BY l.Log_ID DESC;
        ROLLBACK TRANSACTION;
        RAISERROR('CONCURRENT|%s saved changes for this user on %s. Reload to review what changed, then save again.', 16, 1, @who, @when);
        RETURN;
    END

    DECLARE @Changes INT = (SELECT COUNT(*) FROM #G);
    IF @Confirmed = 0 AND @Changes > 25
    BEGIN
        ROLLBACK TRANSACTION;
        SELECT 'CONFIRM' AS Status, @Changes AS Changes, 1 AS AffectedUsers, @Current AS Version;
        RETURN;
    END

    DECLARE @m INT, @p INT, @c INT, @v VARCHAR(1), @r NVARCHAR(500);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Menu_ID, Page_ID, Control_ID, Permission, Reason FROM #G;
    OPEN cur; FETCH NEXT FROM cur INTO @m, @p, @c, @v, @r;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @v = ''
            EXEC dbo.usp_Auth_UserPermission_Clear @User_ID = @User_ID, @Menu_ID = @m, @Page_ID = @p, @Control_ID = @c, @Branch_ID = @Branch_ID, @ChangedBy = @ChangedBy;
        ELSE
            EXEC dbo.usp_Auth_UserPermission_Upsert @User_ID = @User_ID, @Menu_ID = @m, @Page_ID = @p, @Control_ID = @c, @Branch_ID = @Branch_ID,
                 @Permission = @v, @Reason = @r, @ChangedBy = @ChangedBy;
        FETCH NEXT FROM cur INTO @m, @p, @c, @v, @r;
    END
    CLOSE cur; DEALLOCATE cur;

    EXEC dbo.usp_Auth_Admin_AssertCanStillOpen @UserId = @ChangedBy, @BranchId = @ActorBranchId, @RoleId = @ActorRoleId, @GuardPageCode = @GuardPageCode;
    COMMIT TRANSACTION;

    SELECT 'OK' AS Status, @Changes AS Changes, 1 AS AffectedUsers,
           (SELECT ISNULL(MAX(Log_ID), 0) FROM dbo.PermissionAuditLog WHERE Entity = 'USER' AND Target_ID = @User_ID) AS Version;
    SELECT @User_ID AS UserId;
END;
GO

-- ════════════════════════════════════════════════════════════════════════════
-- History (both grant screens) and the "why?" trace (viewer)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_GetHistory
    @Entity VARCHAR(10), @Target_ID INT, @Top INT = 200
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) l.Log_ID, l.Changed_On, ISNULL(NULLIF(u.FullName, ''), u.Username) AS ChangedBy,
           COALESCE(p.Title + ISNULL(' · ' + c.Control_Code, ''), m.Title) AS Target,
           CASE WHEN l.Control_ID IS NOT NULL THEN 'Control' WHEN l.Page_ID IS NOT NULL THEN 'Page'
                WHEN m.Menu_Type = 'NAV' THEN 'Nav bar item' WHEN m.Menu_Type = 'MENU' THEN 'Menu item' ELSE 'Sub-menu item' END AS Scope,
           ISNULL(b.BranchName, 'All branches') AS Branch, l.Old_Value, l.New_Value, l.Reason
    FROM dbo.PermissionAuditLog l
    LEFT JOIN dbo.Users u ON u.Id = l.Changed_By
    LEFT JOIN dbo.MenuMaster m ON m.Menu_ID = l.Menu_ID
    LEFT JOIN dbo.PageMaster p ON p.Page_ID = l.Page_ID
    LEFT JOIN dbo.PageControlMaster c ON c.Control_ID = l.Control_ID
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = l.Branch_ID
    WHERE l.Entity = @Entity AND l.Target_ID = @Target_ID
    ORDER BY l.Log_ID DESC;
END;
GO

-- Replays the five scopes, innermost first, for one page (+ control), showing every row found.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_Explain
    @UserId INT, @BranchId INT, @RoleId INT = NULL, @Page_ID INT, @Control_ID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Sub INT, @Menu INT, @Nav INT, @m1 INT, @t1 VARCHAR(10);
    SELECT @m1 = pg.Menu_ID FROM dbo.PageMaster pg WHERE pg.Page_ID = @Page_ID;
    SELECT @t1 = Menu_Type FROM dbo.MenuMaster WHERE Menu_ID = @m1;
    IF @t1 = 'SUBMENU' BEGIN SET @Sub = @m1; SELECT @Menu = Parent_Menu_ID FROM dbo.MenuMaster WHERE Menu_ID = @Sub; SELECT @Nav = Parent_Menu_ID FROM dbo.MenuMaster WHERE Menu_ID = @Menu; END
    IF @t1 = 'MENU'    BEGIN SET @Menu = @m1; SELECT @Nav = Parent_Menu_ID FROM dbo.MenuMaster WHERE Menu_ID = @Menu; END
    IF @t1 = 'NAV'     SET @Nav = @m1;

    SELECT DISTINCT ur.RoleId INTO #R FROM dbo.Userroles ur
    WHERE ur.UserId = @UserId AND ur.IsActive = 1 AND (ur.Branch_ID IS NULL OR ur.Branch_ID = @BranchId) AND (@RoleId IS NULL OR ur.RoleId = @RoleId);

    SELECT x.Scope, x.ScopeName, x.Target, x.Source, x.Who, x.Permission, x.Reason, x.ChangedOn
    FROM (
        SELECT 5 AS Scope, 'Control' AS ScopeName, c.Control_Code AS Target, 'USER' AS Source, 'user override' AS Who, up.Permission, up.Reason, ISNULL(up.ModifiedDate, up.CreatedDate) AS ChangedOn
        FROM dbo.UserPermission up INNER JOIN dbo.PageControlMaster c ON c.Control_ID = up.Control_ID
        WHERE @Control_ID IS NOT NULL AND up.User_ID = @UserId AND up.Page_ID = @Page_ID AND up.Control_ID = @Control_ID AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        UNION ALL
        SELECT 5, 'Control', c.Control_Code, 'ROLE', 'role ' + r.Name, rp.Permission, rp.Reason, ISNULL(rp.ModifiedDate, rp.CreatedDate)
        FROM dbo.RolePermission rp INNER JOIN #R mr ON mr.RoleId = rp.Role_ID INNER JOIN dbo.roles r ON r.Id = rp.Role_ID INNER JOIN dbo.PageControlMaster c ON c.Control_ID = rp.Control_ID
        WHERE @Control_ID IS NOT NULL AND rp.Page_ID = @Page_ID AND rp.Control_ID = @Control_ID AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        UNION ALL
        SELECT 4, 'Page', p.Title, 'USER', 'user override', up.Permission, up.Reason, ISNULL(up.ModifiedDate, up.CreatedDate)
        FROM dbo.UserPermission up INNER JOIN dbo.PageMaster p ON p.Page_ID = up.Page_ID
        WHERE up.User_ID = @UserId AND up.Page_ID = @Page_ID AND up.Control_ID IS NULL AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        UNION ALL
        SELECT 4, 'Page', p.Title, 'ROLE', 'role ' + r.Name, rp.Permission, rp.Reason, ISNULL(rp.ModifiedDate, rp.CreatedDate)
        FROM dbo.RolePermission rp INNER JOIN #R mr ON mr.RoleId = rp.Role_ID INNER JOIN dbo.roles r ON r.Id = rp.Role_ID INNER JOIN dbo.PageMaster p ON p.Page_ID = rp.Page_ID
        WHERE rp.Page_ID = @Page_ID AND rp.Control_ID IS NULL AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        UNION ALL
        SELECT s.Scope, s.ScopeName, m.Title, 'USER', 'user override', up.Permission, up.Reason, ISNULL(up.ModifiedDate, up.CreatedDate)
        FROM (VALUES (3, 'Sub-menu', @Sub), (2, 'Menu', @Menu), (1, 'Nav bar', @Nav)) s (Scope, ScopeName, Menu_ID)
        INNER JOIN dbo.UserPermission up ON up.Menu_ID = s.Menu_ID AND up.User_ID = @UserId AND (up.Branch_ID IS NULL OR up.Branch_ID = @BranchId)
        INNER JOIN dbo.MenuMaster m ON m.Menu_ID = s.Menu_ID
        UNION ALL
        SELECT s.Scope, s.ScopeName, m.Title, 'ROLE', 'role ' + r.Name, rp.Permission, rp.Reason, ISNULL(rp.ModifiedDate, rp.CreatedDate)
        FROM (VALUES (3, 'Sub-menu', @Sub), (2, 'Menu', @Menu), (1, 'Nav bar', @Nav)) s (Scope, ScopeName, Menu_ID)
        INNER JOIN dbo.RolePermission rp ON rp.Menu_ID = s.Menu_ID AND (rp.Branch_ID IS NULL OR rp.Branch_ID = @BranchId)
        INNER JOIN #R mr ON mr.RoleId = rp.Role_ID INNER JOIN dbo.roles r ON r.Id = rp.Role_ID
        INNER JOIN dbo.MenuMaster m ON m.Menu_ID = s.Menu_ID
    ) x
    ORDER BY x.Scope DESC, CASE x.Source WHEN 'USER' THEN 0 ELSE 1 END;

    SELECT 5 AS Scope, 'Control' AS ScopeName, (SELECT Control_Code FROM dbo.PageControlMaster WHERE Control_ID = @Control_ID) AS Title WHERE @Control_ID IS NOT NULL
    UNION ALL SELECT 4, 'Page', (SELECT Title FROM dbo.PageMaster WHERE Page_ID = @Page_ID)
    UNION ALL SELECT 3, 'Sub-menu', (SELECT Title FROM dbo.MenuMaster WHERE Menu_ID = @Sub)
    UNION ALL SELECT 2, 'Menu', (SELECT Title FROM dbo.MenuMaster WHERE Menu_ID = @Menu)
    UNION ALL SELECT 1, 'Nav bar', (SELECT Title FROM dbo.MenuMaster WHERE Menu_ID = @Nav);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_DecisionLog_Recent
    @FromDate DATETIME2 = NULL, @UserId INT = NULL, @Top INT = 300
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromDate IS NULL SET @FromDate = DATEADD(DAY, -7, SYSDATETIME());
    SELECT TOP (@Top) l.Log_ID, l.Logged_On, l.App, l.Mode, l.Outcome, l.User_ID, ISNULL(NULLIF(u.FullName, ''), u.Username) AS UserName,
           b.BranchName, l.Http_Method, l.Controller, l.Action, l.Path, l.Page_Code, l.Control_Code, l.Decided_At_Scope, l.Decided_By
    FROM dbo.AuthorizationDecisionLog l
    LEFT JOIN dbo.Users u ON u.Id = l.User_ID
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = l.Branch_ID
    WHERE l.Logged_On >= @FromDate AND (@UserId IS NULL OR l.User_ID = @UserId)
    ORDER BY l.Log_ID DESC;
END;
GO

PRINT 'Script 2165 applied: authorization admin procedures ready.';
GO
