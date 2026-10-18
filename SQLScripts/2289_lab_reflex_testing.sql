-- ============================================================================================================
-- Migration: 2289_lab_reflex_testing.sql
-- LAB reflex test suggestions (AI features): when an entered result meets a reflex rule (e.g. TSH > 4.5), LAB Reporting
-- suggests the follow-up test (Free / Total T4) to the pathologist, who advises it or dismisses it. An advice is a
-- RECOMMENDATION only: billing, the order and the printed report are not changed; the front desk sees it on B2C
-- booking and the patient profile and adds the test with the patient's consent.
--   dbo.LabReflexRule             the rules (Master > Lab Master > Reflex Rules)
--   dbo.LabReflexRecommendation   one row per advice / dismissal on an order
--   standard rules matched to this database's test names - seeded SWITCHED OFF: pathology reviews each one
--     (thresholds, units) and switches it on; nothing runs until then
--   page MASTER.LABREFLEXRULES under Lab Master; control REFLEX on LAB.LABREPORTING, POST/GET endpoints mapped.
--   No role or user grant is seeded - set them in Settings > Security > Role Permissions.
-- Shown only when Hospital Settings > Enable AI Features at Billing is Yes for the branch. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.LabReflexRule', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabReflexRule
    (
        Rule_ID          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabReflexRule PRIMARY KEY,
        CompanyId        INT            NOT NULL,
        Trigger_Test_ID  INT            NOT NULL,          -- LabInvestigationMaster.Test_ID whose result is checked
        Condition_Type   VARCHAR(10)    NOT NULL,          -- GT GTE LT LTE BETWEEN OUTSIDE FLAG_H FLAG_L FLAG_ABN TEXT
        Value1           DECIMAL(18,4)  NULL,
        Value2           DECIMAL(18,4)  NULL,              -- upper bound for BETWEEN / OUTSIDE
        Text_Value       NVARCHAR(100)  NULL,              -- TEXT: the result contains this (e.g. Positive)
        Gender           VARCHAR(10)    NOT NULL CONSTRAINT DF_LabReflexRule_Gender DEFAULT ('All'),   -- All | Male | Female
        Suggest_Test_ID  INT            NOT NULL,          -- the follow-up test or profile (LabInvestigationMaster.Test_ID)
        Reason           NVARCHAR(250)  NULL,              -- why, shown to the pathologist and the front desk
        Is_Standard      BIT            NOT NULL CONSTRAINT DF_LabReflexRule_Std DEFAULT (0),
        IsActive         BIT            NOT NULL CONSTRAINT DF_LabReflexRule_Active DEFAULT (1),
        CreatedBy        INT            NULL,
        CreatedDate      DATETIME       NOT NULL CONSTRAINT DF_LabReflexRule_Created DEFAULT (GETDATE()),
        ModifiedBy       INT            NULL,
        ModifiedDate     DATETIME       NULL,
        CONSTRAINT CK_LabReflexRule_Condition CHECK (Condition_Type IN ('GT','GTE','LT','LTE','BETWEEN','OUTSIDE','FLAG_H','FLAG_L','FLAG_ABN','TEXT')),
        CONSTRAINT CK_LabReflexRule_Gender CHECK (Gender IN ('All','Male','Female'))
    );
    CREATE INDEX IX_LabReflexRule_Trigger ON dbo.LabReflexRule (CompanyId, Trigger_Test_ID, IsActive);
    PRINT 'Created dbo.LabReflexRule.';
END
GO

IF OBJECT_ID(N'dbo.LabReflexRecommendation', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabReflexRecommendation
    (
        Recommendation_ID  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabReflexRecommendation PRIMARY KEY,
        CompanyId          INT            NOT NULL,
        BranchId           INT            NOT NULL,
        LabOrderId         INT            NOT NULL,
        PatientId          INT            NOT NULL,
        Rule_ID            INT            NOT NULL,
        Trigger_Test_ID    INT            NOT NULL,
        Trigger_Value      NVARCHAR(100)  NULL,            -- the result as it stood when advised
        Suggest_Test_ID    INT            NOT NULL,
        Status             CHAR(1)        NOT NULL,        -- A = advised, D = dismissed
        Note               NVARCHAR(250)  NULL,
        ActionBy           INT            NULL,
        ActionDate         DATETIME       NOT NULL CONSTRAINT DF_LabReflexRec_Date DEFAULT (GETDATE()),
        CONSTRAINT CK_LabReflexRec_Status CHECK (Status IN ('A','D'))
    );
    CREATE UNIQUE INDEX UX_LabReflexRec_Order ON dbo.LabReflexRecommendation (LabOrderId, Rule_ID);
    CREATE INDEX IX_LabReflexRec_Patient ON dbo.LabReflexRecommendation (PatientId, Status) INCLUDE (Suggest_Test_ID, ActionDate);
    PRINT 'Created dbo.LabReflexRecommendation.';
END
GO

-- ── standard rules: matched to this database's tests by name, seeded SWITCHED OFF for pathology review ──
DECLARE @std TABLE (TriggerLike NVARCHAR(100), Cond VARCHAR(10), V1 DECIMAL(18,4), V2 DECIMAL(18,4), Txt NVARCHAR(100), Gender VARCHAR(10),
                    SuggestLike NVARCHAR(100), Reason NVARCHAR(250));
INSERT @std VALUES
 (N'%Thyroid Stimulating Hormone%', 'GT',  4.5,  NULL, NULL, 'All', N'%Free T4%',               N'High TSH: check thyroxine (FT4) to confirm hypothyroidism'),
 (N'%Thyroid Stimulating Hormone%', 'GT',  4.5,  NULL, NULL, 'All', N'%Total Thyroxine%',       N'High TSH: check thyroxine (T4) to confirm hypothyroidism'),
 (N'%Thyroid Stimulating Hormone%', 'LT',  0.4,  NULL, NULL, 'All', N'%Total Triiodothyronine%',N'Low TSH: check T3 for hyperthyroidism'),
 (N'%Fasting Blood Sugar%',          'GTE', 126,  NULL, NULL, 'All', N'%HbA1c%',                 N'Fasting sugar in the diabetic range: HbA1c confirms long-term control'),
 (N'%Fasting Blood Sugar%',          'BETWEEN', 100, 125.99, NULL, 'All', N'%HbA1c%',            N'Impaired fasting glucose: HbA1c to assess prediabetes'),
 (N'%HbA1c%',                        'GTE', 6.5,  NULL, NULL, 'All', N'Serum Creatinine%',       N'Diabetic HbA1c: kidney function screening'),
 (N'Total Cholesterol',              'GT',  200,  NULL, NULL, 'All', N'Lipid Profile%',          N'High total cholesterol: full lipid profile'),
 (N'Hemoglobin (Hb)%',               'LT',  11,   NULL, NULL, 'Female', N'%Vitamin B12%',        N'Low haemoglobin: check B12 for nutritional anaemia'),
 (N'Hemoglobin (Hb)%',               'LT',  12.5, NULL, NULL, 'Male', N'%Vitamin B12%',          N'Low haemoglobin: check B12 for nutritional anaemia'),
 (N'Serum Creatinine%',              'GT',  1.3,  NULL, NULL, 'All', N'Blood Urea',              N'Raised creatinine: blood urea for kidney function'),
 (N'Serum Uric Acid%',               'GT',  7,    NULL, NULL, 'All', N'Serum Creatinine%',       N'Raised uric acid: kidney function'),
 (N'SGPT / ALT%',                    'GT',  80,   NULL, NULL, 'All', N'%HBsAg%',                 N'ALT above twice normal: screen for hepatitis B');

INSERT dbo.LabReflexRule (CompanyId, Trigger_Test_ID, Condition_Type, Value1, Value2, Text_Value, Gender, Suggest_Test_ID, Reason, Is_Standard, IsActive)
SELECT t.CompanyId, t.Test_ID, s.Cond, s.V1, s.V2, s.Txt, s.Gender, g.Test_ID, s.Reason, 1, 0
  FROM @std s
 CROSS APPLY (SELECT TOP 1 Test_ID, CompanyId FROM dbo.LabInvestigationMaster
               WHERE Test_Name LIKE s.TriggerLike AND Status = 1 AND ISNULL(IsDeleted, 0) = 0 ORDER BY Test_ID) t
 CROSS APPLY (SELECT TOP 1 Test_ID FROM dbo.LabInvestigationMaster
               WHERE Test_Name LIKE s.SuggestLike AND CompanyId = t.CompanyId AND Status = 1 AND ISNULL(IsDeleted, 0) = 0 ORDER BY Test_ID) g
 WHERE g.Test_ID <> t.Test_ID
   AND NOT EXISTS (SELECT 1 FROM dbo.LabReflexRule r WHERE r.CompanyId = t.CompanyId AND r.Trigger_Test_ID = t.Test_ID
                      AND r.Suggest_Test_ID = g.Test_ID AND r.Condition_Type = s.Cond AND r.Gender = s.Gender);
PRINT CONCAT('Standard reflex rules seeded (switched off): ', @@ROWCOUNT);
GO

-- ── permissions: the master page, and the REFLEX control on LAB Reporting ──
DECLARE @co INT, @menu INT, @page INT, @ctl INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = N'MASTER.LAB_MASTER';
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = (SELECT TOP 1 Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'MASTER.LAB_MASTER' AND CompanyId = @co);
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'MASTER.LABREFLEXRULES', @Title = N'Reflex Rules',
         @Controller = N'LabReflexRules', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 95, @Icon = N'bi bi-signpost-split me-2',
         @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabReflexRules', @Action = N'Index',  @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabReflexRules', @Action = N'Tests',  @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabReflexRules', @Action = N'Save',   @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabReflexRules', @Action = N'Toggle', @Source = 'SEED';
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABREPORTING';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'REFLEX', @Title = N'Reflex test suggestions (advise / dismiss)', @Sort_Order = 60, @Control_ID = @ctl OUTPUT;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'REFLEX';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabReporting', @Action = N'ReflexSuggestions', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabReporting', @Action = N'ReflexAction',      @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;

-- the front desk reads advised tests on B2C booking (page's VIEW)
DECLARE pb CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABORDERBOOKING.B2CBOOKING';
OPEN pb; FETCH NEXT FROM pb INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabOrderBooking', @Action = N'ReflexAdvised', @Source = 'SEED';
    FETCH NEXT FROM pb INTO @page;
END
CLOSE pb; DEALLOCATE pb;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2289 applied: LAB reflex test suggestions.';
GO
