-- ============================================================================================================
-- 2549: Investigation Master - new test "Beta hCG (Serum)", MRP 600, unit mIU/mL, LMP date asked at billing.
--   Category, sub-category, sample type, method and TAT are copied from the company's TSH test; the department is the
--   category's department (Investigation Master lists only the categories of the selected department).
--   Unit mIU/mL is added to Unit Master when the company does not have it.
--   Reference ranges (mIU/mL):  Female (not pregnant) 0 - 5 · Male 0 - 2;
--     remarks: below 5 negative, 5 - 25 borderline (repeat after 48 hours), 25 and above suggests pregnancy.
--   One database, many companies: runs once per active company of CompanyMaster (or only @OnlyCompanyId); a company
--   needs a TSH test to copy from and is skipped when it already has a beta hCG test. @PreviewOnly = 1 lists what would
--   happen per company and changes nothing. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- ════════ SETTINGS ════════
DECLARE @OnlyCompanyId INT = NULL;   -- NULL = every active company; e.g. 3 = only company 3
DECLARE @PreviewOnly   BIT = 0;      -- 1 = preview only (nothing is changed); 0 = apply
-- ══════════════════════════
DECLARE @co INT, @tpl INT, @unit INT, @test INT, @code VARCHAR(20), @ucode VARCHAR(20);
CREATE TABLE #Result (CompanyId INT, Company NVARCHAR(200), Result NVARCHAR(400));
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR
    SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1 AND (@OnlyCompanyId IS NULL OR CompanyId = @OnlyCompanyId) ORDER BY CompanyId;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE CompanyId = @co AND IsDeleted = 0
                AND (REPLACE(REPLACE(Test_Name, ' ', ''), '-', '') LIKE '%betahcg%' OR REPLACE(Test_Name, ' ', '') LIKE N'%βhcg%'))
    BEGIN
        PRINT CONCAT('Company ', @co, ': beta hCG already exists - skipped.');
        INSERT #Result SELECT @co, CompanyName, N'Beta hCG already exists - skipped' FROM dbo.CompanyMaster WHERE CompanyId = @co;
        GOTO next_co;
    END

    SET @tpl = (SELECT TOP 1 Test_ID FROM dbo.LabInvestigationMaster
                 WHERE CompanyId = @co AND IsDeleted = 0 AND Is_Profile_Test = 0 AND Test_Name LIKE '%TSH%' AND Test_Name NOT LIKE '%Profile%'
                 ORDER BY Test_ID);
    IF @tpl IS NULL
    BEGIN
        PRINT CONCAT('Company ', @co, ': no TSH test to copy the department / sample from - skipped.');
        INSERT #Result SELECT @co, CompanyName, N'No TSH test to copy the settings from - skipped' FROM dbo.CompanyMaster WHERE CompanyId = @co;
        GOTO next_co;
    END

    IF @PreviewOnly = 1
    BEGIN
        INSERT #Result SELECT @co, CompanyName, N'Will add Beta hCG (Serum), settings copied from Test_ID ' + CAST(@tpl AS NVARCHAR(10))
               + CASE WHEN EXISTS (SELECT 1 FROM dbo.LabUnitMaster WHERE CompanyId = @co AND IsDeleted = 0 AND Unit_Symbol = 'mIU/mL') THEN N'' ELSE N'; unit mIU/mL will be created' END
        FROM dbo.CompanyMaster WHERE CompanyId = @co;
        GOTO next_co;
    END

    -- unit mIU/mL
    SET @unit = (SELECT TOP 1 Unit_ID FROM dbo.LabUnitMaster WHERE CompanyId = @co AND IsDeleted = 0 AND Unit_Symbol = 'mIU/mL' ORDER BY Unit_ID);
    IF @unit IS NULL
    BEGIN
        SET @ucode = 'UNT' + RIGHT('0000' + CAST(ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(Unit_Code, 4, 10) AS INT)) FROM dbo.LabUnitMaster WHERE Unit_Code LIKE 'UNT%'), 0) + 1 AS VARCHAR(10)), 4);
        INSERT dbo.LabUnitMaster (CompanyId, Unit_Name, Unit_Code, Unit_Symbol, Conversion_Factor, Display_Order, Status, CreatedDate, IsDeleted)
        VALUES (@co, N'Milli-international Units per Milliliter', @ucode, N'mIU/mL', 1,
                ISNULL((SELECT MAX(Display_Order) FROM dbo.LabUnitMaster WHERE CompanyId = @co), 0) + 1, 1, GETDATE(), 0);
        SET @unit = SCOPE_IDENTITY();
    END

    -- the test
    SET @code = 'TST' + RIGHT('0000' + CAST(ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(Test_Code, 4, 10) AS INT)) FROM dbo.LabInvestigationMaster WHERE Test_Code LIKE 'TST%'), 0) + 1 AS VARCHAR(10)), 4);
    INSERT dbo.LabInvestigationMaster (CompanyId, Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Sample_Type_ID, Method_ID, Unit_ID,
           Reporting_Type, TAT_Hours, NABL_Accredited, NABL_Scope_No, Is_Outsourced, MRP, Status, CreatedDate, IsDeleted, Is_Profile_Test,
           Applicable_Gender, Is_Billable, Is_Fasting_Required, Sample_Quantity, Sample_Quantity_Unit_ID, Reported_Duration_Value, Reported_Duration_Unit,
           Is_Consent_Required, OVD_Document, Prescription_Required, Reporting_Name, Has_External_Document, Is_LMP_Date_Required)
    SELECT @co, @code, N'Beta hCG (Serum)', ISNULL(c.Department_ID, t.Department_ID), t.Category_ID, t.SubCategory_ID, t.Sample_Type_ID, t.Method_ID, @unit,
           'Numeric', t.TAT_Hours, 0, NULL, 0, 600.00, 1, GETDATE(), 0, 0,
           'All', 1, 0, t.Sample_Quantity, t.Sample_Quantity_Unit_ID, t.Reported_Duration_Value, t.Reported_Duration_Unit,
           0, 0, 0, N'Beta Human Chorionic Gonadotropin (Beta hCG), Serum', 0, 1
    FROM dbo.LabInvestigationMaster t
    LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = t.Category_ID   -- the department of the test's category, so Edit shows the category
    WHERE t.Test_ID = @tpl;
    SET @test = SCOPE_IDENTITY();

    -- reference ranges
    INSERT dbo.LabReferenceRangeMaster (CompanyId, Test_ID, Unit_ID, Age_From, Age_To, Age_Unit, Gender, Pregnancy_Trimester, Low_Value, High_Value,
           Range_Source, Effective_From, Status, IsDeleted, CreatedDate, Special_Remarks, Is_Common_For_All, Notification_Required, Acknowledgement_Required)
    VALUES (@co, @test, @unit, 0, 100, 'Years', 'Female', 'Not Applicable', 0, 5, N'CLIA Method', '2020-01-01', 1, 0, GETDATE(),
            N'Non-pregnant: below 5 mIU/mL (negative). 5 - 25 mIU/mL: borderline, repeat after 48 hours. 25 mIU/mL and above: suggests pregnancy.', 0, 0, 0),
           (@co, @test, @unit, 0, 100, 'Years', 'Male', 'Not Applicable', 0, 2, N'CLIA Method', '2020-01-01', 1, 0, GETDATE(),
            N'Male: below 2 mIU/mL.', 0, 0, 0);

    PRINT CONCAT('Company ', @co, ': added ', @code, ' Beta hCG (Serum), Test_ID ', @test, '.');
    INSERT #Result SELECT @co, CompanyName, N'Added ' + @code + N' Beta hCG (Serum), Test_ID ' + CAST(@test AS NVARCHAR(10)) FROM dbo.CompanyMaster WHERE CompanyId = @co;
next_co:
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

SELECT CompanyId, Company, Result FROM #Result ORDER BY CompanyId;
DROP TABLE #Result;
GO

PRINT 'Script 2549 applied: Investigation Master - Beta hCG (Serum).';
GO
