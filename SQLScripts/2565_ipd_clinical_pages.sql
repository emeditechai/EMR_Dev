-- 2565: IPD Phase 3 - authorization (controls, endpoints, IPD > Nursing Station). No grants are seeded: give them in Role Permissions.
--   IPD Patient (IPD.PATIENT) controls:
--     doctor  : CLIN_ASSESS (doctor's initial assessment), CLIN_NOTE (rounds / progress notes), CLIN_ORDER (orders: write, stop, cancel,
--               link the pharmacy indent), CLIN_COUNTERSIGN (countersign a verbal / telephone order), CLIN_CONSULT (cross-consultation)
--     nursing : NURS_ASSESS (nursing assessment, care plan), NURS_CHART (vitals, intake / output, nursing notes, risk scores),
--               NURS_MAR (eMAR, acknowledge orders), NURS_HANDOVER (SBAR handover), NURS_INCIDENT (incident report / close),
--               ORDER_DONE (mark a service / procedure order done: posts its charge)
--     both    : CLIN_CORRECT (strike out a wrong entry with a reason)
--   IPD > Nursing Station (IPD.NURSINGSTATION): VIEW.
-- Needs 2424 (IPD menu, IPD.PATIENT) and 2562-2564. Safe to re-run.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. IPD Patient: Clinical and Nursing tabs ──────────────────────────────────────────────────────────────────────
DECLARE @pp INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT' AND CompanyId = 1), @pv INT, @ctl INT, @a NVARCHAR(60);
IF @pp IS NULL THROW 51500, 'Page IPD.PATIENT is missing (SQLScripts/2424).', 1;
SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'VIEW';
-- reads of the tabs open with the page
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'Data,NursingData,Services,PrintChart', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdClinical', @Action = @a, @Source = 'SEED';
    FETCH NEXT FROM v INTO @a;
END
CLOSE v; DEALLOCATE v;

DECLARE @c TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT, Acts NVARCHAR(300));
INSERT @c VALUES
    ('CLIN_ASSESS',      N'Write and sign the doctor''s initial assessment', 130, N'SaveAssessment'),
    ('CLIN_NOTE',        N'Write rounds / progress notes (signing charges the visit)', 131, N'SaveNote'),
    ('CLIN_ORDER',       N'Write doctor orders (CPOE), stop / cancel them, send medicines to the pharmacy', 132, N'SaveOrder,StopOrder,CancelOrder,LinkIndent'),
    ('CLIN_COUNTERSIGN', N'Countersign a verbal / telephone order', 133, N'Countersign'),
    ('CLIN_CONSULT',     N'Ask for / cancel a cross-consultation', 134, N'CrossConsult'),
    ('NURS_ASSESS',      N'Write the nursing assessment and the care plan', 140, N'SaveNursingAssessment,CarePlan'),
    ('NURS_CHART',       N'Chart vitals (NEWS2), intake / output, nursing notes, fall / pressure-ulcer risk', 141, N'Vital,IntakeOutput,NursingNote,Risk'),
    ('NURS_MAR',         N'Record medicines given / held / refused (eMAR) and acknowledge orders', 142, N'Mar,AckOrder'),
    ('NURS_HANDOVER',    N'Give / take an SBAR shift handover', 143, N'Handover'),
    ('NURS_INCIDENT',    N'Report and close an incident', 144, N'Incident'),
    ('ORDER_DONE',       N'Mark a service / procedure order done (posts its charge)', 145, N'OrderDone'),
    ('CLIN_CORRECT',     N'Strike out a wrong clinical / nursing entry (with a reason)', 146, N'Strike');
DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @ca NVARCHAR(300), @one NVARCHAR(60);
DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort, Acts FROM @c;
OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @pp, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
    DECLARE e CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@ca, ',') WHERE value <> N'';
    OPEN e; FETCH NEXT FROM e INTO @one;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdClinical', @Action = @one, @Source = 'SEED';
        FETCH NEXT FROM e INTO @one;
    END
    CLOSE e; DEALLOCATE e;
    FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
END
CLOSE k; DEALLOCATE k;
GO

-- ── 2. IPD > Nursing Station ───────────────────────────────────────────────────────────────────────────────────────
DECLARE @co INT = 1, @nav INT, @page INT, @view INT, @a NVARCHAR(60);
SELECT @nav = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'IPD' AND CompanyId = 1;
IF @nav IS NULL THROW 51501, 'Menu IPD is missing (SQLScripts/2424).', 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @nav, @Page_Code = N'IPD.NURSINGSTATION', @Title = N'Nursing Station', @Controller = N'IpdClinical', @Action = N'Station',
     @Show_In_Menu = 1, @Sort_Order = 26, @Icon = N'bi bi-clipboard2-pulse me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'Station,StationData', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdClinical', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
CLOSE v; DEALLOCATE v;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2565 IPD Phase 3 clinical pages and controls - done.';
GO
