-- ============================================================================================================
-- 2555: Investigation Master - obstetric / pregnancy imaging needs consent, so its B2C bills print FORM F (2554).
--   Sets Applicable Gender = Female and Consent Required = Yes (and LMP Date Required = Yes, for FORM F item 8) on:
--   USG Obstetric (any), USG NT Scan, USG Transvaginal (TVS), Doppler Obstetric, Fetal Echocardiography.
--   Every company; @OnlyCompanyId limits to one, @PreviewOnly = 1 lists and changes nothing. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- ════════ SETTINGS ════════
DECLARE @OnlyCompanyId INT = NULL;   -- NULL = every company; e.g. 3 = only company 3
DECLARE @PreviewOnly   BIT = 0;      -- 1 = preview only (nothing is changed); 0 = apply
-- ══════════════════════════

SELECT CompanyId, Test_ID, Test_Code, Test_Name, Applicable_Gender, Is_Consent_Required, Is_LMP_Date_Required
INTO #X
FROM dbo.LabInvestigationMaster
WHERE IsDeleted = 0
  AND (Test_Name LIKE N'USG Obstetric%' OR Test_Name LIKE N'USG NT Scan%' OR Test_Name LIKE N'USG Transvaginal%'
       OR Test_Name LIKE N'Doppler Obstetric%' OR Test_Name LIKE N'Fetal Echo%')
  AND (ISNULL(Applicable_Gender, '') <> 'Female' OR ISNULL(Is_Consent_Required, 0) = 0 OR ISNULL(Is_LMP_Date_Required, 0) = 0)
  AND (@OnlyCompanyId IS NULL OR CompanyId = @OnlyCompanyId);

IF @PreviewOnly = 0
    UPDATE i SET Applicable_Gender = 'Female', Is_Consent_Required = 1, Is_LMP_Date_Required = 1, ModifiedDate = GETDATE()
    FROM dbo.LabInvestigationMaster i INNER JOIN #X x ON x.Test_ID = i.Test_ID;

SELECT CASE WHEN @PreviewOnly = 1 THEN 'Would change' ELSE 'Changed' END AS Action, CompanyId, Test_ID, Test_Code, Test_Name,
       Applicable_Gender AS GenderWas, Is_Consent_Required AS ConsentWas, Is_LMP_Date_Required AS LmpWas
FROM #X ORDER BY CompanyId, Test_Name;
DROP TABLE #X;
GO

PRINT 'Script 2555 applied: obstetric imaging - Female, Consent Required, LMP Date Required.';
GO
