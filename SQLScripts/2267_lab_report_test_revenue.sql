-- ============================================================================================================
-- Migration: 2267_lab_report_test_revenue.sql
-- LR-23 Test & Department Volume and Revenue (Reports > LAB): which tests, profiles and packages bring the volume
-- and the money. By bill date.
--   Revenue per line = the line's share of its bill's net (B2B at the partner rate) - exactly as the Owner MIS
--   (usp_Api_LabReport_OwnerMis) splits a bill, so both reports show the same revenue.
--   Growth: against the previous period of the same length.
--   RS1 summary - RS2 groups (byTest, byKind, byDepartment, byBillingType) - RS3 rows (one per bill line) - RS4 options
--   Own-data rule: a user without Administrator sees only the bills they created (as LR-24).
--   Cost and gross profit per test from the BOM (2247-2249), exactly as the Owner MIS (2252): actual = the consumption
--   runs recorded for the line (re-runs included, at each run's frozen cost); estimated = an in-house test billed but not
--   run yet, at its current BOM cost; a package is its member tests; outsourced tests carry no BOM cost. Collection kits
--   are a per-bill cost and stay in the Owner MIS (not split per test).
-- Run after 2266. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_TestRevenue
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @Kind          VARCHAR(10)   = NULL,   -- Test / Profile / Package
    @BillingType   VARCHAR(10)   = NULL,   -- B2C / B2B
    @DepartmentId  INT           = NULL,
    @CreatedBy     INT           = NULL,
    @Search        NVARCHAR(100) = NULL,   -- test name / code, bill no, patient
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    IF @OwnOnly = 1 SET @CreatedBy = @UserId;
    SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), '');
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    DECLARE @Days INT = DATEDIFF(DAY, @FromDate, @ToDate) + 1;
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @PrevFrom DATETIME = DATEADD(DAY, -@Days, @From);

    -- ── bills of the period and of the previous period of the same length ───────────────────────────────────
    SELECT lo.LabOrderId, lo.BillNo, lo.OrderDate, lo.PatientId, lo.CreatedBy,
           CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, lo.AgentType, lo.B2BAgentID,
           CAST(CASE WHEN lo.OrderDate >= @From THEN 1 ELSE 0 END AS BIT) AS InPeriod,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
           ph.PaymentHeaderId
    INTO #O
    FROM dbo.LabOrder lo
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.BranchId = @BranchId AND lo.IsActive = 1 AND lo.OrderDate >= @PrevFrom AND lo.OrderDate < @To
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0));

    -- ── bill lines: revenue per line = its share of the bill's net (the Owner MIS split) ───────────────────
    SELECT o.LabOrderId, o.InPeriod, o.IsB2B, li.LabOrderItemId,
           CASE WHEN li.[Type] = 'P' THEN 'Package' WHEN ISNULL(lim.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END AS Kind,
           CASE WHEN li.[Type] = 'P' THEN 'P-' ELSE 'T-' END + CAST(li.InvestigationId AS VARCHAR(20)) AS ItemKey,
           COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Code END, lim.Test_Code, '') AS TestCode,
           COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Name END, lim.Test_Name, 'Item ' + CAST(li.InvestigationId AS VARCHAR(20))) AS TestName,
           CASE WHEN li.[Type] = 'P' THEN NULL ELSE lim.Department_ID END AS DepartmentId,
           CASE WHEN li.[Type] = 'P' THEN 'Packages' ELSE ISNULL(dm.DeptName, 'Not set') END AS Department,
           CAST(li.Price AS DECIMAL(18, 2)) AS Mrp,
           CAST(CASE WHEN o.IsB2B = 1 THEN ISNULL(li.B2BRate, li.Price) ELSE COALESCE(pli.NetLineAmount, li.Price) END AS DECIMAL(18, 4)) AS Basis,
           o.NetAmount AS BillNet
    INTO #L
    FROM #O o
    INNER JOIN dbo.LabOrderItem li ON li.LabOrderId = o.LabOrderId AND li.IsActive = 1
    LEFT  JOIN dbo.LabInvestigationMaster lim ON li.[Type] <> 'P' AND lim.Test_ID = li.InvestigationId
    LEFT  JOIN dbo.LabInvestigationProfileHeader h ON li.[Type] = 'P' AND h.Profile_ID = li.InvestigationId
    LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    LEFT  JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = o.PaymentHeaderId AND pli.ModuleLineRefId = li.LabOrderItemId AND pli.IsActive = 1;

    ALTER TABLE #L ADD Revenue DECIMAL(18, 2), Discount DECIMAL(18, 2), PartnerMargin DECIMAL(18, 2);
    ;WITH s AS (SELECT LabOrderId, SUM(Basis) AS SumBasis FROM #L GROUP BY LabOrderId)
    UPDATE l SET Revenue = CAST(CASE WHEN s.SumBasis > 0 THEN l.Basis * l.BillNet / s.SumBasis ELSE 0 END AS DECIMAL(18, 2))
    FROM #L l INNER JOIN s ON s.LabOrderId = l.LabOrderId;
    UPDATE #L SET Discount = CASE WHEN IsB2B = 0 THEN Mrp - Revenue ELSE 0 END,
                  PartnerMargin = CASE WHEN IsB2B = 1 THEN Mrp - Revenue ELSE 0 END;

    -- the page's own filters apply to the lines (a bill keeps its other lines out of the totals)
    DELETE FROM #L
    WHERE (@Kind IS NOT NULL AND Kind <> @Kind)
       OR (@DepartmentId IS NOT NULL AND ISNULL(DepartmentId, -1) <> @DepartmentId);
    IF @Search IS NOT NULL
        DELETE l FROM #L l
        INNER JOIN #O o ON o.LabOrderId = l.LabOrderId
        LEFT  JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
        WHERE NOT (l.TestName LIKE '%' + @Search + '%' OR l.TestCode LIKE '%' + @Search + '%' OR o.BillNo LIKE '%' + @Search + '%'
                   OR p.PatientCode LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%');

    -- ── BOM cost of the period's lines (the Owner MIS 2252 method) ─────────────────────────────────────────────
    ALTER TABLE #L ADD TestId INT, IsPackage BIT NOT NULL DEFAULT 0, ActualCost DECIMAL(18, 2) NOT NULL DEFAULT 0,
                       PendingCost DECIMAL(18, 2) NOT NULL DEFAULT 0, Runs INT NOT NULL DEFAULT 0,
                       PendingTests INT NOT NULL DEFAULT 0, NoBomTests INT NOT NULL DEFAULT 0, OutsourcedTests INT NOT NULL DEFAULT 0;
    UPDATE l SET TestId = li.InvestigationId, IsPackage = CASE WHEN li.[Type] = 'P' THEN 1 ELSE 0 END
    FROM #L l INNER JOIN dbo.LabOrderItem li ON li.LabOrderItemId = l.LabOrderItemId;

    SELECT l.LabOrderItemId, l.LabOrderId, CASE WHEN l.IsPackage = 1 THEN pd.Test_ID ELSE l.TestId END AS UnitTestId,
           CASE WHEN l.IsPackage = 1 THEN l.TestId END AS PackageId
    INTO #LU
    FROM #L l
    LEFT JOIN dbo.LabInvestigationProfileDetail pd ON l.IsPackage = 1 AND pd.Profile_ID = l.TestId AND ISNULL(pd.IsDeleted, 0) = 0
    WHERE l.InPeriod = 1 AND (l.IsPackage = 0 OR pd.Test_ID IS NOT NULL);

    ALTER TABLE #LU ADD ActualCost DECIMAL(18, 2), Runs INT, NoBomRuns INT, Outsourced BIT, EstCost DECIMAL(18, 2);
    UPDATE u SET ActualCost = ISNULL(x.Cost, 0), Runs = ISNULL(x.Runs, 0), NoBomRuns = ISNULL(x.NoBom, 0),
                 Outsourced = CASE WHEN ISNULL(m.Is_Outsourced, 0) = 1
                                     OR EXISTS (SELECT 1 FROM dbo.SampleCollection sc
                                                LEFT JOIN dbo.LabInvestigationProfileHeader ph ON ph.Profile_ID = sc.ProfileId
                                                WHERE sc.Laborderid = u.LabOrderId AND ISNULL(sc.IsoutSource, 0) = 1
                                                  AND (sc.InvestigationID = u.UnitTestId OR ph.Test_ID = u.UnitTestId)) THEN 1 ELSE 0 END,
                 EstCost = dbo.ufn_Qc_TestMaterialCost(u.UnitTestId, NULL)
    FROM #LU u
    LEFT JOIN dbo.LabInvestigationMaster m ON m.Test_ID = u.UnitTestId
    OUTER APPLY (SELECT SUM(c.MaterialCost) AS Cost, COUNT(1) AS Runs, SUM(CASE WHEN c.Status = 'NO_BOM' THEN 1 ELSE 0 END) AS NoBom
                 FROM dbo.QcConsumption c
                 WHERE c.LabOrderId = u.LabOrderId AND c.TestId = u.UnitTestId AND ISNULL(c.PackageId, 0) = ISNULL(u.PackageId, 0)) x;

    UPDATE l SET ActualCost = x.ActualCost, PendingCost = x.PendingCost, Runs = x.Runs,
                 PendingTests = x.PendingTests, NoBomTests = x.NoBomTests, OutsourcedTests = x.OutsourcedTests
    FROM #L l
    INNER JOIN (SELECT LabOrderItemId, SUM(ActualCost) AS ActualCost,
                       SUM(CASE WHEN Runs = 0 AND Outsourced = 0 THEN ISNULL(EstCost, 0) ELSE 0 END) AS PendingCost,
                       SUM(Runs) AS Runs,
                       SUM(CASE WHEN Runs = 0 AND Outsourced = 0 AND EstCost IS NOT NULL THEN 1 ELSE 0 END) AS PendingTests,
                       SUM(CASE WHEN Outsourced = 0 AND ((Runs > 0 AND NoBomRuns = Runs) OR (Runs = 0 AND EstCost IS NULL)) THEN 1 ELSE 0 END) AS NoBomTests,
                       SUM(CASE WHEN Outsourced = 1 THEN 1 ELSE 0 END) AS OutsourcedTests
                FROM #LU GROUP BY LabOrderItemId) x ON x.LabOrderItemId = l.LabOrderItemId;

    -- ── one line per test / profile / package: this period, the previous one, ranks ────────────────────────
    SELECT ItemKey, MAX(Kind) AS Kind, MAX(TestCode) AS TestCode, MAX(TestName) AS TestName, MAX(Department) AS Department,
           SUM(CASE WHEN InPeriod = 1 THEN 1 ELSE 0 END) AS Tests,
           COUNT(DISTINCT CASE WHEN InPeriod = 1 THEN LabOrderId END) AS Bills,
           SUM(CASE WHEN InPeriod = 1 THEN Mrp ELSE 0 END) AS Mrp,
           SUM(CASE WHEN InPeriod = 1 THEN Discount ELSE 0 END) AS Discount,
           SUM(CASE WHEN InPeriod = 1 THEN PartnerMargin ELSE 0 END) AS PartnerMargin,
           SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END) AS Revenue,
           SUM(CASE WHEN InPeriod = 1 AND IsB2B = 0 THEN Revenue ELSE 0 END) AS B2CRevenue,
           SUM(CASE WHEN InPeriod = 1 AND IsB2B = 1 THEN Revenue ELSE 0 END) AS B2BRevenue,
           SUM(CASE WHEN InPeriod = 0 THEN 1 ELSE 0 END) AS PrevTests,
           SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END) AS PrevRevenue,
           SUM(CASE WHEN InPeriod = 1 THEN ActualCost + PendingCost ELSE 0 END) AS MaterialCost,
           SUM(CASE WHEN InPeriod = 1 THEN PendingCost ELSE 0 END) AS PendingCost,
           SUM(CASE WHEN InPeriod = 1 THEN NoBomTests ELSE 0 END) AS NoBomTests
    INTO #T FROM #L GROUP BY ItemKey;

    ALTER TABLE #T ADD RankRevenue INT, RankCount INT;
    ;WITH r AS (SELECT ItemKey,
                       ROW_NUMBER() OVER (ORDER BY Revenue DESC, Tests DESC, TestName) AS rr,
                       ROW_NUMBER() OVER (ORDER BY Tests DESC, Revenue DESC, TestName) AS rc
                FROM #T WHERE Tests > 0)
    UPDATE t SET RankRevenue = r.rr, RankCount = r.rc FROM #T t INNER JOIN r ON r.ItemKey = t.ItemKey;

    DECLARE @Rev DECIMAL(18, 2) = (SELECT ISNULL(SUM(Revenue), 0) FROM #L WHERE InPeriod = 1);
    DECLARE @PrevRev DECIMAL(18, 2) = (SELECT ISNULL(SUM(Revenue), 0) FROM #L WHERE InPeriod = 0);
    DECLARE @Lines INT = (SELECT COUNT(1) FROM #L WHERE InPeriod = 1);
    DECLARE @PrevLines INT = (SELECT COUNT(1) FROM #L WHERE InPeriod = 0);

    -- RS1 summary
    SELECT @Rev AS Revenue, @Lines AS Tests,
           (SELECT COUNT(DISTINCT LabOrderId) FROM #L WHERE InPeriod = 1) AS Bills,
           (SELECT COUNT(1) FROM #T WHERE Tests > 0) AS DistinctItems,
           (SELECT ISNULL(SUM(Mrp), 0) FROM #L WHERE InPeriod = 1) AS Mrp,
           (SELECT ISNULL(SUM(Discount), 0) FROM #L WHERE InPeriod = 1) AS Discount,
           (SELECT ISNULL(SUM(PartnerMargin), 0) FROM #L WHERE InPeriod = 1) AS PartnerMargin,
           (SELECT ISNULL(SUM(Revenue), 0) FROM #L WHERE InPeriod = 1 AND Kind = 'Test') AS TestRevenue,
           (SELECT ISNULL(SUM(Revenue), 0) FROM #L WHERE InPeriod = 1 AND Kind = 'Profile') AS ProfileRevenue,
           (SELECT ISNULL(SUM(Revenue), 0) FROM #L WHERE InPeriod = 1 AND Kind = 'Package') AS PackageRevenue,
           (SELECT COUNT(1) FROM #L WHERE InPeriod = 1 AND Kind = 'Test') AS TestCount,
           (SELECT COUNT(1) FROM #L WHERE InPeriod = 1 AND Kind = 'Profile') AS ProfileCount,
           (SELECT COUNT(1) FROM #L WHERE InPeriod = 1 AND Kind = 'Package') AS PackageCount,
           @PrevRev AS PrevRevenue, @PrevLines AS PrevTests,
           CAST(CASE WHEN @PrevRev > 0 THEN (@Rev - @PrevRev) * 100.0 / @PrevRev END AS DECIMAL(10, 1)) AS RevenueGrowthPct,
           CAST(CASE WHEN @PrevLines > 0 THEN (@Lines - @PrevLines) * 100.0 / @PrevLines END AS DECIMAL(10, 1)) AS TestsGrowthPct,
           CONVERT(VARCHAR(10), CAST(@PrevFrom AS DATE), 23) AS PrevFrom, CONVERT(VARCHAR(10), DATEADD(DAY, -1, @FromDate), 23) AS PrevTo,
           (SELECT TestName FROM #T WHERE RankRevenue = 1) AS TopByRevenue,
           (SELECT Revenue FROM #T WHERE RankRevenue = 1) AS TopByRevenueAmount,
           (SELECT TestName FROM #T WHERE RankCount = 1) AS TopByCount,
           (SELECT Tests FROM #T WHERE RankCount = 1) AS TopByCountTests,
           (SELECT TOP 1 Department FROM #L WHERE InPeriod = 1 GROUP BY Department ORDER BY SUM(Revenue) DESC, Department) AS TopDepartment,
           CAST((SELECT TOP 1 SUM(Revenue) FROM #L WHERE InPeriod = 1 GROUP BY Department ORDER BY SUM(Revenue) DESC) * 100.0 / NULLIF(@Rev, 0) AS DECIMAL(10, 1)) AS TopDepartmentSharePct,
           (SELECT ISNULL(SUM(Revenue), 0) FROM #T WHERE RankRevenue <= 20) AS Top20Revenue,
           (SELECT ISNULL(SUM(ActualCost + PendingCost), 0) FROM #L WHERE InPeriod = 1) AS MaterialCost,
           (SELECT ISNULL(SUM(ActualCost), 0) FROM #L WHERE InPeriod = 1) AS MaterialActual,
           (SELECT ISNULL(SUM(PendingCost), 0) FROM #L WHERE InPeriod = 1) AS MaterialPending,
           @Rev - (SELECT ISNULL(SUM(ActualCost + PendingCost), 0) FROM #L WHERE InPeriod = 1) AS Profit,
           CAST(CASE WHEN @Rev > 0 THEN (@Rev - (SELECT ISNULL(SUM(ActualCost + PendingCost), 0) FROM #L WHERE InPeriod = 1)) * 100.0 / @Rev END AS DECIMAL(10, 1)) AS MarginPct,
           (SELECT ISNULL(SUM(NoBomTests), 0) FROM #L WHERE InPeriod = 1) AS NoBomTests,
           (SELECT ISNULL(SUM(PendingTests), 0) FROM #L WHERE InPeriod = 1) AS PendingTests,
           (SELECT ISNULL(SUM(OutsourcedTests), 0) FROM #L WHERE InPeriod = 1) AS OutsourcedTests,
           (SELECT TOP 1 TestName FROM #T WHERE Tests > 0 AND MaterialCost > 0 ORDER BY Revenue - MaterialCost DESC, TestName) AS TopByProfit,
           (SELECT TOP 1 Revenue - MaterialCost FROM #T WHERE Tests > 0 AND MaterialCost > 0 ORDER BY Revenue - MaterialCost DESC, TestName) AS TopByProfitAmount;

    -- RS2 groups (SortOrder = rank by revenue, so the Summary opens on the best sellers)
    SELECT 'byTest' AS GroupKey, ItemKey AS GroupId, TestName AS GroupName, RankRevenue AS SortOrder,
           Kind + CASE WHEN Kind = 'Package' THEN '' ELSE ' · ' + Department END + CASE WHEN TestCode <> '' THEN ' · ' + TestCode ELSE '' END AS Detail,
           Tests, Bills, Mrp, Discount, PartnerMargin, Revenue, B2CRevenue, B2BRevenue,
           CAST(CASE WHEN Tests > 0 THEN Revenue / Tests END AS DECIMAL(18, 2)) AS AvgRevenue,
           PrevTests, PrevRevenue,
           CAST(CASE WHEN PrevRevenue > 0 THEN (Revenue - PrevRevenue) * 100.0 / PrevRevenue END AS DECIMAL(10, 1)) AS GrowthPct,
           RankRevenue, RankCount,
           MaterialCost, Revenue - MaterialCost AS Profit,
           CAST(CASE WHEN Revenue > 0 THEN (Revenue - MaterialCost) * 100.0 / Revenue END AS DECIMAL(10, 1)) AS MarginPct,
           PendingCost, NoBomTests
    FROM #T WHERE Tests > 0
    UNION ALL
    SELECT 'byKind', Kind, Kind, CASE Kind WHEN 'Test' THEN 1 WHEN 'Profile' THEN 2 ELSE 3 END, NULL,
           SUM(CASE WHEN InPeriod = 1 THEN 1 ELSE 0 END), COUNT(DISTINCT CASE WHEN InPeriod = 1 THEN LabOrderId END),
           SUM(CASE WHEN InPeriod = 1 THEN Mrp ELSE 0 END), SUM(CASE WHEN InPeriod = 1 THEN Discount ELSE 0 END),
           SUM(CASE WHEN InPeriod = 1 THEN PartnerMargin ELSE 0 END), SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END),
           SUM(CASE WHEN InPeriod = 1 AND IsB2B = 0 THEN Revenue ELSE 0 END), SUM(CASE WHEN InPeriod = 1 AND IsB2B = 1 THEN Revenue ELSE 0 END),
           CAST(SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END) / NULLIF(SUM(CASE WHEN InPeriod = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(18, 2)),
           SUM(CASE WHEN InPeriod = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END),
           CAST(CASE WHEN SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END) > 0
                     THEN (SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END) - SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END)) * 100.0
                          / SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END) END AS DECIMAL(10, 1)),
NULL, NULL,
           SUM(CASE WHEN InPeriod = 1 THEN ActualCost + PendingCost ELSE 0 END),
           SUM(CASE WHEN InPeriod = 1 THEN Revenue - ActualCost - PendingCost ELSE 0 END),
           CAST(SUM(CASE WHEN InPeriod = 1 THEN Revenue - ActualCost - PendingCost ELSE 0 END) * 100.0
                / NULLIF(SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END), 0) AS DECIMAL(10, 1)),
           SUM(CASE WHEN InPeriod = 1 THEN PendingCost ELSE 0 END), SUM(CASE WHEN InPeriod = 1 THEN NoBomTests ELSE 0 END)
    FROM #L GROUP BY Kind HAVING SUM(CASE WHEN InPeriod = 1 THEN 1 ELSE 0 END) > 0
    UNION ALL
    SELECT 'byDepartment', Department, Department, 0, NULL,
           SUM(CASE WHEN InPeriod = 1 THEN 1 ELSE 0 END), COUNT(DISTINCT CASE WHEN InPeriod = 1 THEN LabOrderId END),
           SUM(CASE WHEN InPeriod = 1 THEN Mrp ELSE 0 END), SUM(CASE WHEN InPeriod = 1 THEN Discount ELSE 0 END),
           SUM(CASE WHEN InPeriod = 1 THEN PartnerMargin ELSE 0 END), SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END),
           SUM(CASE WHEN InPeriod = 1 AND IsB2B = 0 THEN Revenue ELSE 0 END), SUM(CASE WHEN InPeriod = 1 AND IsB2B = 1 THEN Revenue ELSE 0 END),
           CAST(SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END) / NULLIF(SUM(CASE WHEN InPeriod = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(18, 2)),
           SUM(CASE WHEN InPeriod = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END),
           CAST(CASE WHEN SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END) > 0
                     THEN (SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END) - SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END)) * 100.0
                          / SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END) END AS DECIMAL(10, 1)),
NULL, NULL,
           SUM(CASE WHEN InPeriod = 1 THEN ActualCost + PendingCost ELSE 0 END),
           SUM(CASE WHEN InPeriod = 1 THEN Revenue - ActualCost - PendingCost ELSE 0 END),
           CAST(SUM(CASE WHEN InPeriod = 1 THEN Revenue - ActualCost - PendingCost ELSE 0 END) * 100.0
                / NULLIF(SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END), 0) AS DECIMAL(10, 1)),
           SUM(CASE WHEN InPeriod = 1 THEN PendingCost ELSE 0 END), SUM(CASE WHEN InPeriod = 1 THEN NoBomTests ELSE 0 END)
    FROM #L GROUP BY Department HAVING SUM(CASE WHEN InPeriod = 1 THEN 1 ELSE 0 END) > 0
    UNION ALL
    SELECT 'byBillingType', CASE WHEN IsB2B = 1 THEN 'B2B' ELSE 'B2C' END, CASE WHEN IsB2B = 1 THEN 'B2B' ELSE 'B2C' END, CAST(IsB2B AS INT), NULL,
           SUM(CASE WHEN InPeriod = 1 THEN 1 ELSE 0 END), COUNT(DISTINCT CASE WHEN InPeriod = 1 THEN LabOrderId END),
           SUM(CASE WHEN InPeriod = 1 THEN Mrp ELSE 0 END), SUM(CASE WHEN InPeriod = 1 THEN Discount ELSE 0 END),
           SUM(CASE WHEN InPeriod = 1 THEN PartnerMargin ELSE 0 END), SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END),
           SUM(CASE WHEN InPeriod = 1 AND IsB2B = 0 THEN Revenue ELSE 0 END), SUM(CASE WHEN InPeriod = 1 AND IsB2B = 1 THEN Revenue ELSE 0 END),
           CAST(SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END) / NULLIF(SUM(CASE WHEN InPeriod = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(18, 2)),
           SUM(CASE WHEN InPeriod = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END),
           CAST(CASE WHEN SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END) > 0
                     THEN (SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END) - SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END)) * 100.0
                          / SUM(CASE WHEN InPeriod = 0 THEN Revenue ELSE 0 END) END AS DECIMAL(10, 1)),
NULL, NULL,
           SUM(CASE WHEN InPeriod = 1 THEN ActualCost + PendingCost ELSE 0 END),
           SUM(CASE WHEN InPeriod = 1 THEN Revenue - ActualCost - PendingCost ELSE 0 END),
           CAST(SUM(CASE WHEN InPeriod = 1 THEN Revenue - ActualCost - PendingCost ELSE 0 END) * 100.0
                / NULLIF(SUM(CASE WHEN InPeriod = 1 THEN Revenue ELSE 0 END), 0) AS DECIMAL(10, 1)),
           SUM(CASE WHEN InPeriod = 1 THEN PendingCost ELSE 0 END), SUM(CASE WHEN InPeriod = 1 THEN NoBomTests ELSE 0 END)
    FROM #L GROUP BY IsB2B HAVING SUM(CASE WHEN InPeriod = 1 THEN 1 ELSE 0 END) > 0
    ORDER BY GroupKey, SortOrder, Revenue DESC, GroupName;

    -- RS3 rows: one per bill line of the period (the bills containing each test), latest first
    SELECT l.LabOrderItemId, l.LabOrderId, o.BillNo, o.OrderDate AS BillDate, l.ItemKey, l.Kind, l.TestCode, l.TestName, l.Department,
           CASE WHEN l.IsB2B = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
           CASE WHEN o.AgentType = 'F' THEN f.Franchise_Name WHEN o.AgentType = 'C' THEN c.Corporate_Name END AS PartnerName,
           p.PatientCode, LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           l.Mrp, l.Discount, l.PartnerMargin, l.Revenue,
           l.ActualCost + l.PendingCost AS MaterialCost, l.Revenue - l.ActualCost - l.PendingCost AS Profit,
           CASE WHEN l.OutsourcedTests > 0 AND l.ActualCost + l.PendingCost = 0 THEN 'Outsourced'
                WHEN l.NoBomTests > 0 AND l.ActualCost + l.PendingCost = 0 THEN 'No BOM'
                WHEN l.PendingCost > 0 AND l.ActualCost = 0 THEN 'Estimate (not run yet)'
                WHEN l.PendingCost > 0 THEN 'Actual + estimate'
                WHEN l.Runs > 0 THEN 'Actual'
                ELSE 'No BOM' END AS CostBasis,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS BilledBy
    FROM #L l
    INNER JOIN #O o ON o.LabOrderId = l.LabOrderId
    LEFT  JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
    LEFT  JOIN dbo.LabFranchiseMaster f ON o.AgentType = 'F' AND f.Franchise_ID = o.B2BAgentID
    LEFT  JOIN dbo.CorporateMaster c ON o.AgentType = 'C' AND c.Corporate_ID = o.B2BAgentID
    LEFT  JOIN dbo.Users u ON u.Id = o.CreatedBy
    WHERE l.InPeriod = 1
    ORDER BY o.OrderDate DESC, o.LabOrderId DESC, l.LabOrderItemId;

    -- RS4 filter options: LAB departments, and who created bills of the branch in the period
    SELECT 'departmentId' AS FilterKey, CAST(d.DeptId AS VARCHAR(20)) AS Value, d.DeptName AS Text
    FROM dbo.DepartmentMaster d
    WHERE ISNULL(d.IsActive, 1) = 1 AND EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster m WHERE m.Department_ID = d.DeptId)
    UNION ALL
    SELECT DISTINCT 'createdBy', CAST(u.Id AS VARCHAR(20)), ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)
    FROM dbo.LabOrder lo INNER JOIN dbo.Users u ON u.Id = lo.CreatedBy
    WHERE lo.BranchId = @BranchId AND lo.OrderDate >= @From AND lo.OrderDate < @To
    ORDER BY FilterKey, Text;

    DROP TABLE #O; DROP TABLE #L; DROP TABLE #T; DROP TABLE #LU;
END;
GO

-- ── menu page and endpoints (database navigation, Reports > LAB, before LR-24 at 210) ──────────────────────
DECLARE @co INT, @menu INT, @page INT, @view INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'REPORTS.LABTESTREVENUE',
             @Title = N'Test & Department Volume and Revenue', @Controller = N'Reports', @Action = N'LabTestRevenue',
             @Show_In_Menu = 1, @Sort_Order = 205, @Icon = N'bi bi-bar-chart-steps me-2',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        SET @view = NULL;
        SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'LabTestRevenue', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'GetLabReportData', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2267 applied: Reports > LAB > LR-23 Test & Department Volume and Revenue (with BOM cost and gross profit).';
GO
