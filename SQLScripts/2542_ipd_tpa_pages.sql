-- ============================================================================================================
-- 2542: IPD Phase 6 - authorization (pages, controls, endpoints). No grants are seeded: give them in Role Permissions.
--   IPD > Pre-Authorisations (IPD.PREAUTHS): VIEW (worklist with the IRDAI clock).
--   IPD > TPA Claims (IPD.TPACLAIMS): VIEW; SUBMIT (checklist, documents, submit, query / reply, claim details);
--         SETTLE (enter settlements); SETTLE_CANCEL (cancel a settlement); WRITEOFF_APPROVE (approve / reject write-offs,
--         together with the Approval Matrix module IPD.TPAWRITEOFF when one is set for the branch).
--   IPD > TPA Receivable & Ageing (IPD.TPAAGEING): VIEW.
--   Master > IPD Master > TPA Document Checklist (MASTER.IPD_TPADOCS): VIEW; EDIT.
--   IPD Patient (IPD.PATIENT): the Insurance / TPA tab reads with VIEW; control PREAUTH = start / edit the pre-auth,
--         record the TPA's answers, set co-pay / deductible / non-payables, documents (also from the worklist).
-- Needs 2424 (IPD menu, IPD.PATIENT). Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── a page with its VIEW reads and its controls (Code|Title|Sort|POST actions) ─────────────────────────────────
DROP PROCEDURE IF EXISTS #ipd_page;
GO
CREATE PROCEDURE #ipd_page
    @MenuCode NVARCHAR(60), @PageCode NVARCHAR(60), @Title NVARCHAR(150), @Controller NVARCHAR(60), @Action NVARCHAR(60), @Sort INT, @Icon NVARCHAR(60),
    @ViewGets NVARCHAR(400), @Controls NVARCHAR(MAX) = NULL, @ShowInMenu BIT = 1
AS
BEGIN
    DECLARE @nav INT = (SELECT Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = @MenuCode AND CompanyId = 1), @page INT, @view INT, @ctl INT, @a NVARCHAR(60);
    IF @nav IS NULL THROW 58290, 'A menu is missing (IPD / MASTER.IPD_MASTER).', 1;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = 1, @Menu_ID = @nav, @Page_Code = @PageCode, @Title = @Title, @Controller = @Controller, @Action = @Action,
         @Show_In_Menu = @ShowInMenu, @Sort_Order = @Sort, @Icon = @Icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
    DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@ViewGets, ',') WHERE value <> N'';
    OPEN v; FETCH NEXT FROM v INTO @a;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = @Controller, @Action = @a, @Source = 'SEED';
        FETCH NEXT FROM v INTO @a;
    END
    CLOSE v; DEALLOCATE v;
    -- controls: "CODE|Title|Sort|Action1,Action2;CODE2|..."
    DECLARE @line NVARCHAR(MAX), @code NVARCHAR(30), @ct NVARCHAR(200), @cs INT, @acts NVARCHAR(400), @one NVARCHAR(60);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(ISNULL(@Controls, N''), ';') WHERE value <> N'';
    OPEN c; FETCH NEXT FROM c INTO @line;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @code = JSON_VALUE(j, '$[0]'), @ct = JSON_VALUE(j, '$[1]'), @cs = JSON_VALUE(j, '$[2]'), @acts = JSON_VALUE(j, '$[3]')
        FROM (SELECT N'["' + REPLACE(REPLACE(@line, N'"', N'\"'), N'|', N'","') + N'"]' AS j) x;
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @code, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
        DECLARE e CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@acts, ',') WHERE value <> N'';
        OPEN e; FETCH NEXT FROM e INTO @one;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = @Controller, @Action = @one, @Source = 'SEED';
            FETCH NEXT FROM e INTO @one;
        END
        CLOSE e; DEALLOCATE e;
        FETCH NEXT FROM c INTO @line;
    END
    CLOSE c; DEALLOCATE c;
END
GO

EXEC #ipd_page @MenuCode = N'IPD', @PageCode = N'IPD.PREAUTHS', @Title = N'Pre-Authorisations', @Controller = N'IpdInsurance', @Action = N'PreAuths',
     @Sort = 46, @Icon = N'bi bi-shield-check me-2', @ViewGets = N'PreAuths,PreAuthList';
EXEC #ipd_page @MenuCode = N'IPD', @PageCode = N'IPD.TPACLAIMS', @Title = N'TPA Claims', @Controller = N'IpdClaims', @Action = N'Index',
     @Sort = 47, @Icon = N'bi bi-file-earmark-medical me-2', @ViewGets = N'Index,ListData,ClaimData,Lookups',
     @Controls = N'SUBMIT|Claim documents, submission and TPA queries|20|UpdateClaim,Submit,ClaimEvent,Checklist,UploadDocument;SETTLE|Enter claim settlements (amount, TDS, disallowance)|30|Settle;SETTLE_CANCEL|Cancel a claim settlement (with a reason)|40|CancelSettlement;WRITEOFF_APPROVE|Approve or reject claim write-offs|50|DecideWriteOff';
EXEC #ipd_page @MenuCode = N'IPD', @PageCode = N'IPD.TPAAGEING', @Title = N'TPA Receivable & Ageing', @Controller = N'IpdClaims', @Action = N'Ageing',
     @Sort = 48, @Icon = N'bi bi-hourglass-split me-2', @ViewGets = N'Ageing,AgeingData,StatementData,AgeingLookups';
EXEC #ipd_page @MenuCode = N'MASTER.IPD_MASTER', @PageCode = N'MASTER.IPD_TPADOCS', @Title = N'TPA Document Checklist', @Controller = N'IpdClaims', @Action = N'DocTypes',
     @Sort = 255, @Icon = N'bi bi-card-checklist me-2', @ViewGets = N'DocTypes,DocTypesData', @Controls = N'EDIT|Add / edit documents|20|SaveDocType';
GO

-- ── IPD Patient: the Insurance / TPA tab ───────────────────────────────────────────────────────────────────────
DECLARE @pp INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT' AND CompanyId = 1), @pv INT, @ctl INT, @a NVARCHAR(60);
IF @pp IS NULL THROW 58291, 'Page IPD.PATIENT is missing (SQLScripts/2424).', 1;
SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'VIEW';
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'TabData,Lookups', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdInsurance', @Action = @a, @Source = 'SEED';
    FETCH NEXT FROM v INTO @a;
END
CLOSE v; DEALLOCATE v;
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @pp, @Control_Code = 'PREAUTH', @Title = N'Insurance / TPA: pre-authorisation, TPA answers, patient share, documents', @Sort_Order = 130, @Control_ID = @ctl OUTPUT;
DECLARE p CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'SavePreAuth,PreAuthEvent,SaveSplit,Checklist,UploadDocument', ',');
OPEN p; FETCH NEXT FROM p INTO @a;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdInsurance', @Action = @a, @Source = 'SEED';
    FETCH NEXT FROM p INTO @a;
END
CLOSE p; DEALLOCATE p;
GO

DROP PROCEDURE IF EXISTS #ipd_page;
GO
PRINT 'Script 2542 applied: IPD Insurance / TPA pages and controls.';
GO
