-- ============================================================================
-- Migration: 2180_authorization_microbiology_reporting_page.sql
-- Description: LAB > Microbiology Report Entry (MicrobiologyReporting/Index) in the database navigation and the
--   page catalogue: page LAB.MICROBIOLOGYREPORTING under the LAB menu, right after Image Report Entry (Sort 65),
--   with the controls of Lab Report Entry - VIEW, ENTRY (result entry / submit), SAMPLE_STATUS (re-collect / reject),
--   VALIDATE and APPROVE (checked inside the save) and PRINT - and every endpoint the list and entry screens call mapped.
--   No role or user grant is seeded: who may open the page is set in Settings > Security > Role Permissions.
--   Run after 2179.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @co INT, @menu INT, @page INT, @ctl INT;
DECLARE @Controls TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES
    ('ENTRY',    N'Report entry', 75),
    ('SAMPLE_STATUS', N'Reject / re-collect sample', 80),
    ('PRINT',    N'Print', 70),
    ('VALIDATE', N'Validate', 88),
    ('APPROVE',  N'Approve a report (save with status Approved)', 90);
DECLARE @Map TABLE (Method VARCHAR(10), Ctrl NVARCHAR(150), Action NVARCHAR(150), Control VARCHAR(30));
INSERT INTO @Map VALUES
 ('GET', 'MicrobiologyReporting', 'Index',                       'VIEW'),
 ('GET', 'MicrobiologyReporting', 'GetHeadersJson',              'VIEW'),
 ('GET', 'MicrobiologyReporting', 'Entry',                       'ENTRY'),
 ('POST','MicrobiologyReporting', 'SaveEntryJson',               'ENTRY'),
 ('POST','MicrobiologyReporting', 'UpdateSampleStatusJson',      'SAMPLE_STATUS'),
 ('POST','MicrobiologyReporting', 'CalculateFormulasJson',       'VIEW'),
 ('GET', 'MicrobiologyReporting', 'PrintReportPdf',              'PRINT'),
 ('POST','MicrobiologyReporting', 'LogReportPrintedJson',        'PRINT'),
 ('GET', 'LabReporting',          'GetCategoriesForDropdown',    'VIEW'),
 ('GET', 'LabReporting',          'GetSubCategoriesForDropdown', 'VIEW'),
 ('GET', 'LabReporting',          'GetAuditHistoryJson',         'VIEW');

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'LAB.MICROBIOLOGYREPORTING',
             @Title = N'Microbiology Report Entry', @Controller = N'MicrobiologyReporting', @Action = N'Index',
             @Show_In_Menu = 1, @Sort_Order = 65, @Icon = N'bi bi-virus me-2 text-success',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;

        DECLARE @c VARCHAR(30), @t NVARCHAR(150), @s INT;
        DECLARE ctl CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls;
        OPEN ctl; FETCH NEXT FROM ctl INTO @c, @t, @s;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @c, @Title = @t, @Sort_Order = @s, @Control_ID = @ctl OUTPUT;
            FETCH NEXT FROM ctl INTO @c, @t, @s;
        END
        CLOSE ctl; DEALLOCATE ctl;

        DECLARE @m VARCHAR(10), @k1 NVARCHAR(150), @a NVARCHAR(150), @k VARCHAR(30);
        DECLARE mp CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Ctrl, Action, Control FROM @Map;
        OPEN mp; FETCH NEXT FROM mp INTO @m, @k1, @a, @k;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ctl = NULL;
            SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @k;
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @m,
                 @Controller = @k1, @Action = @a, @Source = 'SEED';
            FETCH NEXT FROM mp INTO @m, @k1, @a, @k;
        END
        CLOSE mp; DEALLOCATE mp;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

-- Other screens open a bill on Lab Report Entry (Report Approval Dashboard, Un-Authorize Report, Patient Orders ...).
-- A microbiology bill opens on Microbiology Report Entry instead, so wherever LabReporting/Entry is placed on another
-- page, MicrobiologyReporting/Entry gets the same placement and control.
DECLARE @op INT, @oc INT;
DECLARE oe CURSOR LOCAL FAST_FORWARD FOR
    SELECT m.Page_ID, m.Control_ID
    FROM dbo.PageEndpointMap m
    INNER JOIN dbo.PageMaster p ON p.Page_ID = m.Page_ID
    WHERE m.App = 'WEB' AND m.Http_Method = 'GET' AND m.Controller = 'LabReporting' AND m.Action = 'Entry'
      AND p.Page_Code <> 'LAB.LABREPORTING';
OPEN oe; FETCH NEXT FROM oe INTO @op, @oc;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @op, @Control_ID = @oc, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'MicrobiologyReporting', @Action = N'Entry', @Source = 'SEED';
    FETCH NEXT FROM oe INTO @op, @oc;
END
CLOSE oe; DEALLOCATE oe;

-- Report Approval Dashboard: a microbiology-only bill prints its Microbiology Report from the sign-off page,
-- placed like Lab Report Entry's print endpoints on that page.
DECLARE @pd INT, @pdView INT, @pdPrint INT;
DECLARE pdc CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = 'LAB.PATHOLOGISTDASHBOARD';
OPEN pdc; FETCH NEXT FROM pdc INTO @pd;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @pdView = NULL; SET @pdPrint = NULL;
    SELECT @pdView = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pd AND Control_Code = 'VIEW';
    SELECT @pdPrint = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pd AND Control_Code = 'PRINT';
    IF @pdPrint IS NULL SET @pdPrint = @pdView;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pd, @Control_ID = @pdPrint, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'MicrobiologyReporting', @Action = N'PrintReportPdf', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pd, @Control_ID = @pdPrint, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'MicrobiologyReporting', @Action = N'LogReportPrintedJson', @Source = 'SEED';
    FETCH NEXT FROM pdc INTO @pd;
END
CLOSE pdc; DEALLOCATE pdc;
GO

PRINT 'Script 2180 applied: LAB > Microbiology Report Entry page catalogue.';
GO
