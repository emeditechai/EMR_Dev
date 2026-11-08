-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2433  ICD-10 master (WHO ICD-10) with SAMPLE codes of common inpatient diagnoses, and the search used by the IPD
--       admission (provisional diagnosis) and, later, the discharge summary. Source = 'SAMPLE' rows are to be replaced
--       by the official WHO ICD-10 tabular list when it is loaded. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('dbo.IcdCode', 'U') IS NULL
    CREATE TABLE dbo.IcdCode
    (
        Code         NVARCHAR(10)  NOT NULL CONSTRAINT PK_IcdCode PRIMARY KEY,
        Title        NVARCHAR(300) NOT NULL,
        Version      VARCHAR(20)   NOT NULL CONSTRAINT DF_IcdCode_Version DEFAULT ('ICD-10 WHO'),
        Source       VARCHAR(10)   NOT NULL CONSTRAINT DF_IcdCode_Source DEFAULT ('SAMPLE'),   -- SAMPLE / WHO
        IsActive     BIT           NOT NULL CONSTRAINT DF_IcdCode_Active DEFAULT (1),
        CreatedDate  DATETIME      NOT NULL CONSTRAINT DF_IcdCode_Created DEFAULT (GETDATE())
    );
GO
DECLARE @s TABLE (Code NVARCHAR(10), Title NVARCHAR(300));
INSERT @s VALUES
 (N'A01.0', N'Typhoid fever'), (N'A09', N'Diarrhoea and gastroenteritis of presumed infectious origin'),
 (N'A15.0', N'Tuberculosis of lung, confirmed by sputum microscopy with or without culture'), (N'A41.9', N'Sepsis, unspecified'),
 (N'A90', N'Dengue fever [classical dengue]'), (N'A91', N'Dengue haemorrhagic fever'),
 (N'B50.9', N'Plasmodium falciparum malaria, unspecified'), (N'B54', N'Unspecified malaria'), (N'B34.9', N'Viral infection, unspecified'),
 (N'C34.9', N'Malignant neoplasm: Bronchus or lung, unspecified'), (N'C50.9', N'Malignant neoplasm: Breast, unspecified'),
 (N'D64.9', N'Anaemia, unspecified'),
 (N'E10.1', N'Insulin-dependent diabetes mellitus with ketoacidosis'), (N'E11.9', N'Non-insulin-dependent diabetes mellitus without complications'),
 (N'E86', N'Volume depletion'), (N'E87.1', N'Hypo-osmolality and hyponatraemia'),
 (N'F10.3', N'Mental and behavioural disorders due to use of alcohol: withdrawal state'), (N'F20.9', N'Schizophrenia, unspecified'),
 (N'F32.9', N'Depressive episode, unspecified'),
 (N'G40.9', N'Epilepsy, unspecified'), (N'G45.9', N'Transient cerebral ischaemic attack, unspecified'),
 (N'H25.9', N'Senile cataract, unspecified'),
 (N'I10', N'Essential (primary) hypertension'), (N'I20.0', N'Unstable angina'), (N'I21.9', N'Acute myocardial infarction, unspecified'),
 (N'I48', N'Atrial fibrillation and flutter'), (N'I50.0', N'Congestive heart failure'), (N'I61.9', N'Intracerebral haemorrhage, unspecified'),
 (N'I63.9', N'Cerebral infarction, unspecified'), (N'I64', N'Stroke, not specified as haemorrhage or infarction'),
 (N'J18.9', N'Pneumonia, unspecified'), (N'J44.1', N'Chronic obstructive pulmonary disease with acute exacerbation, unspecified'),
 (N'J45.9', N'Asthma, unspecified'), (N'J96.0', N'Acute respiratory failure'),
 (N'K37', N'Unspecified appendicitis'), (N'K40.9', N'Unilateral or unspecified inguinal hernia, without obstruction or gangrene'),
 (N'K70.3', N'Alcoholic cirrhosis of liver'), (N'K74.6', N'Other and unspecified cirrhosis of liver'),
 (N'K80.2', N'Calculus of gallbladder without cholecystitis'), (N'K81.0', N'Acute cholecystitis'), (N'K85.9', N'Acute pancreatitis, unspecified'),
 (N'K92.2', N'Gastrointestinal haemorrhage, unspecified'),
 (N'L03.9', N'Cellulitis, unspecified'),
 (N'M17.9', N'Gonarthrosis, unspecified'), (N'M51.2', N'Other specified intervertebral disc displacement'),
 (N'N10', N'Acute tubulo-interstitial nephritis'), (N'N17.9', N'Acute renal failure, unspecified'), (N'N18.5', N'Chronic kidney disease, stage 5'),
 (N'N20.0', N'Calculus of kidney'), (N'N39.0', N'Urinary tract infection, site not specified'),
 (N'O14.1', N'Severe pre-eclampsia'), (N'O21.0', N'Mild hyperemesis gravidarum'), (N'O80.0', N'Spontaneous vertex delivery'),
 (N'O82.0', N'Delivery by elective caesarean section'),
 (N'P07.3', N'Other preterm infants'), (N'P22.0', N'Respiratory distress syndrome of newborn'), (N'P59.9', N'Neonatal jaundice, unspecified'),
 (N'R10.4', N'Other and unspecified abdominal pain'), (N'R50.9', N'Fever, unspecified'), (N'R55', N'Syncope and collapse'),
 (N'R56.8', N'Other and unspecified convulsions'),
 (N'S06.0', N'Concussion'), (N'S52.5', N'Fracture of lower end of radius'), (N'S72.0', N'Fracture of neck of femur'),
 (N'S82.2', N'Fracture of shaft of tibia'), (N'T14.9', N'Injury, unspecified'),
 (N'T30.0', N'Burn of unspecified body region, unspecified degree'), (N'T51.0', N'Toxic effect of ethanol'),
 (N'T60.0', N'Toxic effect of organophosphate and carbamate insecticides'), (N'T63.0', N'Toxic effect of snake venom'),
 (N'U07.1', N'COVID-19, virus identified'),
 (N'Z38.0', N'Singleton, born in hospital'), (N'Z51.1', N'Chemotherapy session for neoplasm');
INSERT dbo.IcdCode (Code, Title) SELECT s.Code, s.Title FROM @s s WHERE NOT EXISTS (SELECT 1 FROM dbo.IcdCode c WHERE c.Code = s.Code);
PRINT CONCAT('2433 sample ICD-10 codes added: ', @@ROWCOUNT);
GO
-- Search by code (prefix) or words of the title; codes first.
CREATE OR ALTER PROCEDURE dbo.usp_Api_Icd_Search @Q NVARCHAR(100), @Top INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    SET @Q = LTRIM(RTRIM(ISNULL(@Q, N'')));
    IF LEN(@Q) < 2 RETURN;
    SELECT TOP (CASE WHEN @Top BETWEEN 1 AND 50 THEN @Top ELSE 20 END) Code, Title, Source
    FROM dbo.IcdCode
    WHERE IsActive = 1 AND (Code LIKE @Q + N'%' OR REPLACE(Code, N'.', N'') LIKE REPLACE(@Q, N'.', N'') + N'%' OR Title LIKE N'%' + @Q + N'%')
    ORDER BY CASE WHEN Code LIKE @Q + N'%' THEN 0 WHEN Title LIKE @Q + N'%' THEN 1 ELSE 2 END, Code;
END;
GO
-- the admission page and the IPD Patient screen search it
SET NOCOUNT ON;
DECLARE @pg NVARCHAR(60), @page INT, @view INT;
DECLARE p CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'IPD.ADMISSION,IPD.PATIENT', ',');
OPEN p; FETCH NEXT FROM p INTO @pg;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = @pg AND CompanyId = 1;
    SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @page IS NOT NULL EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdAdmission', @Action = N'IcdSearch', @Source = 'SEED';
    FETCH NEXT FROM p INTO @pg;
END
CLOSE p; DEALLOCATE p;
GO
PRINT '2433 ICD-10 master - done.';
GO
