-- ============================================================================================================
-- 2552: Investigation Master - Test Method follows the Department.
--   Create / Edit list only the methods of the selected department (and reload them when the department changes,
--   LabInvestigations/GetDependentLookups). Methods were all kept under Pathology, so a Biochemistry / Microbiology /
--   Immunology ... test showed an empty Test Method and lost its method when saved from Edit.
--   Fix: for every test whose method belongs to another department, the same method is made available in the test's
--   department (created there when missing, same name, next MTH code) and the test points to it. The original method
--   stays where it is. Every company; @OnlyCompanyId limits to one, @PreviewOnly = 1 lists and changes nothing.
--   Also maps the new endpoint LabInvestigations/GetDependentLookups to the page's VIEW permission.
-- Run after 2551. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- ════════ SETTINGS ════════
DECLARE @OnlyCompanyId INT = NULL;   -- NULL = every company; e.g. 3 = only company 3
DECLARE @PreviewOnly   BIT = 0;      -- 1 = preview only (nothing is changed); 0 = apply
-- ══════════════════════════

-- tests whose method is of another department
SELECT i.CompanyId, i.Test_ID, i.Department_ID AS TestDeptId, m.Method_ID AS OldMethodId, m.Method_Name
INTO #W
FROM dbo.LabInvestigationMaster i
INNER JOIN dbo.LabTestMethodMaster m ON m.Method_ID = i.Method_ID
WHERE i.IsDeleted = 0 AND i.Department_ID IS NOT NULL AND m.Department_ID <> i.Department_ID
  AND (@OnlyCompanyId IS NULL OR i.CompanyId = @OnlyCompanyId);

-- the methods each department needs and does not have
SELECT DISTINCT w.CompanyId, w.TestDeptId, w.Method_Name
INTO #Need
FROM #W w
WHERE NOT EXISTS (SELECT 1 FROM dbo.LabTestMethodMaster x
                   WHERE x.CompanyId = w.CompanyId AND x.Department_ID = w.TestDeptId AND x.Method_Name = w.Method_Name AND x.IsDeleted = 0);

IF @PreviewOnly = 0
BEGIN
    INSERT dbo.LabTestMethodMaster (CompanyId, Department_ID, Method_Name, Method_Code, Display_Order, Status, CreatedDate, IsDeleted)
    SELECT n.CompanyId, n.TestDeptId, n.Method_Name,
           'MTH' + RIGHT('0000' + CAST(ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(Method_Code, 4, 10) AS INT)) FROM dbo.LabTestMethodMaster WHERE Method_Code LIKE 'MTH%'), 0)
                                  + ROW_NUMBER() OVER (ORDER BY n.CompanyId, n.TestDeptId, n.Method_Name) AS VARCHAR(10)), 4),
           ROW_NUMBER() OVER (PARTITION BY n.CompanyId, n.TestDeptId ORDER BY n.Method_Name), 1, GETDATE(), 0
    FROM #Need n;

    UPDATE i SET Method_ID = x.Method_ID, ModifiedDate = GETDATE()
    FROM dbo.LabInvestigationMaster i
    INNER JOIN #W w ON w.Test_ID = i.Test_ID
    CROSS APPLY (SELECT TOP 1 m.Method_ID FROM dbo.LabTestMethodMaster m
                  WHERE m.CompanyId = w.CompanyId AND m.Department_ID = w.TestDeptId AND m.Method_Name = w.Method_Name AND m.IsDeleted = 0
                  ORDER BY m.Method_ID) x;
END

SELECT CASE WHEN @PreviewOnly = 1 THEN 'Would create' ELSE 'Created' END AS Action, n.CompanyId, d.DeptName AS Department, n.Method_Name AS Method
FROM #Need n LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = n.TestDeptId
ORDER BY n.CompanyId, d.DeptName, n.Method_Name;
SELECT CASE WHEN @PreviewOnly = 1 THEN 'Would re-point' ELSE 'Re-pointed' END AS Action, COUNT(1) AS Tests FROM #W;
DROP TABLE #W; DROP TABLE #Need;
GO

-- ── endpoint: LabInvestigations/GetDependentLookups under the Investigation Master page's VIEW ──
DECLARE @page INT, @view INT;
DECLARE pp CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = 'MASTER.LABINVESTIGATIONS';
OPEN pp; FETCH NEXT FROM pp INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @view = (SELECT TOP 1 Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'LabInvestigations', @Action = N'GetDependentLookups', @Source = 'SEED';
    FETCH NEXT FROM pp INTO @page;
END
CLOSE pp; DEALLOCATE pp;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2552 applied: Investigation Master - Test Method follows the Department.';
GO
