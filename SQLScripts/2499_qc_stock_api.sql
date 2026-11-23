-- ============================================================================================================
-- Migration: 2499_qc_stock_api.sql   (after 2498)
-- Description: Quality & Compliance > Stock Management - the procedures behind EMR.Api api/qc/stock.
--   Reads:  usp_Api_QcInv_Lookups, _DocList, _DocGet, _Stock, _ItemLedger, _LotsForPick, _Fefo, _IndentForIssue,
--           _Reorder, _Lots, _Pending, _Dashboard, _Report
--   Writes (one row: Success, Error, ...): usp_Api_QcInv_DocSave, _DocAction, _CountCreate, _LotAction, _MarkOpened,
--           _PendingRetry, _PendingSkip, _SettingsSave, _PostConsumption
--   Stock coming in (opening, GRN, received issue, adjustment / count posted) settles PENDING test consumption of
--   those items in that branch automatically, after the document commits; so does accepting / unblocking a lot.
--   Goods receipt: batch / lot number and expiry are required on every line (user decision 2026-11-20).
--   Document flow:
--     OPN  DRAFT -> POSTED
--     PO   DRAFT -> SUBMITTED -> APPROVED -> PARTIAL -> CLOSED (by GRNs or short-closed); approval can be switched off
--     GRN  DRAFT -> POSTED (lots created; reagent / kit / control lots in QUARANTINE until accepted)
--     PRET DRAFT -> POSTED
--     IND  DRAFT -> SUBMITTED -> PARTIAL -> CLOSED (by issues) | REJECTED by the supplying store
--     ISS  DRAFT -> INTRANSIT (dispatched, out of the from-store) -> RECEIVED (into the to-store; a shortage is a loss)
--     ADJ  DRAFT -> SUBMITTED -> POSTED on approval (or straight to POSTED when approval is off)
--     CNT  DRAFT (counts) -> SUBMITTED -> POSTED on approval
--   Approver is never the maker (except a Super Admin). Refusals: THROW 53600-53799 (message shown as is).
--   Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION dbo.ufn_Inv_UserName (@UserId INT)
RETURNS NVARCHAR(200)
AS
BEGIN
    RETURN (SELECT ISNULL(NULLIF(LTRIM(RTRIM(FullName)), ''), Username) FROM dbo.Users WHERE Id = @UserId);
END;
GO

CREATE OR ALTER FUNCTION dbo.ufn_Inv_DocTypeName (@DocType VARCHAR(6))
RETURNS NVARCHAR(40)
AS
BEGIN
    RETURN CASE @DocType WHEN 'OPN' THEN N'Opening stock' WHEN 'PO' THEN N'Purchase order' WHEN 'GRN' THEN N'Goods receipt' WHEN 'PRET' THEN N'Purchase return'
        WHEN 'IND' THEN N'Indent' WHEN 'ISS' THEN N'Issue / transfer' WHEN 'ISSO' THEN N'Issue out' WHEN 'ISSI' THEN N'Issue received'
        WHEN 'ADJ' THEN N'Adjustment' WHEN 'CNT' THEN N'Stock count' WHEN 'CONS' THEN N'Test consumption' ELSE @DocType END;
END;
GO

-- ═════ Lookups ═════════════════════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_Lookups @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.StoreId, s.StoreCode, s.StoreName, s.StoreType, s.BranchId, b.BranchName, s.DepartmentId, d.DeptName AS DepartmentName,
           CAST(CASE WHEN s.BranchId = @BranchId THEN 1 ELSE 0 END AS BIT) AS IsMine,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.InvStockLedger g WHERE g.StoreId = s.StoreId) THEN 1 ELSE 0 END AS BIT) AS HasStock
    FROM dbo.InvStore s LEFT JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = s.DepartmentId
    WHERE s.CompanyId = @CompanyId AND s.IsDeleted = 0 AND s.Status = 1
    ORDER BY CASE WHEN s.BranchId = @BranchId THEN 0 ELSE 1 END, b.BranchName, CASE s.StoreType WHEN 'Main' THEN 0 ELSE 1 END, s.StoreName;

    SELECT SupplierId, SupplierCode, SupplierName, Gstin, IsApproved, PaymentTermsDays
    FROM dbo.InvSupplier WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND Status = 1 ORDER BY SupplierName;

    SELECT i.ItemId, i.ItemCode, i.ItemName, i.CategoryId, c.CategoryName, pu.UnitName AS PurchaseUnit, cu.UnitName AS ConsumptionUnit, i.PackSize,
           i.PurchaseRate, ISNULL(i.GstPercent, 0) AS GstPercent, i.IsLotTracked, i.IsExpiryTracked, c.RequiresAcceptance, i.MinShelfLifeDays,
           i.OpenStabilityDays, i.ReorderLevel, i.MinStock, i.MaxStock, i.AvgUnitCost, dbo.ufn_Qc_ItemUnitCost(i.ItemId) AS UnitCost, i.Manufacturer
    FROM dbo.InvItem i JOIN dbo.InvItemCategory c ON c.CategoryId = i.CategoryId
    JOIN dbo.InvUnit pu ON pu.UnitId = i.PurchaseUnitId JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    WHERE i.CompanyId = @CompanyId AND i.IsDeleted = 0 AND i.Status = 1
    ORDER BY i.ItemName;

    SELECT ReasonCode AS Id, ReasonName AS Name, Direction, IsUsage FROM dbo.InvAdjReason WHERE IsActive = 1 ORDER BY SortOrder;

    SELECT * FROM dbo.ufn_Inv_Settings(@CompanyId);

    SELECT CategoryId AS Id, CategoryName AS Name, RequiresAcceptance FROM dbo.InvItemCategory WHERE IsActive = 1 ORDER BY SortOrder;
END;
GO

-- ═════ Document list ══════════════════════════════════════════════════════════════════════════════════════
-- @Scope: OUT = documents of my branch (default); IN = indents asked of / issues sent to my branch's stores
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_DocList
    @CompanyId INT, @BranchId INT, @DocType VARCHAR(6), @Status VARCHAR(12) = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL,
    @Search NVARCHAR(100) = NULL, @Scope VARCHAR(3) = 'OUT', @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @Status = NULLIF(@Status, ''); SET @Scope = ISNULL(NULLIF(@Scope, ''), 'OUT');
    SELECT TOP 500 d.DocId, d.DocType, d.DocNo, d.DocDate, d.Status, d.StoreId, s.StoreName, sb.BranchName AS StoreBranch,
           d.ToStoreId, ts.StoreName AS ToStoreName, tb.BranchName AS ToBranchName, d.SupplierId, sp.SupplierName,
           r.DocNo AS RefDocNo, d.SupplierInvNo, d.SupplierInvDate, d.ExpectedDate, d.Priority, ar.ReasonName,
           (SELECT COUNT(1) FROM dbo.InvDocLine l WHERE l.DocId = d.DocId) AS LineCount,
           d.NetAmount, d.TaxableAmount, d.StockValue, d.VoucherNo,
           dbo.ufn_Inv_UserName(d.CreatedBy) AS CreatedByName, d.CreatedOn, d.CreatedBy,
           dbo.ufn_Inv_UserName(d.ApprovedBy) AS ApprovedByName, d.ApprovedOn, d.PostedOn, d.ReceivedOn, d.RejectReason,
           CAST(CASE WHEN d.BranchId = @BranchId THEN 1 ELSE 0 END AS BIT) AS IsMine,
           CAST(CASE WHEN ts.BranchId = @BranchId THEN 1 ELSE 0 END AS BIT) AS IsToMine
    FROM dbo.InvDoc d
    JOIN dbo.InvStore s ON s.StoreId = d.StoreId
    LEFT JOIN dbo.Branchmaster sb ON sb.BranchID = s.BranchId
    LEFT JOIN dbo.InvStore ts ON ts.StoreId = d.ToStoreId
    LEFT JOIN dbo.Branchmaster tb ON tb.BranchID = ts.BranchId
    LEFT JOIN dbo.InvSupplier sp ON sp.SupplierId = d.SupplierId
    LEFT JOIN dbo.InvDoc r ON r.DocId = d.RefDocId
    LEFT JOIN dbo.InvAdjReason ar ON ar.ReasonCode = d.ReasonCode
    WHERE d.CompanyId = @CompanyId AND d.DocType = @DocType
      AND ((@Scope = 'OUT' AND d.BranchId = @BranchId) OR (@Scope = 'IN' AND ts.BranchId = @BranchId AND d.Status NOT IN ('DRAFT', 'CANCELLED'))
           OR (@Scope = 'ALL' AND (d.BranchId = @BranchId OR ts.BranchId = @BranchId)))
      AND (@Status IS NULL OR d.Status = @Status OR (@Status = 'OPEN' AND d.Status IN ('DRAFT', 'SUBMITTED', 'APPROVED', 'PARTIAL', 'INTRANSIT')))
      AND (@FromDate IS NULL OR d.DocDate >= @FromDate) AND (@ToDate IS NULL OR d.DocDate <= @ToDate)
      AND (@StoreId IS NULL OR d.StoreId = @StoreId OR d.ToStoreId = @StoreId)
      AND (@Search IS NULL OR d.DocNo LIKE '%' + @Search + '%' OR sp.SupplierName LIKE '%' + @Search + '%' OR d.SupplierInvNo LIKE '%' + @Search + '%'
           OR EXISTS (SELECT 1 FROM dbo.InvDocLine l JOIN dbo.InvItem i ON i.ItemId = l.ItemId WHERE l.DocId = d.DocId
                      AND (i.ItemName LIKE '%' + @Search + '%' OR i.ItemCode LIKE '%' + @Search + '%' OR l.LotNo LIKE '%' + @Search + '%')))
    ORDER BY d.DocDate DESC, d.DocId DESC;
END;
GO

-- ═════ One document ═══════════════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_DocGet @CompanyId INT, @BranchId INT, @DocId INT, @DocType VARCHAR(6) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- the screen's own document type only (a document of another type reads as not found)
    IF @DocType IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.InvDoc WHERE DocId = @DocId AND DocType = @DocType) SET @DocId = -1;
    SELECT d.*, s.StoreName, s.StoreCode, sb.BranchName AS StoreBranch, sb.Address AS BranchAddress, ts.StoreName AS ToStoreName, tb.BranchName AS ToBranchName,
           sp.SupplierName, sp.SupplierCode, sp.Gstin AS SupplierGstin, sp.Address AS SupplierAddress, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail,
           sp.IsApproved AS SupplierApproved, r.DocNo AS RefDocNo, r.DocType AS RefDocType, ar.ReasonName, c.CategoryName,
           dbo.ufn_Inv_DocTypeName(d.DocType) AS DocTypeName,
           dbo.ufn_Inv_UserName(d.CreatedBy) AS CreatedByName, dbo.ufn_Inv_UserName(d.SubmittedBy) AS SubmittedByName,
           dbo.ufn_Inv_UserName(d.ApprovedBy) AS ApprovedByName, dbo.ufn_Inv_UserName(d.RejectedBy) AS RejectedByName,
           dbo.ufn_Inv_UserName(d.PostedBy) AS PostedByName, dbo.ufn_Inv_UserName(d.ReceivedBy) AS ReceivedByName,
           dbo.ufn_Inv_UserName(d.CancelledBy) AS CancelledByName, dbo.ufn_Inv_UserName(d.ClosedBy) AS ClosedByName,
           CAST(CASE WHEN d.BranchId = @BranchId THEN 1 ELSE 0 END AS BIT) AS IsMine,
           CAST(CASE WHEN ts.BranchId = @BranchId THEN 1 ELSE 0 END AS BIT) AS IsToMine,
           cm.CompanyName
    FROM dbo.InvDoc d
    JOIN dbo.InvStore s ON s.StoreId = d.StoreId
    LEFT JOIN dbo.Branchmaster sb ON sb.BranchID = s.BranchId
    LEFT JOIN dbo.InvStore ts ON ts.StoreId = d.ToStoreId
    LEFT JOIN dbo.Branchmaster tb ON tb.BranchID = ts.BranchId
    LEFT JOIN dbo.InvSupplier sp ON sp.SupplierId = d.SupplierId
    LEFT JOIN dbo.InvDoc r ON r.DocId = d.RefDocId
    LEFT JOIN dbo.InvAdjReason ar ON ar.ReasonCode = d.ReasonCode
    LEFT JOIN dbo.InvItemCategory c ON c.CategoryId = d.CategoryId
    LEFT JOIN dbo.CompanyMaster cm ON cm.CompanyId = d.CompanyId
    WHERE d.DocId = @DocId AND d.CompanyId = @CompanyId AND (d.BranchId = @BranchId OR ts.BranchId = @BranchId);

    SELECT l.*, i.ItemCode, i.ItemName, i.PackSize, pu.UnitName AS PurchaseUnit, cu.UnitName AS ConsumptionUnit, i.HsnCode,
           i.IsLotTracked, i.IsExpiryTracked, ISNULL(lt.LotNo, l.LotNo) AS LotLabel, ISNULL(lt.ExpiryDate, l.ExpiryDate) AS LotExpiry, lt.Status AS LotStatus,
           ISNULL(b.Qty, 0) AS AvailableQty,
           CASE WHEN d.DocType IN ('PO', 'IND') THEN CASE WHEN l.BaseQty - l.DoneBaseQty > 0 THEN l.BaseQty - l.DoneBaseQty ELSE 0 END END AS PendingBaseQty,
           CASE WHEN d.DocType = 'CNT' AND l.CountedBaseQty IS NOT NULL THEN l.CountedBaseQty - ISNULL(l.SystemBaseQty, 0) END AS DiffBaseQty,
           CASE WHEN d.DocType = 'CNT' AND l.CountedBaseQty IS NOT NULL
                THEN CAST(ROUND((l.CountedBaseQty - ISNULL(l.SystemBaseQty, 0)) * dbo.ufn_Qc_ItemUnitCost(l.ItemId), 2) AS DECIMAL(18,2)) END AS DiffValue
    FROM dbo.InvDocLine l
    JOIN dbo.InvDoc d ON d.DocId = l.DocId
    JOIN dbo.InvItem i ON i.ItemId = l.ItemId
    JOIN dbo.InvUnit pu ON pu.UnitId = i.PurchaseUnitId JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    LEFT JOIN dbo.InvLot lt ON lt.LotId = l.LotId
    LEFT JOIN dbo.InvStockBalance b ON b.StoreId = d.StoreId AND b.LotId = l.LotId
    WHERE l.DocId = @DocId AND d.CompanyId = @CompanyId
    ORDER BY l.SeqNo, l.LineId;

    -- related documents (receipts of a PO, issues of an indent, the PO of a GRN ...)
    SELECT x.DocId, x.DocType, dbo.ufn_Inv_DocTypeName(x.DocType) AS DocTypeName, x.DocNo, x.DocDate, x.Status, x.NetAmount
    FROM dbo.InvDoc x
    WHERE x.CompanyId = @CompanyId AND (x.RefDocId = @DocId OR x.DocId = (SELECT RefDocId FROM dbo.InvDoc WHERE DocId = @DocId))
    ORDER BY x.DocDate, x.DocId;

    -- stock movements made by the document
    SELECT g.TxnOn, g.DocType, dbo.ufn_Inv_DocTypeName(g.DocType) AS MoveName, st.StoreName, i.ItemName, lt.LotNo, g.QtyIn, g.QtyOut, g.UnitCost, g.Value
    FROM dbo.InvStockLedger g JOIN dbo.InvStore st ON st.StoreId = g.StoreId JOIN dbo.InvItem i ON i.ItemId = g.ItemId JOIN dbo.InvLot lt ON lt.LotId = g.LotId
    WHERE g.DocId = @DocId AND g.DocType IN (SELECT DocType FROM dbo.InvDoc WHERE DocId = @DocId UNION ALL SELECT 'ISSO' UNION ALL SELECT 'ISSI')
      AND g.CompanyId = @CompanyId AND (g.DocType <> 'CONS')
    ORDER BY g.LedgerId;
END;
GO

-- ═════ Save a draft ═══════════════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_DocSave
    @CompanyId INT, @BranchId INT, @UserId INT, @DocId INT = NULL, @DocType VARCHAR(6), @DocDate DATE = NULL,
    @StoreId INT, @ToStoreId INT = NULL, @SupplierId INT = NULL, @RefDocId INT = NULL, @SupplierInvNo NVARCHAR(50) = NULL,
    @SupplierInvDate DATE = NULL, @ExpectedDate DATE = NULL, @IsInterState BIT = 0, @ReasonCode VARCHAR(12) = NULL,
    @Priority VARCHAR(10) = NULL, @Terms NVARCHAR(1000) = NULL, @OtherCharges DECIMAL(18,2) = 0, @Remarks NVARCHAR(1000) = NULL,
    @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @msg NVARCHAR(500), @today DATE = CAST(GETDATE() AS DATE), @no NVARCHAR(40), @dir SMALLINT;
        SET @DocDate = ISNULL(@DocDate, @today);
        SET @OtherCharges = CASE WHEN @DocType = 'GRN' THEN ISNULL(@OtherCharges, 0) ELSE 0 END;
        IF @DocType NOT IN ('OPN', 'PO', 'GRN', 'PRET', 'IND', 'ISS', 'ADJ') THROW 53600, 'This document type cannot be saved here.', 1;
        IF @DocDate > @today THROW 53601, 'The document date cannot be in the future.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.InvStore WHERE StoreId = @StoreId AND CompanyId = @CompanyId AND BranchId = @BranchId AND IsDeleted = 0 AND Status = 1)
            THROW 53602, 'Select an active store of this branch.', 1;
        IF @DocType IN ('IND', 'ISS')
        BEGIN
            IF @ToStoreId IS NULL OR @ToStoreId = @StoreId THROW 53603, 'Select a different store to move the stock to / from.', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.InvStore WHERE StoreId = @ToStoreId AND CompanyId = @CompanyId AND IsDeleted = 0 AND Status = 1)
                THROW 53604, 'The other store is not active.', 1;
        END
        ELSE SET @ToStoreId = NULL;
        IF @DocType IN ('PO', 'GRN', 'PRET')
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.InvSupplier WHERE SupplierId = @SupplierId AND CompanyId = @CompanyId AND IsDeleted = 0 AND Status = 1)
                THROW 53605, 'Select an active supplier.', 1;
        END
        ELSE SET @SupplierId = NULL;
        IF @DocType = 'ADJ'
        BEGIN
            SELECT @dir = Direction FROM dbo.InvAdjReason WHERE ReasonCode = @ReasonCode AND IsActive = 1;
            IF @dir IS NULL THROW 53606, 'Select the reason for the adjustment.', 1;
        END
        ELSE IF @DocType <> 'PRET' SET @ReasonCode = NULL;

        -- reference document
        IF @RefDocId IS NOT NULL
        BEGIN
            IF @DocType = 'GRN' AND NOT EXISTS (SELECT 1 FROM dbo.InvDoc WHERE DocId = @RefDocId AND CompanyId = @CompanyId AND DocType = 'PO'
                                                 AND BranchId = @BranchId AND SupplierId = @SupplierId AND Status IN ('APPROVED', 'PARTIAL'))
                THROW 53607, 'The purchase order is not open for receipt (approved, same supplier, this branch).', 1;
            IF @DocType = 'PRET' AND NOT EXISTS (SELECT 1 FROM dbo.InvDoc WHERE DocId = @RefDocId AND CompanyId = @CompanyId AND DocType = 'GRN'
                                                  AND SupplierId = @SupplierId AND Status = 'POSTED')
                THROW 53608, 'The goods receipt is not a posted receipt of this supplier.', 1;
            IF @DocType = 'ISS' AND NOT EXISTS (SELECT 1 FROM dbo.InvDoc WHERE DocId = @RefDocId AND CompanyId = @CompanyId AND DocType = 'IND'
                                                 AND ToStoreId = @StoreId AND StoreId = @ToStoreId AND Status IN ('SUBMITTED', 'PARTIAL'))
                THROW 53609, 'The indent is not open, or was not raised on this store.', 1;
            IF @DocType NOT IN ('GRN', 'PRET', 'ISS') SET @RefDocId = NULL;
        END

        -- lines
        CREATE TABLE #L (Seq INT IDENTITY(1,1), ItemId INT, LotId INT, LotNo NVARCHAR(50), ExpiryDate DATE, MfgDate DATE, UnitMode CHAR(1), Qty DECIMAL(18,4),
                         FreeQty DECIMAL(18,4), Rate DECIMAL(18,4), DiscPct DECIMAL(9,4), GstPct DECIMAL(9,4), RefLineId INT, Remarks NVARCHAR(300),
                         Factor DECIMAL(18,4), BaseQty DECIMAL(18,4), BaseFree DECIMAL(18,4), Gross DECIMAL(18,2), Disc DECIMAL(18,2), Taxable DECIMAL(18,2),
                         Gst DECIMAL(18,2), Amount DECIMAL(18,2));
        INSERT #L (ItemId, LotId, LotNo, ExpiryDate, MfgDate, UnitMode, Qty, FreeQty, Rate, DiscPct, GstPct, RefLineId, Remarks)
        SELECT j.ItemId, j.LotId, NULLIF(LTRIM(RTRIM(j.LotNo)), ''), j.ExpiryDate, j.MfgDate,
               CASE WHEN @DocType IN ('PO', 'GRN') THEN 'P' WHEN j.UnitMode = 'P' THEN 'P' ELSE 'C' END,
               ISNULL(j.Qty, 0), CASE WHEN @DocType = 'GRN' THEN ISNULL(j.FreeQty, 0) ELSE 0 END,
               CASE WHEN @DocType IN ('PO', 'GRN', 'PRET', 'OPN') THEN ISNULL(j.Rate, 0) ELSE 0 END,
               CASE WHEN @DocType IN ('PO', 'GRN', 'PRET') THEN ISNULL(j.DiscPct, 0) ELSE 0 END,
               CASE WHEN @DocType IN ('PO', 'GRN', 'PRET') THEN ISNULL(j.GstPct, 0) ELSE 0 END,
               j.RefLineId, NULLIF(LTRIM(RTRIM(j.Remarks)), '')
        FROM OPENJSON(@Lines) WITH (ItemId INT '$.ItemId', LotId INT '$.LotId', LotNo NVARCHAR(50) '$.LotNo', ExpiryDate DATE '$.ExpiryDate', MfgDate DATE '$.MfgDate',
                                   UnitMode CHAR(1) '$.UnitMode', Qty DECIMAL(18,4) '$.Qty', FreeQty DECIMAL(18,4) '$.FreeQty', Rate DECIMAL(18,4) '$.Rate',
                                   DiscPct DECIMAL(9,4) '$.DiscPct', GstPct DECIMAL(9,4) '$.GstPct', RefLineId INT '$.RefLineId', Remarks NVARCHAR(300) '$.Remarks') j;
        IF NOT EXISTS (SELECT 1 FROM #L) THROW 53610, 'Add at least one item.', 1;
        IF EXISTS (SELECT 1 FROM #L l LEFT JOIN dbo.InvItem i ON i.ItemId = l.ItemId AND i.CompanyId = @CompanyId AND i.IsDeleted = 0 WHERE i.ItemId IS NULL)
            THROW 53611, 'A line has an item that is not in the Item Master.', 1;
        IF EXISTS (SELECT 1 FROM #L WHERE Qty < 0 OR FreeQty < 0 OR Rate < 0 OR DiscPct < 0 OR DiscPct > 100 OR GstPct < 0 OR GstPct > 40)
            THROW 53612, 'Quantities, rates, discount and GST cannot be negative (discount up to 100 %, GST up to 40 %).', 1;
        IF EXISTS (SELECT 1 FROM #L WHERE Qty = 0 AND NOT (@DocType = 'GRN' AND FreeQty > 0))
            THROW 53613, 'Every line needs a quantity.', 1;

        UPDATE l SET Factor = CASE WHEN l.UnitMode = 'P' THEN i.PackSize ELSE 1 END FROM #L l JOIN dbo.InvItem i ON i.ItemId = l.ItemId;
        UPDATE #L SET BaseQty = Qty * Factor, BaseFree = FreeQty * Factor,
                      Gross = ROUND(Qty * Rate, 2);
        UPDATE #L SET Disc = ROUND(Gross * DiscPct / 100, 2);
        UPDATE #L SET Taxable = Gross - Disc;
        UPDATE #L SET Gst = ROUND(Taxable * GstPct / 100, 2);
        UPDATE #L SET Amount = Taxable + Gst;

        -- lot rules
        IF @DocType IN ('OPN', 'GRN')
        BEGIN
            UPDATE #L SET LotId = NULL;
            -- a goods receipt (supplier bill) needs the batch number and expiry of every line, whatever the item's tracking flags
            SELECT TOP 1 @msg = CASE
                WHEN (i.IsLotTracked = 1 OR @DocType = 'GRN') AND l.LotNo IS NULL THEN CONCAT(i.ItemName, N': the batch / lot number is required.')
                WHEN (i.IsExpiryTracked = 1 OR @DocType = 'GRN') AND l.ExpiryDate IS NULL THEN CONCAT(i.ItemName, N': the expiry date is required.')
                WHEN l.ExpiryDate IS NOT NULL AND l.ExpiryDate < @today THEN CONCAT(i.ItemName, N': this lot has already expired.')
                WHEN @DocType = 'GRN' AND l.ExpiryDate IS NOT NULL AND i.MinShelfLifeDays IS NOT NULL AND DATEDIFF(DAY, @today, l.ExpiryDate) < i.MinShelfLifeDays
                    THEN CONCAT(i.ItemName, N': the lot expires in ', DATEDIFF(DAY, @today, l.ExpiryDate), N' days; the item needs at least ', i.MinShelfLifeDays, N' days of shelf life.')
                WHEN l.MfgDate IS NOT NULL AND l.MfgDate > @today THEN CONCAT(i.ItemName, N': the manufacturing date is in the future.')
                WHEN l.MfgDate IS NOT NULL AND l.ExpiryDate IS NOT NULL AND l.MfgDate >= l.ExpiryDate THEN CONCAT(i.ItemName, N': the manufacturing date must be before the expiry.')
                END
            FROM #L l JOIN dbo.InvItem i ON i.ItemId = l.ItemId
            WHERE ((i.IsLotTracked = 1 OR @DocType = 'GRN') AND l.LotNo IS NULL) OR ((i.IsExpiryTracked = 1 OR @DocType = 'GRN') AND l.ExpiryDate IS NULL)
               OR (l.ExpiryDate IS NOT NULL AND l.ExpiryDate < @today)
               OR (@DocType = 'GRN' AND l.ExpiryDate IS NOT NULL AND i.MinShelfLifeDays IS NOT NULL AND DATEDIFF(DAY, @today, l.ExpiryDate) < i.MinShelfLifeDays)
               OR (l.MfgDate IS NOT NULL AND (l.MfgDate > @today OR (l.ExpiryDate IS NOT NULL AND l.MfgDate >= l.ExpiryDate)));
            IF @msg IS NOT NULL THROW 53614, @msg, 1;
            UPDATE l SET LotNo = CASE WHEN i.IsLotTracked = 1 OR @DocType = 'GRN' THEN UPPER(l.LotNo) ELSE N'NA' END,
                         ExpiryDate = CASE WHEN i.IsExpiryTracked = 1 OR i.IsLotTracked = 1 OR @DocType = 'GRN' THEN l.ExpiryDate END
            FROM #L l JOIN dbo.InvItem i ON i.ItemId = l.ItemId;
        END
        ELSE IF @DocType IN ('PRET', 'ISS', 'ADJ')
        BEGIN
            IF EXISTS (SELECT 1 FROM #L l LEFT JOIN dbo.InvLot t ON t.LotId = l.LotId AND t.ItemId = l.ItemId AND t.CompanyId = @CompanyId WHERE t.LotId IS NULL)
                THROW 53615, 'Select the lot of every line.', 1;
            UPDATE l SET LotNo = t.LotNo, ExpiryDate = t.ExpiryDate FROM #L l JOIN dbo.InvLot t ON t.LotId = l.LotId;
            IF @DocType IN ('ISS', 'PRET') AND EXISTS (SELECT 1 FROM #L GROUP BY LotId HAVING COUNT(1) > 1)
                THROW 53616, 'A lot appears on two lines; enter it once.', 1;
        END
        ELSE UPDATE #L SET LotId = NULL, LotNo = NULL, ExpiryDate = NULL, MfgDate = NULL;

        -- reference lines
        IF @DocType = 'GRN'
        BEGIN
            IF @RefDocId IS NULL UPDATE #L SET RefLineId = NULL;
            ELSE IF EXISTS (SELECT 1 FROM #L l LEFT JOIN dbo.InvDocLine p ON p.LineId = l.RefLineId AND p.DocId = @RefDocId AND p.ItemId = l.ItemId
                            WHERE l.RefLineId IS NOT NULL AND p.LineId IS NULL)
                THROW 53617, 'A line does not match an item of the purchase order.', 1;
        END
        ELSE IF @DocType = 'ISS'
        BEGIN
            IF @RefDocId IS NULL UPDATE #L SET RefLineId = NULL;
            ELSE UPDATE l SET RefLineId = (SELECT TOP 1 p.LineId FROM dbo.InvDocLine p WHERE p.DocId = @RefDocId AND p.ItemId = l.ItemId ORDER BY p.SeqNo)
                 FROM #L l WHERE l.RefLineId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.InvDocLine p WHERE p.LineId = l.RefLineId AND p.DocId = @RefDocId AND p.ItemId = l.ItemId);
        END
        ELSE UPDATE #L SET RefLineId = NULL;

        DECLARE @taxable DECIMAL(18,2), @gst DECIMAL(18,2), @gross DECIMAL(18,2), @disc DECIMAL(18,2), @total DECIMAL(18,2), @net DECIMAL(18,2);
        SELECT @gross = ISNULL(SUM(Gross), 0), @disc = ISNULL(SUM(Disc), 0), @taxable = ISNULL(SUM(Taxable), 0), @gst = ISNULL(SUM(Gst), 0) FROM #L;
        SET @total = @taxable + @gst + @OtherCharges;
        SET @net = CASE WHEN @DocType IN ('PO', 'GRN', 'PRET') THEN ROUND(@total, 0) ELSE @total END;

        BEGIN TRANSACTION;
        IF @DocId IS NULL OR @DocId = 0
        BEGIN
            EXEC dbo.usp_Inv_NextNumber @BranchId, @DocType, @DocDate, @no OUTPUT;
            INSERT dbo.InvDoc (CompanyId, BranchId, DocType, DocNo, DocDate, Status, StoreId, ToStoreId, SupplierId, RefDocId, SupplierInvNo, SupplierInvDate,
                               ExpectedDate, IsInterState, ReasonCode, Priority, Terms, GrossAmount, DiscountAmount, TaxableAmount, GstAmount, OtherCharges,
                               RoundOff, NetAmount, Remarks, CreatedBy)
            VALUES (@CompanyId, @BranchId, @DocType, @no, @DocDate, 'DRAFT', @StoreId, @ToStoreId, @SupplierId, @RefDocId, NULLIF(LTRIM(RTRIM(@SupplierInvNo)), ''),
                    @SupplierInvDate, @ExpectedDate, ISNULL(@IsInterState, 0), @ReasonCode, CASE WHEN @DocType = 'IND' THEN ISNULL(NULLIF(@Priority, ''), 'Normal') END,
                    NULLIF(LTRIM(RTRIM(@Terms)), ''), @gross, @disc, @taxable, @gst, @OtherCharges, @net - @total, @net, NULLIF(LTRIM(RTRIM(@Remarks)), ''), @UserId);
            SET @DocId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            DECLARE @st VARCHAR(12), @ty VARCHAR(6), @br INT;
            SELECT @st = Status, @ty = DocType, @br = BranchId, @no = DocNo FROM dbo.InvDoc WITH (UPDLOCK) WHERE DocId = @DocId AND CompanyId = @CompanyId;
            IF @st IS NULL OR @br <> @BranchId THROW 53618, 'The document was not found in this branch.', 1;
            IF @ty <> @DocType THROW 53619, 'The document type cannot change.', 1;
            IF @st NOT IN ('DRAFT', 'REJECTED') THROW 53620, 'Only a draft (or a rejected document) can be edited.', 1;
            UPDATE dbo.InvDoc SET DocDate = @DocDate, Status = 'DRAFT', StoreId = @StoreId, ToStoreId = @ToStoreId, SupplierId = @SupplierId, RefDocId = @RefDocId,
                   SupplierInvNo = NULLIF(LTRIM(RTRIM(@SupplierInvNo)), ''), SupplierInvDate = @SupplierInvDate, ExpectedDate = @ExpectedDate,
                   IsInterState = ISNULL(@IsInterState, 0), ReasonCode = @ReasonCode,
                   Priority = CASE WHEN @DocType = 'IND' THEN ISNULL(NULLIF(@Priority, ''), 'Normal') END, Terms = NULLIF(LTRIM(RTRIM(@Terms)), ''),
                   GrossAmount = @gross, DiscountAmount = @disc, TaxableAmount = @taxable, GstAmount = @gst, OtherCharges = @OtherCharges,
                   RoundOff = @net - @total, NetAmount = @net, Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''),
                   SubmittedBy = NULL, SubmittedOn = NULL, RejectedBy = NULL, RejectedOn = NULL, ModifiedBy = @UserId, ModifiedOn = GETDATE()
            WHERE DocId = @DocId;
            DELETE FROM dbo.InvDocLine WHERE DocId = @DocId;
        END
        INSERT dbo.InvDocLine (DocId, SeqNo, ItemId, LotId, LotNo, ExpiryDate, MfgDate, UnitMode, Factor, Qty, FreeQty, BaseQty, BaseFreeQty, Sign, Rate, DiscPct, GstPct,
                               GrossAmount, DiscountAmount, TaxableAmount, GstAmount, LineAmount, RefLineId, Remarks)
        SELECT @DocId, Seq, ItemId, LotId, LotNo, ExpiryDate, MfgDate, UnitMode, Factor, Qty, FreeQty, BaseQty, BaseFree, CASE WHEN @DocType = 'ADJ' THEN @dir ELSE 1 END,
               Rate, DiscPct, GstPct, Gross, Disc, Taxable, Gst, Amount, RefLineId, Remarks
        FROM #L ORDER BY Seq;
        COMMIT TRANSACTION;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @DocId AS DocId, @no AS DocNo, 'DRAFT' AS Status;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, CAST(ERROR_MESSAGE() AS NVARCHAR(600)) AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ═════ Posting (called inside the action's transaction) ═══════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Inv_DocPost @DocId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @co INT, @br INT, @type VARCHAR(6), @store INT, @sup INT, @no NVARCHAR(40), @ref INT, @inv NVARCHAR(50), @other DECIMAL(18,2), @taxable DECIMAL(18,2),
            @msg NVARCHAR(500), @today DATE = CAST(GETDATE() AS DATE), @lotAcc BIT, @now DATETIME = GETDATE(), @value DECIMAL(18,2) = 0;
    SELECT @co = CompanyId, @br = BranchId, @type = DocType, @store = StoreId, @sup = SupplierId, @no = DocNo, @ref = RefDocId, @inv = SupplierInvNo,
           @other = OtherCharges, @taxable = TaxableAmount
    FROM dbo.InvDoc WHERE DocId = @DocId;
    SELECT @lotAcc = LotAcceptanceRequired FROM dbo.ufn_Inv_Settings(@co);

    DECLARE @line INT, @item INT, @lot INT, @lotNo NVARCHAR(50), @exp DATE, @mfg DATE, @qty DECIMAL(18,4), @free DECIMAL(18,4), @factor DECIMAL(18,4),
            @rate DECIMAL(18,4), @lineTax DECIMAL(18,2), @sign SMALLINT, @refLine INT, @cost DECIMAL(18,6), @q BIT, @v DECIMAL(18,2), @k DECIMAL(18,6), @mv DECIMAL(18,4);

    IF @type = 'GRN'
    BEGIN
        IF @inv IS NULL THROW 53630, 'Enter the supplier''s bill number before posting.', 1;
        IF EXISTS (SELECT 1 FROM dbo.InvDoc WHERE CompanyId = @co AND DocType = 'GRN' AND Status = 'POSTED' AND SupplierId = @sup AND SupplierInvNo = @inv AND DocId <> @DocId)
            THROW 53631, 'This supplier bill number is already posted on another goods receipt.', 1;
        IF @ref IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.InvDoc WITH (UPDLOCK) WHERE DocId = @ref AND Status IN ('APPROVED', 'PARTIAL'))
                THROW 53632, 'The purchase order is no longer open for receipt.', 1;
            SELECT TOP 1 @msg = CONCAT(i.ItemName, N': more than the purchase order still due (', FORMAT((p.BaseQty - p.DoneBaseQty) / NULLIF(p.Factor, 0), '0.###'), N' ', pu.UnitName, N').')
            FROM (SELECT RefLineId, SUM(BaseQty) AS Q FROM dbo.InvDocLine WHERE DocId = @DocId AND RefLineId IS NOT NULL GROUP BY RefLineId) g
            JOIN dbo.InvDocLine p ON p.LineId = g.RefLineId JOIN dbo.InvItem i ON i.ItemId = p.ItemId JOIN dbo.InvUnit pu ON pu.UnitId = i.PurchaseUnitId
            WHERE g.Q > p.BaseQty - p.DoneBaseQty + 0.0001;
            IF @msg IS NOT NULL THROW 53633, @msg, 1;
        END
    END

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT l.LineId, l.ItemId, l.LotId, l.LotNo, l.ExpiryDate, l.MfgDate, l.BaseQty, l.BaseFreeQty, l.Factor, l.Rate, l.TaxableAmount, l.Sign, l.RefLineId,
               CAST(CASE WHEN @lotAcc = 1 AND cat.RequiresAcceptance = 1 THEN 1 ELSE 0 END AS BIT)
        FROM dbo.InvDocLine l JOIN dbo.InvItem i ON i.ItemId = l.ItemId JOIN dbo.InvItemCategory cat ON cat.CategoryId = i.CategoryId
        WHERE l.DocId = @DocId ORDER BY l.SeqNo;
    OPEN c; FETCH NEXT FROM c INTO @line, @item, @lot, @lotNo, @exp, @mfg, @qty, @free, @factor, @rate, @lineTax, @sign, @refLine, @q;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @type = 'OPN'
        BEGIN
            SET @cost = @rate / NULLIF(@factor, 0);
            EXEC dbo.usp_Inv_GetLot @co, @item, @lotNo, @exp, @mfg, @cost, NULL, @DocId, 0, @UserId, @lot OUTPUT;
            EXEC dbo.usp_Inv_Move @CompanyId = @co, @StoreId = @store, @ItemId = @item, @LotId = @lot, @Qty = @qty, @UnitCost = @cost, @UpdateAvg = 1,
                 @DocType = 'OPN', @DocId = @DocId, @DocNo = @no, @DocLineId = @line, @Remarks = N'Opening stock', @UserId = @UserId, @ValueOut = @v OUTPUT, @CostOut = @k OUTPUT;
            UPDATE dbo.InvDocLine SET LotId = @lot, UnitCost = @k WHERE LineId = @line;
        END
        ELSE IF @type = 'GRN'
        BEGIN
            -- landed cost per consumption unit: taxable value + its share of the other charges, over paid + free quantity (GST is input credit)
            SET @cost = (@lineTax + CASE WHEN @taxable > 0 THEN @other * @lineTax / @taxable ELSE 0 END) / NULLIF(@qty + @free, 0);
            EXEC dbo.usp_Inv_GetLot @co, @item, @lotNo, @exp, @mfg, @cost, @sup, @DocId, @q, @UserId, @lot OUTPUT;
            SET @mv = @qty + @free;
            EXEC dbo.usp_Inv_Move @CompanyId = @co, @StoreId = @store, @ItemId = @item, @LotId = @lot, @Qty = @mv, @UnitCost = @cost, @UpdateAvg = 1,
                 @DocType = 'GRN', @DocId = @DocId, @DocNo = @no, @DocLineId = @line, @Remarks = N'Goods receipt', @UserId = @UserId, @ValueOut = @v OUTPUT, @CostOut = @k OUTPUT;
            UPDATE dbo.InvDocLine SET LotId = @lot, UnitCost = @k WHERE LineId = @line;
            IF @refLine IS NOT NULL UPDATE dbo.InvDocLine SET DoneBaseQty = DoneBaseQty + @qty WHERE LineId = @refLine;
            IF @rate > 0 UPDATE dbo.InvItem SET PurchaseRate = @rate WHERE ItemId = @item;   -- last purchase rate (per pack)
        END
        ELSE IF @type = 'PRET'
        BEGIN
            SET @cost = @rate / NULLIF(@factor, 0);
            SET @mv = -@qty;
            EXEC dbo.usp_Inv_Move @CompanyId = @co, @StoreId = @store, @ItemId = @item, @LotId = @lot, @Qty = @mv, @UnitCost = @cost, @UpdateAvg = 1,
                 @DocType = 'PRET', @DocId = @DocId, @DocNo = @no, @DocLineId = @line, @Remarks = N'Returned to supplier', @UserId = @UserId, @ValueOut = @v OUTPUT, @CostOut = @k OUTPUT;
            UPDATE dbo.InvDocLine SET UnitCost = @k WHERE LineId = @line;
        END
        ELSE IF @type = 'ADJ'
        BEGIN
            SET @mv = @sign * @qty;
            EXEC dbo.usp_Inv_Move @CompanyId = @co, @StoreId = @store, @ItemId = @item, @LotId = @lot, @Qty = @mv, @UnitCost = NULL, @UpdateAvg = 0,
                 @DocType = 'ADJ', @DocId = @DocId, @DocNo = @no, @DocLineId = @line, @Remarks = N'Stock adjustment', @UserId = @UserId, @ValueOut = @v OUTPUT, @CostOut = @k OUTPUT;
            UPDATE dbo.InvDocLine SET UnitCost = @k WHERE LineId = @line;
        END
        ELSE IF @type = 'CNT'
        BEGIN
            SELECT @mv = CountedBaseQty - ISNULL(SystemBaseQty, 0) FROM dbo.InvDocLine WHERE LineId = @line AND CountedBaseQty IS NOT NULL;
            IF @mv IS NOT NULL AND @mv <> 0
            BEGIN
                EXEC dbo.usp_Inv_Move @CompanyId = @co, @StoreId = @store, @ItemId = @item, @LotId = @lot, @Qty = @mv, @UnitCost = NULL, @UpdateAvg = 0,
                     @DocType = 'CNT', @DocId = @DocId, @DocNo = @no, @DocLineId = @line, @Remarks = N'Physical count difference', @UserId = @UserId, @ValueOut = @v OUTPUT, @CostOut = @k OUTPUT;
                UPDATE dbo.InvDocLine SET UnitCost = @k WHERE LineId = @line;
            END
            SET @mv = NULL;
        END
        SET @value = @value + ISNULL(@v, 0); SET @v = 0;
        FETCH NEXT FROM c INTO @line, @item, @lot, @lotNo, @exp, @mfg, @qty, @free, @factor, @rate, @lineTax, @sign, @refLine, @q;
    END
    CLOSE c; DEALLOCATE c;

    UPDATE dbo.InvDoc SET Status = 'POSTED', PostedBy = @UserId, PostedOn = @now, StockValue = @value WHERE DocId = @DocId;
    IF @type = 'GRN' AND @ref IS NOT NULL
        UPDATE dbo.InvDoc SET Status = CASE WHEN EXISTS (SELECT 1 FROM dbo.InvDocLine WHERE DocId = @ref AND DoneBaseQty < BaseQty) THEN 'PARTIAL' ELSE 'CLOSED' END,
               ClosedBy = CASE WHEN EXISTS (SELECT 1 FROM dbo.InvDocLine WHERE DocId = @ref AND DoneBaseQty < BaseQty) THEN NULL ELSE @UserId END,
               ClosedOn = CASE WHEN EXISTS (SELECT 1 FROM dbo.InvDocLine WHERE DocId = @ref AND DoneBaseQty < BaseQty) THEN NULL ELSE @now END
        WHERE DocId = @ref;
    EXEC dbo.usp_Inv_PostLedger @type, @DocId, @UserId;
END;
GO

-- issue: out of the from-store (in transit)
CREATE OR ALTER PROCEDURE dbo.usp_Inv_DocDispatch @DocId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @co INT, @store INT, @no NVARCHAR(40), @ref INT, @msg NVARCHAR(500), @now DATETIME = GETDATE(), @value DECIMAL(18,2) = 0;
    SELECT @co = CompanyId, @store = StoreId, @no = DocNo, @ref = RefDocId FROM dbo.InvDoc WHERE DocId = @DocId;
    SELECT TOP 1 @msg = CONCAT(i.ItemName, N' lot ', t.LotNo, CASE WHEN t.Status <> 'ACCEPTED' THEN N' is ' + LOWER(t.Status) + N' and cannot be issued.' ELSE N' has expired and cannot be issued.' END)
    FROM dbo.InvDocLine l JOIN dbo.InvLot t ON t.LotId = l.LotId JOIN dbo.InvItem i ON i.ItemId = l.ItemId
    WHERE l.DocId = @DocId AND (t.Status <> 'ACCEPTED' OR (t.ExpiryDate IS NOT NULL AND t.ExpiryDate < CAST(GETDATE() AS DATE)));
    IF @msg IS NOT NULL THROW 53640, @msg, 1;

    DECLARE @line INT, @item INT, @lot INT, @qty DECIMAL(18,4), @refLine INT, @mv DECIMAL(18,4), @v DECIMAL(18,2), @k DECIMAL(18,6);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT LineId, ItemId, LotId, BaseQty, RefLineId FROM dbo.InvDocLine WHERE DocId = @DocId ORDER BY SeqNo;
    OPEN c; FETCH NEXT FROM c INTO @line, @item, @lot, @qty, @refLine;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @mv = -@qty;
        EXEC dbo.usp_Inv_Move @CompanyId = @co, @StoreId = @store, @ItemId = @item, @LotId = @lot, @Qty = @mv, @UnitCost = NULL, @UpdateAvg = 0,
             @DocType = 'ISSO', @DocId = @DocId, @DocNo = @no, @DocLineId = @line, @Remarks = N'Issued / transferred out', @UserId = @UserId, @ValueOut = @v OUTPUT, @CostOut = @k OUTPUT;
        UPDATE dbo.InvDocLine SET UnitCost = @k WHERE LineId = @line;
        IF @refLine IS NOT NULL UPDATE dbo.InvDocLine SET DoneBaseQty = DoneBaseQty + @qty WHERE LineId = @refLine;
        SET @value = @value - ISNULL(@v, 0);
        FETCH NEXT FROM c INTO @line, @item, @lot, @qty, @refLine;
    END
    CLOSE c; DEALLOCATE c;
    UPDATE dbo.InvDoc SET Status = 'INTRANSIT', PostedBy = @UserId, PostedOn = @now, StockValue = @value WHERE DocId = @DocId;
    IF @ref IS NOT NULL
        UPDATE dbo.InvDoc SET Status = CASE WHEN EXISTS (SELECT 1 FROM dbo.InvDocLine WHERE DocId = @ref AND DoneBaseQty < BaseQty) THEN 'PARTIAL' ELSE 'CLOSED' END,
               ClosedOn = CASE WHEN EXISTS (SELECT 1 FROM dbo.InvDocLine WHERE DocId = @ref AND DoneBaseQty < BaseQty) THEN NULL ELSE @now END,
               ClosedBy = CASE WHEN EXISTS (SELECT 1 FROM dbo.InvDocLine WHERE DocId = @ref AND DoneBaseQty < BaseQty) THEN NULL ELSE @UserId END
        WHERE DocId = @ref;
END;
GO

-- issue: into the to-store. @Received = [{LineId, ReceivedQty}] in consumption units (missing = all); a shortage is written off
CREATE OR ALTER PROCEDURE dbo.usp_Inv_DocReceive @DocId INT, @UserId INT, @Received NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @co INT, @to INT, @no NVARCHAR(40), @short DECIMAL(18,2) = 0;
    SELECT @co = CompanyId, @to = ToStoreId, @no = DocNo FROM dbo.InvDoc WHERE DocId = @DocId;
    CREATE TABLE #R (LineId INT PRIMARY KEY, Q DECIMAL(18,4));
    INSERT #R SELECT l.LineId, ISNULL(j.ReceivedQty, l.BaseQty)
    FROM dbo.InvDocLine l
    LEFT JOIN OPENJSON(ISNULL(@Received, '[]')) WITH (LineId INT '$.LineId', ReceivedQty DECIMAL(18,4) '$.ReceivedQty') j ON j.LineId = l.LineId
    WHERE l.DocId = @DocId;
    IF EXISTS (SELECT 1 FROM #R r JOIN dbo.InvDocLine l ON l.LineId = r.LineId WHERE r.Q < 0 OR r.Q > l.BaseQty)
        THROW 53645, 'The received quantity must be between zero and the quantity sent.', 1;
    DECLARE @line INT, @item INT, @lot INT, @q DECIMAL(18,4), @sent DECIMAL(18,4), @cost DECIMAL(18,6), @v DECIMAL(18,2), @k DECIMAL(18,6);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT l.LineId, l.ItemId, l.LotId, r.Q, l.BaseQty, l.UnitCost FROM dbo.InvDocLine l JOIN #R r ON r.LineId = l.LineId WHERE l.DocId = @DocId ORDER BY l.SeqNo;
    OPEN c; FETCH NEXT FROM c INTO @line, @item, @lot, @q, @sent, @cost;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @q > 0
            EXEC dbo.usp_Inv_Move @CompanyId = @co, @StoreId = @to, @ItemId = @item, @LotId = @lot, @Qty = @q, @UnitCost = @cost, @UpdateAvg = 0,
                 @DocType = 'ISSI', @DocId = @DocId, @DocNo = @no, @DocLineId = @line, @Remarks = N'Issue / transfer received', @UserId = @UserId, @ValueOut = @v OUTPUT, @CostOut = @k OUTPUT;
        UPDATE dbo.InvDocLine SET DoneBaseQty = @q WHERE LineId = @line;
        SET @short = @short + ROUND((@sent - @q) * ISNULL(@cost, 0), 2);
        FETCH NEXT FROM c INTO @line, @item, @lot, @q, @sent, @cost;
    END
    CLOSE c; DEALLOCATE c;
    UPDATE dbo.InvDoc SET Status = 'RECEIVED', ReceivedBy = @UserId, ReceivedOn = GETDATE() WHERE DocId = @DocId;
    IF @short > 0 EXEC dbo.usp_Inv_PostLedger 'TLOSS', @DocId, @UserId, @short;
END;
GO

-- ═════ Actions ════════════════════════════════════════════════════════════════════════════════════════════
-- @Action: SUBMIT APPROVE REJECT POST DISPATCH DISPATCH_RECEIVE RECEIVE CANCEL CLOSE COUNTS
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_DocAction
    @CompanyId INT, @BranchId INT, @UserId INT, @IsSuperAdmin BIT = 0, @DocId INT, @Action VARCHAR(20), @Remarks NVARCHAR(500) = NULL, @Data NVARCHAR(MAX) = NULL,
    @DocType VARCHAR(6) = NULL   -- the screen's document type: a document of another type is refused
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @type VARCHAR(6), @st VARCHAR(12), @br INT, @toBr INT, @maker INT, @needApproval BIT, @now DATETIME = GETDATE(), @msg NVARCHAR(500), @ref INT;
        SET @Action = UPPER(LTRIM(RTRIM(@Action)));
        SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), '');
        BEGIN TRANSACTION;
        SELECT @type = d.DocType, @st = d.Status, @br = d.BranchId, @toBr = ts.BranchId, @maker = ISNULL(d.SubmittedBy, d.CreatedBy), @ref = d.RefDocId
        FROM dbo.InvDoc d WITH (UPDLOCK, HOLDLOCK) LEFT JOIN dbo.InvStore ts ON ts.StoreId = d.ToStoreId
        WHERE d.DocId = @DocId AND d.CompanyId = @CompanyId;
        IF @type IS NULL OR (@DocType IS NOT NULL AND @type <> @DocType) THROW 53650, 'The document was not found.', 1;

        -- who may act: the document's own branch; receiving an issue / answering an indent: the other store's branch
        IF @Action = 'RECEIVE' OR (@type = 'IND' AND @Action IN ('REJECT', 'CLOSE'))
        BEGIN
            IF ISNULL(@toBr, -1) <> @BranchId THROW 53651, 'Switch to the receiving / supplying branch to do this.', 1;
        END
        ELSE IF @br <> @BranchId THROW 53651, 'Switch to the document''s branch to do this.', 1;

        SELECT @needApproval = CASE @type WHEN 'PO' THEN PoApprovalRequired WHEN 'ADJ' THEN AdjApprovalRequired WHEN 'CNT' THEN CountApprovalRequired ELSE 0 END
        FROM dbo.ufn_Inv_Settings(@CompanyId);

        IF @Action = 'COUNTS'
        BEGIN
            IF @type <> 'CNT' OR @st <> 'DRAFT' THROW 53652, 'Counts can be entered only on a draft stock count.', 1;
            UPDATE l SET CountedBaseQty = j.CountedQty, Remarks = NULLIF(LTRIM(RTRIM(ISNULL(j.Remarks, l.Remarks))), '')
            FROM dbo.InvDocLine l
            JOIN OPENJSON(ISNULL(@Data, '[]')) WITH (LineId INT '$.LineId', CountedQty DECIMAL(18,4) '$.CountedQty', Remarks NVARCHAR(300) '$.Remarks') j ON j.LineId = l.LineId
            WHERE l.DocId = @DocId;
            IF EXISTS (SELECT 1 FROM dbo.InvDocLine WHERE DocId = @DocId AND CountedBaseQty < 0) THROW 53653, 'A counted quantity cannot be negative.', 1;
            -- lots found that were not on the sheet
            INSERT dbo.InvDocLine (DocId, SeqNo, ItemId, LotId, LotNo, ExpiryDate, UnitMode, Factor, Qty, BaseQty, SystemBaseQty, CountedBaseQty, Remarks)
            SELECT @DocId, ISNULL((SELECT MAX(SeqNo) FROM dbo.InvDocLine WHERE DocId = @DocId), 0) + ROW_NUMBER() OVER (ORDER BY j.LotId),
                   t.ItemId, t.LotId, t.LotNo, t.ExpiryDate, 'C', 1, 0, 0,
                   ISNULL((SELECT b.Qty FROM dbo.InvStockBalance b JOIN dbo.InvDoc d ON d.StoreId = b.StoreId WHERE d.DocId = @DocId AND b.LotId = t.LotId), 0),
                   j.CountedQty, N'Added during count'
            FROM OPENJSON(ISNULL(@Data, '[]')) WITH (LineId INT '$.LineId', LotId INT '$.LotId', CountedQty DECIMAL(18,4) '$.CountedQty') j
            JOIN dbo.InvLot t ON t.LotId = j.LotId AND t.CompanyId = @CompanyId
            WHERE j.LineId IS NULL AND j.CountedQty IS NOT NULL AND j.CountedQty >= 0
              AND NOT EXISTS (SELECT 1 FROM dbo.InvDocLine x WHERE x.DocId = @DocId AND x.LotId = j.LotId);
            UPDATE dbo.InvDoc SET ModifiedBy = @UserId, ModifiedOn = @now, Remarks = ISNULL(@Remarks, Remarks) WHERE DocId = @DocId;
        END
        ELSE IF @Action = 'SUBMIT'
        BEGIN
            IF @type NOT IN ('PO', 'IND', 'ADJ', 'CNT') THROW 53654, 'This document is not submitted for approval; post it instead.', 1;
            IF @st NOT IN ('DRAFT', 'REJECTED') THROW 53655, 'Only a draft can be submitted.', 1;
            IF @type = 'CNT' AND NOT EXISTS (SELECT 1 FROM dbo.InvDocLine WHERE DocId = @DocId AND CountedBaseQty IS NOT NULL)
                THROW 53656, 'Enter the counted quantity of at least one line.', 1;
            UPDATE dbo.InvDoc SET Status = 'SUBMITTED', SubmittedBy = @UserId, SubmittedOn = @now, RejectedBy = NULL, RejectedOn = NULL, RejectReason = NULL WHERE DocId = @DocId;
            IF @needApproval = 0 AND @type IN ('PO', 'ADJ', 'CNT')
            BEGIN
                UPDATE dbo.InvDoc SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedOn = @now WHERE DocId = @DocId;
                IF @type IN ('ADJ', 'CNT') EXEC dbo.usp_Inv_DocPost @DocId, @UserId;
            END
        END
        ELSE IF @Action IN ('APPROVE', 'REJECT') AND @type <> 'IND'
        BEGIN
            IF @type NOT IN ('PO', 'ADJ', 'CNT') THROW 53657, 'This document has no approval step.', 1;
            IF @st <> 'SUBMITTED' THROW 53658, 'Only a submitted document can be approved or rejected.', 1;
            IF @maker = @UserId AND ISNULL(@IsSuperAdmin, 0) = 0 THROW 53659, 'You raised this document; another user must approve or reject it.', 1;
            IF @Action = 'REJECT'
            BEGIN
                IF @Remarks IS NULL THROW 53660, 'Give the reason for rejecting.', 1;
                UPDATE dbo.InvDoc SET Status = 'REJECTED', RejectedBy = @UserId, RejectedOn = @now, RejectReason = @Remarks WHERE DocId = @DocId;
            END
            ELSE
            BEGIN
                UPDATE dbo.InvDoc SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedOn = @now WHERE DocId = @DocId;
                IF @type IN ('ADJ', 'CNT') EXEC dbo.usp_Inv_DocPost @DocId, @UserId;
            END
        END
        ELSE IF @Action = 'REJECT' AND @type = 'IND'
        BEGIN
            IF @st <> 'SUBMITTED' THROW 53661, 'Only an indent not yet issued against can be rejected; close it instead.', 1;
            IF @Remarks IS NULL THROW 53660, 'Give the reason for rejecting.', 1;
            UPDATE dbo.InvDoc SET Status = 'REJECTED', RejectedBy = @UserId, RejectedOn = @now, RejectReason = @Remarks WHERE DocId = @DocId;
        END
        ELSE IF @Action = 'POST'
        BEGIN
            IF @type NOT IN ('OPN', 'GRN', 'PRET') THROW 53662, 'This document is not posted directly.', 1;
            IF @st <> 'DRAFT' THROW 53663, 'Only a draft can be posted.', 1;
            EXEC dbo.usp_Inv_DocPost @DocId, @UserId;
        END
        ELSE IF @Action IN ('DISPATCH', 'DISPATCH_RECEIVE')
        BEGIN
            IF @type <> 'ISS' OR @st <> 'DRAFT' THROW 53664, 'Only a draft issue can be dispatched.', 1;
            IF @ref IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.InvDoc WITH (UPDLOCK) WHERE DocId = @ref AND Status IN ('SUBMITTED', 'PARTIAL'))
                THROW 53665, 'The indent of this issue is no longer open.', 1;
            EXEC dbo.usp_Inv_DocDispatch @DocId, @UserId;
            IF @Action = 'DISPATCH_RECEIVE'
            BEGIN
                IF ISNULL(@toBr, -1) <> @BranchId THROW 53666, 'Receive at once is only for a store of this branch; the other branch receives it.', 1;
                EXEC dbo.usp_Inv_DocReceive @DocId, @UserId, NULL;
            END
        END
        ELSE IF @Action = 'RECEIVE'
        BEGIN
            IF @type <> 'ISS' OR @st <> 'INTRANSIT' THROW 53667, 'Only an issue in transit can be received.', 1;
            EXEC dbo.usp_Inv_DocReceive @DocId, @UserId, @Data;
        END
        ELSE IF @Action = 'CANCEL'
        BEGIN
            IF @st NOT IN ('DRAFT', 'SUBMITTED', 'REJECTED', 'APPROVED') THROW 53668, 'A posted, dispatched or partly received document cannot be cancelled.', 1;
            IF @st = 'APPROVED' AND @type <> 'PO' THROW 53668, 'A posted, dispatched or partly received document cannot be cancelled.', 1;
            IF @type = 'PO' AND EXISTS (SELECT 1 FROM dbo.InvDoc WHERE RefDocId = @DocId AND DocType = 'GRN' AND Status = 'POSTED')
                THROW 53669, 'Goods were already received against this purchase order; close it instead.', 1;
            IF @Remarks IS NULL AND @st <> 'DRAFT' THROW 53670, 'Give the reason for cancelling.', 1;
            UPDATE dbo.InvDoc SET Status = 'CANCELLED', CancelledBy = @UserId, CancelledOn = @now, CancelReason = @Remarks WHERE DocId = @DocId;
        END
        ELSE IF @Action = 'CLOSE'
        BEGIN
            IF NOT ((@type = 'PO' AND @st IN ('APPROVED', 'PARTIAL')) OR (@type = 'IND' AND @st IN ('SUBMITTED', 'PARTIAL')))
                THROW 53671, 'Only an open purchase order or indent can be closed.', 1;
            IF EXISTS (SELECT 1 FROM dbo.InvDoc WHERE RefDocId = @DocId AND Status = 'DRAFT')
                THROW 53672, 'A draft receipt / issue is still open against it; post or cancel that first.', 1;
            UPDATE dbo.InvDoc SET Status = 'CLOSED', ClosedBy = @UserId, ClosedOn = @now, Remarks = CASE WHEN @Remarks IS NULL THEN Remarks ELSE CONCAT(Remarks, CASE WHEN Remarks IS NULL THEN N'' ELSE N' | ' END, N'Closed: ', @Remarks) END
            WHERE DocId = @DocId;
        END
        ELSE THROW 53673, 'Unknown action.', 1;

        COMMIT TRANSACTION;

        -- stock came in: settle the test consumption that was waiting for these items in that branch (after the commit:
        -- it can never undo the document; anything still short simply stays PENDING)
        DECLARE @newSt VARCHAR(12) = (SELECT Status FROM dbo.InvDoc WHERE DocId = @DocId);
        IF (@type IN ('OPN', 'GRN', 'ADJ', 'CNT') AND @newSt = 'POSTED') OR (@type = 'ISS' AND @newSt = 'RECEIVED')
        BEGIN
            BEGIN TRY
                DECLARE @inBr INT = CASE WHEN @type = 'ISS' THEN @toBr ELSE @br END;
                DECLARE @waiting NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(l.ConsumptionLineId AS VARCHAR(12)), ',')
                    FROM dbo.QcConsumptionLine l JOIN dbo.QcConsumption c ON c.ConsumptionId = l.ConsumptionId
                    WHERE c.CompanyId = @CompanyId AND c.BranchId = @inBr AND l.StockStatus = 'PENDING'
                      AND l.ItemId IN (SELECT ItemId FROM dbo.InvDocLine WHERE DocId = @DocId));
                IF @waiting IS NOT NULL EXEC dbo.usp_Inv_ConsumeLines @LabOrderId = NULL, @LineIds = @waiting, @UserId = @UserId;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
                BEGIN TRY
                    INSERT INTO dbo.QcConsumptionLog (LabOrderId, ErrorNumber, ErrorMessage) VALUES (NULL, ERROR_NUMBER(), LEFT(N'Stock: pending settle after ' + @type + N' ' + CAST(@DocId AS NVARCHAR(12)) + N': ' + ERROR_MESSAGE(), 2000));
                END TRY
                BEGIN CATCH
                END CATCH
            END CATCH
        END

        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, d.DocId, d.DocNo, d.Status, d.VoucherNo
        FROM dbo.InvDoc d WHERE d.DocId = @DocId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, CAST(ERROR_MESSAGE() AS NVARCHAR(600)) AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ═════ Physical count: a new count sheet (book stock frozen per lot) ══════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_CountCreate
    @CompanyId INT, @BranchId INT, @UserId INT, @StoreId INT, @CategoryId INT = NULL, @IncludeZero BIT = 0, @Remarks NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.InvStore WHERE StoreId = @StoreId AND CompanyId = @CompanyId AND BranchId = @BranchId AND IsDeleted = 0 AND Status = 1)
            THROW 53680, 'Select an active store of this branch.', 1;
        IF EXISTS (SELECT 1 FROM dbo.InvDoc WHERE DocType = 'CNT' AND StoreId = @StoreId AND Status IN ('DRAFT', 'SUBMITTED'))
            THROW 53681, 'This store already has an open stock count; finish or cancel it first.', 1;
        DECLARE @no NVARCHAR(40), @id INT, @today DATE = CAST(GETDATE() AS DATE);
        BEGIN TRANSACTION;
            EXEC dbo.usp_Inv_NextNumber @BranchId, 'CNT', @today, @no OUTPUT;
            INSERT dbo.InvDoc (CompanyId, BranchId, DocType, DocNo, DocDate, Status, StoreId, CategoryId, Remarks, CreatedBy)
            VALUES (@CompanyId, @BranchId, 'CNT', @no, @today, 'DRAFT', @StoreId, @CategoryId, NULLIF(LTRIM(RTRIM(@Remarks)), ''), @UserId);
            SET @id = SCOPE_IDENTITY();
            INSERT dbo.InvDocLine (DocId, SeqNo, ItemId, LotId, LotNo, ExpiryDate, UnitMode, Factor, Qty, BaseQty, SystemBaseQty)
            SELECT @id, ROW_NUMBER() OVER (ORDER BY i.ItemName, t.ExpiryDate, t.LotNo), b.ItemId, b.LotId, t.LotNo, t.ExpiryDate, 'C', 1, 0, 0, b.Qty
            FROM dbo.InvStockBalance b JOIN dbo.InvLot t ON t.LotId = b.LotId JOIN dbo.InvItem i ON i.ItemId = b.ItemId
            WHERE b.StoreId = @StoreId AND (b.Qty > 0 OR @IncludeZero = 1) AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId);
            IF @@ROWCOUNT = 0 THROW 53682, 'There is no stock in this store to count (for this category).', 1;
        COMMIT TRANSACTION;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS DocId, @no AS DocNo, 'DRAFT' AS Status;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, CAST(ERROR_MESSAGE() AS NVARCHAR(600)) AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ═════ Stock enquiry ══════════════════════════════════════════════════════════════════════════════════════
-- @View ITEM (one row per item) | LOT (store x lot). @Filter ALL | INSTOCK | LOW | NEAR | EXPIRED | QUARANTINE | OPENED
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_Stock
    @CompanyId INT, @BranchId INT, @StoreId INT = NULL, @View VARCHAR(5) = 'ITEM', @Filter VARCHAR(12) = 'INSTOCK', @Search NVARCHAR(100) = NULL, @CategoryId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @Filter = ISNULL(NULLIF(@Filter, ''), 'INSTOCK');
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @near INT = (SELECT NearExpiryDays FROM dbo.ufn_Inv_Settings(@CompanyId));

    SELECT b.StoreId, s.StoreName, s.StoreType, b.ItemId, b.LotId, t.LotNo, t.ExpiryDate, t.Status AS LotStatus, b.Qty, b.OpenedOn,
           CASE WHEN b.OpenedOn IS NOT NULL AND i.OpenStabilityDays IS NOT NULL THEN DATEADD(DAY, i.OpenStabilityDays, b.OpenedOn) END AS OpenUseBy,
           DATEDIFF(DAY, @today, t.ExpiryDate) AS DaysToExpiry
    INTO #B
    FROM dbo.InvStockBalance b JOIN dbo.InvStore s ON s.StoreId = b.StoreId JOIN dbo.InvLot t ON t.LotId = b.LotId JOIN dbo.InvItem i ON i.ItemId = b.ItemId
    WHERE s.CompanyId = @CompanyId AND s.BranchId = @BranchId AND (@StoreId IS NULL OR b.StoreId = @StoreId)
      AND (b.Qty > 0 OR @Filter = 'ALL');

    IF @View = 'LOT'
    BEGIN
        SELECT x.*, i.ItemCode, i.ItemName, c.CategoryName, cu.UnitName AS ConsumptionUnit, pu.UnitName AS PurchaseUnit, i.PackSize,
               CAST(x.Qty / NULLIF(i.PackSize, 0) AS DECIMAL(18,3)) AS Packs, dbo.ufn_Qc_ItemUnitCost(i.ItemId) AS UnitCost,
               CAST(ROUND(x.Qty * dbo.ufn_Qc_ItemUnitCost(i.ItemId), 2) AS DECIMAL(18,2)) AS Value, i.OpenStabilityDays, i.StorageTemp,
               CASE WHEN x.ExpiryDate < @today THEN 'EXPIRED' WHEN x.DaysToExpiry <= @near THEN 'NEAR' ELSE 'OK' END AS ExpiryState
        FROM #B x JOIN dbo.InvItem i ON i.ItemId = x.ItemId JOIN dbo.InvItemCategory c ON c.CategoryId = i.CategoryId
        JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId JOIN dbo.InvUnit pu ON pu.UnitId = i.PurchaseUnitId
        WHERE (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
          AND (@Search IS NULL OR i.ItemName LIKE '%' + @Search + '%' OR i.ItemCode LIKE '%' + @Search + '%' OR x.LotNo LIKE '%' + @Search + '%')
          AND (@Filter IN ('ALL', 'INSTOCK', 'LOW')
               OR (@Filter = 'NEAR' AND x.ExpiryDate >= @today AND x.DaysToExpiry <= @near)
               OR (@Filter = 'EXPIRED' AND x.ExpiryDate < @today)
               OR (@Filter = 'QUARANTINE' AND x.LotStatus IN ('QUARANTINE', 'REJECTED', 'BLOCKED'))
               OR (@Filter = 'OPENED' AND x.OpenedOn IS NOT NULL))
        ORDER BY i.ItemName, x.StoreName, ISNULL(x.ExpiryDate, '99991231'), x.LotNo;
        RETURN;
    END

    SELECT i.ItemId, i.ItemCode, i.ItemName, c.CategoryName, cu.UnitName AS ConsumptionUnit, pu.UnitName AS PurchaseUnit, i.PackSize,
           ISNULL(g.Qty, 0) AS Qty, CAST(ISNULL(g.Qty, 0) / NULLIF(i.PackSize, 0) AS DECIMAL(18,3)) AS Packs,
           ISNULL(g.UsableQty, 0) AS UsableQty, ISNULL(g.HeldQty, 0) AS HeldQty, ISNULL(g.ExpiredQty, 0) AS ExpiredQty,
           dbo.ufn_Qc_ItemUnitCost(i.ItemId) AS UnitCost, CAST(ROUND(ISNULL(g.Qty, 0) * dbo.ufn_Qc_ItemUnitCost(i.ItemId), 2) AS DECIMAL(18,2)) AS Value,
           i.ReorderLevel, i.MinStock, i.MaxStock, g.NearestExpiry, g.Lots, g.Stores,
           CAST(CASE WHEN i.ReorderLevel IS NOT NULL AND ISNULL(g.UsableQty, 0) / NULLIF(i.PackSize, 0) <= i.ReorderLevel THEN 1 ELSE 0 END AS BIT) AS IsLow,
           (SELECT MAX(x.TxnOn) FROM dbo.InvStockLedger x WHERE x.ItemId = i.ItemId AND x.BranchId = @BranchId AND x.QtyIn > 0) AS LastReceiptOn,
           (SELECT MAX(x.TxnOn) FROM dbo.InvStockLedger x WHERE x.ItemId = i.ItemId AND x.BranchId = @BranchId AND x.QtyOut > 0) AS LastIssueOn
    FROM dbo.InvItem i
    JOIN dbo.InvItemCategory c ON c.CategoryId = i.CategoryId
    JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId JOIN dbo.InvUnit pu ON pu.UnitId = i.PurchaseUnitId
    LEFT JOIN (SELECT ItemId, SUM(Qty) AS Qty,
                      SUM(CASE WHEN LotStatus = 'ACCEPTED' AND (ExpiryDate IS NULL OR ExpiryDate >= @today) THEN Qty ELSE 0 END) AS UsableQty,
                      SUM(CASE WHEN LotStatus <> 'ACCEPTED' THEN Qty ELSE 0 END) AS HeldQty,
                      SUM(CASE WHEN ExpiryDate < @today THEN Qty ELSE 0 END) AS ExpiredQty,
                      MIN(CASE WHEN Qty > 0 AND (ExpiryDate IS NULL OR ExpiryDate >= @today) THEN ExpiryDate END) AS NearestExpiry,
                      COUNT(DISTINCT CASE WHEN Qty > 0 THEN LotId END) AS Lots, COUNT(DISTINCT CASE WHEN Qty > 0 THEN StoreId END) AS Stores,
                      MAX(CASE WHEN OpenedOn IS NOT NULL THEN 1 ELSE 0 END) AS AnyOpened,
                      MAX(CASE WHEN LotStatus <> 'ACCEPTED' AND Qty > 0 THEN 1 ELSE 0 END) AS AnyHeld,
                      MAX(CASE WHEN Qty > 0 AND ExpiryDate >= @today AND DaysToExpiry <= @near THEN 1 ELSE 0 END) AS AnyNear
               FROM #B GROUP BY ItemId) g ON g.ItemId = i.ItemId
    WHERE i.CompanyId = @CompanyId AND i.IsDeleted = 0 AND (i.Status = 1 OR g.Qty > 0)
      AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
      AND (@Search IS NULL OR i.ItemName LIKE '%' + @Search + '%' OR i.ItemCode LIKE '%' + @Search + '%' OR i.Manufacturer LIKE '%' + @Search + '%')
      AND (@Filter = 'ALL'
           OR (@Filter = 'INSTOCK' AND g.Qty > 0)
           OR (@Filter = 'LOW' AND i.ReorderLevel IS NOT NULL AND ISNULL(g.UsableQty, 0) / NULLIF(i.PackSize, 0) <= i.ReorderLevel)
           OR (@Filter = 'NEAR' AND g.AnyNear = 1)
           OR (@Filter = 'EXPIRED' AND g.ExpiredQty > 0)
           OR (@Filter = 'QUARANTINE' AND g.AnyHeld = 1)
           OR (@Filter = 'OPENED' AND g.AnyOpened = 1))
    ORDER BY i.ItemName;
END;
GO

-- item (or lot) movements with running balance
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_ItemLedger
    @CompanyId INT, @BranchId INT, @ItemId INT, @StoreId INT = NULL, @LotId INT = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @FromDate = ISNULL(@FromDate, DATEADD(MONTH, -3, CAST(GETDATE() AS DATE))); SET @ToDate = ISNULL(@ToDate, CAST(GETDATE() AS DATE));
    DECLARE @to DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @open DECIMAL(18,4) = (SELECT ISNULL(SUM(QtyIn - QtyOut), 0) FROM dbo.InvStockLedger
        WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND ItemId = @ItemId AND (@StoreId IS NULL OR StoreId = @StoreId) AND (@LotId IS NULL OR LotId = @LotId) AND TxnOn < @FromDate);
    SELECT i.ItemCode, i.ItemName, cu.UnitName AS ConsumptionUnit, i.PackSize, pu.UnitName AS PurchaseUnit, @open AS OpeningQty
    FROM dbo.InvItem i JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId JOIN dbo.InvUnit pu ON pu.UnitId = i.PurchaseUnitId WHERE i.ItemId = @ItemId AND i.CompanyId = @CompanyId;
    SELECT g.LedgerId, g.TxnOn, g.DocType, dbo.ufn_Inv_DocTypeName(g.DocType) AS MoveName, g.DocId, g.DocNo, s.StoreName, t.LotNo, t.ExpiryDate,
           g.QtyIn, g.QtyOut, g.UnitCost, g.Value, g.Remarks, dbo.ufn_Inv_UserName(g.UserId) AS UserName,
           @open + SUM(g.QtyIn - g.QtyOut) OVER (ORDER BY g.TxnOn, g.LedgerId ROWS UNBOUNDED PRECEDING) AS RunningQty,
           CASE WHEN g.DocType = 'CONS' THEN (SELECT TOP 1 m.Test_Name FROM dbo.QcConsumption c JOIN dbo.LabInvestigationMaster m ON m.Test_ID = c.TestId WHERE c.ConsumptionId = g.DocId) END AS TestName
    FROM dbo.InvStockLedger g JOIN dbo.InvStore s ON s.StoreId = g.StoreId JOIN dbo.InvLot t ON t.LotId = g.LotId
    WHERE g.CompanyId = @CompanyId AND g.BranchId = @BranchId AND g.ItemId = @ItemId AND (@StoreId IS NULL OR g.StoreId = @StoreId) AND (@LotId IS NULL OR g.LotId = @LotId)
      AND g.TxnOn >= @FromDate AND g.TxnOn < @to
    ORDER BY g.TxnOn, g.LedgerId;
END;
GO

-- lots of an item for a line. @Purpose ISSUE (accepted, unexpired, in stock) | OUT (any in stock: return, write-off) | ANY (count, found stock)
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_LotsForPick @CompanyId INT, @BranchId INT, @StoreId INT, @ItemId INT, @Purpose VARCHAR(6) = 'ISSUE'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    SELECT t.LotId, t.LotNo, t.ExpiryDate, t.Status, ISNULL(b.Qty, 0) AS Qty, b.OpenedOn, DATEDIFF(DAY, @today, t.ExpiryDate) AS DaysToExpiry,
           t.UnitCost AS LotCost, dbo.ufn_Qc_ItemUnitCost(t.ItemId) AS AvgCost,
           (SELECT TOP 1 l.Rate / NULLIF(l.Factor, 0) FROM dbo.InvDocLine l JOIN dbo.InvDoc d ON d.DocId = l.DocId
            WHERE l.LotId = t.LotId AND d.DocType = 'GRN' AND d.Status = 'POSTED' ORDER BY d.DocId DESC) AS GrnUnitRate,
           (SELECT TOP 1 l.GstPct FROM dbo.InvDocLine l JOIN dbo.InvDoc d ON d.DocId = l.DocId
            WHERE l.LotId = t.LotId AND d.DocType = 'GRN' AND d.Status = 'POSTED' ORDER BY d.DocId DESC) AS GrnGstPct
    FROM dbo.InvLot t
    LEFT JOIN dbo.InvStockBalance b ON b.LotId = t.LotId AND b.StoreId = @StoreId
    WHERE t.CompanyId = @CompanyId AND t.ItemId = @ItemId
      AND EXISTS (SELECT 1 FROM dbo.InvStore s WHERE s.StoreId = @StoreId AND s.CompanyId = @CompanyId)
      AND ((@Purpose = 'ISSUE' AND b.Qty > 0 AND t.Status = 'ACCEPTED' AND (t.ExpiryDate IS NULL OR t.ExpiryDate >= @today))
        OR (@Purpose = 'OUT' AND b.Qty > 0)
        OR (@Purpose = 'ANY'))
    ORDER BY CASE WHEN b.OpenedOn IS NOT NULL THEN 0 ELSE 1 END, ISNULL(t.ExpiryDate, '99991231'), t.LotId;
END;
GO

-- FEFO allocation of a quantity (consumption units) over the usable lots of a store
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_Fefo @CompanyId INT, @StoreId INT, @ItemId INT, @Qty DECIMAL(18,4)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    ;WITH L AS (
        SELECT t.LotId, t.LotNo, t.ExpiryDate, b.Qty, b.OpenedOn,
               SUM(b.Qty) OVER (ORDER BY CASE WHEN b.OpenedOn IS NOT NULL THEN 0 ELSE 1 END, ISNULL(t.ExpiryDate, '99991231'), t.LotId ROWS UNBOUNDED PRECEDING) AS Cum
        FROM dbo.InvStockBalance b JOIN dbo.InvLot t ON t.LotId = b.LotId
        WHERE b.StoreId = @StoreId AND b.ItemId = @ItemId AND b.Qty > 0 AND t.CompanyId = @CompanyId AND t.Status = 'ACCEPTED'
          AND (t.ExpiryDate IS NULL OR t.ExpiryDate >= @today))
    SELECT LotId, LotNo, ExpiryDate, Qty AS Available,
           CASE WHEN Cum <= @Qty THEN Qty ELSE @Qty - (Cum - Qty) END AS Take
    FROM L WHERE Cum - Qty < @Qty
    ORDER BY Cum;
END;
GO

-- an indent's pending quantities allocated FEFO from the supplying store (to start an issue)
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_IndentForIssue @CompanyId INT, @BranchId INT, @IndentId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @store INT, @today DATE = CAST(GETDATE() AS DATE);
    SELECT @store = d.ToStoreId FROM dbo.InvDoc d JOIN dbo.InvStore s ON s.StoreId = d.ToStoreId
    WHERE d.DocId = @IndentId AND d.CompanyId = @CompanyId AND d.DocType = 'IND' AND s.BranchId = @BranchId AND d.Status IN ('SUBMITTED', 'PARTIAL');
    IF @store IS NULL BEGIN SELECT TOP 0 1 AS Nothing; RETURN; END
    ;WITH P AS (
        SELECT l.LineId, l.ItemId, l.BaseQty - l.DoneBaseQty AS Pending FROM dbo.InvDocLine l WHERE l.DocId = @IndentId AND l.BaseQty > l.DoneBaseQty),
    L AS (
        SELECT p.LineId, p.ItemId, p.Pending, t.LotId, t.LotNo, t.ExpiryDate, b.Qty,
               SUM(b.Qty) OVER (PARTITION BY p.LineId ORDER BY CASE WHEN b.OpenedOn IS NOT NULL THEN 0 ELSE 1 END, ISNULL(t.ExpiryDate, '99991231'), t.LotId ROWS UNBOUNDED PRECEDING) AS Cum
        FROM P p JOIN dbo.InvStockBalance b ON b.StoreId = @store AND b.ItemId = p.ItemId AND b.Qty > 0
        JOIN dbo.InvLot t ON t.LotId = b.LotId AND t.Status = 'ACCEPTED' AND (t.ExpiryDate IS NULL OR t.ExpiryDate >= @today))
    SELECT p.LineId AS RefLineId, p.ItemId, p.Pending, x.LotId, x.LotNo, x.ExpiryDate, x.Qty AS Available,
           CASE WHEN x.LotId IS NULL THEN 0 WHEN x.Cum <= p.Pending THEN x.Qty ELSE p.Pending - (x.Cum - x.Qty) END AS Take
    FROM P p LEFT JOIN L x ON x.LineId = p.LineId AND x.Cum - x.Qty < p.Pending
    ORDER BY p.LineId, x.Cum;
END;
GO

-- items at or below reorder level in this branch, with a suggested order in packs
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_Reorder @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    ;WITH S AS (
        SELECT b.ItemId, SUM(CASE WHEN t.Status = 'ACCEPTED' AND (t.ExpiryDate IS NULL OR t.ExpiryDate >= @today) THEN b.Qty ELSE 0 END) AS Usable
        FROM dbo.InvStockBalance b JOIN dbo.InvStore s ON s.StoreId = b.StoreId JOIN dbo.InvLot t ON t.LotId = b.LotId
        WHERE s.BranchId = @BranchId AND s.CompanyId = @CompanyId GROUP BY b.ItemId),
    U AS (
        SELECT ItemId, SUM(QtyOut) / 30.0 AS PerDay FROM dbo.InvStockLedger
        WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND DocType IN ('CONS', 'ADJ') AND TxnOn >= DATEADD(DAY, -30, @today) GROUP BY ItemId),
    O AS (
        SELECT l.ItemId, SUM(l.BaseQty - l.DoneBaseQty) AS OnOrder FROM dbo.InvDocLine l JOIN dbo.InvDoc d ON d.DocId = l.DocId
        WHERE d.DocType = 'PO' AND d.BranchId = @BranchId AND d.Status IN ('SUBMITTED', 'APPROVED', 'PARTIAL') AND l.BaseQty > l.DoneBaseQty GROUP BY l.ItemId)
    SELECT i.ItemId, i.ItemCode, i.ItemName, pu.UnitName AS PurchaseUnit, cu.UnitName AS ConsumptionUnit, i.PackSize,
           CAST(ISNULL(s.Usable, 0) / i.PackSize AS DECIMAL(18,3)) AS StockPacks, i.ReorderLevel, i.MinStock, i.MaxStock,
           CAST(ISNULL(o.OnOrder, 0) / i.PackSize AS DECIMAL(18,3)) AS OnOrderPacks,
           CAST(ISNULL(u.PerDay, 0) AS DECIMAL(18,3)) AS UsePerDay,
           CASE WHEN ISNULL(u.PerDay, 0) > 0 THEN CAST(ISNULL(s.Usable, 0) / u.PerDay AS DECIMAL(18,1)) END AS DaysLeft,
           CAST(CEILING(CASE WHEN ISNULL(i.MaxStock, i.ReorderLevel * 2) - ISNULL(s.Usable, 0) / i.PackSize - ISNULL(o.OnOrder, 0) / i.PackSize > 0
                             THEN ISNULL(i.MaxStock, i.ReorderLevel * 2) - ISNULL(s.Usable, 0) / i.PackSize - ISNULL(o.OnOrder, 0) / i.PackSize ELSE 0 END) AS DECIMAL(18,0)) AS SuggestPacks,
           i.PurchaseRate, ISNULL(i.GstPercent, 0) AS GstPercent,
           (SELECT TOP 1 d.SupplierId FROM dbo.InvDocLine l JOIN dbo.InvDoc d ON d.DocId = l.DocId WHERE l.ItemId = i.ItemId AND d.DocType = 'GRN' AND d.Status = 'POSTED' ORDER BY d.DocId DESC) AS LastSupplierId,
           (SELECT TOP 1 sp.SupplierName FROM dbo.InvDocLine l JOIN dbo.InvDoc d ON d.DocId = l.DocId JOIN dbo.InvSupplier sp ON sp.SupplierId = d.SupplierId
            WHERE l.ItemId = i.ItemId AND d.DocType = 'GRN' AND d.Status = 'POSTED' ORDER BY d.DocId DESC) AS LastSupplier
    FROM dbo.InvItem i
    JOIN dbo.InvUnit pu ON pu.UnitId = i.PurchaseUnitId JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    LEFT JOIN S s ON s.ItemId = i.ItemId LEFT JOIN U u ON u.ItemId = i.ItemId LEFT JOIN O o ON o.ItemId = i.ItemId
    WHERE i.CompanyId = @CompanyId AND i.IsDeleted = 0 AND i.Status = 1 AND i.ReorderLevel IS NOT NULL
      AND ISNULL(s.Usable, 0) / i.PackSize <= i.ReorderLevel
    ORDER BY CASE WHEN ISNULL(u.PerDay, 0) > 0 THEN ISNULL(s.Usable, 0) / u.PerDay ELSE 99999 END, i.ItemName;
END;
GO

-- ═════ Lot acceptance / hold ══════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_Lots @CompanyId INT, @BranchId INT, @Status VARCHAR(12) = 'QUARANTINE', @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @Status = NULLIF(@Status, '');
    SELECT TOP 500 t.LotId, t.LotNo, t.ExpiryDate, t.MfgDate, t.Status, t.UnitCost, t.DecisionNote, t.DecisionOn, dbo.ufn_Inv_UserName(t.DecisionBy) AS DecisionByName,
           t.CreatedOn, i.ItemId, i.ItemCode, i.ItemName, c.CategoryName, cu.UnitName AS ConsumptionUnit, i.Manufacturer, i.StorageTemp,
           sp.SupplierName, d.DocNo AS FirstDocNo, d.DocType AS FirstDocType, d.DocId AS FirstDocId,
           ISNULL((SELECT SUM(b.Qty) FROM dbo.InvStockBalance b JOIN dbo.InvStore s ON s.StoreId = b.StoreId WHERE b.LotId = t.LotId AND s.BranchId = @BranchId), 0) AS BranchQty,
           ISNULL((SELECT SUM(b.Qty) FROM dbo.InvStockBalance b WHERE b.LotId = t.LotId), 0) AS TotalQty,
           (SELECT TOP 1 p.LotNo FROM dbo.InvLot p WHERE p.ItemId = t.ItemId AND p.Status = 'ACCEPTED' AND p.LotId <> t.LotId ORDER BY p.LotId DESC) AS PreviousLotNo,
           DATEDIFF(DAY, CAST(GETDATE() AS DATE), t.ExpiryDate) AS DaysToExpiry
    FROM dbo.InvLot t JOIN dbo.InvItem i ON i.ItemId = t.ItemId JOIN dbo.InvItemCategory c ON c.CategoryId = i.CategoryId
    JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    LEFT JOIN dbo.InvSupplier sp ON sp.SupplierId = t.SupplierId LEFT JOIN dbo.InvDoc d ON d.DocId = t.FirstDocId
    WHERE t.CompanyId = @CompanyId AND t.LotNo <> N'NA'
      AND (@Status IS NULL OR t.Status = @Status)
      AND (@Search IS NULL OR t.LotNo LIKE '%' + @Search + '%' OR i.ItemName LIKE '%' + @Search + '%' OR i.ItemCode LIKE '%' + @Search + '%')
    ORDER BY CASE t.Status WHEN 'QUARANTINE' THEN 0 WHEN 'BLOCKED' THEN 1 ELSE 2 END, t.CreatedOn DESC;
END;
GO

-- @Action ACCEPT (quarantine -> accepted, verification note required) | REJECT | BLOCK (accepted -> on hold) | UNBLOCK
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_LotAction @CompanyId INT, @UserId INT, @LotId INT, @Action VARCHAR(10), @Note NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @st VARCHAR(12), @new VARCHAR(12);
        SET @Note = NULLIF(LTRIM(RTRIM(@Note)), ''); SET @Action = UPPER(@Action);
        SELECT @st = Status FROM dbo.InvLot WITH (UPDLOCK) WHERE LotId = @LotId AND CompanyId = @CompanyId;
        IF @st IS NULL THROW 53690, 'The lot was not found.', 1;
        SET @new = CASE WHEN @Action = 'ACCEPT' AND @st = 'QUARANTINE' THEN 'ACCEPTED'
                        WHEN @Action = 'REJECT' AND @st IN ('QUARANTINE', 'BLOCKED') THEN 'REJECTED'
                        WHEN @Action = 'BLOCK' AND @st = 'ACCEPTED' THEN 'BLOCKED'
                        WHEN @Action = 'UNBLOCK' AND @st = 'BLOCKED' THEN 'ACCEPTED' END;
        IF @new IS NULL THROW 53691, 'This lot cannot be changed that way from its current status.', 1;
        IF @Note IS NULL THROW 53692, 'Record the verification result or the reason.', 1;
        UPDATE dbo.InvLot SET Status = @new, DecisionBy = @UserId, DecisionOn = GETDATE(),
               DecisionNote = LEFT(CONCAT(FORMAT(GETDATE(), 'dd-MMM-yyyy HH:mm'), N' ', @Action, N': ', @Note, CASE WHEN DecisionNote IS NULL THEN N'' ELSE N' | ' + DecisionNote END), 1000)
        WHERE LotId = @LotId;

        -- the lot became usable (accepted / unblocked): settle test consumption of this item waiting in the branches holding it
        IF @new = 'ACCEPTED'
        BEGIN
            BEGIN TRY
                DECLARE @waiting NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(l.ConsumptionLineId AS VARCHAR(12)), ',')
                    FROM dbo.QcConsumptionLine l JOIN dbo.QcConsumption c ON c.ConsumptionId = l.ConsumptionId
                    WHERE c.CompanyId = @CompanyId AND l.StockStatus = 'PENDING'
                      AND l.ItemId = (SELECT ItemId FROM dbo.InvLot WHERE LotId = @LotId)
                      AND c.BranchId IN (SELECT s.BranchId FROM dbo.InvStockBalance b JOIN dbo.InvStore s ON s.StoreId = b.StoreId WHERE b.LotId = @LotId AND b.Qty > 0));
                IF @waiting IS NOT NULL EXEC dbo.usp_Inv_ConsumeLines @LabOrderId = NULL, @LineIds = @waiting, @UserId = @UserId;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
                BEGIN TRY
                    INSERT INTO dbo.QcConsumptionLog (LabOrderId, ErrorNumber, ErrorMessage) VALUES (NULL, ERROR_NUMBER(), LEFT(N'Stock: pending settle after lot ' + CAST(@LotId AS NVARCHAR(12)) + N' accepted: ' + ERROR_MESSAGE(), 2000));
                END TRY
                BEGIN CATCH
                END CATCH
            END CATCH
        END
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @LotId AS LotId, @new AS Status;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, CAST(ERROR_MESSAGE() AS NVARCHAR(600)) AS Error; ELSE THROW;
    END CATCH
END;
GO

-- open-vial tracking: the date the first container of a lot was opened in a store (@Clear = 1 removes it)
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_MarkOpened @CompanyId INT, @BranchId INT, @UserId INT, @StoreId INT, @LotId INT, @OpenedOn DATE = NULL, @Clear BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SET @OpenedOn = ISNULL(@OpenedOn, CAST(GETDATE() AS DATE));
        IF @OpenedOn > CAST(GETDATE() AS DATE) THROW 53693, 'The opened date cannot be in the future.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.InvStockBalance b JOIN dbo.InvStore s ON s.StoreId = b.StoreId
                       WHERE b.StoreId = @StoreId AND b.LotId = @LotId AND s.BranchId = @BranchId AND s.CompanyId = @CompanyId)
            THROW 53694, 'This lot is not held in a store of this branch.', 1;
        UPDATE dbo.InvStockBalance SET OpenedOn = CASE WHEN @Clear = 1 THEN NULL ELSE @OpenedOn END, OpenedBy = CASE WHEN @Clear = 1 THEN NULL ELSE @UserId END
        WHERE StoreId = @StoreId AND LotId = @LotId;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, CAST(ERROR_MESSAGE() AS NVARCHAR(600)) AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ═════ Pending consumption (tests that ran while a store was short) ═══════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_Pending @CompanyId INT, @BranchId INT, @Status VARCHAR(12) = 'PENDING', @FromDate DATE = NULL, @ToDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Status = ISNULL(NULLIF(@Status, ''), 'PENDING');
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    SELECT TOP 1000 l.ConsumptionLineId AS LineId, c.ConsumptionId, c.LabOrderId, lo.BillNo, c.ConsumedOn, m.Test_Name AS TestName, c.RunNo,
           i.ItemId, i.ItemCode, i.ItemName, cu.UnitName AS ConsumptionUnit, l.Qty, l.StockStatus, l.StockNote, l.StoreId, s.StoreName,
           ISNULL((SELECT SUM(b.Qty) FROM dbo.InvStockBalance b JOIN dbo.InvLot t ON t.LotId = b.LotId
                   WHERE b.StoreId = l.StoreId AND b.ItemId = l.ItemId AND t.Status = 'ACCEPTED' AND (t.ExpiryDate IS NULL OR t.ExpiryDate >= @today)), 0) AS AvailableNow
    FROM dbo.QcConsumptionLine l
    JOIN dbo.QcConsumption c ON c.ConsumptionId = l.ConsumptionId
    JOIN dbo.InvItem i ON i.ItemId = l.ItemId JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    LEFT JOIN dbo.LabInvestigationMaster m ON m.Test_ID = c.TestId
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = c.LabOrderId
    LEFT JOIN dbo.InvStore s ON s.StoreId = l.StoreId
    WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId AND l.StockStatus = @Status
      AND (@FromDate IS NULL OR c.ConsumedOn >= @FromDate) AND (@ToDate IS NULL OR c.ConsumedOn < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)))
    ORDER BY c.ConsumedOn DESC, l.ConsumptionLineId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_PendingRetry @CompanyId INT, @BranchId INT, @UserId INT, @LineIds NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @ids NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(l.ConsumptionLineId AS VARCHAR(12)), ',')
            FROM dbo.QcConsumptionLine l JOIN dbo.QcConsumption c ON c.ConsumptionId = l.ConsumptionId
            WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId AND l.StockStatus = 'PENDING'
              AND l.ConsumptionLineId IN (SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(ISNULL(@LineIds, ''), ',')));
        IF @ids IS NULL THROW 53695, 'Select pending lines of this branch.', 1;
        EXEC dbo.usp_Inv_ConsumeLines @LabOrderId = NULL, @LineIds = @ids, @UserId = @UserId;
        DECLARE @today DATE = CAST(GETDATE() AS DATE);
        EXEC dbo.usp_Inv_PostConsumptionAccounts @CompanyId = @CompanyId, @BranchId = @BranchId, @UpTo = @today, @UserId = @UserId;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error,
               SUM(CASE WHEN StockStatus = 'POSTED' THEN 1 ELSE 0 END) AS Posted, SUM(CASE WHEN StockStatus = 'PENDING' THEN 1 ELSE 0 END) AS StillPending
        FROM dbo.QcConsumptionLine WHERE ConsumptionLineId IN (SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(@ids, ','));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, CAST(ERROR_MESSAGE() AS NVARCHAR(600)) AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_PendingSkip @CompanyId INT, @BranchId INT, @UserId INT, @LineIds NVARCHAR(MAX), @Reason NVARCHAR(250)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), '');
        IF @Reason IS NULL THROW 53696, 'Give the reason for not taking these lines out of stock.', 1;
        UPDATE l SET StockStatus = 'SKIPPED', StockNote = LEFT(CONCAT(N'Skipped by ', dbo.ufn_Inv_UserName(@UserId), N' on ', FORMAT(GETDATE(), 'dd-MMM-yyyy'), N': ', @Reason), 300)
        FROM dbo.QcConsumptionLine l JOIN dbo.QcConsumption c ON c.ConsumptionId = l.ConsumptionId
        WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId AND l.StockStatus = 'PENDING'
          AND l.ConsumptionLineId IN (SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(ISNULL(@LineIds, ''), ','));
        IF @@ROWCOUNT = 0 THROW 53695, 'Select pending lines of this branch.', 1;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, CAST(ERROR_MESSAGE() AS NVARCHAR(600)) AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ═════ Settings, accounts ═════════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_SettingsSave
    @CompanyId INT, @UserId INT, @PoApprovalRequired BIT, @AdjApprovalRequired BIT, @CountApprovalRequired BIT, @LotAcceptanceRequired BIT,
    @DeductOnConsumption BIT, @NearExpiryDays INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @NearExpiryDays IS NULL OR @NearExpiryDays < 1 OR @NearExpiryDays > 365 THROW 53697, 'Near-expiry days must be between 1 and 365.', 1;
        IF EXISTS (SELECT 1 FROM dbo.InvSettings WHERE CompanyId = @CompanyId)
            UPDATE dbo.InvSettings SET PoApprovalRequired = @PoApprovalRequired, AdjApprovalRequired = @AdjApprovalRequired, CountApprovalRequired = @CountApprovalRequired,
                   LotAcceptanceRequired = @LotAcceptanceRequired, DeductOnConsumption = @DeductOnConsumption, NearExpiryDays = @NearExpiryDays,
                   ModifiedBy = @UserId, ModifiedOn = GETDATE()
            WHERE CompanyId = @CompanyId;
        ELSE
            INSERT dbo.InvSettings (CompanyId, PoApprovalRequired, AdjApprovalRequired, CountApprovalRequired, LotAcceptanceRequired, DeductOnConsumption, NearExpiryDays, ModifiedBy, ModifiedOn)
            VALUES (@CompanyId, @PoApprovalRequired, @AdjApprovalRequired, @CountApprovalRequired, @LotAcceptanceRequired, @DeductOnConsumption, @NearExpiryDays, @UserId, GETDATE());
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, CAST(ERROR_MESSAGE() AS NVARCHAR(600)) AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_PostConsumption @CompanyId INT, @BranchId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @before INT = (SELECT COUNT(1) FROM dbo.InvConsumptionPosting WHERE BranchId = @BranchId), @today DATE = CAST(GETDATE() AS DATE);
        EXEC dbo.usp_Inv_PostConsumptionAccounts @CompanyId = @CompanyId, @BranchId = @BranchId, @UpTo = @today, @UserId = @UserId;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, (SELECT COUNT(1) FROM dbo.InvConsumptionPosting WHERE BranchId = @BranchId) - @before AS DaysPosted;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, CAST(ERROR_MESSAGE() AS NVARCHAR(600)) AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ═════ Dashboard ══════════════════════════════════════════════════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_Dashboard @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @near INT = (SELECT NearExpiryDays FROM dbo.ufn_Inv_Settings(@CompanyId));
    SELECT b.StoreId, b.LotId, b.ItemId, b.Qty, b.OpenedOn, t.Status, t.ExpiryDate, t.LotNo, i.PackSize, i.ReorderLevel, i.OpenStabilityDays
    INTO #B
    FROM dbo.InvStockBalance b JOIN dbo.InvStore s ON s.StoreId = b.StoreId JOIN dbo.InvLot t ON t.LotId = b.LotId JOIN dbo.InvItem i ON i.ItemId = b.ItemId
    WHERE s.BranchId = @BranchId AND s.CompanyId = @CompanyId AND b.Qty > 0;

    -- 1. tiles
    SELECT CAST(ISNULL((SELECT SUM(ROUND(x.Qty * dbo.ufn_Qc_ItemUnitCost(x.ItemId), 2)) FROM #B x), 0) AS DECIMAL(18,2)) AS StockValue,
           (SELECT COUNT(DISTINCT ItemId) FROM #B) AS ItemsInStock,
           (SELECT COUNT(1) FROM dbo.InvItem i WHERE i.CompanyId = @CompanyId AND i.IsDeleted = 0 AND i.Status = 1 AND i.ReorderLevel IS NOT NULL
               AND ISNULL((SELECT SUM(x.Qty) FROM #B x WHERE x.ItemId = i.ItemId AND x.Status = 'ACCEPTED' AND (x.ExpiryDate IS NULL OR x.ExpiryDate >= @today)), 0) / i.PackSize <= i.ReorderLevel) AS BelowReorder,
           (SELECT COUNT(1) FROM #B WHERE ExpiryDate >= @today AND DATEDIFF(DAY, @today, ExpiryDate) <= @near) AS NearExpiryLots,
           CAST(ISNULL((SELECT SUM(ROUND(x.Qty * dbo.ufn_Qc_ItemUnitCost(x.ItemId), 2)) FROM #B x WHERE x.ExpiryDate >= @today AND DATEDIFF(DAY, @today, x.ExpiryDate) <= @near), 0) AS DECIMAL(18,2)) AS NearExpiryValue,
           (SELECT COUNT(1) FROM #B WHERE ExpiryDate < @today) AS ExpiredLots,
           CAST(ISNULL((SELECT SUM(ROUND(x.Qty * dbo.ufn_Qc_ItemUnitCost(x.ItemId), 2)) FROM #B x WHERE x.ExpiryDate < @today), 0) AS DECIMAL(18,2)) AS ExpiredValue,
           (SELECT COUNT(1) FROM dbo.InvLot t WHERE t.CompanyId = @CompanyId AND t.Status = 'QUARANTINE'
               AND EXISTS (SELECT 1 FROM #B x WHERE x.LotId = t.LotId)) AS QuarantineLots,
           (SELECT COUNT(1) FROM #B WHERE OpenedOn IS NOT NULL AND OpenStabilityDays IS NOT NULL AND DATEADD(DAY, OpenStabilityDays, OpenedOn) < @today) AS OpenedPastStability,
           (SELECT COUNT(1) FROM dbo.QcConsumptionLine l JOIN dbo.QcConsumption c ON c.ConsumptionId = l.ConsumptionId
               WHERE c.BranchId = @BranchId AND c.CompanyId = @CompanyId AND l.StockStatus = 'PENDING') AS PendingConsumption,
           CAST(ISNULL((SELECT -SUM(Value) FROM dbo.InvStockLedger WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND DocType = 'CONS'
               AND TxnOn >= DATEADD(DAY, -30, @today)), 0) AS DECIMAL(18,2)) AS Consumption30,
           CAST(ISNULL((SELECT SUM(NetAmount) FROM dbo.InvDoc WHERE BranchId = @BranchId AND DocType = 'GRN' AND Status = 'POSTED'
               AND DocDate >= DATEFROMPARTS(YEAR(@today), MONTH(@today), 1)), 0) AS DECIMAL(18,2)) AS PurchaseThisMonth,
           (SELECT COUNT(1) FROM dbo.InvDoc WHERE BranchId = @BranchId AND DocType = 'PO' AND Status = 'SUBMITTED') AS PoToApprove,
           (SELECT COUNT(1) FROM dbo.InvDoc WHERE BranchId = @BranchId AND DocType = 'PO' AND Status IN ('APPROVED', 'PARTIAL')) AS PoOpen,
           (SELECT COUNT(1) FROM dbo.InvDoc WHERE BranchId = @BranchId AND DocType IN ('ADJ', 'CNT') AND Status = 'SUBMITTED') AS AdjToApprove,
           (SELECT COUNT(1) FROM dbo.InvDoc d JOIN dbo.InvStore s ON s.StoreId = d.ToStoreId WHERE s.BranchId = @BranchId AND d.DocType = 'IND' AND d.Status IN ('SUBMITTED', 'PARTIAL')) AS IndentsToIssue,
           (SELECT COUNT(1) FROM dbo.InvDoc d JOIN dbo.InvStore s ON s.StoreId = d.ToStoreId WHERE s.BranchId = @BranchId AND d.DocType = 'ISS' AND d.Status = 'INTRANSIT') AS IssuesToReceive,
           (SELECT COUNT(1) FROM dbo.InvDoc WHERE BranchId = @BranchId AND Status = 'DRAFT') AS Drafts,
           (SELECT COUNT(1) FROM dbo.InvStore WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND IsDeleted = 0 AND Status = 1
               AND NOT EXISTS (SELECT 1 FROM dbo.InvStockLedger g WHERE g.StoreId = InvStore.StoreId)) AS StoresNotStarted;

    -- 2. lots expiring soonest (incl. expired)
    SELECT TOP 12 x.LotId, x.StoreId, s.StoreName, i.ItemName, x.LotNo, x.ExpiryDate, DATEDIFF(DAY, @today, x.ExpiryDate) AS DaysToExpiry, x.Qty, cu.UnitName AS ConsumptionUnit,
           CAST(ROUND(x.Qty * dbo.ufn_Qc_ItemUnitCost(x.ItemId), 2) AS DECIMAL(18,2)) AS Value
    FROM #B x JOIN dbo.InvStore s ON s.StoreId = x.StoreId JOIN dbo.InvItem i ON i.ItemId = x.ItemId JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    WHERE x.ExpiryDate IS NOT NULL AND DATEDIFF(DAY, @today, x.ExpiryDate) <= @near
    ORDER BY x.ExpiryDate;

    -- 3. below reorder
    SELECT TOP 12 i.ItemId, i.ItemName, pu.UnitName AS PurchaseUnit, i.ReorderLevel,
           CAST(ISNULL((SELECT SUM(x.Qty) FROM #B x WHERE x.ItemId = i.ItemId AND x.Status = 'ACCEPTED' AND (x.ExpiryDate IS NULL OR x.ExpiryDate >= @today)), 0) / i.PackSize AS DECIMAL(18,2)) AS StockPacks
    FROM dbo.InvItem i JOIN dbo.InvUnit pu ON pu.UnitId = i.PurchaseUnitId
    WHERE i.CompanyId = @CompanyId AND i.IsDeleted = 0 AND i.Status = 1 AND i.ReorderLevel IS NOT NULL
      AND ISNULL((SELECT SUM(x.Qty) FROM #B x WHERE x.ItemId = i.ItemId AND x.Status = 'ACCEPTED' AND (x.ExpiryDate IS NULL OR x.ExpiryDate >= @today)), 0) / i.PackSize <= i.ReorderLevel
    ORDER BY 5, i.ItemName;

    -- 4. consumption value per day, last 30 days (tests + QC / calibration use)
    SELECT CAST(g.TxnOn AS DATE) AS Day, CAST(-SUM(CASE WHEN g.DocType = 'CONS' THEN g.Value ELSE 0 END) AS DECIMAL(18,2)) AS Tests,
           CAST(-SUM(CASE WHEN g.DocType = 'ADJ' AND r.IsUsage = 1 THEN g.Value ELSE 0 END) AS DECIMAL(18,2)) AS QcUse
    FROM dbo.InvStockLedger g LEFT JOIN dbo.InvDoc d ON d.DocId = g.DocId AND g.DocType = 'ADJ' LEFT JOIN dbo.InvAdjReason r ON r.ReasonCode = d.ReasonCode
    WHERE g.BranchId = @BranchId AND g.CompanyId = @CompanyId AND g.TxnOn >= DATEADD(DAY, -29, @today) AND g.DocType IN ('CONS', 'ADJ')
    GROUP BY CAST(g.TxnOn AS DATE) ORDER BY 1;

    -- 5. stock value by store
    SELECT s.StoreId, s.StoreName, s.StoreType, CAST(ISNULL(SUM(ROUND(x.Qty * dbo.ufn_Qc_ItemUnitCost(x.ItemId), 2)), 0) AS DECIMAL(18,2)) AS Value,
           COUNT(DISTINCT x.ItemId) AS Items, CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.InvStockLedger g WHERE g.StoreId = s.StoreId) THEN 1 ELSE 0 END AS BIT) AS Started
    FROM dbo.InvStore s LEFT JOIN #B x ON x.StoreId = s.StoreId
    WHERE s.BranchId = @BranchId AND s.CompanyId = @CompanyId AND s.IsDeleted = 0 AND s.Status = 1
    GROUP BY s.StoreId, s.StoreName, s.StoreType ORDER BY CASE s.StoreType WHEN 'Main' THEN 0 ELSE 1 END, s.StoreName;

    -- 6. settings
    SELECT * FROM dbo.ufn_Inv_Settings(@CompanyId);
END;
GO

-- ═════ Reports ════════════════════════════════════════════════════════════════════════════════════════════
-- one result set; column names are the headings shown and exported
CREATE OR ALTER PROCEDURE dbo.usp_Api_QcInv_Report
    @CompanyId INT, @BranchId INT, @Report VARCHAR(20), @FromDate DATE = NULL, @ToDate DATE = NULL, @StoreId INT = NULL, @ItemId INT = NULL,
    @SupplierId INT = NULL, @CategoryId INT = NULL, @Days INT = NULL, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    SET @FromDate = ISNULL(@FromDate, DATEFROMPARTS(YEAR(@today), MONTH(@today), 1)); SET @ToDate = ISNULL(@ToDate, @today);
    DECLARE @to DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');

    IF @Report = 'STOCK'           -- stock summary by store and item, as now
        SELECT s.StoreName AS [Store], i.ItemCode AS [Code], i.ItemName AS [Item], c.CategoryName AS [Category], SUM(b.Qty) AS [Qty], cu.UnitName AS [Unit],
               CAST(SUM(b.Qty) / i.PackSize AS DECIMAL(18,3)) AS [Packs], pu.UnitName AS [Pack unit], dbo.ufn_Qc_ItemUnitCost(i.ItemId) AS [Avg cost / unit],
               CAST(ROUND(SUM(b.Qty) * dbo.ufn_Qc_ItemUnitCost(i.ItemId), 2) AS DECIMAL(18,2)) AS [Value], COUNT(DISTINCT b.LotId) AS [Lots],
               MIN(CASE WHEN t.ExpiryDate >= @today THEN t.ExpiryDate END) AS [Nearest expiry], i.ReorderLevel AS [Reorder level (packs)]
        FROM dbo.InvStockBalance b JOIN dbo.InvStore s ON s.StoreId = b.StoreId JOIN dbo.InvItem i ON i.ItemId = b.ItemId JOIN dbo.InvLot t ON t.LotId = b.LotId
        JOIN dbo.InvItemCategory c ON c.CategoryId = i.CategoryId JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId JOIN dbo.InvUnit pu ON pu.UnitId = i.PurchaseUnitId
        WHERE s.BranchId = @BranchId AND s.CompanyId = @CompanyId AND b.Qty > 0 AND (@StoreId IS NULL OR b.StoreId = @StoreId)
          AND (@ItemId IS NULL OR b.ItemId = @ItemId) AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
        GROUP BY s.StoreName, i.ItemId, i.ItemCode, i.ItemName, c.CategoryName, cu.UnitName, pu.UnitName, i.PackSize, i.ReorderLevel
        ORDER BY s.StoreName, i.ItemName;

    ELSE IF @Report = 'LOTS'       -- lot-wise stock with expiry and status
        SELECT s.StoreName AS [Store], i.ItemCode AS [Code], i.ItemName AS [Item], t.LotNo AS [Lot], t.ExpiryDate AS [Expiry], DATEDIFF(DAY, @today, t.ExpiryDate) AS [Days left],
               t.Status AS [Lot status], b.Qty AS [Qty], cu.UnitName AS [Unit], b.OpenedOn AS [Opened on],
               CASE WHEN b.OpenedOn IS NOT NULL AND i.OpenStabilityDays IS NOT NULL THEN DATEADD(DAY, i.OpenStabilityDays, b.OpenedOn) END AS [Use opened by],
               CAST(ROUND(b.Qty * dbo.ufn_Qc_ItemUnitCost(i.ItemId), 2) AS DECIMAL(18,2)) AS [Value], sp.SupplierName AS [Supplier]
        FROM dbo.InvStockBalance b JOIN dbo.InvStore s ON s.StoreId = b.StoreId JOIN dbo.InvItem i ON i.ItemId = b.ItemId JOIN dbo.InvLot t ON t.LotId = b.LotId
        JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId LEFT JOIN dbo.InvSupplier sp ON sp.SupplierId = t.SupplierId
        WHERE s.BranchId = @BranchId AND s.CompanyId = @CompanyId AND b.Qty > 0 AND (@StoreId IS NULL OR b.StoreId = @StoreId)
          AND (@ItemId IS NULL OR b.ItemId = @ItemId) AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
        ORDER BY i.ItemName, s.StoreName, ISNULL(t.ExpiryDate, '99991231');

    ELSE IF @Report = 'VALUATION'  -- book value as on @ToDate from the ledger (in at cost, out at average)
        SELECT s.StoreName AS [Store], i.ItemCode AS [Code], i.ItemName AS [Item], c.CategoryName AS [Category],
               SUM(g.QtyIn - g.QtyOut) AS [Qty], cu.UnitName AS [Unit], CAST(SUM(g.Value) AS DECIMAL(18,2)) AS [Book value]
        FROM dbo.InvStockLedger g JOIN dbo.InvStore s ON s.StoreId = g.StoreId JOIN dbo.InvItem i ON i.ItemId = g.ItemId
        JOIN dbo.InvItemCategory c ON c.CategoryId = i.CategoryId JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
        WHERE g.BranchId = @BranchId AND g.CompanyId = @CompanyId AND g.TxnOn < @to AND (@StoreId IS NULL OR g.StoreId = @StoreId)
          AND (@ItemId IS NULL OR g.ItemId = @ItemId) AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
        GROUP BY s.StoreName, i.ItemCode, i.ItemName, c.CategoryName, cu.UnitName
        HAVING SUM(g.QtyIn - g.QtyOut) <> 0 OR SUM(g.Value) <> 0
        ORDER BY s.StoreName, i.ItemName;

    ELSE IF @Report = 'MOVEMENT'   -- every movement in the period
        SELECT g.TxnOn AS [Date], dbo.ufn_Inv_DocTypeName(g.DocType) AS [Movement], g.DocNo AS [Document], s.StoreName AS [Store], i.ItemCode AS [Code], i.ItemName AS [Item],
               t.LotNo AS [Lot], g.QtyIn AS [In], g.QtyOut AS [Out], cu.UnitName AS [Unit], g.UnitCost AS [Unit cost], g.Value AS [Value], g.BalanceAfter AS [Lot balance],
               dbo.ufn_Inv_UserName(g.UserId) AS [By], g.Remarks AS [Remarks]
        FROM dbo.InvStockLedger g JOIN dbo.InvStore s ON s.StoreId = g.StoreId JOIN dbo.InvItem i ON i.ItemId = g.ItemId JOIN dbo.InvLot t ON t.LotId = g.LotId
        JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
        WHERE g.BranchId = @BranchId AND g.CompanyId = @CompanyId AND g.TxnOn >= @FromDate AND g.TxnOn < @to AND (@StoreId IS NULL OR g.StoreId = @StoreId)
          AND (@ItemId IS NULL OR g.ItemId = @ItemId) AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
        ORDER BY g.TxnOn, g.LedgerId;

    ELSE IF @Report = 'SUMMARY'    -- opening, in, out, closing per item for the period
        SELECT i.ItemCode AS [Code], i.ItemName AS [Item], cu.UnitName AS [Unit],
               SUM(CASE WHEN g.TxnOn < @FromDate THEN g.QtyIn - g.QtyOut ELSE 0 END) AS [Opening],
               SUM(CASE WHEN g.TxnOn >= @FromDate AND g.DocType IN ('GRN', 'OPN') THEN g.QtyIn ELSE 0 END) AS [Received],
               SUM(CASE WHEN g.TxnOn >= @FromDate AND g.DocType = 'ISSI' THEN g.QtyIn ELSE 0 END) AS [Transfer in],
               SUM(CASE WHEN g.TxnOn >= @FromDate AND g.DocType = 'ISSO' THEN g.QtyOut ELSE 0 END) AS [Transfer out],
               SUM(CASE WHEN g.TxnOn >= @FromDate AND g.DocType = 'CONS' THEN g.QtyOut ELSE 0 END) AS [Used by tests],
               SUM(CASE WHEN g.TxnOn >= @FromDate AND g.DocType IN ('ADJ', 'CNT') THEN g.QtyIn - g.QtyOut ELSE 0 END) AS [Adjusted],
               SUM(CASE WHEN g.TxnOn >= @FromDate AND g.DocType = 'PRET' THEN g.QtyOut ELSE 0 END) AS [Returned],
               SUM(g.QtyIn - g.QtyOut) AS [Closing],
               CAST(SUM(g.Value) AS DECIMAL(18,2)) AS [Closing value]
        FROM dbo.InvStockLedger g JOIN dbo.InvItem i ON i.ItemId = g.ItemId JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
        WHERE g.BranchId = @BranchId AND g.CompanyId = @CompanyId AND g.TxnOn < @to AND (@StoreId IS NULL OR g.StoreId = @StoreId)
          AND (@ItemId IS NULL OR g.ItemId = @ItemId) AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
        GROUP BY i.ItemCode, i.ItemName, cu.UnitName
        ORDER BY i.ItemName;

    ELSE IF @Report = 'EXPIRY'     -- expired and expiring within @Days (default: near-expiry setting)
        SELECT s.StoreName AS [Store], i.ItemName AS [Item], t.LotNo AS [Lot], t.ExpiryDate AS [Expiry], DATEDIFF(DAY, @today, t.ExpiryDate) AS [Days left],
               CASE WHEN t.ExpiryDate < @today THEN N'Expired' ELSE N'Expiring' END AS [State], b.Qty AS [Qty], cu.UnitName AS [Unit],
               CAST(ROUND(b.Qty * dbo.ufn_Qc_ItemUnitCost(i.ItemId), 2) AS DECIMAL(18,2)) AS [Value], sp.SupplierName AS [Supplier]
        FROM dbo.InvStockBalance b JOIN dbo.InvStore s ON s.StoreId = b.StoreId JOIN dbo.InvItem i ON i.ItemId = b.ItemId JOIN dbo.InvLot t ON t.LotId = b.LotId
        JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId LEFT JOIN dbo.InvSupplier sp ON sp.SupplierId = t.SupplierId
        WHERE s.BranchId = @BranchId AND s.CompanyId = @CompanyId AND b.Qty > 0 AND t.ExpiryDate IS NOT NULL
          AND DATEDIFF(DAY, @today, t.ExpiryDate) <= ISNULL(@Days, (SELECT NearExpiryDays FROM dbo.ufn_Inv_Settings(@CompanyId)))
          AND (@StoreId IS NULL OR b.StoreId = @StoreId) AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
        ORDER BY t.ExpiryDate, i.ItemName;

    ELSE IF @Report = 'PURCHASE'   -- purchase register (posted goods receipts, line-wise, with GST)
        SELECT d.DocDate AS [GRN date], d.DocNo AS [GRN no], sp.SupplierName AS [Supplier], sp.Gstin AS [GSTIN], d.SupplierInvNo AS [Bill no], d.SupplierInvDate AS [Bill date],
               i.ItemName AS [Item], i.HsnCode AS [HSN], l.LotNo AS [Lot], l.ExpiryDate AS [Expiry], l.Qty AS [Qty], l.FreeQty AS [Free], l.Rate AS [Rate],
               l.DiscountAmount AS [Discount], l.TaxableAmount AS [Taxable], l.GstPct AS [GST %],
               CASE WHEN d.IsInterState = 1 THEN 0 ELSE CAST(l.GstAmount / 2 AS DECIMAL(18,2)) END AS [CGST],
               CASE WHEN d.IsInterState = 1 THEN 0 ELSE l.GstAmount - CAST(l.GstAmount / 2 AS DECIMAL(18,2)) END AS [SGST],
               CASE WHEN d.IsInterState = 1 THEN l.GstAmount ELSE 0 END AS [IGST], l.LineAmount AS [Amount], d.VoucherNo AS [Voucher]
        FROM dbo.InvDoc d JOIN dbo.InvDocLine l ON l.DocId = d.DocId JOIN dbo.InvItem i ON i.ItemId = l.ItemId JOIN dbo.InvSupplier sp ON sp.SupplierId = d.SupplierId
        WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId AND d.DocType = 'GRN' AND d.Status = 'POSTED' AND d.DocDate BETWEEN @FromDate AND @ToDate
          AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId) AND (@ItemId IS NULL OR l.ItemId = @ItemId) AND (@StoreId IS NULL OR d.StoreId = @StoreId)
        ORDER BY d.DocDate, d.DocNo, l.SeqNo;

    ELSE IF @Report = 'SUPPLIER'   -- purchases and returns by supplier
        SELECT sp.SupplierName AS [Supplier], sp.Gstin AS [GSTIN],
               SUM(CASE WHEN d.DocType = 'GRN' THEN 1 ELSE 0 END) AS [Receipts], CAST(SUM(CASE WHEN d.DocType = 'GRN' THEN d.TaxableAmount ELSE 0 END) AS DECIMAL(18,2)) AS [Taxable],
               CAST(SUM(CASE WHEN d.DocType = 'GRN' THEN d.GstAmount ELSE 0 END) AS DECIMAL(18,2)) AS [GST],
               CAST(SUM(CASE WHEN d.DocType = 'GRN' THEN d.NetAmount ELSE 0 END) AS DECIMAL(18,2)) AS [Purchases],
               CAST(SUM(CASE WHEN d.DocType = 'PRET' THEN d.NetAmount ELSE 0 END) AS DECIMAL(18,2)) AS [Returns],
               CAST(SUM(CASE WHEN d.DocType = 'GRN' THEN d.NetAmount ELSE -d.NetAmount END) AS DECIMAL(18,2)) AS [Net],
               (SELECT COUNT(1) FROM dbo.InvLot t WHERE t.SupplierId = sp.SupplierId AND t.Status = 'REJECTED' AND t.CreatedOn >= @FromDate AND t.CreatedOn < @to) AS [Lots rejected]
        FROM dbo.InvDoc d JOIN dbo.InvSupplier sp ON sp.SupplierId = d.SupplierId
        WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId AND d.DocType IN ('GRN', 'PRET') AND d.Status = 'POSTED' AND d.DocDate BETWEEN @FromDate AND @ToDate
          AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
        GROUP BY sp.SupplierId, sp.SupplierName, sp.Gstin ORDER BY [Net] DESC;

    ELSE IF @Report = 'PO'         -- purchase order status, line-wise
        SELECT d.DocDate AS [PO date], d.DocNo AS [PO no], d.Status AS [Status], sp.SupplierName AS [Supplier], d.ExpectedDate AS [Expected], i.ItemName AS [Item],
               l.Qty AS [Ordered], CAST(l.DoneBaseQty / NULLIF(l.Factor, 0) AS DECIMAL(18,3)) AS [Received],
               CAST(CASE WHEN l.BaseQty > l.DoneBaseQty THEN (l.BaseQty - l.DoneBaseQty) / NULLIF(l.Factor, 0) ELSE 0 END AS DECIMAL(18,3)) AS [Pending], pu.UnitName AS [Unit],
               l.Rate AS [Rate], l.LineAmount AS [Amount]
        FROM dbo.InvDoc d JOIN dbo.InvDocLine l ON l.DocId = d.DocId JOIN dbo.InvItem i ON i.ItemId = l.ItemId JOIN dbo.InvUnit pu ON pu.UnitId = i.PurchaseUnitId
        JOIN dbo.InvSupplier sp ON sp.SupplierId = d.SupplierId
        WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId AND d.DocType = 'PO' AND d.Status <> 'CANCELLED' AND d.DocDate BETWEEN @FromDate AND @ToDate
          AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId) AND (@ItemId IS NULL OR l.ItemId = @ItemId)
        ORDER BY d.DocDate, d.DocNo, l.SeqNo;

    ELSE IF @Report = 'ISSUE'      -- issues / transfers sent and received
        SELECT d.DocDate AS [Date], d.DocNo AS [Issue no], d.Status AS [Status], s.StoreName AS [From store], ts.StoreName AS [To store], tb.BranchName AS [To branch],
               r.DocNo AS [Indent], i.ItemName AS [Item], l.LotNo AS [Lot], l.BaseQty AS [Sent], CASE WHEN d.Status = 'RECEIVED' THEN l.DoneBaseQty END AS [Received],
               cu.UnitName AS [Unit], CAST(ROUND(l.BaseQty * ISNULL(l.UnitCost, 0), 2) AS DECIMAL(18,2)) AS [Value], d.PostedOn AS [Dispatched on], d.ReceivedOn AS [Received on]
        FROM dbo.InvDoc d JOIN dbo.InvDocLine l ON l.DocId = d.DocId JOIN dbo.InvItem i ON i.ItemId = l.ItemId JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
        JOIN dbo.InvStore s ON s.StoreId = d.StoreId JOIN dbo.InvStore ts ON ts.StoreId = d.ToStoreId LEFT JOIN dbo.Branchmaster tb ON tb.BranchID = ts.BranchId
        LEFT JOIN dbo.InvDoc r ON r.DocId = d.RefDocId
        WHERE d.CompanyId = @CompanyId AND (d.BranchId = @BranchId OR ts.BranchId = @BranchId) AND d.DocType = 'ISS' AND d.Status IN ('INTRANSIT', 'RECEIVED')
          AND d.DocDate BETWEEN @FromDate AND @ToDate AND (@StoreId IS NULL OR d.StoreId = @StoreId OR d.ToStoreId = @StoreId) AND (@ItemId IS NULL OR l.ItemId = @ItemId)
        ORDER BY d.DocDate, d.DocNo, l.SeqNo;

    ELSE IF @Report = 'ADJUST'     -- adjustments, write-offs and count differences
        SELECT d.DocDate AS [Date], d.DocNo AS [Document], dbo.ufn_Inv_DocTypeName(d.DocType) AS [Type], ISNULL(ar.ReasonName, N'Count difference') AS [Reason],
               s.StoreName AS [Store], i.ItemName AS [Item], l.LotNo AS [Lot],
               CASE WHEN d.DocType = 'CNT' THEN l.CountedBaseQty - ISNULL(l.SystemBaseQty, 0) ELSE l.Sign * l.BaseQty END AS [Qty (+ in / - out)], cu.UnitName AS [Unit],
               g.Value AS [Value], dbo.ufn_Inv_UserName(d.CreatedBy) AS [Raised by], dbo.ufn_Inv_UserName(d.ApprovedBy) AS [Approved by], l.Remarks AS [Remarks]
        FROM dbo.InvDoc d JOIN dbo.InvDocLine l ON l.DocId = d.DocId JOIN dbo.InvItem i ON i.ItemId = l.ItemId JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
        JOIN dbo.InvStore s ON s.StoreId = d.StoreId LEFT JOIN dbo.InvAdjReason ar ON ar.ReasonCode = d.ReasonCode
        LEFT JOIN dbo.InvStockLedger g ON g.DocType = d.DocType AND g.DocId = d.DocId AND g.DocLineId = l.LineId
        WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId AND d.DocType IN ('ADJ', 'CNT') AND d.Status = 'POSTED' AND d.DocDate BETWEEN @FromDate AND @ToDate
          AND (d.DocType = 'ADJ' OR (l.CountedBaseQty IS NOT NULL AND l.CountedBaseQty <> ISNULL(l.SystemBaseQty, 0)))
          AND (@StoreId IS NULL OR d.StoreId = @StoreId) AND (@ItemId IS NULL OR l.ItemId = @ItemId)
        ORDER BY d.DocDate, d.DocNo, l.SeqNo;

    ELSE IF @Report = 'CONSUMPTION' -- item use by tests (from stock) and QC / calibration in the period
        SELECT i.ItemCode AS [Code], i.ItemName AS [Item], s.StoreName AS [Store], cu.UnitName AS [Unit],
               SUM(CASE WHEN g.DocType = 'CONS' THEN g.QtyOut ELSE 0 END) AS [Used by tests],
               COUNT(DISTINCT CASE WHEN g.DocType = 'CONS' THEN g.DocId END) AS [Test runs],
               SUM(CASE WHEN g.DocType = 'ADJ' AND r.IsUsage = 1 THEN g.QtyOut ELSE 0 END) AS [QC / calibration use],
               SUM(CASE WHEN g.DocType = 'ADJ' AND r.IsUsage = 0 THEN g.QtyOut ELSE 0 END) AS [Written off],
               CAST(-SUM(g.Value) AS DECIMAL(18,2)) AS [Value]
        FROM dbo.InvStockLedger g JOIN dbo.InvItem i ON i.ItemId = g.ItemId JOIN dbo.InvStore s ON s.StoreId = g.StoreId JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
        LEFT JOIN dbo.InvDoc d ON d.DocId = g.DocId AND g.DocType = 'ADJ' LEFT JOIN dbo.InvAdjReason r ON r.ReasonCode = d.ReasonCode
        WHERE g.BranchId = @BranchId AND g.CompanyId = @CompanyId AND g.TxnOn >= @FromDate AND g.TxnOn < @to AND (g.DocType = 'CONS' OR (g.DocType = 'ADJ' AND g.QtyOut > 0))
          AND (@StoreId IS NULL OR g.StoreId = @StoreId) AND (@ItemId IS NULL OR g.ItemId = @ItemId) AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
        GROUP BY i.ItemCode, i.ItemName, s.StoreName, cu.UnitName
        ORDER BY [Value] DESC;

    ELSE IF @Report = 'TRACE'      -- lot traceability: receipt, every movement and the bills whose tests used it (@Search = lot no)
        SELECT g.TxnOn AS [Date], dbo.ufn_Inv_DocTypeName(g.DocType) AS [Movement], g.DocNo AS [Document / bill], s.StoreName AS [Store], i.ItemName AS [Item], t.LotNo AS [Lot],
               t.ExpiryDate AS [Expiry], t.Status AS [Lot status], g.QtyIn AS [In], g.QtyOut AS [Out], cu.UnitName AS [Unit],
               CASE WHEN g.DocType = 'CONS' THEN m.Test_Name END AS [Test],
               CASE WHEN g.DocType = 'CONS' THEN LTRIM(RTRIM(ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))) END AS [Patient],
               CASE WHEN g.DocType = 'CONS' THEN pm.PatientCode END AS [Patient code]
        FROM dbo.InvStockLedger g JOIN dbo.InvLot t ON t.LotId = g.LotId JOIN dbo.InvItem i ON i.ItemId = g.ItemId JOIN dbo.InvStore s ON s.StoreId = g.StoreId
        JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
        LEFT JOIN dbo.QcConsumption c ON g.DocType = 'CONS' AND c.ConsumptionId = g.DocId
        LEFT JOIN dbo.LabInvestigationMaster m ON m.Test_ID = c.TestId
        LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = c.LabOrderId LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = lo.PatientId
        WHERE g.CompanyId = @CompanyId AND (@Search IS NOT NULL OR @ItemId IS NOT NULL)
          AND (@Search IS NULL OR t.LotNo = @Search OR t.LotNo LIKE @Search + '%') AND (@ItemId IS NULL OR g.ItemId = @ItemId)
          AND g.TxnOn >= @FromDate AND g.TxnOn < @to
        ORDER BY t.LotNo, g.TxnOn, g.LedgerId;

    ELSE IF @Report = 'FSN'        -- fast / slow / non-moving items over the last @Days (default 90) days
    BEGIN
        DECLARE @d INT = ISNULL(@Days, 90);
        ;WITH M AS (
            SELECT i.ItemId, i.ItemCode, i.ItemName, cu.UnitName,
                   ISNULL((SELECT SUM(b.Qty) FROM dbo.InvStockBalance b JOIN dbo.InvStore s ON s.StoreId = b.StoreId WHERE b.ItemId = i.ItemId AND s.BranchId = @BranchId), 0) AS Stock,
                   ISNULL((SELECT SUM(g.QtyOut) FROM dbo.InvStockLedger g WHERE g.ItemId = i.ItemId AND g.BranchId = @BranchId AND g.DocType IN ('CONS', 'ADJ', 'ISSO')
                           AND g.TxnOn >= DATEADD(DAY, -@d, @today)), 0) AS UsedQty,
                   (SELECT MAX(g.TxnOn) FROM dbo.InvStockLedger g WHERE g.ItemId = i.ItemId AND g.BranchId = @BranchId AND g.QtyOut > 0) AS LastOut
            FROM dbo.InvItem i JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
            WHERE i.CompanyId = @CompanyId AND i.IsDeleted = 0 AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId))
        SELECT ItemCode AS [Code], ItemName AS [Item], UnitName AS [Unit], Stock AS [Stock], UsedQty AS [Used in period], LastOut AS [Last used],
               CASE WHEN UsedQty = 0 THEN N'N - non-moving' WHEN Stock > 0 AND UsedQty / NULLIF(Stock, 0) < 0.5 THEN N'S - slow' ELSE N'F - fast' END AS [Class],
               CAST(ROUND(Stock * dbo.ufn_Qc_ItemUnitCost(ItemId), 2) AS DECIMAL(18,2)) AS [Stock value]
        FROM M WHERE Stock > 0 OR UsedQty > 0
        ORDER BY CASE WHEN UsedQty = 0 THEN 2 WHEN Stock > 0 AND UsedQty / NULLIF(Stock, 0) < 0.5 THEN 1 ELSE 0 END DESC, [Stock value] DESC;
    END
    ELSE
        THROW 53699, 'Unknown report.', 1;
END;
GO

PRINT 'Script 2499 applied: Quality & Compliance stock management API procedures.';
GO
