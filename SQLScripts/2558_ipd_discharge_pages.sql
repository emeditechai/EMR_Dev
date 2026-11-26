-- 2558: IPD Phase 7 - authorization (pages, controls, endpoints). No grants are seeded: give them in Role Permissions.
--   IPD Patient (IPD.PATIENT) controls: DISCHARGE_ADVISE, CLEAR_PHARMACY, CLEAR_LAB, CLEAR_NURSING, CLEAR_TPA, DISCHARGE_SUMMARY,
--   DISCHARGE_SUMMARY_SIGN, DISCHARGE_SUMMARY_ONBEHALF, DISCHARGE_LAMA, DEATH_RECORD, GATEPASS, GATEPASS_CREDIT, FOLLOWUP. The reads and prints of the
--   Discharge tab are part of VIEW. IpdDischarge/Clear and /SaveSummary check the department / sign right in the controller.
--   IPD > Discharges (IPD.DISCHARGES): VIEW (tracker, register, TAT, death register).
-- Needs 2424 and 2557. Safe to re-run.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @pp INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT' AND CompanyId = 1), @pv INT, @ctl INT, @a NVARCHAR(60);
IF @pp IS NULL THROW 51500, 'Page IPD.PATIENT is missing (SQLScripts/2424).', 1;
SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'VIEW';
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'Data,Prefill,Slots,Medicines,PrintSummary,PrintLama,PrintDeath,PrintGatePass', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdDischarge', @Action = @a, @Source = 'SEED';
    FETCH NEXT FROM v INTO @a;
END
CLOSE v; DEALLOCATE v;
-- department clearances and the summary save share one endpoint each: the controller checks the control
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdDischarge', @Action = N'Clear', @Source = 'SEED';

DECLARE @c TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT, Acts NVARCHAR(300));
INSERT @c VALUES
    ('DISCHARGE_ADVISE',       N'Advise discharge (type, planned time) / change / cancel the advice', 130, N'Advise,CancelAdvice'),
    ('CLEAR_PHARMACY',         N'Discharge clearance: pharmacy (returns, indents)', 131, N''),
    ('CLEAR_LAB',              N'Discharge clearance: LAB / radiology (pending samples and reports)', 132, N''),
    ('CLEAR_NURSING',          N'Discharge clearance: nursing checklist', 133, N''),
    ('CLEAR_TPA',              N'Discharge clearance: TPA / insurance', 134, N''),
    ('DISCHARGE_SUMMARY',      N'Write the discharge / death summary (draft)', 135, N'SaveSummary'),
    ('DISCHARGE_SUMMARY_SIGN', N'Sign the discharge summary as the consultant linked to the login / amend a signed one with a reason', 136, N''),
    ('DISCHARGE_SUMMARY_ONBEHALF', N'Sign the discharge summary on behalf of a consultant (bypass, with a reason)', 136, N''),
    ('DISCHARGE_LAMA',         N'Record / void the LAMA / DAMA form with signatures', 137, N'Lama'),
    ('DEATH_RECORD',           N'Record the death (cause of death, MCCD Form 4 / 4A data, death register)', 138, N'Death'),
    ('GATEPASS',               N'Issue the gate pass (patient leaves, bed released)', 139, N'GatePass'),
    ('GATEPASS_CREDIT',        N'Gate pass with a balance due (credit discharge, with a reason)', 140, N''),
    ('FOLLOWUP',               N'Book / cancel the OPD follow-up from the discharge screen', 141, N'FollowUp');
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
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdDischarge', @Action = @one, @Source = 'SEED';
        FETCH NEXT FROM e INTO @one;
    END
    CLOSE e; DEALLOCATE e;
    FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
END
CLOSE k; DEALLOCATE k;
GO

DECLARE @co INT = 1, @nav INT, @page INT, @view INT, @a NVARCHAR(60);
SELECT @nav = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'IPD' AND CompanyId = 1;
IF @nav IS NULL THROW 51501, 'Menu IPD is missing (SQLScripts/2424).', 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @nav, @Page_Code = N'IPD.DISCHARGES', @Title = N'Discharges', @Controller = N'IpdDischarge', @Action = N'Board',
     @Show_In_Menu = 1, @Sort_Order = 29, @Icon = N'bi bi-door-open me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'Board,BoardData', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdDischarge', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
CLOSE v; DEALLOCATE v;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2558 IPD discharge pages and controls - done.';
GO
