-- ============================================================================================================
-- 2551: Investigation Master - a test's department must be its category's department, and its sub-category must be of its category.
--   Investigation Master > Edit lists only the categories of the selected department, so a test whose category belongs
--   to another department opens with an empty "Test Category" and cannot be saved ("Category is required").
--   Found on Dev: Thyroid Profile, T3, T4, TSH, Vitamin D3, Vitamin B12, Beta hCG (Pathology, category under
--   Biochemistry) and RT-PCR COVID-19 (category moved to Molecular Biology by 2550).
--   Also: a test whose sub-category belongs to another category shows an empty Sub-Category. CK-MB (Clinical Pathology
--   with the Cardiac Markers sub-category) moves to that sub-category's category, Clinical Biochemistry; any other such
--   sub-category is cleared (Dev: Organism, Microbiology with the Routine Urine sub-category).
--   Fix order: CK-MB category, other mismatched sub-categories, then department = category's department.
--   Every company; only active categories.
--   @PreviewOnly = 1 lists the tests that would change and changes nothing. Run after 2550. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- ════════ SETTINGS ════════
DECLARE @OnlyCompanyId INT = NULL;   -- NULL = every company; e.g. 3 = only company 3
DECLARE @PreviewOnly   BIT = 0;      -- 1 = preview only (nothing is changed); 0 = apply
-- ══════════════════════════

CREATE TABLE #Sub (CompanyId INT, Test_ID INT, Test_Code VARCHAR(20), Test_Name NVARCHAR(200), Change NVARCHAR(400));

-- 1. CK-MB filed under Clinical Pathology with the Cardiac Markers sub-category: it belongs to Clinical Biochemistry
INSERT #Sub
SELECT i.CompanyId, i.Test_ID, i.Test_Code, i.Test_Name, N'Category ' + c.Category_Name + N' -> ' + s.Category_Name_Of
FROM dbo.LabInvestigationMaster i
INNER JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = i.Category_ID
CROSS APPLY (SELECT sc.Category_ID AS SubCatCategory, pc.Category_Name AS Category_Name_Of
             FROM dbo.LabTestSubCategoryMaster sc INNER JOIN dbo.LabTestCategoryMaster pc ON pc.Category_ID = sc.Category_ID
             WHERE sc.SubCategory_ID = i.SubCategory_ID AND sc.IsDeleted = 0 AND pc.IsDeleted = 0) s
WHERE i.IsDeleted = 0 AND LTRIM(RTRIM(i.Test_Name)) IN (N'CK-MB', N'CK MB', N'CKMB') AND s.SubCatCategory <> i.Category_ID
  AND (@OnlyCompanyId IS NULL OR i.CompanyId = @OnlyCompanyId);
IF @PreviewOnly = 0
    UPDATE i SET Category_ID = sc.Category_ID, ModifiedDate = GETDATE()
    FROM dbo.LabInvestigationMaster i INNER JOIN #Sub x ON x.Test_ID = i.Test_ID
    INNER JOIN dbo.LabTestSubCategoryMaster sc ON sc.SubCategory_ID = i.SubCategory_ID;

-- 2. any other test whose sub-category belongs to another category: the sub-category is cleared (Edit would show it empty)
INSERT #Sub
SELECT i.CompanyId, i.Test_ID, i.Test_Code, i.Test_Name, N'Sub-category ' + sc.SubCategory_Name + N' cleared (it belongs to another category)'
FROM dbo.LabInvestigationMaster i
INNER JOIN dbo.LabTestSubCategoryMaster sc ON sc.SubCategory_ID = i.SubCategory_ID
WHERE i.IsDeleted = 0 AND (sc.Category_ID <> i.Category_ID OR sc.IsDeleted = 1)
  AND NOT EXISTS (SELECT 1 FROM #Sub x WHERE x.Test_ID = i.Test_ID)
  AND (@OnlyCompanyId IS NULL OR i.CompanyId = @OnlyCompanyId);
IF @PreviewOnly = 0
    UPDATE i SET SubCategory_ID = NULL, ModifiedDate = GETDATE()
    FROM dbo.LabInvestigationMaster i INNER JOIN #Sub x ON x.Test_ID = i.Test_ID AND x.Change LIKE N'Sub-category%';

SELECT CASE WHEN @PreviewOnly = 1 THEN 'Would change' ELSE 'Changed' END AS Action, CompanyId, Test_ID, Test_Code, Test_Name, Change
FROM #Sub ORDER BY CompanyId, Test_ID;
DROP TABLE #Sub;

-- 3. the test's department = its category's department
SELECT i.CompanyId, i.Test_ID, i.Test_Code, i.Test_Name,
       d.DeptName AS FromDepartment, cd.DeptName AS ToDepartment, c.Category_Name AS Category, c.Department_ID AS NewDepartmentId
INTO #Fix
FROM dbo.LabInvestigationMaster i
INNER JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = i.Category_ID AND c.IsDeleted = 0
LEFT  JOIN dbo.DepartmentMaster d  ON d.DeptId  = i.Department_ID
LEFT  JOIN dbo.DepartmentMaster cd ON cd.DeptId = c.Department_ID
WHERE i.IsDeleted = 0 AND ISNULL(i.Department_ID, -1) <> c.Department_ID
  AND (@OnlyCompanyId IS NULL OR i.CompanyId = @OnlyCompanyId);

IF @PreviewOnly = 0
    UPDATE i SET Department_ID = f.NewDepartmentId, ModifiedDate = GETDATE()
    FROM dbo.LabInvestigationMaster i INNER JOIN #Fix f ON f.Test_ID = i.Test_ID;

SELECT CASE WHEN @PreviewOnly = 1 THEN 'Would change' ELSE 'Changed' END AS Action,
       CompanyId, Test_ID, Test_Code, Test_Name, FromDepartment, ToDepartment, Category
FROM #Fix ORDER BY CompanyId, Test_ID;
DROP TABLE #Fix;
GO

PRINT 'Script 2551 applied: Investigation Master - test department follows its category.';
GO
