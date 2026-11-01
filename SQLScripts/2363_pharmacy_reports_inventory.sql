-- ============================================================================================================
-- Migration: 2363_pharmacy_reports_inventory.sql
-- Reports > Pharmacy, stock & inventory reports (I1-I13 of the Pharmacy Reports plan), read through EMR.Api.
--   Same contract as 2361: common parameters; result sets 1 tiles · 2 the page of rows (@PageSize 0 = all) · 3 totals + TotalRows.
--   Units: stock is in sale units; cost value = qty x batch landed cost (per sale unit); MRP value = qty x MRP / conversion;
--   reorder / min / max levels are in purchase units (packs). Movements come from PhStockLedger (UnitCost per sale unit).
--   I8 is FSN (fast / slow / non-moving) only: VED needs a VED flag on the Item Master, not added yet.
--   Menu: one page per report directly under Reports > Pharmacy, after the purchase reports, VIEW and EXPORT. No grants.
-- Run after 2362. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhStockLedger_ItemDate' AND object_id = OBJECT_ID('dbo.PhStockLedger'))
    CREATE INDEX IX_PhStockLedger_ItemDate ON dbo.PhStockLedger (BranchId, ItemId, TxnDate) INCLUDE (DocType, QtyIn, QtyOut, UnitCost, BatchId);
GO

-- what a stock-ledger document type is called on the reports
CREATE OR ALTER FUNCTION dbo.fn_PhLedgerDocName (@DocType VARCHAR(10))
RETURNS NVARCHAR(40)
AS
BEGIN
    RETURN CASE @DocType WHEN 'GRN' THEN N'Purchase (GRN)' WHEN 'PRET' THEN N'Purchase return' WHEN 'SALE' THEN N'Sale' WHEN 'SRET' THEN N'Sale return'
                         WHEN 'SCAN' THEN N'Bill cancelled' WHEN 'TRFO' THEN N'Transfer out' WHEN 'TRFI' THEN N'Transfer in' WHEN 'ADJ' THEN N'Adjustment'
                         WHEN 'WOF' THEN N'Write-off' WHEN 'PCNT' THEN N'Physical count' WHEN 'OPEN' THEN N'Opening stock' ELSE @DocType END;
END
GO

-- ── I1 Current Stock (batch-wise) with valuation, as on today ───────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_CurrentStock
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE);
    SELECT ROW_NUMBER() OVER (ORDER BY ISNULL(pc.CategoryName, c.CategoryName), c.CategoryName, i.ItemName, b.ExpiryDate, br.BranchCode) AS Rn,
           br.BranchCode, ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, i.ItemCode, i.ItemName, m.ManufacturerName, i.ScheduleCode,
           ib.RackNo, b.BatchNo, b.ExpiryDate, DATEDIFF(DAY, @today, b.ExpiryDate) AS DaysToExpiry, s.QtyOnHand AS Qty, su.UomCode AS SaleUom,
           CASE WHEN i.ConversionQty > 1 THEN s.QtyOnHand / i.ConversionQty END AS Packs, b.LandedCost AS UnitCost,
           ROUND(s.QtyOnHand * b.LandedCost, 2) AS CostValue, ROUND(s.QtyOnHand * b.Mrp / i.ConversionQty, 2) AS MrpValue, sp.SupplierName,
           CASE WHEN b.IsBlocked = 1 THEN N'Blocked' WHEN b.ExpiryDate <= @today THEN N'Expired' WHEN b.ExpiryDate <= DATEADD(DAY, 90, @today) THEN N'Near expiry' ELSE N'' END AS Flag,
           s.ItemId
      INTO #R
      FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId JOIN dbo.BranchMaster br ON br.BranchID = s.BranchId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
      LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId LEFT JOIN dbo.PhSupplier sp ON sp.SupplierId = b.SupplierId
      LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = s.BranchId
     WHERE b.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.QtyOnHand > 0
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId) AND (@Schedule IS NULL OR i.ScheduleCode = @Schedule)
       AND (@SupplierId IS NULL OR b.SupplierId = @SupplierId)
       AND (@Option IS NULL OR (@Option = 'EXPIRED' AND b.ExpiryDate <= @today) OR (@Option = 'NEAR' AND b.ExpiryDate > @today AND b.ExpiryDate <= DATEADD(DAY, 90, @today))
            OR (@Option = 'SALEABLE' AND b.ExpiryDate > @today AND b.IsBlocked = 0))
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search OR b.BatchNo LIKE @like OR ib.RackNo = @Search);

    SELECT COUNT(DISTINCT ItemId) AS Items, COUNT(*) AS Batches, ISNULL(SUM(CostValue), 0) AS CostValue, ISNULL(SUM(MrpValue), 0) AS MrpValue,
           ISNULL(SUM(CASE WHEN Flag = N'Expired' THEN CostValue END), 0) AS ExpiredValue, ISNULL(SUM(CASE WHEN Flag = N'Near expiry' THEN CostValue END), 0) AS NearValue
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(CostValue) AS CostValue, SUM(MrpValue) AS MrpValue FROM #R;
END
GO

-- ── I2 Stock Summary (one line per item), as on today ───────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_StockSummary
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE);
    SELECT i.ItemId, i.ItemCode, i.ItemName, ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, m.ManufacturerName, i.ScheduleCode,
           su.UomCode AS SaleUom, pu.UomCode AS PurchaseUom, i.ConversionQty,
           ISNULL(st.Qty, 0) AS Qty, ISNULL(st.Qty, 0) / i.ConversionQty AS Packs, ISNULL(st.Batches, 0) AS Batches, st.NearestExpiry,
           ISNULL(st.CostValue, 0) AS CostValue, ISNULL(ROUND(st.MrpRaw / i.ConversionQty, 2), 0) AS MrpValue,
           CASE WHEN @BranchId IS NULL THEN i.ReorderLevel ELSE ISNULL(ib.ReorderLevel, i.ReorderLevel) END AS ReorderLevel,
           CASE WHEN @BranchId IS NULL THEN i.MaxQty ELSE ISNULL(ib.MaxQty, i.MaxQty) END AS MaxQty
      INTO #G
      FROM dbo.PhItem i JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
      LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
      LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
      OUTER APPLY (SELECT SUM(s.QtyOnHand) AS Qty, COUNT(*) AS Batches, MIN(b.ExpiryDate) AS NearestExpiry,
                          ROUND(SUM(s.QtyOnHand * b.LandedCost), 2) AS CostValue, SUM(s.QtyOnHand * b.Mrp) AS MrpRaw
                     FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.ItemId = i.ItemId AND s.QtyOnHand > 0 AND (@BranchId IS NULL OR s.BranchId = @BranchId)) st
     WHERE i.CompanyId = @CompanyId AND i.IsActive = 1
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId) AND (@Schedule IS NULL OR i.ScheduleCode = @Schedule)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search);
    SELECT ROW_NUMBER() OVER (ORDER BY ItemName) AS Rn, *,
           CASE WHEN Qty <= 0 THEN N'Out of stock' WHEN ReorderLevel > 0 AND Packs <= ReorderLevel THEN N'Below reorder'
                WHEN NearestExpiry <= @today THEN N'Has expired stock' ELSE N'' END AS Status
      INTO #R FROM #G
     WHERE (@Option = 'ALL') OR (@Option = 'OUT' AND Qty <= 0) OR (@Option = 'BELOW' AND ReorderLevel > 0 AND Packs <= ReorderLevel)
        OR (ISNULL(@Option, '') NOT IN ('ALL', 'OUT', 'BELOW') AND Qty > 0);

    SELECT COUNT(*) AS Items, ISNULL(SUM(CASE WHEN Qty <= 0 THEN 1 ELSE 0 END), 0) AS OutOfStock, ISNULL(SUM(CASE WHEN Status = N'Below reorder' THEN 1 ELSE 0 END), 0) AS BelowReorder,
           ISNULL(SUM(CostValue), 0) AS CostValue, ISNULL(SUM(MrpValue), 0) AS MrpValue
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(Batches) AS Batches, SUM(CostValue) AS CostValue, SUM(MrpValue) AS MrpValue FROM #R;
END
GO

-- ── I3 Stock Movement / Item Ledger ─────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_ItemLedger
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT ROW_NUMBER() OVER (ORDER BY l.TxnDate, l.LedgerId) AS Rn, br.BranchCode, l.TxnDate, dbo.fn_PhLedgerDocName(l.DocType) AS DocName, l.DocNo,
           i.ItemCode, i.ItemName, b.BatchNo, b.ExpiryDate, l.QtyIn, l.QtyOut, l.BalanceAfter, l.UnitCost,
           ROUND(l.QtyIn * l.UnitCost, 2) AS ValueIn, ROUND(l.QtyOut * l.UnitCost, 2) AS ValueOut,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = l.CreatedBy) AS UserName
      INTO #R
      FROM dbo.PhStockLedger l JOIN dbo.PhBatch b ON b.BatchId = l.BatchId JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.BranchMaster br ON br.BranchID = l.BranchId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
     WHERE b.CompanyId = @CompanyId AND (@BranchId IS NULL OR l.BranchId = @BranchId) AND l.TxnDate >= @From AND l.TxnDate < @end
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@Option IS NULL OR (@Option = 'PURCHASE' AND l.DocType IN ('GRN', 'PRET')) OR (@Option = 'SALE' AND l.DocType IN ('SALE', 'SRET', 'SCAN'))
            OR (@Option = 'TRANSFER' AND l.DocType IN ('TRFO', 'TRFI')) OR (@Option = 'ADJUST' AND l.DocType IN ('ADJ', 'WOF', 'PCNT')))
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search OR b.BatchNo LIKE @like OR l.DocNo LIKE @like);

    SELECT COUNT(*) AS Lines, COUNT(DISTINCT ItemCode) AS Items, ISNULL(SUM(QtyIn), 0) AS QtyIn, ISNULL(SUM(QtyOut), 0) AS QtyOut,
           ISNULL(SUM(ValueIn), 0) AS ValueIn, ISNULL(SUM(ValueOut), 0) AS ValueOut
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(QtyIn) AS QtyIn, SUM(QtyOut) AS QtyOut, SUM(ValueIn) AS ValueIn, SUM(ValueOut) AS ValueOut FROM #R;
END
GO

-- ── I4 Stock Statement: opening - in - out - closing, by item (default) or by category (@Option CATEGORY) ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_StockStatement
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME)), @cat BIT = CASE WHEN @Option = 'CATEGORY' THEN 1 ELSE 0 END;
    -- every ledger line up to the end of the period, signed (+ in, - out), with its cost
    SELECT CASE WHEN @cat = 1 THEN NULL ELSE i.ItemCode END AS ItemCode,
           CASE WHEN @cat = 1 THEN ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName ELSE i.ItemName END AS Name,
           ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName,
           CASE WHEN l.TxnDate < @From THEN 1 ELSE 0 END AS Before, l.DocType, l.QtyIn - l.QtyOut AS Q, (l.QtyIn - l.QtyOut) * l.UnitCost AS V
      INTO #L
      FROM dbo.PhStockLedger l JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
      LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
     WHERE i.CompanyId = @CompanyId AND (@BranchId IS NULL OR l.BranchId = @BranchId) AND l.TxnDate < @end
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search);
    SELECT ItemCode, Name, MAX(CategoryName) AS CategoryName,
           SUM(CASE WHEN Before = 1 THEN Q ELSE 0 END) AS Opening, ROUND(SUM(CASE WHEN Before = 1 THEN V ELSE 0 END), 2) AS OpeningValue,
           SUM(CASE WHEN Before = 0 AND DocType IN ('GRN', 'PRET', 'OPEN') THEN Q ELSE 0 END) AS Purchases,
           -SUM(CASE WHEN Before = 0 AND DocType IN ('SALE', 'SRET', 'SCAN') THEN Q ELSE 0 END) AS Sales,
           SUM(CASE WHEN Before = 0 AND DocType IN ('TRFI', 'TRFO') THEN Q ELSE 0 END) AS Transfers,
           SUM(CASE WHEN Before = 0 AND DocType IN ('ADJ', 'WOF', 'PCNT') THEN Q ELSE 0 END) AS Adjustments,
           SUM(Q) AS Closing, ROUND(SUM(V), 2) AS ClosingValue,
           ROUND(SUM(CASE WHEN Before = 0 AND DocType IN ('GRN', 'PRET', 'OPEN') THEN V ELSE 0 END), 2) AS PurchaseValue,
           ROUND(-SUM(CASE WHEN Before = 0 AND DocType IN ('SALE', 'SRET', 'SCAN') THEN V ELSE 0 END), 2) AS SalesCost
      INTO #G FROM #L GROUP BY ItemCode, Name;
    SELECT ROW_NUMBER() OVER (ORDER BY CategoryName, Name) AS Rn, * INTO #R FROM #G
     WHERE Opening <> 0 OR Purchases <> 0 OR Sales <> 0 OR Transfers <> 0 OR Adjustments <> 0 OR Closing <> 0;

    SELECT COUNT(*) AS Lines, ISNULL(SUM(OpeningValue), 0) AS OpeningValue, ISNULL(SUM(PurchaseValue), 0) AS PurchaseValue, ISNULL(SUM(SalesCost), 0) AS SalesCost,
           ISNULL(SUM(ClosingValue), 0) AS ClosingValue
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Opening) AS Opening, SUM(OpeningValue) AS OpeningValue, SUM(Purchases) AS Purchases, SUM(PurchaseValue) AS PurchaseValue,
           SUM(Sales) AS Sales, SUM(SalesCost) AS SalesCost, SUM(Transfers) AS Transfers, SUM(Adjustments) AS Adjustments, SUM(Closing) AS Closing,
           SUM(ClosingValue) AS ClosingValue
      FROM #R;
END
GO

-- ── I5 Reorder / Shortage Report, as on today (levels in purchase units) ────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_Reorder
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE);
    SELECT i.ItemId, i.ItemCode, i.ItemName, ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, m.ManufacturerName, pu.UomCode AS PurchaseUom,
           ISNULL(st.Qty, 0) / i.ConversionQty AS StockPacks,
           CASE WHEN @BranchId IS NULL THEN i.ReorderLevel ELSE ISNULL(ib.ReorderLevel, i.ReorderLevel) END AS ReorderLevel,
           CASE WHEN @BranchId IS NULL THEN i.MinQty ELSE ISNULL(ib.MinQty, i.MinQty) END AS MinQty,
           CASE WHEN @BranchId IS NULL THEN i.MaxQty ELSE ISNULL(ib.MaxQty, i.MaxQty) END AS MaxQty,
           ISNULL(po.Pending, 0) AS PendingPo, i.LeadDays, lg.SupplierName AS LastSupplier, lg.Rate AS LastRate, lg.GrnDate AS LastGrn,
           ISNULL(sl.Qty, 0) / i.ConversionQty AS Sold30
      INTO #G
      FROM dbo.PhItem i JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
      LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
      LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
      OUTER APPLY (SELECT SUM(s.QtyOnHand) AS Qty FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.ItemId = i.ItemId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND b.ExpiryDate > @today AND b.IsBlocked = 0) st
      OUTER APPLY (SELECT SUM(d.Qty - d.ReceivedQty) AS Pending FROM dbo.PhPurchaseOrderDtl d JOIN dbo.PhPurchaseOrder p ON p.PoId = d.PoId
                    WHERE d.ItemId = i.ItemId AND p.Status IN ('APPROVED', 'PARTIAL') AND d.Qty > d.ReceivedQty AND (@BranchId IS NULL OR p.BranchId = @BranchId)) po
      OUTER APPLY (SELECT TOP 1 s.SupplierName, d.Rate, g.GrnDate, g.SupplierId FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId
                    WHERE d.ItemId = i.ItemId AND g.Status = 'POSTED' AND (@BranchId IS NULL OR g.BranchId = @BranchId) ORDER BY g.GrnDate DESC, d.GrnDtlId DESC) lg
      OUTER APPLY (SELECT SUM(l.QtyOut - l.QtyIn) AS Qty FROM dbo.PhStockLedger l
                    WHERE l.ItemId = i.ItemId AND l.DocType IN ('SALE', 'SRET', 'SCAN') AND l.TxnDate >= DATEADD(DAY, -30, @today) AND (@BranchId IS NULL OR l.BranchId = @BranchId)) sl
     WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 AND ISNULL(ib.IsStocked, 1) = 1
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId) AND (@SupplierId IS NULL OR lg.SupplierId = @SupplierId)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search);
    -- suggested order: up to the maximum level (or twice the reorder level), less stock and what is already on order
    SELECT ROW_NUMBER() OVER (ORDER BY CASE WHEN ReorderLevel = 0 THEN 1 ELSE 0 END, StockPacks / NULLIF(ReorderLevel, 0), ItemName) AS Rn, *,
           CASE WHEN StockPacks <= 0 THEN N'Out of stock' WHEN StockPacks <= MinQty AND MinQty > 0 THEN N'Below minimum' WHEN StockPacks <= ReorderLevel THEN N'Reorder' ELSE N'' END AS Status,
           CEILING(CASE WHEN (CASE WHEN MaxQty > 0 THEN MaxQty ELSE ReorderLevel * 2 END) - StockPacks - PendingPo > 0
                        THEN (CASE WHEN MaxQty > 0 THEN MaxQty ELSE ReorderLevel * 2 END) - StockPacks - PendingPo ELSE 0 END) AS Suggested
      INTO #R FROM #G
     WHERE (@Option = 'ALL' AND ReorderLevel > 0) OR (ISNULL(@Option, '') <> 'ALL' AND ReorderLevel > 0 AND StockPacks <= ReorderLevel)
        OR (@Option = 'OUT' AND StockPacks <= 0);
    UPDATE #R SET LastRate = ISNULL(LastRate, 0);
    ALTER TABLE #R ADD SuggestedValue DECIMAL(18,2);
    UPDATE #R SET SuggestedValue = Suggested * LastRate;

    SELECT COUNT(*) AS Items, ISNULL(SUM(CASE WHEN StockPacks <= 0 THEN 1 ELSE 0 END), 0) AS OutOfStock, ISNULL(SUM(CASE WHEN PendingPo > 0 THEN 1 ELSE 0 END), 0) AS OnOrder,
           ISNULL(SUM(SuggestedValue), 0) AS SuggestedValue
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(PendingPo) AS PendingPo, SUM(Suggested) AS Suggested, SUM(SuggestedValue) AS SuggestedValue FROM #R;
END
GO

-- ── I6 Non-moving & Slow-moving Stock: in stock, no sale in the last @Option days (30 / 60 / 90 / 180; default 90) ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_NonMoving
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE),
            @days INT = CASE WHEN @Option IN ('30', '60', '90', '180') THEN CAST(@Option AS INT) ELSE 90 END;
    SELECT i.ItemId, i.ItemCode, i.ItemName, ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, m.ManufacturerName, su.UomCode AS SaleUom,
           st.Qty, st.Batches, st.CostValue, ROUND(st.MrpRaw / i.ConversionQty, 2) AS MrpValue, st.NearestExpiry, ls.LastSale, lg.LastGrn,
           DATEDIFF(DAY, COALESCE(ls.LastSale, lg.LastGrn), @today) AS DaysIdle
      INTO #G
      FROM dbo.PhItem i JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
      LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
      CROSS APPLY (SELECT SUM(s.QtyOnHand) AS Qty, COUNT(*) AS Batches, MIN(b.ExpiryDate) AS NearestExpiry,
                          ROUND(SUM(s.QtyOnHand * b.LandedCost), 2) AS CostValue, SUM(s.QtyOnHand * b.Mrp) AS MrpRaw
                     FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.ItemId = i.ItemId AND s.QtyOnHand > 0 AND (@BranchId IS NULL OR s.BranchId = @BranchId)) st
      OUTER APPLY (SELECT MAX(l.TxnDate) AS LastSale FROM dbo.PhStockLedger l WHERE l.ItemId = i.ItemId AND l.DocType = 'SALE' AND (@BranchId IS NULL OR l.BranchId = @BranchId)) ls
      OUTER APPLY (SELECT MAX(l.TxnDate) AS LastGrn FROM dbo.PhStockLedger l WHERE l.ItemId = i.ItemId AND l.DocType IN ('GRN', 'TRFI') AND (@BranchId IS NULL OR l.BranchId = @BranchId)) lg
     WHERE i.CompanyId = @CompanyId AND st.Qty > 0
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search);
    -- an item received recently but never sold is counted from its receipt
    SELECT ROW_NUMBER() OVER (ORDER BY CostValue DESC, ItemName) AS Rn, *,
           CASE WHEN LastSale IS NULL THEN N'Never sold' WHEN DaysIdle > 180 THEN N'Over 180 days' WHEN DaysIdle > 90 THEN N'91-180 days'
                WHEN DaysIdle > 60 THEN N'61-90 days' ELSE N'31-60 days' END AS Band
      INTO #R FROM #G WHERE ISNULL(DaysIdle, 99999) >= @days;

    SELECT COUNT(*) AS Items, ISNULL(SUM(CostValue), 0) AS CostValue, ISNULL(SUM(MrpValue), 0) AS MrpValue, ISNULL(SUM(CASE WHEN LastSale IS NULL THEN 1 ELSE 0 END), 0) AS NeverSold FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(Batches) AS Batches, SUM(CostValue) AS CostValue, SUM(MrpValue) AS MrpValue FROM #R;
END
GO

-- ── I7 ABC Analysis: consumption value (sales at cost, net of returns) in the period; A = first 70%, B = next 20%, C = rest ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_AbcAnalysis
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT i.ItemId, i.ItemCode, i.ItemName, ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, su.UomCode AS SaleUom,
           SUM(l.QtyOut - l.QtyIn) AS Qty, ROUND(SUM((l.QtyOut - l.QtyIn) * l.UnitCost), 2) AS Value
      INTO #G
      FROM dbo.PhStockLedger l JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
     WHERE i.CompanyId = @CompanyId AND (@BranchId IS NULL OR l.BranchId = @BranchId) AND l.DocType IN ('SALE', 'SRET', 'SCAN') AND l.TxnDate >= @From AND l.TxnDate < @end
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId)
     GROUP BY i.ItemId, i.ItemCode, i.ItemName, pc.CategoryName, c.CategoryName, su.UomCode
    HAVING SUM((l.QtyOut - l.QtyIn) * l.UnitCost) > 0;
    DECLARE @total DECIMAL(18,2) = (SELECT SUM(Value) FROM #G);
    SELECT ROW_NUMBER() OVER (ORDER BY Value DESC, ItemName) AS Rn, *, Value * 100 / @total AS SharePct,
           SUM(Value) OVER (ORDER BY Value DESC, ItemName ROWS UNBOUNDED PRECEDING) * 100 / @total AS CumPct
      INTO #C FROM #G;
    -- the item that crosses 70% (or 90%) still belongs to the higher class
    SELECT *, CASE WHEN CumPct - SharePct < 70 THEN 'A' WHEN CumPct - SharePct < 90 THEN 'B' ELSE 'C' END AS Class INTO #R FROM #C;
    DELETE #R WHERE @Option IN ('A', 'B', 'C') AND Class <> @Option;

    SELECT (SELECT COUNT(*) FROM #C) AS Items, ISNULL(@total, 0) AS Value,
           (SELECT COUNT(*) FROM #C WHERE CumPct - SharePct < 70) AS ClassA, (SELECT COUNT(*) FROM #C WHERE CumPct - SharePct >= 70 AND CumPct - SharePct < 90) AS ClassB,
           (SELECT COUNT(*) FROM #C WHERE CumPct - SharePct >= 90) AS ClassC;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(Value) AS Value, SUM(SharePct) AS SharePct FROM #R;
END
GO

-- ── I8 FSN Analysis: fast / slow / non-moving by number of sale lines in the period (F = first 70%, S = rest, N = none) ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_FsnAnalysis
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    -- items in stock now or sold in the period
    SELECT i.ItemId, i.ItemCode, i.ItemName, ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, su.UomCode AS SaleUom,
           ISNULL(sl.Lines, 0) AS SaleLines, ISNULL(sl.Days, 0) AS SaleDays, ISNULL(sl.Qty, 0) AS QtySold, ISNULL(st.Qty, 0) AS Stock, ISNULL(st.CostValue, 0) AS CostValue,
           sl.LastSale
      INTO #G
      FROM dbo.PhItem i JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
      OUTER APPLY (SELECT COUNT(*) AS Lines, COUNT(DISTINCT CAST(l.TxnDate AS DATE)) AS Days, SUM(l.QtyOut) AS Qty, MAX(l.TxnDate) AS LastSale
                     FROM dbo.PhStockLedger l WHERE l.ItemId = i.ItemId AND l.DocType = 'SALE' AND l.TxnDate >= @From AND l.TxnDate < @end
                      AND (@BranchId IS NULL OR l.BranchId = @BranchId)) sl
      OUTER APPLY (SELECT SUM(s.QtyOnHand) AS Qty, ROUND(SUM(s.QtyOnHand * b.LandedCost), 2) AS CostValue FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.ItemId = i.ItemId AND s.QtyOnHand > 0 AND (@BranchId IS NULL OR s.BranchId = @BranchId)) st
     WHERE i.CompanyId = @CompanyId AND (ISNULL(st.Qty, 0) > 0 OR ISNULL(sl.Lines, 0) > 0)
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId);
    DECLARE @lines DECIMAL(18,2) = NULLIF((SELECT SUM(SaleLines) FROM #G), 0);
    SELECT *, SUM(SaleLines) OVER (ORDER BY SaleLines DESC, ItemName ROWS UNBOUNDED PRECEDING) * 100 / @lines AS CumPct,
           SaleLines * 100 / @lines AS SharePct
      INTO #C FROM #G;
    SELECT ROW_NUMBER() OVER (ORDER BY SaleLines DESC, ItemName) AS Rn, *,
           CASE WHEN SaleLines = 0 THEN 'N' WHEN CumPct - SharePct < 70 THEN 'F' ELSE 'S' END AS Class,
           CASE WHEN SaleLines = 0 THEN N'Non-moving' WHEN CumPct - SharePct < 70 THEN N'Fast' ELSE N'Slow' END AS ClassName
      INTO #R FROM #C;
    DELETE #R WHERE @Option IN ('F', 'S', 'N') AND Class <> @Option;

    SELECT (SELECT COUNT(*) FROM #C) AS Items, (SELECT COUNT(*) FROM #C WHERE SaleLines > 0 AND CumPct - SharePct < 70) AS Fast,
           (SELECT COUNT(*) FROM #C WHERE SaleLines > 0 AND CumPct - SharePct >= 70) AS Slow, (SELECT COUNT(*) FROM #C WHERE SaleLines = 0) AS NonMoving,
           ISNULL((SELECT SUM(CostValue) FROM #C WHERE SaleLines = 0), 0) AS NonMovingValue;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(SaleLines) AS SaleLines, SUM(QtySold) AS QtySold, SUM(Stock) AS Stock, SUM(CostValue) AS CostValue FROM #R;
END
GO

-- ── I9 Stock Transfer Register (line by line; a branch sees transfers it sent or received) ──────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_Transfers
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT ROW_NUMBER() OVER (ORDER BY t.RequestDate, t.TransferId, d.TransferDtlId) AS Rn, t.TransferId, t.RequestNo, t.TransferNo, t.RequestDate, t.DispatchDate, t.ReceiveDate,
           fb.BranchCode AS FromBranch, tb.BranchCode AS ToBranch,
           CASE WHEN @BranchId IS NULL THEN N'' WHEN t.FromBranchId = @BranchId THEN N'Out' ELSE N'In' END AS Direction,
           i.ItemName, b.BatchNo, d.RequestQty, d.DispatchQty, d.ReceivedQty,
           CASE WHEN t.Status = 'RECEIVED' THEN ISNULL(d.DispatchQty, 0) - ISNULL(d.ReceivedQty, 0) ELSE 0 END AS ShortQty,
           ROUND(ISNULL(d.DispatchQty, 0) * ISNULL(d.UnitCost, 0), 2) AS SentValue,
           ROUND(CASE WHEN t.Status = 'RECEIVED' THEN (ISNULL(d.DispatchQty, 0) - ISNULL(d.ReceivedQty, 0)) * ISNULL(d.UnitCost, 0) ELSE 0 END, 2) AS ShortValue,
           d.VarianceReason, CASE t.Status WHEN 'REQUESTED' THEN N'Requested' WHEN 'DISPATCHED' THEN N'In transit' WHEN 'RECEIVED' THEN N'Received'
                                          WHEN 'CANCELLED' THEN N'Cancelled' ELSE t.Status END AS Status
      INTO #R
      FROM dbo.PhTransferDtl d JOIN dbo.PhTransfer t ON t.TransferId = d.TransferId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
      LEFT JOIN dbo.PhBatch b ON b.BatchId = d.BatchId JOIN dbo.BranchMaster fb ON fb.BranchID = t.FromBranchId JOIN dbo.BranchMaster tb ON tb.BranchID = t.ToBranchId
     WHERE t.CompanyId = @CompanyId AND (@BranchId IS NULL OR t.FromBranchId = @BranchId OR t.ToBranchId = @BranchId)
       AND t.RequestDate >= @From AND t.RequestDate < @end
       AND (@Option IS NULL OR (@Option = 'TRANSIT' AND t.Status = 'DISPATCHED') OR (@Option = 'SHORT' AND t.Status = 'RECEIVED' AND d.DispatchQty > d.ReceivedQty)
            OR (@Option = 'OUT' AND t.FromBranchId = @BranchId) OR (@Option = 'IN' AND t.ToBranchId = @BranchId))
       AND (@Search IS NULL OR t.RequestNo LIKE @like OR t.TransferNo LIKE @like OR i.ItemName LIKE @like OR b.BatchNo LIKE @like);

    SELECT COUNT(DISTINCT TransferId) AS Transfers, COUNT(*) AS Lines, ISNULL(SUM(SentValue), 0) AS SentValue,
           COUNT(DISTINCT CASE WHEN Status = N'In transit' THEN TransferId END) AS InTransit, ISNULL(SUM(ShortValue), 0) AS ShortValue
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(RequestQty) AS RequestQty, SUM(DispatchQty) AS DispatchQty, SUM(ReceivedQty) AS ReceivedQty, SUM(ShortQty) AS ShortQty,
           SUM(SentValue) AS SentValue, SUM(ShortValue) AS ShortValue
      FROM #R;
END
GO

-- ── I10 Stock Adjustment & Write-off Register (approved documents, line by line) ────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_Adjustments
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT ROW_NUMBER() OVER (ORDER BY a.DocDate, a.AdjustmentId, d.AdjustmentDtlId) AS Rn, a.AdjustmentId, br.BranchCode, a.DocNo, a.DocDate,
           CASE a.Kind WHEN 'WRITEOFF' THEN N'Write-off' WHEN 'PHYSICAL' THEN N'Physical count' ELSE N'Adjustment' END AS KindName, rs.ReasonName,
           i.ItemName, b.BatchNo, b.ExpiryDate, d.QtyChange, d.UnitCost, ROUND(d.QtyChange * d.UnitCost, 2) AS Value, d.Remarks,
           a.DisposalMethod, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = a.CreatedBy) AS MadeBy,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = a.ApprovedBy) AS ApprovedBy, CAST(a.ApprovedDate AS DATE) AS ApprovedDate
      INTO #R
      FROM dbo.PhAdjustmentDtl d JOIN dbo.PhAdjustment a ON a.AdjustmentId = d.AdjustmentId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
      JOIN dbo.PhBatch b ON b.BatchId = d.BatchId JOIN dbo.BranchMaster br ON br.BranchID = a.BranchId LEFT JOIN dbo.PhReason rs ON rs.ReasonId = a.ReasonId
     WHERE a.CompanyId = @CompanyId AND (@BranchId IS NULL OR a.BranchId = @BranchId) AND a.Status = 'APPROVED' AND a.DocDate BETWEEN @From AND @To
       AND (@Option IS NULL OR a.Kind = @Option)
       AND (@Search IS NULL OR a.DocNo LIKE @like OR i.ItemName LIKE @like OR b.BatchNo LIKE @like OR rs.ReasonName LIKE @like);

    SELECT COUNT(DISTINCT AdjustmentId) AS Docs, COUNT(*) AS Lines, ISNULL(SUM(CASE WHEN Value > 0 THEN Value END), 0) AS PlusValue,
           ISNULL(SUM(CASE WHEN Value < 0 THEN -Value END), 0) AS MinusValue, ISNULL(SUM(Value), 0) AS NetValue
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(QtyChange) AS QtyChange, SUM(Value) AS Value FROM #R;
END
GO

-- ── I11 Physical Verification Variance (counts started in the period) ───────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_CountVariance
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT ROW_NUMBER() OVER (ORDER BY k.CreatedDate, k.StockCountId, d.RackNo, i.ItemName) AS Rn, k.StockCountId, br.BranchCode, k.CountNo, k.CreatedDate AS CountDate,
           CASE k.Status WHEN 'COUNTING' THEN N'Counting' WHEN 'SUBMITTED' THEN N'Submitted' WHEN 'APPROVED' THEN N'Approved' WHEN 'REJECTED' THEN N'Rejected'
                         WHEN 'CANCELLED' THEN N'Cancelled' ELSE k.Status END AS Status,
           d.RackNo, i.ItemName, b.BatchNo, b.ExpiryDate, d.SystemQty, d.CountedQty, d.CountedQty - d.SystemQty AS Difference, d.UnitCost,
           ROUND((d.CountedQty - d.SystemQty) * d.UnitCost, 2) AS Value, d.Remarks
      INTO #R
      FROM dbo.PhStockCountDtl d JOIN dbo.PhStockCount k ON k.StockCountId = d.StockCountId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
      JOIN dbo.PhBatch b ON b.BatchId = d.BatchId JOIN dbo.BranchMaster br ON br.BranchID = k.BranchId
     WHERE k.CompanyId = @CompanyId AND (@BranchId IS NULL OR k.BranchId = @BranchId) AND k.CreatedDate >= @From AND k.CreatedDate < @end
       AND d.CountedQty IS NOT NULL AND (ISNULL(@Option, '') <> 'DIFF' OR d.CountedQty <> d.SystemQty)
       AND (@Search IS NULL OR k.CountNo LIKE @like OR i.ItemName LIKE @like OR b.BatchNo LIKE @like OR d.RackNo = @Search);

    SELECT COUNT(DISTINCT StockCountId) AS Counts, COUNT(*) AS Lines, ISNULL(SUM(CASE WHEN Difference <> 0 THEN 1 ELSE 0 END), 0) AS Differences,
           ISNULL(SUM(CASE WHEN Value > 0 THEN Value END), 0) AS Excess, ISNULL(SUM(CASE WHEN Value < 0 THEN -Value END), 0) AS Shortage
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(SystemQty) AS SystemQty, SUM(CountedQty) AS CountedQty, SUM(Difference) AS Difference, SUM(Value) AS Value FROM #R;
END
GO

-- ── I12 Batch Correction Audit ──────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_BatchCorrections
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT ROW_NUMBER() OVER (ORDER BY x.CreatedDate, x.CorrectionId) AS Rn, br.BranchCode, x.DocNo, x.CreatedDate, i.ItemName,
           x.OldBatchNo, x.NewBatchNo, x.OldExpiry, x.NewExpiry, x.OldMrp, x.NewMrp,
           LTRIM(CONCAT(CASE WHEN ISNULL(x.OldBatchNo, N'') <> ISNULL(x.NewBatchNo, N'') THEN N'Batch no ' END,
                        CASE WHEN ISNULL(x.OldExpiry, '19000101') <> ISNULL(x.NewExpiry, '19000101') THEN N'Expiry ' END,
                        CASE WHEN ISNULL(x.OldMrp, 0) <> ISNULL(x.NewMrp, 0) THEN N'MRP' END)) AS Changed,
           x.Reason, CASE x.Status WHEN 'SUBMITTED' THEN N'Awaiting approval' WHEN 'APPROVED' THEN N'Approved' WHEN 'REJECTED' THEN N'Rejected' ELSE x.Status END AS Status,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = x.CreatedBy) AS MadeBy,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = x.ApprovedBy) AS ApprovedBy, x.ApprovedDate, x.ActionRemarks
      INTO #R
      FROM dbo.PhBatchCorrection x JOIN dbo.PhBatch b ON b.BatchId = x.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId JOIN dbo.BranchMaster br ON br.BranchID = x.BranchId
     WHERE x.CompanyId = @CompanyId AND (@BranchId IS NULL OR x.BranchId = @BranchId) AND x.CreatedDate >= @From AND x.CreatedDate < @end
       AND (@Option IS NULL OR x.Status = @Option)
       AND (@Search IS NULL OR x.DocNo LIKE @like OR i.ItemName LIKE @like OR x.OldBatchNo LIKE @like OR x.NewBatchNo LIKE @like);

    SELECT COUNT(*) AS Corrections, ISNULL(SUM(CASE WHEN Status = N'Approved' THEN 1 ELSE 0 END), 0) AS Approved, ISNULL(SUM(CASE WHEN Status = N'Awaiting approval' THEN 1 ELSE 0 END), 0) AS Pending,
           ISNULL(SUM(CASE WHEN Changed LIKE N'%MRP%' THEN 1 ELSE 0 END), 0) AS MrpChanges
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows FROM #R;
END
GO

-- ── I13 Stock Turnover & Days of Inventory: by category (default) or item (@Option ITEM) ────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_StockTurnover
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME)), @days INT = DATEDIFF(DAY, @From, @To) + 1, @item BIT = CASE WHEN @Option = 'ITEM' THEN 1 ELSE 0 END;
    SELECT CASE WHEN @item = 1 THEN i.ItemName ELSE ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName END AS Name,
           CASE WHEN l.TxnDate < @From THEN 1 ELSE 0 END AS Before, l.DocType, (l.QtyIn - l.QtyOut) * l.UnitCost AS V
      INTO #L
      FROM dbo.PhStockLedger l JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
      LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
     WHERE i.CompanyId = @CompanyId AND (@BranchId IS NULL OR l.BranchId = @BranchId) AND l.TxnDate < @end
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId);
    SELECT Name, ROUND(SUM(CASE WHEN Before = 1 THEN V ELSE 0 END), 2) AS OpeningValue, ROUND(SUM(V), 2) AS ClosingValue,
           ROUND(-SUM(CASE WHEN Before = 0 AND DocType IN ('SALE', 'SRET', 'SCAN') THEN V ELSE 0 END), 2) AS Cogs
      INTO #G FROM #L GROUP BY Name;
    SELECT ROW_NUMBER() OVER (ORDER BY Cogs DESC, Name) AS Rn, Name, OpeningValue, ClosingValue, (OpeningValue + ClosingValue) / 2 AS AvgStock, Cogs,
           CASE WHEN (OpeningValue + ClosingValue) / 2 > 0 THEN Cogs / ((OpeningValue + ClosingValue) / 2) END AS Turnover,
           CASE WHEN Cogs > 0 THEN (OpeningValue + ClosingValue) / 2 * @days / Cogs END AS DaysOfStock
      INTO #R FROM #G WHERE OpeningValue <> 0 OR ClosingValue <> 0 OR Cogs <> 0;

    SELECT ISNULL(SUM(Cogs), 0) AS Cogs, ISNULL(SUM(AvgStock), 0) AS AvgStock,
           CASE WHEN SUM(AvgStock) > 0 THEN SUM(Cogs) / SUM(AvgStock) END AS Turnover,
           CASE WHEN SUM(Cogs) > 0 THEN SUM(AvgStock) * @days / SUM(Cogs) END AS DaysOfStock, @days AS Days
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(OpeningValue) AS OpeningValue, SUM(ClosingValue) AS ClosingValue, SUM(AvgStock) AS AvgStock, SUM(Cogs) AS Cogs,
           CASE WHEN SUM(AvgStock) > 0 THEN SUM(Cogs) / SUM(AvgStock) END AS Turnover,
           CASE WHEN SUM(Cogs) > 0 THEN SUM(AvgStock) * @days / SUM(Cogs) END AS DaysOfStock
      FROM #R;
END
GO

-- ── menu: pages directly under Reports > Pharmacy, after the purchase reports ───────────────────────────
DECLARE @Pages TABLE (Code NVARCHAR(100), Title NVARCHAR(150), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT @Pages VALUES
 (N'REPORTS.PHARMACY.CURRENTSTOCK',     N'Current Stock (batch-wise)',          N'CurrentStock',     310, N'bi bi-boxes me-2'),
 (N'REPORTS.PHARMACY.STOCKSUMMARY',     N'Stock Summary (item-wise)',           N'StockSummary',     320, N'bi bi-list-columns me-2'),
 (N'REPORTS.PHARMACY.ITEMLEDGER',       N'Stock Movement / Item Ledger',        N'ItemLedger',       330, N'bi bi-journal-text me-2'),
 (N'REPORTS.PHARMACY.STOCKSTATEMENT',   N'Stock Statement (Opening to Closing)', N'StockStatement',  340, N'bi bi-table me-2'),
 (N'REPORTS.PHARMACY.REORDER',          N'Reorder / Shortage Report',           N'Reorder',          350, N'bi bi-cart-plus me-2'),
 (N'REPORTS.PHARMACY.NONMOVING',        N'Non-moving & Slow-moving Stock',      N'NonMoving',        360, N'bi bi-pause-circle me-2'),
 (N'REPORTS.PHARMACY.ABCANALYSIS',      N'ABC Analysis',                        N'AbcAnalysis',      370, N'bi bi-bar-chart-steps me-2'),
 (N'REPORTS.PHARMACY.FSNANALYSIS',      N'FSN Analysis',                        N'FsnAnalysis',      380, N'bi bi-speedometer me-2'),
 (N'REPORTS.PHARMACY.TRANSFERS',        N'Stock Transfer Register',             N'Transfers',        390, N'bi bi-arrow-left-right me-2'),
 (N'REPORTS.PHARMACY.ADJUSTMENTS',      N'Stock Adjustment & Write-off Register', N'Adjustments',    400, N'bi bi-sliders me-2'),
 (N'REPORTS.PHARMACY.COUNTVARIANCE',    N'Physical Verification Variance',      N'CountVariance',    410, N'bi bi-clipboard-check me-2'),
 (N'REPORTS.PHARMACY.BATCHCORRECTIONS', N'Batch Correction Audit',              N'BatchCorrections', 420, N'bi bi-pencil-square me-2'),
 (N'REPORTS.PHARMACY.STOCKTURNOVER',    N'Stock Turnover & Days of Inventory',  N'StockTurnover',    430, N'bi bi-arrow-repeat me-2');

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

PRINT 'Script 2363 applied: Reports > Pharmacy, stock & inventory reports (I1-I13): report procedures, indexes and pages.';
GO
