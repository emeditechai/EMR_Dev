-- ============================================================================================================
-- Migration: 2365_pharmacy_reports_stores.sql
-- Reports > Pharmacy with pharmacy stores / godowns (2364):
--   Store filter (and a Store column) on Current Stock (I1, now store by store), Stock Summary (I2), Item Ledger (I3, store balance when one
--   store is chosen), Stock Statement (I4), Non-moving (I6), Adjustments (I10), Count Variance (I11), Stock Turnover (I13), Sales Register (S1,
--   counter) and Purchase Register (P1, store received into). Store issues (ISO / ISI) are movements of their own; in the Stock Statement they
--   count with transfers (for the whole branch they cancel out except what was received short).
--   New I14 Store Issue Register (Reports > Pharmacy).  Filter lists: set 9 = stores.
-- Run after 2364. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION dbo.fn_PhLedgerDocName (@DocType VARCHAR(10))
RETURNS NVARCHAR(40)
AS
BEGIN
    RETURN CASE @DocType WHEN 'GRN' THEN N'Purchase (GRN)' WHEN 'PRET' THEN N'Purchase return' WHEN 'SALE' THEN N'Sale' WHEN 'SRET' THEN N'Sale return'
                         WHEN 'SCAN' THEN N'Bill cancelled' WHEN 'TRFO' THEN N'Transfer out' WHEN 'TRFI' THEN N'Transfer in' WHEN 'ADJ' THEN N'Adjustment'
                         WHEN 'WOF' THEN N'Write-off' WHEN 'PCNT' THEN N'Physical count' WHEN 'OPEN' THEN N'Opening stock'
                         WHEN 'ISO' THEN N'Store issue out' WHEN 'ISI' THEN N'Store issue in' ELSE @DocType END;
END
GO

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
    SELECT CAST(st.StoreId AS VARCHAR(10)) AS Value, st.StoreName + CASE WHEN @BranchId IS NULL THEN N' (' + b.BranchCode + N')' ELSE N'' END AS Text
      FROM dbo.PhStore st JOIN dbo.BranchMaster b ON b.BranchID = st.BranchId
     WHERE st.CompanyId = @CompanyId AND (@BranchId IS NULL OR st.BranchId = @BranchId) ORDER BY b.BranchCode, st.StoreName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_SalesRegister
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT ROW_NUMBER() OVER (ORDER BY s.SaleDate, s.SaleId) AS Rn, s.SaleId, b.BranchCode, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = s.StoreId) AS StoreName, s.SaleNo, s.SaleDate,
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
       AND (@UserId IS NULL OR s.CreatedBy = @UserId) AND (@Kind IS NULL OR s.CustomerKind = @Kind) AND (@StoreId IS NULL OR s.StoreId = @StoreId)
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

CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_PurchaseRegister
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT ROW_NUMBER() OVER (ORDER BY g.GrnDate, g.GrnId) AS Rn, g.GrnId, b.BranchCode, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = g.StoreId) AS StoreName, g.GrnNo, g.GrnDate, s.SupplierName, s.Gstin, g.InvoiceNo, g.InvoiceDate,
           po.PoNo, (SELECT COUNT(*) FROM dbo.PhGrnDtl d WHERE d.GrnId = g.GrnId) AS Lines, g.GrossAmount, g.DiscountAmount, g.TaxableAmount,
           g.CgstAmount, g.SgstAmount, g.IgstAmount, g.OtherCharges, g.RoundOff, g.NetAmount, g.DueDate,
           ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment p ON p.PaymentId = a.PaymentId
                    WHERE a.GrnId = g.GrnId AND p.Status = 'POSTED'), 0) AS Paid
      INTO #R
      FROM dbo.PhGrn g JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId JOIN dbo.BranchMaster b ON b.BranchID = g.BranchId
      LEFT JOIN dbo.PhPurchaseOrder po ON po.PoId = g.PoId
     WHERE g.CompanyId = @CompanyId AND (@BranchId IS NULL OR g.BranchId = @BranchId) AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @From AND @To
       AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId) AND (@StoreId IS NULL OR g.StoreId = @StoreId)
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

CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_CurrentStock
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE);
    SELECT ROW_NUMBER() OVER (ORDER BY ISNULL(pc.CategoryName, c.CategoryName), c.CategoryName, i.ItemName, b.ExpiryDate, br.BranchCode, st.StoreName) AS Rn,
           br.BranchCode, st.StoreName, ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, i.ItemCode, i.ItemName, m.ManufacturerName, i.ScheduleCode,
           ib.RackNo, b.BatchNo, b.ExpiryDate, DATEDIFF(DAY, @today, b.ExpiryDate) AS DaysToExpiry, s.QtyOnHand AS Qty, su.UomCode AS SaleUom,
           CASE WHEN i.ConversionQty > 1 THEN s.QtyOnHand / i.ConversionQty END AS Packs, b.LandedCost AS UnitCost,
           ROUND(s.QtyOnHand * b.LandedCost, 2) AS CostValue, ROUND(s.QtyOnHand * b.Mrp / i.ConversionQty, 2) AS MrpValue, sp.SupplierName,
           CASE WHEN b.IsBlocked = 1 THEN N'Blocked' WHEN b.ExpiryDate <= @today THEN N'Expired' WHEN b.ExpiryDate <= DATEADD(DAY, 90, @today) THEN N'Near expiry' ELSE N'' END AS Flag,
           s.ItemId
      INTO #R
      FROM dbo.PhStoreStock s JOIN dbo.PhStore st ON st.StoreId = s.StoreId JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId JOIN dbo.BranchMaster br ON br.BranchID = s.BranchId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
      LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId LEFT JOIN dbo.PhSupplier sp ON sp.SupplierId = b.SupplierId
      LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = s.BranchId
     WHERE b.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.QtyOnHand > 0 AND (@StoreId IS NULL OR s.StoreId = @StoreId)
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

CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_StockSummary
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
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
      OUTER APPLY (SELECT SUM(s.QtyOnHand) AS Qty, COUNT(DISTINCT s.BatchId) AS Batches, MIN(b.ExpiryDate) AS NearestExpiry,
                          ROUND(SUM(s.QtyOnHand * b.LandedCost), 2) AS CostValue, SUM(s.QtyOnHand * b.Mrp) AS MrpRaw
                     FROM dbo.PhStoreStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.ItemId = i.ItemId AND s.QtyOnHand > 0 AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND (@StoreId IS NULL OR s.StoreId = @StoreId)) st
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

CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_NonMoving
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
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
      CROSS APPLY (SELECT SUM(s.QtyOnHand) AS Qty, COUNT(DISTINCT s.BatchId) AS Batches, MIN(b.ExpiryDate) AS NearestExpiry,
                          ROUND(SUM(s.QtyOnHand * b.LandedCost), 2) AS CostValue, SUM(s.QtyOnHand * b.Mrp) AS MrpRaw
                     FROM dbo.PhStoreStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.ItemId = i.ItemId AND s.QtyOnHand > 0 AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND (@StoreId IS NULL OR s.StoreId = @StoreId)) st
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

CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_ItemLedger
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT ROW_NUMBER() OVER (ORDER BY l.TxnDate, l.LedgerId) AS Rn, br.BranchCode, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = l.StoreId) AS StoreName, l.TxnDate, dbo.fn_PhLedgerDocName(l.DocType) AS DocName, l.DocNo,
           i.ItemCode, i.ItemName, b.BatchNo, b.ExpiryDate, l.QtyIn, l.QtyOut, CASE WHEN @StoreId IS NULL THEN l.BalanceAfter ELSE l.StoreBalanceAfter END AS BalanceAfter, l.UnitCost,
           ROUND(l.QtyIn * l.UnitCost, 2) AS ValueIn, ROUND(l.QtyOut * l.UnitCost, 2) AS ValueOut,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = l.CreatedBy) AS UserName
      INTO #R
      FROM dbo.PhStockLedger l JOIN dbo.PhBatch b ON b.BatchId = l.BatchId JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.BranchMaster br ON br.BranchID = l.BranchId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
     WHERE b.CompanyId = @CompanyId AND (@BranchId IS NULL OR l.BranchId = @BranchId) AND l.TxnDate >= @From AND l.TxnDate < @end AND (@StoreId IS NULL OR l.StoreId = @StoreId)
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@Option IS NULL OR (@Option = 'PURCHASE' AND l.DocType IN ('GRN', 'PRET')) OR (@Option = 'SALE' AND l.DocType IN ('SALE', 'SRET', 'SCAN'))
            OR (@Option = 'TRANSFER' AND l.DocType IN ('TRFO', 'TRFI')) OR (@Option = 'ISSUE' AND l.DocType IN ('ISO', 'ISI')) OR (@Option = 'ADJUST' AND l.DocType IN ('ADJ', 'WOF', 'PCNT')))
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search OR b.BatchNo LIKE @like OR l.DocNo LIKE @like);

    SELECT COUNT(*) AS Lines, COUNT(DISTINCT ItemCode) AS Items, ISNULL(SUM(QtyIn), 0) AS QtyIn, ISNULL(SUM(QtyOut), 0) AS QtyOut,
           ISNULL(SUM(ValueIn), 0) AS ValueIn, ISNULL(SUM(ValueOut), 0) AS ValueOut
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(QtyIn) AS QtyIn, SUM(QtyOut) AS QtyOut, SUM(ValueIn) AS ValueIn, SUM(ValueOut) AS ValueOut FROM #R;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_StockStatement
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
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
     WHERE i.CompanyId = @CompanyId AND (@BranchId IS NULL OR l.BranchId = @BranchId) AND l.TxnDate < @end AND (@StoreId IS NULL OR l.StoreId = @StoreId)
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search);
    SELECT ItemCode, Name, MAX(CategoryName) AS CategoryName,
           SUM(CASE WHEN Before = 1 THEN Q ELSE 0 END) AS Opening, ROUND(SUM(CASE WHEN Before = 1 THEN V ELSE 0 END), 2) AS OpeningValue,
           SUM(CASE WHEN Before = 0 AND DocType IN ('GRN', 'PRET', 'OPEN') THEN Q ELSE 0 END) AS Purchases,
           -SUM(CASE WHEN Before = 0 AND DocType IN ('SALE', 'SRET', 'SCAN') THEN Q ELSE 0 END) AS Sales,
           SUM(CASE WHEN Before = 0 AND DocType IN ('TRFI', 'TRFO', 'ISO', 'ISI') THEN Q ELSE 0 END) AS Transfers,
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

CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_StockTurnover
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME)), @days INT = DATEDIFF(DAY, @From, @To) + 1, @item BIT = CASE WHEN @Option = 'ITEM' THEN 1 ELSE 0 END;
    SELECT CASE WHEN @item = 1 THEN i.ItemName ELSE ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName END AS Name,
           CASE WHEN l.TxnDate < @From THEN 1 ELSE 0 END AS Before, l.DocType, (l.QtyIn - l.QtyOut) * l.UnitCost AS V
      INTO #L
      FROM dbo.PhStockLedger l JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
      LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
     WHERE i.CompanyId = @CompanyId AND (@BranchId IS NULL OR l.BranchId = @BranchId) AND l.TxnDate < @end AND (@StoreId IS NULL OR l.StoreId = @StoreId)
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

CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_Adjustments
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT ROW_NUMBER() OVER (ORDER BY a.DocDate, a.AdjustmentId, d.AdjustmentDtlId) AS Rn, a.AdjustmentId, br.BranchCode, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = a.StoreId) AS StoreName, a.DocNo, a.DocDate,
           CASE a.Kind WHEN 'WRITEOFF' THEN N'Write-off' WHEN 'PHYSICAL' THEN N'Physical count' ELSE N'Adjustment' END AS KindName, rs.ReasonName,
           i.ItemName, b.BatchNo, b.ExpiryDate, d.QtyChange, d.UnitCost, ROUND(d.QtyChange * d.UnitCost, 2) AS Value, d.Remarks,
           a.DisposalMethod, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = a.CreatedBy) AS MadeBy,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = a.ApprovedBy) AS ApprovedBy, CAST(a.ApprovedDate AS DATE) AS ApprovedDate
      INTO #R
      FROM dbo.PhAdjustmentDtl d JOIN dbo.PhAdjustment a ON a.AdjustmentId = d.AdjustmentId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
      JOIN dbo.PhBatch b ON b.BatchId = d.BatchId JOIN dbo.BranchMaster br ON br.BranchID = a.BranchId LEFT JOIN dbo.PhReason rs ON rs.ReasonId = a.ReasonId
     WHERE a.CompanyId = @CompanyId AND (@BranchId IS NULL OR a.BranchId = @BranchId) AND a.Status = 'APPROVED' AND a.DocDate BETWEEN @From AND @To AND (@StoreId IS NULL OR a.StoreId = @StoreId)
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

CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_CountVariance
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT ROW_NUMBER() OVER (ORDER BY k.CreatedDate, k.StockCountId, d.RackNo, i.ItemName) AS Rn, k.StockCountId, br.BranchCode, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = k.StoreId) AS StoreName, k.CountNo, k.CreatedDate AS CountDate,
           CASE k.Status WHEN 'COUNTING' THEN N'Counting' WHEN 'SUBMITTED' THEN N'Submitted' WHEN 'APPROVED' THEN N'Approved' WHEN 'REJECTED' THEN N'Rejected'
                         WHEN 'CANCELLED' THEN N'Cancelled' ELSE k.Status END AS Status,
           d.RackNo, i.ItemName, b.BatchNo, b.ExpiryDate, d.SystemQty, d.CountedQty, d.CountedQty - d.SystemQty AS Difference, d.UnitCost,
           ROUND((d.CountedQty - d.SystemQty) * d.UnitCost, 2) AS Value, d.Remarks
      INTO #R
      FROM dbo.PhStockCountDtl d JOIN dbo.PhStockCount k ON k.StockCountId = d.StockCountId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
      JOIN dbo.PhBatch b ON b.BatchId = d.BatchId JOIN dbo.BranchMaster br ON br.BranchID = k.BranchId
     WHERE k.CompanyId = @CompanyId AND (@BranchId IS NULL OR k.BranchId = @BranchId) AND k.CreatedDate >= @From AND k.CreatedDate < @end AND (@StoreId IS NULL OR k.StoreId = @StoreId)
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

-- ── I14 Store Issue Register: godown -> counter, line by line (issued batches) ─────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_StoreIssues
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT ROW_NUMBER() OVER (ORDER BY x.RequestDate, x.IssueId, d.IssueDtlId) AS Rn, x.IssueId, br.BranchCode, x.IssueNo, x.RequestDate, x.IssueDate, x.ReceiveDate,
           f.StoreName AS FromStore, t.StoreName AS ToStore, i.ItemName, b.BatchNo, b.ExpiryDate,
           ISNULL((SELECT SUM(r.RequestQty) FROM dbo.PhStoreIssueDtl r WHERE r.IssueId = x.IssueId AND r.ItemId = d.ItemId AND r.RequestQty > 0), 0) AS Asked,
           d.IssueQty, d.ReceivedQty, CASE WHEN x.Status = 'RECEIVED' THEN ISNULL(d.IssueQty, 0) - ISNULL(d.ReceivedQty, 0) ELSE 0 END AS ShortQty,
           ROUND(ISNULL(d.IssueQty, 0) * ISNULL(d.UnitCost, 0), 2) AS IssuedValue,
           ROUND(CASE WHEN x.Status = 'RECEIVED' THEN (ISNULL(d.IssueQty, 0) - ISNULL(d.ReceivedQty, 0)) * ISNULL(d.UnitCost, 0) ELSE 0 END, 2) AS ShortValue,
           d.VarianceReason, CASE x.Status WHEN 'REQUESTED' THEN N'Requested' WHEN 'ISSUED' THEN N'Issued' WHEN 'RECEIVED' THEN N'Received' WHEN 'CANCELLED' THEN N'Cancelled' ELSE N'Draft' END AS Status,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = x.IssuedBy) AS IssuedBy,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = x.ReceivedBy) AS ReceivedBy
      INTO #R
      FROM dbo.PhStoreIssueDtl d JOIN dbo.PhStoreIssue x ON x.IssueId = d.IssueId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
      JOIN dbo.PhStore f ON f.StoreId = x.FromStoreId JOIN dbo.PhStore t ON t.StoreId = x.ToStoreId JOIN dbo.BranchMaster br ON br.BranchID = x.BranchId
      LEFT JOIN dbo.PhBatch b ON b.BatchId = d.BatchId
     WHERE x.CompanyId = @CompanyId AND (@BranchId IS NULL OR x.BranchId = @BranchId) AND x.RequestDate >= @From AND x.RequestDate < @end
       AND x.Status <> 'DRAFT' AND (d.RequestQty = 0 OR x.Status IN ('REQUESTED', 'CANCELLED'))     -- issued batches; request lines while nothing is issued
       AND (@StoreId IS NULL OR x.FromStoreId = @StoreId OR x.ToStoreId = @StoreId)
       AND (@Option IS NULL OR (@Option = 'PENDING' AND x.Status IN ('REQUESTED', 'ISSUED')) OR (@Option = 'SHORT' AND x.Status = 'RECEIVED' AND d.IssueQty > d.ReceivedQty))
       AND (@Search IS NULL OR x.IssueNo LIKE @like OR i.ItemName LIKE @like OR b.BatchNo LIKE @like);

    SELECT COUNT(DISTINCT IssueId) AS Issues, COUNT(*) AS Lines, ISNULL(SUM(IssuedValue), 0) AS IssuedValue,
           COUNT(DISTINCT CASE WHEN Status IN (N'Requested', N'Issued') THEN IssueId END) AS Pending, ISNULL(SUM(ShortValue), 0) AS ShortValue
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Asked) AS Asked, SUM(IssueQty) AS IssueQty, SUM(ReceivedQty) AS ReceivedQty, SUM(ShortQty) AS ShortQty,
           SUM(IssuedValue) AS IssuedValue, SUM(ShortValue) AS ShortValue
      FROM #R;
END
GO

-- ── menu: I14 under Reports > Pharmacy ─────────────────────────────────────────────────────────────────────
DECLARE @co INT, @reports INT, @ph INT, @page INT, @view INT, @exp INT;
DECLARE co CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS';
OPEN co; FETCH NEXT FROM co INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @reports = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS' AND CompanyId = @co;
    SET @ph = NULL;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @reports, @Menu_Type = 'MENU', @Menu_Code = N'REPORTS.PHARMACY', @Title = N'Pharmacy',
         @Icon = N'bi bi-capsule-pill me-2', @Sort_Order = 25, @UserId = NULL, @Menu_ID = @ph OUTPUT;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @ph, @Page_Code = N'REPORTS.PHARMACY.STOREISSUES', @Title = N'Store Issue Register (Godown to Counter)',
         @Controller = N'PhReports', @Action = N'StoreIssues', @Show_In_Menu = 1, @Sort_Order = 395, @Icon = N'bi bi-box-arrow-in-right me-2', @Route_Values = NULL, @Link_Target = NULL,
         @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    SET @exp = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EXPORT', @Title = N'Export to Excel / PDF', @Sort_Order = 20, @Control_ID = @exp OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = N'StoreIssues', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = N'StoreIssuesData', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @exp, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = N'StoreIssuesExport', @Source = 'SEED';
    FETCH NEXT FROM co INTO @co;
END
CLOSE co; DEALLOCATE co;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2365 applied: Reports > Pharmacy with stores (store filter and column, store issues, I14 Store Issue Register).';
GO
