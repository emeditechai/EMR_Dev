-- 2334 Roles and role permissions are GLOBAL (user decision 2026-10-26): one set of roles, one navigation tree
--   (menus / pages / controls / endpoints) and one set of role permissions for every company, kept under CompanyId 1.
--   1. merges every other company's copy of the tree and of the roles into company 1's (matched by code / name);
--      a duplicate grant keeps company 1's row
--   2. the navigation / permission procedures use the global tree whatever company they are called for
--   3. company onboarding no longer copies the tree, roles or permissions: the first user gets the global Administrator
--   Users, branches and which role a user has in which branch (Userroles.Branch_ID) stay company-wise.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET XACT_ABORT ON;
GO
BEGIN TRANSACTION;

-- ── maps: other company's id -> company 1's id ──
IF OBJECT_ID('tempdb..#mm') IS NOT NULL DROP TABLE #mm;
IF OBJECT_ID('tempdb..#pm') IS NOT NULL DROP TABLE #pm;
IF OBJECT_ID('tempdb..#cm') IS NOT NULL DROP TABLE #cm;
IF OBJECT_ID('tempdb..#rm') IS NOT NULL DROP TABLE #rm;
SELECT o.Menu_ID AS OldId, g.Menu_ID AS NewId INTO #mm
  FROM dbo.MenuMaster o JOIN dbo.MenuMaster g ON g.CompanyId = 1 AND g.Menu_Code = o.Menu_Code WHERE o.CompanyId <> 1;
SELECT o.Page_ID AS OldId, g.Page_ID AS NewId INTO #pm
  FROM dbo.PageMaster o JOIN dbo.PageMaster g ON g.CompanyId = 1 AND g.Page_Code = o.Page_Code WHERE o.CompanyId <> 1;
SELECT o.Control_ID AS OldId, g.Control_ID AS NewId INTO #cm
  FROM dbo.PageControlMaster o JOIN #pm p ON p.OldId = o.Page_ID
  JOIN dbo.PageControlMaster g ON g.Page_ID = p.NewId AND g.Control_Code = o.Control_Code;
SELECT o.Id AS OldId, g.Id AS NewId INTO #rm
  FROM dbo.roles o
  CROSS APPLY (SELECT TOP 1 Id FROM dbo.roles x WHERE x.CompanyId = 1 AND x.Name = o.Name ORDER BY x.Id) g
 WHERE o.CompanyId <> 1;

-- a menu / page / control of another company with no company 1 counterpart is moved into the global tree
UPDATE m SET CompanyId = 1, Parent_Menu_ID = ISNULL(pm.NewId, m.Parent_Menu_ID)
  FROM dbo.MenuMaster m LEFT JOIN #mm pm ON pm.OldId = m.Parent_Menu_ID
 WHERE m.CompanyId <> 1 AND NOT EXISTS (SELECT 1 FROM #mm WHERE OldId = m.Menu_ID);
UPDATE p SET CompanyId = 1, Menu_ID = ISNULL(mm.NewId, p.Menu_ID)
  FROM dbo.PageMaster p LEFT JOIN #mm mm ON mm.OldId = p.Menu_ID
 WHERE p.CompanyId <> 1 AND NOT EXISTS (SELECT 1 FROM #pm WHERE OldId = p.Page_ID);
UPDATE c SET Page_ID = pm.NewId
  FROM dbo.PageControlMaster c JOIN #pm pm ON pm.OldId = c.Page_ID
 WHERE NOT EXISTS (SELECT 1 FROM #cm WHERE OldId = c.Control_ID);

-- ── role permissions: role, menu, page, control -> global ids; a row that would duplicate an existing grant is dropped ──
IF OBJECT_ID('tempdb..#rp') IS NOT NULL DROP TABLE #rp;
SELECT rp.RolePermission_ID,
       ISNULL(rm.NewId, rp.Role_ID) AS R, ISNULL(mm.NewId, rp.Menu_ID) AS M, ISNULL(pm.NewId, rp.Page_ID) AS P, ISNULL(cm.NewId, rp.Control_ID) AS C,
       rp.Branch_ID AS B, CASE WHEN rp.CompanyId = 1 THEN 0 ELSE 1 END AS Moved
  INTO #rp
  FROM dbo.RolePermission rp
  LEFT JOIN #rm rm ON rm.OldId = rp.Role_ID LEFT JOIN #mm mm ON mm.OldId = rp.Menu_ID
  LEFT JOIN #pm pm ON pm.OldId = rp.Page_ID LEFT JOIN #cm cm ON cm.OldId = rp.Control_ID;
DELETE rp FROM dbo.RolePermission rp JOIN #rp x ON x.RolePermission_ID = rp.RolePermission_ID
 WHERE x.Moved = 1 AND EXISTS (SELECT 1 FROM #rp y WHERE y.RolePermission_ID <> x.RolePermission_ID AND y.R = x.R
        AND ISNULL(y.M, 0) = ISNULL(x.M, 0) AND ISNULL(y.P, 0) = ISNULL(x.P, 0) AND ISNULL(y.C, 0) = ISNULL(x.C, 0) AND ISNULL(y.B, 0) = ISNULL(x.B, 0)
        AND (y.Moved = 0 OR y.RolePermission_ID < x.RolePermission_ID));
UPDATE rp SET Role_ID = x.R, Menu_ID = x.M, Page_ID = x.P, Control_ID = x.C, CompanyId = 1
  FROM dbo.RolePermission rp JOIN #rp x ON x.RolePermission_ID = rp.RolePermission_ID WHERE x.Moved = 1;
UPDATE dbo.RolePermission SET CompanyId = 1 WHERE CompanyId <> 1;

-- ── user permissions (per user): menu, page, control -> global ids; duplicates dropped ──
IF OBJECT_ID('tempdb..#up') IS NOT NULL DROP TABLE #up;
SELECT up.UserPermission_ID, up.User_ID AS U, ISNULL(mm.NewId, up.Menu_ID) AS M, ISNULL(pm.NewId, up.Page_ID) AS P, ISNULL(cm.NewId, up.Control_ID) AS C,
       up.Branch_ID AS B, CASE WHEN mm.OldId IS NULL AND pm.OldId IS NULL AND cm.OldId IS NULL THEN 0 ELSE 1 END AS Moved
  INTO #up
  FROM dbo.UserPermission up LEFT JOIN #mm mm ON mm.OldId = up.Menu_ID LEFT JOIN #pm pm ON pm.OldId = up.Page_ID LEFT JOIN #cm cm ON cm.OldId = up.Control_ID;
DELETE up FROM dbo.UserPermission up JOIN #up x ON x.UserPermission_ID = up.UserPermission_ID
 WHERE x.Moved = 1 AND EXISTS (SELECT 1 FROM #up y WHERE y.UserPermission_ID <> x.UserPermission_ID AND y.U = x.U
        AND ISNULL(y.M, 0) = ISNULL(x.M, 0) AND ISNULL(y.P, 0) = ISNULL(x.P, 0) AND ISNULL(y.C, 0) = ISNULL(x.C, 0) AND ISNULL(y.B, 0) = ISNULL(x.B, 0)
        AND (y.Moved = 0 OR y.UserPermission_ID < x.UserPermission_ID));
UPDATE up SET Menu_ID = x.M, Page_ID = x.P, Control_ID = x.C
  FROM dbo.UserPermission up JOIN #up x ON x.UserPermission_ID = up.UserPermission_ID WHERE x.Moved = 1;

-- ── permission history keeps pointing at the same (now global) menu / page / control ──
UPDATE a SET Menu_ID = mm.NewId FROM dbo.PermissionAuditLog a JOIN #mm mm ON mm.OldId = a.Menu_ID;
UPDATE a SET Page_ID = pm.NewId FROM dbo.PermissionAuditLog a JOIN #pm pm ON pm.OldId = a.Page_ID;
UPDATE a SET Control_ID = cm.NewId FROM dbo.PermissionAuditLog a JOIN #cm cm ON cm.OldId = a.Control_ID;

-- ── endpoints: the copy is dropped where company 1 maps the same endpoint, otherwise re-pointed ──
DELETE e FROM dbo.PageEndpointMap e JOIN #pm pm ON pm.OldId = e.Page_ID
 WHERE EXISTS (SELECT 1 FROM dbo.PageEndpointMap g WHERE g.Page_ID = pm.NewId AND g.App = e.App AND g.Http_Method = e.Http_Method
                 AND g.Controller = e.Controller AND g.Action = e.Action);
UPDATE e SET Page_ID = pm.NewId, Control_ID = ISNULL(cm.NewId, e.Control_ID)
  FROM dbo.PageEndpointMap e JOIN #pm pm ON pm.OldId = e.Page_ID LEFT JOIN #cm cm ON cm.OldId = e.Control_ID;

-- ── the copies themselves ──
DELETE c FROM dbo.PageControlMaster c JOIN #cm cm ON cm.OldId = c.Control_ID;
DELETE p FROM dbo.PageMaster p JOIN #pm pm ON pm.OldId = p.Page_ID;
UPDATE dbo.MenuMaster SET Parent_Menu_ID = NULL WHERE Menu_ID IN (SELECT OldId FROM #mm);
DELETE m FROM dbo.MenuMaster m JOIN #mm mm ON mm.OldId = m.Menu_ID;

-- ── roles: one per name; users keep their branch-wise role ──
UPDATE ur SET RoleId = rm.NewId FROM dbo.Userroles ur JOIN #rm rm ON rm.OldId = ur.RoleId;
UPDATE x SET RoleId = rm.NewId FROM dbo.UserRoleMap x JOIN #rm rm ON rm.OldId = x.RoleId;
UPDATE x SET RoleId = rm.NewId FROM dbo.UserMaster x JOIN #rm rm ON rm.OldId = x.RoleId;
DELETE r FROM dbo.roles r JOIN #rm rm ON rm.OldId = r.Id;
UPDATE dbo.roles SET CompanyId = 1 WHERE CompanyId IS NULL OR CompanyId <> 1;

COMMIT TRANSACTION;
GO

-- Copy (replace) every grant of one role onto another, all branches, with audit rows.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_CopyRoleGrants
    @FromRole_ID INT, @ToRole_ID INT, @CompanyId INT, @ChangedBy INT,
    @ActorBranchId INT, @ActorRoleId INT = NULL, @GuardPageCode NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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
-- SCREEN 2 · Role -> Page mapping
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_GetRoleGrants
    @Role_ID INT, @CompanyId INT, @Branch_ID INT = NULL   -- NULL = the all-branches rows
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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

-- ════════════════════════════════════════════════════════════════════════════
-- SCREEN 1 · Menu & Page Master
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_GetTree
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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

-- Map endpoints in bulk: [{"e":123,"p":45,"c":"EDIT"}]. Creates the control on the page if the vocabulary allows it.
-- An endpoint already mapped to another page gains an extra placement; mapped to the same page, its control changes.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_MapEndpoints
    @CompanyId INT,
    @Json      NVARCHAR(MAX),
    @UserId    INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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

-- Page-specific controls: a standard code, or the screen's own (e.g. CONSULTING_CHARGES) with a title.
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
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
    SET @Control_Code = UPPER(LTRIM(RTRIM(@Control_Code)));
    SET @Title = NULLIF(LTRIM(RTRIM(@Title)), '');
    IF @Control_ID = 0 SET @Control_ID = NULL;

    IF NOT EXISTS (SELECT 1 FROM dbo.PageMaster WHERE Page_ID = @Page_ID AND CompanyId = @CompanyId)
    BEGIN RAISERROR('That page belongs to another company.', 16, 1); RETURN; END
    IF @Control_Code IS NULL OR @Control_Code LIKE '%[^A-Z0-9_]%' OR LEFT(@Control_Code, 1) NOT LIKE '[A-Z]'
    BEGIN RAISERROR('Use a code of capital letters, digits and _ (e.g. CONSULTING_CHARGES).', 16, 1); RETURN; END
    IF @Title IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.PermissionControlVocabulary WHERE Control_Code = @Control_Code)
    BEGIN RAISERROR('Give the control a title - the name of the button on the screen.', 16, 1); RETURN; END
    IF @Control_ID IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.PageControlMaster WHERE Control_ID = @Control_ID AND Control_Code = 'VIEW' AND @Control_Code <> 'VIEW')
    BEGIN RAISERROR('VIEW cannot be removed - it is how the screen is opened.', 16, 1); RETURN; END

    SELECT @Title = ISNULL(@Title, Title), @Sort_Order = ISNULL(@Sort_Order, Sort_Order)
    FROM dbo.PermissionControlVocabulary WHERE Control_Code = @Control_Code;
    SET @Sort_Order = ISNULL(@Sort_Order, 75);

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
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SetControlActive
    @Control_ID INT, @CompanyId INT, @IsActive BIT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM dbo.PageControlMaster WHERE Control_ID = @Control_ID AND Control_Code = 'VIEW')
    BEGIN RAISERROR('VIEW cannot be removed - it is how the screen is opened.', 16, 1); RETURN; END
    UPDATE c SET c.IsActive = @IsActive, c.ModifiedBy = @UserId, c.ModifiedDate = GETDATE()
    FROM dbo.PageControlMaster c INNER JOIN dbo.PageMaster p ON p.Page_ID = c.Page_ID AND p.CompanyId = @CompanyId
    WHERE c.Control_ID = @Control_ID;
    IF @@ROWCOUNT = 0 RAISERROR('Control not found.', 16, 1);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SetMenuActive
    @Menu_ID INT, @CompanyId INT, @IsActive BIT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
    UPDATE dbo.MenuMaster SET IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE Menu_ID = @Menu_ID AND CompanyId = @CompanyId;
    IF @@ROWCOUNT = 0 RAISERROR('Menu item not found.', 16, 1);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SetPageActive
    @Page_ID INT, @CompanyId INT, @IsActive BIT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
    UPDATE dbo.PageMaster SET IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE Page_ID = @Page_ID AND CompanyId = @CompanyId;
    IF @@ROWCOUNT = 0 RAISERROR('Page not found.', 16, 1);
END;
GO

-- Remove one mapping: the extra placement row goes; the last placement falls back to unmapped.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_UnmapEndpoint
    @Endpoint_ID INT, @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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

-- Validates staged grant changes held in #G (Menu_ID, Page_ID, Control_ID, Permission ''=clear, Reason).
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_ValidateGrantRows
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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
           @Company  = 1   -- 2334: one global navigation tree and role permissions
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

-- ── The navigation tree to render (RS1 menus, RS2 pages) ────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Auth_GetNavTree
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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

    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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

    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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

    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
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

CREATE OR ALTER PROCEDURE dbo.usp_Auth_SeedNavTree
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
    SET XACT_ABORT ON;
    DECLARE @page INT, @view INT;
    BEGIN TRANSACTION;
    DECLARE @m1 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=NULL, @Menu_Type='NAV', @Menu_Code=N'HOME', @Title=N'Home', @Icon=N'bi bi-house-fill me-1', @Sort_Order=10, @UserId=NULL, @Menu_ID=@m1 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m1, @Page_Code=N'HOME.DASHBOARD', @Title=N'Home', @Controller=N'Dashboard', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-house-fill me-1', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Dashboard', @Action=N'Index', @Source='SEED';
    DECLARE @m3 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=NULL, @Menu_Type='NAV', @Menu_Code=N'OPD', @Title=N'OPD', @Icon=N'bi bi-person-vcard me-2', @Sort_Order=20, @UserId=NULL, @Menu_ID=@m3 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m3, @Page_Code=N'OPD.DASHBOARD', @Title=N'OPD Dashboard', @Controller=N'OPD', @Action=N'Dashboard', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-speedometer2 me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'OPD', @Action=N'Dashboard', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m3, @Page_Code=N'OPD.DOCTORDASHBOARD', @Title=N'Doctor Dashboard', @Controller=N'OPD', @Action=N'DoctorDashboard', @Show_In_Menu=1, @Sort_Order=20, @Icon=N'bi bi-person-badge-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'OPD', @Action=N'DoctorDashboard', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m3, @Page_Code=N'OPD.PATIENTREGISTRATION', @Title=N'Patient Registration', @Controller=N'OPD', @Action=N'PatientRegistration', @Show_In_Menu=1, @Sort_Order=30, @Icon=N'bi bi-person-plus-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'OPD', @Action=N'PatientRegistration', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m3, @Page_Code=N'OPD.DOCTORROSTER', @Title=N'Doctor Roster', @Controller=N'DoctorRoster', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=40, @Icon=N'bi bi-calendar-range-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorRoster', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m3, @Page_Code=N'OPD.SERVICEBOOKING', @Title=N'Service Booking', @Controller=N'OPD', @Action=N'ServiceBooking', @Show_In_Menu=1, @Sort_Order=50, @Icon=N'bi bi-calendar2-check-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'OPD', @Action=N'ServiceBooking', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m3, @Page_Code=N'OPD.TOKENMANAGEMENT', @Title=N'Token Management', @Controller=N'OPD', @Action=N'TokenManagement', @Show_In_Menu=1, @Sort_Order=70, @Icon=N'bi bi-display me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'OPD', @Action=N'TokenManagement', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m3, @Page_Code=N'OPD.VITALS', @Title=N'Patient Vitals', @Controller=N'Vitals', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=80, @Icon=N'bi bi-activity me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Vitals', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m3, @Page_Code=N'OPD.DOCTORDISBURSAL', @Title=N'Doctor Commission & Disbursals', @Controller=N'DoctorDisbursal', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=100, @Icon=N'bi bi-wallet2 me-2 text-primary', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorDisbursal', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m3, @Page_Code=N'OPD.BILLCANCELLATION.OPD', @Title=N'Bill Cancellation & Refund', @Controller=N'BillCancellation', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=120, @Icon=N'bi bi-x-circle-fill me-2 text-danger', @Route_Values=N'moduleCode=OPD', @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'BillCancellation', @Action=N'Index', @Source='SEED';
    DECLARE @m13 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=NULL, @Menu_Type='NAV', @Menu_Code=N'LAB', @Title=N'LAB', @Icon=N'bi bi-droplet-half me-2', @Sort_Order=30, @UserId=NULL, @Menu_ID=@m13 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m13, @Page_Code=N'LAB.LABDASHBOARD', @Title=N'LAB Dashboard', @Controller=N'LabDashboard', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-speedometer2 me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabDashboard', @Action=N'Index', @Source='SEED';
    DECLARE @m15 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=@m13, @Menu_Type='MENU', @Menu_Code=N'LAB.LAB_ORDER_BOOKING_REGISTRATION', @Title=N'LAB Order Booking / Registration', @Icon=N'bi bi-journal-plus me-2', @Sort_Order=20, @UserId=NULL, @Menu_ID=@m15 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m15, @Page_Code=N'LAB.LABORDERBOOKING.B2CBOOKING', @Title=N'B2C Booking / Registration', @Controller=N'LabOrderBooking', @Action=N'B2CBooking', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-person-fill-add me-2 text-primary', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabOrderBooking', @Action=N'B2CBooking', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m15, @Page_Code=N'LAB.LABORDERBOOKING.B2CORDERLIST', @Title=N'B2C Order List', @Controller=N'LabOrderBooking', @Action=N'B2COrderList', @Show_In_Menu=1, @Sort_Order=20, @Icon=N'bi bi-journal-text me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabOrderBooking', @Action=N'B2COrderList', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m15, @Page_Code=N'LAB.LABORDERBOOKING.B2BBOOKING', @Title=N'B2B Lab Billing & Booking', @Controller=N'LabOrderBooking', @Action=N'B2BBooking', @Show_In_Menu=1, @Sort_Order=40, @Icon=N'bi bi-building-fill-add me-2 text-primary', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabOrderBooking', @Action=N'B2BBooking', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m15, @Page_Code=N'LAB.LABORDERBOOKING.B2BREGISTRATION', @Title=N'B2B Order List', @Controller=N'LabOrderBooking', @Action=N'B2BRegistration', @Show_In_Menu=1, @Sort_Order=50, @Icon=N'bi bi-journal-check me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabOrderBooking', @Action=N'B2BRegistration', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m15, @Page_Code=N'LAB.LABORDERBOOKING.B2BINVOICES', @Title=N'B2B Invoices', @Controller=N'LabOrderBooking', @Action=N'B2BInvoices', @Show_In_Menu=1, @Sort_Order=60, @Icon=N'bi bi-file-earmark-medical me-2 text-info', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabOrderBooking', @Action=N'B2BInvoices', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m15, @Page_Code=N'LAB.LABORDERBOOKING.B2BSETTLEMENT', @Title=N'B2B Multi-Bill Settlement', @Controller=N'LabOrderBooking', @Action=N'B2BSettlement', @Show_In_Menu=1, @Sort_Order=70, @Icon=N'bi bi-wallet2 me-2 text-success', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabOrderBooking', @Action=N'B2BSettlement', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m13, @Page_Code=N'LAB.SAMPLECOLLECTION', @Title=N'Sample Collection Management', @Controller=N'SampleCollection', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=30, @Icon=N'bi bi-eyedropper me-2 text-primary', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'SampleCollection', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m13, @Page_Code=N'LAB.SAMPLETRANSFER', @Title=N'Sample Transfer', @Controller=N'SampleTransfer', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=40, @Icon=N'bi bi-arrow-left-right me-2 text-warning', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'SampleTransfer', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m13, @Page_Code=N'LAB.LABREPORTING', @Title=N'Lab Reporting Entry', @Controller=N'LabReporting', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=50, @Icon=N'bi bi-file-earmark-medical me-2 text-info', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabReporting', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m13, @Page_Code=N'LAB.LABIMAGEREPORTING', @Title=N'Image Report Entry', @Controller=N'LabImageReporting', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=60, @Icon=N'bi bi-file-earmark-image me-2 text-primary', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabImageReporting', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m13, @Page_Code=N'LAB.LABREPORTDISPATCH', @Title=N'Lab Report Dispatch', @Controller=N'LabReportDispatch', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=70, @Icon=N'bi bi-printer-fill me-2 text-success', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabReportDispatch', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m13, @Page_Code=N'LAB.PATHOLOGISTDASHBOARD', @Title=N'Report Approval Dashboard', @Controller=N'PathologistDashboard', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=80, @Icon=N'bi bi-clipboard2-pulse-fill me-2 text-danger', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'PathologistDashboard', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m13, @Page_Code=N'LAB.LABUNAPPROVE', @Title=N'Un-Authorize Report', @Controller=N'LabUnapprove', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=90, @Icon=N'bi bi-unlock-fill me-2 text-warning', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabUnapprove', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m13, @Page_Code=N'LAB.BILLCANCELLATION.LAB', @Title=N'Bill Cancellation & Refund', @Controller=N'BillCancellation', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=110, @Icon=N'bi bi-x-circle-fill me-2 text-danger', @Route_Values=N'moduleCode=LAB', @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'BillCancellation', @Action=N'Index', @Source='SEED';
    DECLARE @m30 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=NULL, @Menu_Type='NAV', @Menu_Code=N'IPD', @Title=N'IPD', @Icon=N'bi bi-hospital me-2', @Sort_Order=40, @UserId=NULL, @Menu_ID=@m30 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m30, @Page_Code=N'IPD.INDEX', @Title=N'IPD', @Controller=N'IPD', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-hospital me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'IPD', @Action=N'Index', @Source='SEED';
    DECLARE @m32 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=NULL, @Menu_Type='NAV', @Menu_Code=N'MASTER', @Title=N'Master', @Icon=N'bi bi-database-fill me-2', @Sort_Order=50, @UserId=NULL, @Menu_ID=@m32 OUTPUT;
    DECLARE @m33 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=@m32, @Menu_Type='MENU', @Menu_Code=N'MASTER.GENERAL', @Title=N'General', @Icon=N'bi bi-grid-fill me-2', @Sort_Order=10, @UserId=NULL, @Menu_ID=@m33 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.OPD', @Title=N'Patient Master', @Controller=N'OPD', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-person-heart me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'OPD', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.DOCTORS', @Title=N'Doctor Master', @Controller=N'Doctors', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=20, @Icon=N'bi bi-heart-pulse-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Doctors', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.REFERRALDOCTORS', @Title=N'Referral Doctor Master', @Controller=N'ReferralDoctors', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=30, @Icon=N'bi bi-person-lines-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'ReferralDoctors', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.DOCTORSPECIALITIES', @Title=N'Doctor Speciality Master', @Controller=N'DoctorSpecialities', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=40, @Icon=N'bi bi-award-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorSpecialities', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.DOCTORSUBSPECIALITIES', @Title=N'Doctor Sub-Speciality Master', @Controller=N'DoctorSubSpecialities', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=50, @Icon=N'bi bi-patch-plus-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorSubSpecialities', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.DEPARTMENTS', @Title=N'Department Master', @Controller=N'Departments', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=60, @Icon=N'bi bi-building me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Departments', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.CLINICALUNITS', @Title=N'Clinical Unit Master', @Controller=N'ClinicalUnits', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=70, @Icon=N'bi bi-diagram-3-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'ClinicalUnits', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.CORPORATES', @Title=N'Corporate Master', @Controller=N'Corporates', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=80, @Icon=N'bi bi-briefcase-fill me-2 text-primary', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Corporates', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.DISCOUNTTYPES', @Title=N'Discount Type Master', @Controller=N'DiscountTypes', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=90, @Icon=N'bi bi-tags-fill me-2 text-warning', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DiscountTypes', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.INSURANCES', @Title=N'Insurance / TPA Master', @Controller=N'Insurances', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=100, @Icon=N'bi bi-shield-check me-2 text-info', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Insurances', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.GOVERNMENTSCHEMES', @Title=N'Government Scheme Master', @Controller=N'GovernmentSchemes', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=110, @Icon=N'bi bi-bank2 me-2 text-warning', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'GovernmentSchemes', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.SHIFTS', @Title=N'Shift Master', @Controller=N'Shifts', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=120, @Icon=N'bi bi-clock-history me-2 text-primary', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Shifts', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.CONSENTMASTERS', @Title=N'Consent Masters', @Controller=N'ConsentMasters', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=130, @Icon=N'bi bi-file-earmark-check-fill me-2 text-success', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'ConsentMasters', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.LABUNITS', @Title=N'Unit Master', @Controller=N'LabUnits', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=140, @Icon=N'bi bi-rulers me-2 text-primary', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabUnits', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.ANALYZERS', @Title=N'Analyzer Master', @Controller=N'Analyzers', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=150, @Icon=N'bi bi-cpu-fill me-2 text-info', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Analyzers', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.BUILDINGS', @Title=N'Building Master', @Controller=N'Buildings', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=160, @Icon=N'bi bi-buildings-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Buildings', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.FLOORS', @Title=N'Floor Master', @Controller=N'Floors', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=170, @Icon=N'bi bi-layers-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Floors', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.COUNTRIES', @Title=N'Country Master', @Controller=N'Countries', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=190, @Icon=N'bi bi-globe me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Countries', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.STATES', @Title=N'State Master', @Controller=N'States', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=200, @Icon=N'bi bi-map me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'States', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.DISTRICTS', @Title=N'District Master', @Controller=N'Districts', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=210, @Icon=N'bi bi-geo me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Districts', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.CITIES', @Title=N'City Master', @Controller=N'Cities', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=220, @Icon=N'bi bi-buildings me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Cities', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m33, @Page_Code=N'MASTER.AREAS', @Title=N'Area Master', @Controller=N'Areas', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=230, @Icon=N'bi bi-pin-map me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Areas', @Action=N'Index', @Source='SEED';
    DECLARE @m56 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=@m32, @Menu_Type='MENU', @Menu_Code=N'MASTER.OPD_MASTER', @Title=N'OPD Master', @Icon=N'bi bi-clipboard2-pulse me-2', @Sort_Order=20, @UserId=NULL, @Menu_ID=@m56 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m56, @Page_Code=N'MASTER.SERVICES', @Title=N'Service Master', @Controller=N'Services', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-clipboard2-check me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Services', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m56, @Page_Code=N'MASTER.DOCTORROOMS', @Title=N'Doctor Room', @Controller=N'DoctorRooms', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=20, @Icon=N'bi bi-door-open-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorRooms', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m56, @Page_Code=N'MASTER.ROOMDOCTORASSIGNMENT', @Title=N'Room Doctor Assignment', @Controller=N'RoomDoctorAssignment', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=30, @Icon=N'bi bi-person-lines-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'RoomDoctorAssignment', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m56, @Page_Code=N'MASTER.EMRINVESTIGATIONS', @Title=N'EMR Investigation Master', @Controller=N'EmrInvestigations', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=50, @Icon=N'bi bi-eyedropper me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'EmrInvestigations', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m56, @Page_Code=N'MASTER.EMRMEDICATIONS', @Title=N'EMR Medication Master', @Controller=N'EmrMedications', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=60, @Icon=N'bi bi-capsule me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'EmrMedications', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m56, @Page_Code=N'MASTER.DOCTORVISITPROCESSCONFIGS', @Title=N'Doctor Visit Process Config', @Controller=N'DoctorVisitProcessConfigs', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=80, @Icon=N'bi bi-diagram-3-fill me-2 text-primary', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorVisitProcessConfigs', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m56, @Page_Code=N'MASTER.DOCTORCOMMISSIONCONFIGS', @Title=N'Doctor Commission Config', @Controller=N'DoctorCommissionConfigs', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=90, @Icon=N'bi bi-percent me-2 text-success', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorCommissionConfigs', @Action=N'Index', @Source='SEED';
    DECLARE @m64 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=@m32, @Menu_Type='MENU', @Menu_Code=N'MASTER.IPD_MASTER', @Title=N'IPD Master', @Icon=N'bi bi-hospital me-2', @Sort_Order=30, @UserId=NULL, @Menu_ID=@m64 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.WARDS', @Title=N'Ward Master', @Controller=N'Wards', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-hospital me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Wards', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.NURSINGSTATIONS', @Title=N'Nursing Station Master', @Controller=N'NursingStations', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=20, @Icon=N'bi bi-person-workspace me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'NursingStations', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.ROOMS', @Title=N'IPD Room Master', @Controller=N'Rooms', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=30, @Icon=N'bi bi-door-open me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Rooms', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.BEDCATEGORIES', @Title=N'Bed Category Master', @Controller=N'BedCategories', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=40, @Icon=N'bi bi-bookmark-star me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'BedCategories', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.BEDS', @Title=N'Bed Master', @Controller=N'Beds', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=50, @Icon=N'bi bi-hospital-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Beds', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.TARIFFCATEGORIES', @Title=N'Tariff Category Master', @Controller=N'TariffCategories', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=60, @Icon=N'bi bi-tags-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'TariffCategories', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.BEDROOMTARIFFS', @Title=N'Bed/Room Tariff Master', @Controller=N'BedRoomTariffs', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=70, @Icon=N'bi bi-receipt-cutoff me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'BedRoomTariffs', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.HOSPITALSERVICES', @Title=N'Hospital Service Master', @Controller=N'HospitalServices', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=90, @Icon=N'bi bi-gear-wide-connected me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'HospitalServices', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.HOSPITALSERVICERATES', @Title=N'Hospital Service Rate Master', @Controller=N'HospitalServiceRates', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=100, @Icon=N'bi bi-cash-coin me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'HospitalServiceRates', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.PROCEDURES', @Title=N'Procedure Master', @Controller=N'Procedures', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=120, @Icon=N'bi bi-heart-pulse me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Procedures', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.PROCEDURETARIFFS', @Title=N'Procedure Tariff Master', @Controller=N'ProcedureTariffs', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=130, @Icon=N'bi bi-receipt me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'ProcedureTariffs', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.OTS', @Title=N'OT Master', @Controller=N'Ots', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=150, @Icon=N'bi bi-hospital me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Ots', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.OTEQUIPMENTS', @Title=N'OT Equipment Master', @Controller=N'OtEquipments', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=160, @Icon=N'bi bi-tools me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'OtEquipments', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.OTTARIFFS', @Title=N'OT Tariff Master', @Controller=N'OtTariffs', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=170, @Icon=N'bi bi-calculator me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'OtTariffs', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.ANAESTHESIAS', @Title=N'Anaesthesia Master', @Controller=N'Anaesthesias', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=190, @Icon=N'bi bi-shield-plus me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Anaesthesias', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.ICUS', @Title=N'ICU Master', @Controller=N'Icus', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=210, @Icon=N'bi bi-hospital-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Icus', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.HOSPITALPACKAGES', @Title=N'Hospital Package Master', @Controller=N'HospitalPackages', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=230, @Icon=N'bi bi-box2-heart-fill me-2 text-primary', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'HospitalPackages', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m64, @Page_Code=N'MASTER.HOUSEKEEPING', @Title=N'Housekeeping Masters', @Controller=N'Housekeeping', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=250, @Icon=N'bi bi-brush-fill me-2 text-success', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Housekeeping', @Action=N'Index', @Source='SEED';
    DECLARE @m83 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=@m32, @Menu_Type='MENU', @Menu_Code=N'MASTER.LAB_MASTER', @Title=N'Lab Master', @Icon=N'bi bi-eyedropper me-2', @Sort_Order=40, @UserId=NULL, @Menu_ID=@m83 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABTESTCATEGORIES', @Title=N'Test Category Master', @Controller=N'LabTestCategories', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-tags me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabTestCategories', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABTESTSUBCATEGORIES', @Title=N'Test Sub Category Master', @Controller=N'LabTestSubCategories', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=20, @Icon=N'bi bi-tag-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabTestSubCategories', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABSAMPLETYPES', @Title=N'Sample Type Master', @Controller=N'LabSampleTypes', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=30, @Icon=N'bi bi-droplet-half me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabSampleTypes', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABTESTMETHODS', @Title=N'Test Method Master', @Controller=N'LabTestMethods', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=40, @Icon=N'bi bi-gear-wide-connected me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabTestMethods', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LAB_MASTER.LABUNITS', @Title=N'Unit Master', @Controller=N'LabUnits', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=50, @Icon=N'bi bi-rulers me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabUnits', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABINVESTIGATIONS', @Title=N'Investigation Master', @Controller=N'LabInvestigations', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=60, @Icon=N'bi bi-journal-medical me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabInvestigations', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABINVESTIGATIONPROFILES', @Title=N'Investigation Profile Master', @Controller=N'LabInvestigationProfiles', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=70, @Icon=N'bi bi-collection-play me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabInvestigationProfiles', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABREFERENCERANGES', @Title=N'Reference Range Master', @Controller=N'LabReferenceRanges', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=80, @Icon=N'bi bi-sliders2-vertical me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabReferenceRanges', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABSAMPLEREJECTIONREASONS', @Title=N'Sample Rejection Reason Master', @Controller=N'LabSampleRejectionReasons', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=90, @Icon=N'bi bi-x-octagon me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabSampleRejectionReasons', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABREPORTINGCONDITIONS', @Title=N'Conditions of Reporting', @Controller=N'LabReportingConditions', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=100, @Icon=N'bi bi-file-earmark-ruled me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabReportingConditions', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABFRANCHISES', @Title=N'Franchise Setup', @Controller=N'LabFranchises', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=110, @Icon=N'bi bi-building-gear me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabFranchises', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABFRANCHISEBARCODES', @Title=N'Franchise Barcode Assignment', @Controller=N'LabFranchiseBarcodes', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=120, @Icon=N'bi bi-upc-scan me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabFranchiseBarcodes', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABRATELISTB2C', @Title=N'Rate List (B2C)', @Controller=N'LabRateListB2C', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=130, @Icon=N'bi bi-currency-dollar me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabRateListB2C', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABRATELISTFRANCHISE', @Title=N'Rate List (Franchise)', @Controller=N'LabRateListFranchise', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=140, @Icon=N'bi bi-building-gear me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabRateListFranchise', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABRATELISTCORPORATE', @Title=N'Rate List (Corporate)', @Controller=N'LabRateListCorporate', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=150, @Icon=N'bi bi-building me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabRateListCorporate', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABFORMULAPARAMETERS', @Title=N'Lab Formula Component', @Controller=N'LabFormulaParameters', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=160, @Icon=N'bi bi-calculator me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabFormulaParameters', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABDESCRIPTIVETESTTEMPLATES', @Title=N'Descriptive Test Template', @Controller=N'LabDescriptiveTestTemplates', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=170, @Icon=N'bi bi-file-earmark-richtext me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabDescriptiveTestTemplates', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABPARAMETEROPTIONS', @Title=N'Parameter Option Master', @Controller=N'LabParameterOptions', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=180, @Icon=N'bi bi-ui-radios me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabParameterOptions', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABORGANISMS', @Title=N'Organism Master', @Controller=N'LabOrganisms', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=190, @Icon=N'bi bi-bug me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabOrganisms', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABANTIBIOTICS', @Title=N'Antibiotic Master', @Controller=N'LabAntibiotics', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=200, @Icon=N'bi bi-capsule-pill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabAntibiotics', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABANTIBIOTICPANELS', @Title=N'Antibiotic Panel Master', @Controller=N'LabAntibioticPanels', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=210, @Icon=N'bi bi-grid-3x3-gap me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabAntibioticPanels', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABEXPERTRULES', @Title=N'Expert Rule Master', @Controller=N'LabExpertRules', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=220, @Icon=N'bi bi-shield-exclamation me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabExpertRules', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m83, @Page_Code=N'MASTER.LABBREAKPOINTS', @Title=N'Breakpoint Master', @Controller=N'LabBreakpoints', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=230, @Icon=N'bi bi-rulers me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabBreakpoints', @Action=N'Index', @Source='SEED';
    DECLARE @m107 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=@m32, @Menu_Type='MENU', @Menu_Code=N'MASTER.PHARMACY_MASTER', @Title=N'Pharmacy Master', @Icon=N'bi bi-bag-heart me-2', @Sort_Order=50, @UserId=NULL, @Menu_ID=@m107 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m107, @Page_Code=N'MASTER.MEDICINES', @Title=N'Medicine Master', @Controller=N'Medicines', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-capsule me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Medicines', @Action=N'Index', @Source='SEED';
    DECLARE @m109 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=NULL, @Menu_Type='NAV', @Menu_Code=N'SETTINGS', @Title=N'Settings', @Icon=N'bi bi-gear-fill me-2', @Sort_Order=60, @UserId=NULL, @Menu_ID=@m109 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m109, @Page_Code=N'SETTINGS.COMPANIES', @Title=N'Company Master', @Controller=N'Companies', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-buildings me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Companies', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m109, @Page_Code=N'SETTINGS.BRANCHES', @Title=N'Branch Master', @Controller=N'Branches', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=20, @Icon=N'bi bi-diagram-3 me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Branches', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m109, @Page_Code=N'SETTINGS.USERS', @Title=N'User Master', @Controller=N'Users', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=30, @Icon=N'bi bi-people me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Users', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m109, @Page_Code=N'SETTINGS.HOSPITALSETTINGS', @Title=N'Hospital Settings', @Controller=N'HospitalSettings', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=50, @Icon=N'bi bi-hospital-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'HospitalSettings', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m109, @Page_Code=N'SETTINGS.LABAPPROVALFLOWS', @Title=N'Pathologist Approval Flow', @Controller=N'LabApprovalFlows', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=60, @Icon=N'bi bi-diagram-3-fill me-2 text-success', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'LabApprovalFlows', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m109, @Page_Code=N'SETTINGS.SMTPCONFIG', @Title=N'Email Configuration', @Controller=N'SmtpConfig', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=70, @Icon=N'bi bi-envelope-at me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'SmtpConfig', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m109, @Page_Code=N'SETTINGS.WHATSAPPCONFIG', @Title=N'WhatsApp Configuration', @Controller=N'WhatsAppConfig', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=80, @Icon=N'bi bi-whatsapp me-2 text-success', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'WhatsAppConfig', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m109, @Page_Code=N'SETTINGS.VIDEOCONFIG', @Title=N'Video Consultation Config', @Controller=N'VideoConfig', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=90, @Icon=N'bi bi-camera-video-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'VideoConfig', @Action=N'Index', @Source='SEED';
    DECLARE @m118 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=@m109, @Menu_Type='MENU', @Menu_Code=N'SETTINGS.SECURITY', @Title=N'Security', @Icon=N'bi bi-shield-lock-fill me-2 text-danger', @Sort_Order=110, @UserId=NULL, @Menu_ID=@m118 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m118, @Page_Code=N'SETTINGS.SECURITY.MENUPAGES', @Title=N'Menu & Page Master', @Controller=N'Security', @Action=N'MenuPages', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-diagram-3-fill me-2 text-primary', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Security', @Action=N'MenuPages', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m118, @Page_Code=N'SETTINGS.SECURITY.ROLEPERMISSIONS', @Title=N'Role Permissions', @Controller=N'Security', @Action=N'RolePermissions', @Show_In_Menu=1, @Sort_Order=20, @Icon=N'bi bi-person-lock me-2 text-success', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Security', @Action=N'RolePermissions', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m118, @Page_Code=N'SETTINGS.SECURITY.USERPERMISSIONS', @Title=N'User Permissions', @Controller=N'Security', @Action=N'UserPermissions', @Show_In_Menu=1, @Sort_Order=30, @Icon=N'bi bi-person-gear me-2 text-warning', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Security', @Action=N'UserPermissions', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m118, @Page_Code=N'SETTINGS.SECURITY.EFFECTIVEPERMISSIONS', @Title=N'Effective Permissions', @Controller=N'Security', @Action=N'EffectivePermissions', @Show_In_Menu=1, @Sort_Order=40, @Icon=N'bi bi-search-heart me-2 text-info', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Security', @Action=N'EffectivePermissions', @Source='SEED';
    DECLARE @m123 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=NULL, @Menu_Type='NAV', @Menu_Code=N'UTILITY', @Title=N'Utility', @Icon=N'bi bi-tools me-2', @Sort_Order=70, @UserId=NULL, @Menu_ID=@m123 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m123, @Page_Code=N'UTILITY.AUDITLOGS', @Title=N'Audit Log', @Controller=N'AuditLogs', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-journal-text me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'AuditLogs', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m123, @Page_Code=N'UTILITY.EMAILLOGS', @Title=N'Email Logs', @Controller=N'EmailLogs', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=20, @Icon=N'bi bi-inbox-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'EmailLogs', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m123, @Page_Code=N'UTILITY.EMAILTEMPLATE', @Title=N'Email Templates', @Controller=N'EmailTemplate', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=30, @Icon=N'bi bi-envelope-paper me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'EmailTemplate', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m123, @Page_Code=N'UTILITY.EMRTEMPLATES', @Title=N'EMR Template Settings', @Controller=N'EmrTemplates', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=40, @Icon=N'bi bi-file-earmark-medical me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'EmrTemplates', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m123, @Page_Code=N'UTILITY.PATIENTPORTAL.LOGIN', @Title=N'Patient Login', @Controller=N'PatientPortal', @Action=N'Login', @Show_In_Menu=1, @Sort_Order=60, @Icon=N'bi bi-person-badge me-2', @Route_Values=NULL, @Link_Target=N'_blank', @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'PatientPortal', @Action=N'Login', @Source='SEED';
    DECLARE @m129 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=NULL, @Menu_Type='NAV', @Menu_Code=N'REPORTS', @Title=N'Reports', @Icon=N'bi bi-bar-chart-line-fill me-2', @Sort_Order=80, @UserId=NULL, @Menu_ID=@m129 OUTPUT;
    DECLARE @m130 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=@m129, @Menu_Type='MENU', @Menu_Code=N'REPORTS.LAB', @Title=N'LAB', @Icon=N'bi bi-droplet-half me-2', @Sort_Order=10, @UserId=NULL, @Menu_ID=@m130 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m130, @Page_Code=N'REPORTS.LABBILLINGREGISTER', @Title=N'Daily Billing Register', @Controller=N'Reports', @Action=N'LabBillingRegister', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-journal-text me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'LabBillingRegister', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m130, @Page_Code=N'REPORTS.LABB2CCOLLECTIONREGISTER', @Title=N'B2C Collection Register', @Controller=N'Reports', @Action=N'LabB2CCollectionRegister', @Show_In_Menu=1, @Sort_Order=20, @Icon=N'bi bi-receipt me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'LabB2CCollectionRegister', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m130, @Page_Code=N'REPORTS.LABOUTSTANDINGDUES', @Title=N'Outstanding Dues & Ageing', @Controller=N'Reports', @Action=N'LabOutstandingDues', @Show_In_Menu=1, @Sort_Order=30, @Icon=N'bi bi-hourglass-split me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'LabOutstandingDues', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m130, @Page_Code=N'REPORTS.LABDISCOUNTREGISTER', @Title=N'Discount Register', @Controller=N'Reports', @Action=N'LabDiscountRegister', @Show_In_Menu=1, @Sort_Order=40, @Icon=N'bi bi-percent me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'LabDiscountRegister', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m130, @Page_Code=N'REPORTS.LABCANCELLATIONREFUND', @Title=N'Cancellation & Refund Register', @Controller=N'Reports', @Action=N'LabCancellationRefund', @Show_In_Menu=1, @Sort_Order=50, @Icon=N'bi bi-x-octagon me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'LabCancellationRefund', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m130, @Page_Code=N'REPORTS.LABPATIENTORDERS', @Title=N'Patient-wise Lab Orders', @Controller=N'Reports', @Action=N'LabPatientOrders', @Show_In_Menu=1, @Sort_Order=70, @Icon=N'bi bi-person-lines-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'LabPatientOrders', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m130, @Page_Code=N'REPORTS.LABB2BPARTNERBILLING', @Title=N'B2B Partner Billing Register', @Controller=N'Reports', @Action=N'LabB2BPartnerBilling', @Show_In_Menu=1, @Sort_Order=90, @Icon=N'bi bi-buildings me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'LabB2BPartnerBilling', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m130, @Page_Code=N'REPORTS.LABFRANCHISEWALLET', @Title=N'Franchise Wallet Statement', @Controller=N'Reports', @Action=N'LabFranchiseWallet', @Show_In_Menu=1, @Sort_Order=100, @Icon=N'bi bi-wallet2 me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'LabFranchiseWallet', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m130, @Page_Code=N'REPORTS.LABB2BOUTSTANDING', @Title=N'B2B Outstanding & Credit Use', @Controller=N'Reports', @Action=N'LabB2BOutstanding', @Show_In_Menu=1, @Sort_Order=110, @Icon=N'bi bi-credit-card-2-back me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'LabB2BOutstanding', @Source='SEED';
    DECLARE @m140 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=@m129, @Menu_Type='MENU', @Menu_Code=N'REPORTS.OPD', @Title=N'OPD', @Icon=N'bi bi-file-medical me-2', @Sort_Order=20, @UserId=NULL, @Menu_ID=@m140 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m140, @Page_Code=N'REPORTS.DAILYCOLLECTION', @Title=N'Daily Collection', @Controller=N'Reports', @Action=N'DailyCollection', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-cash-stack me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'DailyCollection', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m140, @Page_Code=N'REPORTS.PATIENTREGISTER', @Title=N'Patient Register', @Controller=N'Reports', @Action=N'PatientRegister', @Show_In_Menu=1, @Sort_Order=20, @Icon=N'bi bi-people-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'PatientRegister', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m140, @Page_Code=N'REPORTS.OPDREPORT', @Title=N'Other OPD Report', @Controller=N'Reports', @Action=N'OPDReport', @Show_In_Menu=1, @Sort_Order=30, @Icon=NULL, @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'OPDReport', @Source='SEED';
    DECLARE @m144 INT;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID=@m129, @Menu_Type='MENU', @Menu_Code=N'REPORTS.FINANCE_DOCTOR_SETTLEMENT', @Title=N'Finance / Doctor Settlement', @Icon=N'bi bi-cash-coin me-2', @Sort_Order=30, @UserId=NULL, @Menu_ID=@m144 OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m144, @Page_Code=N'REPORTS.DOCTORSETTLEMENTREPORTS', @Title=N'All Settlement Reports', @Controller=N'DoctorSettlementReports', @Action=N'Index', @Show_In_Menu=1, @Sort_Order=10, @Icon=N'bi bi-grid me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorSettlementReports', @Action=N'Index', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m144, @Page_Code=N'REPORTS.DOCTORSETTLEMENTREPORTS.VISITPAYMENTSTATUS', @Title=N'RPT-01: Visit Payment Status', @Controller=N'DoctorSettlementReports', @Action=N'VisitPaymentStatus', @Show_In_Menu=1, @Sort_Order=30, @Icon=N'bi bi-clipboard2-check me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorSettlementReports', @Action=N'VisitPaymentStatus', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m144, @Page_Code=N'REPORTS.DOCTORSETTLEMENTREPORTS.OUTSTANDINGBYVISIT', @Title=N'RPT-02: Outstanding by Visit', @Controller=N'DoctorSettlementReports', @Action=N'OutstandingByVisit', @Show_In_Menu=1, @Sort_Order=40, @Icon=N'bi bi-hourglass-split me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorSettlementReports', @Action=N'OutstandingByVisit', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m144, @Page_Code=N'REPORTS.DOCTORSETTLEMENTREPORTS.DOCTORCOMMISSIONREPORT', @Title=N'RPT-03: Doctor Commission', @Controller=N'DoctorSettlementReports', @Action=N'DoctorCommissionReport', @Show_In_Menu=1, @Sort_Order=50, @Icon=N'bi bi-percent me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorSettlementReports', @Action=N'DoctorCommissionReport', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m144, @Page_Code=N'REPORTS.DOCTORSETTLEMENTREPORTS.DISBURSALREGISTER', @Title=N'RPT-04: Disbursal Register', @Controller=N'DoctorSettlementReports', @Action=N'DisbursalRegister', @Show_In_Menu=1, @Sort_Order=60, @Icon=N'bi bi-journal-bookmark me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorSettlementReports', @Action=N'DisbursalRegister', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m144, @Page_Code=N'REPORTS.DOCTORSETTLEMENTREPORTS.PAYMENTTRANSACTIONS', @Title=N'RPT-05: Payment Transactions', @Controller=N'DoctorSettlementReports', @Action=N'PaymentTransactions', @Show_In_Menu=1, @Sort_Order=70, @Icon=N'bi bi-credit-card-2-front me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorSettlementReports', @Action=N'PaymentTransactions', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m144, @Page_Code=N'REPORTS.DOCTORSETTLEMENTREPORTS.BILLINGADJUSTMENTS', @Title=N'RPT-06: Billing Adjustments', @Controller=N'DoctorSettlementReports', @Action=N'BillingAdjustments', @Show_In_Menu=1, @Sort_Order=80, @Icon=N'bi bi-plus-slash-minus me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorSettlementReports', @Action=N'BillingAdjustments', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m144, @Page_Code=N'REPORTS.DOCTORSETTLEMENTREPORTS.REFUNDREVERSALS', @Title=N'RPT-07: Refund & Reversal', @Controller=N'DoctorSettlementReports', @Action=N'RefundReversals', @Show_In_Menu=1, @Sort_Order=90, @Icon=N'bi bi-arrow-counterclockwise me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorSettlementReports', @Action=N'RefundReversals', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m144, @Page_Code=N'REPORTS.DOCTORSETTLEMENTREPORTS.SETTLEMENTSUMMARY', @Title=N'RPT-08: Settlement Summary', @Controller=N'DoctorSettlementReports', @Action=N'SettlementSummary', @Show_In_Menu=1, @Sort_Order=100, @Icon=N'bi bi-pie-chart-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'DoctorSettlementReports', @Action=N'SettlementSummary', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m129, @Page_Code=N'REPORTS.IPDREPORT', @Title=N'IPD Report', @Controller=N'Reports', @Action=N'IPDReport', @Show_In_Menu=1, @Sort_Order=40, @Icon=N'bi bi-hospital me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'IPDReport', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m129, @Page_Code=N'REPORTS.PATIENTREPORT', @Title=N'Patient Report', @Controller=N'Reports', @Action=N'PatientReport', @Show_In_Menu=1, @Sort_Order=50, @Icon=N'bi bi-person-lines-fill me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'PatientReport', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m129, @Page_Code=N'REPORTS.BILLINGREPORT', @Title=N'Billing Report', @Controller=N'Reports', @Action=N'BillingReport', @Show_In_Menu=1, @Sort_Order=60, @Icon=N'bi bi-receipt me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'BillingReport', @Source='SEED';
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID=@m129, @Page_Code=N'REPORTS.PHARMACYREPORT', @Title=N'Pharmacy Report', @Controller=N'Reports', @Action=N'PharmacyReport', @Show_In_Menu=1, @Sort_Order=70, @Icon=N'bi bi-capsule me-2', @Route_Values=NULL, @Link_Target=NULL, @UserId=NULL, @Page_ID=@page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', @Controller=N'Reports', @Action=N'PharmacyReport', @Source='SEED';

    COMMIT TRANSACTION;
END;
GO

-- ── the whole catalog: menus, pages, page actions and the articles (EMR.Api builds help and search from it) ──
CREATE OR ALTER PROCEDURE dbo.usp_Help_Catalog @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
    SELECT m.Menu_ID AS MenuId, m.Menu_Code AS MenuCode, m.Title, m.Parent_Menu_ID AS ParentMenuId, m.Sort_Order AS SortOrder, m.Icon
      FROM dbo.MenuMaster m WHERE m.CompanyId = @CompanyId AND ISNULL(m.IsActive, 1) = 1
     ORDER BY m.Sort_Order;
    SELECT p.Page_Code AS PageCode, p.Title, m.Menu_Code AS MenuCode, p.Controller, p.Action, p.Icon, p.Sort_Order AS SortOrder
      FROM dbo.PageMaster p JOIN dbo.MenuMaster m ON m.Menu_ID = p.Menu_ID
     WHERE m.CompanyId = @CompanyId AND p.IsActive = 1 AND p.Show_In_Menu = 1
     ORDER BY m.Sort_Order, p.Sort_Order;
    SELECT p.Page_Code AS PageCode, c.Title
      FROM dbo.PageControlMaster c JOIN dbo.PageMaster p ON p.Page_ID = c.Page_ID JOIN dbo.MenuMaster m ON m.Menu_ID = p.Menu_ID
     WHERE m.CompanyId = @CompanyId AND ISNULL(c.IsActive, 1) = 1 AND c.Control_Code <> 'VIEW'
     ORDER BY p.Page_Code, c.Sort_Order;
    SELECT Code, Kind, Module, Title, Summary, PageCodes, Keywords, BodyJson, SortOrder
      FROM dbo.HelpArticle WHERE IsActive = 1 ORDER BY SortOrder;
END
GO

-- the page a screen belongs to (for the ? help of the page you are on)
CREATE OR ALTER PROCEDURE dbo.usp_Help_PageByRoute @CompanyId INT, @Controller NVARCHAR(100), @Action NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SET @CompanyId = 1;   -- 2334: one global navigation tree, roles and role permissions (kept under company 1)
    SELECT TOP 1 p.Page_Code
      FROM dbo.PageMaster p JOIN dbo.MenuMaster m ON m.Menu_ID = p.Menu_ID
     WHERE m.CompanyId = @CompanyId AND p.IsActive = 1 AND p.Controller = @Controller
     ORDER BY CASE WHEN p.Action = @Action THEN 0 WHEN p.Action = 'Index' THEN 1 ELSE 2 END, p.Show_In_Menu DESC, p.Sort_Order;
END
GO

-- ── onboard: everything in one transaction ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_Company_Onboard
    -- company
    @CompanyCode NVARCHAR(50), @CompanyName NVARCHAR(200), @LegalName NVARCHAR(250) = NULL, @RegistrationNumber NVARCHAR(100) = NULL,
    @GSTIN NVARCHAR(50) = NULL, @PAN NVARCHAR(50) = NULL, @Email NVARCHAR(200) = NULL, @Phone NVARCHAR(50) = NULL, @Website NVARCHAR(250) = NULL,
    @Address NVARCHAR(500) = NULL, @Country NVARCHAR(100) = NULL, @State NVARCHAR(100) = NULL, @City NVARCHAR(100) = NULL, @Pincode NVARCHAR(20) = NULL,
    @LogoPath NVARCHAR(500) = NULL,
    -- head office branch
    @BranchCode NVARCHAR(50), @BranchName NVARCHAR(200), @BranchAddress NVARCHAR(500) = NULL, @BranchCountry NVARCHAR(100) = NULL,
    @BranchState NVARCHAR(100) = NULL, @BranchCity NVARCHAR(100) = NULL, @BranchPincode NVARCHAR(20) = NULL, @BranchIsLab BIT = 1,
    -- hospital settings of the branch
    @HospitalName NVARCHAR(200), @HospitalPhone NVARCHAR(50) = NULL, @HospitalEmail NVARCHAR(200) = NULL, @OpdRegistrationValidityDays INT = NULL,
    -- administrator
    @AdminUsername NVARCHAR(100), @AdminFirstName NVARCHAR(100), @AdminLastName NVARCHAR(100), @AdminEmail NVARCHAR(200) = NULL,
    @AdminPhone NVARCHAR(50) = NULL, @AdminEmployeeCode NVARCHAR(50) = NULL, @AdminPasswordHash NVARCHAR(500), @AdminSalt NVARCHAR(200) = NULL,
    @AdminMustChangePassword BIT = 1,
    -- what to copy from the template company
    @TemplateCompanyId INT, @CopyAdminPermissions BIT = 1, @CopyOtherRoles BIT = 1,
    @CreatedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @CompanyCode = UPPER(LTRIM(RTRIM(@CompanyCode)));
    SET @BranchCode = UPPER(LTRIM(RTRIM(@BranchCode)));
    SET @AdminUsername = LTRIM(RTRIM(@AdminUsername));
    IF NULLIF(@CompanyCode, '') IS NULL OR NULLIF(LTRIM(@CompanyName), '') IS NULL THROW 50001, 'Company code and name are required.', 1;
    IF NULLIF(@BranchCode, '') IS NULL OR NULLIF(LTRIM(@BranchName), '') IS NULL THROW 50002, 'Head Office branch code and name are required.', 1;
    IF NULLIF(@AdminUsername, '') IS NULL OR NULLIF(@AdminPasswordHash, '') IS NULL THROW 50003, 'The administrator''s username and password are required.', 1;
    IF EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyCode = @CompanyCode) THROW 50004, 'This company code is already used.', 1;
    IF EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchCode = @BranchCode) THROW 50005, 'This branch code is already used (branch codes are unique in the whole application).', 1;
    IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @AdminUsername) THROW 50006, 'This username is already used.', 1;
    IF NULLIF(LTRIM(@AdminEmail), '') IS NULL THROW 50008, 'The administrator''s e-mail is required - it is the sign-in.', 1;
    IF EXISTS (SELECT 1 FROM dbo.Users WHERE LOWER(LTRIM(RTRIM(Email))) = LOWER(LTRIM(RTRIM(@AdminEmail))) OR Username = LOWER(LTRIM(RTRIM(@AdminEmail))))
        THROW 50009, 'This e-mail is already used by another sign-in.', 1;

    DECLARE @now DATETIME = GETDATE(), @CompanyId INT, @BranchId INT, @SettingsId INT, @AdminRoleId INT, @UserId INT;
    DECLARE @Menus INT = 0, @Pages INT = 0, @Controls INT = 0, @Endpoints INT = 0, @Roles INT = 0, @Permissions INT = 0;

    BEGIN TRANSACTION;

    -- 1. company
    INSERT dbo.CompanyMaster (CompanyCode, CompanyName, LegalName, RegistrationNumber, GSTIN, PAN, Email, Phone, Website, LogoPath,
                              Address, Country, State, City, Pincode, IsActive, CreatedBy, CreatedDate)
    VALUES (@CompanyCode, LTRIM(RTRIM(@CompanyName)), @LegalName, @RegistrationNumber, UPPER(@GSTIN), UPPER(@PAN), @Email, @Phone, @Website, @LogoPath,
            @Address, @Country, @State, @City, @Pincode, 1, @CreatedBy, @now);
    SET @CompanyId = SCOPE_IDENTITY();

    -- 2. head office branch
    INSERT dbo.Branchmaster (BranchName, BranchCode, Country, State, City, Address, Pincode, IsHOBranch, IsActive, CreatedBy, CreatedDate, CompanyId, IsLab)
    VALUES (LTRIM(RTRIM(@BranchName)), @BranchCode, COALESCE(@BranchCountry, @Country), COALESCE(@BranchState, @State), COALESCE(@BranchCity, @City),
            COALESCE(@BranchAddress, @Address), COALESCE(@BranchPincode, @Pincode), 1, 1, @CreatedBy, @now, @CompanyId, ISNULL(@BranchIsLab, 1));
    SET @BranchId = SCOPE_IDENTITY();

    -- 3. hospital settings of the branch (every other parameter takes its default)
    INSERT dbo.HospitalSettings (BranchID, CompanyId, HotelName, Address, ContactNumber1, EmailAddress, Website, GSTCode, LogoPath, RegistrationNumber,
                                 IsActive, CreatedDate, CreatedBy)
    VALUES (@BranchId, @CompanyId, LTRIM(RTRIM(@HospitalName)), COALESCE(@BranchAddress, @Address), COALESCE(@HospitalPhone, @Phone),
            COALESCE(@HospitalEmail, @Email), @Website, UPPER(@GSTIN), @LogoPath, @RegistrationNumber, 1, @now, @CreatedBy);
    SET @SettingsId = SCOPE_IDENTITY();
    IF @OpdRegistrationValidityDays IS NOT NULL
        UPDATE dbo.HospitalSettings SET OpdRegistrationValidityDays = @OpdRegistrationValidityDays WHERE Id = @SettingsId;

    -- 4-5. 2334: the navigation, the roles and the role permissions are global (one set for every company) - nothing is
    --      copied (@TemplateCompanyId / @CopyAdminPermissions / @CopyOtherRoles are kept for callers); the first user gets
    --      the global Administrator role
    SELECT TOP 1 @AdminRoleId = Id FROM dbo.roles WHERE Name = N'Administrator' ORDER BY Id;
    IF @AdminRoleId IS NULL
    BEGIN
        INSERT dbo.roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, IconClass, CompanyId)
        VALUES (N'Administrator', N'Administrator', 1, @now, @now, N'bi-shield-lock', 1);
        SET @AdminRoleId = SCOPE_IDENTITY();
        SET @Roles = 1;
    END

    -- 6. the first user: Administrator of the Head Office
    INSERT dbo.Users (Username, Email, PasswordHash, Salt, FirstName, LastName, FullName, PhoneNumber, Phone, Role, IsActive, IsLockedOut,
                      FailedLoginAttempts, CreatedDate, MustChangePassword, PasswordLastChanged, RequiresMFA, CompanyId, IsSuperAdmin, User_Type)
    VALUES (@AdminUsername, @AdminEmail, @AdminPasswordHash, @AdminSalt, LTRIM(RTRIM(@AdminFirstName)), LTRIM(RTRIM(@AdminLastName)),
            LTRIM(RTRIM(@AdminFirstName)) + N' ' + LTRIM(RTRIM(@AdminLastName)), @AdminPhone, @AdminPhone, N'Administrator', 1, 0,
            0, @now, ISNULL(@AdminMustChangePassword, 1), @now, 0, @CompanyId, 0, 'U');
    SET @UserId = SCOPE_IDENTITY();
    INSERT dbo.UserBranches (UserId, BranchID, IsActive, CreatedBy, CreatedDate, EmployeeCode, CompanyId)
    VALUES (@UserId, @BranchId, 1, @CreatedBy, @now, NULLIF(UPPER(LTRIM(RTRIM(@AdminEmployeeCode))), ''), @CompanyId);
    INSERT dbo.Userroles (UserId, RoleId, IsActive, AssignedDate, AssignedBy, CreatedBy, CreatedDate, Branch_ID)
    VALUES (@UserId, @AdminRoleId, 1, @now, @CreatedBy, @CreatedBy, @now, @BranchId);

    COMMIT TRANSACTION;

    SELECT @CompanyId AS CompanyId, @BranchId AS BranchId, @SettingsId AS HospitalSettingsId, @AdminRoleId AS AdminRoleId, @UserId AS UserId,
           @Menus AS Menus, @Pages AS Pages, @Controls AS Controls, @Endpoints AS Endpoints, @Roles AS Roles, @Permissions AS Permissions;
END
GO

-- ── the companies a new one can copy its navigation (and Administrator role) from ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_Company_OnboardTemplates
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.CompanyId, c.CompanyCode, c.CompanyName,
           (SELECT COUNT(*) FROM dbo.MenuMaster m WHERE m.CompanyId = c.CompanyId) AS Menus,
           (SELECT COUNT(*) FROM dbo.PageMaster p WHERE p.CompanyId = c.CompanyId) AS Pages,
           (SELECT COUNT(*) FROM dbo.roles r) AS Roles /* 2334: roles are global */,
           (SELECT COUNT(*) FROM dbo.RolePermission rp JOIN dbo.roles r ON r.Id = rp.Role_ID
             WHERE r.CompanyId = c.CompanyId AND r.Name = N'Administrator' AND rp.Branch_ID IS NULL) AS AdminPermissions
      FROM dbo.CompanyMaster c
     WHERE c.IsActive = 1 AND EXISTS (SELECT 1 FROM dbo.PageMaster p WHERE p.CompanyId = c.CompanyId)
     ORDER BY c.CompanyId;
END
GO

-- the lists of the wizard: branches (with the mail account each one sends from), roles, specialities
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_Options @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.BranchID AS Id, b.BranchName AS Name, CAST(ISNULL(b.IsHOBranch, 0) AS BIT) AS IsHo,
           (SELECT TOP 1 s.SenderEmail FROM dbo.SmtpEmailConfiguration s WHERE s.BranchId = b.BranchID AND s.IsActive = 1 ORDER BY s.IsDefault DESC, s.Id) AS SenderEmail,
           (SELECT TOP 1 h.HotelName FROM dbo.HospitalSettings h WHERE h.BranchId = b.BranchID) AS HospitalName
      FROM dbo.Branchmaster b WHERE b.CompanyId = @CompanyId AND b.IsActive = 1 ORDER BY b.IsHOBranch DESC, b.BranchName;
    SELECT Id, Name FROM dbo.roles ORDER BY Name;   -- 2334: roles are global
    SELECT SpecialityId AS Id, SpecialityName AS Name FROM dbo.DoctorSpecialityMaster
     WHERE ISNULL(IsActive, 1) = 1 AND ISNULL(CompanyId, @CompanyId) = @CompanyId ORDER BY SpecialityName;
END
GO
PRINT 'Script 2334 applied: roles, navigation and role permissions are global.';
GO
