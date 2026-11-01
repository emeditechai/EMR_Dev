-- ============================================================================================================
-- Migration: 2361_pharmacy_reports_sales.sql
-- Reports > Pharmacy > Sales (S1-S12 of the Pharmacy Reports plan), read through EMR.Api.
--   Every report procedure has the same parameters and answers the same three result sets:
--     1 tiles (one row) · 2 the requested page of rows (@PageSize 0 = every row, for export) · 3 totals (one row, TotalRows)
--   @BranchId NULL = all branches of the company (EMR.Web allows that to the Super Admin only).
--   Figures come only from posted documents (held and cancelled bills are left out unless the report is about them).
--   Menu: Reports > Pharmacy, one page per report (as under LAB / OPD) (REPORTS.PHARMACY.*) with VIEW and EXPORT. No grants.
-- Run after 2360. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── indexes for date-range reports ───────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhSale_Rpt' AND object_id = OBJECT_ID('dbo.PhSale'))
    CREATE INDEX IX_PhSale_Rpt ON dbo.PhSale (CompanyId, SaleDate) INCLUDE (BranchId, Status, NetAmount, CreatedBy);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhSaleDtl_Sale' AND object_id = OBJECT_ID('dbo.PhSaleDtl'))
    CREATE INDEX IX_PhSaleDtl_Sale ON dbo.PhSaleDtl (SaleId) INCLUDE (ItemId, Qty, ReturnedQty, Amount, TaxableAmount, UnitCost, UnitMrp, DiscPercent);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhSaleReturn_Rpt' AND object_id = OBJECT_ID('dbo.PhSaleReturn'))
    CREATE INDEX IX_PhSaleReturn_Rpt ON dbo.PhSaleReturn (CompanyId, ReturnDate) INCLUDE (BranchId, SaleId, NetAmount);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhStockLedger_Rpt' AND object_id = OBJECT_ID('dbo.PhStockLedger'))
    CREATE INDEX IX_PhStockLedger_Rpt ON dbo.PhStockLedger (BranchId, TxnDate);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhGrn_Rpt' AND object_id = OBJECT_ID('dbo.PhGrn'))
    CREATE INDEX IX_PhGrn_Rpt ON dbo.PhGrn (BranchId, GrnDate);
GO

-- ── filter lists: 1 users, 2 categories, 3 manufacturers, 4 schedules, 5 payment modes, 6 return reasons, 7 branches, 8 suppliers ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_Lookups @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT CAST(u.Id AS VARCHAR(10)) AS Value, ISNULL(NULLIF(u.FullName, ''), u.Username) AS Text
      FROM dbo.Users u
     WHERE u.Id IN (SELECT CreatedBy FROM dbo.PhSale WHERE CompanyId = @CompanyId AND (@BranchId IS NULL OR BranchId = @BranchId)
                    UNION SELECT CreatedBy FROM dbo.PhSaleReturn WHERE CompanyId = @CompanyId AND (@BranchId IS NULL OR BranchId = @BranchId)
                    UNION SELECT CancelledBy FROM dbo.PhSale WHERE CompanyId = @CompanyId AND CancelledBy IS NOT NULL AND (@BranchId IS NULL OR BranchId = @BranchId))
     ORDER BY Text;
    SELECT CAST(c.CategoryId AS VARCHAR(10)) AS Value, CASE WHEN p.CategoryId IS NULL THEN c.CategoryName ELSE p.CategoryName + N' › ' + c.CategoryName END AS Text
      FROM dbo.PhCategory c LEFT JOIN dbo.PhCategory p ON p.CategoryId = c.ParentCategoryId
     WHERE c.CompanyId = @CompanyId ORDER BY ISNULL(p.SortOrder, c.SortOrder), ISNULL(p.CategoryName, c.CategoryName), c.ParentCategoryId, c.SortOrder;
    SELECT CAST(ManufacturerId AS VARCHAR(10)) AS Value, ManufacturerName AS Text FROM dbo.PhManufacturer WHERE CompanyId = @CompanyId ORDER BY ManufacturerName;
    SELECT ScheduleCode AS Value, ScheduleCode + N' - ' + ScheduleName AS Text FROM dbo.PhDrugSchedule ORDER BY SortOrder;
    SELECT UPPER(MethodCode) AS Value, MethodName AS Text FROM dbo.PaymentMethodMaster WHERE IsActive = 1 AND UPPER(MethodCode) IN ('CASH', 'CARD', 'UPI', 'NEFT', 'CHEQUE') ORDER BY PaymentMethodId;
    SELECT CAST(ReasonId AS VARCHAR(10)) AS Value, ReasonName AS Text FROM dbo.PhReason WHERE CompanyId = @CompanyId AND ReasonType = 'SALE_RETURN' ORDER BY SortOrder, ReasonName;
    SELECT CAST(BranchID AS VARCHAR(10)) AS Value, BranchName + N' (' + BranchCode + N')' AS Text FROM dbo.BranchMaster WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY ISNULL(IsHOBranch, 0) DESC, BranchName;
    SELECT CAST(SupplierId AS VARCHAR(10)) AS Value, SupplierName AS Text FROM dbo.PhSupplier WHERE CompanyId = @CompanyId ORDER BY SupplierName;
END
GO

-- ── S1 Daily Sales Register: every bill (@Option ALL = with cancelled bills) ─────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_SalesRegister
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT ROW_NUMBER() OVER (ORDER BY s.SaleDate, s.SaleId) AS Rn, s.SaleId, b.BranchCode, s.SaleNo, s.SaleDate,
           ISNULL(NULLIF(s.CustomerName, N''), N'Walk-in') AS CustomerName, s.Mobile,
           CASE s.CustomerKind WHEN 'PATIENT' THEN N'Patient' WHEN 'CUSTOMER' THEN N'Credit customer' ELSE N'Walk-in' END AS CustomerType,
           s.DoctorName, (SELECT COUNT(*) FROM dbo.PhSaleDtl d WHERE d.SaleId = s.SaleId) AS Items,
           s.MrpAmount, s.DiscountAmount, s.TaxableAmount, s.CgstAmount, s.SgstAmount, s.RoundOff, s.NetAmount, s.PaidAmount, s.ReturnedAmount, s.BalanceDue,
           CASE s.Status WHEN 'POSTED' THEN N'Posted' ELSE N'Cancelled' END AS Status,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = s.CreatedBy) AS UserName
      INTO #R
      FROM dbo.PhSale s JOIN dbo.BranchMaster b ON b.BranchID = s.BranchId
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.SaleDate >= @From AND s.SaleDate < @end
       AND (s.Status = 'POSTED' OR (@Option = 'ALL' AND s.Status = 'CANCELLED'))
       AND (@UserId IS NULL OR s.CreatedBy = @UserId) AND (@Kind IS NULL OR s.CustomerKind = @Kind)
       AND (@Mode IS NULL OR EXISTS (SELECT 1 FROM dbo.PaymentHeader ph JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = ph.PaymentHeaderId
                                     JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
                                     WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.ModuleRefId = s.SaleId AND pd.IsActive = 1 AND UPPER(pm.MethodCode) = @Mode))
       AND (@Search IS NULL OR s.SaleNo LIKE @like OR s.CustomerName LIKE @like OR s.Mobile LIKE @like OR s.DoctorName LIKE @like);

    SELECT COUNT(*) AS Bills, ISNULL(SUM(NetAmount), 0) AS NetSales, ISNULL(SUM(DiscountAmount), 0) AS Discount,
           ISNULL(SUM(CgstAmount + SgstAmount), 0) AS Gst, ISNULL(SUM(PaidAmount), 0) AS Paid, ISNULL(SUM(BalanceDue), 0) AS Due,
           CASE WHEN COUNT(*) = 0 THEN 0 ELSE ISNULL(SUM(NetAmount), 0) / COUNT(*) END AS AvgBill
      FROM #R WHERE Status = N'Posted';
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Items) AS Items, SUM(MrpAmount) AS MrpAmount, SUM(DiscountAmount) AS DiscountAmount, SUM(TaxableAmount) AS TaxableAmount,
           SUM(CgstAmount) AS CgstAmount, SUM(SgstAmount) AS SgstAmount, SUM(RoundOff) AS RoundOff, SUM(NetAmount) AS NetAmount, SUM(PaidAmount) AS PaidAmount,
           SUM(ReturnedAmount) AS ReturnedAmount, SUM(BalanceDue) AS BalanceDue
      FROM #R;
END
GO

-- ── S2 Sales Summary: day-wise (default) or month-wise (@Option MONTH) ──────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_SalesSummary
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME)), @month BIT = CASE WHEN @Option = 'MONTH' THEN 1 ELSE 0 END;
    -- bills: net, and what was paid on the bill the same day (the rest went on credit)
    SELECT CASE WHEN @month = 1 THEN DATEFROMPARTS(YEAR(s.SaleDate), MONTH(s.SaleDate), 1) ELSE CAST(s.SaleDate AS DATE) END AS Period, s.NetAmount,
           ISNULL((SELECT SUM(pd.PaidAmount) FROM dbo.PaymentHeader ph JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = ph.PaymentHeaderId
                    WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.ModuleRefId = s.SaleId AND pd.IsActive = 1
                      AND CAST(COALESCE(pd.PaymentDate, pd.CreatedDate) AS DATE) = CAST(s.SaleDate AS DATE)), 0) AS PaidAtBill
      INTO #B FROM dbo.PhSale s
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED' AND s.SaleDate >= @From AND s.SaleDate < @end
       AND (@UserId IS NULL OR s.CreatedBy = @UserId) AND (@Kind IS NULL OR s.CustomerKind = @Kind);
    SELECT CASE WHEN @month = 1 THEN DATEFROMPARTS(YEAR(r.ReturnDate), MONTH(r.ReturnDate), 1) ELSE CAST(r.ReturnDate AS DATE) END AS Period, r.NetAmount
      INTO #T FROM dbo.PhSaleReturn r JOIN dbo.PhSale s ON s.SaleId = r.SaleId
     WHERE r.CompanyId = @CompanyId AND (@BranchId IS NULL OR r.BranchId = @BranchId) AND r.ReturnDate >= @From AND r.ReturnDate < @end
       AND (@UserId IS NULL OR r.CreatedBy = @UserId) AND (@Kind IS NULL OR s.CustomerKind = @Kind);
    -- money received in the period (bills and credit collections) by mode, and money paid back
    SELECT CASE WHEN @month = 1 THEN DATEFROMPARTS(YEAR(x.D), MONTH(x.D), 1) ELSE CAST(x.D AS DATE) END AS Period, x.Mode, x.Amount
      INTO #P FROM (
        SELECT COALESCE(pd.PaymentDate, pd.CreatedDate) AS D, UPPER(pm.MethodCode) AS Mode, pd.PaidAmount AS Amount, pd.CreatedBy, s.CustomerKind
          FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
          JOIN dbo.PhSale s ON s.SaleId = ph.ModuleRefId
         WHERE RTRIM(ph.ModuleCode) = 'PHR' AND pd.IsActive = 1 AND s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId)
        UNION ALL
        SELECT r.RefundDate, 'REFUND', -r.RefundAmount, r.CreatedBy, s.CustomerKind
          FROM dbo.BillRefund r JOIN dbo.PhSale s ON s.SaleId = r.ModuleRefId
         WHERE r.ModuleCode = 'PHR' AND r.IsActive = 1 AND s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId)) x
     WHERE x.D >= @From AND x.D < @end AND (@UserId IS NULL OR x.CreatedBy = @UserId) AND (@Kind IS NULL OR x.CustomerKind = @Kind);

    SELECT p.Period, ROW_NUMBER() OVER (ORDER BY p.Period) AS Rn,
           CASE WHEN @month = 1 THEN FORMAT(p.Period, 'MMM yyyy', 'en-US') ELSE FORMAT(p.Period, 'dd MMM yyyy, ddd', 'en-US') END AS PeriodLabel,
           ISNULL(b.Bills, 0) AS Bills, ISNULL(b.Sales, 0) AS Sales, ISNULL(t.Returns, 0) AS Returns, ISNULL(b.Sales, 0) - ISNULL(t.Returns, 0) AS NetSales,
           ISNULL(m.Cash, 0) AS Cash, ISNULL(m.Card, 0) AS Card, ISNULL(m.Upi, 0) AS Upi, ISNULL(m.Other, 0) AS Other, ISNULL(m.Refunds, 0) AS Refunds,
           ISNULL(b.Sales, 0) - ISNULL(b.PaidAtBill, 0) AS Credit,
           CASE WHEN ISNULL(b.Bills, 0) = 0 THEN 0 ELSE b.Sales / b.Bills END AS AvgBill
      INTO #R
      FROM (SELECT Period FROM #B UNION SELECT Period FROM #T UNION SELECT Period FROM #P) p
      LEFT JOIN (SELECT Period, COUNT(*) Bills, SUM(NetAmount) Sales, SUM(PaidAtBill) PaidAtBill FROM #B GROUP BY Period) b ON b.Period = p.Period
      LEFT JOIN (SELECT Period, SUM(NetAmount) Returns FROM #T GROUP BY Period) t ON t.Period = p.Period
      LEFT JOIN (SELECT Period, SUM(CASE WHEN Mode = 'CASH' THEN Amount END) Cash, SUM(CASE WHEN Mode = 'CARD' THEN Amount END) Card,
                        SUM(CASE WHEN Mode = 'UPI' THEN Amount END) Upi, SUM(CASE WHEN Mode IN ('NEFT', 'CHEQUE') THEN Amount END) Other,
                        SUM(CASE WHEN Mode = 'REFUND' THEN -Amount END) Refunds
                   FROM #P GROUP BY Period) m ON m.Period = p.Period;

    SELECT ISNULL(SUM(Bills), 0) AS Bills, ISNULL(SUM(Sales), 0) AS Sales, ISNULL(SUM(Returns), 0) AS Returns, ISNULL(SUM(NetSales), 0) AS NetSales,
           ISNULL(SUM(Cash + Card + Upi + Other), 0) AS Collected, ISNULL(SUM(Credit), 0) AS Credit,
           CASE WHEN ISNULL(SUM(Bills), 0) = 0 THEN 0 ELSE SUM(Sales) / SUM(Bills) END AS AvgBill
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Bills) AS Bills, SUM(Sales) AS Sales, SUM(Returns) AS Returns, SUM(NetSales) AS NetSales, SUM(Cash) AS Cash, SUM(Card) AS Card,
           SUM(Upi) AS Upi, SUM(Other) AS Other, SUM(Refunds) AS Refunds, SUM(Credit) AS Credit,
           CASE WHEN ISNULL(SUM(Bills), 0) = 0 THEN 0 ELSE SUM(Sales) / SUM(Bills) END AS AvgBill
      FROM #R;
END
GO

-- ── S3 Item-wise Sales: quantity and value net of returns, cost at the batch's landed cost ───────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_ItemSales
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT i.ItemId, i.ItemCode, i.ItemName, df.ShortName AS FormShort, ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, m.ManufacturerName,
           i.ScheduleCode, su.UomCode AS SaleUom, pu.UomCode AS PurchaseUom, i.ConversionQty,
           SUM(d.Qty - d.ReturnedQty) AS Qty, COUNT(DISTINCT s.SaleId) AS Bills,
           ROUND(SUM(CASE WHEN d.Qty = 0 THEN 0 ELSE d.TaxableAmount * (d.Qty - d.ReturnedQty) / d.Qty END), 2) AS Sales,
           ROUND(SUM(CASE WHEN d.Qty = 0 THEN 0 ELSE d.Amount * (d.Qty - d.ReturnedQty) / d.Qty END), 2) AS SalesWithGst,
           ROUND(SUM(d.UnitCost * (d.Qty - d.ReturnedQty)), 2) AS Cost,
           ROUND(SUM(d.UnitMrp * (d.Qty - d.ReturnedQty)), 2) AS MrpValue
      INTO #G
      FROM dbo.PhSaleDtl d JOIN dbo.PhSale s ON s.SaleId = d.SaleId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
      LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
      LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED' AND s.SaleDate >= @From AND s.SaleDate < @end
       AND (@UserId IS NULL OR s.CreatedBy = @UserId) AND (@Kind IS NULL OR s.CustomerKind = @Kind)
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId) AND (@Schedule IS NULL OR i.ScheduleCode = @Schedule)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search OR g.GenericName LIKE @like)
     GROUP BY i.ItemId, i.ItemCode, i.ItemName, df.ShortName, pc.CategoryName, c.CategoryName, m.ManufacturerName, i.ScheduleCode, su.UomCode, pu.UomCode, i.ConversionQty;
    SELECT ROW_NUMBER() OVER (ORDER BY Sales DESC, ItemName) AS Rn, *, CASE WHEN ConversionQty > 1 THEN Qty / ConversionQty END AS Packs,
           Sales - Cost AS Margin, CASE WHEN Sales = 0 THEN 0 ELSE (Sales - Cost) * 100 / Sales END AS MarginPct
      INTO #R FROM #G;

    SELECT COUNT(*) AS Items, ISNULL(SUM(Qty), 0) AS Qty, ISNULL(SUM(Sales), 0) AS Sales, ISNULL(SUM(Cost), 0) AS Cost, ISNULL(SUM(Margin), 0) AS Margin,
           CASE WHEN ISNULL(SUM(Sales), 0) = 0 THEN 0 ELSE SUM(Margin) * 100 / SUM(Sales) END AS MarginPct
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(Bills) AS Bills, SUM(Sales) AS Sales, SUM(SalesWithGst) AS SalesWithGst, SUM(Cost) AS Cost, SUM(Margin) AS Margin,
           CASE WHEN ISNULL(SUM(Sales), 0) = 0 THEN 0 ELSE SUM(Margin) * 100 / SUM(Sales) END AS MarginPct, SUM(MrpValue) AS MrpValue
      FROM #R;
END
GO

-- ── S4 Payment-mode Collection Register: every receipt (bill or credit collection) and refund ─────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_Collections
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT x.*, ROW_NUMBER() OVER (ORDER BY x.TxnDate, x.Seq) AS Rn INTO #R FROM (
        SELECT pd.PaymentDetailId AS Seq, b.BranchCode, pd.ReceiptNo AS DocNo, COALESCE(pd.PaymentDate, pd.CreatedDate) AS TxnDate, s.SaleId, s.SaleNo,
               ISNULL(NULLIF(s.CustomerName, N''), N'Walk-in') AS CustomerName,
               CASE WHEN pd.Notes LIKE N'Pharmacy credit collection%' THEN N'Credit collection' ELSE N'Bill payment' END AS EntryType,
               UPPER(pm.MethodCode) AS Mode, pm.MethodName, COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''), pd.ChequeNo) AS Reference,
               pd.PaidAmount AS Amount, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = pd.CreatedBy) AS UserName, pd.CreatedBy
          FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
          JOIN dbo.PhSale s ON s.SaleId = ph.ModuleRefId JOIN dbo.BranchMaster b ON b.BranchID = s.BranchId
         WHERE RTRIM(ph.ModuleCode) = 'PHR' AND pd.IsActive = 1 AND s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId)
        UNION ALL
        SELECT 1000000000 + r.RefundId, b.BranchCode, c.CancellationNo, r.RefundDate, s.SaleId, s.SaleNo, ISNULL(NULLIF(s.CustomerName, N''), N'Walk-in'),
               CASE WHEN c.CancellationType = 'F' THEN N'Refund - bill cancelled' ELSE N'Refund - sale return' END,
               UPPER(r.RefundMode), ISNULL(pm.MethodName, r.RefundMode), r.TransactionRef, -r.RefundAmount,
               (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = r.CreatedBy), r.CreatedBy
          FROM dbo.BillRefund r JOIN dbo.PhSale s ON s.SaleId = r.ModuleRefId JOIN dbo.BranchMaster b ON b.BranchID = s.BranchId
          LEFT JOIN dbo.BillCancellation c ON c.CancellationId = r.CancellationId
          LEFT JOIN dbo.PaymentMethodMaster pm ON UPPER(pm.MethodCode) = UPPER(r.RefundMode)
         WHERE r.ModuleCode = 'PHR' AND r.IsActive = 1 AND s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId)) x
     WHERE x.TxnDate >= @From AND x.TxnDate < @end AND (@UserId IS NULL OR x.CreatedBy = @UserId) AND (@Mode IS NULL OR x.Mode = @Mode)
       AND (@Search IS NULL OR x.DocNo LIKE @like OR x.SaleNo LIKE @like OR x.CustomerName LIKE @like OR x.Reference LIKE @like);

    SELECT ISNULL(SUM(CASE WHEN Mode = 'CASH' AND Amount > 0 THEN Amount END), 0) AS Cash, ISNULL(SUM(CASE WHEN Mode = 'CARD' AND Amount > 0 THEN Amount END), 0) AS Card,
           ISNULL(SUM(CASE WHEN Mode = 'UPI' AND Amount > 0 THEN Amount END), 0) AS Upi, ISNULL(SUM(CASE WHEN Mode IN ('NEFT', 'CHEQUE') AND Amount > 0 THEN Amount END), 0) AS Other,
           ISNULL(SUM(CASE WHEN Amount < 0 THEN -Amount END), 0) AS Refunds, ISNULL(SUM(Amount), 0) AS Net
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Amount) AS Amount FROM #R;
END
GO

-- ── S5 User-wise Sales: counter performance and cash accountability ─────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_UserSales
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT u AS UserId, SUM(Bills) Bills, SUM(Sales) Sales, SUM(Discount) Discount, SUM(Returns) Returns, SUM(ReturnValue) ReturnValue,
           SUM(Cancelled) Cancelled, SUM(CancelledValue) CancelledValue, SUM(Cash) Cash, SUM(NonCash) NonCash
      INTO #G FROM (
        SELECT s.CreatedBy u, COUNT(*) Bills, SUM(s.NetAmount) Sales, SUM(s.DiscountAmount) Discount, 0 Returns, 0 ReturnValue, 0 Cancelled, 0 CancelledValue, 0 Cash, 0 NonCash
          FROM dbo.PhSale s WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED' AND s.SaleDate >= @From AND s.SaleDate < @end
         GROUP BY s.CreatedBy
        UNION ALL
        SELECT r.CreatedBy, 0, 0, 0, COUNT(*), SUM(r.NetAmount), 0, 0, 0, 0
          FROM dbo.PhSaleReturn r WHERE r.CompanyId = @CompanyId AND (@BranchId IS NULL OR r.BranchId = @BranchId) AND r.ReturnDate >= @From AND r.ReturnDate < @end
         GROUP BY r.CreatedBy
        UNION ALL
        SELECT s.CancelledBy, 0, 0, 0, 0, 0, COUNT(*), SUM(s.NetAmount), 0, 0
          FROM dbo.PhSale s WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'CANCELLED' AND s.CancelledDate >= @From AND s.CancelledDate < @end
         GROUP BY s.CancelledBy
        UNION ALL
        SELECT pd.CreatedBy, 0, 0, 0, 0, 0, 0, 0, SUM(CASE WHEN UPPER(pm.MethodCode) = 'CASH' THEN pd.PaidAmount ELSE 0 END), SUM(CASE WHEN UPPER(pm.MethodCode) <> 'CASH' THEN pd.PaidAmount ELSE 0 END)
          FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
          JOIN dbo.PhSale s ON s.SaleId = ph.ModuleRefId
         WHERE RTRIM(ph.ModuleCode) = 'PHR' AND pd.IsActive = 1 AND s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId)
           AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @From AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @end
         GROUP BY pd.CreatedBy) x
     WHERE (@UserId IS NULL OR u = @UserId)
     GROUP BY u;
    SELECT ROW_NUMBER() OVER (ORDER BY g.Sales DESC) AS Rn, g.*, ISNULL(NULLIF(us.FullName, ''), ISNULL(us.Username, N'Not recorded')) AS UserName,
           CASE WHEN g.Bills = 0 THEN 0 ELSE g.Sales / g.Bills END AS AvgBill
      INTO #R FROM #G g LEFT JOIN dbo.Users us ON us.Id = g.UserId;

    SELECT COUNT(*) AS Users, ISNULL(SUM(Bills), 0) AS Bills, ISNULL(SUM(Sales), 0) AS Sales, ISNULL(SUM(Discount), 0) AS Discount,
           ISNULL(SUM(ReturnValue), 0) AS ReturnValue, ISNULL(SUM(CancelledValue), 0) AS CancelledValue
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Bills) AS Bills, SUM(Sales) AS Sales, SUM(Discount) AS Discount, SUM(Returns) AS Returns, SUM(ReturnValue) AS ReturnValue,
           SUM(Cancelled) AS Cancelled, SUM(CancelledValue) AS CancelledValue, SUM(Cash) AS Cash, SUM(NonCash) AS NonCash,
           CASE WHEN ISNULL(SUM(Bills), 0) = 0 THEN 0 ELSE SUM(Sales) / SUM(Bills) END AS AvgBill
      FROM #R;
END
GO

-- ── S6 Sale Return Register: line by line (@Search also matches the reason; @Mode = refund mode) ──────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_SaleReturns
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT ROW_NUMBER() OVER (ORDER BY r.ReturnDate, r.ReturnId, rd.ReturnDtlId) AS Rn, r.ReturnId, b.BranchCode, r.ReturnNo, r.ReturnDate, s.SaleId, s.SaleNo, s.SaleDate,
           ISNULL(NULLIF(s.CustomerName, N''), N'Walk-in') AS CustomerName, i.ItemName, bt.BatchNo, rd.Qty, su.UomCode AS SaleUom, rd.Amount,
           CASE r.RefundMode WHEN 'ADJUST' THEN N'Adjusted in dues' ELSE r.RefundMode END AS RefundMode, rs.ReasonName,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = r.CreatedBy) AS UserName,
           CASE WHEN rd.ReturnDtlId = (SELECT MIN(x.ReturnDtlId) FROM dbo.PhSaleReturnDtl x WHERE x.ReturnId = r.ReturnId) THEN r.RefundAmount ELSE 0 END AS RefundAmount,
           CASE WHEN rd.ReturnDtlId = (SELECT MIN(x.ReturnDtlId) FROM dbo.PhSaleReturnDtl x WHERE x.ReturnId = r.ReturnId) THEN r.AdjustedAmount ELSE 0 END AS AdjustedAmount
      INTO #R
      FROM dbo.PhSaleReturnDtl rd JOIN dbo.PhSaleReturn r ON r.ReturnId = rd.ReturnId JOIN dbo.PhSale s ON s.SaleId = r.SaleId
      JOIN dbo.PhItem i ON i.ItemId = rd.ItemId JOIN dbo.PhBatch bt ON bt.BatchId = rd.BatchId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      JOIN dbo.BranchMaster b ON b.BranchID = r.BranchId LEFT JOIN dbo.PhReason rs ON rs.ReasonId = r.ReasonId
     WHERE r.CompanyId = @CompanyId AND (@BranchId IS NULL OR r.BranchId = @BranchId) AND r.ReturnDate >= @From AND r.ReturnDate < @end
       AND (@UserId IS NULL OR r.CreatedBy = @UserId) AND (@Mode IS NULL OR r.RefundMode = @Mode)
       AND (@Search IS NULL OR r.ReturnNo LIKE @like OR s.SaleNo LIKE @like OR s.CustomerName LIKE @like OR i.ItemName LIKE @like OR rs.ReasonName LIKE @like);

    SELECT COUNT(DISTINCT ReturnId) AS Returns, COUNT(*) AS Lines, ISNULL(SUM(Amount), 0) AS Value, ISNULL(SUM(RefundAmount), 0) AS Refunded, ISNULL(SUM(AdjustedAmount), 0) AS Adjusted
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(Amount) AS Amount, SUM(RefundAmount) AS RefundAmount, SUM(AdjustedAmount) AS AdjustedAmount FROM #R;
END
GO

-- ── S7 Bill Cancellation Register (by the day the bill was cancelled) ───────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_Cancellations
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT ROW_NUMBER() OVER (ORDER BY s.CancelledDate, s.SaleId) AS Rn, s.SaleId, b.BranchCode, s.SaleNo, s.SaleDate, s.CancelledDate,
           DATEDIFF(MINUTE, s.SaleDate, s.CancelledDate) AS MinutesAfter, ISNULL(NULLIF(s.CustomerName, N''), N'Walk-in') AS CustomerName,
           (SELECT COUNT(*) FROM dbo.PhSaleDtl d WHERE d.SaleId = s.SaleId) AS Items, s.NetAmount,
           ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.BillRefund r WHERE r.ModuleCode = 'PHR' AND r.ModuleRefId = s.SaleId AND r.IsActive = 1
                    AND r.CancellationId IN (SELECT CancellationId FROM dbo.BillCancellation WHERE ModuleCode = 'PHR' AND ModuleRefId = s.SaleId AND CancellationType = 'F')), 0) AS Refunded,
           s.CancelReason, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = s.CreatedBy) AS BilledBy,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = s.CancelledBy) AS CancelledBy
      INTO #R
      FROM dbo.PhSale s JOIN dbo.BranchMaster b ON b.BranchID = s.BranchId
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'CANCELLED' AND s.CancelledDate >= @From AND s.CancelledDate < @end
       AND (@UserId IS NULL OR s.CancelledBy = @UserId)
       AND (@Search IS NULL OR s.SaleNo LIKE @like OR s.CustomerName LIKE @like OR s.CancelReason LIKE @like);

    SELECT COUNT(*) AS Bills, ISNULL(SUM(NetAmount), 0) AS Value, ISNULL(SUM(Refunded), 0) AS Refunded,
           CASE WHEN COUNT(*) = 0 THEN 0 ELSE AVG(CAST(MinutesAfter AS DECIMAL(18,2))) END AS AvgMinutes
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Items) AS Items, SUM(NetAmount) AS NetAmount, SUM(Refunded) AS Refunded FROM #R;
END
GO

-- ── S8 Discount Register: bills with a discount; above the counter limit = the DISCOUNT permission was used (@Option ABOVE) ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_Discounts
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT s.SaleId, b.BranchCode, s.SaleNo, s.SaleDate, ISNULL(NULLIF(s.CustomerName, N''), N'Walk-in') AS CustomerName,
           CASE s.CustomerKind WHEN 'PATIENT' THEN N'Patient' WHEN 'CUSTOMER' THEN N'Credit customer' ELSE N'Walk-in' END AS CustomerType,
           s.BillDiscPercent, ISNULL((SELECT MAX(d.DiscPercent) FROM dbo.PhSaleDtl d WHERE d.SaleId = s.SaleId), 0) AS MaxLineDisc,
           s.MrpAmount, s.DiscountAmount, CASE WHEN s.MrpAmount = 0 THEN 0 ELSE s.DiscountAmount * 100 / s.MrpAmount END AS DiscPctOfMrp, s.NetAmount,
           ISNULL((SELECT TOP 1 PharmacyMaxManualDiscountPercent FROM dbo.HospitalSettings WHERE BranchId = s.BranchId ORDER BY IsActive DESC), 10) AS CounterLimit,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = s.CreatedBy) AS UserName
      INTO #G
      FROM dbo.PhSale s JOIN dbo.BranchMaster b ON b.BranchID = s.BranchId
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED' AND s.SaleDate >= @From AND s.SaleDate < @end
       AND s.DiscountAmount > 0 AND (@UserId IS NULL OR s.CreatedBy = @UserId) AND (@Kind IS NULL OR s.CustomerKind = @Kind)
       AND (@Search IS NULL OR s.SaleNo LIKE @like OR s.CustomerName LIKE @like);
    SELECT ROW_NUMBER() OVER (ORDER BY SaleDate, SaleId) AS Rn, *,
           CASE WHEN MaxLineDisc > CounterLimit THEN N'Yes' ELSE N'' END AS AboveLimit
      INTO #R FROM #G
     WHERE @Option IS NULL OR @Option <> 'ABOVE' OR MaxLineDisc > CounterLimit;

    SELECT COUNT(*) AS Bills, ISNULL(SUM(DiscountAmount), 0) AS Discount, ISNULL(SUM(MrpAmount), 0) AS MrpValue,
           CASE WHEN ISNULL(SUM(MrpAmount), 0) = 0 THEN 0 ELSE SUM(DiscountAmount) * 100 / SUM(MrpAmount) END AS DiscPct,
           ISNULL(SUM(CASE WHEN AboveLimit = N'Yes' THEN 1 ELSE 0 END), 0) AS AboveLimit
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(MrpAmount) AS MrpAmount, SUM(DiscountAmount) AS DiscountAmount, SUM(NetAmount) AS NetAmount,
           CASE WHEN ISNULL(SUM(MrpAmount), 0) = 0 THEN 0 ELSE SUM(DiscountAmount) * 100 / SUM(MrpAmount) END AS DiscPctOfMrp
      FROM #R;
END
GO

-- ── S9 Doctor-wise Prescription Sales (no incentive figures) ─────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_DoctorSales
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT s.SaleId, s.NetAmount, s.RxNo, s.DoctorRegNo, s.PatientId, s.CustomerId, s.Mobile, s.CustomerName,
           ISNULL(NULLIF(LTRIM(RTRIM(s.DoctorName)), N''), N'(no doctor)') AS Doctor
      INTO #B FROM dbo.PhSale s
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED' AND s.SaleDate >= @From AND s.SaleDate < @end
       AND (@UserId IS NULL OR s.CreatedBy = @UserId) AND (@Search IS NULL OR s.DoctorName LIKE @like)
       AND (@Option = 'ALL' OR NULLIF(LTRIM(RTRIM(s.DoctorName)), N'') IS NOT NULL);
    -- top 3 items of each doctor by value
    WITH it AS (
        SELECT b.Doctor, i.ItemName, SUM(d.Amount) AS V, ROW_NUMBER() OVER (PARTITION BY b.Doctor ORDER BY SUM(d.Amount) DESC) AS k
          FROM #B b JOIN dbo.PhSaleDtl d ON d.SaleId = b.SaleId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
         GROUP BY b.Doctor, i.ItemName)
    SELECT Doctor, STRING_AGG(ItemName, N', ') WITHIN GROUP (ORDER BY k) AS TopItems INTO #T FROM it WHERE k <= 3 GROUP BY Doctor;
    SELECT ROW_NUMBER() OVER (ORDER BY SUM(b.NetAmount) DESC) AS Rn, b.Doctor, MAX(b.DoctorRegNo) AS RegNo, COUNT(*) AS Bills,
           COUNT(DISTINCT COALESCE('P' + CAST(b.PatientId AS VARCHAR(12)), 'C' + CAST(b.CustomerId AS VARCHAR(12)), 'M' + NULLIF(b.Mobile, ''), 'N' + b.CustomerName)) AS Customers,
           SUM(CASE WHEN NULLIF(b.RxNo, N'') IS NOT NULL THEN 1 ELSE 0 END) AS RxBills, SUM(b.NetAmount) AS Value, SUM(b.NetAmount) / COUNT(*) AS AvgBill, MAX(t.TopItems) AS TopItems
      INTO #R FROM #B b LEFT JOIN #T t ON t.Doctor = b.Doctor GROUP BY b.Doctor;

    SELECT COUNT(*) AS Doctors, ISNULL(SUM(Bills), 0) AS Bills, ISNULL(SUM(Value), 0) AS Value, ISNULL(SUM(RxBills), 0) AS RxBills FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Bills) AS Bills, SUM(Customers) AS Customers, SUM(RxBills) AS RxBills, SUM(Value) AS Value,
           CASE WHEN ISNULL(SUM(Bills), 0) = 0 THEN 0 ELSE SUM(Value) / SUM(Bills) END AS AvgBill
      FROM #R;
END
GO

-- ── S10 Patient / Customer-wise Purchase History ─────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_CustomerHistory
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT s.SaleId, s.SaleNo, s.SaleDate, s.NetAmount, s.CustomerKind,
           CASE s.CustomerKind WHEN 'PATIENT' THEN 'P' + CAST(s.PatientId AS VARCHAR(12)) WHEN 'CUSTOMER' THEN 'C' + CAST(s.CustomerId AS VARCHAR(12))
                ELSE ISNULL('M' + NULLIF(s.Mobile, N''), 'W') END AS CustKey,
           CASE WHEN s.CustomerKind = 'WALKIN' AND NULLIF(s.Mobile, N'') IS NULL THEN N'Walk-in (no mobile)' ELSE ISNULL(NULLIF(s.CustomerName, N''), N'Walk-in') END AS CustomerName,
           CASE s.CustomerKind WHEN 'PATIENT' THEN N'Patient' WHEN 'CUSTOMER' THEN N'Credit customer' ELSE N'Walk-in' END AS CustomerType,
           pm.PatientCode, s.Mobile
      INTO #B
      FROM dbo.PhSale s LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = s.PatientId
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED' AND s.SaleDate >= @From AND s.SaleDate < @end
       AND (@Kind IS NULL OR s.CustomerKind = @Kind)
       AND (@Search IS NULL OR s.CustomerName LIKE @like OR s.Mobile LIKE @like OR pm.PatientCode LIKE @like);
    SELECT ROW_NUMBER() OVER (ORDER BY SUM(b.NetAmount) DESC) AS Rn, b.CustKey, MAX(b.CustomerName) AS CustomerName, MAX(b.CustomerType) AS CustomerType,
           MAX(b.PatientCode) AS PatientCode, MAX(b.Mobile) AS Mobile, COUNT(*) AS Bills,
           (SELECT COUNT(DISTINCT d.ItemId) FROM dbo.PhSaleDtl d JOIN #B x ON x.SaleId = d.SaleId WHERE x.CustKey = b.CustKey) AS Items,
           SUM(b.NetAmount) AS Value, MIN(b.SaleDate) AS FirstPurchase, MAX(b.SaleDate) AS LastPurchase,
           (SELECT TOP 1 x.SaleNo FROM #B x WHERE x.CustKey = b.CustKey ORDER BY x.SaleDate DESC) AS LastBillNo,
           DATEDIFF(DAY, MAX(b.SaleDate), GETDATE()) AS DaysSince
      INTO #R FROM #B b GROUP BY b.CustKey;

    SELECT COUNT(*) AS Customers, ISNULL(SUM(Bills), 0) AS Bills, ISNULL(SUM(Value), 0) AS Value,
           ISNULL(SUM(CASE WHEN Bills > 1 THEN 1 ELSE 0 END), 0) AS Repeat
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Bills) AS Bills, SUM(Value) AS Value FROM #R;
END
GO

-- ── S11 Credit Sales & Outstanding Ageing: today's dues of credit customers, aged from the bill date ──────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_CreditAgeing
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE);
    SELECT ROW_NUMBER() OVER (ORDER BY SUM(s.BalanceDue) DESC) AS Rn, c.CustomerId, c.CustomerName, c.Mobile, c.CreditLimit, COUNT(*) AS Bills,
           SUM(s.BalanceDue) AS Outstanding,
           SUM(CASE WHEN DATEDIFF(DAY, s.SaleDate, @today) <= 30 THEN s.BalanceDue ELSE 0 END) AS D0_30,
           SUM(CASE WHEN DATEDIFF(DAY, s.SaleDate, @today) BETWEEN 31 AND 60 THEN s.BalanceDue ELSE 0 END) AS D31_60,
           SUM(CASE WHEN DATEDIFF(DAY, s.SaleDate, @today) BETWEEN 61 AND 90 THEN s.BalanceDue ELSE 0 END) AS D61_90,
           SUM(CASE WHEN DATEDIFF(DAY, s.SaleDate, @today) > 90 THEN s.BalanceDue ELSE 0 END) AS D90,
           MIN(s.SaleDate) AS OldestBill, CASE WHEN SUM(s.BalanceDue) > c.CreditLimit THEN N'Over limit' ELSE N'' END AS OverLimit
      INTO #R
      FROM dbo.PhSale s JOIN dbo.PhCustomer c ON c.CustomerId = s.CustomerId
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED' AND s.BalanceDue > 0
       AND (@Search IS NULL OR c.CustomerName LIKE @like OR c.Mobile LIKE @like)
     GROUP BY c.CustomerId, c.CustomerName, c.Mobile, c.CreditLimit;
    DELETE #R WHERE @Option = 'OVER' AND OverLimit = N'';

    SELECT COUNT(*) AS Customers, ISNULL(SUM(Outstanding), 0) AS Outstanding, ISNULL(SUM(D61_90 + D90), 0) AS Over60, ISNULL(SUM(D90), 0) AS Over90,
           ISNULL(SUM(CASE WHEN OverLimit <> N'' THEN 1 ELSE 0 END), 0) AS OverLimit
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(CreditLimit) AS CreditLimit, SUM(Bills) AS Bills, SUM(Outstanding) AS Outstanding, SUM(D0_30) AS D0_30, SUM(D31_60) AS D31_60,
           SUM(D61_90) AS D61_90, SUM(D90) AS D90
      FROM #R;
END
GO

-- ── S12 Hourly Sales Pattern: hour of day × weekday (@Option VALUE = sales value, else number of bills) ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_HourlyPattern
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET DATEFIRST 1;
    DECLARE @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME)), @value BIT = CASE WHEN @Option = 'VALUE' THEN 1 ELSE 0 END;
    SELECT DATEPART(HOUR, s.SaleDate) AS H, DATEPART(WEEKDAY, s.SaleDate) AS W, CASE WHEN @value = 1 THEN s.NetAmount ELSE 1 END AS V, s.NetAmount
      INTO #B FROM dbo.PhSale s
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED' AND s.SaleDate >= @From AND s.SaleDate < @end
       AND (@UserId IS NULL OR s.CreatedBy = @UserId);
    -- the opening hours of a pharmacy counter, plus any other hour that had a sale
    SELECT h.H AS Hour, ROW_NUMBER() OVER (ORDER BY h.H) AS Rn,
           RIGHT('0' + CAST(h.H AS VARCHAR(2)), 2) + ':00 - ' + RIGHT('0' + CAST((h.H + 1) % 24 AS VARCHAR(2)), 2) + ':00' AS HourLabel,
           ISNULL(SUM(CASE WHEN b.W = 1 THEN b.V END), 0) AS Mon, ISNULL(SUM(CASE WHEN b.W = 2 THEN b.V END), 0) AS Tue, ISNULL(SUM(CASE WHEN b.W = 3 THEN b.V END), 0) AS Wed,
           ISNULL(SUM(CASE WHEN b.W = 4 THEN b.V END), 0) AS Thu, ISNULL(SUM(CASE WHEN b.W = 5 THEN b.V END), 0) AS Fri, ISNULL(SUM(CASE WHEN b.W = 6 THEN b.V END), 0) AS Sat,
           ISNULL(SUM(CASE WHEN b.W = 7 THEN b.V END), 0) AS Sun, ISNULL(SUM(b.V), 0) AS Total
      INTO #R
      FROM (SELECT v AS H FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15),(16),(17),(18),(19),(20),(21),(22),(23)) t (v)) h
      LEFT JOIN #B b ON b.H = h.H
     WHERE h.H BETWEEN 7 AND 22 OR EXISTS (SELECT 1 FROM #B x WHERE x.H = h.H)
     GROUP BY h.H;

    SELECT (SELECT COUNT(*) FROM #B) AS Bills, ISNULL((SELECT SUM(NetAmount) FROM #B), 0) AS Value,
           (SELECT TOP 1 HourLabel FROM #R WHERE Total > 0 ORDER BY Total DESC) AS BusiestHour,
           (SELECT TOP 1 CASE W WHEN 1 THEN N'Monday' WHEN 2 THEN N'Tuesday' WHEN 3 THEN N'Wednesday' WHEN 4 THEN N'Thursday' WHEN 5 THEN N'Friday' WHEN 6 THEN N'Saturday' ELSE N'Sunday' END
              FROM #B GROUP BY W ORDER BY SUM(V) DESC) AS BusiestDay;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Mon) AS Mon, SUM(Tue) AS Tue, SUM(Wed) AS Wed, SUM(Thu) AS Thu, SUM(Fri) AS Fri, SUM(Sat) AS Sat, SUM(Sun) AS Sun, SUM(Total) AS Total FROM #R;
END
GO

-- ── menu: Reports > Pharmacy, one page per report (VIEW, EXPORT) ─────────────────────────────────
DECLARE @Pages TABLE (Code NVARCHAR(100), Title NVARCHAR(150), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT @Pages VALUES
 (N'REPORTS.PHARMACY.SALESREGISTER',  N'Daily Sales Register',             N'SalesRegister',   10,  N'bi bi-receipt me-2'),
 (N'REPORTS.PHARMACY.SALESSUMMARY',   N'Sales Summary',                    N'SalesSummary',    20,  N'bi bi-graph-up me-2'),
 (N'REPORTS.PHARMACY.ITEMSALES',      N'Item-wise Sales',                  N'ItemSales',       30,  N'bi bi-capsule me-2'),
 (N'REPORTS.PHARMACY.COLLECTIONS',    N'Payment-mode Collection Register', N'Collections',     40,  N'bi bi-cash-coin me-2'),
 (N'REPORTS.PHARMACY.USERSALES',      N'User / Shift-wise Sales',          N'UserSales',       50,  N'bi bi-person-badge me-2'),
 (N'REPORTS.PHARMACY.SALERETURNS',    N'Sale Return Register',             N'SaleReturns',     60,  N'bi bi-arrow-counterclockwise me-2'),
 (N'REPORTS.PHARMACY.CANCELLATIONS',  N'Bill Cancellation Register',       N'Cancellations',   70,  N'bi bi-x-octagon me-2'),
 (N'REPORTS.PHARMACY.DISCOUNTS',      N'Discount Register',                N'Discounts',       80,  N'bi bi-percent me-2'),
 (N'REPORTS.PHARMACY.DOCTORSALES',    N'Doctor-wise Prescription Sales',   N'DoctorSales',     90,  N'bi bi-prescription2 me-2'),
 (N'REPORTS.PHARMACY.CUSTOMERHISTORY',N'Customer-wise Purchase History',  N'CustomerHistory', 100, N'bi bi-people me-2'),
 (N'REPORTS.PHARMACY.CREDITAGEING',   N'Credit Outstanding & Ageing',     N'CreditAgeing',    110, N'bi bi-hourglass-split me-2'),
 (N'REPORTS.PHARMACY.HOURLYPATTERN',  N'Hourly Sales Pattern',            N'HourlyPattern',   120, N'bi bi-clock-history me-2');

DECLARE @co INT, @reports INT, @ph INT, @page INT, @view INT, @exp INT, @pc NVARCHAR(100), @title NVARCHAR(150), @action NVARCHAR(100), @sort INT, @icon NVARCHAR(100);
DECLARE co CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS';
OPEN co; FETCH NEXT FROM co INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @reports = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS' AND CompanyId = @co;
    SET @ph = NULL;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @reports, @Menu_Type = 'MENU', @Menu_Code = N'REPORTS.PHARMACY', @Title = N'Pharmacy',
         @Icon = N'bi bi-capsule-pill me-2', @Sort_Order = 25, @UserId = NULL, @Menu_ID = @ph OUTPUT;
    -- reports sit directly under Reports > Pharmacy, as under LAB / OPD: remove the earlier hub page and Sales sub-menu
    DECLARE @old TABLE (Page_ID INT);
    INSERT @old SELECT p.Page_ID FROM dbo.PageMaster p JOIN dbo.MenuMaster m ON m.Menu_ID = p.Menu_ID
     WHERE m.CompanyId = @co AND p.Page_Code = N'REPORTS.PHARMACY.HUB';
    DELETE FROM dbo.PageEndpointMap WHERE Page_ID IN (SELECT Page_ID FROM @old);
    DELETE FROM dbo.RolePermission WHERE Page_ID IN (SELECT Page_ID FROM @old) OR Control_ID IN (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID IN (SELECT Page_ID FROM @old));
    DELETE FROM dbo.UserPermission WHERE Page_ID IN (SELECT Page_ID FROM @old) OR Control_ID IN (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID IN (SELECT Page_ID FROM @old));
    DELETE FROM dbo.PageControlMaster WHERE Page_ID IN (SELECT Page_ID FROM @old);
    DELETE FROM dbo.PageMaster WHERE Page_ID IN (SELECT Page_ID FROM @old);
    UPDATE p SET Menu_ID = @ph FROM dbo.PageMaster p JOIN dbo.MenuMaster m ON m.Menu_ID = p.Menu_ID WHERE m.CompanyId = @co AND m.Menu_Code = N'REPORTS.PHARMACY.SALES';
    DELETE FROM dbo.RolePermission WHERE Menu_ID IN (SELECT Menu_ID FROM dbo.MenuMaster WHERE CompanyId = @co AND Menu_Code = N'REPORTS.PHARMACY.SALES');
    DELETE FROM dbo.UserPermission WHERE Menu_ID IN (SELECT Menu_ID FROM dbo.MenuMaster WHERE CompanyId = @co AND Menu_Code = N'REPORTS.PHARMACY.SALES');
    DELETE FROM dbo.MenuMaster WHERE CompanyId = @co AND Menu_Code = N'REPORTS.PHARMACY.SALES';

    DECLARE p CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Action, Sort, Icon FROM @Pages;
    OPEN p; FETCH NEXT FROM p INTO @pc, @title, @action, @sort, @icon;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @ph, @Page_Code = @pc, @Title = @title, @Controller = N'PhReports', @Action = @action,
             @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        SET @exp = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EXPORT', @Title = N'Export to Excel / PDF', @Sort_Order = 20, @Control_ID = @exp OUTPUT;
        DECLARE @a1 NVARCHAR(100) = @action, @a2 NVARCHAR(100) = @action + N'Data', @a3 NVARCHAR(100) = @action + N'Export';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @a1, @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @a2, @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @exp, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @a3, @Source = 'SEED';
        FETCH NEXT FROM p INTO @pc, @title, @action, @sort, @icon;
    END
    CLOSE p; DEALLOCATE p;
    FETCH NEXT FROM co INTO @co;
END
CLOSE co; DEALLOCATE co;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2361 applied: Reports > Pharmacy, sales reports (S1-S12): report procedures, indexes, menu and pages.';
GO
