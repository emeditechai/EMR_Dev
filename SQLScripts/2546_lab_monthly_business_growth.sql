-- ============================================================================================================
-- 2546: Reports > LAB > Monthly Business Growth - month-wise growth or loss of the lab.
--   usp_Api_LabReport_MonthlyGrowth returns, for each month of the range (up to 24 months) and the 12 months before it
--   (for the same month last year):
--     RS1 months       bills, patients (new = first LAB bill ever), tests, MRP, discount, partner margin, net revenue
--                      (B2C / B2B), cost (actual + not run yet + kits, as Owner MIS), gross profit,
--                      receipts (wallet deductions apart), refunds, cancelled amount, due on the month's bills.
--     RS2 departments  net revenue per department per month (bill lines scaled so a bill's lines add up to its net).
--     RS3 branches     net revenue and bills per branch per month.
--     RS4 doctors      referring doctor by month; RS5 partners B2B partner by month; RS6 executives LAB marketing executive by month
--     RS7 meta         branches in scope.
--   Definitions match usp_Api_LabReport_OwnerMis (net / paid / due, B2B at the contract total, receipts by receipt date).
--   Cost = as Owner MIS: BOM material consumed for the bills + tests not run yet at BOM cost + collection kits (estimated).
--   Scope: the current branch, or all branches the user works in (super admin: all of the company).
--   Page REPORTS.LABMONTHLYGROWTH (Reports > LAB). No grants are seeded: give them in Role Permissions.
-- Needs 2200, 2252. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_MonthlyGrowth
    @BranchId     INT,
    @FromMonth    DATE,          -- any day of the first month
    @ToMonth      DATE,          -- any day of the last month
    @AllBranches  BIT = 0,
    @UserId       INT = NULL,
    @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;

    SET @FromMonth = DATEFROMPARTS(YEAR(@FromMonth), MONTH(@FromMonth), 1);
    SET @ToMonth   = DATEFROMPARTS(YEAR(@ToMonth), MONTH(@ToMonth), 1);
    IF @ToMonth < @FromMonth BEGIN DECLARE @sw DATE = @FromMonth; SET @FromMonth = @ToMonth; SET @ToMonth = @sw; END
    IF DATEDIFF(MONTH, @FromMonth, @ToMonth) > 23
        THROW 50020, 'Please select up to 24 months.', 1;

    DECLARE @LoadFrom DATETIME = DATEADD(MONTH, -12, @FromMonth);           -- same month last year
    DECLARE @To       DATETIME = DATEADD(MONTH, 1, @ToMonth);

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

    -- ── the months (range + 12 before it) ────────────────────────────────────
    CREATE TABLE #M (MonthStart DATE PRIMARY KEY, InRange BIT);
    DECLARE @m DATE = CAST(@LoadFrom AS DATE);
    WHILE @m <= @ToMonth
    BEGIN
        INSERT #M VALUES (@m, CASE WHEN @m >= @FromMonth THEN 1 ELSE 0 END);
        SET @m = DATEADD(MONTH, 1, @m);
    END

    -- ── bills ────────────────────────────────────────────────────────────────
    SELECT lo.LabOrderId, lo.BranchId, lo.PatientId,
           DATEFROMPARTS(YEAR(lo.OrderDate), MONTH(lo.OrderDate), 1) AS MonthStart,
           CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, CAST(lo.IsActive AS BIT) AS IsActive,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
           CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
           ph.PaymentHeaderId,
           lo.AgentType, lo.B2BAgentID, lo.RefDoctorId, lo.ReferralDoctorId, lo.MarketingExecutiveId
    INTO #O
    FROM dbo.LabOrder lo
    INNER JOIN @Br br ON br.BranchId = lo.BranchId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.OrderDate >= @LoadFrom AND lo.OrderDate < @To;
    CREATE CLUSTERED INDEX IX_O ON #O (LabOrderId);

    -- bill lines: MRP and the line's share of the bill's net (as Owner MIS)
    SELECT o.LabOrderId, li.LabOrderItemId, li.InvestigationId AS TestId, CAST(CASE WHEN li.[Type] = 'P' THEN 1 ELSE 0 END AS BIT) AS IsPackage,
           o.MonthStart, o.IsB2B,
           CASE WHEN li.[Type] = 'P' THEN 'Packages' ELSE ISNULL(dm.DeptName, 'Not set') END AS Department,
           CAST(li.Price AS DECIMAL(18, 2)) AS Mrp,
           CAST(CASE WHEN o.IsB2B = 1 THEN ISNULL(li.B2BRate, li.Price) ELSE COALESCE(pli.NetLineAmount, li.Price) END AS DECIMAL(18, 4)) AS Basis,
           o.NetAmount AS BillNet
    INTO #L
    FROM #O o
    INNER JOIN dbo.LabOrderItem li ON li.LabOrderId = o.LabOrderId AND li.IsActive = 1
    LEFT  JOIN dbo.LabInvestigationMaster lim ON li.[Type] <> 'P' AND lim.Test_ID = li.InvestigationId
    LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    LEFT  JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = o.PaymentHeaderId AND pli.ModuleLineRefId = li.LabOrderItemId AND pli.IsActive = 1
    WHERE o.IsActive = 1;

    ALTER TABLE #L ADD NetLine DECIMAL(18, 2);
    ;WITH s AS (SELECT LabOrderId, SUM(Basis) AS SumBasis FROM #L GROUP BY LabOrderId)
    UPDATE l SET NetLine = CAST(CASE WHEN s.SumBasis > 0 THEN l.Basis * l.BillNet / s.SumBasis ELSE 0 END AS DECIMAL(18, 2))
    FROM #L l INNER JOIN s ON s.LabOrderId = l.LabOrderId;

    -- cost of the tests billed (same rules as Owner MIS, SQLScripts/2250 / 2449):
    --   actual    = consumption runs recorded for the line on its own bill (re-runs included);
    --   estimated = an in-house test billed but not run yet, at its current BOM cost; outsourced tests have no BOM cost;
    --   kits      = one collection kit per sample type collected in-house (estimated).
    SELECT l.LabOrderItemId, l.LabOrderId, CASE WHEN l.IsPackage = 1 THEN pd.Test_ID ELSE l.TestId END AS UnitTestId,
           CASE WHEN l.IsPackage = 1 THEN l.TestId END AS PackageId
    INTO #LU
    FROM #L l
    LEFT JOIN dbo.LabInvestigationProfileDetail pd ON l.IsPackage = 1 AND pd.Profile_ID = l.TestId AND ISNULL(pd.IsDeleted, 0) = 0
    WHERE l.IsPackage = 0 OR pd.Test_ID IS NOT NULL;

    ALTER TABLE #LU ADD ActualCost DECIMAL(18, 2), Runs INT, Outsourced BIT, EstCost DECIMAL(18, 2);
    UPDATE u SET ActualCost = ISNULL(x.Cost, 0), Runs = ISNULL(x.Runs, 0),
                 Outsourced = CASE WHEN ISNULL(m.Is_Outsourced, 0) = 1
                                     OR EXISTS (SELECT 1 FROM dbo.SampleCollection sc
                                                LEFT JOIN dbo.LabInvestigationProfileHeader ph ON ph.Profile_ID = sc.ProfileId
                                                WHERE sc.Laborderid = u.LabOrderId AND ISNULL(sc.IsoutSource, 0) = 1
                                                  AND (sc.InvestigationID = u.UnitTestId OR ph.Test_ID = u.UnitTestId)) THEN 1 ELSE 0 END,
                 EstCost = dbo.ufn_Qc_TestMaterialCost(u.UnitTestId, NULL)
    FROM #LU u
    LEFT JOIN dbo.LabInvestigationMaster m ON m.Test_ID = u.UnitTestId
    OUTER APPLY (SELECT SUM(c.MaterialCost) AS Cost, COUNT(1) AS Runs
                 FROM dbo.QcConsumption c
                 WHERE c.LabOrderId = u.LabOrderId AND c.TestId = u.UnitTestId AND ISNULL(c.PackageId, 0) = ISNULL(u.PackageId, 0)) x;

    -- per bill: tests, MRP, material (actual + not run yet) and kits
    ALTER TABLE #O ADD Tests INT NOT NULL DEFAULT 0, Mrp DECIMAL(18, 2) NOT NULL DEFAULT 0,
                       ActualCost DECIMAL(18, 2) NOT NULL DEFAULT 0, PendingCost DECIMAL(18, 2) NOT NULL DEFAULT 0, KitCost DECIMAL(18, 2) NOT NULL DEFAULT 0;
    UPDATE o SET Tests = x.Tests, Mrp = x.Mrp
    FROM #O o INNER JOIN (SELECT LabOrderId, COUNT(1) AS Tests, SUM(Mrp) AS Mrp FROM #L GROUP BY LabOrderId) x ON x.LabOrderId = o.LabOrderId;
    UPDATE o SET ActualCost = x.ActualCost, PendingCost = x.PendingCost
    FROM #O o INNER JOIN (SELECT LabOrderId, SUM(ActualCost) AS ActualCost,
                                 SUM(CASE WHEN Runs = 0 AND Outsourced = 0 THEN ISNULL(EstCost, 0) ELSE 0 END) AS PendingCost
                          FROM #LU GROUP BY LabOrderId) x ON x.LabOrderId = o.LabOrderId;
    UPDATE o SET KitCost = ISNULL((SELECT SUM(ISNULL(dbo.ufn_Qc_SampleKitCost(s.SampleTypeId), 0))
                                   FROM (SELECT DISTINCT m.Sample_Type_ID AS SampleTypeId
                                         FROM dbo.SampleCollection sc
                                         INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = sc.InvestigationID
                                         WHERE sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0
                                           AND ISNULL(sc.IsoutSource, 0) = 0 AND m.Sample_Type_ID IS NOT NULL) s), 0)
    FROM #O o WHERE o.IsActive = 1;

    -- new patients: the month of the patient's first active LAB bill ever (any branch)
    SELECT f.PatientId, DATEFROMPARTS(YEAR(f.FirstBill), MONTH(f.FirstBill), 1) AS FirstMonth
    INTO #NP
    FROM (SELECT lo.PatientId, MIN(lo.OrderDate) AS FirstBill FROM dbo.LabOrder lo
          WHERE lo.IsActive = 1 AND lo.PatientId IN (SELECT PatientId FROM #O WHERE IsActive = 1)
          GROUP BY lo.PatientId) f;

    -- receipts (receipt date); wallet deductions apart
    SELECT DATEFROMPARTS(YEAR(COALESCE(pd.PaymentDate, pd.CreatedDate)), MONTH(COALESCE(pd.PaymentDate, pd.CreatedDate)), 1) AS MonthStart,
           pd.PaidAmount,
           CAST(CASE WHEN ISNULL(pd.TransactionRef, '') LIKE 'WALLET-DEBIT-%' THEN 1 ELSE 0 END AS BIT) AS FromWallet
    INTO #P
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'LAB' AND ph.IsActive = 1
    INNER JOIN @Br br ON br.BranchId = ph.BranchId
    WHERE pd.IsActive = 1 AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @LoadFrom AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @To;

    -- RS1 months
    SELECT CONVERT(VARCHAR(7), m.MonthStart, 23) AS Month, m.InRange,
           ISNULL(b.Bills, 0) AS Bills, ISNULL(b.B2CBills, 0) AS B2CBills, ISNULL(b.B2BBills, 0) AS B2BBills,
           ISNULL(b.CancelledBills, 0) AS CancelledBills,
           ISNULL(b.Patients, 0) AS Patients,
           ISNULL((SELECT COUNT(1) FROM #NP np WHERE np.FirstMonth = m.MonthStart), 0) AS NewPatients,
           ISNULL(b.Tests, 0) AS Tests,
           ISNULL(b.Mrp, 0) AS Mrp,
           ISNULL(b.Discount, 0) AS Discount, ISNULL(b.PartnerMargin, 0) AS PartnerMargin,
           ISNULL(b.Net, 0) AS NetRevenue, ISNULL(b.B2CNet, 0) AS B2CRevenue, ISNULL(b.B2BNet, 0) AS B2BRevenue,
           ISNULL(b.ActualCost, 0) AS MaterialActual, ISNULL(b.PendingCost, 0) AS MaterialPending, ISNULL(b.KitCost, 0) AS KitCost,
           ISNULL(b.ActualCost, 0) + ISNULL(b.PendingCost, 0) + ISNULL(b.KitCost, 0) AS MaterialCost,
           ISNULL(b.Net, 0) - ISNULL(b.ActualCost, 0) - ISNULL(b.PendingCost, 0) - ISNULL(b.KitCost, 0) AS GrossProfit,
           ISNULL(b.Due, 0) AS DueOnBills,
           ISNULL((SELECT SUM(p.PaidAmount) FROM #P p WHERE p.MonthStart = m.MonthStart AND p.FromWallet = 0), 0) AS Collected,
           ISNULL((SELECT SUM(p.PaidAmount) FROM #P p WHERE p.MonthStart = m.MonthStart AND p.FromWallet = 1), 0) AS PaidFromWallet,
           ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.BillRefund r
                   INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = r.ModuleRefId
                   INNER JOIN @Br br ON br.BranchId = lo.BranchId
                   WHERE r.ModuleCode = 'LAB' AND r.IsActive = 1 AND ISNULL(r.Status, 'P') = 'P'
                     AND r.RefundDate >= m.MonthStart AND r.RefundDate < DATEADD(MONTH, 1, m.MonthStart)), 0) AS Refunds,
           ISNULL((SELECT SUM(bc.CancelledAmount) FROM dbo.BillCancellation bc
                   INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bc.ModuleRefId
                   INNER JOIN @Br br ON br.BranchId = lo.BranchId
                   WHERE bc.ModuleCode = 'LAB' AND bc.IsActive = 1
                     AND bc.CancellationDate >= m.MonthStart AND bc.CancellationDate < DATEADD(MONTH, 1, m.MonthStart)), 0) AS CancelledAmount,
           DAY(EOMONTH(m.MonthStart)) AS DaysInMonth,
           CASE WHEN m.MonthStart = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1) THEN DAY(GETDATE())
                WHEN m.MonthStart > CAST(GETDATE() AS DATE) THEN 0 ELSE DAY(EOMONTH(m.MonthStart)) END AS DaysElapsed
    FROM #M m
    OUTER APPLY (SELECT SUM(CASE WHEN o.IsActive = 1 THEN 1 ELSE 0 END) AS Bills,
                        SUM(CASE WHEN o.IsActive = 1 AND o.IsB2B = 0 THEN 1 ELSE 0 END) AS B2CBills,
                        SUM(CASE WHEN o.IsActive = 1 AND o.IsB2B = 1 THEN 1 ELSE 0 END) AS B2BBills,
                        SUM(CASE WHEN o.IsActive = 0 THEN 1 ELSE 0 END) AS CancelledBills,
                        COUNT(DISTINCT CASE WHEN o.IsActive = 1 THEN o.PatientId END) AS Patients,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Tests END) AS Tests,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Mrp END) AS Mrp,
                        SUM(CASE WHEN o.IsActive = 1 AND o.IsB2B = 0 AND o.Mrp > o.NetAmount THEN o.Mrp - o.NetAmount ELSE 0 END) AS Discount,
                        SUM(CASE WHEN o.IsActive = 1 AND o.IsB2B = 1 AND o.Mrp > o.NetAmount THEN o.Mrp - o.NetAmount ELSE 0 END) AS PartnerMargin,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.NetAmount END) AS Net,
                        SUM(CASE WHEN o.IsActive = 1 AND o.IsB2B = 0 THEN o.NetAmount END) AS B2CNet,
                        SUM(CASE WHEN o.IsActive = 1 AND o.IsB2B = 1 THEN o.NetAmount END) AS B2BNet,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.ActualCost END) AS ActualCost,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.PendingCost END) AS PendingCost,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.KitCost END) AS KitCost,
                        SUM(CASE WHEN o.IsActive = 1 AND o.NetAmount > o.PaidAmount THEN o.NetAmount - o.PaidAmount ELSE 0 END) AS Due
                 FROM #O o WHERE o.MonthStart = m.MonthStart) b
    ORDER BY m.MonthStart;

    -- RS2 departments by month (range months only)
    SELECT CONVERT(VARCHAR(7), l.MonthStart, 23) AS Month, l.Department, COUNT(1) AS Tests, SUM(l.NetLine) AS Net
    FROM #L l WHERE l.MonthStart >= @FromMonth
    GROUP BY l.MonthStart, l.Department
    ORDER BY l.MonthStart, Net DESC;

    -- RS3 branches by month (range months only)
    SELECT CONVERT(VARCHAR(7), o.MonthStart, 23) AS Month, br.BranchName AS Branch,
           COUNT(1) AS Bills, SUM(o.NetAmount) AS Net
    FROM #O o INNER JOIN @Br br ON br.BranchId = o.BranchId
    WHERE o.IsActive = 1 AND o.MonthStart >= @FromMonth
    GROUP BY o.MonthStart, br.BranchName
    ORDER BY o.MonthStart, Net DESC;

    -- RS4 referring doctor by month (as Owner MIS "By referring doctor")
    SELECT CONVERT(VARCHAR(7), o.MonthStart, 23) AS Month,
           ISNULL(COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix, '') + ' ' + ISNULL(d.FullName, ''))), ''),
                           NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')), 'Self / walk-in') AS Doctor,
           COUNT(1) AS Bills, SUM(o.NetAmount) AS Net
    FROM #O o
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = o.RefDoctorId
    LEFT JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = o.ReferralDoctorId
    WHERE o.IsActive = 1 AND o.MonthStart >= @FromMonth
    GROUP BY o.MonthStart, o.RefDoctorId, o.ReferralDoctorId, d.NamePrefix, d.FullName, rd.Salutation, rd.DoctorName
    ORDER BY o.MonthStart, Net DESC;

    -- RS5 B2B partner by month (as Owner MIS "By B2B partner")
    SELECT CONVERT(VARCHAR(7), o.MonthStart, 23) AS Month,
           ISNULL(CASE o.AgentType WHEN 'F' THEN f.Franchise_Name ELSE c.Corporate_Name END, 'Unknown partner')
             + CASE o.AgentType WHEN 'F' THEN ' (Franchise)' WHEN 'C' THEN ' (Corporate)' ELSE '' END AS Partner,
           COUNT(1) AS Bills, SUM(o.NetAmount) AS Net
    FROM #O o
    LEFT JOIN dbo.LabFranchiseMaster f ON o.AgentType = 'F' AND f.Franchise_ID = o.B2BAgentID
    LEFT JOIN dbo.CorporateMaster c ON o.AgentType = 'C' AND c.Corporate_ID = o.B2BAgentID
    WHERE o.IsActive = 1 AND o.IsB2B = 1 AND o.MonthStart >= @FromMonth
    GROUP BY o.MonthStart, o.AgentType, o.B2BAgentID, f.Franchise_Name, c.Corporate_Name
    ORDER BY o.MonthStart, Net DESC;

    -- RS6 LAB marketing executive by month (executive stored on the bill, as Owner MIS "By marketing executive")
    SELECT CONVERT(VARCHAR(7), o.MonthStart, 23) AS Month,
           ISNULL(e.ExecutiveName, N'Not tagged') AS Executive,
           COUNT(1) AS Bills, SUM(o.NetAmount) AS Net
    FROM #O o
    LEFT JOIN dbo.MarketingExecutive e ON e.ExecutiveId = o.MarketingExecutiveId AND e.IsDeleted = 0 AND e.ExecutiveType = 'LAB'
    WHERE o.IsActive = 1 AND o.MonthStart >= @FromMonth
    GROUP BY o.MonthStart, e.ExecutiveId, e.ExecutiveName
    ORDER BY o.MonthStart, Net DESC;

    -- RS7 meta
    SELECT (SELECT COUNT(1) FROM @Br) AS BranchCount,
           CONVERT(VARCHAR(7), @FromMonth, 23) AS FromMonth, CONVERT(VARCHAR(7), @ToMonth, 23) AS ToMonth;

    DROP TABLE #M; DROP TABLE #O; DROP TABLE #L; DROP TABLE #LU; DROP TABLE #NP; DROP TABLE #P;
END;
GO

-- ── menu page and endpoints (database navigation) ────────────────────────────
DECLARE @co INT, @menu INT, @page INT, @view INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'REPORTS.LABMONTHLYGROWTH',
             @Title = N'Monthly Business Growth', @Controller = N'Reports', @Action = N'LabMonthlyGrowth', @Show_In_Menu = 1, @Sort_Order = 6,
             @Icon = N'bi bi-bar-chart-line me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        SET @view = NULL;
        SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'LabMonthlyGrowth', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'GetLabMonthlyGrowthData', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2546 applied: Reports > LAB > Monthly Business Growth.';
GO
