-- ============================================================================================================
-- Migration: 2362_pharmacy_reports_purchase.sql
-- Reports > Pharmacy, purchase reports (P1-P9 of the Pharmacy Reports plan), read through EMR.Api.
--   Same contract as 2360: common parameters; result sets 1 tiles · 2 the page of rows (@PageSize 0 = all) · 3 totals + TotalRows.
--   Only posted documents count (draft GRNs / returns / payments are left out); POs count once approved.
--   Menu: one page per report directly under Reports > Pharmacy (after the sales reports), VIEW and EXPORT. No grants.
-- Run after 2361. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhGrnDtl_Grn' AND object_id = OBJECT_ID('dbo.PhGrnDtl'))
    CREATE INDEX IX_PhGrnDtl_Grn ON dbo.PhGrnDtl (GrnId) INCLUDE (ItemId, Qty, FreeQty, Rate, TaxableAmount, GstAmount, Mrp);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhGrnDtl_Item' AND object_id = OBJECT_ID('dbo.PhGrnDtl'))
    CREATE INDEX IX_PhGrnDtl_Item ON dbo.PhGrnDtl (ItemId) INCLUDE (GrnId, Rate, Mrp, Qty);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhSupplierPaymentAlloc_Grn' AND object_id = OBJECT_ID('dbo.PhSupplierPaymentAlloc'))
    CREATE INDEX IX_PhSupplierPaymentAlloc_Grn ON dbo.PhSupplierPaymentAlloc (GrnId) INCLUDE (PaymentId, Amount);
GO

-- ── P1 Purchase Register (GRN-wise) ─────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_PurchaseRegister
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT ROW_NUMBER() OVER (ORDER BY g.GrnDate, g.GrnId) AS Rn, g.GrnId, b.BranchCode, g.GrnNo, g.GrnDate, s.SupplierName, s.Gstin, g.InvoiceNo, g.InvoiceDate,
           po.PoNo, (SELECT COUNT(*) FROM dbo.PhGrnDtl d WHERE d.GrnId = g.GrnId) AS Lines, g.GrossAmount, g.DiscountAmount, g.TaxableAmount,
           g.CgstAmount, g.SgstAmount, g.IgstAmount, g.OtherCharges, g.RoundOff, g.NetAmount, g.DueDate,
           ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment p ON p.PaymentId = a.PaymentId
                    WHERE a.GrnId = g.GrnId AND p.Status = 'POSTED'), 0) AS Paid
      INTO #R
      FROM dbo.PhGrn g JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId JOIN dbo.BranchMaster b ON b.BranchID = g.BranchId
      LEFT JOIN dbo.PhPurchaseOrder po ON po.PoId = g.PoId
     WHERE g.CompanyId = @CompanyId AND (@BranchId IS NULL OR g.BranchId = @BranchId) AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @From AND @To
       AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId)
       AND (@Search IS NULL OR g.GrnNo LIKE @like OR g.InvoiceNo LIKE @like OR s.SupplierName LIKE @like OR po.PoNo LIKE @like);
    ALTER TABLE #R ADD Balance DECIMAL(18,2);
    UPDATE #R SET Balance = NetAmount - Paid;

    SELECT COUNT(*) AS Grns, COUNT(DISTINCT SupplierName) AS Suppliers, ISNULL(SUM(TaxableAmount), 0) AS Taxable,
           ISNULL(SUM(CgstAmount + SgstAmount + IgstAmount), 0) AS Gst, ISNULL(SUM(NetAmount), 0) AS Net, ISNULL(SUM(Balance), 0) AS Balance
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Lines) AS Lines, SUM(GrossAmount) AS GrossAmount, SUM(DiscountAmount) AS DiscountAmount, SUM(TaxableAmount) AS TaxableAmount,
           SUM(CgstAmount) AS CgstAmount, SUM(SgstAmount) AS SgstAmount, SUM(IgstAmount) AS IgstAmount, SUM(OtherCharges) AS OtherCharges, SUM(RoundOff) AS RoundOff,
           SUM(NetAmount) AS NetAmount, SUM(Paid) AS Paid, SUM(Balance) AS Balance
      FROM #R;
END
GO

-- ── P2 Item-wise Purchase ───────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_ItemPurchases
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT i.ItemId, i.ItemCode, i.ItemName, ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, m.ManufacturerName, pu.UomCode AS PurchaseUom,
           SUM(d.Qty) AS Qty, SUM(d.FreeQty) AS FreeQty, COUNT(DISTINCT g.GrnId) AS Grns, COUNT(DISTINCT g.SupplierId) AS Suppliers,
           SUM(d.TaxableAmount) AS Taxable, SUM(d.GstAmount) AS Gst, SUM(d.TaxableAmount + d.GstAmount) AS Value,
           MIN(d.Rate) AS MinRate, MAX(d.Rate) AS MaxRate
      INTO #G
      FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
      JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
     WHERE g.CompanyId = @CompanyId AND (@BranchId IS NULL OR g.BranchId = @BranchId) AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @From AND @To
       AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId)
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search)
     GROUP BY i.ItemId, i.ItemCode, i.ItemName, pc.CategoryName, c.CategoryName, m.ManufacturerName, pu.UomCode;
    -- the latest purchase of each item in the period: its rate and supplier
    SELECT ROW_NUMBER() OVER (ORDER BY g.Value DESC, g.ItemName) AS Rn, g.*,
           CASE WHEN g.Qty = 0 THEN 0 ELSE g.Taxable / g.Qty END AS AvgRate,
           CASE WHEN g.Qty + g.FreeQty = 0 THEN 0 ELSE g.Taxable / (g.Qty + g.FreeQty) END AS EffRate,
           l.Rate AS LastRate, l.SupplierName AS LastSupplier, l.GrnDate AS LastDate
      INTO #R FROM #G g
     OUTER APPLY (SELECT TOP 1 d.Rate, s.SupplierName, x.GrnDate FROM dbo.PhGrnDtl d JOIN dbo.PhGrn x ON x.GrnId = d.GrnId JOIN dbo.PhSupplier s ON s.SupplierId = x.SupplierId
                   WHERE d.ItemId = g.ItemId AND x.CompanyId = @CompanyId AND (@BranchId IS NULL OR x.BranchId = @BranchId) AND x.Status = 'POSTED'
                     AND x.GrnDate BETWEEN @From AND @To AND (@SupplierId IS NULL OR x.SupplierId = @SupplierId)
                   ORDER BY x.GrnDate DESC, d.GrnDtlId DESC) l;

    SELECT COUNT(*) AS Items, ISNULL(SUM(Qty), 0) AS Qty, ISNULL(SUM(FreeQty), 0) AS FreeQty, ISNULL(SUM(Taxable), 0) AS Taxable, ISNULL(SUM(Value), 0) AS Value FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(FreeQty) AS FreeQty, SUM(Grns) AS Grns, SUM(Taxable) AS Taxable, SUM(Gst) AS Gst, SUM(Value) AS Value FROM #R;
END
GO

-- ── P3 Supplier-wise Purchase Summary ───────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_SupplierPurchases
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT x.SupplierId, SUM(x.Grns) AS Grns, SUM(x.Taxable) AS Taxable, SUM(x.Gst) AS Gst, SUM(x.Purchases) AS Purchases, SUM(x.Returns) AS Returns, SUM(x.ReturnDocs) AS ReturnDocs,
           SUM(x.Paid) AS Paid
      INTO #G FROM (
        SELECT g.SupplierId, COUNT(*) Grns, SUM(g.TaxableAmount) Taxable, SUM(g.CgstAmount + g.SgstAmount + g.IgstAmount) Gst, SUM(g.NetAmount) Purchases, 0 Returns, 0 ReturnDocs, 0 Paid
          FROM dbo.PhGrn g WHERE g.CompanyId = @CompanyId AND (@BranchId IS NULL OR g.BranchId = @BranchId) AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @From AND @To
         GROUP BY g.SupplierId
        UNION ALL
        SELECT r.SupplierId, 0, 0, 0, 0, SUM(r.NetAmount), COUNT(*), 0
          FROM dbo.PhPurchaseReturn r WHERE r.CompanyId = @CompanyId AND (@BranchId IS NULL OR r.BranchId = @BranchId) AND r.Status = 'POSTED' AND r.ReturnDate BETWEEN @From AND @To
         GROUP BY r.SupplierId
        UNION ALL
        SELECT p.SupplierId, 0, 0, 0, 0, 0, 0, SUM(p.Amount)
          FROM dbo.PhSupplierPayment p WHERE p.CompanyId = @CompanyId AND (@BranchId IS NULL OR p.BranchId = @BranchId) AND p.Status = 'POSTED' AND p.PaymentDate BETWEEN @From AND @To
         GROUP BY p.SupplierId) x
     WHERE @SupplierId IS NULL OR x.SupplierId = @SupplierId
     GROUP BY x.SupplierId;
    DECLARE @all DECIMAL(18,2) = (SELECT SUM(Purchases - Returns) FROM #G);
    SELECT ROW_NUMBER() OVER (ORDER BY g.Purchases - g.Returns DESC) AS Rn, g.*, s.SupplierName, s.Gstin, s.City, s.CreditDays,
           g.Purchases - g.Returns AS NetPurchases, CASE WHEN ISNULL(@all, 0) = 0 THEN 0 ELSE (g.Purchases - g.Returns) * 100 / @all END AS SharePct
      INTO #R FROM #G g JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId
     WHERE @Search IS NULL OR s.SupplierName LIKE @like OR s.Gstin LIKE @like OR s.City LIKE @like;

    SELECT COUNT(*) AS Suppliers, ISNULL(SUM(Purchases), 0) AS Purchases, ISNULL(SUM(Returns), 0) AS Returns, ISNULL(SUM(NetPurchases), 0) AS NetPurchases,
           ISNULL(SUM(Paid), 0) AS Paid, (SELECT TOP 1 SupplierName FROM #R ORDER BY NetPurchases DESC) AS TopSupplier
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Grns) AS Grns, SUM(Taxable) AS Taxable, SUM(Gst) AS Gst, SUM(Purchases) AS Purchases, SUM(ReturnDocs) AS ReturnDocs,
           SUM(Returns) AS Returns, SUM(NetPurchases) AS NetPurchases, SUM(SharePct) AS SharePct, SUM(Paid) AS Paid
      FROM #R;
END
GO

-- ── P4 Purchase Return (Debit Note) Register, line by line ──────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_PurchaseReturns
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT ROW_NUMBER() OVER (ORDER BY r.ReturnDate, r.ReturnId, d.ReturnDtlId) AS Rn, r.ReturnId, b.BranchCode, r.ReturnNo, r.ReturnDate, s.SupplierName,
           i.ItemName, bt.BatchNo, bt.ExpiryDate, d.Qty, d.Rate, d.TaxableAmount, d.GstAmount, d.TaxableAmount + d.GstAmount AS Amount, rs.ReasonName,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = r.CreatedBy) AS UserName
      INTO #R
      FROM dbo.PhPurchaseReturnDtl d JOIN dbo.PhPurchaseReturn r ON r.ReturnId = d.ReturnId JOIN dbo.PhSupplier s ON s.SupplierId = r.SupplierId
      JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhBatch bt ON bt.BatchId = d.BatchId JOIN dbo.BranchMaster b ON b.BranchID = r.BranchId
      LEFT JOIN dbo.PhReason rs ON rs.ReasonId = r.ReasonId
     WHERE r.CompanyId = @CompanyId AND (@BranchId IS NULL OR r.BranchId = @BranchId) AND r.Status = 'POSTED' AND r.ReturnDate BETWEEN @From AND @To
       AND (@SupplierId IS NULL OR r.SupplierId = @SupplierId)
       AND (@Search IS NULL OR r.ReturnNo LIKE @like OR s.SupplierName LIKE @like OR i.ItemName LIKE @like OR bt.BatchNo LIKE @like OR rs.ReasonName LIKE @like);

    SELECT COUNT(DISTINCT ReturnId) AS Returns, COUNT(*) AS Lines, COUNT(DISTINCT SupplierName) AS Suppliers, ISNULL(SUM(Amount), 0) AS Value FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(TaxableAmount) AS TaxableAmount, SUM(GstAmount) AS GstAmount, SUM(Amount) AS Amount FROM #R;
END
GO

-- ── P5 Pending Purchase Orders: approved / part-received PO lines not yet fully received (as on today) ─────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_PendingPos
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE);
    SELECT ROW_NUMBER() OVER (ORDER BY ISNULL(p.ExpectedDate, p.PoDate), p.PoId, d.PoDtlId) AS Rn, p.PoId, b.BranchCode, p.PoNo, p.PoDate, s.SupplierName, s.Phone,
           i.ItemName, d.Qty AS Ordered, d.ReceivedQty AS Received, d.Qty - d.ReceivedQty AS Pending, d.Rate,
           ROUND((d.Qty - d.ReceivedQty) * d.Rate * (1 - d.DiscPercent / 100) * (1 + d.GstPercent / 100), 2) AS PendingValue,
           p.ExpectedDate, CASE WHEN p.ExpectedDate < @today THEN DATEDIFF(DAY, p.ExpectedDate, @today) ELSE 0 END AS DaysOverdue,
           DATEDIFF(DAY, p.PoDate, @today) AS AgeDays, CASE p.Status WHEN 'PARTIAL' THEN N'Part received' ELSE N'Approved' END AS Status
      INTO #R
      FROM dbo.PhPurchaseOrderDtl d JOIN dbo.PhPurchaseOrder p ON p.PoId = d.PoId JOIN dbo.PhSupplier s ON s.SupplierId = p.SupplierId
      JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.BranchMaster b ON b.BranchID = p.BranchId
     WHERE p.CompanyId = @CompanyId AND (@BranchId IS NULL OR p.BranchId = @BranchId) AND p.Status IN ('APPROVED', 'PARTIAL') AND ISNULL(p.IsDirect, 0) = 0
       AND d.Qty > d.ReceivedQty AND (@SupplierId IS NULL OR p.SupplierId = @SupplierId)
       AND (@Option IS NULL OR @Option <> 'OVERDUE' OR p.ExpectedDate < @today)
       AND (@Search IS NULL OR p.PoNo LIKE @like OR s.SupplierName LIKE @like OR i.ItemName LIKE @like);

    SELECT COUNT(DISTINCT PoId) AS Pos, COUNT(*) AS Lines, ISNULL(SUM(PendingValue), 0) AS PendingValue,
           COUNT(DISTINCT CASE WHEN DaysOverdue > 0 THEN PoId END) AS OverduePos
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Ordered) AS Ordered, SUM(Received) AS Received, SUM(Pending) AS Pending, SUM(PendingValue) AS PendingValue FROM #R;
END
GO

-- ── P6 Supplier Outstanding & Ageing (as on today, by due date) ─────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_SupplierAgeing
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE);
    -- each posted GRN's unpaid balance (the same as Supplier Payments) and how many days it is past its due date
    SELECT g.SupplierId, g.GrnDate, x.Bal, DATEDIFF(DAY, ISNULL(g.DueDate, g.InvoiceDate), @today) AS DaysOver
      INTO #B
      FROM dbo.PhGrn g
     CROSS APPLY (SELECT g.NetAmount - ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment p ON p.PaymentId = a.PaymentId
                                               WHERE a.GrnId = g.GrnId AND p.Status = 'POSTED'), 0) AS Bal) x
     WHERE g.CompanyId = @CompanyId AND (@BranchId IS NULL OR g.BranchId = @BranchId) AND g.Status = 'POSTED' AND x.Bal > 0
       AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId);
    SELECT ROW_NUMBER() OVER (ORDER BY SUM(b.Bal) DESC) AS Rn, s.SupplierId, s.SupplierName, s.Phone, s.CreditDays, COUNT(*) AS Bills, SUM(b.Bal) AS Outstanding,
           SUM(CASE WHEN b.DaysOver <= 0 THEN b.Bal ELSE 0 END) AS NotDue,
           SUM(CASE WHEN b.DaysOver BETWEEN 1 AND 30 THEN b.Bal ELSE 0 END) AS D1_30,
           SUM(CASE WHEN b.DaysOver BETWEEN 31 AND 60 THEN b.Bal ELSE 0 END) AS D31_60,
           SUM(CASE WHEN b.DaysOver BETWEEN 61 AND 90 THEN b.Bal ELSE 0 END) AS D61_90,
           SUM(CASE WHEN b.DaysOver > 90 THEN b.Bal ELSE 0 END) AS D90,
           SUM(CASE WHEN b.DaysOver > 0 THEN b.Bal ELSE 0 END) AS Overdue, MIN(b.GrnDate) AS OldestBill,
           ISNULL((SELECT SUM(r.NetAmount) FROM dbo.PhPurchaseReturn r WHERE r.SupplierId = s.SupplierId AND r.Status = 'POSTED'
                     AND (@BranchId IS NULL OR r.BranchId = @BranchId)), 0) AS Returns
      INTO #R
      FROM #B b JOIN dbo.PhSupplier s ON s.SupplierId = b.SupplierId
     WHERE @Search IS NULL OR s.SupplierName LIKE @like OR s.Phone LIKE @like
     GROUP BY s.SupplierId, s.SupplierName, s.Phone, s.CreditDays;
    DELETE #R WHERE @Option = 'OVERDUE' AND Overdue = 0;

    SELECT COUNT(*) AS Suppliers, ISNULL(SUM(Outstanding), 0) AS Outstanding, ISNULL(SUM(NotDue), 0) AS NotDue, ISNULL(SUM(Overdue), 0) AS Overdue,
           ISNULL(SUM(D90), 0) AS Over90
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Bills) AS Bills, SUM(Outstanding) AS Outstanding, SUM(NotDue) AS NotDue, SUM(D1_30) AS D1_30, SUM(D31_60) AS D31_60,
           SUM(D61_90) AS D61_90, SUM(D90) AS D90, SUM(Overdue) AS Overdue, SUM(Returns) AS Returns
      FROM #R;
END
GO

-- ── P7 Supplier Payment Register ────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_SupplierPayments
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT ROW_NUMBER() OVER (ORDER BY p.PaymentDate, p.PaymentId) AS Rn, p.PaymentId, b.BranchCode, p.PaymentNo, p.PaymentDate, s.SupplierName,
           ISNULL(pm.MethodName, p.PaymentMode) AS ModeName, p.PaymentMode AS Mode, p.ReferenceNo, p.Amount,
           (SELECT COUNT(*) FROM dbo.PhSupplierPaymentAlloc a WHERE a.PaymentId = p.PaymentId) AS Bills,
           (SELECT STRING_AGG(g.GrnNo + ISNULL(N' / ' + g.InvoiceNo, N''), N', ') FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhGrn g ON g.GrnId = a.GrnId WHERE a.PaymentId = p.PaymentId) AS BillsSettled,
           p.Remarks, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = p.CreatedBy) AS UserName
      INTO #R
      FROM dbo.PhSupplierPayment p JOIN dbo.PhSupplier s ON s.SupplierId = p.SupplierId JOIN dbo.BranchMaster b ON b.BranchID = p.BranchId
      LEFT JOIN dbo.PaymentMethodMaster pm ON UPPER(pm.MethodCode) = UPPER(p.PaymentMode)
     WHERE p.CompanyId = @CompanyId AND (@BranchId IS NULL OR p.BranchId = @BranchId) AND p.Status = 'POSTED' AND p.PaymentDate BETWEEN @From AND @To
       AND (@SupplierId IS NULL OR p.SupplierId = @SupplierId) AND (@Mode IS NULL OR UPPER(p.PaymentMode) = @Mode)
       AND (@Search IS NULL OR p.PaymentNo LIKE @like OR s.SupplierName LIKE @like OR p.ReferenceNo LIKE @like);

    SELECT COUNT(*) AS Payments, COUNT(DISTINCT SupplierName) AS Suppliers, ISNULL(SUM(Amount), 0) AS Amount,
           ISNULL(SUM(CASE WHEN Mode = 'CASH' THEN Amount END), 0) AS Cash, ISNULL(SUM(CASE WHEN Mode <> 'CASH' THEN Amount END), 0) AS Bank
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Amount) AS Amount, SUM(Bills) AS Bills FROM #R;
END
GO

-- ── P8 Purchase Rate Variation: each item's last three purchase rates, change and best supplier ──────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_RateVariation
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT d.ItemId, d.Rate, d.Mrp, g.GrnDate, s.SupplierName,
           ROW_NUMBER() OVER (PARTITION BY d.ItemId ORDER BY g.GrnDate DESC, d.GrnDtlId DESC) AS k
      INTO #L
      FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
     WHERE g.CompanyId = @CompanyId AND (@BranchId IS NULL OR g.BranchId = @BranchId) AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @From AND @To
       AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId)
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search);
    SELECT i.ItemId, i.ItemCode, i.ItemName, COUNT(*) AS Purchases, MIN(l.Rate) AS MinRate, MAX(l.Rate) AS MaxRate,
           MAX(CASE WHEN l.k = 1 THEN l.Rate END) AS LastRate, MAX(CASE WHEN l.k = 1 THEN l.SupplierName END) AS LastSupplier, MAX(CASE WHEN l.k = 1 THEN l.GrnDate END) AS LastDate,
           MAX(CASE WHEN l.k = 2 THEN l.Rate END) AS PrevRate,
           MAX(CASE WHEN l.k = 1 THEN l.Mrp END) AS LastMrp, (SELECT TOP 1 x.Mrp FROM #L x WHERE x.ItemId = i.ItemId ORDER BY x.k DESC) AS FirstMrp,
           (SELECT TOP 1 x.Rate FROM #L x WHERE x.ItemId = i.ItemId ORDER BY x.k DESC) AS FirstRate,
           (SELECT STRING_AGG(FORMAT(x.Rate, 'N2', 'en-IN') + N' ' + x.SupplierName + N' (' + FORMAT(x.GrnDate, 'dd MMM', 'en-US') + N')', N'; ') WITHIN GROUP (ORDER BY x.k)
              FROM #L x WHERE x.ItemId = i.ItemId AND x.k <= 3) AS Last3,
           (SELECT TOP 1 x.SupplierName FROM #L x WHERE x.ItemId = i.ItemId GROUP BY x.SupplierName ORDER BY AVG(x.Rate), x.SupplierName) AS BestSupplier
      INTO #G
      FROM #L l JOIN dbo.PhItem i ON i.ItemId = l.ItemId
     GROUP BY i.ItemId, i.ItemCode, i.ItemName;
    SELECT ROW_NUMBER() OVER (ORDER BY ABS(CASE WHEN FirstRate = 0 THEN 0 ELSE (LastRate - FirstRate) * 100 / FirstRate END) DESC, ItemName) AS Rn, *,
           CASE WHEN ISNULL(PrevRate, 0) = 0 THEN NULL ELSE (LastRate - PrevRate) * 100 / PrevRate END AS ChangePct,
           CASE WHEN FirstRate = 0 THEN 0 ELSE (LastRate - FirstRate) * 100 / FirstRate END AS PeriodChangePct,
           CASE WHEN ISNULL(FirstMrp, 0) = 0 THEN 0 ELSE (LastMrp - FirstMrp) * 100 / FirstMrp END AS MrpChangePct
      INTO #R FROM #G
     WHERE @Option IS NULL OR @Option <> 'CHANGED' OR MinRate <> MaxRate OR FirstMrp <> LastMrp;

    SELECT COUNT(*) AS Items, SUM(CASE WHEN LastRate > FirstRate THEN 1 ELSE 0 END) AS Up, SUM(CASE WHEN LastRate < FirstRate THEN 1 ELSE 0 END) AS Down,
           SUM(CASE WHEN LastMrp <> FirstMrp THEN 1 ELSE 0 END) AS MrpChanged
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Purchases) AS Purchases FROM #R;
END
GO

-- ── P9 Indent to GRN Turnaround ─────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_IndentTurnaround
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT ROW_NUMBER() OVER (ORDER BY n.IndentDate, n.IndentId) AS Rn, n.IndentId, b.BranchCode, n.IndentNo, n.IndentDate,
           CASE n.Priority WHEN 'URGENT' THEN N'Urgent' WHEN 'HIGH' THEN N'High' ELSE N'Normal' END AS Priority,
           (SELECT COUNT(*) FROM dbo.PhPurchaseIndentDtl d WHERE d.IndentId = n.IndentId) AS Items, CAST(n.ApprovedDate AS DATE) AS ApprovedDate,
           po.PoNos, po.FirstPo, po.Suppliers, gr.GrnNos, gr.FirstGrn, gr.LastGrn,
           DATEDIFF(DAY, n.IndentDate, n.ApprovedDate) AS DaysToApprove, DATEDIFF(DAY, n.IndentDate, po.FirstPo) AS DaysToPo,
           DATEDIFF(DAY, po.FirstPo, gr.FirstGrn) AS DaysPoToGrn, DATEDIFF(DAY, n.IndentDate, gr.LastGrn) AS TotalDays,
           CASE WHEN gr.FirstGrn IS NOT NULL THEN N'Received' WHEN po.FirstPo IS NOT NULL THEN N'Ordered' WHEN n.Status = 'APPROVED' THEN N'Approved'
                WHEN n.Status = 'REJECTED' THEN N'Rejected' WHEN n.Status = 'CANCELLED' THEN N'Cancelled' ELSE N'Pending approval' END AS Stage
      INTO #R
      FROM dbo.PhPurchaseIndent n JOIN dbo.BranchMaster b ON b.BranchID = n.BranchId
     OUTER APPLY (SELECT STRING_AGG(p.PoNo, N', ') AS PoNos, MIN(p.PoDate) AS FirstPo, COUNT(DISTINCT p.SupplierId) AS Suppliers
                    FROM dbo.PhPurchaseOrder p WHERE p.IndentId = n.IndentId AND p.Status NOT IN ('DRAFT', 'CANCELLED')
                     AND (@SupplierId IS NULL OR p.SupplierId = @SupplierId)) po
     OUTER APPLY (SELECT STRING_AGG(g.GrnNo, N', ') AS GrnNos, MIN(g.GrnDate) AS FirstGrn, MAX(g.GrnDate) AS LastGrn
                    FROM dbo.PhGrn g JOIN dbo.PhPurchaseOrder p ON p.PoId = g.PoId WHERE p.IndentId = n.IndentId AND g.Status = 'POSTED') gr
     WHERE n.CompanyId = @CompanyId AND (@BranchId IS NULL OR n.BranchId = @BranchId) AND n.IndentDate BETWEEN @From AND @To AND n.Status <> 'DRAFT'
       AND (@SupplierId IS NULL OR po.FirstPo IS NOT NULL)
       AND (@Search IS NULL OR n.IndentNo LIKE @like OR po.PoNos LIKE @like OR gr.GrnNos LIKE @like);
    DELETE #R WHERE @Option = 'OPEN' AND Stage IN (N'Received', N'Rejected', N'Cancelled');

    SELECT COUNT(*) AS Indents, SUM(CASE WHEN Stage = N'Received' THEN 1 ELSE 0 END) AS Received,
           AVG(CAST(DaysToPo AS DECIMAL(18,2))) AS AvgToPo, AVG(CAST(DaysPoToGrn AS DECIMAL(18,2))) AS AvgPoToGrn, AVG(CAST(TotalDays AS DECIMAL(18,2))) AS AvgTotal
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Items) AS Items FROM #R;
END
GO

-- ── menu: pages directly under Reports > Pharmacy, after the sales reports ──────────────────────────────
DECLARE @Pages TABLE (Code NVARCHAR(100), Title NVARCHAR(150), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT @Pages VALUES
 (N'REPORTS.PHARMACY.PURCHASEREGISTER',  N'Purchase Register (GRN-wise)',        N'PurchaseRegister',  210, N'bi bi-truck me-2'),
 (N'REPORTS.PHARMACY.ITEMPURCHASES',     N'Item-wise Purchase',                  N'ItemPurchases',     220, N'bi bi-box-seam me-2'),
 (N'REPORTS.PHARMACY.SUPPLIERPURCHASES', N'Supplier-wise Purchase Summary',      N'SupplierPurchases', 230, N'bi bi-building me-2'),
 (N'REPORTS.PHARMACY.PURCHASERETURNS',   N'Purchase Return (Debit Note) Register', N'PurchaseReturns', 240, N'bi bi-box-arrow-left me-2'),
 (N'REPORTS.PHARMACY.PENDINGPOS',        N'Pending Purchase Orders',             N'PendingPos',        250, N'bi bi-hourglass me-2'),
 (N'REPORTS.PHARMACY.SUPPLIERAGEING',    N'Supplier Outstanding & Ageing',       N'SupplierAgeing',    260, N'bi bi-calendar-x me-2'),
 (N'REPORTS.PHARMACY.SUPPLIERPAYMENTS',  N'Supplier Payment Register',           N'SupplierPayments',  270, N'bi bi-wallet2 me-2'),
 (N'REPORTS.PHARMACY.RATEVARIATION',     N'Purchase Rate Variation',             N'RateVariation',     280, N'bi bi-graph-up-arrow me-2'),
 (N'REPORTS.PHARMACY.INDENTTURNAROUND',  N'Indent to GRN Turnaround',            N'IndentTurnaround',  290, N'bi bi-stopwatch me-2');

DECLARE @co INT, @reports INT, @ph INT, @page INT, @view INT, @exp INT, @pc NVARCHAR(100), @title NVARCHAR(150), @action NVARCHAR(100), @sort INT, @icon NVARCHAR(100);
DECLARE co CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS';
OPEN co; FETCH NEXT FROM co INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @reports = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS' AND CompanyId = @co;
    SET @ph = NULL;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @reports, @Menu_Type = 'MENU', @Menu_Code = N'REPORTS.PHARMACY', @Title = N'Pharmacy',
         @Icon = N'bi bi-capsule-pill me-2', @Sort_Order = 25, @UserId = NULL, @Menu_ID = @ph OUTPUT;
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

PRINT 'Script 2362 applied: Reports > Pharmacy, purchase reports (P1-P9): report procedures, indexes and pages.';
GO
