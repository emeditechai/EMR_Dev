-- ============================================================================================================
-- Migration: 2369_pharmacy_reports_expiry.sql
-- Reports > Pharmacy, expiry & quality reports (E1-E4 of the Pharmacy Reports plan), read through EMR.Api.
--   Same contract as 2361: common parameters (with @StoreId); result sets 1 tiles · 2 the page of rows (@PageSize 0 = all) · 3 totals + TotalRows.
--   E1 Near-expiry (as on today, 30 / 60 / 90 / 180 days)   E2 Expired stock with what is being done about it (return / write-off)
--   E3 Expiry loss by month (written off vs recovered from suppliers)   E4 Short-expiry receipts (GRN lines under the branch's minimum shelf life)
--   An expiry loss is a write-off whose reason speaks of expiry or whose batch had expired; a recovery is a purchase return of such a batch
--   (expired, or expiring within 90 days of the return) or with an expiry reason.
-- Run after 2368. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── E1 Near-Expiry Report ────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_NearExpiry
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE),
            @days INT = CASE WHEN @Option IN ('30', '60', '90', '180') THEN CAST(@Option AS INT) ELSE 90 END;
    SELECT ROW_NUMBER() OVER (ORDER BY b.ExpiryDate, i.ItemName, st.StoreName) AS Rn, br.BranchCode, st.StoreName, i.ItemCode, i.ItemName,
           ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, m.ManufacturerName, ib.RackNo, b.BatchNo, b.ExpiryDate,
           DATEDIFF(DAY, @today, b.ExpiryDate) AS DaysLeft,
           CASE WHEN DATEDIFF(DAY, @today, b.ExpiryDate) <= 30 THEN N'0-30 days' WHEN DATEDIFF(DAY, @today, b.ExpiryDate) <= 60 THEN N'31-60 days'
                WHEN DATEDIFF(DAY, @today, b.ExpiryDate) <= 90 THEN N'61-90 days' ELSE N'91-180 days' END AS Band,
           s.QtyOnHand AS Qty, su.UomCode AS SaleUom, ROUND(s.QtyOnHand * b.LandedCost, 2) AS CostValue, ROUND(s.QtyOnHand * b.Mrp / i.ConversionQty, 2) AS MrpValue,
           sp.SupplierName, sp.Phone AS SupplierPhone,
           ISNULL((SELECT SUM(l.QtyOut - l.QtyIn) FROM dbo.PhStockLedger l WHERE l.ItemId = i.ItemId AND l.BranchId = s.BranchId AND l.DocType IN ('SALE', 'SRET', 'SCAN')
                     AND l.TxnDate >= DATEADD(DAY, -30, @today)), 0) AS Sold30,
           s.ItemId
      INTO #R
      FROM dbo.PhStoreStock s JOIN dbo.PhStore st ON st.StoreId = s.StoreId JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId
      JOIN dbo.BranchMaster br ON br.BranchID = s.BranchId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
      LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId LEFT JOIN dbo.PhSupplier sp ON sp.SupplierId = b.SupplierId
      LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = s.BranchId
     WHERE b.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND (@StoreId IS NULL OR s.StoreId = @StoreId) AND s.QtyOnHand > 0
       AND b.ExpiryDate > @today AND b.ExpiryDate <= DATEADD(DAY, @days, @today)
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId) AND (@SupplierId IS NULL OR b.SupplierId = @SupplierId)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search OR b.BatchNo LIKE @like OR ib.RackNo = @Search);
    -- what will be left on expiry at the last 30 days' selling rate
    ALTER TABLE #R ADD UnsoldAtExpiry DECIMAL(14,3);
    UPDATE #R SET UnsoldAtExpiry = CASE WHEN Qty - Sold30 / 30.0 * DaysLeft > 0 THEN ROUND(Qty - Sold30 / 30.0 * DaysLeft, 0) ELSE 0 END;

    SELECT COUNT(*) AS Batches, COUNT(DISTINCT ItemId) AS Items, ISNULL(SUM(CostValue), 0) AS CostValue, ISNULL(SUM(MrpValue), 0) AS MrpValue,
           ISNULL(SUM(CASE WHEN DaysLeft <= 30 THEN CostValue END), 0) AS Within30
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(CostValue) AS CostValue, SUM(MrpValue) AS MrpValue, SUM(UnsoldAtExpiry) AS UnsoldAtExpiry FROM #R;
END
GO

-- ── E2 Expired Stock: expired batches still in stock and what is being done about them ──────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_ExpiredStock
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE);
    SELECT br.BranchCode, st.StoreName, i.ItemCode, i.ItemName, b.BatchId, b.BatchNo, b.ExpiryDate, DATEDIFF(DAY, b.ExpiryDate, @today) AS DaysExpired,
           s.QtyOnHand AS Qty, su.UomCode AS SaleUom, ROUND(s.QtyOnHand * b.LandedCost, 2) AS CostValue, ROUND(s.QtyOnHand * b.Mrp / i.ConversionQty, 2) AS MrpValue,
           sp.SupplierName, sp.Phone AS SupplierPhone, b.IsBlocked,
           (SELECT TOP 1 ISNULL(r.ReturnNo + N' ', N'') + N'(' + LOWER(r.Status) + N')' FROM dbo.PhPurchaseReturnDtl rd JOIN dbo.PhPurchaseReturn r ON r.ReturnId = rd.ReturnId
             WHERE rd.BatchId = b.BatchId AND r.BranchId = s.BranchId AND r.Status = 'DRAFT' ORDER BY r.ReturnId DESC) AS ReturnDoc,
           (SELECT TOP 1 ISNULL(a.DocNo + N' ', N'') + N'(' + LOWER(a.Status) + N')' FROM dbo.PhAdjustmentDtl ad JOIN dbo.PhAdjustment a ON a.AdjustmentId = ad.AdjustmentId
             WHERE ad.BatchId = b.BatchId AND a.BranchId = s.BranchId AND a.Kind = 'WRITEOFF' AND a.Status IN ('DRAFT', 'SUBMITTED') ORDER BY a.AdjustmentId DESC) AS WriteOffDoc
      INTO #G
      FROM dbo.PhStoreStock s JOIN dbo.PhStore st ON st.StoreId = s.StoreId JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId
      JOIN dbo.BranchMaster br ON br.BranchID = s.BranchId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
      LEFT JOIN dbo.PhSupplier sp ON sp.SupplierId = b.SupplierId
     WHERE b.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND (@StoreId IS NULL OR s.StoreId = @StoreId)
       AND s.QtyOnHand > 0 AND b.ExpiryDate <= @today
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@SupplierId IS NULL OR b.SupplierId = @SupplierId)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search OR b.BatchNo LIKE @like);
    SELECT ROW_NUMBER() OVER (ORDER BY ExpiryDate, ItemName) AS Rn, *,
           CASE WHEN WriteOffDoc IS NOT NULL THEN N'Write-off ' + WriteOffDoc WHEN ReturnDoc IS NOT NULL THEN N'Return ' + ReturnDoc
                ELSE N'Awaiting return / destruction' END AS Action
      INTO #R FROM #G
     WHERE ISNULL(@Option, '') = '' OR (@Option = 'OPEN' AND WriteOffDoc IS NULL AND ReturnDoc IS NULL) OR (@Option = 'INHAND' AND (WriteOffDoc IS NOT NULL OR ReturnDoc IS NOT NULL));

    SELECT COUNT(*) AS Batches, ISNULL(SUM(CostValue), 0) AS CostValue, ISNULL(SUM(MrpValue), 0) AS MrpValue,
           ISNULL(SUM(CASE WHEN WriteOffDoc IS NULL AND ReturnDoc IS NULL THEN 1 ELSE 0 END), 0) AS NoAction, ISNULL(SUM(CASE WHEN IsBlocked = 0 THEN 1 ELSE 0 END), 0) AS NotBlocked
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(CostValue) AS CostValue, SUM(MrpValue) AS MrpValue FROM #R;
END
GO

-- ── E3 Expiry Loss Report, month by month ────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_ExpiryLoss
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- written off because of expiry (approved write-offs)
    SELECT DATEFROMPARTS(YEAR(a.DocDate), MONTH(a.DocDate), 1) AS Mon, -SUM(d.QtyChange * d.UnitCost) AS V, COUNT(DISTINCT d.BatchId) AS N
      INTO #W
      FROM dbo.PhAdjustmentDtl d JOIN dbo.PhAdjustment a ON a.AdjustmentId = d.AdjustmentId JOIN dbo.PhBatch b ON b.BatchId = d.BatchId
      LEFT JOIN dbo.PhReason rs ON rs.ReasonId = a.ReasonId
     WHERE a.CompanyId = @CompanyId AND (@BranchId IS NULL OR a.BranchId = @BranchId) AND (@StoreId IS NULL OR a.StoreId = @StoreId)
       AND a.Kind = 'WRITEOFF' AND a.Status = 'APPROVED' AND a.DocDate BETWEEN @From AND @To AND d.QtyChange < 0
       AND (rs.ReasonName LIKE N'%expir%' OR b.ExpiryDate <= a.DocDate) AND (@SupplierId IS NULL OR b.SupplierId = @SupplierId)
     GROUP BY DATEFROMPARTS(YEAR(a.DocDate), MONTH(a.DocDate), 1);
    -- recovered from suppliers: purchase returns of expired / short-dated batches
    SELECT DATEFROMPARTS(YEAR(r.ReturnDate), MONTH(r.ReturnDate), 1) AS Mon, SUM(d.TaxableAmount) AS V, COUNT(DISTINCT d.BatchId) AS N
      INTO #P
      FROM dbo.PhPurchaseReturnDtl d JOIN dbo.PhPurchaseReturn r ON r.ReturnId = d.ReturnId JOIN dbo.PhBatch b ON b.BatchId = d.BatchId
      LEFT JOIN dbo.PhReason rs ON rs.ReasonId = r.ReasonId
     WHERE r.CompanyId = @CompanyId AND (@BranchId IS NULL OR r.BranchId = @BranchId) AND (@StoreId IS NULL OR r.StoreId = @StoreId)
       AND r.Status = 'POSTED' AND r.ReturnDate BETWEEN @From AND @To AND (@SupplierId IS NULL OR r.SupplierId = @SupplierId)
       AND (rs.ReasonName LIKE N'%expir%' OR b.ExpiryDate <= DATEADD(DAY, 90, r.ReturnDate))
     GROUP BY DATEFROMPARTS(YEAR(r.ReturnDate), MONTH(r.ReturnDate), 1);
    -- purchases of the month, for the loss as a share of what was bought
    SELECT DATEFROMPARTS(YEAR(g.GrnDate), MONTH(g.GrnDate), 1) AS Mon, SUM(g.TaxableAmount) AS V
      INTO #B
      FROM dbo.PhGrn g
     WHERE g.CompanyId = @CompanyId AND (@BranchId IS NULL OR g.BranchId = @BranchId) AND (@StoreId IS NULL OR g.StoreId = @StoreId)
       AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @From AND @To AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId)
     GROUP BY DATEFROMPARTS(YEAR(g.GrnDate), MONTH(g.GrnDate), 1);
    -- every month of the period
    WITH m AS (SELECT DATEFROMPARTS(YEAR(@From), MONTH(@From), 1) AS Mon UNION ALL SELECT DATEADD(MONTH, 1, Mon) FROM m WHERE DATEADD(MONTH, 1, Mon) <= @To)
    SELECT ROW_NUMBER() OVER (ORDER BY m.Mon) AS Rn, FORMAT(m.Mon, 'MMM yyyy', 'en-US') AS Month,
           ISNULL(w.N, 0) AS BatchesWrittenOff, CAST(ROUND(ISNULL(w.V, 0), 2) AS DECIMAL(18,2)) AS WrittenOff,
           ISNULL(p.N, 0) AS BatchesReturned, CAST(ROUND(ISNULL(p.V, 0), 2) AS DECIMAL(18,2)) AS Recovered,
           CAST(ROUND(ISNULL(w.V, 0), 2) AS DECIMAL(18,2)) AS NetLoss, CAST(ISNULL(b.V, 0) AS DECIMAL(18,2)) AS Purchases,
           CASE WHEN ISNULL(b.V, 0) = 0 THEN NULL ELSE ISNULL(w.V, 0) * 100 / b.V END AS LossPct,
           CASE WHEN ISNULL(w.V, 0) + ISNULL(p.V, 0) = 0 THEN NULL ELSE ISNULL(p.V, 0) * 100 / (ISNULL(w.V, 0) + ISNULL(p.V, 0)) END AS RecoveryPct
      INTO #R
      FROM m LEFT JOIN #W w ON w.Mon = m.Mon LEFT JOIN #P p ON p.Mon = m.Mon LEFT JOIN #B b ON b.Mon = m.Mon
    OPTION (MAXRECURSION 400);

    SELECT ISNULL(SUM(WrittenOff), 0) AS WrittenOff, ISNULL(SUM(Recovered), 0) AS Recovered, ISNULL(SUM(NetLoss), 0) AS NetLoss,
           CASE WHEN ISNULL(SUM(Purchases), 0) = 0 THEN 0 ELSE SUM(NetLoss) * 100 / SUM(Purchases) END AS LossPct,
           CASE WHEN ISNULL(SUM(WrittenOff + Recovered), 0) = 0 THEN 0 ELSE SUM(Recovered) * 100 / SUM(WrittenOff + Recovered) END AS RecoveryPct
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(BatchesWrittenOff) AS BatchesWrittenOff, SUM(WrittenOff) AS WrittenOff, SUM(BatchesReturned) AS BatchesReturned,
           SUM(Recovered) AS Recovered, SUM(NetLoss) AS NetLoss, SUM(Purchases) AS Purchases,
           CASE WHEN ISNULL(SUM(Purchases), 0) = 0 THEN NULL ELSE SUM(NetLoss) * 100 / SUM(Purchases) END AS LossPct,
           CASE WHEN ISNULL(SUM(WrittenOff + Recovered), 0) = 0 THEN NULL ELSE SUM(Recovered) * 100 / SUM(WrittenOff + Recovered) END AS RecoveryPct
      FROM #R;
END
GO

-- ── E4 Short-Expiry Receipts: GRN lines received with less than the branch's minimum shelf life ──────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_ShortExpiryReceipts
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT g.GrnId, br.BranchCode, g.GrnNo, g.GrnDate, s.SupplierName, g.InvoiceNo, i.ItemName, d.BatchNo, d.ExpiryDate,
           DATEDIFF(DAY, g.GrnDate, d.ExpiryDate) AS ShelfDays,
           ISNULL((SELECT TOP 1 h.PharmacyMinShelfLifeGrnDays FROM dbo.HospitalSettings h WHERE h.BranchId = g.BranchId ORDER BY h.IsActive DESC), 180) AS MinShelfDays,
           d.Qty + d.FreeQty AS Qty, pu.UomCode AS PurchaseUom, d.TaxableAmount AS Value
      INTO #G
      FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId
      JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId JOIN dbo.BranchMaster br ON br.BranchID = g.BranchId
     WHERE g.CompanyId = @CompanyId AND (@BranchId IS NULL OR g.BranchId = @BranchId) AND (@StoreId IS NULL OR g.StoreId = @StoreId)
       AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @From AND @To AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId)
       AND (@Search IS NULL OR g.GrnNo LIKE @like OR i.ItemName LIKE @like OR d.BatchNo LIKE @like OR s.SupplierName LIKE @like);
    SELECT ROW_NUMBER() OVER (ORDER BY ShelfDays, GrnDate) AS Rn, *, MinShelfDays - ShelfDays AS DaysShort
      INTO #R FROM #G
     WHERE ShelfDays < MinShelfDays OR (@Option = 'ALL');
    -- per supplier: how often the supplier sends short-dated stock
    SELECT COUNT(*) AS Lines, COUNT(DISTINCT SupplierName) AS Suppliers, ISNULL(SUM(Value), 0) AS Value,
           (SELECT TOP 1 SupplierName FROM #R WHERE ShelfDays < MinShelfDays GROUP BY SupplierName ORDER BY COUNT(*) DESC, SUM(Value) DESC) AS WorstSupplier,
           CASE WHEN (SELECT COUNT(*) FROM #G) = 0 THEN 0 ELSE (SELECT COUNT(*) FROM #G WHERE ShelfDays < MinShelfDays) * 100.0 / (SELECT COUNT(*) FROM #G) END AS ShortPct
      FROM #R WHERE ShelfDays < MinShelfDays;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(Value) AS Value FROM #R;
END
GO

-- ── menu: pages under Reports > Pharmacy, after the stock reports ────────────────────────────────────────
DECLARE @Pages TABLE (Code NVARCHAR(100), Title NVARCHAR(150), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT @Pages VALUES
 (N'REPORTS.PHARMACY.NEAREXPIRY',          N'Near-Expiry Report',            N'NearExpiry',          510, N'bi bi-hourglass-bottom me-2'),
 (N'REPORTS.PHARMACY.EXPIREDSTOCK',        N'Expired Stock Report',          N'ExpiredStock',        520, N'bi bi-x-octagon me-2'),
 (N'REPORTS.PHARMACY.EXPIRYLOSS',          N'Expiry Loss Report',            N'ExpiryLoss',          530, N'bi bi-graph-down-arrow me-2'),
 (N'REPORTS.PHARMACY.SHORTEXPIRYRECEIPTS', N'Short-Expiry Receipts',         N'ShortExpiryReceipts', 540, N'bi bi-calendar2-x me-2');

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

PRINT 'Script 2369 applied: Reports > Pharmacy, expiry & quality reports (E1-E4).';
GO
