-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2424  IPD Phase 1 · Foundation and Admission (part 3 of 3: navbar IPD > pages, one control per action)
--
--   IPD Dashboard (IPD.INDEX, existing page re-titled) · New Admission · Admission List · IPD Patient (workspace,
--   opened from the lists, not in the menu) · Current Billing Estimation · Pre-admission Estimate
--
-- Sensitive controls (CANCEL, REFUND, CHANGE_TARIFF, BACKDATE, WAIVE_ADVANCE, DOCUMENT_DELETE) must be ticked per role
-- before module IPD is added to Authorization:EnforceModules. No grants are seeded. Needs 2422, 2423. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET NOCOUNT ON;
DECLARE @co INT = 1, @nav INT, @page INT, @view INT, @ctl INT, @i INT = 1;
EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = NULL, @Menu_Type = 'NAV', @Menu_Code = N'IPD',
     @Title = N'IPD', @Icon = N'bi bi-hospital me-2', @Sort_Order = 40, @UserId = NULL, @Menu_ID = @nav OUTPUT;

DECLARE @pages TABLE (n INT IDENTITY, Code NVARCHAR(60), Title NVARCHAR(100), Ctl NVARCHAR(60), Act NVARCHAR(60), InMenu BIT, Sort INT, Icon NVARCHAR(60), ViewActs NVARCHAR(600));
INSERT @pages (Code, Title, Ctl, Act, InMenu, Sort, Icon, ViewActs) VALUES
 (N'IPD.INDEX',         N'IPD Dashboard',              N'IPD',            N'Index',        1, 10, N'bi bi-speedometer2 me-2',     N'Index,DashboardData'),
 (N'IPD.ADMISSION',     N'New Admission',              N'IpdAdmission',   N'New',          1, 20, N'bi bi-person-plus-fill me-2', N'New,Lookups,Beds,SearchPatientByPhone,SearchPatientByCode,SearchPatientByName,GetPatientDetails,GetStatesByCountry,GetDistrictsByState,GetCitiesByDistrict,GetAreasByCity,PatientStatus,PatientEstimates,ConsentPreview'),
 (N'IPD.ADMISSIONLIST', N'Admission List',             N'IpdAdmission',   N'Index',        1, 30, N'bi bi-card-list me-2',        N'Index,ListData'),
 (N'IPD.PATIENT',       N'IPD Patient',                N'IpdAdmission',   N'Patient',      0, 35, N'bi bi-person-badge me-2',     N'Patient,PatientData,PatientLookups,PrintFaceSheet,PrintWristband,PrintConsent,PrintReceipt,PatientConsentPreview'),
 (N'IPD.ESTIMATION',    N'Current Billing Estimation', N'IpdEstimation',  N'Index',        1, 40, N'bi bi-calculator me-2',       N'Index,DueListData,Patient,LiveData,LinesData,Print'),
 (N'IPD.PREESTIMATE',   N'Pre-admission Estimate',     N'IpdEstimation',  N'PreAdmission', 1, 50, N'bi bi-file-earmark-medical me-2', N'PreAdmission,PreAdmissionData,PreAdmissionForm,PreAdmissionLookups,PreAdmissionCalc,PrintPreAdmission');

DECLARE @controls TABLE (Code NVARCHAR(60), Control VARCHAR(30), Title NVARCHAR(150), Sort INT, Acts NVARCHAR(200));
INSERT @controls VALUES
 (N'IPD.ADMISSION', 'SAVE',            N'Admit a patient (bed, payer, consent, advance)', 20, N'Save'),
 (N'IPD.ADMISSION', 'BACKDATE',        N'Enter an earlier admission time (more than 30 minutes back)', 30, N''),
 (N'IPD.ADMISSION', 'WAIVE_ADVANCE',   N'Admit a cash patient without the minimum advance', 40, N''),
 (N'IPD.PATIENT',   'EDIT',            N'Edit admission details, payer, attendants, MLC', 20, N'Update'),
 (N'IPD.PATIENT',   'CHANGE_TARIFF',   N'Change the payer / tariff category of an admission', 25, N''),
 (N'IPD.PATIENT',   'ADVANCE',         N'Collect an advance / deposit', 30, N'AddAdvance'),
 (N'IPD.PATIENT',   'REFUND',          N'Refund advance', 40, N'RefundAdvance'),
 (N'IPD.PATIENT',   'CONSENT',         N'Record a signed consent', 50, N'SaveConsent'),
 (N'IPD.PATIENT',   'DOCUMENT',        N'Upload a document', 60, N'UploadDocument'),
 (N'IPD.PATIENT',   'DOCUMENT_DELETE', N'Remove a document', 70, N'RemoveDocument'),
 (N'IPD.PATIENT',   'CANCEL',          N'Cancel an admission made by mistake', 80, N'Cancel'),
 (N'IPD.PREESTIMATE', 'SAVE',          N'Create / edit a pre-admission estimate', 20, N'SavePreAdmission'),
 (N'IPD.PREESTIMATE', 'CANCEL',        N'Cancel a pre-admission estimate', 30, N'CancelPreAdmission');

DECLARE @code NVARCHAR(60), @title NVARCHAR(100), @c NVARCHAR(60), @a NVARCHAR(60), @inMenu BIT, @sort INT, @icon NVARCHAR(60), @va NVARCHAR(600),
        @act NVARCHAR(60), @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @ca NVARCHAR(200);
WHILE @i <= (SELECT COUNT(*) FROM @pages)
BEGIN
    SELECT @code = Code, @title = Title, @c = Ctl, @a = Act, @inMenu = InMenu, @sort = Sort, @icon = Icon, @va = ViewActs FROM @pages WHERE n = @i;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @nav, @Page_Code = @code, @Title = @title, @Controller = @c, @Action = @a,
         @Show_In_Menu = @inMenu, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
    DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@va, ',') WHERE value <> '';
    OPEN v; FETCH NEXT FROM v INTO @act;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = @c, @Action = @act, @Source = 'SEED';
        FETCH NEXT FROM v INTO @act;
    END
    CLOSE v; DEALLOCATE v;
    DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Control, Title, Sort, Acts FROM @controls WHERE Code = @code;
    OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
        DECLARE e CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@ca, ',') WHERE value <> '';
        OPEN e; FETCH NEXT FROM e INTO @act;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = @c, @Action = @act, @Source = 'SEED';
            FETCH NEXT FROM e INTO @act;
        END
        CLOSE e; DEALLOCATE e;
        FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
    END
    CLOSE k; DEALLOCATE k;
    SET @i += 1;
END
GO

-- the pre-admission estimate finds the patient with the admission page's Patient Master searches: those endpoints
-- belong to both pages (allowed when either page is allowed)
DECLARE @sp INT, @sv INT, @sc NVARCHAR(60), @sa NVARCHAR(400), @x NVARCHAR(60);
DECLARE @shared2 TABLE (Code NVARCHAR(60), Ctl NVARCHAR(60), Acts NVARCHAR(400));
INSERT @shared2 VALUES (N'IPD.PREESTIMATE', N'IpdAdmission', N'SearchPatientByPhone,SearchPatientByCode,SearchPatientByName');
SELECT @sp = p.Page_ID, @sc = s.Ctl, @sa = s.Acts FROM @shared2 s JOIN dbo.PageMaster p ON p.Page_Code = s.Code AND p.CompanyId = 1;
SELECT @sv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @sp AND Control_Code = 'VIEW';
DECLARE z CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@sa, ',');
OPEN z; FETCH NEXT FROM z INTO @x;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @sp, @Control_ID = @sv, @App = 'WEB', @Http_Method = 'GET', @Controller = @sc, @Action = @x, @Source = 'SEED'; FETCH NEXT FROM z INTO @x; END
CLOSE z; DEALLOCATE z;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2424 IPD pages - done.';
GO
