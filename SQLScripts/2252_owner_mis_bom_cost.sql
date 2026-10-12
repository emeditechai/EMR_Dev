-- ============================================================================
-- Migration: 2250_owner_mis_bom_cost.sql
-- Description: Reports > LAB > Owner MIS & Test Revenue (LF-18) now shows cost and gross profit from BOM consumption
--   (SQLScripts/2247-2249). Everything that was there is unchanged; added:
--   * cost of the tests billed in the period, matched to their revenue: the actual consumption runs recorded for each
--     line on its bill (re-runs included, at each run's frozen cost, wherever the test was run), plus an estimate at the
--     current BOM cost for in-house tests not run yet; a package is its member tests; outsourced tests carry no BOM cost;
--   * collection kits, estimated per bill (one kit per sample type collected in-house; kit consumption is not recorded yet);
--   * summary: material actual / not run yet, kits, runs, re-runs, tests without BOM, consumption of the period (to tie
--     out with the BOM Consumption Register); by test and by department: material cost and gross profit; by doctor,
--     B2B partner and branch: cost (material + kits) and gross profit; new section 11 "items": items consumed.
--   Requires 2249 (QcConsumption). Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_OwnerMis
    @BranchId     INT,
    @FromDate     DATE,
    @ToDate       DATE,
    @AllBranches  BIT = 0,
    @UserId       INT = NULL,
    @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @sw DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @sw; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @Days INT = DATEDIFF(DAY, @FromDate, @ToDate) + 1;
    DECLARE @PrevFrom DATETIME = DATEADD(DAY, -@Days, @From), @PrevTo DATETIME = @From;
    DECLARE @ByMonth BIT = CASE WHEN @Days > 62 THEN 1 ELSE 0 END;

    -- ── branches in scope ────────────────────────────────────────────────────
    DECLARE @Br TABLE (BranchId INT PRIMARY KEY, BranchName NVARCHAR(200));
    IF ISNULL(@AllBranches, 0) = 1
        INSERT INTO @Br
        SELECT b.BranchID, b.BranchName
        FROM dbo.Branchmaster b
        WHERE b.IsActive = 1
          AND b.CompanyId = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId)
          AND (ISNULL(@IsSuperAdmin, 0) = 1
               OR EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = @UserId AND ub.BranchID = b.BranchID AND ISNULL(ub.IsActive, 1) = 1));
    ELSE
        INSERT INTO @Br SELECT BranchID, BranchName FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    -- ── bills of the period (and of the previous period, for growth) ─────────
    SELECT lo.LabOrderId, lo.BranchId, lo.OrderDate, lo.PatientId,
           CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, lo.AgentType, lo.B2BAgentID, lo.RefDoctorId, lo.ReferralDoctorId,
           CAST(lo.IsActive AS BIT) AS IsActive,
           CAST(CASE WHEN lo.OrderDate >= @From THEN 1 ELSE 0 END AS BIT) AS InPeriod,
           CAST(lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0) AS DECIMAL(18, 2)) AS GrossAmount /* 2240: + misc charges with GST */,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
           CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
           ph.PaymentHeaderId
    INTO #O
    FROM dbo.LabOrder lo
    INNER JOIN @Br br ON br.BranchId = lo.BranchId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.OrderDate >= @PrevFrom AND lo.OrderDate < @To;

    ALTER TABLE #O ADD DueAmount DECIMAL(18, 2);
    UPDATE #O SET DueAmount = CASE WHEN IsActive = 0 OR NetAmount - PaidAmount < 0 THEN 0 ELSE NetAmount - PaidAmount END;

    -- ── bill lines of the period: revenue per test (lines of a bill add up to the bill's net) ──
    SELECT o.LabOrderId, o.BranchId, o.IsB2B, li.LabOrderItemId,
           CASE WHEN li.[Type] = 'P' THEN 'Package' WHEN ISNULL(lim.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END AS Kind,
           COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Code END, lim.Test_Code, '') AS TestCode,
           COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Name END, lim.Test_Name, 'Item ' + CAST(li.InvestigationId AS VARCHAR(20))) AS TestName,
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
    LEFT  JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = o.PaymentHeaderId AND pli.ModuleLineRefId = li.LabOrderItemId AND pli.IsActive = 1
    WHERE o.InPeriod = 1 AND o.IsActive = 1;

    ALTER TABLE #L ADD NetLine DECIMAL(18, 2), Discount DECIMAL(18, 2), PartnerMargin DECIMAL(18, 2);
    ;WITH s AS (SELECT LabOrderId, SUM(Basis) AS SumBasis FROM #L GROUP BY LabOrderId)
    UPDATE l SET NetLine = CAST(CASE WHEN s.SumBasis > 0 THEN l.Basis * l.BillNet / s.SumBasis ELSE 0 END AS DECIMAL(18, 2))
    FROM #L l INNER JOIN s ON s.LabOrderId = l.LabOrderId;
    UPDATE #L SET Discount = CASE WHEN IsB2B = 0 THEN Mrp - NetLine ELSE 0 END,
                  PartnerMargin = CASE WHEN IsB2B = 1 THEN Mrp - NetLine ELSE 0 END;

    -- ── 2252: cost of the tests billed in the period (BOM consumption, SQLScripts/2249) ──
    -- actual    = the consumption runs recorded for the line on its own bill (re-runs included, at the cost of each run),
    --             wherever and whenever the test was run (cost follows the bill, as revenue does);
    -- estimated = an in-house test billed but not run yet, at its current BOM cost (shown apart as "not run yet").
    -- A package line is its member tests / profile tests; an outsourced test has no BOM cost.
    ALTER TABLE #L ADD TestId INT, IsPackage BIT NOT NULL DEFAULT 0, ActualCost DECIMAL(18, 2) NOT NULL DEFAULT 0,
                       PendingCost DECIMAL(18, 2) NOT NULL DEFAULT 0, Runs INT NOT NULL DEFAULT 0, Reruns INT NOT NULL DEFAULT 0,
                       PendingTests INT NOT NULL DEFAULT 0, NoBomTests INT NOT NULL DEFAULT 0;
    UPDATE l SET TestId = li.InvestigationId, IsPackage = CASE WHEN li.[Type] = 'P' THEN 1 ELSE 0 END
    FROM #L l INNER JOIN dbo.LabOrderItem li ON li.LabOrderItemId = l.LabOrderItemId;

    SELECT l.LabOrderItemId, l.LabOrderId, CASE WHEN l.IsPackage = 1 THEN pd.Test_ID ELSE l.TestId END AS UnitTestId,
           CASE WHEN l.IsPackage = 1 THEN l.TestId END AS PackageId
    INTO #LU
    FROM #L l
    LEFT JOIN dbo.LabInvestigationProfileDetail pd ON l.IsPackage = 1 AND pd.Profile_ID = l.TestId AND ISNULL(pd.IsDeleted, 0) = 0
    WHERE l.IsPackage = 0 OR pd.Test_ID IS NOT NULL;

    ALTER TABLE #LU ADD ActualCost DECIMAL(18, 2), Runs INT, Reruns INT, NoBomRuns INT, Outsourced BIT, EstCost DECIMAL(18, 2);
    UPDATE u SET ActualCost = ISNULL(x.Cost, 0), Runs = ISNULL(x.Runs, 0), Reruns = ISNULL(x.Reruns, 0), NoBomRuns = ISNULL(x.NoBom, 0),
                 Outsourced = CASE WHEN ISNULL(m.Is_Outsourced, 0) = 1
                                     OR EXISTS (SELECT 1 FROM dbo.SampleCollection sc
                                                LEFT JOIN dbo.LabInvestigationProfileHeader ph ON ph.Profile_ID = sc.ProfileId
                                                WHERE sc.Laborderid = u.LabOrderId AND ISNULL(sc.IsoutSource, 0) = 1
                                                  AND (sc.InvestigationID = u.UnitTestId OR ph.Test_ID = u.UnitTestId)) THEN 1 ELSE 0 END,
                 EstCost = dbo.ufn_Qc_TestMaterialCost(u.UnitTestId, NULL)
    FROM #LU u
    LEFT JOIN dbo.LabInvestigationMaster m ON m.Test_ID = u.UnitTestId
    OUTER APPLY (SELECT SUM(c.MaterialCost) AS Cost, COUNT(1) AS Runs, SUM(CASE WHEN c.RunNo > 1 THEN 1 ELSE 0 END) AS Reruns,
                        SUM(CASE WHEN c.Status = 'NO_BOM' THEN 1 ELSE 0 END) AS NoBom
                 FROM dbo.QcConsumption c
                 WHERE c.LabOrderId = u.LabOrderId AND c.TestId = u.UnitTestId AND ISNULL(c.PackageId, 0) = ISNULL(u.PackageId, 0)) x;

    UPDATE l SET ActualCost = x.ActualCost, PendingCost = x.PendingCost, Runs = x.Runs, Reruns = x.Reruns,
                 PendingTests = x.PendingTests, NoBomTests = x.NoBomTests
    FROM #L l
    INNER JOIN (SELECT LabOrderItemId, SUM(ActualCost) AS ActualCost,
                       SUM(CASE WHEN Runs = 0 AND Outsourced = 0 THEN ISNULL(EstCost, 0) ELSE 0 END) AS PendingCost,
                       SUM(Runs) AS Runs, SUM(Reruns) AS Reruns,
                       SUM(CASE WHEN Runs = 0 AND Outsourced = 0 AND EstCost IS NOT NULL THEN 1 ELSE 0 END) AS PendingTests,
                       SUM(CASE WHEN Outsourced = 0 AND ((Runs > 0 AND NoBomRuns = Runs) OR (Runs = 0 AND EstCost IS NULL)) THEN 1 ELSE 0 END) AS NoBomTests
                FROM #LU GROUP BY LabOrderItemId) x ON x.LabOrderItemId = l.LabOrderItemId;

    -- per bill: tests, MRP and partner margin of its lines (for the doctor and partner tables)
    ALTER TABLE #O ADD Tests INT NOT NULL DEFAULT 0, LineMrp DECIMAL(18, 2) NOT NULL DEFAULT 0, LineMargin DECIMAL(18, 2) NOT NULL DEFAULT 0;
    UPDATE o SET Tests = x.Tests, LineMrp = x.Mrp, LineMargin = x.Margin
    FROM #O o INNER JOIN (SELECT LabOrderId, COUNT(1) AS Tests, SUM(Mrp) AS Mrp, SUM(PartnerMargin) AS Margin FROM #L GROUP BY LabOrderId) x
         ON x.LabOrderId = o.LabOrderId;

    -- 2252: cost per bill = BOM material of its lines + collection kits (estimated: one kit per sample type collected in-house)
    ALTER TABLE #O ADD MaterialCost DECIMAL(18, 2) NOT NULL DEFAULT 0, KitCost DECIMAL(18, 2) NOT NULL DEFAULT 0;
    UPDATE o SET MaterialCost = ISNULL((SELECT SUM(l.ActualCost + l.PendingCost) FROM #L l WHERE l.LabOrderId = o.LabOrderId), 0),
                 KitCost = ISNULL((SELECT SUM(ISNULL(dbo.ufn_Qc_SampleKitCost(s.SampleTypeId), 0))
                                   FROM (SELECT DISTINCT m.Sample_Type_ID AS SampleTypeId
                                         FROM dbo.SampleCollection sc
                                         INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = sc.InvestigationID
                                         WHERE sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0
                                           AND ISNULL(sc.IsoutSource, 0) = 0 AND m.Sample_Type_ID IS NOT NULL) s), 0)
    FROM #O o WHERE o.InPeriod = 1 AND o.IsActive = 1;

    -- ── tests approved in the period: lab TAT (received at lab -> approval) against the TAT hours (dbo.ufn_LabReport_TatUnits) ──
    SELECT ISNULL(dm.DeptName, 'Not set') AS Department, t.LabHours AS Hours,
           CAST(CASE WHEN t.TatStatus IN ('ONTIME', 'BREACH') THEN 1 ELSE 0 END AS BIT) AS HasTarget,
           CAST(CASE WHEN t.TatStatus = 'ONTIME' THEN 1 ELSE 0 END AS BIT) AS Within
    INTO #T
    FROM dbo.ufn_LabReport_TatUnits(@From, @To) t
    INNER JOIN @Br br ON br.BranchId = t.HolderBranchId
    LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = t.DepartmentId;

    -- ── quality: specimens collected / rejected / sent for re-collection (as LR-11), retests ──
    SELECT l.ToStatusId, l.RejectionReasonId, l.RejectionReason,
           COALESCE(l.BarcodeNo, CASE WHEN l.ProfileId IS NOT NULL THEN CONCAT('P', l.LabOrderId, '-', l.ProfileId) ELSE CONCAT('S', l.SampleCollectionId) END) AS SpecimenKey
    INTO #Q
    FROM dbo.LabSampleStatusLog l
    INNER JOIN @Br br ON br.BranchId = l.BranchId
    WHERE l.ToStatusId IN (2, 3, 4) AND l.ChangedOn >= @From AND l.ChangedOn < @To;

    DECLARE @Specimens INT = (SELECT COUNT(DISTINCT SpecimenKey) FROM #Q WHERE ToStatusId = 2);
    DECLARE @Rejected INT = (SELECT COUNT(DISTINCT SpecimenKey) FROM #Q WHERE ToStatusId = 4);
    DECLARE @Recollect INT = (SELECT COUNT(DISTINCT SpecimenKey) FROM #Q WHERE ToStatusId = 3);
    DECLARE @Retests INT = (SELECT COUNT(1) FROM dbo.LabReportUnapproval u
                            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = u.LabOrderId
                            INNER JOIN @Br br ON br.BranchId = lo.BranchId
                            WHERE u.Action = 'RETEST' AND u.UnapprovedDate >= @From AND u.UnapprovedDate < @To);

    -- ── money received in the period (receipt date); wallet deductions are shown apart (paid earlier as top-ups) ──
    SELECT pd.PaidAmount, ISNULL(pm.MethodName, 'Unknown') AS Mode,
           CAST(CASE WHEN ISNULL(pd.TransactionRef, '') LIKE 'WALLET-DEBIT-%' THEN 1 ELSE 0 END AS BIT) AS FromWallet,
           CAST(CASE WHEN COALESCE(pd.PaymentDate, pd.CreatedDate) >= @From THEN 1 ELSE 0 END AS BIT) AS InPeriod,
           ph.BranchId, COALESCE(pd.PaymentDate, pd.CreatedDate) AS PaidOn
    INTO #P
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'LAB' AND ph.IsActive = 1
    INNER JOIN @Br br ON br.BranchId = ph.BranchId
    LEFT  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE pd.IsActive = 1 AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @PrevFrom AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @To;

    DECLARE @Refunds DECIMAL(18, 2) = (SELECT ISNULL(SUM(r.RefundAmount), 0) FROM dbo.BillRefund r
                                       INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = r.ModuleRefId
                                       INNER JOIN @Br br ON br.BranchId = lo.BranchId
                                       WHERE r.ModuleCode = 'LAB' AND r.IsActive = 1 AND ISNULL(r.Status, 'P') = 'P'
                                         AND r.RefundDate >= @From AND r.RefundDate < @To);

    DECLARE @CancelledAmount DECIMAL(18, 2) = (SELECT ISNULL(SUM(bc.CancelledAmount), 0) FROM dbo.BillCancellation bc
                                               INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bc.ModuleRefId
                                               INNER JOIN @Br br ON br.BranchId = lo.BranchId
                                               WHERE bc.ModuleCode = 'LAB' AND bc.IsActive = 1 AND bc.CancellationDate >= @From AND bc.CancellationDate < @To);

    -- ── outstanding today (all open bills of the branches), for ageing ───────
    SELECT CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, DATEDIFF(DAY, lo.OrderDate, GETDATE()) AS AgeDays,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END
                - ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS Due
    INTO #D
    FROM dbo.LabOrder lo
    INNER JOIN @Br br ON br.BranchId = lo.BranchId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.IsActive = 1;
    DELETE FROM #D WHERE Due <= 0;

    -- RS1 summary
    SELECT
        (SELECT COUNT(1) FROM @Br) AS BranchCount,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN 1 ELSE 0 END) AS BillCount,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 0 THEN 1 ELSE 0 END) AS B2CBills,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 1 THEN 1 ELSE 0 END) AS B2BBills,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 0 THEN 1 ELSE 0 END) AS CancelledBills,
        @CancelledAmount AS CancelledAmount,
        COUNT(DISTINCT CASE WHEN InPeriod = 1 AND IsActive = 1 THEN PatientId END) AS PatientCount,
        (SELECT COUNT(1) FROM #L) AS TestCount,
        (SELECT ISNULL(SUM(Mrp), 0) FROM #L) AS GrossAmount,
        (SELECT ISNULL(SUM(Discount), 0) FROM #L) AS DiscountAmount,
        (SELECT ISNULL(SUM(PartnerMargin), 0) FROM #L) AS PartnerMargin,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN NetAmount END), 0) AS NetRevenue,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 0 THEN NetAmount END), 0) AS B2CRevenue,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 1 THEN NetAmount END), 0) AS B2BRevenue,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN PaidAmount END), 0) AS CollectedOnPeriodBills,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN DueAmount END), 0) AS PeriodBillsDue,
        (SELECT ISNULL(SUM(PaidAmount), 0) FROM #P WHERE InPeriod = 1 AND FromWallet = 0) AS Collected,
        (SELECT ISNULL(SUM(PaidAmount), 0) FROM #P WHERE InPeriod = 1 AND FromWallet = 1) AS PaidFromWallet,
        @Refunds AS Refunds,
        (SELECT ISNULL(SUM(Due), 0) FROM #D) AS OutstandingNow,
        -- previous period of the same length, for growth
        SUM(CASE WHEN InPeriod = 0 AND IsActive = 1 THEN 1 ELSE 0 END) AS PrevBillCount,
        ISNULL(SUM(CASE WHEN InPeriod = 0 AND IsActive = 1 THEN NetAmount END), 0) AS PrevNetRevenue,
        COUNT(DISTINCT CASE WHEN InPeriod = 0 AND IsActive = 1 THEN PatientId END) AS PrevPatientCount,
        (SELECT ISNULL(SUM(PaidAmount), 0) FROM #P WHERE InPeriod = 0 AND FromWallet = 0) AS PrevCollected,
        (SELECT COUNT(1) FROM #T) AS ReportsApproved,
        (SELECT COUNT(1) FROM #T WHERE HasTarget = 1) AS TatTests,
        (SELECT COUNT(1) FROM #T WHERE Within = 1) AS TatWithin,
        (SELECT CAST(AVG(Hours) AS DECIMAL(10, 1)) FROM #T WHERE Hours IS NOT NULL) AS TatAvgHours,
        @Specimens AS SpecimensCollected, @Rejected AS SpecimensRejected, @Recollect AS SpecimensRecollect, @Retests AS Retests,
        -- 2252: cost and gross profit of the tests billed in the period
        (SELECT ISNULL(SUM(ActualCost), 0) FROM #L) AS MaterialActual,
        (SELECT ISNULL(SUM(PendingCost), 0) FROM #L) AS MaterialPending,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN KitCost END), 0) AS KitCost,
        (SELECT ISNULL(SUM(Runs), 0) FROM #L) AS TestRuns, (SELECT ISNULL(SUM(Reruns), 0) FROM #L) AS Reruns,
        (SELECT ISNULL(SUM(PendingTests), 0) FROM #L) AS PendingTests, (SELECT ISNULL(SUM(NoBomTests), 0) FROM #L) AS NoBomTests,
        (SELECT ISNULL(SUM(c.MaterialCost), 0) FROM dbo.QcConsumption c INNER JOIN @Br br ON br.BranchId = c.BranchId
          WHERE c.ConsumedOn >= @From AND c.ConsumedOn < @To) AS ConsumedInPeriod,
        @Days AS PeriodDays,
        CONVERT(VARCHAR(10), CAST(@PrevFrom AS DATE), 23) AS PrevFrom,
        CONVERT(VARCHAR(10), DATEADD(DAY, -1, CAST(@PrevTo AS DATE)), 23) AS PrevTo
    FROM #O;

    -- RS2 trend: billed / collected per day (per month for long periods)
    ;WITH b AS (
        SELECT CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), OrderDate, 23) ELSE CONVERT(VARCHAR(10), OrderDate, 23) END AS Bucket,
               COUNT(1) AS Bills, SUM(NetAmount) AS Billed
        FROM #O WHERE InPeriod = 1 AND IsActive = 1
        GROUP BY CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), OrderDate, 23) ELSE CONVERT(VARCHAR(10), OrderDate, 23) END),
    c AS (
        SELECT CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), PaidOn, 23) ELSE CONVERT(VARCHAR(10), PaidOn, 23) END AS Bucket,
               SUM(PaidAmount) AS Collected
        FROM #P WHERE InPeriod = 1 AND FromWallet = 0
        GROUP BY CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), PaidOn, 23) ELSE CONVERT(VARCHAR(10), PaidOn, 23) END)
    SELECT COALESCE(b.Bucket, c.Bucket) AS Bucket, ISNULL(b.Bills, 0) AS Bills, ISNULL(b.Billed, 0) AS Billed, ISNULL(c.Collected, 0) AS Collected,
           CAST(@ByMonth AS BIT) AS ByMonth
    FROM b FULL OUTER JOIN c ON c.Bucket = b.Bucket
    ORDER BY Bucket;

    -- RS3 revenue by test
    SELECT Kind, TestCode, TestName, Department,
           COUNT(1) AS Tests, SUM(CASE WHEN IsB2B = 0 THEN 1 ELSE 0 END) AS B2CTests, SUM(CASE WHEN IsB2B = 1 THEN 1 ELSE 0 END) AS B2BTests,
           SUM(Mrp) AS Gross, SUM(Discount) AS Discount, SUM(PartnerMargin) AS PartnerMargin, SUM(NetLine) AS Net,
           CAST(SUM(NetLine) / NULLIF(COUNT(1), 0) AS DECIMAL(18, 2)) AS AvgRealised,
           SUM(ActualCost) AS ActualCost, SUM(PendingCost) AS PendingCost, SUM(ActualCost + PendingCost) AS MaterialCost,
           SUM(NetLine) - SUM(ActualCost + PendingCost) AS Profit, SUM(PendingTests) AS PendingTests, SUM(Reruns) AS Reruns, SUM(NoBomTests) AS NoBomTests
    FROM #L GROUP BY Kind, TestCode, TestName, Department
    ORDER BY Net DESC;

    -- RS4 by department: revenue and TAT compliance
    ;WITH r AS (SELECT Department, COUNT(1) AS Tests, SUM(Mrp) AS Gross, SUM(Discount) AS Discount, SUM(PartnerMargin) AS PartnerMargin, SUM(NetLine) AS Net, SUM(ActualCost + PendingCost) AS Cost
                FROM #L GROUP BY Department),
    t AS (SELECT Department, COUNT(1) AS Reported, SUM(CASE WHEN HasTarget = 1 THEN 1 ELSE 0 END) AS TatTests,
                 SUM(CASE WHEN Within = 1 THEN 1 ELSE 0 END) AS TatWithin, CAST(AVG(Hours) AS DECIMAL(10, 1)) AS AvgHours
          FROM #T GROUP BY Department)
    SELECT COALESCE(r.Department, t.Department) AS Department, ISNULL(r.Tests, 0) AS Tests, ISNULL(r.Gross, 0) AS Gross,
           ISNULL(r.Discount, 0) AS Discount, ISNULL(r.PartnerMargin, 0) AS PartnerMargin, ISNULL(r.Net, 0) AS Net,
           ISNULL(r.Cost, 0) AS MaterialCost, ISNULL(r.Net, 0) - ISNULL(r.Cost, 0) AS Profit,
           ISNULL(t.Reported, 0) AS Reported, ISNULL(t.TatTests, 0) AS TatTests, ISNULL(t.TatWithin, 0) AS TatWithin, t.AvgHours
    FROM r FULL OUTER JOIN t ON t.Department = r.Department
    ORDER BY ISNULL(r.Net, 0) DESC;

    -- RS5 by referring doctor
    SELECT COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)), ''),
                    NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), ''), 'Self / walk-in') AS Doctor,
           COUNT(1) AS Bills, COUNT(DISTINCT o.PatientId) AS Patients, SUM(o.Tests) AS Tests,
           SUM(CASE WHEN o.IsB2B = 0 THEN 1 ELSE 0 END) AS B2CBills, SUM(CASE WHEN o.IsB2B = 1 THEN 1 ELSE 0 END) AS B2BBills,
           SUM(o.NetAmount) AS Net, SUM(o.DueAmount) AS Due,
           SUM(o.MaterialCost + o.KitCost) AS Cost, SUM(o.NetAmount) - SUM(o.MaterialCost + o.KitCost) AS Profit
    FROM #O o
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = o.RefDoctorId
    LEFT JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = o.ReferralDoctorId
    WHERE o.InPeriod = 1 AND o.IsActive = 1
    GROUP BY o.RefDoctorId, o.ReferralDoctorId, d.NamePrefix, d.FullName, rd.Salutation, rd.DoctorName
    ORDER BY Net DESC;

    -- RS6 by B2B partner
    SELECT CASE o.AgentType WHEN 'F' THEN 'Franchise' WHEN 'C' THEN 'Corporate' ELSE 'Other' END AS PartnerType,
           CASE o.AgentType WHEN 'F' THEN f.Franchise_Code ELSE c.Corporate_Code END AS PartnerCode,
           ISNULL(CASE o.AgentType WHEN 'F' THEN f.Franchise_Name ELSE c.Corporate_Name END, 'Unknown partner') AS Partner,
           COUNT(1) AS Bills, SUM(o.Tests) AS Tests, SUM(o.LineMrp) AS Mrp, SUM(o.NetAmount) AS Billed, SUM(o.LineMargin) AS MarginGiven,
           SUM(o.PaidAmount) AS Collected, SUM(o.DueAmount) AS Due,
           SUM(o.MaterialCost + o.KitCost) AS Cost, SUM(o.NetAmount) - SUM(o.MaterialCost + o.KitCost) AS Profit
    FROM #O o
    LEFT JOIN dbo.LabFranchiseMaster f ON o.AgentType = 'F' AND f.Franchise_ID = o.B2BAgentID
    LEFT JOIN dbo.CorporateMaster c ON o.AgentType = 'C' AND c.Corporate_ID = o.B2BAgentID
    WHERE o.InPeriod = 1 AND o.IsActive = 1 AND o.IsB2B = 1
    GROUP BY o.AgentType, o.B2BAgentID, f.Franchise_Code, f.Franchise_Name, c.Corporate_Code, c.Corporate_Name
    ORDER BY Billed DESC;

    -- RS7 quality: rejection / re-collection reasons
    SELECT ISNULL(NULLIF(LTRIM(RTRIM(COALESCE(rr.Reason_Text, q.RejectionReason))), ''), 'Not recorded') AS Reason,
           COUNT(DISTINCT CASE WHEN q.ToStatusId = 4 THEN q.SpecimenKey END) AS Rejected,
           COUNT(DISTINCT CASE WHEN q.ToStatusId = 3 THEN q.SpecimenKey END) AS Recollect
    FROM #Q q
    LEFT JOIN dbo.LabSampleRejectionReasonMaster rr ON rr.Reason_ID = q.RejectionReasonId
    WHERE q.ToStatusId IN (3, 4)
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(COALESCE(rr.Reason_Text, q.RejectionReason))), ''), 'Not recorded')
    ORDER BY COUNT(DISTINCT q.SpecimenKey) DESC;

    -- RS8 outstanding ageing today (B2C buckets as Outstanding Dues, B2B as B2B Outstanding)
    SELECT Segment, Bucket, SortOrder, COUNT(1) AS Bills, SUM(Due) AS Due
    FROM (SELECT CASE WHEN IsB2B = 1 THEN 'B2B' ELSE 'B2C' END AS Segment,
                 CASE WHEN IsB2B = 0 THEN CASE WHEN AgeDays <= 2 THEN '0-2' WHEN AgeDays <= 7 THEN '3-7' WHEN AgeDays <= 30 THEN '8-30' ELSE '30+' END
                      ELSE CASE WHEN AgeDays <= 30 THEN '0-30' WHEN AgeDays <= 60 THEN '31-60' WHEN AgeDays <= 90 THEN '61-90' ELSE '90+' END END AS Bucket,
                 CASE WHEN IsB2B = 0 THEN CASE WHEN AgeDays <= 2 THEN 1 WHEN AgeDays <= 7 THEN 2 WHEN AgeDays <= 30 THEN 3 ELSE 4 END
                      ELSE CASE WHEN AgeDays <= 30 THEN 1 WHEN AgeDays <= 60 THEN 2 WHEN AgeDays <= 90 THEN 3 ELSE 4 END END AS SortOrder,
                 Due
          FROM #D) x
    GROUP BY Segment, Bucket, SortOrder
    ORDER BY Segment, SortOrder;

    -- RS9 collection by payment mode (receipts of the period)
    SELECT CASE WHEN FromWallet = 1 THEN 'Franchise wallet' ELSE Mode END AS Mode, COUNT(1) AS Receipts, SUM(PaidAmount) AS Amount
    FROM #P WHERE InPeriod = 1
    GROUP BY CASE WHEN FromWallet = 1 THEN 'Franchise wallet' ELSE Mode END
    ORDER BY Amount DESC;

    -- RS10 by branch
    SELECT br.BranchName AS Branch,
           (SELECT COUNT(1) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Bills,
           (SELECT ISNULL(SUM(o.NetAmount), 0) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Net,
           (SELECT ISNULL(SUM(p.PaidAmount), 0) FROM #P p WHERE p.BranchId = br.BranchId AND p.InPeriod = 1 AND p.FromWallet = 0) AS Collected,
           (SELECT ISNULL(SUM(o.DueAmount), 0) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Due,
           (SELECT ISNULL(SUM(o.MaterialCost + o.KitCost), 0) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Cost,
           (SELECT ISNULL(SUM(o.NetAmount - o.MaterialCost - o.KitCost), 0) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Profit
    FROM @Br br
    ORDER BY Net DESC;

    -- RS11 2252: items consumed for the tests billed in the period (actual BOM consumption of their runs)
    SELECT i.ItemCode, i.ItemName, cat.CategoryName AS Category, cu.UnitName AS Unit, COUNT(DISTINCT c.ConsumptionId) AS Runs,
           CAST(SUM(cl.Qty) AS DECIMAL(18, 4)) AS Qty, CAST(SUM(cl.LineCost) AS DECIMAL(18, 2)) AS Cost
    FROM dbo.QcConsumption c
    INNER JOIN (SELECT DISTINCT LabOrderId FROM #L) b ON b.LabOrderId = c.LabOrderId
    INNER JOIN dbo.QcConsumptionLine cl ON cl.ConsumptionId = c.ConsumptionId
    INNER JOIN dbo.InvItem i ON i.ItemId = cl.ItemId
    INNER JOIN dbo.InvItemCategory cat ON cat.CategoryId = i.CategoryId
    INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    GROUP BY i.ItemCode, i.ItemName, cat.CategoryName, cu.UnitName
    ORDER BY Cost DESC;

    DROP TABLE #LU; DROP TABLE #O; DROP TABLE #L; DROP TABLE #T; DROP TABLE #Q; DROP TABLE #P; DROP TABLE #D;
END;
GO

PRINT 'Script 2252 applied: Owner MIS shows BOM cost and gross profit.';
GO
