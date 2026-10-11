-- ============================================================================
-- Migration: 2248_qc_bom_reports.sql
-- Description: Quality & Compliance - BOM & Costing reports under Reports > LAB (Reports Catalogue, group A).
--   Every report uses the register shape of SQLScripts/2124 (summary / groups / rows / options / lines) and is run by
--   EMR.Api ReportsController "lab/run/{report}":
--     bom-register          usp_Api_LabReport_BomRegister          #1  Test BOM Register (lines open under each BOM)
--     bom-coverage          usp_Api_LabReport_BomCoverage          #2  BOM Coverage / tests without BOM
--     item-where-used       usp_Api_LabReport_ItemWhereUsed        #3  Item Where-Used (BOMs and sample kits; unused items)
--     bom-history           usp_Api_LabReport_BomHistory           #4  BOM Version / Change History (by date, line differences)
--     test-cost-sheet       usp_Api_LabReport_TestCostSheet        #5  Test Cost Sheet (reagent, QC share, reruns, dead volume, kit)
--     price-vs-cost         usp_Api_LabReport_PriceVsCost          #6  Price vs Cost (margin of tests, profiles and packages)
--     margin-alert          usp_Api_LabReport_MarginAlert          #7  Loss / Low-Margin Alert (with the rate needed)
--     package-profitability usp_Api_LabReport_PackageProfitability #8  Package & Profile Profitability
--     sample-kit-cost       usp_Api_LabReport_SampleKitCost        #9  Sample Kit Cost Register
--     analyzer-cost         usp_Api_LabReport_AnalyzerCost         #10 Analyzer-wise Cost Comparison
--     price-impact          usp_Api_LabReport_PriceImpact          #11 Price-Change Impact (what-if)
--     dept-cost-summary     usp_Api_LabReport_DeptCostSummary      #12 Department Cost Summary
--   Costs are the BOM master's (current item unit cost; SQLScripts/2247), rates the branch's current B2C rate card.
--   All are snapshots "as on today" except #4 (changes in the selected period). Master data is company-wide, so the
--   reports are the same for every user of the branch (no "own data only" rule).
--   Pages REPORTS.LAB* under Reports > LAB (VIEW = the page and its data). No role is granted here: give them from
--   Settings > Security (Super Admin sees them without a grant).
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- material cost of one BOM version (same formula as ufn_Qc_TestMaterialCost)
CREATE OR ALTER FUNCTION dbo.ufn_Qc_BomCost (@BomId INT)
RETURNS DECIMAL(14,2)
AS
BEGIN
    IF @BomId IS NULL RETURN NULL;
    RETURN (SELECT CAST(ROUND(SUM(l.Qty * dbo.ufn_Qc_ItemUnitCost(l.ItemId)) * (1 + (b.RerunPct + b.DeadVolumePct) / 100.0), 2) AS DECIMAL(14,2))
            FROM dbo.BomTest b INNER JOIN dbo.BomTestLine l ON l.BomId = b.BomId WHERE b.BomId = @BomId GROUP BY b.RerunPct, b.DeadVolumePct);
END;
GO

-- the company of a branch (masters are company-wide)
CREATE OR ALTER FUNCTION dbo.ufn_Qc_BranchCompany (@BranchId INT)
RETURNS INT
AS
BEGIN
    RETURN COALESCE((SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId),
                    (SELECT TOP 1 CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1 ORDER BY CompanyId));
END;
GO

-- every bookable test / profile test with its default BOM, costs and the branch's B2C rate
CREATE OR ALTER FUNCTION dbo.ufn_Qc_TestCostList (@CompanyId INT, @BranchId INT)
RETURNS TABLE
AS RETURN
(
    SELECT m.Test_ID AS TestId, m.Test_Code AS TestCode, m.Test_Name AS TestName,
           CAST(CASE WHEN ISNULL(m.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END AS VARCHAR(10)) AS Kind,
           ISNULL(m.Department_ID, 0) AS DepartmentId, ISNULL(d.DeptName, N'No department') AS DepartmentName,
           m.Sample_Type_ID AS SampleTypeId, st.Sample_Name AS SampleType,
           CAST(ISNULL(m.Is_Outsourced, 0) AS BIT) AS IsOutsourced,
           b.BomId, b.VersionNo, b.EffectiveFrom, b.RerunPct, b.DeadVolumePct,
           (SELECT COUNT(1) FROM dbo.BomTest x WHERE x.TestId = m.Test_ID AND x.IsActive = 1 AND x.AnalyzerId IS NOT NULL) AS AnalyzerBoms,
           (SELECT COUNT(1) FROM dbo.BomTestLine l WHERE l.BomId = b.BomId) AS LineCount,
           dbo.ufn_Qc_BomCost(b.BomId) AS MaterialCost,
           dbo.ufn_Qc_SampleKitCost(m.Sample_Type_ID) AS KitCost,
           r.B2CRate AS Rate
    FROM dbo.LabInvestigationMaster m
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = m.Department_ID
    LEFT JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = m.Sample_Type_ID
    OUTER APPLY (SELECT TOP 1 x.BomId, x.VersionNo, x.EffectiveFrom, x.RerunPct, x.DeadVolumePct FROM dbo.BomTest x
                 WHERE x.TestId = m.Test_ID AND x.IsActive = 1 AND x.AnalyzerId IS NULL AND x.CompanyId = @CompanyId) b
    OUTER APPLY (SELECT TOP 1 x.B2CRate FROM dbo.fn_LabBookableItems(@BranchId, 'B2C', NULL) x
                 WHERE x.Item_ID = m.Test_ID AND x.Item_Type = CASE WHEN ISNULL(m.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END) r
    WHERE ISNULL(m.IsDeleted, 0) = 0 AND m.Status = 1 AND (ISNULL(m.Is_Billable, 1) = 1 OR ISNULL(m.Is_Profile_Test, 0) = 1)
      AND (m.CompanyId = @CompanyId OR m.CompanyId IS NULL)
);
GO

-- ═════ #1 Test BOM Register ═══════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_BomRegister
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @AppliesTo VARCHAR(20) = NULL,        -- DEFAULT | ANALYZER
    @DepartmentId INT = NULL, @CategoryId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @AppliesTo = NULLIF(UPPER(LTRIM(RTRIM(@AppliesTo))), '');

    SELECT b.BomId, b.TestId, m.Test_Code AS TestCode, m.Test_Name AS TestName,
           CASE WHEN ISNULL(m.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END AS Kind,
           ISNULL(m.Department_ID, 0) AS DepartmentId, ISNULL(d.DeptName, N'No department') AS DepartmentName,
           st.Sample_Name AS SampleType,
           ISNULL(b.AnalyzerId, 0) AS AppliesToId, ISNULL(a.Analyzer_Name, N'Default (all analyzers)') AS AppliesTo,
           b.VersionNo, b.EffectiveFrom, b.RerunPct, b.DeadVolumePct, b.Remarks,
           (SELECT COUNT(1) FROM dbo.BomTestLine l WHERE l.BomId = b.BomId) AS LineCount,
           CAST((SELECT SUM(l.Qty * dbo.ufn_Qc_ItemUnitCost(l.ItemId)) FROM dbo.BomTestLine l WHERE l.BomId = b.BomId) AS DECIMAL(14,2)) AS ItemsCost,
           dbo.ufn_Qc_BomCost(b.BomId) AS MaterialCost,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS CreatedByName
    INTO #B
    FROM dbo.BomTest b
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = b.TestId
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = m.Department_ID
    LEFT JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = m.Sample_Type_ID
    LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = b.AnalyzerId
    LEFT JOIN dbo.Users u ON u.Id = b.CreatedBy
    WHERE b.IsActive = 1 AND b.CompanyId = @CompanyId
      AND (@AppliesTo IS NULL OR (@AppliesTo = 'DEFAULT' AND b.AnalyzerId IS NULL) OR (@AppliesTo = 'ANALYZER' AND b.AnalyzerId IS NOT NULL))
      AND (@DepartmentId IS NULL OR m.Department_ID = @DepartmentId)
      AND (@CategoryId IS NULL OR EXISTS (SELECT 1 FROM dbo.BomTestLine l INNER JOIN dbo.InvItem i ON i.ItemId = l.ItemId WHERE l.BomId = b.BomId AND i.CategoryId = @CategoryId))
      AND (@Search IS NULL OR m.Test_Name LIKE '%' + @Search + '%' OR m.Test_Code LIKE '%' + @Search + '%'
           OR EXISTS (SELECT 1 FROM dbo.BomTestLine l INNER JOIN dbo.InvItem i ON i.ItemId = l.ItemId
                      WHERE l.BomId = b.BomId AND (i.ItemName LIKE '%' + @Search + '%' OR i.ItemCode LIKE '%' + @Search + '%')));

    SELECT COUNT(1) AS BomCount, COUNT(DISTINCT TestId) AS TestCount, ISNULL(SUM(LineCount), 0) AS LineCount,
           (SELECT COUNT(DISTINCT l.ItemId) FROM dbo.BomTestLine l WHERE l.BomId IN (SELECT BomId FROM #B)) AS ItemCount,
           CAST(AVG(MaterialCost) AS DECIMAL(14,2)) AS AvgMaterialCost,
           SUM(CASE WHEN AppliesToId > 0 THEN 1 ELSE 0 END) AS AnalyzerBoms
    FROM #B;

    SELECT 'byDept' AS GroupKey, DepartmentId AS GroupId, DepartmentName AS GroupName, COUNT(1) AS Boms, SUM(LineCount) AS Lines,
           CAST(AVG(MaterialCost) AS DECIMAL(14,2)) AS AvgCost
    FROM #B GROUP BY DepartmentId, DepartmentName
    UNION ALL
    SELECT 'byAppliesTo', AppliesToId, AppliesTo, COUNT(1), SUM(LineCount), CAST(AVG(MaterialCost) AS DECIMAL(14,2))
    FROM #B GROUP BY AppliesToId, AppliesTo
    ORDER BY GroupKey, GroupName;

    SELECT * FROM #B ORDER BY DepartmentName, TestName, AppliesToId;

    SELECT 'departmentId' AS FilterKey, CAST(DeptId AS VARCHAR(20)) AS Value, DeptName AS Text FROM dbo.DepartmentMaster
    WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%')
    UNION ALL
    SELECT 'categoryId', CAST(CategoryId AS VARCHAR(20)), CategoryName FROM dbo.InvItemCategory WHERE IsActive = 1
    ORDER BY FilterKey, Text;

    SELECT l.BomId, i.ItemCode, i.ItemName, c.CategoryName, c.IsQcMaterial, l.Qty, cu.UnitName AS Unit,
           dbo.ufn_Qc_ItemUnitCost(l.ItemId) AS UnitCost,
           CAST(ROUND(l.Qty * dbo.ufn_Qc_ItemUnitCost(l.ItemId), 4) AS DECIMAL(14,4)) AS LineCost, l.Remarks
    FROM dbo.BomTestLine l
    INNER JOIN dbo.InvItem i ON i.ItemId = l.ItemId
    INNER JOIN dbo.InvItemCategory c ON c.CategoryId = i.CategoryId
    INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    WHERE l.BomId IN (SELECT BomId FROM #B)
    ORDER BY l.BomId, l.BomLineId;
END;
GO

-- ═════ #2 BOM Coverage ═══════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_BomCoverage
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @Coverage VARCHAR(20) = NULL,         -- COSTED | NOBOM | ANALYZER | OUTSOURCED
    @DepartmentId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @Coverage = NULLIF(UPPER(LTRIM(RTRIM(@Coverage))), '');

    SELECT t.*,
           CASE WHEN t.BomId IS NOT NULL THEN 'COSTED' WHEN t.AnalyzerBoms > 0 THEN 'ANALYZER' WHEN t.IsOutsourced = 1 THEN 'OUTSOURCED' ELSE 'NOBOM' END AS Coverage,
           CASE WHEN t.BomId IS NOT NULL THEN 'Costed (default BOM)' WHEN t.AnalyzerBoms > 0 THEN 'Analyzer BOM only'
                WHEN t.IsOutsourced = 1 THEN 'Outsourced (no BOM needed)' ELSE 'No BOM' END AS CoverageLabel,
           (SELECT MAX(x.CreatedDate) FROM dbo.BomTest x WHERE x.TestId = t.TestId) AS LastChanged
    INTO #T
    FROM dbo.ufn_Qc_TestCostList(@CompanyId, @BranchId) t
    WHERE (@DepartmentId IS NULL OR t.DepartmentId = @DepartmentId)
      AND (@Search IS NULL OR t.TestName LIKE '%' + @Search + '%' OR t.TestCode LIKE '%' + @Search + '%');

    SELECT COUNT(1) AS Tests, SUM(CASE WHEN Coverage = 'COSTED' THEN 1 ELSE 0 END) AS Costed,
           SUM(CASE WHEN Coverage = 'NOBOM' THEN 1 ELSE 0 END) AS NoBom,
           SUM(CASE WHEN Coverage = 'ANALYZER' THEN 1 ELSE 0 END) AS AnalyzerOnly,
           SUM(CASE WHEN Coverage = 'OUTSOURCED' THEN 1 ELSE 0 END) AS Outsourced,
           CAST(SUM(CASE WHEN Coverage IN ('COSTED', 'ANALYZER') THEN 1 ELSE 0 END) * 100.0
                / NULLIF(SUM(CASE WHEN Coverage <> 'OUTSOURCED' THEN 1 ELSE 0 END), 0) AS DECIMAL(5,1)) AS CoveragePct,
           CAST(SUM(CASE WHEN Coverage = 'NOBOM' THEN ISNULL(Rate, 0) ELSE 0 END) AS DECIMAL(14,2)) AS UncostedRateValue
    FROM #T;

    SELECT 'byDept' AS GroupKey, DepartmentId AS GroupId, DepartmentName AS GroupName, 1 AS SortOrder, COUNT(1) AS Tests,
           SUM(CASE WHEN Coverage IN ('COSTED', 'ANALYZER') THEN 1 ELSE 0 END) AS Costed,
           SUM(CASE WHEN Coverage = 'NOBOM' THEN 1 ELSE 0 END) AS NoBom,
           SUM(CASE WHEN Coverage = 'OUTSOURCED' THEN 1 ELSE 0 END) AS Outsourced,
           CAST(SUM(CASE WHEN Coverage IN ('COSTED', 'ANALYZER') THEN 1 ELSE 0 END) * 100.0
                / NULLIF(SUM(CASE WHEN Coverage <> 'OUTSOURCED' THEN 1 ELSE 0 END), 0) AS DECIMAL(5,1)) AS CoveragePct
    FROM #T GROUP BY DepartmentId, DepartmentName
    UNION ALL
    SELECT 'byCoverage', NULL, CoverageLabel, MIN(CASE Coverage WHEN 'NOBOM' THEN 1 WHEN 'ANALYZER' THEN 2 WHEN 'OUTSOURCED' THEN 3 ELSE 4 END), COUNT(1),
           SUM(CASE WHEN Coverage IN ('COSTED', 'ANALYZER') THEN 1 ELSE 0 END), SUM(CASE WHEN Coverage = 'NOBOM' THEN 1 ELSE 0 END),
           SUM(CASE WHEN Coverage = 'OUTSOURCED' THEN 1 ELSE 0 END), NULL
    FROM #T GROUP BY CoverageLabel
    UNION ALL
    SELECT 'byKind', NULL, Kind, 1, COUNT(1), SUM(CASE WHEN Coverage IN ('COSTED', 'ANALYZER') THEN 1 ELSE 0 END),
           SUM(CASE WHEN Coverage = 'NOBOM' THEN 1 ELSE 0 END), SUM(CASE WHEN Coverage = 'OUTSOURCED' THEN 1 ELSE 0 END),
           CAST(SUM(CASE WHEN Coverage IN ('COSTED', 'ANALYZER') THEN 1 ELSE 0 END) * 100.0
                / NULLIF(SUM(CASE WHEN Coverage <> 'OUTSOURCED' THEN 1 ELSE 0 END), 0) AS DECIMAL(5,1))
    FROM #T GROUP BY Kind
    ORDER BY GroupKey, SortOrder, GroupName;

    SELECT * FROM #T WHERE (@Coverage IS NULL OR Coverage = @Coverage)
    ORDER BY CASE Coverage WHEN 'NOBOM' THEN 1 WHEN 'ANALYZER' THEN 2 WHEN 'OUTSOURCED' THEN 3 ELSE 4 END, DepartmentName, TestName;

    SELECT 'departmentId' AS FilterKey, CAST(DeptId AS VARCHAR(20)) AS Value, DeptName AS Text FROM dbo.DepartmentMaster
    WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%') ORDER BY Text;
END;
GO

-- ═════ #3 Item Where-Used ════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_ItemWhereUsed
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @Usage VARCHAR(20) = NULL,            -- BOM | KIT | UNUSED
    @CategoryId INT = NULL, @ItemId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @Usage = NULLIF(UPPER(LTRIM(RTRIM(@Usage))), '');

    SELECT i.ItemId, i.ItemCode, i.ItemName, i.CategoryId, c.CategoryName, cu.UnitName AS Unit, dbo.ufn_Qc_ItemUnitCost(i.ItemId) AS UnitCost
    INTO #I
    FROM dbo.InvItem i
    INNER JOIN dbo.InvItemCategory c ON c.CategoryId = i.CategoryId
    INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    WHERE i.CompanyId = @CompanyId AND i.IsDeleted = 0 AND i.Status = 1
      AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId) AND (@ItemId IS NULL OR i.ItemId = @ItemId);

    -- one row per use: a BOM line of a current BOM, a sample-kit line; an active item used nowhere is listed once
    SELECT x.* INTO #R FROM (
        SELECT i.ItemId, i.ItemCode, i.ItemName, i.CategoryId, i.CategoryName, i.Unit, i.UnitCost,
               'BOM' AS Usage, 'Test BOM' AS UsageLabel, m.Test_Name AS UsedIn, m.Test_Code AS UsedInCode,
               ISNULL(a.Analyzer_Name, N'Default') AS AppliesTo, ISNULL(d.DeptName, N'No department') AS DepartmentName,
               l.Qty, CAST(ROUND(l.Qty * i.UnitCost, 4) AS DECIMAL(14,4)) AS LineCost,
               CAST(ROUND(l.Qty * i.UnitCost * 100.0 / NULLIF((SELECT SUM(l2.Qty * dbo.ufn_Qc_ItemUnitCost(l2.ItemId)) FROM dbo.BomTestLine l2 WHERE l2.BomId = b.BomId), 0), 1) AS DECIMAL(6,1)) AS SharePct
        FROM #I i
        INNER JOIN dbo.BomTestLine l ON l.ItemId = i.ItemId
        INNER JOIN dbo.BomTest b ON b.BomId = l.BomId AND b.IsActive = 1
        INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = b.TestId
        LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = m.Department_ID
        LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = b.AnalyzerId
        UNION ALL
        SELECT i.ItemId, i.ItemCode, i.ItemName, i.CategoryId, i.CategoryName, i.Unit, i.UnitCost,
               'KIT', 'Sample kit', st.Sample_Name, NULL, NULL, N'Sample collection', k.Qty, CAST(ROUND(k.Qty * i.UnitCost, 4) AS DECIMAL(14,4)),
               CAST(ROUND(k.Qty * i.UnitCost * 100.0 / NULLIF(dbo.ufn_Qc_SampleKitCost(k.SampleTypeId), 0), 1) AS DECIMAL(6,1))
        FROM #I i
        INNER JOIN dbo.BomSampleKit k ON k.ItemId = i.ItemId AND k.IsActive = 1 AND k.CompanyId = @CompanyId
        INNER JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = k.SampleTypeId
        UNION ALL
        SELECT i.ItemId, i.ItemCode, i.ItemName, i.CategoryId, i.CategoryName, i.Unit, i.UnitCost,
               'UNUSED', 'Not used', NULL, NULL, NULL, NULL, NULL, NULL, NULL
        FROM #I i
        WHERE NOT EXISTS (SELECT 1 FROM dbo.BomTestLine l INNER JOIN dbo.BomTest b ON b.BomId = l.BomId AND b.IsActive = 1 WHERE l.ItemId = i.ItemId)
          AND NOT EXISTS (SELECT 1 FROM dbo.BomSampleKit k WHERE k.ItemId = i.ItemId AND k.IsActive = 1)
    ) x
    WHERE (@Usage IS NULL OR x.Usage = @Usage)
      AND (@Search IS NULL OR x.ItemName LIKE '%' + @Search + '%' OR x.ItemCode LIKE '%' + @Search + '%' OR x.UsedIn LIKE '%' + @Search + '%');

    SELECT (SELECT COUNT(1) FROM #I) AS ActiveItems,
           COUNT(DISTINCT CASE WHEN Usage <> 'UNUSED' THEN ItemId END) AS ItemsUsed,
           COUNT(DISTINCT CASE WHEN Usage = 'UNUSED' THEN ItemId END) AS ItemsUnused,
           SUM(CASE WHEN Usage = 'BOM' THEN 1 ELSE 0 END) AS BomUses, SUM(CASE WHEN Usage = 'KIT' THEN 1 ELSE 0 END) AS KitUses,
           (SELECT TOP 1 ItemName FROM #R WHERE Usage <> 'UNUSED' GROUP BY ItemName ORDER BY COUNT(1) DESC, ItemName) AS TopItem,
           (SELECT TOP 1 COUNT(1) FROM #R WHERE Usage <> 'UNUSED' GROUP BY ItemName ORDER BY COUNT(1) DESC, ItemName) AS TopItemUses
    FROM #R;

    SELECT 'byItem' AS GroupKey, ItemId AS GroupId, ItemName AS GroupName,
           SUM(CASE WHEN Usage = 'BOM' THEN 1 ELSE 0 END) AS TestUses, SUM(CASE WHEN Usage = 'KIT' THEN 1 ELSE 0 END) AS KitUses,
           CAST(AVG(LineCost) AS DECIMAL(14,2)) AS AvgCostPerUse
    FROM #R GROUP BY ItemId, ItemName
    UNION ALL
    SELECT 'byCategory', CategoryId, CategoryName, SUM(CASE WHEN Usage = 'BOM' THEN 1 ELSE 0 END), SUM(CASE WHEN Usage = 'KIT' THEN 1 ELSE 0 END),
           CAST(AVG(LineCost) AS DECIMAL(14,2))
    FROM #R GROUP BY CategoryId, CategoryName
    UNION ALL
    SELECT 'byUsage', NULL, UsageLabel, SUM(CASE WHEN Usage = 'BOM' THEN 1 ELSE 0 END), SUM(CASE WHEN Usage = 'KIT' THEN 1 ELSE 0 END),
           CAST(AVG(LineCost) AS DECIMAL(14,2))
    FROM #R GROUP BY UsageLabel
    ORDER BY GroupKey, GroupName;

    SELECT * FROM #R ORDER BY ItemName, CASE Usage WHEN 'BOM' THEN 1 WHEN 'KIT' THEN 2 ELSE 3 END, UsedIn;

    SELECT 'categoryId' AS FilterKey, CAST(CategoryId AS VARCHAR(20)) AS Value, CategoryName AS Text FROM dbo.InvItemCategory WHERE IsActive = 1
    UNION ALL
    SELECT 'itemId', CAST(ItemId AS VARCHAR(20)), ItemName FROM dbo.InvItem WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND Status = 1
    ORDER BY FilterKey, Text;
END;
GO

-- ═════ #4 BOM Version / Change History ══════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_BomHistory
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @EventType VARCHAR(20) = NULL,        -- CREATED | REVISED | STOPPED
    @DepartmentId INT = NULL, @ChangedBy INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @EventType = NULLIF(UPPER(LTRIM(RTRIM(@EventType))), '');

    -- a version saved = Created (first) or Revised; a version closed with no newer one = Stopped
    SELECT e.* INTO #E FROM (
        SELECT 'V' + CAST(b.BomId AS VARCHAR(12)) AS EventKey, b.BomId, prev.BomId AS PrevBomId,
               CASE WHEN prev.BomId IS NULL THEN 'CREATED' ELSE 'REVISED' END AS EventType,
               b.EffectiveFrom AS EventDate, b.CreatedBy AS ChangedById
        FROM dbo.BomTest b
        OUTER APPLY (SELECT TOP 1 p.BomId FROM dbo.BomTest p WHERE p.TestId = b.TestId AND ISNULL(p.AnalyzerId, 0) = ISNULL(b.AnalyzerId, 0)
                     AND p.VersionNo < b.VersionNo ORDER BY p.VersionNo DESC) prev
        WHERE b.CompanyId = @CompanyId AND b.EffectiveFrom >= @From AND b.EffectiveFrom < @To
        UNION ALL
        SELECT 'S' + CAST(b.BomId AS VARCHAR(12)), b.BomId, b.BomId, 'STOPPED', b.EffectiveTo, b.ClosedBy
        FROM dbo.BomTest b
        WHERE b.CompanyId = @CompanyId AND b.IsActive = 0 AND b.EffectiveTo >= @From AND b.EffectiveTo < @To
          AND NOT EXISTS (SELECT 1 FROM dbo.BomTest n WHERE n.TestId = b.TestId AND ISNULL(n.AnalyzerId, 0) = ISNULL(b.AnalyzerId, 0) AND n.VersionNo > b.VersionNo)
    ) e;

    SELECT e.EventKey, e.EventType,
           CASE e.EventType WHEN 'CREATED' THEN 'BOM created' WHEN 'REVISED' THEN 'BOM revised' ELSE 'BOM stopped' END AS EventLabel,
           e.EventDate, CONVERT(VARCHAR(10), CAST(e.EventDate AS DATE), 23) AS EventDay,
           b.TestId, m.Test_Code AS TestCode, m.Test_Name AS TestName,
           ISNULL(m.Department_ID, 0) AS DepartmentId, ISNULL(d.DeptName, N'No department') AS DepartmentName,
           ISNULL(a.Analyzer_Name, N'Default (all analyzers)') AS AppliesTo, b.VersionNo,
           pv.VersionNo AS PrevVersionNo,
           (SELECT COUNT(1) FROM dbo.BomTestLine l WHERE l.BomId = b.BomId) AS LineCount,
           CASE WHEN e.EventType = 'STOPPED' THEN NULL ELSE dbo.ufn_Qc_BomCost(b.BomId) END AS NewCost,
           CASE WHEN e.EventType = 'CREATED' THEN NULL ELSE dbo.ufn_Qc_BomCost(e.PrevBomId) END AS OldCost,
           CAST(CASE WHEN e.EventType = 'REVISED' THEN dbo.ufn_Qc_BomCost(b.BomId) - dbo.ufn_Qc_BomCost(e.PrevBomId) END AS DECIMAL(14,2)) AS CostChange,
           CASE WHEN e.EventType = 'REVISED' THEN
                (SELECT COUNT(1) FROM dbo.BomTestLine n WHERE n.BomId = b.BomId AND NOT EXISTS (SELECT 1 FROM dbo.BomTestLine o WHERE o.BomId = e.PrevBomId AND o.ItemId = n.ItemId)) END AS LinesAdded,
           CASE WHEN e.EventType = 'REVISED' THEN
                (SELECT COUNT(1) FROM dbo.BomTestLine o WHERE o.BomId = e.PrevBomId AND NOT EXISTS (SELECT 1 FROM dbo.BomTestLine n WHERE n.BomId = b.BomId AND n.ItemId = o.ItemId)) END AS LinesRemoved,
           CASE WHEN e.EventType = 'REVISED' THEN
                (SELECT COUNT(1) FROM dbo.BomTestLine n INNER JOIN dbo.BomTestLine o ON o.BomId = e.PrevBomId AND o.ItemId = n.ItemId WHERE n.BomId = b.BomId AND o.Qty <> n.Qty) END AS QtyChanged,
           CASE WHEN e.EventType = 'REVISED' AND (pv.RerunPct <> b.RerunPct OR pv.DeadVolumePct <> b.DeadVolumePct)
                THEN CONCAT('Reruns ', pv.RerunPct, '% to ', b.RerunPct, '%, dead volume ', pv.DeadVolumePct, '% to ', b.DeadVolumePct, '%') END AS PctChange,
           b.Remarks, ISNULL(e.ChangedById, 0) AS ChangedById,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'Not recorded')) AS ChangedByName
    INTO #R
    FROM #E e
    INNER JOIN dbo.BomTest b ON b.BomId = e.BomId
    LEFT JOIN dbo.BomTest pv ON pv.BomId = e.PrevBomId AND e.EventType = 'REVISED'
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = b.TestId
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = m.Department_ID
    LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = b.AnalyzerId
    LEFT JOIN dbo.Users u ON u.Id = e.ChangedById
    WHERE (@EventType IS NULL OR e.EventType = @EventType)
      AND (@DepartmentId IS NULL OR m.Department_ID = @DepartmentId)
      AND (@ChangedBy IS NULL OR e.ChangedById = @ChangedBy)
      AND (@Search IS NULL OR m.Test_Name LIKE '%' + @Search + '%' OR m.Test_Code LIKE '%' + @Search + '%');

    SELECT COUNT(1) AS Events, SUM(CASE WHEN EventType = 'CREATED' THEN 1 ELSE 0 END) AS Created,
           SUM(CASE WHEN EventType = 'REVISED' THEN 1 ELSE 0 END) AS Revised, SUM(CASE WHEN EventType = 'STOPPED' THEN 1 ELSE 0 END) AS Stopped,
           COUNT(DISTINCT TestId) AS TestsChanged,
           CAST(ISNULL(SUM(CostChange), 0) AS DECIMAL(14,2)) AS NetCostChange,
           SUM(CASE WHEN CostChange > 0 THEN 1 ELSE 0 END) AS CostUp, SUM(CASE WHEN CostChange < 0 THEN 1 ELSE 0 END) AS CostDown
    FROM #R;

    SELECT 'byEvent' AS GroupKey, NULL AS GroupId, EventLabel AS GroupName, COUNT(1) AS Events, COUNT(DISTINCT TestId) AS Tests,
           CAST(ISNULL(SUM(CostChange), 0) AS DECIMAL(14,2)) AS CostChange
    FROM #R GROUP BY EventLabel
    UNION ALL
    SELECT 'byDate', NULL, EventDay, COUNT(1), COUNT(DISTINCT TestId), CAST(ISNULL(SUM(CostChange), 0) AS DECIMAL(14,2)) FROM #R GROUP BY EventDay
    UNION ALL
    SELECT 'byUser', ChangedById, ChangedByName, COUNT(1), COUNT(DISTINCT TestId), CAST(ISNULL(SUM(CostChange), 0) AS DECIMAL(14,2)) FROM #R GROUP BY ChangedById, ChangedByName
    UNION ALL
    SELECT 'byDept', DepartmentId, DepartmentName, COUNT(1), COUNT(DISTINCT TestId), CAST(ISNULL(SUM(CostChange), 0) AS DECIMAL(14,2)) FROM #R GROUP BY DepartmentId, DepartmentName
    ORDER BY GroupKey, GroupName;

    SELECT * FROM #R ORDER BY EventDate DESC, TestName;

    SELECT 'departmentId' AS FilterKey, CAST(DeptId AS VARCHAR(20)) AS Value, DeptName AS Text FROM dbo.DepartmentMaster
    WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%')
    UNION ALL
    SELECT DISTINCT 'changedBy', CAST(ChangedById AS VARCHAR(20)), ChangedByName FROM #R WHERE ChangedById > 0
    ORDER BY FilterKey, Text;

    -- line differences of each change (added / removed / quantity changed / unchanged)
    SELECT r.EventKey, x.ItemCode, x.ItemName, x.Unit, x.OldQty, x.NewQty,
           CASE WHEN x.OldQty IS NULL THEN 'Added' WHEN x.NewQty IS NULL THEN 'Removed' WHEN x.OldQty <> x.NewQty THEN 'Quantity changed' ELSE 'Unchanged' END AS Change,
           CAST(ROUND((ISNULL(x.NewQty, 0) - ISNULL(x.OldQty, 0)) * dbo.ufn_Qc_ItemUnitCost(x.ItemId), 2) AS DECIMAL(14,2)) AS CostEffect
    FROM #R r
    INNER JOIN #E e ON e.EventKey = r.EventKey
    CROSS APPLY (
        SELECT i.ItemId, i.ItemCode, i.ItemName, cu.UnitName AS Unit, o.Qty AS OldQty, n.Qty AS NewQty
        FROM (SELECT ItemId, Qty FROM dbo.BomTestLine WHERE BomId = CASE WHEN e.EventType = 'STOPPED' THEN NULL ELSE e.BomId END) n
        FULL OUTER JOIN (SELECT ItemId, Qty FROM dbo.BomTestLine WHERE BomId = CASE WHEN e.EventType = 'CREATED' THEN NULL ELSE e.PrevBomId END) o ON o.ItemId = n.ItemId
        INNER JOIN dbo.InvItem i ON i.ItemId = COALESCE(n.ItemId, o.ItemId)
        INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    ) x
    ORDER BY r.EventKey, CASE WHEN x.OldQty IS NULL THEN 1 WHEN x.NewQty IS NULL THEN 2 WHEN x.OldQty <> x.NewQty THEN 3 ELSE 4 END, x.ItemName;
END;
GO

-- ═════ #5 Test Cost Sheet ════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_TestCostSheet
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @Kind VARCHAR(20) = NULL,             -- Test | Profile
    @DepartmentId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), '');

    SELECT t.TestId, t.TestCode, t.TestName, t.Kind, t.DepartmentId, t.DepartmentName, t.SampleTypeId, t.SampleType, t.BomId, t.VersionNo,
           t.RerunPct, t.DeadVolumePct, t.LineCount, t.Rate,
           CAST(ISNULL(c.Reagent, 0) AS DECIMAL(14,2)) AS ReagentCost,
           CAST(ISNULL(c.Qc, 0) AS DECIMAL(14,2)) AS QcCost,
           CAST((ISNULL(c.Reagent, 0) + ISNULL(c.Qc, 0)) * t.RerunPct / 100.0 AS DECIMAL(14,2)) AS RerunCost,
           CAST((ISNULL(c.Reagent, 0) + ISNULL(c.Qc, 0)) * t.DeadVolumePct / 100.0 AS DECIMAL(14,2)) AS DeadVolumeCost,
           t.MaterialCost, t.KitCost,
           CAST(t.MaterialCost + ISNULL(t.KitCost, 0) AS DECIMAL(14,2)) AS TotalCost,
           CAST(t.Rate - (t.MaterialCost + ISNULL(t.KitCost, 0)) AS DECIMAL(14,2)) AS Margin,
           CAST(CASE WHEN ISNULL(t.Rate, 0) = 0 THEN NULL ELSE (t.Rate - (t.MaterialCost + ISNULL(t.KitCost, 0))) * 100.0 / t.Rate END AS DECIMAL(7,2)) AS MarginPct
    INTO #R
    FROM dbo.ufn_Qc_TestCostList(@CompanyId, @BranchId) t
    OUTER APPLY (SELECT SUM(CASE WHEN cat.IsQcMaterial = 0 THEN l.Qty * dbo.ufn_Qc_ItemUnitCost(l.ItemId) ELSE 0 END) AS Reagent,
                        SUM(CASE WHEN cat.IsQcMaterial = 1 THEN l.Qty * dbo.ufn_Qc_ItemUnitCost(l.ItemId) ELSE 0 END) AS Qc
                 FROM dbo.BomTestLine l INNER JOIN dbo.InvItem i ON i.ItemId = l.ItemId INNER JOIN dbo.InvItemCategory cat ON cat.CategoryId = i.CategoryId
                 WHERE l.BomId = t.BomId) c
    WHERE t.BomId IS NOT NULL
      AND (@Kind IS NULL OR t.Kind = @Kind) AND (@DepartmentId IS NULL OR t.DepartmentId = @DepartmentId)
      AND (@Search IS NULL OR t.TestName LIKE '%' + @Search + '%' OR t.TestCode LIKE '%' + @Search + '%');

    SELECT COUNT(1) AS Tests, CAST(AVG(TotalCost) AS DECIMAL(14,2)) AS AvgTotalCost,
           CAST(SUM(QcCost) * 100.0 / NULLIF(SUM(ReagentCost + QcCost), 0) AS DECIMAL(5,1)) AS QcSharePct,
           CAST(SUM(RerunCost + DeadVolumeCost) * 100.0 / NULLIF(SUM(ReagentCost + QcCost), 0) AS DECIMAL(5,1)) AS UpliftPct,
           CAST(SUM(KitCost) * 100.0 / NULLIF(SUM(TotalCost), 0) AS DECIMAL(5,1)) AS KitSharePct,
           CAST(AVG(MarginPct) AS DECIMAL(5,1)) AS AvgMarginPct
    FROM #R;

    SELECT 'byDept' AS GroupKey, DepartmentId AS GroupId, DepartmentName AS GroupName, COUNT(1) AS Tests,
           CAST(AVG(ReagentCost) AS DECIMAL(14,2)) AS AvgReagent, CAST(AVG(QcCost) AS DECIMAL(14,2)) AS AvgQc,
           CAST(AVG(RerunCost + DeadVolumeCost) AS DECIMAL(14,2)) AS AvgUplift, CAST(AVG(KitCost) AS DECIMAL(14,2)) AS AvgKit,
           CAST(AVG(TotalCost) AS DECIMAL(14,2)) AS AvgTotal
    FROM #R GROUP BY DepartmentId, DepartmentName
    UNION ALL
    SELECT 'byKind', NULL, Kind, COUNT(1), CAST(AVG(ReagentCost) AS DECIMAL(14,2)), CAST(AVG(QcCost) AS DECIMAL(14,2)),
           CAST(AVG(RerunCost + DeadVolumeCost) AS DECIMAL(14,2)), CAST(AVG(KitCost) AS DECIMAL(14,2)), CAST(AVG(TotalCost) AS DECIMAL(14,2))
    FROM #R GROUP BY Kind
    ORDER BY GroupKey, GroupName;

    SELECT * FROM #R ORDER BY DepartmentName, TestName;

    SELECT 'departmentId' AS FilterKey, CAST(DeptId AS VARCHAR(20)) AS Value, DeptName AS Text FROM dbo.DepartmentMaster
    WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%') ORDER BY Text;

    -- the cost lines: BOM items (reagent / QC) and the collection kit of the test's sample type
    SELECT r.TestId, x.Section, x.ItemCode, x.ItemName, x.CategoryName, x.Qty, x.Unit, x.UnitCost, x.LineCost
    FROM #R r
    CROSS APPLY (
        SELECT CASE WHEN cat.IsQcMaterial = 1 THEN 'QC share' ELSE 'Reagent & consumable' END AS Section, i.ItemCode, i.ItemName, cat.CategoryName,
               l.Qty, cu.UnitName AS Unit, dbo.ufn_Qc_ItemUnitCost(l.ItemId) AS UnitCost,
               CAST(ROUND(l.Qty * dbo.ufn_Qc_ItemUnitCost(l.ItemId), 4) AS DECIMAL(14,4)) AS LineCost, cat.IsQcMaterial AS SortKey, l.BomLineId AS Seq
        FROM dbo.BomTestLine l INNER JOIN dbo.InvItem i ON i.ItemId = l.ItemId
        INNER JOIN dbo.InvItemCategory cat ON cat.CategoryId = i.CategoryId INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
        WHERE l.BomId = r.BomId
        UNION ALL
        SELECT 'Collection kit', i.ItemCode, i.ItemName, cat.CategoryName, k.Qty, cu.UnitName, dbo.ufn_Qc_ItemUnitCost(k.ItemId),
               CAST(ROUND(k.Qty * dbo.ufn_Qc_ItemUnitCost(k.ItemId), 4) AS DECIMAL(14,4)), 2, k.KitLineId
        FROM dbo.BomSampleKit k INNER JOIN dbo.InvItem i ON i.ItemId = k.ItemId
        INNER JOIN dbo.InvItemCategory cat ON cat.CategoryId = i.CategoryId INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
        WHERE k.SampleTypeId = r.SampleTypeId AND k.IsActive = 1 AND k.CompanyId = @CompanyId
    ) x
    ORDER BY r.TestId, x.SortKey, x.Seq;
END;
GO

-- shared by #6 / #7 / #12: the caller fills #C from the cost preview (SQLScripts/2247), this adds status and margin band
-- (a procedure sees its caller's temp table; INSERT ... EXEC cannot be nested)
CREATE OR ALTER PROCEDURE dbo.usp_Qc_ReportCostBands
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE #C SET
        CostStatus = CASE WHEN MissingBom >= Tests THEN 'NOBOM' WHEN MissingBom > 0 THEN 'PARTIAL' ELSE 'COSTED' END,
        MarginBand = CASE WHEN Rate IS NULL THEN 'No B2C rate' WHEN MissingBom >= Tests THEN 'BOM missing'
                          WHEN Margin < 0 THEN 'Loss (cost above rate)' WHEN MarginPct < 20 THEN 'Below 20%' WHEN MarginPct < 40 THEN '20% to 40%'
                          WHEN MarginPct < 60 THEN '40% to 60%' ELSE '60% and above' END,
        BandOrder = CASE WHEN Rate IS NULL THEN 7 WHEN MissingBom >= Tests THEN 6 WHEN Margin < 0 THEN 1 WHEN MarginPct < 20 THEN 2
                         WHEN MarginPct < 40 THEN 3 WHEN MarginPct < 60 THEN 4 ELSE 5 END;
END;
GO
IF OBJECT_ID(N'dbo.usp_Qc_ReportCostRows', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_Qc_ReportCostRows;
GO

-- ═════ #6 Price vs Cost ══════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_PriceVsCost
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @Kind VARCHAR(20) = NULL,             -- Test | Profile | Package
    @MarginBand VARCHAR(20) = NULL,       -- LOSS | LT20 | 20TO40 | 40TO60 | GE60 | NOBOM | NORATE
    @DepartmentId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), ''); SET @MarginBand = NULLIF(UPPER(LTRIM(RTRIM(@MarginBand))), '');

    CREATE TABLE #C (Kind VARCHAR(10), ItemId INT, Code NVARCHAR(50), Name NVARCHAR(300), DepartmentName NVARCHAR(150), Tests INT, MissingBom INT,
                     MaterialCost DECIMAL(14,2), KitCost DECIMAL(14,2), TotalCost DECIMAL(14,2), Rate DECIMAL(14,2), Margin DECIMAL(14,2), MarginPct DECIMAL(7,2),
                     CostStatus VARCHAR(10), MarginBand VARCHAR(40), BandOrder INT);
    INSERT INTO #C (Kind, ItemId, Code, Name, DepartmentName, Tests, MissingBom, MaterialCost, KitCost, TotalCost, Rate, Margin, MarginPct)
    EXEC dbo.usp_Qc_CostPreview @CompanyId = @CompanyId, @BranchId = @BranchId, @Kind = @Kind, @DepartmentId = @DepartmentId, @Search = @Search;
    EXEC dbo.usp_Qc_ReportCostBands;
    DELETE FROM #C WHERE @MarginBand IS NOT NULL AND BandOrder <> CASE @MarginBand WHEN 'LOSS' THEN 1 WHEN 'LT20' THEN 2 WHEN '20TO40' THEN 3
                                                                                WHEN '40TO60' THEN 4 WHEN 'GE60' THEN 5 WHEN 'NOBOM' THEN 6 ELSE 7 END;

    SELECT COUNT(1) AS Items, SUM(CASE WHEN CostStatus = 'COSTED' THEN 1 ELSE 0 END) AS Costed,
           SUM(CASE WHEN BandOrder = 1 THEN 1 ELSE 0 END) AS LossItems, SUM(CASE WHEN BandOrder = 2 THEN 1 ELSE 0 END) AS LowItems,
           CAST(AVG(CASE WHEN CostStatus = 'COSTED' THEN MarginPct END) AS DECIMAL(5,1)) AS AvgMarginPct,
           CAST(AVG(CASE WHEN CostStatus = 'COSTED' THEN TotalCost END) AS DECIMAL(14,2)) AS AvgCost,
           SUM(CASE WHEN Rate IS NULL THEN 1 ELSE 0 END) AS NoRate
    FROM #C;

    SELECT 'byBand' AS GroupKey, NULL AS GroupId, MarginBand AS GroupName, MIN(BandOrder) AS SortOrder, COUNT(1) AS Items,
           CAST(AVG(TotalCost) AS DECIMAL(14,2)) AS AvgCost, CAST(AVG(Rate) AS DECIMAL(14,2)) AS AvgRate, CAST(AVG(MarginPct) AS DECIMAL(7,1)) AS AvgMarginPct
    FROM #C GROUP BY MarginBand
    UNION ALL
    SELECT 'byDept', NULL, DepartmentName, 1, COUNT(1), CAST(AVG(CASE WHEN CostStatus = 'COSTED' THEN TotalCost END) AS DECIMAL(14,2)),
           CAST(AVG(Rate) AS DECIMAL(14,2)), CAST(AVG(CASE WHEN CostStatus = 'COSTED' THEN MarginPct END) AS DECIMAL(7,1))
    FROM #C GROUP BY DepartmentName
    UNION ALL
    SELECT 'byKind', NULL, Kind, MIN(CASE Kind WHEN 'Test' THEN 1 WHEN 'Profile' THEN 2 ELSE 3 END), COUNT(1),
           CAST(AVG(CASE WHEN CostStatus = 'COSTED' THEN TotalCost END) AS DECIMAL(14,2)), CAST(AVG(Rate) AS DECIMAL(14,2)),
           CAST(AVG(CASE WHEN CostStatus = 'COSTED' THEN MarginPct END) AS DECIMAL(7,1))
    FROM #C GROUP BY Kind
    ORDER BY GroupKey, SortOrder, GroupName;

    SELECT * FROM #C ORDER BY BandOrder, MarginPct, Name;

    SELECT 'departmentId' AS FilterKey, CAST(DeptId AS VARCHAR(20)) AS Value, DeptName AS Text FROM dbo.DepartmentMaster
    WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%') ORDER BY Text;
END;
GO

-- ═════ #7 Loss / Low-Margin Alert ═════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_MarginAlert
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @Threshold VARCHAR(20) = NULL,        -- minimum margin %: 0 / 10 / 20 / 30 / 40 / 50 (30 when not chosen)
    @Kind VARCHAR(20) = NULL, @DepartmentId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    DECLARE @Min DECIMAL(5,2) = ISNULL(TRY_CAST(NULLIF(LTRIM(RTRIM(@Threshold)), '') AS DECIMAL(5,2)), 30);
    IF @Min < 0 OR @Min >= 100 SET @Min = 30;
    SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), '');

    CREATE TABLE #C (Kind VARCHAR(10), ItemId INT, Code NVARCHAR(50), Name NVARCHAR(300), DepartmentName NVARCHAR(150), Tests INT, MissingBom INT,
                     MaterialCost DECIMAL(14,2), KitCost DECIMAL(14,2), TotalCost DECIMAL(14,2), Rate DECIMAL(14,2), Margin DECIMAL(14,2), MarginPct DECIMAL(7,2),
                     CostStatus VARCHAR(10), MarginBand VARCHAR(40), BandOrder INT);
    INSERT INTO #C (Kind, ItemId, Code, Name, DepartmentName, Tests, MissingBom, MaterialCost, KitCost, TotalCost, Rate, Margin, MarginPct)
    EXEC dbo.usp_Qc_CostPreview @CompanyId = @CompanyId, @BranchId = @BranchId, @Kind = @Kind, @DepartmentId = @DepartmentId, @Search = @Search;
    EXEC dbo.usp_Qc_ReportCostBands;

    -- only fully costed items with a rate: a missing BOM would understate the cost
    SELECT c.*, @Min AS ThresholdPct,
           CASE WHEN c.Margin < 0 THEN 'LOSS' ELSE 'LOW' END AS Severity,
           CASE WHEN c.Margin < 0 THEN 'Loss: cost above rate' ELSE CONCAT('Margin below ', CAST(@Min AS DECIMAL(5,0)), '%') END AS SeverityLabel,
           CAST(CEILING(c.TotalCost / (1 - @Min / 100.0)) AS DECIMAL(14,2)) AS RateNeeded,
           CAST(CEILING(c.TotalCost / (1 - @Min / 100.0)) - c.Rate AS DECIMAL(14,2)) AS RateGap
    INTO #R
    FROM #C c
    WHERE c.CostStatus = 'COSTED' AND c.Rate IS NOT NULL AND (c.Margin < 0 OR c.MarginPct < @Min);

    SELECT COUNT(1) AS Alerts, SUM(CASE WHEN Severity = 'LOSS' THEN 1 ELSE 0 END) AS LossItems, SUM(CASE WHEN Severity = 'LOW' THEN 1 ELSE 0 END) AS LowItems,
           @Min AS ThresholdPct, CAST(ISNULL(SUM(RateGap), 0) AS DECIMAL(14,2)) AS TotalRateGap,
           (SELECT COUNT(1) FROM #C WHERE CostStatus = 'COSTED' AND Rate IS NOT NULL) AS CheckedItems,
           (SELECT COUNT(1) FROM #C WHERE CostStatus <> 'COSTED' OR Rate IS NULL) AS NotChecked
    FROM #R;

    SELECT 'bySeverity' AS GroupKey, NULL AS GroupId, SeverityLabel AS GroupName, MIN(CASE Severity WHEN 'LOSS' THEN 1 ELSE 2 END) AS SortOrder,
           COUNT(1) AS Items, CAST(SUM(RateGap) AS DECIMAL(14,2)) AS RateGap, CAST(AVG(MarginPct) AS DECIMAL(7,1)) AS AvgMarginPct
    FROM #R GROUP BY SeverityLabel
    UNION ALL
    SELECT 'byDept', NULL, DepartmentName, 1, COUNT(1), CAST(SUM(RateGap) AS DECIMAL(14,2)), CAST(AVG(MarginPct) AS DECIMAL(7,1)) FROM #R GROUP BY DepartmentName
    UNION ALL
    SELECT 'byKind', NULL, Kind, MIN(CASE Kind WHEN 'Test' THEN 1 WHEN 'Profile' THEN 2 ELSE 3 END), COUNT(1), CAST(SUM(RateGap) AS DECIMAL(14,2)),
           CAST(AVG(MarginPct) AS DECIMAL(7,1))
    FROM #R GROUP BY Kind
    ORDER BY GroupKey, SortOrder, GroupName;

    SELECT * FROM #R ORDER BY CASE Severity WHEN 'LOSS' THEN 1 ELSE 2 END, MarginPct, Name;

    SELECT 'departmentId' AS FilterKey, CAST(DeptId AS VARCHAR(20)) AS Value, DeptName AS Text FROM dbo.DepartmentMaster
    WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%') ORDER BY Text;
END;
GO

-- ═════ #8 Package & Profile Profitability ═══════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_PackageProfitability
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @Kind VARCHAR(20) = NULL,             -- Package | Profile
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), '');

    SELECT * INTO #T FROM dbo.ufn_Qc_TestCostList(@CompanyId, @BranchId);

    -- members: a package's tests / profile tests (Profile_Type 2); a profile test's parameters (Profile_Type 1)
    SELECT h.Profile_ID AS ProfileId, CASE WHEN h.Profile_Type = 2 THEN 'Package' ELSE 'Profile' END AS Kind, pd.Test_ID AS TestId,
           t.TestCode, t.TestName, t.SampleTypeId, t.Rate AS OwnRate, t.MaterialCost, t.KitCost,
           CAST(CASE WHEN t.MaterialCost IS NULL THEN NULL ELSE t.MaterialCost + ISNULL(t.KitCost, 0) END AS DECIMAL(14,2)) AS OwnCost,
           CAST(CASE WHEN t.BomId IS NULL THEN 0 ELSE 1 END AS BIT) AS HasBom, t.IsOutsourced
    INTO #M
    FROM dbo.LabInvestigationProfileHeader h
    INNER JOIN dbo.LabInvestigationProfileDetail pd ON pd.Profile_ID = h.Profile_ID AND ISNULL(pd.IsDeleted, 0) = 0
    LEFT JOIN #T t ON t.TestId = pd.Test_ID
    WHERE ISNULL(h.IsDeleted, 0) = 0 AND h.Status = 1 AND (h.CompanyId = @CompanyId OR h.CompanyId IS NULL)
      AND (h.Profile_Type = 2 OR h.Test_ID IS NOT NULL);

    SELECT x.* INTO #R FROM (
        -- package: cost = its tests' material + one kit per distinct sample type (as the cost preview)
        SELECT 'Package' AS Kind, h.Profile_ID AS ProfileId, h.Profile_Code AS Code, h.Profile_Name AS Name, N'Packages' AS DepartmentName,
               r.B2CRate AS Rate,
               (SELECT COUNT(1) FROM #M m WHERE m.ProfileId = h.Profile_ID) AS Members,
               (SELECT COUNT(1) FROM #M m WHERE m.ProfileId = h.Profile_ID AND m.HasBom = 0) AS MissingBom,
               CAST((SELECT SUM(m.OwnRate) FROM #M m WHERE m.ProfileId = h.Profile_ID) AS DECIMAL(14,2)) AS SeparatePrice,
               CAST((SELECT SUM(ISNULL(m.MaterialCost, 0)) FROM #M m WHERE m.ProfileId = h.Profile_ID)
                    + ISNULL((SELECT SUM(ISNULL(dbo.ufn_Qc_SampleKitCost(s.SampleTypeId), 0)) FROM (SELECT DISTINCT m.SampleTypeId FROM #M m WHERE m.ProfileId = h.Profile_ID) s), 0) AS DECIMAL(14,2)) AS TotalCost
        FROM dbo.LabInvestigationProfileHeader h
        OUTER APPLY (SELECT TOP 1 x.B2CRate FROM dbo.fn_LabBookableItems(@BranchId, 'B2C', NULL) x WHERE x.Item_ID = h.Profile_ID AND x.Item_Type = 'Package') r
        WHERE ISNULL(h.IsDeleted, 0) = 0 AND h.Status = 1 AND h.Profile_Type = 2 AND (h.CompanyId = @CompanyId OR h.CompanyId IS NULL)
        UNION ALL
        -- profile test: its own BOM (one run of the panel) against the price of its parameters ordered one by one
        SELECT 'Profile', h.Profile_ID, t.TestCode, t.TestName, t.DepartmentName, t.Rate,
               (SELECT COUNT(1) FROM #M m WHERE m.ProfileId = h.Profile_ID),
               CASE WHEN t.BomId IS NULL THEN 1 ELSE 0 END,
               CAST((SELECT SUM(m.OwnRate) FROM #M m WHERE m.ProfileId = h.Profile_ID) AS DECIMAL(14,2)),
               CAST(CASE WHEN t.MaterialCost IS NULL THEN NULL ELSE t.MaterialCost + ISNULL(t.KitCost, 0) END AS DECIMAL(14,2))
        FROM dbo.LabInvestigationProfileHeader h
        INNER JOIN #T t ON t.TestId = h.Test_ID
        WHERE ISNULL(h.IsDeleted, 0) = 0 AND h.Status = 1 AND h.Profile_Type = 1 AND (h.CompanyId = @CompanyId OR h.CompanyId IS NULL)
    ) x
    WHERE (@Kind IS NULL OR x.Kind = @Kind) AND (@Search IS NULL OR x.Name LIKE '%' + @Search + '%' OR x.Code LIKE '%' + @Search + '%');

    ALTER TABLE #R ADD PatientSaving DECIMAL(14,2), SavingPct DECIMAL(7,2), Margin DECIMAL(14,2), MarginPct DECIMAL(7,2), Status NVARCHAR(40);
    UPDATE #R SET PatientSaving = CASE WHEN Rate IS NOT NULL AND SeparatePrice IS NOT NULL THEN SeparatePrice - Rate END,
                  SavingPct = CASE WHEN Rate IS NOT NULL AND ISNULL(SeparatePrice, 0) > 0 THEN (SeparatePrice - Rate) * 100.0 / SeparatePrice END,
                  Margin = CASE WHEN Rate IS NOT NULL AND TotalCost IS NOT NULL THEN Rate - TotalCost END,
                  MarginPct = CASE WHEN ISNULL(Rate, 0) > 0 AND TotalCost IS NOT NULL THEN (Rate - TotalCost) * 100.0 / Rate END;
    UPDATE #R SET Status = CASE WHEN Rate IS NULL THEN N'No B2C rate' WHEN TotalCost IS NULL OR MissingBom >= Members AND Kind = 'Package' THEN N'BOM missing'
                                WHEN MissingBom > 0 THEN N'Partly costed' WHEN Margin < 0 THEN N'Loss' WHEN MarginPct < 30 THEN N'Low margin' ELSE N'Healthy' END;

    SELECT SUM(CASE WHEN Kind = 'Package' THEN 1 ELSE 0 END) AS Packages, SUM(CASE WHEN Kind = 'Profile' THEN 1 ELSE 0 END) AS Profiles,
           CAST(AVG(CASE WHEN Status IN (N'Healthy', N'Low margin', N'Loss') THEN MarginPct END) AS DECIMAL(5,1)) AS AvgMarginPct,
           CAST(AVG(SavingPct) AS DECIMAL(5,1)) AS AvgSavingPct,
           SUM(CASE WHEN Status IN (N'Loss', N'Low margin') THEN 1 ELSE 0 END) AS WeakItems,
           SUM(CASE WHEN Status IN (N'BOM missing', N'Partly costed', N'No B2C rate') THEN 1 ELSE 0 END) AS IncompleteItems
    FROM #R;

    SELECT 'byStatus' AS GroupKey, NULL AS GroupId, Status AS GroupName, COUNT(1) AS Items, CAST(SUM(Rate) AS DECIMAL(14,2)) AS Price,
           CAST(SUM(TotalCost) AS DECIMAL(14,2)) AS Cost, CAST(SUM(Margin) AS DECIMAL(14,2)) AS Margin
    FROM #R GROUP BY Status
    UNION ALL
    SELECT 'byKind', NULL, Kind, COUNT(1), CAST(SUM(Rate) AS DECIMAL(14,2)), CAST(SUM(TotalCost) AS DECIMAL(14,2)), CAST(SUM(Margin) AS DECIMAL(14,2))
    FROM #R GROUP BY Kind
    ORDER BY GroupKey, GroupName;

    SELECT * FROM #R ORDER BY Kind DESC, Name;

    SELECT m.ProfileId, m.Kind, m.TestCode, m.TestName, m.OwnRate, m.MaterialCost, m.KitCost, m.OwnCost, m.HasBom, m.IsOutsourced
    FROM #M m WHERE EXISTS (SELECT 1 FROM #R r WHERE r.ProfileId = m.ProfileId)
    ORDER BY m.ProfileId, m.TestName;
END;
GO

-- ═════ #9 Sample Kit Cost Register ══════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_SampleKitCost
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @KitStatus VARCHAR(20) = NULL,        -- DEFINED | NOTDEFINED
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @KitStatus = NULLIF(UPPER(LTRIM(RTRIM(@KitStatus))), '');

    SELECT st.Sample_Type_ID AS SampleTypeId, st.Sample_Name AS SampleType, st.Container_Type AS Container,
           (SELECT COUNT(1) FROM dbo.BomSampleKit k WHERE k.SampleTypeId = st.Sample_Type_ID AND k.IsActive = 1 AND k.CompanyId = @CompanyId) AS LineCount,
           dbo.ufn_Qc_SampleKitCost(st.Sample_Type_ID) AS KitCost,
           (SELECT COUNT(1) FROM dbo.LabInvestigationMaster m WHERE m.Sample_Type_ID = st.Sample_Type_ID AND ISNULL(m.IsDeleted, 0) = 0 AND m.Status = 1
                AND (ISNULL(m.Is_Billable, 1) = 1 OR ISNULL(m.Is_Profile_Test, 0) = 1)) AS Tests,
           (SELECT MAX(k.CreatedDate) FROM dbo.BomSampleKit k WHERE k.SampleTypeId = st.Sample_Type_ID AND k.IsActive = 1 AND k.CompanyId = @CompanyId) AS UpdatedOn
    INTO #A
    FROM dbo.LabSampleTypeMaster st
    WHERE ISNULL(st.IsDeleted, 0) = 0 AND st.Status = 1
      AND (@Search IS NULL OR st.Sample_Name LIKE '%' + @Search + '%' OR st.Container_Type LIKE '%' + @Search + '%');

    SELECT a.*, CASE WHEN a.LineCount > 0 THEN 'DEFINED' ELSE 'NOTDEFINED' END AS KitStatus,
           CASE WHEN a.LineCount > 0 THEN 'Kit defined' ELSE 'No kit defined' END AS KitStatusLabel
    INTO #R FROM #A a;

    SELECT COUNT(1) AS SampleTypes, SUM(CASE WHEN KitStatus = 'DEFINED' THEN 1 ELSE 0 END) AS Defined,
           SUM(CASE WHEN KitStatus = 'NOTDEFINED' THEN 1 ELSE 0 END) AS NotDefined,
           SUM(CASE WHEN KitStatus = 'NOTDEFINED' THEN Tests ELSE 0 END) AS TestsWithoutKit,
           CAST(AVG(CASE WHEN KitStatus = 'DEFINED' THEN KitCost END) AS DECIMAL(14,2)) AS AvgKitCost,
           (SELECT TOP 1 SampleType FROM #R WHERE KitStatus = 'DEFINED' ORDER BY KitCost DESC) AS CostliestKit,
           (SELECT MAX(KitCost) FROM #R) AS CostliestKitCost
    FROM #R;

    SELECT 'byStatus' AS GroupKey, NULL AS GroupId, KitStatusLabel AS GroupName, COUNT(1) AS SampleTypes, SUM(Tests) AS Tests,
           CAST(AVG(KitCost) AS DECIMAL(14,2)) AS AvgKitCost
    FROM #R GROUP BY KitStatusLabel
    UNION ALL
    SELECT 'byContainer', NULL, ISNULL(Container, N'Not set'), COUNT(1), SUM(Tests), CAST(AVG(KitCost) AS DECIMAL(14,2))
    FROM #R GROUP BY ISNULL(Container, N'Not set')
    ORDER BY GroupKey, GroupName;

    SELECT * FROM #R WHERE (@KitStatus IS NULL OR KitStatus = @KitStatus) ORDER BY CASE KitStatus WHEN 'DEFINED' THEN 1 ELSE 2 END, SampleType;

    SELECT CAST(NULL AS VARCHAR(20)) AS FilterKey, CAST(NULL AS VARCHAR(20)) AS Value, CAST(NULL AS NVARCHAR(100)) AS Text WHERE 1 = 0;

    SELECT k.SampleTypeId, i.ItemCode, i.ItemName, c.CategoryName, k.Qty, cu.UnitName AS Unit, dbo.ufn_Qc_ItemUnitCost(k.ItemId) AS UnitCost,
           CAST(ROUND(k.Qty * dbo.ufn_Qc_ItemUnitCost(k.ItemId), 4) AS DECIMAL(14,4)) AS LineCost
    FROM dbo.BomSampleKit k
    INNER JOIN dbo.InvItem i ON i.ItemId = k.ItemId
    INNER JOIN dbo.InvItemCategory c ON c.CategoryId = i.CategoryId
    INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    WHERE k.IsActive = 1 AND k.CompanyId = @CompanyId AND k.SampleTypeId IN (SELECT SampleTypeId FROM #R)
    ORDER BY k.SampleTypeId, k.KitLineId;
END;
GO

-- ═════ #10 Analyzer-wise Cost Comparison ═════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_AnalyzerCost
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @AnalyzerId INT = NULL, @DepartmentId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');

    -- tests run on more than one setup: the default BOM and each analyzer's own BOM
    SELECT b.BomId, b.TestId, m.Test_Code AS TestCode, m.Test_Name AS TestName, ISNULL(m.Department_ID, 0) AS DepartmentId,
           ISNULL(d.DeptName, N'No department') AS DepartmentName, ISNULL(b.AnalyzerId, 0) AS AnalyzerId,
           ISNULL(a.Analyzer_Name, N'Default (all analyzers)') AS AppliesTo, b.VersionNo, b.RerunPct, b.DeadVolumePct,
           (SELECT COUNT(1) FROM dbo.BomTestLine l WHERE l.BomId = b.BomId) AS LineCount,
           dbo.ufn_Qc_BomCost(b.BomId) AS MaterialCost,
           dbo.ufn_Qc_BomCost((SELECT TOP 1 x.BomId FROM dbo.BomTest x WHERE x.TestId = b.TestId AND x.IsActive = 1 AND x.AnalyzerId IS NULL)) AS DefaultCost
    INTO #B
    FROM dbo.BomTest b
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = b.TestId
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = m.Department_ID
    LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = b.AnalyzerId
    WHERE b.IsActive = 1 AND b.CompanyId = @CompanyId
      AND EXISTS (SELECT 1 FROM dbo.BomTest x WHERE x.TestId = b.TestId AND x.IsActive = 1 AND x.AnalyzerId IS NOT NULL)
      AND (@DepartmentId IS NULL OR m.Department_ID = @DepartmentId)
      AND (@Search IS NULL OR m.Test_Name LIKE '%' + @Search + '%' OR m.Test_Code LIKE '%' + @Search + '%')
      AND (@AnalyzerId IS NULL OR EXISTS (SELECT 1 FROM dbo.BomTest x WHERE x.TestId = b.TestId AND x.IsActive = 1 AND x.AnalyzerId = @AnalyzerId));

    SELECT b.*,
           CAST(CASE WHEN b.AnalyzerId > 0 AND b.DefaultCost IS NOT NULL THEN b.MaterialCost - b.DefaultCost END AS DECIMAL(14,2)) AS DiffVsDefault,
           CAST(CASE WHEN b.AnalyzerId > 0 AND ISNULL(b.DefaultCost, 0) > 0 THEN (b.MaterialCost - b.DefaultCost) * 100.0 / b.DefaultCost END AS DECIMAL(7,1)) AS DiffPct,
           CAST(CASE WHEN b.MaterialCost = (SELECT MIN(x.MaterialCost) FROM #B x WHERE x.TestId = b.TestId) THEN 1 ELSE 0 END AS BIT) AS IsCheapest,
           CAST((SELECT MAX(x.MaterialCost) - MIN(x.MaterialCost) FROM #B x WHERE x.TestId = b.TestId) AS DECIMAL(14,2)) AS Spread
    INTO #R FROM #B b;

    SELECT COUNT(DISTINCT TestId) AS TestsCompared, SUM(CASE WHEN AnalyzerId > 0 THEN 1 ELSE 0 END) AS AnalyzerBoms,
           SUM(CASE WHEN DiffVsDefault < 0 THEN 1 ELSE 0 END) AS Cheaper, SUM(CASE WHEN DiffVsDefault > 0 THEN 1 ELSE 0 END) AS Dearer,
           CAST(MAX(Spread) AS DECIMAL(14,2)) AS MaxSpread,
           (SELECT TOP 1 TestName FROM #R ORDER BY Spread DESC) AS MaxSpreadTest
    FROM #R;

    SELECT 'byAnalyzer' AS GroupKey, AnalyzerId AS GroupId, AppliesTo AS GroupName, COUNT(1) AS Boms,
           CAST(AVG(MaterialCost) AS DECIMAL(14,2)) AS AvgCost, CAST(AVG(DiffVsDefault) AS DECIMAL(14,2)) AS AvgDiff
    FROM #R GROUP BY AnalyzerId, AppliesTo
    UNION ALL
    SELECT 'byTest', TestId, TestName, COUNT(1), CAST(AVG(MaterialCost) AS DECIMAL(14,2)), CAST(MAX(Spread) AS DECIMAL(14,2))
    FROM #R GROUP BY TestId, TestName
    ORDER BY GroupKey, GroupName;

    SELECT * FROM #R ORDER BY DepartmentName, TestName, AnalyzerId;

    SELECT 'analyzerId' AS FilterKey, CAST(Analyzer_ID AS VARCHAR(20)) AS Value, Analyzer_Name AS Text FROM dbo.tbl_mst_analyzer
    WHERE ISNULL(IsDeleted, 0) = 0 AND ISNULL(Status, 1) = 1 AND (CompanyId = @CompanyId OR CompanyId IS NULL)
    UNION ALL
    SELECT 'departmentId', CAST(DeptId AS VARCHAR(20)), DeptName FROM dbo.DepartmentMaster WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%')
    ORDER BY FilterKey, Text;

    SELECT l.BomId, i.ItemCode, i.ItemName, l.Qty, cu.UnitName AS Unit, dbo.ufn_Qc_ItemUnitCost(l.ItemId) AS UnitCost,
           CAST(ROUND(l.Qty * dbo.ufn_Qc_ItemUnitCost(l.ItemId), 4) AS DECIMAL(14,4)) AS LineCost
    FROM dbo.BomTestLine l INNER JOIN dbo.InvItem i ON i.ItemId = l.ItemId INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    WHERE l.BomId IN (SELECT BomId FROM #R) ORDER BY l.BomId, l.BomLineId;
END;
GO

-- ═════ #11 Price-Change Impact (what-if) ═════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_PriceImpact
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @ChangePct VARCHAR(20) = NULL,        -- price change in %, e.g. 10 or -5 (10 when not chosen)
    @ItemId INT = NULL, @CategoryId INT = NULL,   -- neither = every item
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    DECLARE @Pct DECIMAL(7,2) = ISNULL(TRY_CAST(NULLIF(LTRIM(RTRIM(@ChangePct)), '') AS DECIMAL(7,2)), 10);
    IF @Pct <= -100 OR @Pct > 500 SET @Pct = 10;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');

    -- the items whose price changes, with their unit cost now and after the change
    SELECT i.ItemId, dbo.ufn_Qc_ItemUnitCost(i.ItemId) AS UnitCost, dbo.ufn_Qc_ItemUnitCost(i.ItemId) * (1 + @Pct / 100.0) AS NewUnitCost
    INTO #F
    FROM dbo.InvItem i
    WHERE i.CompanyId = @CompanyId AND i.IsDeleted = 0
      AND (@ItemId IS NULL OR i.ItemId = @ItemId) AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId);

    SELECT t.TestId, t.TestCode, t.TestName, t.Kind, t.DepartmentId, t.DepartmentName, t.SampleType, t.Rate,
           t.MaterialCost, t.KitCost, CAST(t.MaterialCost + ISNULL(t.KitCost, 0) AS DECIMAL(14,2)) AS TotalCost,
           CAST(ROUND(nm.Items * (1 + (t.RerunPct + t.DeadVolumePct) / 100.0), 2) AS DECIMAL(14,2)) AS NewMaterialCost,
           CAST(ROUND(nk.Items, 2) AS DECIMAL(14,2)) AS NewKitCost,
           (SELECT STRING_AGG(i.ItemName, ', ') FROM (SELECT DISTINCT l.ItemId FROM dbo.BomTestLine l WHERE l.BomId = t.BomId AND l.ItemId IN (SELECT ItemId FROM #F)
                                                        UNION SELECT k.ItemId FROM dbo.BomSampleKit k WHERE k.SampleTypeId = t.SampleTypeId AND k.IsActive = 1 AND k.CompanyId = @CompanyId
                                                              AND k.ItemId IN (SELECT ItemId FROM #F)) u
            INNER JOIN dbo.InvItem i ON i.ItemId = u.ItemId) AS ItemsAffected
    INTO #A
    FROM dbo.ufn_Qc_TestCostList(@CompanyId, @BranchId) t
    OUTER APPLY (SELECT SUM(l.Qty * ISNULL(f.NewUnitCost, dbo.ufn_Qc_ItemUnitCost(l.ItemId))) AS Items
                 FROM dbo.BomTestLine l LEFT JOIN #F f ON f.ItemId = l.ItemId WHERE l.BomId = t.BomId) nm
    OUTER APPLY (SELECT SUM(k.Qty * ISNULL(f.NewUnitCost, dbo.ufn_Qc_ItemUnitCost(k.ItemId))) AS Items
                 FROM dbo.BomSampleKit k LEFT JOIN #F f ON f.ItemId = k.ItemId
                 WHERE k.SampleTypeId = t.SampleTypeId AND k.IsActive = 1 AND k.CompanyId = @CompanyId) nk
    WHERE t.BomId IS NOT NULL
      AND (EXISTS (SELECT 1 FROM dbo.BomTestLine l WHERE l.BomId = t.BomId AND l.ItemId IN (SELECT ItemId FROM #F))
           OR EXISTS (SELECT 1 FROM dbo.BomSampleKit k WHERE k.SampleTypeId = t.SampleTypeId AND k.IsActive = 1 AND k.CompanyId = @CompanyId AND k.ItemId IN (SELECT ItemId FROM #F)))
      AND (@Search IS NULL OR t.TestName LIKE '%' + @Search + '%' OR t.TestCode LIKE '%' + @Search + '%');

    SELECT a.*, @Pct AS ChangePct,
           CAST(a.NewMaterialCost + ISNULL(a.NewKitCost, 0) AS DECIMAL(14,2)) AS NewTotalCost,
           CAST(a.NewMaterialCost + ISNULL(a.NewKitCost, 0) - a.TotalCost AS DECIMAL(14,2)) AS CostChange,
           CAST(CASE WHEN a.TotalCost > 0 THEN (a.NewMaterialCost + ISNULL(a.NewKitCost, 0) - a.TotalCost) * 100.0 / a.TotalCost END AS DECIMAL(7,1)) AS CostChangePct,
           CAST(CASE WHEN ISNULL(a.Rate, 0) > 0 THEN (a.Rate - a.TotalCost) * 100.0 / a.Rate END AS DECIMAL(7,1)) AS MarginPct,
           CAST(CASE WHEN ISNULL(a.Rate, 0) > 0 THEN (a.Rate - (a.NewMaterialCost + ISNULL(a.NewKitCost, 0))) * 100.0 / a.Rate END AS DECIMAL(7,1)) AS NewMarginPct
    INTO #R FROM #A a;
    ALTER TABLE #R ADD Outcome NVARCHAR(40), OutcomeOrder INT;
    UPDATE #R SET Outcome = CASE WHEN Rate IS NULL THEN N'No B2C rate' WHEN NewMarginPct < 0 AND MarginPct >= 0 THEN N'Turns loss-making'
                                 WHEN NewMarginPct < 0 THEN N'Already loss-making' WHEN NewMarginPct < 30 AND MarginPct >= 30 THEN N'Falls below 30% margin'
                                 WHEN NewMarginPct < 30 THEN N'Already below 30%' ELSE N'Still 30% or more' END;
    UPDATE #R SET OutcomeOrder = CASE Outcome WHEN N'Turns loss-making' THEN 1 WHEN N'Already loss-making' THEN 2 WHEN N'Falls below 30% margin' THEN 3
                                              WHEN N'Already below 30%' THEN 4 WHEN N'Still 30% or more' THEN 5 ELSE 6 END;

    SELECT @Pct AS ChangePct, (SELECT COUNT(1) FROM #F) AS ItemsChanged, COUNT(1) AS TestsAffected,
           CAST(AVG(CostChange) AS DECIMAL(14,2)) AS AvgCostChange, CAST(MAX(CostChange) AS DECIMAL(14,2)) AS MaxCostChange,
           SUM(CASE WHEN OutcomeOrder = 1 THEN 1 ELSE 0 END) AS TurnLoss, SUM(CASE WHEN OutcomeOrder = 3 THEN 1 ELSE 0 END) AS FallBelow30,
           CAST(AVG(MarginPct) AS DECIMAL(5,1)) AS AvgMarginPct, CAST(AVG(NewMarginPct) AS DECIMAL(5,1)) AS AvgNewMarginPct,
           CASE WHEN @ItemId IS NOT NULL THEN (SELECT ItemName FROM dbo.InvItem WHERE ItemId = @ItemId)
                WHEN @CategoryId IS NOT NULL THEN (SELECT CategoryName + N' (all items)' FROM dbo.InvItemCategory WHERE CategoryId = @CategoryId)
                ELSE N'All items' END AS ChangedWhat
    FROM #R;

    SELECT 'byOutcome' AS GroupKey, NULL AS GroupId, Outcome AS GroupName, MIN(OutcomeOrder) AS SortOrder, COUNT(1) AS Tests,
           CAST(SUM(CostChange) AS DECIMAL(14,2)) AS CostChange, CAST(AVG(MarginPct) AS DECIMAL(7,1)) AS MarginPct, CAST(AVG(NewMarginPct) AS DECIMAL(7,1)) AS NewMarginPct
    FROM #R GROUP BY Outcome
    UNION ALL
    SELECT 'byDept', DepartmentId, DepartmentName, 1, COUNT(1), CAST(SUM(CostChange) AS DECIMAL(14,2)), CAST(AVG(MarginPct) AS DECIMAL(7,1)), CAST(AVG(NewMarginPct) AS DECIMAL(7,1))
    FROM #R GROUP BY DepartmentId, DepartmentName
    ORDER BY GroupKey, SortOrder, GroupName;

    SELECT * FROM #R ORDER BY OutcomeOrder, CostChange DESC, TestName;

    SELECT 'itemId' AS FilterKey, CAST(ItemId AS VARCHAR(20)) AS Value, ItemName AS Text FROM dbo.InvItem WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND Status = 1
    UNION ALL
    SELECT 'categoryId', CAST(CategoryId AS VARCHAR(20)), CategoryName FROM dbo.InvItemCategory WHERE IsActive = 1
    ORDER BY FilterKey, Text;
END;
GO

-- ═════ #12 Department Cost Summary ═══════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_DeptCostSummary
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @Kind VARCHAR(20) = NULL,             -- Test | Profile
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), '');

    CREATE TABLE #C (Kind VARCHAR(10), ItemId INT, Code NVARCHAR(50), Name NVARCHAR(300), DepartmentName NVARCHAR(150), Tests INT, MissingBom INT,
                     MaterialCost DECIMAL(14,2), KitCost DECIMAL(14,2), TotalCost DECIMAL(14,2), Rate DECIMAL(14,2), Margin DECIMAL(14,2), MarginPct DECIMAL(7,2),
                     CostStatus VARCHAR(10), MarginBand VARCHAR(40), BandOrder INT);
    INSERT INTO #C (Kind, ItemId, Code, Name, DepartmentName, Tests, MissingBom, MaterialCost, KitCost, TotalCost, Rate, Margin, MarginPct)
    EXEC dbo.usp_Qc_CostPreview @CompanyId = @CompanyId, @BranchId = @BranchId, @Kind = @Kind, @DepartmentId = NULL, @Search = @Search;
    EXEC dbo.usp_Qc_ReportCostBands;
    DELETE FROM #C WHERE Kind = 'Package';   -- packages are not billed under a department

    SELECT 'byDept' AS GroupKey, NULL AS GroupId, DepartmentName AS GroupName, COUNT(1) AS Tests,
           SUM(CASE WHEN CostStatus = 'COSTED' THEN 1 ELSE 0 END) AS Costed,
           CAST(AVG(CASE WHEN CostStatus = 'COSTED' THEN TotalCost END) AS DECIMAL(14,2)) AS AvgCost,
           CAST(AVG(CASE WHEN CostStatus = 'COSTED' THEN Rate END) AS DECIMAL(14,2)) AS AvgRate,
           CAST(AVG(CASE WHEN CostStatus = 'COSTED' AND Rate IS NOT NULL THEN MarginPct END) AS DECIMAL(7,1)) AS AvgMarginPct,
           SUM(CASE WHEN BandOrder = 1 THEN 1 ELSE 0 END) AS LossTests, SUM(CASE WHEN BandOrder = 2 THEN 1 ELSE 0 END) AS LowTests
    INTO #G FROM #C GROUP BY DepartmentName;

    SELECT (SELECT COUNT(1) FROM #G) AS Departments, (SELECT SUM(Tests) FROM #G) AS Tests, (SELECT SUM(Costed) FROM #G) AS Costed,
           (SELECT TOP 1 GroupName FROM #G WHERE AvgMarginPct IS NOT NULL ORDER BY AvgMarginPct DESC) AS BestDept,
           (SELECT TOP 1 AvgMarginPct FROM #G WHERE AvgMarginPct IS NOT NULL ORDER BY AvgMarginPct DESC) AS BestMarginPct,
           (SELECT TOP 1 GroupName FROM #G WHERE AvgMarginPct IS NOT NULL ORDER BY AvgMarginPct) AS WeakDept,
           (SELECT TOP 1 AvgMarginPct FROM #G WHERE AvgMarginPct IS NOT NULL ORDER BY AvgMarginPct) AS WeakMarginPct,
           (SELECT SUM(LossTests) FROM #G) AS LossTests;

    SELECT * FROM #G
    UNION ALL
    SELECT 'byKind', NULL, Kind, COUNT(1), SUM(CASE WHEN CostStatus = 'COSTED' THEN 1 ELSE 0 END),
           CAST(AVG(CASE WHEN CostStatus = 'COSTED' THEN TotalCost END) AS DECIMAL(14,2)), CAST(AVG(CASE WHEN CostStatus = 'COSTED' THEN Rate END) AS DECIMAL(14,2)),
           CAST(AVG(CASE WHEN CostStatus = 'COSTED' AND Rate IS NOT NULL THEN MarginPct END) AS DECIMAL(7,1)),
           SUM(CASE WHEN BandOrder = 1 THEN 1 ELSE 0 END), SUM(CASE WHEN BandOrder = 2 THEN 1 ELSE 0 END)
    FROM #C GROUP BY Kind
    ORDER BY GroupKey, AvgMarginPct DESC;

    SELECT * FROM #C ORDER BY DepartmentName, BandOrder, MarginPct, Name;
END;
GO

-- Pages under Reports > LAB -----------------------------------------------------------------------
DECLARE @co INT, @menu INT, @page INT, @view INT, @code NVARCHAR(150), @title NVARCHAR(150), @action NVARCHAR(100), @sort INT, @icon NVARCHAR(100);
DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
 (N'REPORTS.LABBOMREGISTER',   N'Test BOM Register',               N'LabBomRegister',          300, N'bi bi-diagram-3 me-2'),
 (N'REPORTS.LABBOMCOVERAGE',   N'BOM Coverage',                    N'LabBomCoverage',          305, N'bi bi-ui-checks-grid me-2'),
 (N'REPORTS.LABITEMWHEREUSED', N'Item Where-Used',                 N'LabItemWhereUsed',        310, N'bi bi-box-arrow-in-down-right me-2'),
 (N'REPORTS.LABBOMHISTORY',    N'BOM Change History',              N'LabBomHistory',           315, N'bi bi-clock-history me-2'),
 (N'REPORTS.LABTESTCOSTSHEET', N'Test Cost Sheet',                 N'LabTestCostSheet',        320, N'bi bi-receipt-cutoff me-2'),
 (N'REPORTS.LABPRICEVSCOST',   N'Price vs Cost (Margin)',          N'LabPriceVsCost',          325, N'bi bi-graph-up-arrow me-2'),
 (N'REPORTS.LABMARGINALERT',   N'Loss / Low-Margin Alert',         N'LabMarginAlert',          330, N'bi bi-exclamation-triangle me-2'),
 (N'REPORTS.LABPACKAGEPROFIT', N'Package & Profile Profitability', N'LabPackageProfitability', 335, N'bi bi-boxes me-2'),
 (N'REPORTS.LABKITCOST',       N'Sample Kit Cost Register',        N'LabSampleKitCost',        340, N'bi bi-droplet me-2'),
 (N'REPORTS.LABANALYZERCOST',  N'Analyzer-wise Cost Comparison',   N'LabAnalyzerCost',         345, N'bi bi-cpu me-2'),
 (N'REPORTS.LABPRICEIMPACT',   N'Price-Change Impact (What-if)',   N'LabPriceImpact',          350, N'bi bi-sliders me-2'),
 (N'REPORTS.LABDEPTCOST',      N'Department Cost Summary',         N'LabDeptCostSummary',      355, N'bi bi-building me-2');

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Action, Sort, Icon FROM @Pages;
        OPEN pg; FETCH NEXT FROM pg INTO @code, @title, @action, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @page = NULL;
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title, @Controller = N'Reports',
                 @Action = @action, @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Page_ID = @page OUTPUT;
            SET @view = NULL;
            SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = @action, @Source = 'SEED';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = N'GetLabReportData', @Source = 'SEED';
            FETCH NEXT FROM pg INTO @code, @title, @action, @sort, @icon;
        END
        CLOSE pg; DEALLOCATE pg;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2248 applied: BOM & Costing reports (12) under Reports > LAB.';
GO
