-- ============================================================================================================
-- 2403  Pharmacy: Auto Reorder (sales-based, parametric) and Supplier Schemes / free goods (after 2402).
--   * PhSupplierScheme: "buy X get Y free" per item, for one supplier or any supplier, with validity dates.
--     fn_PhSchemeFree gives the free quantity for an order quantity (supplier-specific scheme wins).
--     Master > Pharmacy > Supplier Scheme (generic master: usp_Api_PhSupplierScheme_GetList / _Save).
--   * Auto Reorder (Pharmacy > Purchase > Auto Reorder, page PHARMACY.AUTOREORDER, VIEW + CREATEPO):
--       avg daily sale  = (sales - sale returns) of the last PharmacyReorderSalesDays days, in packs
--       reorder point   = avg x (lead days + safety days), never below the item's reorder level
--       order up to     = avg x (lead days + safety days + cover days), never below the reorder level
--                         (no recent sale: up to Max Qty when set),
--                         capped at Max Qty when one is set
--       suggested qty   = order up to - (stock + pending PO), rounded up to whole packs, only when
--                         stock + pending PO <= reorder point
--     Supplier and rate come from the last posted GRN of the item (editable on the page). "Create POs"
--     makes one DRAFT purchase order per supplier (normal approval flow; GST, inter-state and schemes applied).
--     Works only when Hospital Settings > MED > Auto Reorder is on for the branch.
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.PhSupplierScheme') IS NULL
CREATE TABLE dbo.PhSupplierScheme (
    SupplierSchemeId INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId    INT NOT NULL,
    SupplierId   INT NULL REFERENCES dbo.PhSupplier (SupplierId),   -- NULL = any supplier
    ItemId       INT NOT NULL REFERENCES dbo.PhItem (ItemId),
    BuyQty       DECIMAL(12,2) NOT NULL,                             -- packs billed
    FreeQty      DECIMAL(12,2) NOT NULL,                             -- packs free for every BuyQty
    ValidFrom    DATE NOT NULL,
    ValidTo      DATE NULL,
    Remarks      NVARCHAR(200) NULL,
    IsActive     BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT CK_PhSupplierScheme_Qty CHECK (BuyQty > 0 AND FreeQty > 0)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhSupplierScheme_Item')
    CREATE INDEX IX_PhSupplierScheme_Item ON dbo.PhSupplierScheme (CompanyId, ItemId, IsActive) INCLUDE (SupplierId, BuyQty, FreeQty, ValidFrom, ValidTo);
GO

-- free packs for an order of @Qty packs on @OnDate (supplier-specific scheme first, then "any supplier")
CREATE OR ALTER FUNCTION dbo.fn_PhSchemeFree (@CompanyId INT, @SupplierId INT, @ItemId INT, @Qty DECIMAL(12,2), @OnDate DATE)
RETURNS TABLE
AS
RETURN
    SELECT TOP 1 s.SupplierSchemeId, s.BuyQty, s.FreeQty AS SchemeFree,
           CAST(FLOOR(@Qty / s.BuyQty) * s.FreeQty AS DECIMAL(12,2)) AS FreeQty,
           CAST(CAST(s.BuyQty AS DECIMAL(12,0)) AS NVARCHAR(12)) + N' + ' + CAST(CAST(s.FreeQty AS DECIMAL(12,0)) AS NVARCHAR(12)) AS SchemeText
      FROM dbo.PhSupplierScheme s
     WHERE s.CompanyId = @CompanyId AND s.ItemId = @ItemId AND s.IsActive = 1
       AND (s.SupplierId = @SupplierId OR s.SupplierId IS NULL)
       AND s.ValidFrom <= @OnDate AND (s.ValidTo IS NULL OR s.ValidTo >= @OnDate)
     ORDER BY CASE WHEN s.SupplierId IS NULL THEN 1 ELSE 0 END, s.ValidFrom DESC;
GO

-- ── Supplier Scheme master (generic pharmacy master) ──────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupplierScheme_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.SupplierSchemeId, s.ItemId, s.SupplierId, s.BuyQty, s.FreeQty, s.ValidFrom, s.ValidTo, s.Remarks, s.IsActive
      FROM dbo.PhSupplierScheme s JOIN dbo.PhItem i ON i.ItemId = s.ItemId
     WHERE s.CompanyId = @CompanyId
     ORDER BY i.ItemName, s.ValidFrom DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupplierScheme_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @ItemId INT = NULL, @SupplierId INT = NULL, @BuyQty DECIMAL(12,2) = NULL, @FreeQty DECIMAL(12,2) = NULL,
    @ValidFrom DATE = NULL, @ValidTo DATE = NULL, @Remarks NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhItem WHERE ItemId = @ItemId AND CompanyId = @CompanyId)
    BEGIN SELECT 0 AS Id, N'Pick the item.' AS Error; RETURN; END;
    IF @SupplierId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhSupplier WHERE SupplierId = @SupplierId AND CompanyId = @CompanyId)
    BEGIN SELECT 0 AS Id, N'Supplier not found.' AS Error; RETURN; END;
    IF ISNULL(@BuyQty, 0) <= 0 OR ISNULL(@FreeQty, 0) <= 0
    BEGIN SELECT 0 AS Id, N'Buy and free quantity must both be more than zero (e.g. 10 + 1).' AS Error; RETURN; END;
    IF @FreeQty > @BuyQty
    BEGIN SELECT 0 AS Id, N'Free quantity cannot be more than the quantity bought.' AS Error; RETURN; END;
    SET @ValidFrom = ISNULL(@ValidFrom, CAST(GETDATE() AS DATE));
    IF @ValidTo IS NOT NULL AND @ValidTo < @ValidFrom
    BEGIN SELECT 0 AS Id, N'Valid to is before valid from.' AS Error; RETURN; END;
    -- one running scheme per item and supplier at a time
    IF @IsActive = 1 AND EXISTS (SELECT 1 FROM dbo.PhSupplierScheme o
                                  WHERE o.CompanyId = @CompanyId AND o.ItemId = @ItemId AND o.IsActive = 1 AND o.SupplierSchemeId <> ISNULL(@Id, 0)
                                    AND ISNULL(o.SupplierId, 0) = ISNULL(@SupplierId, 0)
                                    AND o.ValidFrom <= ISNULL(@ValidTo, '9999-12-31') AND ISNULL(o.ValidTo, '9999-12-31') >= @ValidFrom)
    BEGIN SELECT 0 AS Id, N'This item already has a scheme from this supplier for overlapping dates. Close that one first (set its Valid to).' AS Error; RETURN; END;

    BEGIN TRAN;
    IF ISNULL(@Id, 0) = 0
    BEGIN
        INSERT dbo.PhSupplierScheme (CompanyId, SupplierId, ItemId, BuyQty, FreeQty, ValidFrom, ValidTo, Remarks, IsActive, CreatedBy)
        VALUES (@CompanyId, @SupplierId, @ItemId, @BuyQty, @FreeQty, @ValidFrom, @ValidTo, @Remarks, @IsActive, @UserId);
        SET @Id = CAST(SCOPE_IDENTITY() AS INT);
    END
    ELSE
    BEGIN
        UPDATE dbo.PhSupplierScheme SET SupplierId = @SupplierId, ItemId = @ItemId, BuyQty = @BuyQty, FreeQty = @FreeQty, ValidFrom = @ValidFrom,
               ValidTo = @ValidTo, Remarks = @Remarks, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE SupplierSchemeId = @Id AND CompanyId = @CompanyId;
        IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
    END
    COMMIT;
    SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
END
GO

-- lookups of the simple masters: 1 states, 2 main categories, 3 categories, 4 discount schemes, 5 suppliers, 6 items
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhMaster_Lookups
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(StateId AS VARCHAR(10)) AS Value, StateName AS Text FROM dbo.StateMaster WHERE IsActive = 1 ORDER BY StateName;
    SELECT CAST(CategoryId AS VARCHAR(10)) AS Value, CategoryName AS Text FROM dbo.PhCategory WHERE CompanyId = @CompanyId AND ParentCategoryId IS NULL ORDER BY SortOrder, CategoryName;
    SELECT CAST(c.CategoryId AS VARCHAR(10)) AS Value, CASE WHEN p.CategoryId IS NULL THEN c.CategoryName ELSE p.CategoryName + N' › ' + c.CategoryName END AS Text
      FROM dbo.PhCategory c LEFT JOIN dbo.PhCategory p ON p.CategoryId = c.ParentCategoryId
     WHERE c.CompanyId = @CompanyId AND c.IsActive = 1 ORDER BY ISNULL(p.SortOrder, c.SortOrder), ISNULL(p.CategoryName, c.CategoryName), c.ParentCategoryId, c.SortOrder;
    SELECT CAST(SchemeId AS VARCHAR(10)) AS Value, SchemeName AS Text FROM dbo.PhDiscountScheme WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY SchemeName;
    SELECT CAST(SupplierId AS VARCHAR(10)) AS Value, SupplierName AS Text FROM dbo.PhSupplier WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY SupplierName;
    SELECT CAST(i.ItemId AS VARCHAR(10)) AS Value, i.ItemName + ISNULL(N' · ' + i.PackSize, N'') + N' (' + i.ItemCode + N')' AS Text
      FROM dbo.PhItem i WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 ORDER BY i.ItemName;
END
GO

-- free quantity for a purchase line (PO / GRN forms)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_SchemeFree @CompanyId INT, @BranchId INT, @SupplierId INT, @ItemId INT, @Qty DECIMAL(12,2), @OnDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @on DATE = ISNULL(@OnDate, CAST(GETDATE() AS DATE));
    IF ISNULL((SELECT TOP 1 PharmacySchemeAutoApply FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0) = 0
    BEGIN SELECT CAST(0 AS DECIMAL(12,2)) AS FreeQty, CAST(NULL AS NVARCHAR(30)) AS SchemeText, CAST(0 AS BIT) AS AutoApply; RETURN; END;
    SELECT ISNULL(f.FreeQty, 0) AS FreeQty, f.SchemeText, CAST(1 AS BIT) AS AutoApply
      FROM (SELECT 1 x) one OUTER APPLY dbo.fn_PhSchemeFree(@CompanyId, @SupplierId, @ItemId, ISNULL(@Qty, 0), @on) f;
END
GO

-- ── Auto Reorder ────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhReorder_Suggest
    @CompanyId INT, @BranchId INT, @SupplierId INT = NULL, @CategoryId INT = NULL, @ShowAll BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @on BIT, @days INT, @safety INT, @cover INT, @grnNotReq BIT;
    SELECT TOP 1 @on = PharmacyAutoReorderEnabled, @days = PharmacyReorderSalesDays, @safety = PharmacyReorderSafetyDays,
                 @cover = PharmacyReorderCoverDays, @grnNotReq = PharmacyGrnNotRequired
      FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;

    -- 1: the parameters in force
    SELECT ISNULL(@on, 0) AS Enabled, ISNULL(@days, 30) AS SalesDays, ISNULL(@safety, 3) AS SafetyDays, ISNULL(@cover, 15) AS CoverDays,
           ISNULL(@grnNotReq, 0) AS GrnNotRequired;
    IF ISNULL(@on, 0) = 0 RETURN;

    DECLARE @from DATETIME = DATEADD(DAY, -@days, CAST(GETDATE() AS DATE));

    ;WITH sold AS (
        SELECT l.ItemId, SUM(CASE WHEN l.DocType = 'SALE' THEN l.QtyOut WHEN l.DocType = 'SRET' THEN -l.QtyIn ELSE 0 END) AS SoldUnits
          FROM dbo.PhStockLedger l
         WHERE l.BranchId = @BranchId AND l.TxnDate >= @from AND l.DocType IN ('SALE', 'SRET')
         GROUP BY l.ItemId
    ), base AS (
        SELECT f.ItemId, f.ItemCode, f.ItemName, f.FormShort, f.Strength, f.PackSize, f.GenericName, f.ManufacturerName, f.PurchaseUom, f.ConversionQty,
               f.GstPercent, f.ReorderLevel, f.MaxQty, f.PendingPoQty, f.LastRate, f.LastMrp,
               CAST(f.Stock / f.ConversionQty AS DECIMAL(14,2)) AS StockPacks,
               CAST(CASE WHEN ISNULL(s.SoldUnits, 0) < 0 THEN 0 ELSE ISNULL(s.SoldUnits, 0) END / f.ConversionQty / @days AS DECIMAL(14,4)) AS AvgDaily,
               i.LeadDays, i.CategoryId, c.ParentCategoryId
          FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f
          JOIN dbo.PhItem i ON i.ItemId = f.ItemId
          JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
          LEFT JOIN sold s ON s.ItemId = f.ItemId
         WHERE f.IsActive = 1 AND f.IsStocked = 1
           AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
    ), calc AS (
        SELECT b.*,
               CAST(CASE WHEN b.AvgDaily * (b.LeadDays + @safety) > b.ReorderLevel THEN b.AvgDaily * (b.LeadDays + @safety) ELSE b.ReorderLevel END AS DECIMAL(14,2)) AS ReorderPoint,
               -- no recent sale: plain min-max (up to Max Qty when set, else the reorder level)
               CAST(CASE WHEN b.AvgDaily * (b.LeadDays + @safety + @cover) > x.Floor THEN b.AvgDaily * (b.LeadDays + @safety + @cover) ELSE x.Floor END AS DECIMAL(14,2)) AS OrderUpTo
          FROM base b
          CROSS APPLY (SELECT CASE WHEN b.AvgDaily = 0 AND b.MaxQty > b.ReorderLevel THEN b.MaxQty ELSE b.ReorderLevel END AS Floor) x
    ), sug AS (
        SELECT c.*,
               CAST(CASE WHEN c.MaxQty > 0 AND c.OrderUpTo > c.MaxQty THEN c.MaxQty ELSE c.OrderUpTo END AS DECIMAL(14,2)) AS Target
          FROM calc c
    ), fin AS (
        SELECT s.*,
               CAST(CASE WHEN s.StockPacks + s.PendingPoQty <= s.ReorderPoint AND s.Target - s.StockPacks - s.PendingPoQty > 0
                         THEN CEILING(s.Target - s.StockPacks - s.PendingPoQty) ELSE 0 END AS DECIMAL(12,2)) AS SuggestedQty,
               CAST(CASE WHEN s.AvgDaily > 0 THEN s.StockPacks / s.AvgDaily END AS DECIMAL(10,1)) AS DaysOfStock
          FROM sug s
    )
    -- 2: the suggestions
    SELECT f.ItemId, f.ItemCode, f.ItemName, f.FormShort, f.Strength, f.PackSize, f.GenericName, f.ManufacturerName, f.PurchaseUom, f.ConversionQty,
           f.GstPercent, f.StockPacks, f.PendingPoQty, f.AvgDaily, f.DaysOfStock, f.LeadDays, f.ReorderLevel, f.MaxQty, f.ReorderPoint, f.Target AS OrderUpTo,
           f.SuggestedQty, f.LastMrp,
           ls.SupplierId, ls.SupplierName, ISNULL(ls.Rate, f.LastRate) AS Rate, ISNULL(ls.DiscPercent, 0) AS DiscPercent,
           ISNULL(sf.FreeQty, 0) AS FreeQty, sf.SchemeText
      FROM fin f
      OUTER APPLY (SELECT TOP 1 gr.SupplierId, sp.SupplierName, d.Rate, d.DiscPercent
                     FROM dbo.PhGrnDtl d JOIN dbo.PhGrn gr ON gr.GrnId = d.GrnId JOIN dbo.PhSupplier sp ON sp.SupplierId = gr.SupplierId
                    WHERE d.ItemId = f.ItemId AND gr.Status = 'POSTED' AND gr.CompanyId = @CompanyId AND sp.IsActive = 1
                    ORDER BY gr.PostedDate DESC, gr.GrnId DESC) ls
      OUTER APPLY dbo.fn_PhSchemeFree(@CompanyId, ls.SupplierId, f.ItemId, f.SuggestedQty, CAST(GETDATE() AS DATE)) sf
     WHERE (@ShowAll = 1 OR f.SuggestedQty > 0)
       AND (@SupplierId IS NULL OR ls.SupplierId = @SupplierId)
     ORDER BY CASE WHEN f.SuggestedQty > 0 THEN 0 ELSE 1 END, ls.SupplierName, f.ItemName;
END
GO

-- One DRAFT purchase order per supplier from the chosen suggestion lines.
-- @Lines: [{ "ItemId":1, "SupplierId":2, "Qty":10, "Rate":45.5, "DiscPercent":0 }]
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhReorder_CreatePos
    @CompanyId INT, @BranchId INT, @UserId INT, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @on BIT, @direct BIT, @schemes BIT, @today DATE = CAST(GETDATE() AS DATE);
    SELECT TOP 1 @on = PharmacyAutoReorderEnabled, @direct = PharmacyGrnNotRequired, @schemes = PharmacySchemeAutoApply
      FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
    IF ISNULL(@on, 0) = 0 BEGIN SELECT CAST(0 AS INT) AS PoId, N'Auto Reorder is off for this branch (Hospital Settings > MED).' AS Error; RETURN; END;

    DECLARE @l TABLE (ItemId INT, SupplierId INT, Qty DECIMAL(12,2), Rate DECIMAL(12,4), DiscPercent DECIMAL(5,2));
    INSERT @l SELECT ItemId, SupplierId, Qty, Rate, ISNULL(DiscPercent, 0)
      FROM OPENJSON(@Lines) WITH (ItemId INT, SupplierId INT, Qty DECIMAL(12,2), Rate DECIMAL(12,4), DiscPercent DECIMAL(5,2));

    IF NOT EXISTS (SELECT 1 FROM @l) BEGIN SELECT 0 AS PoId, N'Tick at least one item.' AS Error; RETURN; END;
    IF EXISTS (SELECT 1 FROM @l WHERE ISNULL(SupplierId, 0) = 0) BEGIN SELECT 0 AS PoId, N'Every ticked item needs a supplier.' AS Error; RETURN; END;
    IF EXISTS (SELECT 1 FROM @l WHERE ISNULL(Qty, 0) <= 0) BEGIN SELECT 0 AS PoId, N'Every ticked item needs a quantity above zero.' AS Error; RETURN; END;
    IF EXISTS (SELECT 1 FROM @l WHERE ISNULL(Rate, 0) <= 0) BEGIN SELECT 0 AS PoId, N'Every ticked item needs a rate (no earlier purchase was found for some).' AS Error; RETURN; END;
    IF EXISTS (SELECT 1 FROM @l WHERE DiscPercent < 0 OR DiscPercent > 100) BEGIN SELECT 0 AS PoId, N'Discount % must be between 0 and 100.' AS Error; RETURN; END;
    IF EXISTS (SELECT ItemId FROM @l GROUP BY ItemId HAVING COUNT(*) > 1) BEGIN SELECT 0 AS PoId, N'An item is ticked twice.' AS Error; RETURN; END;
    IF EXISTS (SELECT 1 FROM @l l LEFT JOIN dbo.PhItem i ON i.ItemId = l.ItemId AND i.CompanyId = @CompanyId AND i.IsActive = 1 WHERE i.ItemId IS NULL)
    BEGIN SELECT 0 AS PoId, N'An item is not active any more.' AS Error; RETURN; END;
    IF EXISTS (SELECT 1 FROM @l l LEFT JOIN dbo.PhSupplier s ON s.SupplierId = l.SupplierId AND s.CompanyId = @CompanyId AND s.IsActive = 1 WHERE s.SupplierId IS NULL)
    BEGIN SELECT 0 AS PoId, N'A supplier is not active any more.' AS Error; RETURN; END;
    IF EXISTS (SELECT 1 FROM @l l JOIN dbo.PhSupplier s ON s.SupplierId = l.SupplierId WHERE s.DrugLicenceValidTo IS NOT NULL AND s.DrugLicenceValidTo < @today)
    BEGIN
        SELECT TOP 1 0 AS PoId, N'Drug licence of ' + s.SupplierName + N' expired on ' + CONVERT(NVARCHAR(11), s.DrugLicenceValidTo, 106) + N'.' AS Error
          FROM @l l JOIN dbo.PhSupplier s ON s.SupplierId = l.SupplierId WHERE s.DrugLicenceValidTo < @today;
        RETURN;
    END;

    -- priced lines
    DECLARE @p TABLE (ItemId INT, SupplierId INT, Qty DECIMAL(12,2), FreeQty DECIMAL(12,2), Rate DECIMAL(12,4), DiscPercent DECIMAL(5,2), GstPercent DECIMAL(5,2),
                      TaxableAmount DECIMAL(14,2), GstAmount DECIMAL(14,2));
    INSERT @p
    SELECT l.ItemId, l.SupplierId, l.Qty, CASE WHEN ISNULL(@schemes, 0) = 1 THEN ISNULL(sf.FreeQty, 0) ELSE 0 END, l.Rate, l.DiscPercent, h.GstPercent,
           ROUND(l.Qty * l.Rate * (1 - l.DiscPercent / 100), 2), 0
      FROM @l l JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.PhHsn h ON h.HsnId = i.HsnId
      OUTER APPLY dbo.fn_PhSchemeFree(@CompanyId, l.SupplierId, l.ItemId, l.Qty, @today) sf;
    UPDATE @p SET GstAmount = ROUND(TaxableAmount * GstPercent / 100, 2);

    DECLARE @out TABLE (PoId INT, SupplierName NVARCHAR(150), Lines INT, NetAmount DECIMAL(14,2));
    DECLARE @sup INT, @po INT, @inter BIT, @tax DECIMAL(14,2), @gst DECIMAL(14,2);
    BEGIN TRAN;
    DECLARE sc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT SupplierId FROM @p;
    OPEN sc; FETCH NEXT FROM sc INTO @sup;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @inter = CAST(CASE
                    WHEN LEN(s.Gstin) >= 2 AND LEN(bg.Gstin) >= 2 THEN CASE WHEN LEFT(s.Gstin, 2) <> LEFT(bg.Gstin, 2) THEN 1 ELSE 0 END
                    WHEN st.StateName IS NOT NULL AND b.State IS NOT NULL THEN CASE WHEN st.StateName <> b.State THEN 1 ELSE 0 END
                    ELSE 0 END AS BIT)
          FROM dbo.PhSupplier s
          LEFT JOIN dbo.StateMaster st ON st.StateId = s.StateId
          CROSS JOIN (SELECT State FROM dbo.BranchMaster WHERE BranchID = @BranchId) b
          OUTER APPLY (SELECT TOP 1 NULLIF(ISNULL(NULLIF(PharmacyGstin, ''), GSTCode), '') AS Gstin FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC) bg
         WHERE s.SupplierId = @sup;
        SELECT @tax = SUM(TaxableAmount), @gst = SUM(GstAmount) FROM @p WHERE SupplierId = @sup;

        INSERT dbo.PhPurchaseOrder (CompanyId, BranchId, PoDate, SupplierId, ExpectedDate, IsInterState, Remarks, TaxableAmount, GstAmount, NetAmount, IsDirect, CreatedBy)
        SELECT @CompanyId, @BranchId, @today, @sup,
               DATEADD(DAY, ISNULL((SELECT MAX(i.LeadDays) FROM @p p JOIN dbo.PhItem i ON i.ItemId = p.ItemId WHERE p.SupplierId = @sup), 2), @today),
               ISNULL(@inter, 0), N'Auto reorder suggestion', @tax, @gst, @tax + @gst, ISNULL(@direct, 0), @UserId;
        SET @po = CAST(SCOPE_IDENTITY() AS INT);

        INSERT dbo.PhPurchaseOrderDtl (PoId, ItemId, Qty, FreeQty, Rate, DiscPercent, GstPercent, TaxableAmount, GstAmount)
        SELECT @po, ItemId, Qty, FreeQty, Rate, DiscPercent, GstPercent, TaxableAmount, GstAmount FROM @p WHERE SupplierId = @sup;

        INSERT @out SELECT @po, (SELECT SupplierName FROM dbo.PhSupplier WHERE SupplierId = @sup), (SELECT COUNT(*) FROM @p WHERE SupplierId = @sup), @tax + @gst;
        FETCH NEXT FROM sc INTO @sup;
    END
    CLOSE sc; DEALLOCATE sc;
    COMMIT;
    SELECT PoId, SupplierName, Lines, NetAmount, CAST(NULL AS NVARCHAR(300)) AS Error FROM @out ORDER BY SupplierName;
END
GO

-- ── pages: Pharmacy > Purchase > Auto Reorder; Master > Pharmacy > Supplier Scheme ───────────────────────
DECLARE @co INT, @menu INT, @page INT, @view INT, @ctl INT, @save INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY.PURCHASE' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'PHARMACY.AUTOREORDER',
             @Title = N'Auto Reorder', @Controller = N'PhAutoReorder', @Action = N'Index',
             @Show_In_Menu = 1, @Sort_Order = 15, @Icon = N'bi bi-arrow-repeat me-2', @Page_ID = @page OUTPUT;
        SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'CREATEPO', @Title = N'Create purchase orders', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'PhAutoReorder', @Action = N'Index',     @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'PhAutoReorder', @Action = N'Data',      @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'PhAutoReorder', @Action = N'SchemeFree', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl,  @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhAutoReorder', @Action = N'CreatePos', @Source = 'SEED';
    END

    -- scheme free quantity on the purchase order and GRN forms (VIEW of those pages)
    DECLARE @pg INT, @pv INT, @pc NVARCHAR(60), @pctl NVARCHAR(60);
    DECLARE pp CURSOR LOCAL FAST_FORWARD FOR SELECT v.Code, v.Ctl FROM (VALUES (N'PHARMACY.PURCHASEORDER', N'PhPurchaseOrders'), (N'PHARMACY.GRN', N'PhGrns')) v(Code, Ctl);
    OPEN pp; FETCH NEXT FROM pp INTO @pc, @pctl;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @pg = NULL; SET @pv = NULL;
        SELECT @pg = Page_ID FROM dbo.PageMaster WHERE Page_Code = @pc AND CompanyId = @co;
        SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pg AND Control_Code = 'VIEW';
        IF @pv IS NOT NULL
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pg, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = @pctl, @Action = N'SchemeFree', @Source = 'SEED';
        FETCH NEXT FROM pp INTO @pc, @pctl;
    END
    CLOSE pp; DEALLOCATE pp;

    -- Supplier Scheme sits with the other pharmacy masters (same menu as Discount Scheme)
    SET @menu = NULL;
    SELECT @menu = pm.Menu_ID FROM dbo.PageMaster pm WHERE pm.Page_Code = 'MASTER.PH_DISCOUNTS' AND pm.CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'MASTER.PH_SUPPLIERSCHEMES',
             @Title = N'Supplier Scheme (Free Goods)', @Controller = N'PharmacyMasters', @Action = N'SupplierSchemes',
             @Show_In_Menu = 1, @Sort_Order = 115, @Icon = N'bi bi-gift me-2', @Page_ID = @page OUTPUT;
        SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        SET @save = NULL;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PharmacyMasters', @Action = N'SupplierSchemes', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Add / edit', @Sort_Order = 20, @Control_ID = @save OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @save, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PharmacyMasters', @Action = N'SaveSupplierScheme', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

-- ── Report P10 Scheme & Batch Margin: effective cost of each received batch with free goods spread, margin on MRP ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_SchemeMargin
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT g.GrnId, g.GrnNo, g.GrnDate, s.SupplierName, i.ItemCode, i.ItemName, d.BatchNo, d.ExpiryDate, d.Qty, d.FreeQty, d.Rate, d.DiscPercent, d.GstPercent, d.Mrp,
           d.TaxableAmount,
           CASE WHEN d.FreeQty > 0 THEN CAST(CAST(d.Qty AS DECIMAL(12,0)) AS NVARCHAR(12)) + N' + ' + CAST(CAST(d.FreeQty AS DECIMAL(12,0)) AS NVARCHAR(12)) END AS Scheme,
           CAST(d.Rate * (1 - d.DiscPercent / 100) AS DECIMAL(12,2)) AS NetRate,
           CAST(d.TaxableAmount / NULLIF(d.Qty + d.FreeQty, 0) AS DECIMAL(12,2)) AS EffectiveCost,
           CAST(d.TaxableAmount / NULLIF(d.Qty + d.FreeQty, 0) * (1 + d.GstPercent / 100) AS DECIMAL(12,2)) AS EffectiveCostGst,
           CAST(d.FreeQty * d.Rate * (1 - d.DiscPercent / 100) AS DECIMAL(14,2)) AS FreeValue,
           CAST(CASE WHEN d.Mrp > 0 THEN (d.Mrp / (1 + d.GstPercent / 100) - d.Rate * (1 - d.DiscPercent / 100)) * 100 / (d.Mrp / (1 + d.GstPercent / 100)) END AS DECIMAL(8,2)) AS MarginWithoutFree,
           CAST(CASE WHEN d.Mrp > 0 THEN (d.Mrp / (1 + d.GstPercent / 100) - d.TaxableAmount / NULLIF(d.Qty + d.FreeQty, 0)) * 100 / (d.Mrp / (1 + d.GstPercent / 100)) END AS DECIMAL(8,2)) AS MarginPct
      INTO #R
      FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId
      JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
     WHERE g.CompanyId = @CompanyId AND (@BranchId IS NULL OR g.BranchId = @BranchId) AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @From AND @To
       AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId)
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search OR d.BatchNo = @Search)
       AND (@Option IS NULL OR @Option = '' OR (@Option = 'FREE' AND d.FreeQty > 0) OR (@Option = 'LOWMARGIN' AND d.Mrp > 0
            AND (d.Mrp / (1 + d.GstPercent / 100) - d.TaxableAmount / NULLIF(d.Qty + d.FreeQty, 0)) * 100 / (d.Mrp / (1 + d.GstPercent / 100)) < 10));

    SELECT COUNT(*) AS Batches, SUM(CASE WHEN FreeQty > 0 THEN 1 ELSE 0 END) AS WithFree, ISNULL(SUM(FreeValue), 0) AS FreeValue,
           CAST(CASE WHEN SUM(Mrp / (1 + GstPercent / 100) * (Qty + FreeQty)) > 0
                     THEN (SUM(Mrp / (1 + GstPercent / 100) * (Qty + FreeQty)) - SUM(TaxableAmount)) * 100 / SUM(Mrp / (1 + GstPercent / 100) * (Qty + FreeQty)) ELSE 0 END AS DECIMAL(8,2)) AS AvgMargin
      FROM #R;
    SELECT ROW_NUMBER() OVER (ORDER BY GrnDate DESC, GrnId DESC, ItemName) AS Rn, * FROM #R
     ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Qty) AS Qty, SUM(FreeQty) AS FreeQty, SUM(TaxableAmount) AS TaxableAmount, SUM(FreeValue) AS FreeValue FROM #R;
END
GO

DECLARE @co INT, @ph INT, @page INT, @view INT, @exp INT;
DECLARE co CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.PHARMACY';
OPEN co; FETCH NEXT FROM co INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @ph = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.PHARMACY' AND CompanyId = @co;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @ph, @Page_Code = N'REPORTS.PHARMACY.SCHEMEMARGIN', @Title = N'Scheme & Batch Margin', @Controller = N'PhReports',
         @Action = N'SchemeMargin', @Show_In_Menu = 1, @Sort_Order = 295, @Icon = N'bi bi-gift me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    SET @exp = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EXPORT', @Title = N'Export to Excel / PDF', @Sort_Order = 20, @Control_ID = @exp OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = N'SchemeMargin', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = N'SchemeMarginData', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @exp, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = N'SchemeMarginExport', @Source = 'SEED';
    FETCH NEXT FROM co INTO @co;
END
CLOSE co; DEALLOCATE co;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2403 applied: Pharmacy Auto Reorder and Supplier Schemes.';
GO
