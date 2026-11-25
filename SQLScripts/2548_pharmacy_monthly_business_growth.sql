-- ============================================================================================================
-- 2548: Reports > Pharmacy > Pharmacy Monthly Business Growth - month-wise growth or loss of the pharmacy
--   (same page as LAB 2546 / OPD 2547).
--   usp_Api_PhReport_MonthlyGrowth returns, for each month of the range (up to 24 months) and the 12 months before it
--   (for the same month last year):
--     RS1 months         bills, cancelled bills, customers (new = first pharmacy bill ever for a patient / customer /
--                        mobile), items sold, MRP value, discount, GST, sales before GST, returns, net revenue
--                        (walk-in / patient / credit customer), cost of goods (purchase cost of what was kept), gross
--                        profit (sales before GST - cost), receipts, refunds, due on the month's bills.
--     RS2 categories     net revenue per item category per month.
--     RS3 doctors        net revenue per prescribing doctor (name on the bill) per month.
--     RS4 manufacturers  net revenue per manufacturer per month.
--     RS5 customertypes  net revenue per customer type per month.
--     RS6 branches       net revenue and bills per branch per month.
--     RS7 meta           branches in scope.
--   Definitions as Reports > Pharmacy (2361): posted bills only, by sale date; a return reduces the month of the bill it
--   came from (as Item-wise Sales: quantity kept = Qty - ReturnedQty); cost = UnitCost of the quantity kept; receipts
--   are PHR receipts by receipt date. Net revenue = bill net - returned amount (GST included); profit is on sales
--   before GST.
--   Scope: the current branch, or all branches the user works in (super admin: all of the company).
--   Page REPORTS.PHARMACY.MONTHLYGROWTH (Reports > Pharmacy). No grants are seeded: give them in Role Permissions.
-- Needs 2361. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhReport_MonthlyGrowth
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

    -- ── bills (posted; cancelled counted apart) ──────────────────────────────
    SELECT s.SaleId, s.BranchId, s.CustomerKind,
           CASE s.CustomerKind WHEN 'PATIENT' THEN 'P' + CAST(s.PatientId AS VARCHAR(12)) WHEN 'CUSTOMER' THEN 'C' + CAST(s.CustomerId AS VARCHAR(12))
                ELSE COALESCE('M' + NULLIF(LTRIM(RTRIM(s.Mobile)), ''), 'S' + CAST(s.SaleId AS VARCHAR(12))) END AS CustKey,
           ISNULL(NULLIF(LTRIM(RTRIM(s.DoctorName)), N''), N'(no doctor)') AS Doctor,
           DATEFROMPARTS(YEAR(s.SaleDate), MONTH(s.SaleDate), 1) AS MonthStart,
           CAST(CASE WHEN s.Status = 'POSTED' THEN 1 ELSE 0 END AS BIT) AS IsActive,
           CAST(ISNULL(s.MrpAmount, 0) AS DECIMAL(18, 2)) AS Mrp,
           CAST(ISNULL(s.DiscountAmount, 0) AS DECIMAL(18, 2)) AS Discount,
           CAST(ISNULL(s.NetAmount, 0) AS DECIMAL(18, 2)) AS BillNet,
           CAST(ISNULL(s.ReturnedAmount, 0) AS DECIMAL(18, 2)) AS Returned,
           CAST(ISNULL(s.NetAmount, 0) - ISNULL(s.ReturnedAmount, 0) AS DECIMAL(18, 2)) AS NetAmount,
           CAST(ISNULL(s.BalanceDue, 0) AS DECIMAL(18, 2)) AS Due
    INTO #O
    FROM dbo.PhSale s
    INNER JOIN @Br br ON br.BranchId = s.BranchId
    WHERE s.Status IN ('POSTED', 'CANCELLED') AND s.SaleDate >= @LoadFrom AND s.SaleDate < @To;
    CREATE CLUSTERED INDEX IX_O ON #O (SaleId);

    -- lines: quantity kept, sales before GST, GST, cost; each line's share of the bill's net revenue
    SELECT o.SaleId, o.MonthStart, d.ItemId,
           CAST(d.Qty - d.ReturnedQty AS DECIMAL(18, 4)) AS QtyKept,
           CAST(CASE WHEN d.Qty = 0 THEN 0 ELSE d.TaxableAmount * (d.Qty - d.ReturnedQty) / d.Qty END AS DECIMAL(18, 4)) AS Taxable,
           CAST(CASE WHEN d.Qty = 0 THEN 0 ELSE d.Amount * (d.Qty - d.ReturnedQty) / d.Qty END AS DECIMAL(18, 4)) AS Amount,
           CAST(ISNULL(d.UnitCost, 0) * (d.Qty - d.ReturnedQty) AS DECIMAL(18, 4)) AS Cost,
           o.NetAmount AS BillNet
    INTO #L
    FROM #O o
    INNER JOIN dbo.PhSaleDtl d ON d.SaleId = o.SaleId
    WHERE o.IsActive = 1;

    ALTER TABLE #L ADD NetLine DECIMAL(18, 2);
    ;WITH s AS (SELECT SaleId, SUM(Amount) AS SumAmt, COUNT(1) AS Lines FROM #L GROUP BY SaleId)
    UPDATE l SET NetLine = CAST(CASE WHEN s.SumAmt > 0 THEN l.Amount * l.BillNet / s.SumAmt ELSE 0 END AS DECIMAL(18, 2))
    FROM #L l INNER JOIN s ON s.SaleId = l.SaleId;

    ALTER TABLE #O ADD Items DECIMAL(18, 2) NOT NULL DEFAULT 0, Taxable DECIMAL(18, 2) NOT NULL DEFAULT 0,
                       Gst DECIMAL(18, 2) NOT NULL DEFAULT 0, Cost DECIMAL(18, 2) NOT NULL DEFAULT 0;
    UPDATE o SET Items = x.Qty, Taxable = x.Taxable, Gst = x.Amount - x.Taxable, Cost = x.Cost
    FROM #O o INNER JOIN (SELECT SaleId, SUM(QtyKept) AS Qty, SUM(Taxable) AS Taxable, SUM(Amount) AS Amount, SUM(Cost) AS Cost
                          FROM #L GROUP BY SaleId) x ON x.SaleId = o.SaleId;

    -- new customers: the month of the customer's first posted pharmacy bill ever (any branch); walk-ins without a mobile are not counted
    SELECT f.CustKey, DATEFROMPARTS(YEAR(f.FirstBill), MONTH(f.FirstBill), 1) AS FirstMonth
    INTO #NC
    FROM (SELECT k.CustKey, MIN(s.SaleDate) AS FirstBill
          FROM dbo.PhSale s
          CROSS APPLY (SELECT CASE s.CustomerKind WHEN 'PATIENT' THEN 'P' + CAST(s.PatientId AS VARCHAR(12)) WHEN 'CUSTOMER' THEN 'C' + CAST(s.CustomerId AS VARCHAR(12))
                                   ELSE 'M' + NULLIF(LTRIM(RTRIM(s.Mobile)), '') END AS CustKey) k
          WHERE s.Status = 'POSTED' AND k.CustKey IN (SELECT CustKey FROM #O WHERE IsActive = 1 AND LEFT(CustKey, 1) <> 'S')
            AND s.CompanyId = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId)
          GROUP BY k.CustKey) f;

    -- receipts and refunds (receipt / refund date)
    SELECT DATEFROMPARTS(YEAR(COALESCE(pd.PaymentDate, pd.CreatedDate)), MONTH(COALESCE(pd.PaymentDate, pd.CreatedDate)), 1) AS MonthStart, pd.PaidAmount
    INTO #P
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND RTRIM(ph.ModuleCode) = 'PHR'
    INNER JOIN dbo.PhSale s ON s.SaleId = ph.ModuleRefId
    INNER JOIN @Br br ON br.BranchId = s.BranchId
    WHERE pd.IsActive = 1 AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @LoadFrom AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @To;

    -- RS1 months
    SELECT CONVERT(VARCHAR(7), m.MonthStart, 23) AS Month, m.InRange,
           ISNULL(b.Bills, 0) AS Bills, ISNULL(b.CancelledBills, 0) AS CancelledBills,
           ISNULL(b.Customers, 0) AS Patients,
           ISNULL((SELECT COUNT(1) FROM #NC n WHERE n.FirstMonth = m.MonthStart), 0) AS NewPatients,
           ISNULL(b.Items, 0) AS Items,
           ISNULL(b.Mrp, 0) AS Mrp, ISNULL(b.Discount, 0) AS Discount, ISNULL(b.Gst, 0) AS Gst,
           ISNULL(b.Taxable, 0) AS TaxableSales, ISNULL(b.Returned, 0) AS Returned,
           ISNULL(b.Net, 0) AS NetRevenue,
           ISNULL(b.WalkIn, 0) AS WalkInRevenue, ISNULL(b.Patient, 0) AS PatientRevenue, ISNULL(b.Credit, 0) AS CreditRevenue,
           ISNULL(b.Cost, 0) AS CostOfGoods,
           ISNULL(b.Taxable, 0) - ISNULL(b.Cost, 0) AS GrossProfit,
           ISNULL(b.Due, 0) AS DueOnBills,
           ISNULL((SELECT SUM(p.PaidAmount) FROM #P p WHERE p.MonthStart = m.MonthStart), 0) AS Collected,
           ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.BillRefund r
                   INNER JOIN dbo.PhSale s ON s.SaleId = r.ModuleRefId
                   INNER JOIN @Br br ON br.BranchId = s.BranchId
                   WHERE r.ModuleCode = 'PHR' AND r.IsActive = 1
                     AND r.RefundDate >= m.MonthStart AND r.RefundDate < DATEADD(MONTH, 1, m.MonthStart)), 0) AS Refunds,
           DAY(EOMONTH(m.MonthStart)) AS DaysInMonth,
           CASE WHEN m.MonthStart = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1) THEN DAY(GETDATE())
                WHEN m.MonthStart > CAST(GETDATE() AS DATE) THEN 0 ELSE DAY(EOMONTH(m.MonthStart)) END AS DaysElapsed
    FROM #M m
    OUTER APPLY (SELECT SUM(CASE WHEN o.IsActive = 1 THEN 1 ELSE 0 END) AS Bills,
                        SUM(CASE WHEN o.IsActive = 0 THEN 1 ELSE 0 END) AS CancelledBills,
                        COUNT(DISTINCT CASE WHEN o.IsActive = 1 THEN o.CustKey END) AS Customers,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Items END) AS Items,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Mrp END) AS Mrp,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Discount END) AS Discount,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Gst END) AS Gst,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Taxable END) AS Taxable,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Returned END) AS Returned,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.NetAmount END) AS Net,
                        SUM(CASE WHEN o.IsActive = 1 AND o.CustomerKind = 'PATIENT' THEN o.NetAmount ELSE 0 END) AS Patient,
                        SUM(CASE WHEN o.IsActive = 1 AND o.CustomerKind = 'CUSTOMER' THEN o.NetAmount ELSE 0 END) AS Credit,
                        SUM(CASE WHEN o.IsActive = 1 AND ISNULL(o.CustomerKind, '') NOT IN ('PATIENT', 'CUSTOMER') THEN o.NetAmount ELSE 0 END) AS WalkIn,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Cost END) AS Cost,
                        SUM(CASE WHEN o.IsActive = 1 AND o.Due > 0 THEN o.Due ELSE 0 END) AS Due
                 FROM #O o WHERE o.MonthStart = m.MonthStart) b
    ORDER BY m.MonthStart;

    -- RS2 item category by month (parent › child)
    SELECT CONVERT(VARCHAR(7), l.MonthStart, 23) AS Month,
           ISNULL(ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName, N'Not set') AS Category,
           COUNT(DISTINCT l.SaleId) AS Bills, SUM(l.NetLine) AS Net
    FROM #L l
    INNER JOIN dbo.PhItem i ON i.ItemId = l.ItemId
    LEFT  JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
    LEFT  JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
    WHERE l.MonthStart >= @FromMonth
    GROUP BY l.MonthStart, pc.CategoryName, c.CategoryName
    ORDER BY l.MonthStart, Net DESC;

    -- RS3 prescribing doctor by month
    SELECT CONVERT(VARCHAR(7), o.MonthStart, 23) AS Month, o.Doctor, COUNT(1) AS Bills, SUM(o.NetAmount) AS Net
    FROM #O o WHERE o.IsActive = 1 AND o.MonthStart >= @FromMonth
    GROUP BY o.MonthStart, o.Doctor
    ORDER BY o.MonthStart, Net DESC;

    -- RS4 manufacturer by month
    SELECT CONVERT(VARCHAR(7), l.MonthStart, 23) AS Month, ISNULL(mf.ManufacturerName, N'Not set') AS Manufacturer,
           COUNT(DISTINCT l.SaleId) AS Bills, SUM(l.NetLine) AS Net
    FROM #L l
    INNER JOIN dbo.PhItem i ON i.ItemId = l.ItemId
    LEFT  JOIN dbo.PhManufacturer mf ON mf.ManufacturerId = i.ManufacturerId
    WHERE l.MonthStart >= @FromMonth
    GROUP BY l.MonthStart, mf.ManufacturerName
    ORDER BY l.MonthStart, Net DESC;

    -- RS5 customer type by month
    SELECT CONVERT(VARCHAR(7), o.MonthStart, 23) AS Month,
           CASE o.CustomerKind WHEN 'PATIENT' THEN N'Patient' WHEN 'CUSTOMER' THEN N'Credit customer' ELSE N'Walk-in' END AS CustomerType,
           COUNT(1) AS Bills, SUM(o.NetAmount) AS Net
    FROM #O o WHERE o.IsActive = 1 AND o.MonthStart >= @FromMonth
    GROUP BY o.MonthStart, CASE o.CustomerKind WHEN 'PATIENT' THEN N'Patient' WHEN 'CUSTOMER' THEN N'Credit customer' ELSE N'Walk-in' END
    ORDER BY o.MonthStart, Net DESC;

    -- RS6 branch by month
    SELECT CONVERT(VARCHAR(7), o.MonthStart, 23) AS Month, br.BranchName AS Branch, COUNT(1) AS Bills, SUM(o.NetAmount) AS Net
    FROM #O o INNER JOIN @Br br ON br.BranchId = o.BranchId
    WHERE o.IsActive = 1 AND o.MonthStart >= @FromMonth
    GROUP BY o.MonthStart, br.BranchName
    ORDER BY o.MonthStart, Net DESC;

    -- RS7 meta
    SELECT (SELECT COUNT(1) FROM @Br) AS BranchCount,
           CONVERT(VARCHAR(7), @FromMonth, 23) AS FromMonth, CONVERT(VARCHAR(7), @ToMonth, 23) AS ToMonth;

    DROP TABLE #M; DROP TABLE #O; DROP TABLE #L; DROP TABLE #NC; DROP TABLE #P;
END;
GO

-- ── menu page and endpoints (database navigation) ────────────────────────────
DECLARE @co INT, @menu INT, @page INT, @view INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.PHARMACY' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'REPORTS.PHARMACY.MONTHLYGROWTH',
             @Title = N'Pharmacy Monthly Business Growth', @Controller = N'Reports', @Action = N'PharmacyMonthlyGrowth', @Show_In_Menu = 1, @Sort_Order = 5,
             @Icon = N'bi bi-bar-chart-line me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        SET @view = NULL;
        SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'PharmacyMonthlyGrowth', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'GetPharmacyMonthlyGrowthData', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2548 applied: Reports > Pharmacy > Pharmacy Monthly Business Growth.';
GO
