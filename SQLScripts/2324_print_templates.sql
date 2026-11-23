-- ============================================================================================================
-- Migration: 2324_print_templates.sql
-- Utility > Print Templates: header and footer templates for printed bills (LAB B2C bill, OPD bill) and lab reports
-- (numeric and microbiology PDF, print / email / WhatsApp). A template is a layout of rows -> columns -> blocks
-- (logo, data fields picked from the branch's Hospital Settings and the document, text, barcode, line, page info ...)
-- stored as JSON; EMR.Web draws it in the bill page and in the report PDF from the same layout.
--   * Kind: BILL or REPORT.  Draft (being designed) and the published layout are kept apart: printing uses only the
--     published one. Every publish is kept as a version and can be restored into the draft.
--   * Assignment: per branch and kind. No assignment = the built-in "Classic" header and footer (today's print).
-- Data goes EMR.Web -> EMR.Api (api/print-templates) -> the procedures below. Page UTILITY.PRINTTEMPLATES with the
-- controls shown in Settings > Security > Role Permissions: VIEW (list, open, preview), EDIT (create, copy, design,
-- restore a version), PUBLISH (make live), ASSIGN (choose the template of each branch), DELETE (remove an unused one).
-- Changing templates is also limited to the head office (EMR.Web); other branches only view. No role is granted it here.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.PrintTemplate', N'U') IS NULL
CREATE TABLE dbo.PrintTemplate
(
    TemplateId    INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PrintTemplate PRIMARY KEY,
    CompanyId     INT            NOT NULL,
    Kind          VARCHAR(10)    NOT NULL CONSTRAINT CK_PrintTemplate_Kind CHECK (Kind IN ('BILL', 'REPORT')),
    Name          NVARCHAR(100)  NOT NULL,
    DraftJson     NVARCHAR(MAX)  NOT NULL,
    LayoutJson    NVARCHAR(MAX)  NULL,              -- the published layout (NULL = never published)
    Version       INT            NOT NULL CONSTRAINT DF_PrintTemplate_Version DEFAULT (0),
    IsActive      BIT            NOT NULL CONSTRAINT DF_PrintTemplate_IsActive DEFAULT (1),
    CreatedBy     INT            NULL,
    CreatedDate   DATETIME       NOT NULL CONSTRAINT DF_PrintTemplate_Created DEFAULT (GETDATE()),
    ModifiedBy    INT            NULL,
    ModifiedDate  DATETIME       NOT NULL CONSTRAINT DF_PrintTemplate_Modified DEFAULT (GETDATE()),
    PublishedBy   INT            NULL,
    PublishedDate DATETIME       NULL
);
GO
IF OBJECT_ID(N'dbo.PrintTemplateVersion', N'U') IS NULL
CREATE TABLE dbo.PrintTemplateVersion
(
    VersionId     INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PrintTemplateVersion PRIMARY KEY,
    TemplateId    INT            NOT NULL,
    VersionNo     INT            NOT NULL,
    LayoutJson    NVARCHAR(MAX)  NOT NULL,
    PublishedBy   INT            NULL,
    PublishedDate DATETIME       NOT NULL CONSTRAINT DF_PrintTemplateVersion_Date DEFAULT (GETDATE())
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PrintTemplateVersion_Template' AND object_id = OBJECT_ID(N'dbo.PrintTemplateVersion'))
    CREATE INDEX IX_PrintTemplateVersion_Template ON dbo.PrintTemplateVersion (TemplateId, VersionNo);
GO
IF OBJECT_ID(N'dbo.PrintTemplateAssignment', N'U') IS NULL
CREATE TABLE dbo.PrintTemplateAssignment
(
    CompanyId    INT          NOT NULL,
    BranchId     INT          NOT NULL,
    Kind         VARCHAR(10)  NOT NULL,
    TemplateId   INT          NOT NULL,
    ModifiedBy   INT          NULL,
    ModifiedDate DATETIME     NOT NULL CONSTRAINT DF_PrintTemplateAssignment_Modified DEFAULT (GETDATE()),
    CONSTRAINT PK_PrintTemplateAssignment PRIMARY KEY (CompanyId, BranchId, Kind)
);
GO

-- the company's templates, with the branches that print with each
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_List @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT t.TemplateId, t.Kind, t.Name, t.Version,
           CAST(CASE WHEN t.LayoutJson IS NULL THEN 0 ELSE 1 END AS BIT) AS IsPublished,
           CAST(CASE WHEN t.LayoutJson IS NOT NULL AND t.DraftJson <> t.LayoutJson THEN 1 ELSE 0 END AS BIT) AS HasUnpublishedChanges,
           t.ModifiedDate, COALESCE(NULLIF(u.FullName, N''), u.Username) AS ModifiedByName, t.PublishedDate,
           (SELECT STRING_AGG(b.BranchName, N', ') FROM dbo.PrintTemplateAssignment a
              INNER JOIN dbo.Branchmaster b ON b.BranchID = a.BranchId
             WHERE a.TemplateId = t.TemplateId AND a.CompanyId = @CompanyId) AS Branches
    FROM dbo.PrintTemplate t
    LEFT JOIN dbo.Users u ON u.Id = t.ModifiedBy
    WHERE t.CompanyId = @CompanyId AND t.IsActive = 1
    ORDER BY t.Kind, t.Name;
END
GO

-- one template (RS1) and its published versions (RS2)
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_Get @CompanyId INT, @TemplateId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT t.TemplateId, t.Kind, t.Name, t.DraftJson, t.LayoutJson, t.Version,
           CAST(CASE WHEN t.LayoutJson IS NULL THEN 0 ELSE 1 END AS BIT) AS IsPublished, t.ModifiedDate, t.PublishedDate
    FROM dbo.PrintTemplate t
    WHERE t.CompanyId = @CompanyId AND t.TemplateId = @TemplateId AND t.IsActive = 1;

    SELECT v.VersionNo, v.PublishedDate, COALESCE(NULLIF(u.FullName, N''), u.Username) AS PublishedByName
    FROM dbo.PrintTemplateVersion v
    INNER JOIN dbo.PrintTemplate t ON t.TemplateId = v.TemplateId AND t.CompanyId = @CompanyId
    LEFT JOIN dbo.Users u ON u.Id = v.PublishedBy
    WHERE v.TemplateId = @TemplateId
    ORDER BY v.VersionNo DESC;
END
GO

-- create (@TemplateId 0) or save the draft of a template; returns its id
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_Save
    @CompanyId INT, @TemplateId INT, @Kind VARCHAR(10), @Name NVARCHAR(100), @DraftJson NVARCHAR(MAX), @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Name = LTRIM(RTRIM(@Name));
    IF NULLIF(@Name, N'') IS NULL THROW 54001, 'Enter the template name.', 1;
    IF @Kind NOT IN ('BILL', 'REPORT') THROW 54002, 'Choose Bill or Lab Report.', 1;
    IF ISJSON(@DraftJson) = 0 THROW 54003, 'The layout could not be read.', 1;
    IF EXISTS (SELECT 1 FROM dbo.PrintTemplate WHERE CompanyId = @CompanyId AND Kind = @Kind AND Name = @Name AND IsActive = 1 AND TemplateId <> ISNULL(@TemplateId, 0))
        THROW 54004, 'Another template of this kind already has this name.', 1;

    IF ISNULL(@TemplateId, 0) = 0
    BEGIN
        INSERT dbo.PrintTemplate (CompanyId, Kind, Name, DraftJson, CreatedBy, ModifiedBy)
        VALUES (@CompanyId, @Kind, @Name, @DraftJson, @UserId, @UserId);
        SELECT CAST(SCOPE_IDENTITY() AS INT) AS TemplateId;
        RETURN;
    END

    UPDATE dbo.PrintTemplate SET Name = @Name, DraftJson = @DraftJson, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE CompanyId = @CompanyId AND TemplateId = @TemplateId AND IsActive = 1;
    IF @@ROWCOUNT = 0 THROW 54005, 'Template not found.', 1;
    SELECT @TemplateId AS TemplateId;
END
GO

-- the draft goes live: a new version, used by every branch the template is assigned to
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_Publish @CompanyId INT, @TemplateId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @json NVARCHAR(MAX), @ver INT;
    SELECT @json = DraftJson, @ver = Version + 1 FROM dbo.PrintTemplate WHERE CompanyId = @CompanyId AND TemplateId = @TemplateId AND IsActive = 1;
    IF @json IS NULL THROW 54005, 'Template not found.', 1;
    BEGIN TRANSACTION;
        UPDATE dbo.PrintTemplate SET LayoutJson = @json, Version = @ver, PublishedBy = @UserId, PublishedDate = GETDATE()
        WHERE TemplateId = @TemplateId;
        INSERT dbo.PrintTemplateVersion (TemplateId, VersionNo, LayoutJson, PublishedBy) VALUES (@TemplateId, @ver, @json, @UserId);
    COMMIT TRANSACTION;
    SELECT @ver AS Version;
END
GO

-- a published version back into the draft (publish again to make it live)
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_Restore @CompanyId INT, @TemplateId INT, @VersionNo INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @json NVARCHAR(MAX) = (SELECT v.LayoutJson FROM dbo.PrintTemplateVersion v
                                   INNER JOIN dbo.PrintTemplate t ON t.TemplateId = v.TemplateId AND t.CompanyId = @CompanyId AND t.IsActive = 1
                                   WHERE v.TemplateId = @TemplateId AND v.VersionNo = @VersionNo);
    IF @json IS NULL THROW 54006, 'That version was not found.', 1;
    UPDATE dbo.PrintTemplate SET DraftJson = @json, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE TemplateId = @TemplateId;
END
GO

-- a template no branch uses can be removed
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_Delete @CompanyId INT, @TemplateId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM dbo.PrintTemplateAssignment WHERE CompanyId = @CompanyId AND TemplateId = @TemplateId)
        THROW 54007, 'Branches still print with this template. Assign them another template (or Classic) first.', 1;
    UPDATE dbo.PrintTemplate SET IsActive = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE CompanyId = @CompanyId AND TemplateId = @TemplateId;
END
GO

-- every active branch with the template it prints its bills and reports with (NULL = Classic)
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_Assignments @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.BranchID AS BranchId, b.BranchName, CAST(b.IsHOBranch AS BIT) AS IsHOBranch,
           (SELECT a.TemplateId FROM dbo.PrintTemplateAssignment a WHERE a.CompanyId = @CompanyId AND a.BranchId = b.BranchID AND a.Kind = 'BILL') AS BillTemplateId,
           (SELECT a.TemplateId FROM dbo.PrintTemplateAssignment a WHERE a.CompanyId = @CompanyId AND a.BranchId = b.BranchID AND a.Kind = 'REPORT') AS ReportTemplateId
    FROM dbo.Branchmaster b
    WHERE b.IsActive = 1 AND ISNULL(b.CompanyId, 1) = @CompanyId
    ORDER BY CASE WHEN b.IsHOBranch = 1 THEN 0 ELSE 1 END, b.BranchName;
END
GO

-- set the template of a branch for bills or reports (@TemplateId NULL = Classic); only a published template
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_Assign @CompanyId INT, @BranchId INT, @Kind VARCHAR(10), @TemplateId INT = NULL, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Kind NOT IN ('BILL', 'REPORT') THROW 54002, 'Choose Bill or Lab Report.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND ISNULL(CompanyId, 1) = @CompanyId)
        THROW 54008, 'Branch not found.', 1;
    IF @TemplateId IS NULL
    BEGIN
        DELETE dbo.PrintTemplateAssignment WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND Kind = @Kind;
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PrintTemplate WHERE CompanyId = @CompanyId AND TemplateId = @TemplateId AND Kind = @Kind AND IsActive = 1 AND LayoutJson IS NOT NULL)
        THROW 54009, 'Only a published template of the same kind can be assigned.', 1;
    MERGE dbo.PrintTemplateAssignment AS a
    USING (SELECT @CompanyId AS CompanyId, @BranchId AS BranchId, @Kind AS Kind) s
       ON a.CompanyId = s.CompanyId AND a.BranchId = s.BranchId AND a.Kind = s.Kind
    WHEN MATCHED THEN UPDATE SET TemplateId = @TemplateId, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHEN NOT MATCHED THEN INSERT (CompanyId, BranchId, Kind, TemplateId, ModifiedBy) VALUES (@CompanyId, @BranchId, @Kind, @TemplateId, @UserId);
END
GO

-- what a branch prints with: the published layout of its template (no row = Classic)
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_Resolve @BranchId INT, @Kind VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT t.TemplateId, t.Version, t.LayoutJson
    FROM dbo.PrintTemplateAssignment a
    INNER JOIN dbo.Branchmaster b ON b.BranchID = a.BranchId AND ISNULL(b.CompanyId, 1) = a.CompanyId
    INNER JOIN dbo.PrintTemplate t ON t.TemplateId = a.TemplateId AND t.IsActive = 1 AND t.LayoutJson IS NOT NULL
    WHERE a.BranchId = @BranchId AND a.Kind = @Kind;
END
GO

-- ── Utility > Print Templates: page, controls, endpoints (no role grants) ──────────────────────────────────
DECLARE @co INT, @menu INT, @page INT, @ctl INT, @pc NVARCHAR(150) = N'UTILITY.PRINTTEMPLATES';
DECLARE @Endpoints TABLE (App VARCHAR(5), Method VARCHAR(10), Controller NVARCHAR(100), Action NVARCHAR(100), Code VARCHAR(30));
INSERT @Endpoints VALUES
    ('WEB', 'GET',  N'PrintTemplates', N'Index',          'VIEW'),
    ('WEB', 'GET',  N'PrintTemplates', N'Designer',       'VIEW'),
    ('WEB', 'POST', N'PrintTemplates', N'Render',         'VIEW'),
    ('WEB', 'GET',  N'PrintTemplates', N'PreviewBill',    'VIEW'),
    ('WEB', 'GET',  N'PrintTemplates', N'PreviewReport',  'VIEW'),
    ('WEB', 'POST', N'PrintTemplates', N'Create',         'EDIT'),
    ('WEB', 'POST', N'PrintTemplates', N'Save',           'EDIT'),
    ('WEB', 'POST', N'PrintTemplates', N'Copy',           'EDIT'),
    ('WEB', 'POST', N'PrintTemplates', N'Delete',         'DELETE'),
    ('WEB', 'POST', N'PrintTemplates', N'Restore',        'EDIT'),
    ('WEB', 'POST', N'PrintTemplates', N'UploadImage',    'EDIT'),
    ('WEB', 'POST', N'PrintTemplates', N'Publish',        'PUBLISH'),
    ('WEB', 'POST', N'PrintTemplates', N'Assign',         'ASSIGN'),
    ('API', 'GET',  N'PrintTemplates', N'List',           'VIEW'),
    ('API', 'GET',  N'PrintTemplates', N'Get',            'VIEW'),
    ('API', 'GET',  N'PrintTemplates', N'Assignments',    'VIEW'),
    ('API', 'GET',  N'PrintTemplates', N'Resolve',        'VIEW'),
    ('API', 'POST', N'PrintTemplates', N'Save',           'EDIT'),
    ('API', 'POST', N'PrintTemplates', N'Delete',         'DELETE'),
    ('API', 'POST', N'PrintTemplates', N'Restore',        'EDIT'),
    ('API', 'POST', N'PrintTemplates', N'Publish',        'PUBLISH'),
    ('API', 'POST', N'PrintTemplates', N'Assign',         'ASSIGN');

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = (SELECT TOP 1 Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'UTILITY' AND CompanyId = @co);
    IF @menu IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @pc, @Title = N'Print Templates',
             @Controller = N'PrintTemplates', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 42, @Icon = N'bi bi-layout-text-window me-2',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'View templates and preview', @Sort_Order = 10, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Design templates (drafts)', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'PUBLISH', @Title = N'Publish templates (make them live)', @Sort_Order = 30, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'ASSIGN', @Title = N'Choose the template of each branch', @Sort_Order = 40, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'DELETE', @Title = N'Remove a template no branch uses', @Sort_Order = 50, @Control_ID = @ctl OUTPUT;

        DECLARE @app VARCHAR(5), @method VARCHAR(10), @controller NVARCHAR(100), @action NVARCHAR(100), @code VARCHAR(30);
        DECLARE e1 CURSOR LOCAL FAST_FORWARD FOR SELECT App, Method, Controller, Action, Code FROM @Endpoints;
        OPEN e1; FETCH NEXT FROM e1 INTO @app, @method, @controller, @action, @code;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ctl = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @code);
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = @app, @Http_Method = @method,
                 @Controller = @controller, @Action = @action, @Source = 'SEED';
            FETCH NEXT FROM e1 INTO @app, @method, @controller, @action, @code;
        END
        CLOSE e1; DEALLOCATE e1;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2324 applied: Utility > Print Templates (bill and lab report header / footer).';
GO
