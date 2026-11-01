-- ============================================================================================================
-- Migration: 2371_pharmacy_reports_finance.sql
-- Reports > Pharmacy, finance & accounts reports (F1-F5 of the Pharmacy Reports plan), read through EMR.Api.
--   F1 Cashier day-end closing (CashClosing, module PHR)   F2 Gross profit bill / item / category-wise (landed cost of the batch sold)
--   F3 Pharmacy trading account (P&L): opening + purchases - closing = cost of goods sold, from stock; beside it what the pharmacy ledgers say
--   F4 Stock vs books: stock value (stock ledger) against the Pharmacy Inventory ledger, document by document
--   F5 Supplier / customer ledger statement (their account ledger: opening, bills, receipts / payments, returns, closing)
--   Books: every active voucher (a cancellation and its reversal net to nil), as the Accounts reports read them.
--   Filter list 10 = parties (supplier and customer ledgers); @LedgerId is passed only by the reports with a party filter.
-- Run after 2370. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
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
    -- 10 parties: the account ledger of each pharmacy supplier and credit customer (2371)
    SELECT CAST(LedgerId AS VARCHAR(10)) AS Value, CASE WHEN LedgerCode LIKE 'PH[_]SUP[_]%' THEN N'Supplier · ' ELSE N'Customer · ' END + LedgerName AS Text
      FROM dbo.Acc_LedgerMaster WHERE LedgerCode LIKE 'PH[_]SUP[_]%' OR LedgerCode LIKE 'PH[_]CUS[_]%' ORDER BY LedgerCode, LedgerName;
END
GO

-- ── F1 Cashier day-end closing ────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_CashierClosing
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL, @LedgerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ROW_NUMBER() OVER (ORDER BY c.BusinessDate, c.CashClosingId) AS Rn, c.CashClosingId, b.BranchCode, c.ClosingNo, c.BusinessDate, c.CutoffAt,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.UserId) AS Cashier,
           c.OpeningFloat, c.CashReceipts, c.CashRefunds, c.PettyOut, c.PettyIn, c.ExpectedCash, c.NonCashTotal, c.CountedCash, c.Difference,
           CASE c.HandoverMode WHEN 'PERSON' THEN N'To person' WHEN 'BANK' THEN N'Bank deposit' WHEN 'SAFE' THEN N'Safe' ELSE c.HandoverMode END AS Handover,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.HandedToUserId) AS HandedTo, c.HandedAmount, c.RetainedFloat,
           CASE c.Status WHEN 'V' THEN N'Verified' WHEN 'S' THEN N'Submitted' WHEN 'R' THEN N'Rejected' WHEN 'D' THEN N'Draft' ELSE c.Status END AS Status,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.VerifiedBy) AS VerifiedBy, c.VerifiedOn, c.Remarks
      INTO #R
      FROM dbo.CashClosing c JOIN dbo.BranchMaster b ON b.BranchID = c.BranchId
     WHERE c.CompanyId = @CompanyId AND (@BranchId IS NULL OR c.BranchId = @BranchId) AND c.Module = 'PHR' AND c.BusinessDate BETWEEN @From AND @To
       AND (@UserId IS NULL OR c.UserId = @UserId) AND (@Option IS NULL OR (@Option = 'SHORT' AND c.Difference < 0) OR (@Option = 'EXCESS' AND c.Difference > 0) OR (@Option = 'PENDING' AND c.Status <> 'V'));
    SELECT COUNT(*) AS Closings, ISNULL(SUM(CashReceipts), 0) AS CashReceipts, ISNULL(SUM(NonCashTotal), 0) AS NonCash, ISNULL(SUM(ExpectedCash), 0) AS Expected,
           ISNULL(SUM(CountedCash), 0) AS Counted, ISNULL(SUM(Difference), 0) AS Difference, ISNULL(SUM(CASE WHEN Status <> N'Verified' THEN 1 ELSE 0 END), 0) AS NotVerified
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(OpeningFloat) AS OpeningFloat, SUM(CashReceipts) AS CashReceipts, SUM(CashRefunds) AS CashRefunds, SUM(PettyOut) AS PettyOut,
           SUM(PettyIn) AS PettyIn, SUM(ExpectedCash) AS ExpectedCash, SUM(NonCashTotal) AS NonCashTotal, SUM(CountedCash) AS CountedCash, SUM(Difference) AS Difference,
           SUM(HandedAmount) AS HandedAmount
      FROM #R;
END
GO

-- ── F2 Gross profit: bill-wise (default), item-wise (@Option ITEM) or category-wise (@Option CATEGORY); sales before GST, net of returns ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_GrossProfit
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL, @LedgerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME)), @by VARCHAR(10) = ISNULL(NULLIF(@Option, ''), 'BILL');
    SELECT s.SaleId, s.SaleNo, s.SaleDate, ISNULL(NULLIF(s.CustomerName, N''), N'Walk-in') AS CustomerName, b.BranchCode, i.ItemId, i.ItemCode, i.ItemName,
           ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, d.Qty - d.ReturnedQty AS Qty,
           CASE WHEN d.Qty = 0 THEN 0 ELSE d.TaxableAmount * (d.Qty - d.ReturnedQty) / d.Qty END AS Sales, d.UnitCost * (d.Qty - d.ReturnedQty) AS Cost,
           d.UnitMrp * (d.Qty - d.ReturnedQty) AS MrpValue
      INTO #L
      FROM dbo.PhSaleDtl d JOIN dbo.PhSale s ON s.SaleId = d.SaleId JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.BranchMaster b ON b.BranchID = s.BranchId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED' AND s.SaleDate >= @From AND s.SaleDate < @end
       AND (@StoreId IS NULL OR s.StoreId = @StoreId) AND (@UserId IS NULL OR s.CreatedBy = @UserId)
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId) AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId)
       AND (@Search IS NULL OR s.SaleNo LIKE @like OR i.ItemName LIKE @like OR s.CustomerName LIKE @like);
    CREATE TABLE #G (Ref NVARCHAR(60), Name NVARCHAR(300), SaleDate DATETIME NULL, SaleId INT NULL, Detail NVARCHAR(300), Bills INT, Qty DECIMAL(18,3),
                     Sales DECIMAL(18,2), Cost DECIMAL(18,2), MrpValue DECIMAL(18,2));
    IF @by = 'ITEM'
        INSERT #G SELECT MAX(ItemCode), MAX(ItemName), NULL, NULL, MAX(CategoryName), COUNT(DISTINCT SaleId), SUM(Qty), ROUND(SUM(Sales), 2), ROUND(SUM(Cost), 2), ROUND(SUM(MrpValue), 2)
                    FROM #L GROUP BY ItemId;
    ELSE IF @by = 'CATEGORY'
        INSERT #G SELECT NULL, CategoryName, NULL, NULL, NULL, COUNT(DISTINCT SaleId), SUM(Qty), ROUND(SUM(Sales), 2), ROUND(SUM(Cost), 2), ROUND(SUM(MrpValue), 2)
                    FROM #L GROUP BY CategoryName;
    ELSE
        INSERT #G SELECT MAX(SaleNo), MAX(CustomerName), MAX(SaleDate), SaleId, MAX(BranchCode), 1, SUM(Qty), ROUND(SUM(Sales), 2), ROUND(SUM(Cost), 2), ROUND(SUM(MrpValue), 2)
                    FROM #L GROUP BY SaleId;
    SELECT ROW_NUMBER() OVER (ORDER BY CASE WHEN @by = 'BILL' THEN 0 ELSE 1 END, SaleDate, Sales - Cost DESC) AS Rn, *, Sales - Cost AS Profit,
           CASE WHEN Sales = 0 THEN 0 ELSE (Sales - Cost) * 100 / Sales END AS ProfitPct
      INTO #R FROM #G WHERE Qty <> 0 OR Sales <> 0;
    SELECT ISNULL(SUM(Sales), 0) AS Sales, ISNULL(SUM(Cost), 0) AS Cost, ISNULL(SUM(Profit), 0) AS Profit,
           CASE WHEN ISNULL(SUM(Sales), 0) = 0 THEN 0 ELSE SUM(Profit) * 100 / SUM(Sales) END AS ProfitPct,
           (SELECT COUNT(DISTINCT SaleId) FROM #L) AS Bills,
           ISNULL((SELECT SUM(CASE WHEN Sales - Cost < 0 THEN 1 ELSE 0 END) FROM #R), 0) AS LossLines
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Bills) AS Bills, SUM(Qty) AS Qty, SUM(Sales) AS Sales, SUM(Cost) AS Cost, SUM(Profit) AS Profit,
           CASE WHEN ISNULL(SUM(Sales), 0) = 0 THEN 0 ELSE SUM(Profit) * 100 / SUM(Sales) END AS ProfitPct, SUM(MrpValue) AS MrpValue
      FROM #R;
END
GO

-- the movement of the pharmacy ledgers in a period (active vouchers), by ledger code
CREATE OR ALTER FUNCTION dbo.fn_PhLedgerMovement (@CompanyId INT, @BranchId INT, @From DATE, @To DATE)
RETURNS TABLE
AS
RETURN
    SELECT l.LedgerCode, SUM(CASE WHEN t.TransactionDate < @From THEN d.DebitAmount - d.CreditAmount ELSE 0 END) AS Opening,
           SUM(CASE WHEN t.TransactionDate >= @From THEN d.DebitAmount ELSE 0 END) AS Debit, SUM(CASE WHEN t.TransactionDate >= @From THEN d.CreditAmount ELSE 0 END) AS Credit
      FROM dbo.Acc_LedgerTransactionDetail d JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = d.LedgerId
     WHERE t.IsActive = 1 AND t.CompanyId = @CompanyId AND (@BranchId IS NULL OR t.BranchId = @BranchId) AND t.TransactionDate < DATEADD(DAY, 1, CAST(@To AS DATETIME))
       AND l.LedgerCode IN ('PH_INVENTORY', 'PH_SALES', 'PH_COGS', 'PH_STOCK_ADJ', 'PH_WRITEOFF')
     GROUP BY l.LedgerCode;
GO

-- ── F3 Pharmacy trading account: from the stock ledger, and what the pharmacy ledgers say beside it ───────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_TradingAccount
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL, @LedgerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    -- stock movements at cost
    DECLARE @open DECIMAL(18,2), @close DECIMAL(18,2), @grn DECIMAL(18,2), @pret DECIMAL(18,2), @trf DECIMAL(18,2), @iss DECIMAL(18,2), @adj DECIMAL(18,2), @wof DECIMAL(18,2), @cogsLedger DECIMAL(18,2);
    SELECT @open = ISNULL(SUM(CASE WHEN l.TxnDate < @From THEN (l.QtyIn - l.QtyOut) * l.UnitCost END), 0),
           @close = ISNULL(SUM((l.QtyIn - l.QtyOut) * l.UnitCost), 0),
           @grn = ISNULL(SUM(CASE WHEN l.TxnDate >= @From AND l.DocType = 'GRN' THEN l.QtyIn * l.UnitCost END), 0),
           @pret = ISNULL(SUM(CASE WHEN l.TxnDate >= @From AND l.DocType = 'PRET' THEN l.QtyOut * l.UnitCost END), 0),
           @trf = ISNULL(SUM(CASE WHEN l.TxnDate >= @From AND l.DocType IN ('TRFI', 'TRFO') THEN (l.QtyIn - l.QtyOut) * l.UnitCost END), 0),
           @iss = ISNULL(SUM(CASE WHEN l.TxnDate >= @From AND l.DocType IN ('ISI', 'ISO') THEN (l.QtyIn - l.QtyOut) * l.UnitCost END), 0),
           @adj = ISNULL(SUM(CASE WHEN l.TxnDate >= @From AND l.DocType IN ('ADJ', 'PCNT') THEN (l.QtyIn - l.QtyOut) * l.UnitCost END), 0),
           @wof = ISNULL(SUM(CASE WHEN l.TxnDate >= @From AND l.DocType = 'WOF' THEN l.QtyOut * l.UnitCost END), 0),
           @cogsLedger = ISNULL(SUM(CASE WHEN l.TxnDate >= @From AND l.DocType IN ('SALE', 'SRET', 'SCAN') THEN (l.QtyOut - l.QtyIn) * l.UnitCost END), 0)
      FROM dbo.PhStockLedger l JOIN dbo.PhItem i ON i.ItemId = l.ItemId
     WHERE i.CompanyId = @CompanyId AND (@BranchId IS NULL OR l.BranchId = @BranchId) AND l.TxnDate < @end;
    DECLARE @sales DECIMAL(18,2) = ISNULL((SELECT SUM(d.TaxableAmount) FROM dbo.PhSaleDtl d JOIN dbo.PhSale s ON s.SaleId = d.SaleId
                                    WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED' AND s.SaleDate >= @From AND s.SaleDate < @end), 0),
            @returns DECIMAL(18,2) = ISNULL((SELECT SUM(r.TaxableAmount) FROM dbo.PhSaleReturn r
                                    WHERE r.CompanyId = @CompanyId AND (@BranchId IS NULL OR r.BranchId = @BranchId) AND r.ReturnDate >= @From AND r.ReturnDate < @end), 0);
    -- cost of goods sold = opening + purchases - returns to suppliers +/- transfers - losses - closing (what was not sold is still on the shelf)
    DECLARE @cogs DECIMAL(18,2) = @open + @grn - @pret + @trf + @iss + @adj - @wof - @close;
    -- books
    DECLARE @bInv DECIMAL(18,2), @bSales DECIMAL(18,2), @bCogs DECIMAL(18,2), @bAdj DECIMAL(18,2), @bWof DECIMAL(18,2);
    SELECT @bInv = ISNULL(SUM(CASE WHEN LedgerCode = 'PH_INVENTORY' THEN Opening + Debit - Credit END), 0),
           @bSales = ISNULL(SUM(CASE WHEN LedgerCode = 'PH_SALES' THEN Credit - Debit END), 0),
           @bCogs = ISNULL(SUM(CASE WHEN LedgerCode = 'PH_COGS' THEN Debit - Credit END), 0),
           @bAdj = ISNULL(SUM(CASE WHEN LedgerCode = 'PH_STOCK_ADJ' THEN Debit - Credit END), 0),
           @bWof = ISNULL(SUM(CASE WHEN LedgerCode = 'PH_WRITEOFF' THEN Debit - Credit END), 0)
      FROM dbo.fn_PhLedgerMovement(@CompanyId, @BranchId, @From, @To);

    DECLARE @R TABLE (Rn INT IDENTITY, Section NVARCHAR(30), Particulars NVARCHAR(200), Amount DECIMAL(18,2), Books DECIMAL(18,2), Kind VARCHAR(10));
    INSERT @R (Section, Particulars, Amount, Books, Kind) VALUES
        (N'Trading account', N'Opening stock (at cost)', @open, NULL, 'DR'),
        (N'Trading account', N'Add: purchases (GRN, landed cost)', @grn, NULL, 'DR'),
        (N'Trading account', N'Less: purchase returns', -@pret, NULL, 'DR'),
        (N'Trading account', N'Add / less: branch transfers in - out', @trf, NULL, 'DR'),
        (N'Trading account', N'Add / less: store issues (short receipts)', @iss, NULL, 'DR'),
        (N'Trading account', N'Add / less: stock adjustments and count differences', @adj, -@bAdj, 'DR'),
        (N'Trading account', N'Less: expiry / damage written off', -@wof, -@bWof, 'DR'),
        (N'Trading account', N'Less: closing stock (at cost)', -@close, -@bInv, 'DR'),
        (N'Trading account', N'Cost of goods sold', @cogs, @bCogs, 'TOT'),
        (N'Sales', N'Sales (before GST)', @sales, NULL, 'CR'),
        (N'Sales', N'Less: sale returns (before GST)', -@returns, NULL, 'CR'),
        (N'Sales', N'Net sales', @sales - @returns, @bSales, 'TOT'),
        (N'Result', N'Gross profit (net sales - cost of goods sold)', @sales - @returns - @cogs, @bSales - @bCogs, 'TOT'),
        (N'Result', N'Stock losses (write-offs, adjustments)', @wof - @adj, @bWof + @bAdj, 'DR'),
        (N'Result', N'Gross profit after stock losses', @sales - @returns - @cogs - (@wof - @adj), @bSales - @bCogs - @bWof - @bAdj, 'TOT');

    SELECT @sales - @returns AS NetSales, @cogs AS Cogs, @sales - @returns - @cogs AS GrossProfit,
           CASE WHEN @sales - @returns = 0 THEN 0 ELSE (@sales - @returns - @cogs) * 100 / (@sales - @returns) END AS GpPct, @close AS ClosingStock,
           @cogsLedger AS CogsOfBills;
    SELECT Rn, Section, Particulars, Amount, Books, CASE WHEN Books IS NULL THEN NULL ELSE Amount - Books END AS Difference, Kind FROM @R ORDER BY Rn;
    SELECT COUNT(*) AS TotalRows FROM @R;
END
GO

-- ── F4 Stock vs books: the stock ledger at cost against the Pharmacy Inventory ledger, document by document ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_StockVsBooks
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL, @LedgerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    -- stock side: the value each document moved
    SELECT CASE l.DocType WHEN 'GRN' THEN 'PH_GRN' WHEN 'PRET' THEN 'PH_PRET' WHEN 'SALE' THEN 'PH_SALE' WHEN 'SCAN' THEN 'PH_SALE' WHEN 'SRET' THEN 'PH_SRET'
                          WHEN 'ADJ' THEN 'PH_ADJ' WHEN 'WOF' THEN 'PH_ADJ' WHEN 'PCNT' THEN 'PH_ADJ' WHEN 'TRFO' THEN 'PH_TRF' WHEN 'TRFI' THEN 'PH_TRF' ELSE 'PH_' + l.DocType END AS Ref,
           l.DocId, MAX(l.DocNo) AS DocNo, MIN(l.TxnDate) AS DocDate, MAX(dbo.fn_PhLedgerDocName(l.DocType)) AS Movement,
           ROUND(SUM((l.QtyIn - l.QtyOut) * l.UnitCost), 2) AS StockValue
      INTO #S
      FROM dbo.PhStockLedger l JOIN dbo.PhItem i ON i.ItemId = l.ItemId
     WHERE i.CompanyId = @CompanyId AND (@BranchId IS NULL OR l.BranchId = @BranchId) AND l.TxnDate >= @From AND l.TxnDate < @end
       AND l.DocType NOT IN ('ISO', 'ISI')                       -- moves between stores: no change in the books
     GROUP BY CASE l.DocType WHEN 'GRN' THEN 'PH_GRN' WHEN 'PRET' THEN 'PH_PRET' WHEN 'SALE' THEN 'PH_SALE' WHEN 'SCAN' THEN 'PH_SALE' WHEN 'SRET' THEN 'PH_SRET'
                          WHEN 'ADJ' THEN 'PH_ADJ' WHEN 'WOF' THEN 'PH_ADJ' WHEN 'PCNT' THEN 'PH_ADJ' WHEN 'TRFO' THEN 'PH_TRF' WHEN 'TRFI' THEN 'PH_TRF' ELSE 'PH_' + l.DocType END, l.DocId;
    -- books side: what each document posted to Pharmacy Inventory
    SELECT CASE WHEN t.ReferenceType IN ('PH_ADJUST', 'PH_WRITEOFF', 'PH_PHYSICAL') THEN 'PH_ADJ' WHEN t.ReferenceType IN ('PH_TRFLOSS', 'PH_TRANSFER') THEN 'PH_TRF' ELSE t.ReferenceType END AS Ref,
           t.ReferenceId AS DocId, MAX(t.VoucherNo) AS VoucherNo, ROUND(SUM(d.DebitAmount - d.CreditAmount), 2) AS BooksValue
      INTO #B
      FROM dbo.Acc_LedgerTransactionDetail d JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId JOIN dbo.Acc_LedgerMaster lm ON lm.LedgerId = d.LedgerId
     WHERE lm.LedgerCode = 'PH_INVENTORY' AND t.IsActive = 1 AND t.CompanyId = @CompanyId AND (@BranchId IS NULL OR t.BranchId = @BranchId)
       AND t.TransactionDate >= @From AND t.TransactionDate < @end
     GROUP BY CASE WHEN t.ReferenceType IN ('PH_ADJUST', 'PH_WRITEOFF', 'PH_PHYSICAL') THEN 'PH_ADJ' WHEN t.ReferenceType IN ('PH_TRFLOSS', 'PH_TRANSFER') THEN 'PH_TRF' ELSE t.ReferenceType END, t.ReferenceId;
    SELECT ROW_NUMBER() OVER (ORDER BY ISNULL(s.DocDate, '29991231'), COALESCE(s.Ref, b.Ref), COALESCE(s.DocId, b.DocId)) AS Rn,
           COALESCE(s.DocNo, b.VoucherNo) AS DocNo, s.DocDate, ISNULL(s.Movement, REPLACE(b.Ref, 'PH_', '')) AS Movement, b.VoucherNo,
           ISNULL(s.StockValue, 0) AS StockValue, ISNULL(b.BooksValue, 0) AS BooksValue, ISNULL(s.StockValue, 0) - ISNULL(b.BooksValue, 0) AS Difference,
           CASE WHEN b.Ref IS NULL THEN N'Not posted to the books' WHEN s.Ref IS NULL THEN N'In the books only' WHEN ABS(ISNULL(s.StockValue, 0) - ISNULL(b.BooksValue, 0)) > 1 THEN N'Amounts differ' ELSE N'' END AS Remark
      INTO #R
      FROM #S s FULL JOIN #B b ON b.Ref = s.Ref AND b.DocId = s.DocId
     WHERE ISNULL(@Option, '') <> 'DIFF' OR ABS(ISNULL(s.StockValue, 0) - ISNULL(b.BooksValue, 0)) > 1;

    DECLARE @stockClose DECIMAL(18,2) = ISNULL((SELECT SUM((l.QtyIn - l.QtyOut) * l.UnitCost) FROM dbo.PhStockLedger l JOIN dbo.PhItem i ON i.ItemId = l.ItemId
                                                WHERE i.CompanyId = @CompanyId AND (@BranchId IS NULL OR l.BranchId = @BranchId) AND l.TxnDate < @end), 0),
            @stockNow DECIMAL(18,2) = ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                                              WHERE b.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId)), 0),
            @books DECIMAL(18,2) = ISNULL((SELECT Opening + Debit - Credit FROM dbo.fn_PhLedgerMovement(@CompanyId, @BranchId, @From, @To) WHERE LedgerCode = 'PH_INVENTORY'), 0);
    SELECT @stockClose AS StockValue, @books AS BooksBalance, @stockClose - @books AS Difference, @stockNow AS StockOnHandNow,
           ISNULL((SELECT COUNT(*) FROM #R WHERE Remark <> N''), 0) AS Exceptions;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(StockValue) AS StockValue, SUM(BooksValue) AS BooksValue, SUM(Difference) AS Difference FROM #R;
END
GO

-- ── F5 Supplier / customer ledger statement: one party (@LedgerId) line by line, or every party's summary ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_PartyLedger
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL, @LedgerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT lm.LedgerId, lm.LedgerCode, lm.LedgerName, CASE WHEN lm.LedgerCode LIKE 'PH[_]SUP[_]%' THEN N'Supplier' ELSE N'Customer' END AS PartyType,
           CASE WHEN lm.OpeningBalanceType = 'Cr' THEN -ISNULL(lm.OpeningBalance, 0) ELSE ISNULL(lm.OpeningBalance, 0) END AS MasterOpening
      INTO #P FROM dbo.Acc_LedgerMaster lm
     WHERE (lm.LedgerCode LIKE 'PH[_]SUP[_]%' OR lm.LedgerCode LIKE 'PH[_]CUS[_]%') AND (@LedgerId IS NULL OR lm.LedgerId = @LedgerId)
       AND (@Option IS NULL OR (@Option = 'SUPPLIER' AND lm.LedgerCode LIKE 'PH[_]SUP[_]%') OR (@Option = 'CUSTOMER' AND lm.LedgerCode LIKE 'PH[_]CUS[_]%'));
    SELECT p.LedgerId, t.TransactionId, t.TransactionDate, t.VoucherNo, t.ReferenceType, ISNULL(NULLIF(d.Narration, N''), t.Narration) AS Narration, d.DebitAmount, d.CreditAmount
      INTO #T
      FROM #P p JOIN dbo.Acc_LedgerTransactionDetail d ON d.LedgerId = p.LedgerId JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId
     WHERE t.IsActive = 1 AND t.CompanyId = @CompanyId AND (@BranchId IS NULL OR t.BranchId = @BranchId) AND t.TransactionDate < @end;
    CREATE TABLE #R (Rn INT, LedgerId INT, PartyType NVARCHAR(20), Party NVARCHAR(200), Opening DECIMAL(18,2), Debit DECIMAL(18,2), Credit DECIMAL(18,2),
                     TransactionDate DATETIME, VoucherNo NVARCHAR(40), Narration NVARCHAR(600), Closing DECIMAL(18,2), DrCr NVARCHAR(2));
    -- debit balance = the party owes us (customer); credit balance = we owe the party (supplier)
    IF @LedgerId IS NULL
    BEGIN
        SELECT ROW_NUMBER() OVER (ORDER BY p.PartyType DESC, p.LedgerName) AS Rn, p.LedgerId, p.PartyType, p.LedgerName AS Party,
               p.MasterOpening + ISNULL(SUM(CASE WHEN t.TransactionDate < @From THEN t.DebitAmount - t.CreditAmount END), 0) AS Opening,
               ISNULL(SUM(CASE WHEN t.TransactionDate >= @From THEN t.DebitAmount END), 0) AS Debit, ISNULL(SUM(CASE WHEN t.TransactionDate >= @From THEN t.CreditAmount END), 0) AS Credit,
               CAST(NULL AS DATETIME) AS TransactionDate, CAST(NULL AS NVARCHAR(40)) AS VoucherNo, CAST(NULL AS NVARCHAR(500)) AS Narration
          INTO #S FROM #P p LEFT JOIN #T t ON t.LedgerId = p.LedgerId GROUP BY p.LedgerId, p.PartyType, p.LedgerName, p.MasterOpening;
        INSERT #R SELECT Rn, LedgerId, PartyType, Party, Opening, Debit, Credit, TransactionDate, VoucherNo, Narration, Opening + Debit - Credit,
                         CASE WHEN Opening + Debit - Credit > 0 THEN N'Dr' WHEN Opening + Debit - Credit < 0 THEN N'Cr' ELSE N'' END
                    FROM #S WHERE Opening <> 0 OR Debit <> 0 OR Credit <> 0;
        SELECT COUNT(*) AS Parties, ISNULL(SUM(Opening), 0) AS Opening, ISNULL(SUM(Debit), 0) AS Debit, ISNULL(SUM(Credit), 0) AS Credit, ISNULL(SUM(Closing), 0) AS ClosingBalance,
               ISNULL(SUM(CASE WHEN PartyType = N'Supplier' THEN -Closing END), 0) AS WeOwe, ISNULL(SUM(CASE WHEN PartyType = N'Customer' THEN Closing END), 0) AS TheyOwe
          FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
        SELECT COUNT(*) AS TotalRows, SUM(Opening) AS Opening, SUM(Debit) AS Debit, SUM(Credit) AS Credit, SUM(Closing) AS Closing FROM #R;
        RETURN;
    END
    -- one party: opening, then each voucher with the running balance
    DECLARE @op DECIMAL(18,2) = (SELECT MasterOpening FROM #P) + ISNULL((SELECT SUM(DebitAmount - CreditAmount) FROM #T WHERE TransactionDate < @From), 0);
    SELECT ROW_NUMBER() OVER (ORDER BY TransactionDate, TransactionId) + 1 AS Rn, LedgerId, (SELECT PartyType FROM #P) AS PartyType, (SELECT LedgerName FROM #P) AS Party,
           CAST(NULL AS DECIMAL(18,2)) AS Opening, DebitAmount AS Debit, CreditAmount AS Credit, TransactionDate, VoucherNo,
           CASE ReferenceType WHEN 'PH_GRN' THEN N'Purchase (GRN) · ' WHEN 'PH_PRET' THEN N'Purchase return · ' WHEN 'PH_SPAY' THEN N'Payment · ' WHEN 'PH_SALE' THEN N'Sale bill · '
                WHEN 'PH_RECEIPT' THEN N'Receipt · ' WHEN 'PH_SRET' THEN N'Sale return · ' WHEN 'PH_REFUND' THEN N'Refund · ' ELSE N'' END + ISNULL(Narration, N'') AS Narration,
           @op + SUM(DebitAmount - CreditAmount) OVER (ORDER BY TransactionDate, TransactionId ROWS UNBOUNDED PRECEDING) AS Closing
      INTO #L FROM #T WHERE TransactionDate >= @From;
    INSERT #R SELECT *, CASE WHEN Closing > 0 THEN N'Dr' WHEN Closing < 0 THEN N'Cr' ELSE N'' END FROM (
        SELECT 1 AS Rn, (SELECT LedgerId FROM #P) AS LedgerId, (SELECT PartyType FROM #P) AS PartyType, (SELECT LedgerName FROM #P) AS Party, @op AS Opening,
               CAST(NULL AS DECIMAL(18,2)) AS Debit, CAST(NULL AS DECIMAL(18,2)) AS Credit, CAST(@From AS DATETIME) AS TransactionDate, CAST(NULL AS NVARCHAR(40)) AS VoucherNo,
               N'Opening balance' AS Narration, @op AS Closing
        UNION ALL SELECT * FROM #L) x;
    DECLARE @cl DECIMAL(18,2) = @op + ISNULL((SELECT SUM(Debit - Credit) FROM #L), 0), @pt NVARCHAR(20) = (SELECT PartyType FROM #P);
    SELECT 1 AS Parties, @op AS Opening, ISNULL((SELECT SUM(Debit) FROM #L), 0) AS Debit, ISNULL((SELECT SUM(Credit) FROM #L), 0) AS Credit, @cl AS ClosingBalance,
           CASE WHEN @pt = N'Supplier' THEN -@cl ELSE 0 END AS WeOwe, CASE WHEN @pt = N'Customer' THEN @cl ELSE 0 END AS TheyOwe;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Debit) AS Debit, SUM(Credit) AS Credit FROM #R;
END
GO

-- ── menu: pages under Reports > Pharmacy, after the GST reports ──────────────────────────────────────────
DECLARE @Pages TABLE (Code NVARCHAR(100), Title NVARCHAR(150), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT @Pages VALUES
 (N'REPORTS.PHARMACY.CASHIERCLOSING', N'Cashier Day-end Closing',              N'CashierClosing', 710, N'bi bi-cash-stack me-2'),
 (N'REPORTS.PHARMACY.GROSSPROFIT',    N'Gross Profit (Bill / Item / Category)', N'GrossProfit',    720, N'bi bi-graph-up me-2'),
 (N'REPORTS.PHARMACY.TRADINGACCOUNT', N'Pharmacy Profit & Loss (Trading A/c)',  N'TradingAccount', 730, N'bi bi-journal-richtext me-2'),
 (N'REPORTS.PHARMACY.STOCKVSBOOKS',   N'Stock vs Books Reconciliation',         N'StockVsBooks',   740, N'bi bi-intersect me-2'),
 (N'REPORTS.PHARMACY.PARTYLEDGER',    N'Supplier / Customer Ledger Statement',  N'PartyLedger',    750, N'bi bi-person-lines-fill me-2');

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

PRINT 'Script 2371 applied: Reports > Pharmacy, finance & accounts reports (F1-F5).';
GO
