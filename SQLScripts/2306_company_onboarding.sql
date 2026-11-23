-- ============================================================================================================
-- Migration: 2306_company_onboarding.sql
-- Settings > Company Master > New Company: a wizard that creates a ready-to-use company in one step, in one
-- transaction (all or nothing):
--   1. the company (CompanyMaster)
--   2. its Head Office branch (Branchmaster, IsHOBranch = 1)
--   3. the Hospital Settings row of that branch (defaults for everything not entered)
--   4. its navigation, copied from a template company: menus, pages, page actions and endpoint mappings - so the new
--      company gets today's complete menu (the original seed, 2163, is older than many pages)
--   5. its Administrator role (optionally also the template's other role names, without permissions) and,
--      only when asked, the template Administrator's company-wide permissions (grants are the operator's choice)
--   6. its first user: active, Administrator in the Head Office branch, "change password" reminder on
-- Data goes EMR.Web -> EMR.Api (api/company-onboarding) -> the procedures below. Only Super Admin may onboard.
-- The administrator signs in with the e-mail (2307): it is required, unique among all users, and is the user name.
-- Safe to re-run (procedures only, plus endpoint mappings).
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── is a value free? (company code, branch code - unique in the whole application - and username) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_Company_OnboardCheck
    @CompanyCode NVARCHAR(50) = NULL, @BranchCode NVARCHAR(50) = NULL, @Username NVARCHAR(100) = NULL, @Email NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(CASE WHEN NULLIF(LTRIM(@CompanyCode), '') IS NULL THEN 1
                     WHEN EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyCode = LTRIM(RTRIM(@CompanyCode))) THEN 0 ELSE 1 END AS BIT) AS CompanyCodeFree,
           CAST(CASE WHEN NULLIF(LTRIM(@BranchCode), '') IS NULL THEN 1
                     WHEN EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchCode = LTRIM(RTRIM(@BranchCode))) THEN 0 ELSE 1 END AS BIT) AS BranchCodeFree,
           CAST(CASE WHEN NULLIF(LTRIM(@Username), '') IS NULL THEN 1
                     WHEN EXISTS (SELECT 1 FROM dbo.Users WHERE Username = LTRIM(RTRIM(@Username))) THEN 0 ELSE 1 END AS BIT) AS UsernameFree,
           -- sign-in is by e-mail (2307): unique among all users
           CAST(CASE WHEN NULLIF(LTRIM(@Email), '') IS NULL THEN 1
                     WHEN EXISTS (SELECT 1 FROM dbo.Users WHERE LOWER(LTRIM(RTRIM(Email))) = LOWER(LTRIM(RTRIM(@Email)))
                                                            OR Username = LOWER(LTRIM(RTRIM(@Email)))) THEN 0 ELSE 1 END AS BIT) AS EmailFree;
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
           (SELECT COUNT(*) FROM dbo.roles r WHERE r.CompanyId = c.CompanyId) AS Roles,
           (SELECT COUNT(*) FROM dbo.RolePermission rp JOIN dbo.roles r ON r.Id = rp.Role_ID
             WHERE r.CompanyId = c.CompanyId AND r.Name = N'Administrator' AND rp.Branch_ID IS NULL) AS AdminPermissions
      FROM dbo.CompanyMaster c
     WHERE c.IsActive = 1 AND EXISTS (SELECT 1 FROM dbo.PageMaster p WHERE p.CompanyId = c.CompanyId)
     ORDER BY c.CompanyId;
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
    IF NOT EXISTS (SELECT 1 FROM dbo.PageMaster WHERE CompanyId = @TemplateCompanyId) THROW 50007, 'The template company has no navigation to copy.', 1;

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

    -- 4. navigation copied from the template company (old id -> new id maps through MERGE ... OUTPUT)
    DECLARE @menuMap TABLE (OldId INT PRIMARY KEY, NewId INT);
    MERGE dbo.MenuMaster AS t
    USING (SELECT * FROM dbo.MenuMaster WHERE CompanyId = @TemplateCompanyId) AS s ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (CompanyId, Parent_Menu_ID, Menu_Type, Menu_Code, Title, Icon, Sort_Order, IsActive, CreatedBy, CreatedDate)
        VALUES (@CompanyId, NULL, s.Menu_Type, s.Menu_Code, s.Title, s.Icon, s.Sort_Order, s.IsActive, @CreatedBy, @now)
    OUTPUT s.Menu_ID, inserted.Menu_ID INTO @menuMap (OldId, NewId);
    UPDATE m SET m.Parent_Menu_ID = pm.NewId
      FROM dbo.MenuMaster m
      JOIN @menuMap mm ON mm.NewId = m.Menu_ID
      JOIN dbo.MenuMaster src ON src.Menu_ID = mm.OldId
      JOIN @menuMap pm ON pm.OldId = src.Parent_Menu_ID;
    SELECT @Menus = COUNT(*) FROM @menuMap;

    DECLARE @pageMap TABLE (OldId INT PRIMARY KEY, NewId INT);
    MERGE dbo.PageMaster AS t
    USING (SELECT p.*, mm.NewId AS NewMenuId FROM dbo.PageMaster p LEFT JOIN @menuMap mm ON mm.OldId = p.Menu_ID
            WHERE p.CompanyId = @TemplateCompanyId) AS s ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (CompanyId, Menu_ID, Page_Code, Title, Controller, Action, Area, Show_In_Menu, Sort_Order, IsActive, CreatedBy, CreatedDate, Icon, Route_Values, Link_Target)
        VALUES (@CompanyId, s.NewMenuId, s.Page_Code, s.Title, s.Controller, s.Action, s.Area, s.Show_In_Menu, s.Sort_Order, s.IsActive, @CreatedBy, @now,
                s.Icon, s.Route_Values, s.Link_Target)
    OUTPUT s.Page_ID, inserted.Page_ID INTO @pageMap (OldId, NewId);
    SELECT @Pages = COUNT(*) FROM @pageMap;

    DECLARE @ctlMap TABLE (OldId INT PRIMARY KEY, NewId INT);
    MERGE dbo.PageControlMaster AS t
    USING (SELECT c.*, pm.NewId AS NewPageId FROM dbo.PageControlMaster c JOIN @pageMap pm ON pm.OldId = c.Page_ID) AS s ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (Page_ID, Control_Code, Title, Sort_Order, IsActive, CreatedBy, CreatedDate)
        VALUES (s.NewPageId, s.Control_Code, s.Title, s.Sort_Order, s.IsActive, @CreatedBy, @now)
    OUTPUT s.Control_ID, inserted.Control_ID INTO @ctlMap (OldId, NewId);
    SELECT @Controls = COUNT(*) FROM @ctlMap;

    INSERT dbo.PageEndpointMap (Page_ID, Control_ID, App, Http_Method, Controller, Action, Route, IsActive, CreatedDate, Source,
                                Discovered_On, Last_Seen_On, Is_Orphaned, Is_Public)
    SELECT pm.NewId, cm.NewId, e.App, e.Http_Method, e.Controller, e.Action, e.Route, e.IsActive, @now, e.Source,
           e.Discovered_On, e.Last_Seen_On, e.Is_Orphaned, e.Is_Public
      FROM dbo.PageEndpointMap e
      JOIN @pageMap pm ON pm.OldId = e.Page_ID
      LEFT JOIN @ctlMap cm ON cm.OldId = e.Control_ID
     WHERE e.Control_ID IS NULL OR cm.NewId IS NOT NULL;
    SET @Endpoints = @@ROWCOUNT;

    -- 5. roles: Administrator (from the template's, or a new one), optionally the template's other role names
    INSERT dbo.roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, IconClass, CompanyId)
    SELECT TOP 1 r.Name, r.Description, r.IsSystemRole, @now, @now, r.IconClass, @CompanyId
      FROM dbo.roles r WHERE r.CompanyId = @TemplateCompanyId AND r.Name = N'Administrator' ORDER BY r.Id;
    IF @@ROWCOUNT = 0
        INSERT dbo.roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, IconClass, CompanyId)
        VALUES (N'Administrator', N'Company administrator', 1, @now, @now, N'bi-shield-lock', @CompanyId);
    SET @AdminRoleId = SCOPE_IDENTITY();
    SET @Roles = 1;
    IF @CopyOtherRoles = 1
    BEGIN
        INSERT dbo.roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, IconClass, CompanyId)
        SELECT r.Name, r.Description, r.IsSystemRole, @now, @now, r.IconClass, @CompanyId
          FROM dbo.roles r WHERE r.CompanyId = @TemplateCompanyId AND r.Name <> N'Administrator';
        SET @Roles = @Roles + @@ROWCOUNT;
    END

    -- the template Administrator's company-wide grants (branch-specific ones belong to the template's branches)
    IF @CopyAdminPermissions = 1
    BEGIN
        INSERT dbo.RolePermission (Role_ID, Menu_ID, Page_ID, Control_ID, Branch_ID, Permission, CompanyId, Reason, CreatedBy, CreatedDate)
        SELECT @AdminRoleId, mm.NewId, pm.NewId, cm.NewId, NULL, rp.Permission, @CompanyId,
               N'Copied from the template company at onboarding', @CreatedBy, @now
          FROM dbo.RolePermission rp
          JOIN dbo.roles r ON r.Id = rp.Role_ID AND r.CompanyId = @TemplateCompanyId AND r.Name = N'Administrator'
          LEFT JOIN @menuMap mm ON mm.OldId = rp.Menu_ID
          LEFT JOIN @pageMap pm ON pm.OldId = rp.Page_ID
          LEFT JOIN @ctlMap cm ON cm.OldId = rp.Control_ID
         WHERE rp.Branch_ID IS NULL
           AND (rp.Menu_ID IS NULL OR mm.NewId IS NOT NULL)
           AND (rp.Page_ID IS NULL OR pm.NewId IS NOT NULL)
           AND (rp.Control_ID IS NULL OR cm.NewId IS NOT NULL);
        SET @Permissions = @@ROWCOUNT;
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

-- ── endpoints: under Company Master (Web: the wizard's calls; API: api/company-onboarding) ──
DECLARE @page INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'SETTINGS.COMPANIES';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'Companies', @Action = N'Onboard',      @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'Companies', @Action = N'Onboard',      @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'Companies', @Action = N'OnboardCheck', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'Companies', @Action = N'OnboardGeo',   @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'Companies', @Action = N'Onboarded',    @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET',  @Controller = N'CompanyOnboarding', @Action = N'Templates', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET',  @Controller = N'CompanyOnboarding', @Action = N'Check',     @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'POST', @Controller = N'CompanyOnboarding', @Action = N'Onboard',   @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT 'Script 2306 applied: Company onboarding wizard (company + Head Office + Hospital Settings + navigation + Administrator).';
GO
