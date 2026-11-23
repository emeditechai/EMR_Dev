-- 2494: IPD Phase 8 - authorization (pages, controls, endpoints). No grants are seeded: give them in Role Permissions.
--   IPD > OT Schedule (IPD.OTSCHEDULE): VIEW; BOOK (book / change), CANCEL (cancel a booking).
--   IPD > ICU Board (IPD.ICUBOARD): VIEW.
--   IPD Patient (IPD.PATIENT) controls: OT_BOOK, OT_CHECKLIST, OT_PROGRESS, OT_ANAESTHESIA, OT_NOTE, OT_NOTE_SIGN, OT_IMPLANT, OT_CHARGE,
--   ICU_CHART, ICU_CORRECT; reversing OT charges uses the existing CHARGE_CANCEL.
-- Needs 2424 (IPD menu, IPD.PATIENT) and 2492-2493. Safe to re-run.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. IPD Patient: the OT and ICU tabs ─────────────────────────────────────────────────────────────────────────────
DECLARE @pp INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT' AND CompanyId = 1), @pv INT, @ctl INT, @a NVARCHAR(60);
IF @pp IS NULL THROW 51500, 'Page IPD.PATIENT is missing (SQLScripts/2424).', 1;
SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'VIEW';
-- reads of the tabs open with the page
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'IpdOt/Lookups,IpdOt/Data,IpdOt/ChargePreview,IpdOt/PrintRecord,IpdOt/StockItems,IpdOt/Batches,IpdIcu/Data,IpdIcu/PrintChart', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @ctrl NVARCHAR(60) = LEFT(@a, CHARINDEX(N'/', @a) - 1), @act NVARCHAR(60) = SUBSTRING(@a, CHARINDEX(N'/', @a) + 1, 60);
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = @ctrl, @Action = @act, @Source = 'SEED';
    FETCH NEXT FROM v INTO @a;
END
CLOSE v; DEALLOCATE v;

DECLARE @c TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT, Acts NVARCHAR(300));
INSERT @c VALUES
    ('OT_BOOK',        N'Book, change or cancel an OT for the patient', 110, N'IpdOt/Book,IpdOt/Cancel'),
    ('OT_CHECKLIST',   N'Complete the pre-op checklist and the WHO Sign In / Time Out / Sign Out', 111, N'IpdOt/SaveChecklist'),
    ('OT_PROGRESS',    N'Record OT times (in OT, anaesthesia, incision, closure, out) and complete the surgery', 112, N'IpdOt/SaveTimes'),
    ('OT_ANAESTHESIA', N'Write and sign the anaesthesia record', 113, N'IpdOt/SaveAnaesthesia'),
    ('OT_NOTE',        N'Write the surgery note (draft)', 114, N'IpdOt/SaveNote'),
    ('OT_NOTE_SIGN',   N'Sign the surgery note / amend a signed note with a reason', 115, N''),
    ('OT_IMPLANT',     N'Issue implants, surgical items and OT consumables from pharmacy stock / return them', 116, N'IpdOt/AddImplant,IpdOt/RemoveImplant'),
    ('OT_CHARGE',      N'Post the OT charges of a completed surgery', 117, N'IpdOt/PostCharges'),
    ('ICU_CHART',      N'Enter the ICU flowsheet, infusions and device use', 120, N'IpdIcu/AddObservation,IpdIcu/Infusion,IpdIcu/Device'),
    ('ICU_CORRECT',    N'Strike out a wrong ICU flowsheet / infusion / device entry (with a reason)', 121, N'IpdIcu/Strike');
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
        DECLARE @c2 NVARCHAR(60) = LEFT(@one, CHARINDEX(N'/', @one) - 1), @a2 NVARCHAR(60) = SUBSTRING(@one, CHARINDEX(N'/', @one) + 1, 60);
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = @c2, @Action = @a2, @Source = 'SEED';
        FETCH NEXT FROM e INTO @one;
    END
    CLOSE e; DEALLOCATE e;
    FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
END
CLOSE k; DEALLOCATE k;
-- reversing the OT charges of a surgery = cancelling charges
SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'CHARGE_CANCEL';
IF @ctl IS NOT NULL
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdOt', @Action = N'ReverseCharges', @Source = 'SEED';
GO

-- ── 2. IPD > OT Schedule ────────────────────────────────────────────────────────────────────────────────────────────
DECLARE @co INT = 1, @nav INT, @page INT, @view INT, @ctl INT, @a NVARCHAR(60);
SELECT @nav = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'IPD' AND CompanyId = 1;
IF @nav IS NULL THROW 51501, 'Menu IPD is missing (SQLScripts/2424).', 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @nav, @Page_Code = N'IPD.OTSCHEDULE', @Title = N'OT Schedule', @Controller = N'IpdOt', @Action = N'Schedule',
     @Show_In_Menu = 1, @Sort_Order = 27, @Icon = N'bi bi-calendar2-week me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'Schedule,ScheduleData,Lookups,Patients', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdOt', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
CLOSE v; DEALLOCATE v;
SET @ctl = NULL;
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'BOOK', @Title = N'Book or change an OT slot', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdOt', @Action = N'Book', @Source = 'SEED';
SET @ctl = NULL;
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'CANCEL', @Title = N'Cancel an OT booking (with a reason)', @Sort_Order = 30, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdOt', @Action = N'Cancel', @Source = 'SEED';
GO

-- ── 3. IPD > ICU Board ─────────────────────────────────────────────────────────────────────────────────────────────
DECLARE @co INT = 1, @nav INT, @page INT, @view INT, @a NVARCHAR(60);
SELECT @nav = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'IPD' AND CompanyId = 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @nav, @Page_Code = N'IPD.ICUBOARD', @Title = N'ICU Board', @Controller = N'IpdIcu', @Action = N'Board',
     @Show_In_Menu = 1, @Sort_Order = 28, @Icon = N'bi bi-activity me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'Board,BoardData', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdIcu', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
CLOSE v; DEALLOCATE v;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2494 IPD OT / ICU pages and controls - done.';
GO
