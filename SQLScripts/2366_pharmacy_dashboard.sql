-- ============================================================================================================
-- Migration: 2366_pharmacy_dashboard.sql
-- Pharmacy Dashboard: yesterday / month comparison and margin, store issues, and new result sets:
--   6 pending requests (purchase indents to approve, branch indents to send / receive, store requests) for the reminder banner,
--   7 stock by store, 8 collected today by mode, 9 sales and purchases of the last 14 days. Sets 1-5 unchanged.
-- Run after 2365. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── dashboard: 1 figures, 2 to reorder, 3 below reorder / out of stock / supplier due, 4 top items, 5 last 7 days (near expiry: usp_Api_PhInv_Stock 'near') ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Dashboard @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @month DATE = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1);
    SELECT
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= @today), 0) SalesToday,
      (SELECT COUNT(*) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= @today) BillsToday,
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSaleReturn WHERE BranchId = @BranchId AND ReturnDate >= @today), 0) ReturnsToday,
      ISNULL((SELECT SUM(CASE WHEN pm.MethodCode = 'CASH' THEN pd.PaidAmount END) FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
              WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.BranchId = @BranchId AND pd.IsActive = 1 AND pd.CreatedDate >= @today), 0) CashToday,
      ISNULL((SELECT SUM(CASE WHEN pm.MethodCode <> 'CASH' THEN pd.PaidAmount END) FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
              WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.BranchId = @BranchId AND pd.IsActive = 1 AND pd.CreatedDate >= @today), 0) NonCashToday,
      ISNULL((SELECT SUM(NetAmount - PaidAmount) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= @today AND NetAmount > PaidAmount), 0) CreditToday,
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= @month), 0) SalesMonth,
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhGrn WHERE BranchId = @BranchId AND Status = 'POSTED' AND GrnDate >= @today), 0) PurchasesToday,
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhGrn WHERE BranchId = @BranchId AND Status = 'POSTED' AND GrnDate >= @month), 0) PurchasesMonth,
      ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0), 0) StockValue,
      ISNULL((SELECT SUM(s.QtyOnHand * b.Mrp / i.ConversionQty) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0), 0) StockMrpValue,
      (SELECT COUNT(DISTINCT ItemId) FROM dbo.PhStock WHERE BranchId = @BranchId AND QtyOnHand > 0) ItemsInStock,
      (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate <= @today) Expired,
      ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate <= @today), 0) ExpiredValue,
      (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > @today AND b.ExpiryDate <= DATEADD(DAY, 30, @today)) Exp30,
      ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > @today AND b.ExpiryDate <= DATEADD(DAY, 30, @today)), 0) Exp30Value,
      (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 30, @today) AND b.ExpiryDate <= DATEADD(DAY, 60, @today)) Exp60,
      ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 30, @today) AND b.ExpiryDate <= DATEADD(DAY, 60, @today)), 0) Exp60Value,
      (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 60, @today) AND b.ExpiryDate <= DATEADD(DAY, 90, @today)) Exp90,
      ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 60, @today) AND b.ExpiryDate <= DATEADD(DAY, 90, @today)), 0) Exp90Value,
      ISNULL((SELECT SUM(BalanceDue) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND BalanceDue > 0), 0) CreditDue,
      (SELECT COUNT(*) FROM dbo.PhPurchaseIndent WHERE BranchId = @BranchId AND Status = 'SUBMITTED') PendIndents,
      (SELECT COUNT(*) FROM dbo.PhPurchaseOrder WHERE BranchId = @BranchId AND Status IN ('DRAFT', 'APPROVED', 'PARTIAL')) PendPos,
      (SELECT COUNT(*) FROM dbo.PhGrn WHERE BranchId = @BranchId AND Status = 'DRAFT') DraftGrns,
      (SELECT COUNT(*) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'HOLD') HeldBills,
      (SELECT COUNT(*) FROM dbo.PhTransfer WHERE FromBranchId = @BranchId AND Status = 'REQUESTED') ToDispatch,
      (SELECT COUNT(*) FROM dbo.PhTransfer WHERE ToBranchId = @BranchId AND Status = 'DISPATCHED') ToReceive,
      (SELECT COUNT(*) FROM dbo.PhAdjustment WHERE BranchId = @BranchId AND Kind = 'ADJUST' AND Status = 'SUBMITTED') PendAdjust,
      (SELECT COUNT(*) FROM dbo.PhAdjustment WHERE BranchId = @BranchId AND Kind = 'WRITEOFF' AND Status = 'SUBMITTED') PendWriteOff,
      (SELECT COUNT(*) FROM dbo.PhStockCount WHERE BranchId = @BranchId AND Status IN ('COUNTING', 'SUBMITTED')) PendCounts,
      (SELECT COUNT(*) FROM dbo.PhBatchCorrection WHERE BranchId = @BranchId AND Status = 'SUBMITTED') PendCorrections,
      -- 2366: comparison, margin, drafts and store issues
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= DATEADD(DAY, -1, @today) AND SaleDate < @today), 0) SalesYesterday,
      (SELECT COUNT(*) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= @month) BillsMonth,
      ISNULL((SELECT SUM(CostAmount) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= @month), 0) CostMonth,
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSaleReturn WHERE BranchId = @BranchId AND ReturnDate >= @month), 0) ReturnsMonth,
      (SELECT COUNT(*) FROM dbo.PhPurchaseIndent WHERE BranchId = @BranchId AND Status = 'DRAFT') DraftIndents,
      (SELECT COUNT(*) FROM dbo.PhStoreIssue WHERE BranchId = @BranchId AND Status = 'REQUESTED') IssuesToIssue,
      (SELECT COUNT(*) FROM dbo.PhStoreIssue WHERE BranchId = @BranchId AND Status = 'ISSUED') IssuesToReceive,
      (SELECT COUNT(*) FROM dbo.PhStore WHERE BranchId = @BranchId AND IsActive = 1) Stores;

    SELECT TOP 15 i.ItemName, ISNULL(st.Qty, 0) / i.ConversionQty AS Stock, ISNULL(ib.ReorderLevel, i.ReorderLevel) AS Reorder, pu.UomCode AS Uom
      FROM dbo.PhItem i JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
      OUTER APPLY (SELECT SUM(QtyOnHand) Qty FROM dbo.PhStock s WHERE s.BranchId = @BranchId AND s.ItemId = i.ItemId) st
     WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 AND ISNULL(ib.IsStocked, 1) = 1 AND ISNULL(ib.ReorderLevel, i.ReorderLevel) > 0
       AND ISNULL(st.Qty, 0) / i.ConversionQty <= ISNULL(ib.ReorderLevel, i.ReorderLevel)
     ORDER BY ISNULL(st.Qty, 0) / i.ConversionQty / NULLIF(ISNULL(ib.ReorderLevel, i.ReorderLevel), 0);

    SELECT
      (SELECT COUNT(*) FROM dbo.PhItem i LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
        WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 AND ISNULL(ib.IsStocked, 1) = 1 AND ISNULL(ib.ReorderLevel, i.ReorderLevel) > 0
          AND ISNULL((SELECT SUM(QtyOnHand) FROM dbo.PhStock s WHERE s.BranchId = @BranchId AND s.ItemId = i.ItemId), 0) / i.ConversionQty <= ISNULL(ib.ReorderLevel, i.ReorderLevel)) AS BelowReorder,
      (SELECT COUNT(*) FROM dbo.PhItem i WHERE i.CompanyId = @CompanyId AND i.IsActive = 1
          AND ISNULL((SELECT SUM(QtyOnHand) FROM dbo.PhStock s WHERE s.BranchId = @BranchId AND s.ItemId = i.ItemId), 0) <= 0
          AND EXISTS (SELECT 1 FROM dbo.PhStockLedger l WHERE l.BranchId = @BranchId AND l.ItemId = i.ItemId)) AS OutOfStock,
      (SELECT ISNULL(SUM(g.NetAmount), 0) - ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment sp ON sp.PaymentId = a.PaymentId WHERE sp.BranchId = @BranchId AND sp.Status = 'POSTED'), 0)
         FROM dbo.PhGrn g WHERE g.BranchId = @BranchId AND g.Status = 'POSTED') AS SupplierDue;

    SELECT TOP 10 i.ItemName, SUM(x.Qty - x.ReturnedQty) AS Qty, SUM(x.Amount * (x.Qty - x.ReturnedQty) / x.Qty) AS Value
      FROM dbo.PhSaleDtl x JOIN dbo.PhSale s ON s.SaleId = x.SaleId JOIN dbo.PhItem i ON i.ItemId = x.ItemId
     WHERE s.BranchId = @BranchId AND s.Status = 'POSTED' AND s.SaleDate >= DATEADD(DAY, -30, GETDATE()) GROUP BY i.ItemName ORDER BY 3 DESC;

    SELECT CAST(SaleDate AS DATE) AS Day, SUM(NetAmount) AS Value FROM dbo.PhSale
     WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= DATEADD(DAY, -6, CAST(GETDATE() AS DATE))
     GROUP BY CAST(SaleDate AS DATE) ORDER BY 1;


    -- 6 pending requests (the reminder): purchase indents to approve, branch indents to send / receive, store requests to issue / receive
    SELECT TOP 20 * FROM (
        SELECT 'PURCHASE' Kind, n.IndentId Id, n.IndentNo DocNo, ISNULL(n.SubmittedDate, n.CreatedDate) Since, n.Priority,
               N'Purchase indent to approve' Title, CAST((SELECT COUNT(*) FROM dbo.PhPurchaseIndentDtl d WHERE d.IndentId = n.IndentId) AS INT) Items,
               (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = n.CreatedBy) Party
          FROM dbo.PhPurchaseIndent n WHERE n.BranchId = @BranchId AND n.Status = 'SUBMITTED'
        UNION ALL
        SELECT 'BRANCH_OUT', t.TransferId, t.RequestNo, ISNULL(t.RequestDate, t.CreatedDate), t.Priority, N'Branch indent to send',
               (SELECT COUNT(*) FROM dbo.PhTransferDtl d WHERE d.TransferId = t.TransferId AND d.RequestQty > 0), b.BranchName
          FROM dbo.PhTransfer t JOIN dbo.BranchMaster b ON b.BranchID = t.ToBranchId WHERE t.FromBranchId = @BranchId AND t.Status = 'REQUESTED'
        UNION ALL
        SELECT 'BRANCH_IN', t.TransferId, ISNULL(t.TransferNo, t.RequestNo), ISNULL(t.DispatchDate, t.CreatedDate), t.Priority, N'Transfer to receive',
               (SELECT COUNT(*) FROM dbo.PhTransferDtl d WHERE d.TransferId = t.TransferId AND d.DispatchQty > 0), b.BranchName
          FROM dbo.PhTransfer t JOIN dbo.BranchMaster b ON b.BranchID = t.FromBranchId WHERE t.ToBranchId = @BranchId AND t.Status = 'DISPATCHED'
        UNION ALL
        SELECT CASE x.Status WHEN 'REQUESTED' THEN 'STORE_ISSUE' ELSE 'STORE_RECEIVE' END, x.IssueId, x.IssueNo, CASE x.Status WHEN 'REQUESTED' THEN x.RequestDate ELSE x.IssueDate END,
               'NORMAL', CASE x.Status WHEN 'REQUESTED' THEN N'Store request to issue' ELSE N'Store issue to receive' END,
               (SELECT COUNT(*) FROM dbo.PhStoreIssueDtl d WHERE d.IssueId = x.IssueId AND d.RequestQty > 0), f.StoreName + N' → ' + s.StoreName
          FROM dbo.PhStoreIssue x JOIN dbo.PhStore f ON f.StoreId = x.FromStoreId JOIN dbo.PhStore s ON s.StoreId = x.ToStoreId
         WHERE x.BranchId = @BranchId AND x.Status IN ('REQUESTED', 'ISSUED')) p
     ORDER BY CASE WHEN p.Priority = 'URGENT' THEN 0 ELSE 1 END, p.Since;

    -- 7 stock by store
    SELECT st.StoreName, st.StoreType, COUNT(DISTINCT CASE WHEN s.QtyOnHand > 0 THEN s.ItemId END) Items,
           CAST(ISNULL(SUM(CASE WHEN s.QtyOnHand > 0 THEN s.QtyOnHand * b.LandedCost END), 0) AS DECIMAL(18,2)) Value
      FROM dbo.PhStore st LEFT JOIN dbo.PhStoreStock s ON s.StoreId = st.StoreId LEFT JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
     WHERE st.BranchId = @BranchId AND st.IsActive = 1
     GROUP BY st.StoreId, st.StoreName, st.StoreType ORDER BY Value DESC;

    -- 8 collected today by mode
    SELECT ISNULL(pm.MethodName, pm.MethodCode) Mode, SUM(pd.PaidAmount) Amount
      FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
     WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.BranchId = @BranchId AND pd.IsActive = 1 AND pd.CreatedDate >= @today
     GROUP BY ISNULL(pm.MethodName, pm.MethodCode) ORDER BY 2 DESC;

    -- 9 last 14 days: sales and purchases
    SELECT d.Day, ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND CAST(SaleDate AS DATE) = d.Day), 0) Sales,
           ISNULL((SELECT SUM(NetAmount) FROM dbo.PhGrn WHERE BranchId = @BranchId AND Status = 'POSTED' AND GrnDate = d.Day), 0) Purchases
      FROM (SELECT DATEADD(DAY, -v, @today) Day FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13)) x (v)) d
     ORDER BY d.Day;
END
GO

PRINT 'Script 2366 applied: pharmacy dashboard figures, pending requests, stock by store.';
GO
