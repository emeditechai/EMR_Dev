-- ============================================================================================================
-- Migration: 2364_pharmacy_stores.sql
-- Pharmacy godowns / stores, branch-wise.
--   PhStore: the stores of a branch (Main / Godown / Counter): which can receive goods (GRN, transfer in) and which can sell.
--   PhStoreStock: stock of each batch in each store. PhStock stays the branch total (sum of its stores), so the dashboard,
--   reports and searches that read the branch keep working; usp_PhStock_Move keeps both in step and refuses to take a store below zero.
--   Every branch gets a Main Store (receives and sells) holding all stock it has today, so nothing changes until a branch adds stores.
--   Documents name their store: GRN, purchase return, sale bill (and its returns / cancellation), branch transfer (from / to store),
--   adjustment / write-off, physical count. No store given = the branch's default receiving (or selling) store.
--   Store Issue (godown -> counter, same branch): request -> issue (stock out of the godown) -> receive (stock into the counter, short with a reason).
--   Ledger: StoreId and StoreBalanceAfter on every movement; store issue out / in are ISO / ISI.
-- Run after 2363. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.PhStore') IS NULL
CREATE TABLE dbo.PhStore (
    StoreId           INT IDENTITY PRIMARY KEY,
    CompanyId         INT NOT NULL,
    BranchId          INT NOT NULL,
    StoreCode         NVARCHAR(20) NOT NULL,
    StoreName         NVARCHAR(100) NOT NULL,
    StoreType         VARCHAR(10) NOT NULL DEFAULT 'GODOWN',     -- MAIN | GODOWN | COUNTER
    CanReceive        BIT NOT NULL DEFAULT 1,                    -- GRN / branch transfer in
    CanSell           BIT NOT NULL DEFAULT 0,                    -- counter sale
    IsDefaultReceive  BIT NOT NULL DEFAULT 0,
    IsDefaultSell     BIT NOT NULL DEFAULT 0,
    Remarks           NVARCHAR(300) NULL,
    IsActive          BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhStore_Code UNIQUE (BranchId, StoreCode)
);
GO
IF OBJECT_ID('dbo.PhStoreStock') IS NULL
CREATE TABLE dbo.PhStoreStock (
    StoreId      INT NOT NULL REFERENCES dbo.PhStore (StoreId),
    BatchId      INT NOT NULL REFERENCES dbo.PhBatch (BatchId),
    BranchId     INT NOT NULL,
    ItemId       INT NOT NULL,
    QtyOnHand    DECIMAL(14,3) NOT NULL DEFAULT 0,   -- sale units
    ModifiedDate DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_PhStoreStock PRIMARY KEY (StoreId, BatchId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhStoreStock_Item' AND object_id = OBJECT_ID('dbo.PhStoreStock'))
    CREATE INDEX IX_PhStoreStock_Item ON dbo.PhStoreStock (StoreId, ItemId) INCLUDE (QtyOnHand, BatchId);
GO
IF COL_LENGTH('dbo.PhStockLedger', 'StoreId') IS NULL ALTER TABLE dbo.PhStockLedger ADD StoreId INT NULL, StoreBalanceAfter DECIMAL(14,3) NULL;
IF COL_LENGTH('dbo.PhGrn', 'StoreId') IS NULL ALTER TABLE dbo.PhGrn ADD StoreId INT NULL;
IF COL_LENGTH('dbo.PhPurchaseReturn', 'StoreId') IS NULL ALTER TABLE dbo.PhPurchaseReturn ADD StoreId INT NULL;
IF COL_LENGTH('dbo.PhSale', 'StoreId') IS NULL ALTER TABLE dbo.PhSale ADD StoreId INT NULL;
IF COL_LENGTH('dbo.PhTransfer', 'FromStoreId') IS NULL ALTER TABLE dbo.PhTransfer ADD FromStoreId INT NULL, ToStoreId INT NULL;
IF COL_LENGTH('dbo.PhAdjustment', 'StoreId') IS NULL ALTER TABLE dbo.PhAdjustment ADD StoreId INT NULL;
IF COL_LENGTH('dbo.PhStockCount', 'StoreId') IS NULL ALTER TABLE dbo.PhStockCount ADD StoreId INT NULL;
GO

-- ── store issue (godown -> counter, same branch) ──────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhStoreIssue') IS NULL
CREATE TABLE dbo.PhStoreIssue (
    IssueId        INT IDENTITY PRIMARY KEY,
    CompanyId      INT NOT NULL,
    BranchId       INT NOT NULL,
    IssueNo        NVARCHAR(40) NULL,                -- given when the request is sent
    RequestDate    DATETIME NOT NULL DEFAULT GETDATE(),
    FromStoreId    INT NOT NULL REFERENCES dbo.PhStore (StoreId),   -- gives (godown)
    ToStoreId      INT NOT NULL REFERENCES dbo.PhStore (StoreId),   -- asks and receives (counter)
    Status         VARCHAR(10) NOT NULL DEFAULT 'DRAFT', -- DRAFT | REQUESTED | ISSUED | RECEIVED | CANCELLED
    Remarks        NVARCHAR(500) NULL,
    IssueRemarks   NVARCHAR(500) NULL,
    ReceiveRemarks NVARCHAR(500) NULL,
    CostValue      DECIMAL(14,2) NOT NULL DEFAULT 0,
    VarianceValue  DECIMAL(14,2) NOT NULL DEFAULT 0,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
    IssueDate DATETIME NULL, IssuedBy INT NULL, ReceiveDate DATETIME NULL, ReceivedBy INT NULL, CancelledBy INT NULL, CancelledDate DATETIME NULL,
    ModifiedBy INT NULL, ModifiedDate DATETIME NULL
);
GO
IF OBJECT_ID('dbo.PhStoreIssueDtl') IS NULL
CREATE TABLE dbo.PhStoreIssueDtl (
    IssueDtlId     INT IDENTITY PRIMARY KEY,
    IssueId        INT NOT NULL REFERENCES dbo.PhStoreIssue (IssueId),
    ItemId         INT NOT NULL,
    RequestQty     DECIMAL(14,3) NOT NULL DEFAULT 0,   -- request lines (one per item); issued batches are added as lines with RequestQty 0
    BatchId        INT NULL,
    IssueQty       DECIMAL(14,3) NULL,
    ReceivedQty    DECIMAL(14,3) NULL,
    UnitCost       DECIMAL(12,4) NULL,
    Remarks        NVARCHAR(300) NULL,
    VarianceReason NVARCHAR(300) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhStoreIssue_Branch' AND object_id = OBJECT_ID('dbo.PhStoreIssue'))
    CREATE INDEX IX_PhStoreIssue_Branch ON dbo.PhStoreIssue (BranchId, Status);
GO

-- ── store helpers ────────────────────────────────────────────────────────────────────────────────────────
-- the branch's store for a purpose: RECEIVE (GRN, transfer in, adjustments) or SELL (counter)
CREATE OR ALTER FUNCTION dbo.fn_PhDefaultStore (@BranchId INT, @Purpose VARCHAR(10))
RETURNS INT
AS
BEGIN
    RETURN (SELECT TOP 1 StoreId FROM dbo.PhStore
             WHERE BranchId = @BranchId AND IsActive = 1 AND (@Purpose = 'SELL' AND CanSell = 1 OR @Purpose <> 'SELL' AND CanReceive = 1)
             ORDER BY CASE WHEN @Purpose = 'SELL' THEN IsDefaultSell ELSE IsDefaultReceive END DESC, StoreId);
END
GO

-- a store given by the caller is usable for the purpose (ANY = any active store of the branch)
CREATE OR ALTER FUNCTION dbo.fn_PhStoreOk (@BranchId INT, @StoreId INT, @Purpose VARCHAR(10))
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM dbo.PhStore WHERE StoreId = @StoreId AND BranchId = @BranchId AND IsActive = 1
                               AND (@Purpose = 'ANY' OR @Purpose = 'SELL' AND CanSell = 1 OR @Purpose = 'RECEIVE' AND CanReceive = 1)) THEN 1 ELSE 0 END;
END
GO

-- every branch has at least its Main Store (receives and sells)
CREATE OR ALTER PROCEDURE dbo.usp_PhStore_Ensure @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @BranchId IS NULL OR EXISTS (SELECT 1 FROM dbo.PhStore WHERE BranchId = @BranchId) RETURN;
    INSERT dbo.PhStore (CompanyId, BranchId, StoreCode, StoreName, StoreType, CanReceive, CanSell, IsDefaultReceive, IsDefaultSell, Remarks)
    VALUES (@CompanyId, @BranchId, N'MAIN', N'Main Store', 'MAIN', 1, 1, 1, 1, N'Created automatically; receives and sells.');
END
GO

-- ── migration: a Main Store per branch holding today's stock; documents and ledger point to it ─────────────
DECLARE @b TABLE (CompanyId INT, BranchId INT);
INSERT @b SELECT DISTINCT CompanyId, BranchId FROM dbo.PhNumberSeries
    UNION SELECT DISTINCT b.CompanyId, s.BranchId FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId;
DECLARE @co INT, @br INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId, BranchId FROM @b;
OPEN c; FETCH NEXT FROM c INTO @co, @br;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_PhStore_Ensure @co, @br; FETCH NEXT FROM c INTO @co, @br; END
CLOSE c; DEALLOCATE c;

INSERT dbo.PhStoreStock (StoreId, BatchId, BranchId, ItemId, QtyOnHand)
SELECT dbo.fn_PhDefaultStore(s.BranchId, 'RECEIVE'), s.BatchId, s.BranchId, s.ItemId, s.QtyOnHand
  FROM dbo.PhStock s
 WHERE NOT EXISTS (SELECT 1 FROM dbo.PhStoreStock x WHERE x.BranchId = s.BranchId AND x.BatchId = s.BatchId)
   AND NOT EXISTS (SELECT 1 FROM dbo.PhStoreStock x WHERE x.BranchId = s.BranchId);   -- only the first time
UPDATE dbo.PhStockLedger SET StoreId = dbo.fn_PhDefaultStore(BranchId, 'RECEIVE') WHERE StoreId IS NULL;
UPDATE dbo.PhGrn SET StoreId = dbo.fn_PhDefaultStore(BranchId, 'RECEIVE') WHERE StoreId IS NULL;
UPDATE dbo.PhPurchaseReturn SET StoreId = dbo.fn_PhDefaultStore(BranchId, 'RECEIVE') WHERE StoreId IS NULL AND Status <> 'DRAFT';
UPDATE dbo.PhSale SET StoreId = dbo.fn_PhDefaultStore(BranchId, 'SELL') WHERE StoreId IS NULL;
UPDATE dbo.PhTransfer SET FromStoreId = dbo.fn_PhDefaultStore(FromBranchId, 'RECEIVE') WHERE FromStoreId IS NULL AND Status IN ('DISPATCHED', 'RECEIVED');
UPDATE dbo.PhTransfer SET ToStoreId = dbo.fn_PhDefaultStore(ToBranchId, 'RECEIVE') WHERE ToStoreId IS NULL AND Status = 'RECEIVED';
UPDATE dbo.PhAdjustment SET StoreId = dbo.fn_PhDefaultStore(BranchId, 'RECEIVE') WHERE StoreId IS NULL;
UPDATE dbo.PhStockCount SET StoreId = dbo.fn_PhDefaultStore(BranchId, 'RECEIVE') WHERE StoreId IS NULL;

-- number series for store issues
INSERT dbo.PhNumberSeries (CompanyId, BranchId, DocType, DocName, Prefix)
SELECT s.CompanyId, s.BranchId, 'SISS', N'Store Issue (godown to counter)', 'SIS'
  FROM (SELECT DISTINCT CompanyId, BranchId FROM dbo.PhNumberSeries) s
 WHERE NOT EXISTS (SELECT 1 FROM dbo.PhNumberSeries x WHERE x.BranchId = s.BranchId AND x.DocType = 'SISS');
GO

-- ── the one place stock changes: branch total (PhStock) and the store (PhStoreStock) together ──────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhStock_Move
    @BranchId INT, @BatchId INT, @Qty DECIMAL(14,3),      -- + in, - out (sale units)
    @DocType VARCHAR(10), @DocId INT, @DocNo NVARCHAR(40), @UserId INT, @AllowNegative BIT = 0,
    @StoreId INT = NULL                                    -- NULL = the branch's default selling store (sales) or receiving store (everything else)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @item INT, @cost DECIMAL(12,4), @company INT, @bal DECIMAL(14,3), @sbal DECIMAL(14,3);
    SELECT @item = ItemId, @cost = LandedCost, @company = CompanyId FROM dbo.PhBatch WHERE BatchId = @BatchId;
    IF @item IS NULL THROW 51001, 'Batch not found.', 1;
    IF @StoreId IS NULL
    BEGIN
        DECLARE @purpose VARCHAR(10) = CASE WHEN @DocType IN ('SALE', 'SRET', 'SCAN') THEN 'SELL' ELSE 'RECEIVE' END;
        SET @StoreId = dbo.fn_PhDefaultStore(@BranchId, @purpose);
        IF @StoreId IS NULL BEGIN EXEC dbo.usp_PhStore_Ensure @company, @BranchId; SET @StoreId = dbo.fn_PhDefaultStore(@BranchId, @purpose); END
        IF @StoreId IS NULL THROW 51003, 'This branch has no pharmacy store for this movement (Master > Pharmacy Master > Store / Godown).', 1;
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.PhStore WHERE StoreId = @StoreId AND BranchId = @BranchId)
        THROW 51003, 'The store is not of this branch.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.PhStock WITH (UPDLOCK, HOLDLOCK) WHERE BranchId = @BranchId AND BatchId = @BatchId)
        INSERT dbo.PhStock (BranchId, BatchId, ItemId, QtyOnHand) VALUES (@BranchId, @BatchId, @item, 0);
    UPDATE dbo.PhStock WITH (UPDLOCK) SET @bal = QtyOnHand = QtyOnHand + @Qty, ModifiedDate = GETDATE() WHERE BranchId = @BranchId AND BatchId = @BatchId;

    IF NOT EXISTS (SELECT 1 FROM dbo.PhStoreStock WITH (UPDLOCK, HOLDLOCK) WHERE StoreId = @StoreId AND BatchId = @BatchId)
        INSERT dbo.PhStoreStock (StoreId, BatchId, BranchId, ItemId, QtyOnHand) VALUES (@StoreId, @BatchId, @BranchId, @item, 0);
    UPDATE dbo.PhStoreStock WITH (UPDLOCK) SET @sbal = QtyOnHand = QtyOnHand + @Qty, ModifiedDate = GETDATE() WHERE StoreId = @StoreId AND BatchId = @BatchId;

    IF @sbal < 0 AND @AllowNegative = 0
    BEGIN
        DECLARE @msg NVARCHAR(400) = CONCAT(N'Not enough stock of ', (SELECT i.ItemName + N' batch ' + b.BatchNo FROM dbo.PhBatch b JOIN dbo.PhItem i ON i.ItemId = b.ItemId WHERE b.BatchId = @BatchId),
                                            N' in ', (SELECT StoreName FROM dbo.PhStore WHERE StoreId = @StoreId), N': short by ', CAST(-@sbal AS DECIMAL(14,2)), N'.');
        THROW 51002, @msg, 1;
    END
    INSERT dbo.PhStockLedger (BranchId, ItemId, BatchId, DocType, DocId, DocNo, QtyIn, QtyOut, BalanceAfter, UnitCost, CreatedBy, StoreId, StoreBalanceAfter)
    VALUES (@BranchId, @item, @BatchId, @DocType, @DocId, @DocNo, CASE WHEN @Qty > 0 THEN @Qty ELSE 0 END, CASE WHEN @Qty < 0 THEN -@Qty ELSE 0 END, @bal, @cost, @UserId, @StoreId, @sbal);
END;
GO

-- stock rows of one store (same columns as fn_PhStockRows, which is the branch total)
CREATE OR ALTER FUNCTION dbo.fn_PhStoreStockRows (@CompanyId INT, @BranchId INT, @StoreId INT)
RETURNS TABLE
AS
RETURN
    SELECT b.BatchId, i.ItemId, i.ItemCode, i.ItemName, df.ShortName FormShort, g.GenericName, m.ManufacturerName, c.CategoryName, i.ScheduleCode, ib.RackNo,
           b.BatchNo, b.ExpiryDate, b.Mrp, b.LandedCost, b.GstPercent, ISNULL(s.QtyOnHand, 0) Stock, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty, b.IsBlocked, sp.SupplierName,
           s.BatchId AS StockBatchId, s.QtyOnHand, i.Barcode, i.CategoryId, c.ParentCategoryId
      FROM dbo.PhStoreStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
      LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
      LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId LEFT JOIN dbo.PhSupplier sp ON sp.SupplierId = b.SupplierId
      LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
     WHERE b.CompanyId = @CompanyId AND s.StoreId = @StoreId AND s.BranchId = @BranchId;
GO

-- ── store master (Master > Pharmacy Master > Store / Godown), branch-wise ──────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhStore_GetList @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_PhStore_Ensure @CompanyId, @BranchId;
    SELECT s.StoreId, s.StoreCode, s.StoreName, s.StoreType, s.CanReceive, s.CanSell, s.IsDefaultReceive, s.IsDefaultSell, s.Remarks, s.IsActive,
           CAST(ISNULL((SELECT SUM(x.QtyOnHand * b.LandedCost) FROM dbo.PhStoreStock x JOIN dbo.PhBatch b ON b.BatchId = x.BatchId WHERE x.StoreId = s.StoreId AND x.QtyOnHand > 0), 0) AS DECIMAL(14,2)) AS StockValue
      FROM dbo.PhStore s WHERE s.CompanyId = @CompanyId AND s.BranchId = @BranchId
     ORDER BY CASE s.StoreType WHEN 'MAIN' THEN 0 WHEN 'GODOWN' THEN 1 ELSE 2 END, s.StoreName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhStore_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @StoreCode NVARCHAR(20) = NULL, @StoreName NVARCHAR(100) = NULL, @StoreType VARCHAR(10) = NULL, @CanReceive BIT = NULL, @CanSell BIT = NULL,
    @IsDefaultReceive BIT = NULL, @IsDefaultSell BIT = NULL, @Remarks NVARCHAR(300) = NULL, @StockValue DECIMAL(14,2) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SELECT @CanReceive = ISNULL(@CanReceive, 0), @CanSell = ISNULL(@CanSell, 0), @IsDefaultReceive = ISNULL(@IsDefaultReceive, 0), @IsDefaultSell = ISNULL(@IsDefaultSell, 0),
           @StoreType = ISNULL(NULLIF(@StoreType, ''), 'GODOWN');
    IF @StoreType NOT IN ('MAIN', 'GODOWN', 'COUNTER') BEGIN SELECT 0 AS Id, N'Type must be Main, Godown or Counter.' AS Error; RETURN; END;
    IF @CanReceive = 0 AND @CanSell = 0 BEGIN SELECT 0 AS Id, N'A store must at least receive goods or sell.' AS Error; RETURN; END;
    IF @IsDefaultReceive = 1 AND @CanReceive = 0 BEGIN SELECT 0 AS Id, N'Only a store that receives goods can be the default receiving store.' AS Error; RETURN; END;
    IF @IsDefaultSell = 1 AND @CanSell = 0 BEGIN SELECT 0 AS Id, N'Only a store that sells can be the default selling store.' AS Error; RETURN; END;
    IF (@IsDefaultReceive = 1 OR @IsDefaultSell = 1) AND @IsActive = 0 BEGIN SELECT 0 AS Id, N'The default store cannot be made inactive.' AS Error; RETURN; END;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) > 0
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.PhStore WITH (UPDLOCK) WHERE StoreId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId)
            BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END;
            IF @IsActive = 0 AND EXISTS (SELECT 1 FROM dbo.PhStoreStock WHERE StoreId = @Id AND QtyOnHand <> 0)
            BEGIN ROLLBACK; SELECT 0 AS Id, N'This store still holds stock; issue or transfer it out before making the store inactive.' AS Error; RETURN; END;
            IF EXISTS (SELECT 1 FROM dbo.PhStoreIssue WHERE (FromStoreId = @Id OR ToStoreId = @Id) AND Status IN ('REQUESTED', 'ISSUED')) AND @IsActive = 0
            BEGIN ROLLBACK; SELECT 0 AS Id, N'A store issue of this store is still open.' AS Error; RETURN; END;
            UPDATE dbo.PhStore SET StoreCode = UPPER(@StoreCode), StoreName = @StoreName, StoreType = @StoreType, CanReceive = @CanReceive, CanSell = @CanSell,
                   IsDefaultReceive = @IsDefaultReceive, IsDefaultSell = @IsDefaultSell, Remarks = @Remarks, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE StoreId = @Id;
        END
        ELSE
        BEGIN
            INSERT dbo.PhStore (CompanyId, BranchId, StoreCode, StoreName, StoreType, CanReceive, CanSell, IsDefaultReceive, IsDefaultSell, Remarks, IsActive, CreatedBy)
            VALUES (@CompanyId, @BranchId, UPPER(@StoreCode), @StoreName, @StoreType, @CanReceive, @CanSell, @IsDefaultReceive, @IsDefaultSell, @Remarks, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        -- one default of each kind per branch
        IF @IsDefaultReceive = 1 UPDATE dbo.PhStore SET IsDefaultReceive = 0 WHERE BranchId = @BranchId AND StoreId <> @Id;
        IF @IsDefaultSell = 1 UPDATE dbo.PhStore SET IsDefaultSell = 0 WHERE BranchId = @BranchId AND StoreId <> @Id;
        IF NOT EXISTS (SELECT 1 FROM dbo.PhStore WHERE BranchId = @BranchId AND IsActive = 1 AND IsDefaultReceive = 1 AND CanReceive = 1)
        BEGIN ROLLBACK; SELECT 0 AS Id, N'The branch needs one default receiving store (for GRNs and transfers in).' AS Error; RETURN; END;
        IF NOT EXISTS (SELECT 1 FROM dbo.PhStore WHERE BranchId = @BranchId AND IsActive = 1 AND IsDefaultSell = 1 AND CanSell = 1)
        BEGIN ROLLBACK; SELECT 0 AS Id, N'The branch needs one default selling store (the counter).' AS Error; RETURN; END;
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'A store with this code already exists in the branch.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- the stores of the branch for drop-downs: Purpose RECEIVE / SELL / ANY
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhStore_Options @CompanyId INT, @BranchId INT, @Purpose VARCHAR(10) = 'ANY'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_PhStore_Ensure @CompanyId, @BranchId;
    SELECT StoreId, StoreCode, StoreName, StoreType, CanReceive, CanSell,
           CAST(CASE WHEN @Purpose = 'SELL' THEN IsDefaultSell WHEN @Purpose = 'RECEIVE' THEN IsDefaultReceive ELSE 0 END AS BIT) AS IsDefault
      FROM dbo.PhStore
     WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND IsActive = 1
       AND (@Purpose = 'ANY' OR @Purpose = 'SELL' AND CanSell = 1 OR @Purpose = 'RECEIVE' AND CanReceive = 1)
     ORDER BY CASE WHEN @Purpose = 'SELL' THEN IsDefaultSell WHEN @Purpose = 'RECEIVE' THEN IsDefaultReceive ELSE 0 END DESC, StoreName;
END
GO

-- batches with stock in a store (sellable: not expired, not blocked)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhStore_Batches @CompanyId INT, @BranchId INT, @StoreId INT, @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.BatchId, b.ItemId, b.BatchNo, b.ExpiryDate, b.Mrp PackMrp, b.Mrp / i.ConversionQty UnitMrp, b.LandedCost, b.GstPercent, s.QtyOnHand Stock
      FROM dbo.PhStoreStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId
     WHERE s.StoreId = @StoreId AND s.BranchId = @BranchId AND b.CompanyId = @CompanyId AND s.ItemId = @ItemId AND s.QtyOnHand > 0
       AND b.IsBlocked = 0 AND b.ExpiryDate > CAST(GETDATE() AS DATE)
     ORDER BY b.ExpiryDate, b.BatchId;
END
GO
-- ── Store Issue: godown -> counter within the branch ──────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhIss_List @CompanyId INT, @BranchId INT, @Status VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 300 x.IssueId Id, x.IssueNo DocNo, x.RequestDate DocDate, x.Status, f.StoreName FromStore, t.StoreName ToStore,
           (SELECT COUNT(*) FROM dbo.PhStoreIssueDtl d WHERE d.IssueId = x.IssueId AND d.RequestQty > 0) Lines, x.CostValue, x.VarianceValue,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = x.CreatedBy) CreatedByName, x.IssueDate, x.ReceiveDate
      FROM dbo.PhStoreIssue x JOIN dbo.PhStore f ON f.StoreId = x.FromStoreId JOIN dbo.PhStore t ON t.StoreId = x.ToStoreId
     WHERE x.CompanyId = @CompanyId AND x.BranchId = @BranchId AND (@Status IS NULL OR x.Status = @Status)
     ORDER BY CASE x.Status WHEN 'REQUESTED' THEN 0 WHEN 'ISSUED' THEN 1 WHEN 'DRAFT' THEN 2 ELSE 3 END, x.IssueId DESC;
END
GO

-- set 1 header, set 2 lines (request lines: RequestQty > 0; issued batches: RequestQty = 0), with stock in the giving store
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhIss_Get @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhStoreIssue WHERE IssueId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId) SET @Id = -1;
    SELECT x.IssueId Id, x.IssueNo DocNo, x.RequestDate DocDate, x.Status, x.FromStoreId, x.ToStoreId, f.StoreName FromStore, t.StoreName ToStore,
           x.Remarks, x.IssueRemarks, x.ReceiveRemarks, x.CostValue, x.VarianceValue, x.IssueDate, x.ReceiveDate, x.CreatedBy, x.CreatedDate,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = x.CreatedBy) CreatedByName,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = x.IssuedBy) IssuedByName,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = x.ReceivedBy) ReceivedByName
      FROM dbo.PhStoreIssue x JOIN dbo.PhStore f ON f.StoreId = x.FromStoreId JOIN dbo.PhStore t ON t.StoreId = x.ToStoreId
     WHERE x.IssueId = @Id;
    SELECT d.IssueDtlId LineId, d.ItemId, i.ItemName, i.ItemCode, df.ShortName FormShort, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
           d.RequestQty, d.BatchId, b.BatchNo, b.ExpiryDate, d.IssueQty, d.ReceivedQty, d.UnitCost, d.Remarks, d.VarianceReason,
           ISNULL((SELECT SUM(s.QtyOnHand) FROM dbo.PhStoreStock s JOIN dbo.PhStoreIssue x ON x.IssueId = d.IssueId WHERE s.StoreId = x.FromStoreId AND s.ItemId = d.ItemId), 0) FromStock,
           ISNULL((SELECT SUM(s.QtyOnHand) FROM dbo.PhStoreStock s JOIN dbo.PhStoreIssue x ON x.IssueId = d.IssueId WHERE s.StoreId = x.ToStoreId AND s.ItemId = d.ItemId), 0) ToStock
      FROM dbo.PhStoreIssueDtl d JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
      LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId LEFT JOIN dbo.PhBatch b ON b.BatchId = d.BatchId
     WHERE d.IssueId = @Id ORDER BY CASE WHEN d.RequestQty > 0 THEN 0 ELSE 1 END, d.IssueDtlId;
END
GO

-- request (draft or sent). @Lines: [{ "ItemId", "Qty" (sale units), "Remarks" }]. Answers Id, Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhIss_SaveRequest
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @FromStoreId INT, @ToStoreId INT, @Remarks NVARCHAR(500) = NULL, @Submit BIT = 0, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF dbo.fn_PhStoreOk(@BranchId, @FromStoreId, 'ANY') = 0 OR dbo.fn_PhStoreOk(@BranchId, @ToStoreId, 'ANY') = 0
    BEGIN SELECT 0 AS Id, N'Choose two active stores of this branch.' AS Error; RETURN; END;
    IF @FromStoreId = @ToStoreId BEGIN SELECT 0 AS Id, N'The giving and receiving store must be different.' AS Error; RETURN; END;
    DECLARE @L TABLE (Seq INT PRIMARY KEY, ItemId INT, Qty DECIMAL(18,6), Remarks NVARCHAR(300));
    INSERT @L SELECT CAST([key] AS INT), JSON_VALUE(value, '$.ItemId'), JSON_VALUE(value, '$.Qty'), JSON_VALUE(value, '$.Remarks') FROM OPENJSON(@Lines);
    IF NOT EXISTS (SELECT 1 FROM @L) BEGIN SELECT 0 AS Id, N'Add at least one item.' AS Error; RETURN; END;
    IF EXISTS (SELECT 1 FROM @L l LEFT JOIN dbo.PhItem i ON i.ItemId = l.ItemId AND i.CompanyId = @CompanyId WHERE i.ItemId IS NULL OR ISNULL(l.Qty, 0) <= 0)
    BEGIN SELECT 0 AS Id, N'Every line needs an item of the Item Master and a quantity above zero.' AS Error; RETURN; END;
    IF EXISTS (SELECT ItemId FROM @L GROUP BY ItemId HAVING COUNT(*) > 1) BEGIN SELECT 0 AS Id, N'An item is on the request twice.' AS Error; RETURN; END;
    BEGIN TRY
        BEGIN TRAN;
        IF @Id > 0
        BEGIN
            IF ISNULL((SELECT Status FROM dbo.PhStoreIssue WITH (UPDLOCK) WHERE IssueId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'DRAFT'
            BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a draft request can be changed.' AS Error; RETURN; END;
            UPDATE dbo.PhStoreIssue SET FromStoreId = @FromStoreId, ToStoreId = @ToStoreId, Remarks = @Remarks, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE IssueId = @Id;
            DELETE dbo.PhStoreIssueDtl WHERE IssueId = @Id;
        END
        ELSE
        BEGIN
            INSERT dbo.PhStoreIssue (CompanyId, BranchId, FromStoreId, ToStoreId, Remarks, CreatedBy) VALUES (@CompanyId, @BranchId, @FromStoreId, @ToStoreId, @Remarks, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        INSERT dbo.PhStoreIssueDtl (IssueId, ItemId, RequestQty, Remarks) SELECT @Id, ItemId, Qty, Remarks FROM @L ORDER BY Seq;
        IF @Submit = 1
        BEGIN
            DECLARE @no NVARCHAR(40), @tdy DATE = CAST(GETDATE() AS DATE);
            IF NOT EXISTS (SELECT 1 FROM dbo.PhNumberSeries WHERE BranchId = @BranchId AND DocType = 'SISS')
                INSERT dbo.PhNumberSeries (CompanyId, BranchId, DocType, DocName, Prefix) VALUES (@CompanyId, @BranchId, 'SISS', N'Store Issue (godown to counter)', 'SIS');
            EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'SISS', @DocDate = @tdy, @DocNo = @no OUTPUT;
            UPDATE dbo.PhStoreIssue SET Status = 'REQUESTED', IssueNo = @no, RequestDate = GETDATE() WHERE IssueId = @Id;
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT 0 AS Id, ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- issue batches from the giving store. @Lines: [{ "BatchId", "IssueQty" }]. Answers Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhIss_Issue @CompanyId INT, @BranchId INT, @UserId INT, @Id INT, @Remarks NVARCHAR(500) = NULL, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @L TABLE (Seq INT PRIMARY KEY, BatchId INT, IssueQty DECIMAL(18,6), ItemId INT, UnitCost DECIMAL(12,4), Exp DATE, Blocked BIT);
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @from INT, @no NVARCHAR(40);
        SELECT @status = Status, @from = FromStoreId, @no = IssueNo FROM dbo.PhStoreIssue WITH (UPDLOCK) WHERE IssueId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF ISNULL(@status, '') <> 'REQUESTED' BEGIN ROLLBACK; SELECT N'Only a request not yet issued can be issued.' AS Error; RETURN; END;
        DECLARE @Req TABLE (ItemId INT PRIMARY KEY, Qty DECIMAL(18,6));
        INSERT @Req SELECT ItemId, SUM(RequestQty) FROM dbo.PhStoreIssueDtl WHERE IssueId = @Id AND RequestQty > 0 GROUP BY ItemId;
        INSERT @L (Seq, BatchId, IssueQty, ItemId, UnitCost, Exp, Blocked)
        SELECT CAST(j.[key] AS INT), JSON_VALUE(j.value, '$.BatchId'), JSON_VALUE(j.value, '$.IssueQty'), b.ItemId, b.LandedCost, b.ExpiryDate, b.IsBlocked
          FROM OPENJSON(@Lines) j LEFT JOIN dbo.PhBatch b ON b.BatchId = JSON_VALUE(j.value, '$.BatchId') AND b.CompanyId = @CompanyId;
        DELETE @L WHERE ISNULL(IssueQty, 0) = 0;
        IF NOT EXISTS (SELECT 1 FROM @L) BEGIN ROLLBACK; SELECT N'Enter the quantity issued from at least one batch.' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM @L l LEFT JOIN @Req r ON r.ItemId = l.ItemId WHERE l.ItemId IS NULL OR r.ItemId IS NULL)
        BEGIN ROLLBACK; SELECT N'A batch is not of an item on this request.' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM @L WHERE IssueQty < 0) BEGIN ROLLBACK; SELECT N'Quantities must be above zero.' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM @L WHERE Blocked = 1 OR Exp <= CAST(GETDATE() AS DATE)) BEGIN ROLLBACK; SELECT N'An expired or blocked batch cannot be issued.' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM (SELECT ItemId, SUM(IssueQty) Q FROM @L GROUP BY ItemId) g JOIN @Req r ON r.ItemId = g.ItemId WHERE g.Q > r.Qty)
        BEGIN ROLLBACK; SELECT N'More is being issued than was asked for.' AS Error; RETURN; END;
        DELETE dbo.PhStoreIssueDtl WHERE IssueId = @Id AND RequestQty = 0;
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @L), @b INT, @q DECIMAL(14,3), @mq DECIMAL(14,3);
        WHILE @seq IS NOT NULL
        BEGIN
            INSERT dbo.PhStoreIssueDtl (IssueId, ItemId, RequestQty, BatchId, IssueQty, UnitCost) SELECT @Id, ItemId, 0, BatchId, IssueQty, UnitCost FROM @L WHERE Seq = @seq;
            SELECT @b = BatchId, @q = IssueQty FROM @L WHERE Seq = @seq;
            SET @mq = -@q;
            EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @mq, @DocType = 'ISO', @DocId = @Id, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0, @StoreId = @from;
            SET @seq = (SELECT MIN(Seq) FROM @L WHERE Seq > @seq);
        END
        UPDATE dbo.PhStoreIssue SET Status = 'ISSUED', IssueDate = GETDATE(), IssuedBy = @UserId, IssueRemarks = @Remarks,
               CostValue = (SELECT ROUND(SUM(CAST(IssueQty AS DECIMAL(38,18)) * UnitCost), 2) FROM @L)
         WHERE IssueId = @Id;
        COMMIT;
        SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- the receiving store accepts. @Received: [{ "LineId", "Qty", "Reason" }]; lines not given = received in full. Answers Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhIss_Receive @CompanyId INT, @BranchId INT, @UserId INT, @Id INT, @Remarks NVARCHAR(500) = NULL, @Received NVARCHAR(MAX) = N'[]'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @R TABLE (LineId INT PRIMARY KEY, Qty DECIMAL(18,6), HasQty BIT, Reason NVARCHAR(300));
    INSERT @R SELECT JSON_VALUE(value, '$.LineId'), JSON_VALUE(value, '$.Qty'), CASE WHEN JSON_VALUE(value, '$.Qty') IS NULL THEN 0 ELSE 1 END,
                     NULLIF(LTRIM(RTRIM(JSON_VALUE(value, '$.Reason'))), N'')
                FROM OPENJSON(ISNULL(@Received, N'[]'));
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @to INT, @no NVARCHAR(40);
        SELECT @status = Status, @to = ToStoreId, @no = IssueNo FROM dbo.PhStoreIssue WITH (UPDLOCK) WHERE IssueId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF ISNULL(@status, '') <> 'ISSUED' BEGIN ROLLBACK; SELECT N'Only an issued request can be received.' AS Error; RETURN; END;
        DECLARE @S TABLE (Rn INT IDENTITY PRIMARY KEY, DtlId INT, BatchId INT, Qty DECIMAL(14,3), Cost DECIMAL(12,4));
        INSERT @S (DtlId, BatchId, Qty, Cost) SELECT IssueDtlId, BatchId, IssueQty, UnitCost FROM dbo.PhStoreIssueDtl WHERE IssueId = @Id AND RequestQty = 0 AND IssueQty > 0 ORDER BY IssueDtlId;
        DECLARE @rn INT = (SELECT MIN(Rn) FROM @S), @dtl INT, @b INT, @sent DECIMAL(14,3), @cost DECIMAL(12,4), @got DECIMAL(18,6), @why NVARCHAR(300), @variance DECIMAL(38,8) = 0;
        WHILE @rn IS NOT NULL
        BEGIN
            SELECT @dtl = DtlId, @b = BatchId, @sent = Qty, @cost = Cost FROM @S WHERE Rn = @rn;
            SELECT @got = @sent, @why = NULL;
            SELECT @got = CASE WHEN HasQty = 1 THEN Qty ELSE @sent END, @why = Reason FROM @R WHERE LineId = @dtl;
            IF @got < 0 OR @got > @sent BEGIN ROLLBACK; SELECT N'Received quantity cannot be more than what was issued.' AS Error; RETURN; END;
            IF @got < @sent AND @why IS NULL BEGIN ROLLBACK; SELECT N'Give the reason for every quantity received short (broken, missing ...).' AS Error; RETURN; END;
            UPDATE dbo.PhStoreIssueDtl SET ReceivedQty = @got, VarianceReason = @why WHERE IssueDtlId = @dtl;
            IF @got > 0 EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @got, @DocType = 'ISI', @DocId = @Id, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0, @StoreId = @to;
            SET @variance = @variance + (@sent - @got) * @cost;
            SET @rn = (SELECT MIN(Rn) FROM @S WHERE Rn > @rn);
        END
        UPDATE dbo.PhStoreIssue SET Status = 'RECEIVED', ReceiveDate = GETDATE(), ReceivedBy = @UserId, ReceiveRemarks = @Remarks, VarianceValue = ROUND(@variance, 2) WHERE IssueId = @Id;
        COMMIT;
        SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhIss_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PhStoreIssue SET Status = 'CANCELLED', CancelledBy = @UserId, CancelledDate = GETDATE()
     WHERE IssueId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status IN ('DRAFT', 'REQUESTED');
    SELECT CASE WHEN @@ROWCOUNT = 0 THEN N'Only a request not yet issued can be cancelled.' END AS Error;
END
GO

-- ── store-aware versions of the stock procedures (same behaviour with no store: the default store) ──────────
-- ── posting procedures ────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhGrn_Post @GrnId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DECLARE @store INT, @branch INT, @company INT, @status VARCHAR(10), @date DATE, @no NVARCHAR(40), @supplier INT, @po INT, @inv DATE, @neg BIT;
    SELECT @store = StoreId, @branch = BranchId, @company = CompanyId, @status = Status, @date = GrnDate, @supplier = SupplierId, @po = PoId, @inv = InvoiceDate
    FROM dbo.PhGrn WITH (UPDLOCK) WHERE GrnId = @GrnId;
    IF @status IS NULL OR @status <> 'DRAFT' THROW 51020, 'Only a draft GRN can be posted.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhGrnDtl WHERE GrnId = @GrnId) THROW 51021, 'The GRN has no items.', 1;
    IF EXISTS (SELECT 1 FROM dbo.PhGrnDtl WHERE GrnId = @GrnId AND ExpiryDate <= CAST(GETDATE() AS DATE)) THROW 51022, 'An item on this GRN has already expired.', 1;

    EXEC dbo.usp_Ph_NextNumber @branch, 'GRN', @date, @no OUTPUT;

    -- landed cost per sale unit: (taxable + share of other charges) / ((qty + free) x conversion); GST is input credit
    DECLARE @other DECIMAL(14,2) = (SELECT OtherCharges FROM dbo.PhGrn WHERE GrnId = @GrnId);
    DECLARE @taxable DECIMAL(14,2) = (SELECT SUM(TaxableAmount) FROM dbo.PhGrnDtl WHERE GrnId = @GrnId);
    UPDATE d SET LandedCost = (d.TaxableAmount + CASE WHEN @taxable > 0 THEN @other * d.TaxableAmount / @taxable ELSE 0 END)
                            / ((d.Qty + d.FreeQty) * i.ConversionQty)
    FROM dbo.PhGrnDtl d JOIN dbo.PhItem i ON i.ItemId = d.ItemId WHERE d.GrnId = @GrnId;

    -- batches: same item + batch + MRP is the same batch (expiry must agree)
    IF EXISTS (SELECT 1 FROM dbo.PhGrnDtl d JOIN dbo.PhBatch b ON b.ItemId = d.ItemId AND b.BatchNo = d.BatchNo AND b.Mrp = d.Mrp
               WHERE d.GrnId = @GrnId AND b.ExpiryDate <> d.ExpiryDate)
        THROW 51023, 'A batch on this GRN is already in stock with a different expiry date. Check the batch number and expiry.', 1;
    INSERT dbo.PhBatch (CompanyId, ItemId, BatchNo, MfgDate, ExpiryDate, Mrp, PurchaseRate, LandedCost, GstPercent, SupplierId, CreatedBy)
    SELECT @company, d.ItemId, d.BatchNo, MIN(d.MfgDate), MIN(d.ExpiryDate), d.Mrp, MIN(d.Rate * (1 - d.DiscPercent / 100)), MIN(d.LandedCost), MIN(d.GstPercent), @supplier, @UserId
    FROM dbo.PhGrnDtl d
    WHERE d.GrnId = @GrnId AND NOT EXISTS (SELECT 1 FROM dbo.PhBatch b WHERE b.ItemId = d.ItemId AND b.BatchNo = d.BatchNo AND b.Mrp = d.Mrp)
    GROUP BY d.ItemId, d.BatchNo, d.Mrp;
    UPDATE d SET BatchId = b.BatchId FROM dbo.PhGrnDtl d JOIN dbo.PhBatch b ON b.ItemId = d.ItemId AND b.BatchNo = d.BatchNo AND b.Mrp = d.Mrp WHERE d.GrnId = @GrnId;

    -- stock in (sale units), each line
    DECLARE @bid INT, @q DECIMAL(14,3), @cost DECIMAL(12,4);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.BatchId, (d.Qty + d.FreeQty) * i.ConversionQty, d.LandedCost FROM dbo.PhGrnDtl d JOIN dbo.PhItem i ON i.ItemId = d.ItemId WHERE d.GrnId = @GrnId;
    OPEN c; FETCH NEXT FROM c INTO @bid, @q, @cost;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        UPDATE dbo.PhBatch SET LandedCost = @cost WHERE BatchId = @bid;     -- latest cost for valuation of this batch
        EXEC dbo.usp_PhStock_Move @branch, @bid, @q, 'GRN', @GrnId, @no, @UserId, 0, @store;
        FETCH NEXT FROM c INTO @bid, @q, @cost;
    END
    CLOSE c; DEALLOCATE c;

    -- purchase order received quantities and status
    IF @po IS NOT NULL
    BEGIN
        UPDATE p SET ReceivedQty = p.ReceivedQty + x.q
        FROM dbo.PhPurchaseOrderDtl p JOIN (SELECT PoDtlId, SUM(Qty) q FROM dbo.PhGrnDtl WHERE GrnId = @GrnId AND PoDtlId IS NOT NULL GROUP BY PoDtlId) x ON x.PoDtlId = p.PoDtlId;
        UPDATE dbo.PhPurchaseOrder SET Status = CASE WHEN EXISTS (SELECT 1 FROM dbo.PhPurchaseOrderDtl WHERE PoId = @po AND ReceivedQty < Qty) THEN 'PARTIAL' ELSE 'CLOSED' END,
               ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE PoId = @po AND Status IN ('APPROVED', 'PARTIAL');
    END

    UPDATE g SET GrnNo = @no, Status = 'POSTED', PostedBy = @UserId, PostedDate = GETDATE(),
                 DueDate = DATEADD(DAY, ISNULL(s.CreditDays, 0), g.InvoiceDate)
    FROM dbo.PhGrn g JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId WHERE g.GrnId = @GrnId;
    EXEC dbo.usp_Ph_PostLedger 'GRN', @GrnId, @UserId;   -- 2347: Purchase voucher
    COMMIT;
    SELECT @no AS DocNo;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_PhPurchaseReturn_Post @ReturnId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DECLARE @store INT, @branch INT, @status VARCHAR(10), @date DATE, @no NVARCHAR(40);
    SELECT @store = StoreId, @branch = BranchId, @status = Status, @date = ReturnDate FROM dbo.PhPurchaseReturn WITH (UPDLOCK) WHERE ReturnId = @ReturnId;
    IF @status IS NULL OR @status <> 'DRAFT' THROW 51030, 'Only a draft return can be posted.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhPurchaseReturnDtl WHERE ReturnId = @ReturnId) THROW 51031, 'The return has no items.', 1;
    EXEC dbo.usp_Ph_NextNumber @branch, 'PRET', @date, @no OUTPUT;
    DECLARE @bid INT, @q DECIMAL(14,3);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT BatchId, Qty FROM dbo.PhPurchaseReturnDtl WHERE ReturnId = @ReturnId;
    OPEN c; FETCH NEXT FROM c INTO @bid, @q;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @q = -@q;
        EXEC dbo.usp_PhStock_Move @branch, @bid, @q, 'PRET', @ReturnId, @no, @UserId, 0, @store;   -- never below zero
        FETCH NEXT FROM c INTO @bid, @q;
    END
    CLOSE c; DEALLOCATE c;
    UPDATE dbo.PhPurchaseReturn SET ReturnNo = @no, Status = 'POSTED', PostedBy = @UserId, PostedDate = GETDATE() WHERE ReturnId = @ReturnId;
    EXEC dbo.usp_Ph_PostLedger 'PRET', @ReturnId, @UserId;   -- 2347: Debit Note voucher
    COMMIT;
    SELECT @no AS DocNo;
END;
GO

-- lines priced and checked in EMR.Web; the order's pending quantities are checked here, in the transaction.
-- @Lines: [{ PoDtlId, ItemId, BatchNo, MfgDate, ExpiryDate, Mrp, Qty, FreeQty, Rate, DiscPercent, GstPercent, TaxableAmount, GstAmount }]
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhGrn_Save
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @DocDate DATE, @SupplierId INT, @PoId INT = NULL, @InvoiceNo NVARCHAR(40), @InvoiceDate DATE,
    @InvoiceAmount DECIMAL(14,2), @IsInterState BIT, @OtherCharges DECIMAL(14,2) = 0, @Remarks NVARCHAR(300) = NULL, @Lines NVARCHAR(MAX), @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @StoreId = ISNULL(@StoreId, dbo.fn_PhDefaultStore(@BranchId, 'RECEIVE'));
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'RECEIVE') = 0
    BEGIN SELECT 0 AS Id, N'Choose a store of this branch that receives goods.' AS Error; RETURN; END;
    DECLARE @L TABLE (PoDtlId INT, ItemId INT, BatchNo NVARCHAR(30), MfgDate DATE, ExpiryDate DATE, Mrp DECIMAL(12,2), Qty DECIMAL(12,2), FreeQty DECIMAL(12,2),
                      Rate DECIMAL(12,4), DiscPercent DECIMAL(5,2), GstPercent DECIMAL(5,2), TaxableAmount DECIMAL(14,2), GstAmount DECIMAL(14,2));
    INSERT @L SELECT * FROM OPENJSON(@Lines) WITH (PoDtlId INT, ItemId INT, BatchNo NVARCHAR(30), MfgDate DATE, ExpiryDate DATE, Mrp DECIMAL(12,2), Qty DECIMAL(12,2),
                                                   FreeQty DECIMAL(12,2), Rate DECIMAL(12,4), DiscPercent DECIMAL(5,2), GstPercent DECIMAL(5,2), TaxableAmount DECIMAL(14,2), GstAmount DECIMAL(14,2));
    BEGIN TRAN;
    IF EXISTS (SELECT 1 FROM dbo.PhGrn WHERE CompanyId = @CompanyId AND SupplierId = @SupplierId AND InvoiceNo = @InvoiceNo AND Status <> 'CANCELLED' AND GrnId <> ISNULL(@Id, 0))
    BEGIN ROLLBACK; SELECT 0 AS Id, N'Invoice ' + @InvoiceNo + N' of this supplier is already entered.' AS Error; RETURN; END;
    IF @PoId IS NOT NULL
    BEGIN
        DECLARE @P TABLE (PoDtlId INT PRIMARY KEY, Pending DECIMAL(12,2));
        INSERT @P SELECT x.PoDtlId, x.Qty - x.ReceivedQty FROM dbo.PhPurchaseOrderDtl x JOIN dbo.PhPurchaseOrder p ON p.PoId = x.PoId
                   WHERE x.PoId = @PoId AND p.SupplierId = @SupplierId AND p.Status IN ('APPROVED', 'PARTIAL');
        IF NOT EXISTS (SELECT 1 FROM @P) BEGIN ROLLBACK; SELECT 0 AS Id, N'The purchase order is not open for this supplier.' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM (SELECT PoDtlId, SUM(Qty) Q FROM @L WHERE PoDtlId IS NOT NULL GROUP BY PoDtlId) g LEFT JOIN @P p ON p.PoDtlId = g.PoDtlId
                    WHERE p.PoDtlId IS NULL OR g.Q > p.Pending)
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Received quantity is more than the quantity pending on the order.' AS Error; RETURN; END;
    END
    ELSE UPDATE @L SET PoDtlId = NULL;

    DECLARE @taxable DECIMAL(14,2) = (SELECT ISNULL(SUM(TaxableAmount), 0) FROM @L), @gst DECIMAL(14,2) = (SELECT ISNULL(SUM(GstAmount), 0) FROM @L);
    DECLARE @gross DECIMAL(14,2) = (SELECT ROUND(ISNULL(SUM(Qty * Rate), 0), 2) FROM @L);
    DECLARE @cgst DECIMAL(14,2) = CASE WHEN @IsInterState = 1 THEN 0 ELSE ROUND(@gst / 2, 2) END;
    DECLARE @sgst DECIMAL(14,2) = CASE WHEN @IsInterState = 1 THEN 0 ELSE @gst - ROUND(@gst / 2, 2) END;
    DECLARE @igst DECIMAL(14,2) = CASE WHEN @IsInterState = 1 THEN @gst ELSE 0 END;
    DECLARE @exact DECIMAL(14,2) = @taxable + @gst + @OtherCharges;
    DECLARE @net DECIMAL(14,2) = ROUND(@exact, 0);
    IF @Id > 0
    BEGIN
        IF ISNULL((SELECT Status FROM dbo.PhGrn WITH (UPDLOCK) WHERE GrnId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'DRAFT'
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a draft GRN can be changed.' AS Error; RETURN; END;
        UPDATE dbo.PhGrn SET GrnDate = @DocDate, SupplierId = @SupplierId, PoId = @PoId, InvoiceNo = @InvoiceNo, InvoiceDate = @InvoiceDate, InvoiceAmount = @InvoiceAmount,
               IsInterState = @IsInterState, OtherCharges = @OtherCharges, Remarks = @Remarks, GrossAmount = @gross, DiscountAmount = @gross - @taxable, TaxableAmount = @taxable,
               CgstAmount = @cgst, SgstAmount = @sgst, IgstAmount = @igst, RoundOff = @net - @exact, NetAmount = @net, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE GrnId = @Id;
        DELETE dbo.PhGrnDtl WHERE GrnId = @Id;
    END
    ELSE
    BEGIN
        INSERT dbo.PhGrn (CompanyId, BranchId, GrnDate, SupplierId, PoId, InvoiceNo, InvoiceDate, InvoiceAmount, IsInterState, OtherCharges, Remarks,
               GrossAmount, DiscountAmount, TaxableAmount, CgstAmount, SgstAmount, IgstAmount, RoundOff, NetAmount, CreatedBy)
        VALUES (@CompanyId, @BranchId, @DocDate, @SupplierId, @PoId, @InvoiceNo, @InvoiceDate, @InvoiceAmount, @IsInterState, @OtherCharges, @Remarks,
               @gross, @gross - @taxable, @taxable, @cgst, @sgst, @igst, @net - @exact, @net, @UserId);
        SET @Id = CAST(SCOPE_IDENTITY() AS INT);
    END
    INSERT dbo.PhGrnDtl (GrnId, PoDtlId, ItemId, BatchNo, MfgDate, ExpiryDate, Mrp, Qty, FreeQty, Rate, DiscPercent, GstPercent, TaxableAmount, GstAmount)
    SELECT @Id, l.PoDtlId, i.ItemId, l.BatchNo, l.MfgDate, l.ExpiryDate, l.Mrp, l.Qty, l.FreeQty, l.Rate, l.DiscPercent, l.GstPercent, l.TaxableAmount, l.GstAmount
      FROM @L l JOIN dbo.PhItem i ON i.ItemId = l.ItemId AND i.CompanyId = @CompanyId;
    UPDATE dbo.PhGrn SET StoreId = @StoreId WHERE GrnId = @Id;
    COMMIT;
    SELECT @Id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
END
GO

-- ── purchase return ──────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPurRet_BatchSearch @CompanyId INT, @BranchId INT, @Q NVARCHAR(200), @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @StoreId = ISNULL(@StoreId, dbo.fn_PhDefaultStore(@BranchId, 'RECEIVE'));
    DECLARE @like NVARCHAR(210) = N'%' + @Q + N'%';
    SELECT TOP 25 b.BatchId, b.ItemId, i.ItemName, df.ShortName FormShort, b.BatchNo, b.ExpiryDate, b.Mrp,
           b.PurchaseRate / i.ConversionQty RatePerUnit, b.GstPercent, s.QtyOnHand Stock, su.UomCode SaleUom, i.ConversionQty, sp.SupplierName
      FROM dbo.PhStoreStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId LEFT JOIN dbo.PhSupplier sp ON sp.SupplierId = b.SupplierId
      LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId
     WHERE s.StoreId = @StoreId AND s.BranchId = @BranchId AND b.CompanyId = @CompanyId AND s.QtyOnHand > 0
       AND (i.ItemName LIKE @like OR b.BatchNo LIKE @like OR g.GenericName LIKE @like OR i.ItemCode = @Q OR i.Barcode = @Q)
     ORDER BY CASE WHEN b.SupplierId = @SupplierId THEN 0 ELSE 1 END, b.ExpiryDate;
END
GO

-- rate and GST always from the batch; quantity checked against stock now (and again when posted). @Lines: [{ BatchId, Qty }]
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPurRet_Save
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @DocDate DATE, @SupplierId INT, @ReasonId INT, @IsInterState BIT, @Remarks NVARCHAR(300) = NULL, @Lines NVARCHAR(MAX), @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @StoreId = ISNULL(@StoreId, dbo.fn_PhDefaultStore(@BranchId, 'RECEIVE'));
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'ANY') = 0
    BEGIN SELECT 0 AS Id, N'Choose a store of this branch to return the goods from.' AS Error; RETURN; END;
    DECLARE @L TABLE (BatchId INT PRIMARY KEY, Qty DECIMAL(14,3), ItemId INT, Rate DECIMAL(12,4), GstPercent DECIMAL(5,2), Stock DECIMAL(14,3), TaxableAmount DECIMAL(14,2), GstAmount DECIMAL(14,2));
    BEGIN TRAN;
    INSERT @L (BatchId, Qty, ItemId, Rate, GstPercent, Stock)
    SELECT l.BatchId, l.Qty, b.ItemId, ROUND(b.PurchaseRate / i.ConversionQty, 4), b.GstPercent, ISNULL(s.QtyOnHand, 0)
      FROM OPENJSON(@Lines) WITH (BatchId INT, Qty DECIMAL(14,3)) l
      LEFT JOIN dbo.PhBatch b ON b.BatchId = l.BatchId AND b.CompanyId = @CompanyId
      LEFT JOIN dbo.PhItem i ON i.ItemId = b.ItemId
      LEFT JOIN dbo.PhStoreStock s ON s.BatchId = b.BatchId AND s.StoreId = @StoreId;
    IF EXISTS (SELECT 1 FROM @L WHERE ItemId IS NULL) BEGIN ROLLBACK; SELECT 0 AS Id, N'A batch was not found.' AS Error; RETURN; END;
    DECLARE @over NVARCHAR(200) = (SELECT TOP 1 N'Return quantity of a batch (' + FORMAT(Qty, '0.##') + N') is more than its stock (' + FORMAT(Stock, '0.##') + N').' FROM @L WHERE Qty > Stock);
    IF @over IS NOT NULL BEGIN ROLLBACK; SELECT 0 AS Id, @over AS Error; RETURN; END;
    UPDATE @L SET TaxableAmount = ROUND(Qty * Rate, 2);
    UPDATE @L SET GstAmount = ROUND(TaxableAmount * GstPercent / 100, 2);
    DECLARE @taxable DECIMAL(14,2) = (SELECT SUM(TaxableAmount) FROM @L), @gst DECIMAL(14,2) = (SELECT SUM(GstAmount) FROM @L);
    DECLARE @net DECIMAL(14,2) = ROUND(@taxable + @gst, 0);
    IF @Id > 0
    BEGIN
        IF ISNULL((SELECT Status FROM dbo.PhPurchaseReturn WITH (UPDLOCK) WHERE ReturnId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'DRAFT'
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a draft return can be changed.' AS Error; RETURN; END;
        UPDATE dbo.PhPurchaseReturn SET ReturnDate = @DocDate, SupplierId = @SupplierId, ReasonId = @ReasonId, IsInterState = @IsInterState, Remarks = @Remarks,
               TaxableAmount = @taxable, GstAmount = @gst, RoundOff = @net - @taxable - @gst, NetAmount = @net, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE ReturnId = @Id;
        DELETE dbo.PhPurchaseReturnDtl WHERE ReturnId = @Id;
    END
    ELSE
    BEGIN
        INSERT dbo.PhPurchaseReturn (CompanyId, BranchId, ReturnDate, SupplierId, ReasonId, IsInterState, Remarks, TaxableAmount, GstAmount, RoundOff, NetAmount, CreatedBy)
        VALUES (@CompanyId, @BranchId, @DocDate, @SupplierId, @ReasonId, @IsInterState, @Remarks, @taxable, @gst, @net - @taxable - @gst, @net, @UserId);
        SET @Id = CAST(SCOPE_IDENTITY() AS INT);
    END
    INSERT dbo.PhPurchaseReturnDtl (ReturnId, BatchId, ItemId, Qty, Rate, GstPercent, TaxableAmount, GstAmount)
    SELECT @Id, BatchId, ItemId, Qty, Rate, GstPercent, TaxableAmount, GstAmount FROM @L;
    UPDATE dbo.PhPurchaseReturn SET StoreId = @StoreId WHERE ReturnId = @Id;
    COMMIT;
    SELECT @Id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Batches @CompanyId INT, @BranchId INT, @ItemId INT, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0 SET @StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL');
    DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
    SELECT b.BatchId, b.ItemId, b.BatchNo, b.ExpiryDate, b.Mrp PackMrp, b.Mrp / i.ConversionQty UnitMrp, b.LandedCost, b.GstPercent, s.QtyOnHand Stock
      FROM dbo.PhStoreStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId
     WHERE s.StoreId = @StoreId AND s.QtyOnHand > 0 AND b.IsBlocked = 0 AND b.ExpiryDate > DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE))
       AND s.ItemId = @ItemId AND EXISTS (SELECT 1 FROM dbo.PhItem i0 WHERE i0.ItemId = @ItemId AND i0.CompanyId = @CompanyId)
     ORDER BY b.ExpiryDate, b.BatchId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_ItemSearch
    @CompanyId INT, @BranchId INT, @Q NVARCHAR(200) = NULL, @GenericId INT = NULL, @ItemId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0 SET @StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL');
    DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
    DECLARE @like NVARCHAR(210) = N'%' + ISNULL(@Q, N'') + N'%', @starts NVARCHAR(210) = ISNULL(@Q, N'') + N'%';
    DECLARE @minExp DATE = DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE));
    SELECT TOP 25 i.ItemId, i.ItemCode, i.ItemName, df.ShortName FormShort, i.Strength, i.PackSize, i.GenericId, g.GenericName, m.ManufacturerName, i.CategoryId,
           i.ScheduleCode, i.PrescriptionRequired RxRequired, sc.RegisterRequired, sc.IsNarcotic, sc.LabelWarning, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
           i.AllowLooseSale, i.IsDiscountAllowed, i.IsReturnable, i.IsHighAlert, i.IsLasa, i.IsColdChain, h.GstPercent, ib.RackNo,
           ISNULL(st.Qty, 0) Stock, st.NearestExpiry, st.PackMrp
      FROM dbo.PhItem i
      JOIN dbo.PhHsn h ON h.HsnId = i.HsnId JOIN dbo.PhDrugSchedule sc ON sc.ScheduleCode = i.ScheduleCode
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
      LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
      LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
      LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
      OUTER APPLY (SELECT SUM(s.QtyOnHand) Qty, MIN(b.ExpiryDate) NearestExpiry,
                          (SELECT TOP 1 b2.Mrp FROM dbo.PhStoreStock s2 JOIN dbo.PhBatch b2 ON b2.BatchId = s2.BatchId
                            WHERE s2.StoreId = @StoreId AND s2.ItemId = i.ItemId AND s2.QtyOnHand > 0 AND b2.IsBlocked = 0
                              AND b2.ExpiryDate > @minExp ORDER BY b2.ExpiryDate, b2.BatchId) PackMrp
                     FROM dbo.PhStoreStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.StoreId = @StoreId AND s.QtyOnHand > 0 AND b.IsBlocked = 0 AND b.ExpiryDate > @minExp AND s.ItemId = i.ItemId) st
     WHERE i.CompanyId = @CompanyId AND i.IsActive = 1
       AND (@GenericId IS NULL OR i.GenericId = @GenericId) AND (@ItemId IS NULL OR i.ItemId = @ItemId)
       AND (@Q IS NULL OR i.ItemName LIKE @like OR g.GenericName LIKE @like OR i.ItemCode = @Q OR i.Barcode = @Q)
     ORDER BY CASE WHEN i.Barcode = @Q OR i.ItemCode = @Q THEN 0 WHEN ISNULL(st.Qty, 0) > 0 THEN 1 ELSE 2 END,
              CASE WHEN i.ItemName LIKE @starts THEN 0 ELSE 1 END, i.ItemName;
END
GO

-- ── save a bill (or hold it) ─────────────────────────────────────────────────────────────────────────────
-- @Lines:    [{ "ItemId", "BatchId" (null = first expiry first, split over batches), "Qty" (sale units), "DiscPercent" }]
-- @Payments: [{ "Method" (CASH|CARD|UPI|NEFT|CHEQUE, checked in EMR.Web), "Amount", "Ref" }]  - empty when held
-- Answers one row: Success, Error, SaleId, SaleNo, ReceiptNo, NetAmount, Change, BalanceDue
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @Hold BIT, @CanDiscount BIT, @CanCredit BIT, @HoldId INT = NULL,
    @CustomerKind VARCHAR(10), @PatientId INT = NULL, @CustomerId INT = NULL, @CustomerName NVARCHAR(4000) = NULL, @Mobile NVARCHAR(4000) = NULL,
    @Email NVARCHAR(4000) = NULL, @Address NVARCHAR(4000) = NULL, @DoctorId INT = NULL, @DoctorName NVARCHAR(4000) = NULL, @DoctorRegNo NVARCHAR(4000) = NULL,
    @RxNo NVARCHAR(4000) = NULL, @RxDate DATE = NULL, @BillDiscPercent DECIMAL(9,4) = 0, @Remarks NVARCHAR(4000) = NULL, @HoldLabel NVARCHAR(4000) = NULL,
    @Lines NVARCHAR(MAX), @Payments NVARCHAR(MAX) = N'[]', @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @StoreId = ISNULL(@StoreId, dbo.fn_PhDefaultStore(@BranchId, 'SELL'));
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'Choose a selling store (counter) of this branch.' AS Error; RETURN; END;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @err NVARCHAR(500);
    DECLARE @enabled BIT = 0, @lic DATE, @ndps NVARCHAR(100), @shelf INT = 30, @neg BIT = 0, @maxDisc DECIMAL(9,4) = 10, @roundOff BIT = 1;
    SELECT TOP 1 @enabled = PharmacyEnabled, @lic = PharmacyDrugLicence20BValidTo, @ndps = PharmacyNdpsLicenceNo, @shelf = PharmacyMinShelfLifeSaleDays,
           @neg = PharmacyAllowNegativeStock, @maxDisc = PharmacyMaxManualDiscountPercent, @roundOff = PharmacyRoundOffBill
      FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
    IF ISNULL(@enabled, 0) = 0 BEGIN SELECT CAST(0 AS BIT) AS Success, N'The pharmacy is not enabled for this branch (Hospital Settings > Pharmacy & Drug Licence).' AS Error; RETURN; END;
    IF @Hold = 0 AND @lic < @today
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The pharmacy''s drug licence expired on ' + FORMAT(@lic, 'dd-MMM-yyyy', 'en-US') + N'; sales are stopped until it is renewed in Hospital Settings.' AS Error; RETURN; END;

    DECLARE @In TABLE (Seq INT PRIMARY KEY, ItemId INT, BatchId INT, Qty DECIMAL(18,6), Disc DECIMAL(9,4));
    INSERT @In SELECT CAST([key] AS INT), JSON_VALUE(value, '$.ItemId'), JSON_VALUE(value, '$.BatchId'), JSON_VALUE(value, '$.Qty'), ISNULL(JSON_VALUE(value, '$.DiscPercent'), 0)
                 FROM OPENJSON(@Lines);
    DECLARE @Pay TABLE (Seq INT PRIMARY KEY, Method VARCHAR(10), Amount DECIMAL(18,2), Ref NVARCHAR(200));
    INSERT @Pay SELECT CAST([key] AS INT), JSON_VALUE(value, '$.Method'), JSON_VALUE(value, '$.Amount'), JSON_VALUE(value, '$.Ref') FROM OPENJSON(ISNULL(@Payments, N'[]'));
    DECLARE @P TABLE (Seq INT IDENTITY PRIMARY KEY, ItemId INT, BatchId INT, Qty DECIMAL(18,6), Disc DECIMAL(9,4), UnitMrp DECIMAL(12,4), UnitPrice DECIMAL(12,4),
                      Amount DECIMAL(18,2), Gst DECIMAL(5,2), Taxable DECIMAL(18,2), GstAmt DECIMAL(18,2), Cost DECIMAL(12,4), Schedule VARCHAR(10), Register BIT, Narcotic BIT, ItemName NVARCHAR(200));

    BEGIN TRY
        BEGIN TRAN;
        -- customer
        DECLARE @priceType VARCHAR(20) = 'WALKIN', @custFound BIT = 0, @custCredit BIT = 0, @custLimit DECIMAL(14,2) = 0;
        IF @CustomerKind = 'PATIENT'
        BEGIN
            DECLARE @pn NVARCHAR(300), @pp NVARCHAR(50), @pa NVARCHAR(500), @pe NVARCHAR(150), @pf BIT = 0;
            SELECT @pf = 1, @pn = LTRIM(RTRIM(ISNULL(FirstName, '') + ' ' + ISNULL(LastName, ''))), @pp = PhoneNumber, @pa = Address, @pe = EmailId
              FROM dbo.PatientMaster WHERE PatientId = @PatientId AND CompanyId = @CompanyId AND IsActive = 1;
            IF @pf = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Pick the patient (UHID).' AS Error; RETURN; END;
            SET @CustomerName = ISNULL(@CustomerName, @pn); SET @Mobile = ISNULL(@Mobile, @pp); SET @Address = ISNULL(@Address, @pa); SET @Email = ISNULL(@Email, @pe);
            SET @CustomerId = NULL;
        END
        ELSE IF @CustomerKind = 'CUSTOMER'
        BEGIN
            DECLARE @cn NVARCHAR(150), @cm NVARCHAR(15), @ce NVARCHAR(150), @ca NVARCHAR(300), @ct VARCHAR(20);
            SELECT @custFound = 1, @cn = CustomerName, @cm = Mobile, @ce = Email, @ca = Address, @ct = CustomerType, @custCredit = CreditAllowed, @custLimit = CreditLimit
              FROM dbo.PhCustomer WHERE CustomerId = @CustomerId AND CompanyId = @CompanyId AND IsActive = 1;
            IF @custFound = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Pick the pharmacy customer.' AS Error; RETURN; END;
            SET @CustomerName = @cn; SET @Mobile = @cm; SET @Email = ISNULL(@Email, @ce); SET @Address = ISNULL(@Address, @ca); SET @PatientId = NULL;
            IF @ct = 'STAFF' SET @priceType = 'STAFF';
        END
        ELSE BEGIN SET @PatientId = NULL; SET @CustomerId = NULL; END;

        -- items and batches: first expiry first, split over batches; a chosen batch is used as it is
        DECLARE @It TABLE (ItemId INT PRIMARY KEY, ItemName NVARCHAR(200), Conv INT, Loose BIT, DiscOk BIT, Schedule VARCHAR(10), Rx BIT, Reg BIT, Narc BIT, Active BIT);
        INSERT @It SELECT i.ItemId, i.ItemName, i.ConversionQty, i.AllowLooseSale, i.IsDiscountAllowed, i.ScheduleCode, i.PrescriptionRequired, sc.RegisterRequired, sc.IsNarcotic, i.IsActive
                     FROM dbo.PhItem i JOIN dbo.PhDrugSchedule sc ON sc.ScheduleCode = i.ScheduleCode
                    WHERE i.CompanyId = @CompanyId AND i.ItemId IN (SELECT ItemId FROM @In);
        DECLARE @minExpiry DATE = DATEADD(DAY, @shelf, @today);
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @In), @item INT, @batch INT, @qty DECIMAL(18,6), @disc DECIMAL(9,4), @left DECIMAL(18,6),
                @name NVARCHAR(200), @conv INT, @loose BIT, @narc BIT, @reg BIT, @sch VARCHAR(10), @active BIT;
        DECLARE @B TABLE (Rn INT IDENTITY PRIMARY KEY, BatchId INT, Stock DECIMAL(14,3), Expiry DATE, Blocked BIT);
        DECLARE @bn INT, @bId INT, @bStock DECIMAL(14,3), @bExp DATE, @bBlocked BIT, @take DECIMAL(18,6), @last INT;
        WHILE @seq IS NOT NULL
        BEGIN
            SELECT @item = ItemId, @batch = BatchId, @qty = Qty, @disc = Disc FROM @In WHERE Seq = @seq;
            SELECT @name = NULL, @active = NULL;
            SELECT @name = ItemName, @conv = Conv, @loose = Loose, @narc = Narc, @reg = Reg, @sch = Schedule, @active = Active FROM @It WHERE ItemId = @item;
            IF @name IS NULL OR @active = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'An item is not in the Item Master or is inactive.' AS Error; RETURN; END;
            IF @loose = 0 AND @qty % @conv <> 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N' is sold in full packs of ' + CAST(@conv AS NVARCHAR(10)) + N' only.' AS Error; RETURN; END;
            IF @narc = 1 AND NULLIF(LTRIM(RTRIM(@ndps)), N'') IS NULL
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N' is a Schedule X / NDPS drug: the branch has no NDPS licence in Hospital Settings.' AS Error; RETURN; END;
            DELETE @B;
            INSERT @B (BatchId, Stock, Expiry, Blocked)
            SELECT b.BatchId, s.QtyOnHand, b.ExpiryDate, b.IsBlocked FROM dbo.PhStoreStock s WITH (UPDLOCK, HOLDLOCK) JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
             WHERE s.StoreId = @StoreId AND s.ItemId = @item AND (@batch IS NULL OR b.BatchId = @batch) ORDER BY b.ExpiryDate, b.BatchId;
            IF @batch IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @B) BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N': the chosen batch has no stock here.' AS Error; RETURN; END;
            SET @left = @qty;
            SET @bn = (SELECT MIN(Rn) FROM @B);
            WHILE @bn IS NOT NULL AND @left > 0
            BEGIN
                SELECT @bId = BatchId, @bStock = Stock, @bExp = Expiry, @bBlocked = Blocked FROM @B WHERE Rn = @bn;
                IF @bBlocked = 1 OR @bExp <= @today
                BEGIN
                    IF @batch IS NOT NULL BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N': the chosen batch is expired or blocked.' AS Error; RETURN; END;
                END
                ELSE IF @bExp <= @minExpiry
                BEGIN
                    IF @batch IS NOT NULL BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N': the chosen batch expires within ' + CAST(@shelf AS NVARCHAR(10)) + N' days and cannot be sold.' AS Error; RETURN; END;
                END
                ELSE
                BEGIN
                    SET @take = CASE WHEN @Hold = 1 OR @batch IS NOT NULL THEN @left
                                     WHEN @left < (CASE WHEN @bStock > 0 THEN @bStock ELSE 0 END) THEN @left
                                     ELSE (CASE WHEN @bStock > 0 THEN @bStock ELSE 0 END) END;
                    IF @take > 0
                    BEGIN
                        INSERT @P (ItemId, BatchId, Qty, Disc, Schedule, Register, Narcotic, ItemName) VALUES (@item, @bId, @take, @disc, @sch, @reg, @narc, @name);
                        SET @left = @left - @take;
                    END
                END
                SET @bn = (SELECT MIN(Rn) FROM @B WHERE Rn > @bn);
            END
            IF @left > 0
            BEGIN
                IF @neg = 0 AND @Hold = 0
                BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Not enough sellable stock of ' + @name + N': short by ' + FORMAT(@left, '0.##') + N'.' AS Error; RETURN; END;
                SET @last = (SELECT MAX(Seq) FROM @P WHERE ItemId = @item);
                IF @last IS NULL BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N' has no sellable batch.' AS Error; RETURN; END;
                UPDATE @P SET Qty = Qty + @left WHERE Seq = @last;
            END
            SET @seq = (SELECT MIN(Seq) FROM @In WHERE Seq > @seq);
        END

        -- prices and amounts (MRP inclusive of GST)
        UPDATE p SET UnitMrp = ROUND(CAST(b.Mrp AS DECIMAL(38,18)) / i.ConversionQty, 4), Cost = b.LandedCost, Gst = b.GstPercent,
                     UnitPrice = pr.UnitPrice,
                     Disc = CASE WHEN it.DiscOk = 1 THEN CASE WHEN p.Disc + @BillDiscPercent > 100 THEN 100 ELSE p.Disc + @BillDiscPercent END ELSE 0 END
          FROM @P p JOIN dbo.PhBatch b ON b.BatchId = p.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId JOIN @It it ON it.ItemId = p.ItemId
          CROSS APPLY dbo.fn_PhSaleUnitPrice(@CompanyId, p.ItemId, p.BatchId, @priceType) pr;
        UPDATE @P SET Amount = ROUND(CAST(Qty AS DECIMAL(38,18)) * UnitPrice * (1 - CAST(Disc AS DECIMAL(38,18)) / 100), 2);
        UPDATE @P SET Taxable = ROUND(CAST(Amount AS DECIMAL(38,18)) * 100 / (100 + Gst), 2);
        UPDATE @P SET GstAmt = Amount - Taxable;
        DECLARE @manualDisc DECIMAL(9,4) = ISNULL((SELECT MAX(Disc) FROM @P), 0);
        IF @Hold = 0 AND @manualDisc > @maxDisc AND @CanDiscount = 0
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Discount ' + FORMAT(@manualDisc, '0.##') + N'% is above the ' + FORMAT(@maxDisc, '0.##') + N'% allowed at the counter; a user with the Discount permission must bill it.' AS Error; RETURN; END;

        -- prescription and register
        IF @Hold = 0 AND EXISTS (SELECT 1 FROM @P p JOIN @It it ON it.ItemId = p.ItemId WHERE it.Rx = 1)
           AND (LTRIM(RTRIM(ISNULL(@DoctorName, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@RxNo, N''))) = N'')
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'An item that needs a prescription is on the bill: enter the doctor and the prescription number.' AS Error; RETURN; END;
        IF @Hold = 0 AND EXISTS (SELECT 1 FROM @P WHERE Register = 1)
           AND (LTRIM(RTRIM(ISNULL(@CustomerName, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@Address, N''))) = N'')
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'A Schedule H1 / X drug is on the bill: the patient''s name and address are needed for the register.' AS Error; RETURN; END;

        DECLARE @mrpAmt DECIMAL(18,2) = (SELECT ROUND(SUM(CAST(Qty AS DECIMAL(38,18)) * UnitMrp), 2) FROM @P);
        DECLARE @lineTotal DECIMAL(18,2) = (SELECT SUM(Amount) FROM @P);
        DECLARE @net DECIMAL(18,2) = CASE WHEN @roundOff = 1 THEN ROUND(@lineTotal, 0) ELSE @lineTotal END;
        DECLARE @taxable DECIMAL(18,2) = (SELECT SUM(Taxable) FROM @P), @gst DECIMAL(18,2) = (SELECT SUM(GstAmt) FROM @P);
        DECLARE @cgst DECIMAL(18,2) = ROUND(@gst / 2, 2);
        DECLARE @sgst DECIMAL(18,2) = @gst - @cgst;
        DECLARE @cost DECIMAL(18,2) = (SELECT ROUND(SUM(CAST(Qty AS DECIMAL(38,18)) * Cost), 2) FROM @P);

        -- payments: full payment, or the balance on credit for a credit customer
        DELETE @Pay WHERE Amount <= 0;
        DECLARE @tendered DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM @Pay), 0);
        DECLARE @nonCash DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM @Pay WHERE Method <> 'CASH'), 0);
        IF @nonCash > @net BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Card / UPI / bank amount is more than the bill.' AS Error; RETURN; END;
        DECLARE @change DECIMAL(18,2) = CASE WHEN @tendered - @net > 0 THEN @tendered - @net ELSE 0 END;
        IF @change > 0 UPDATE @Pay SET Amount = Amount - @change WHERE Seq = (SELECT MIN(Seq) FROM @Pay WHERE Method = 'CASH');   -- change returned from the cash given
        DECLARE @paid DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM @Pay), 0);
        DECLARE @due DECIMAL(18,2) = CASE WHEN @Hold = 1 THEN 0 ELSE @net - @paid END;
        IF @Hold = 0 AND @due > 0
        BEGIN
            IF @custFound = 0 OR @custCredit = 0
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'₹' + FORMAT(@due, '0.00') + N' is not paid. Only a credit customer can take a bill on credit.' AS Error; RETURN; END;
            IF @CanCredit = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'You do not have permission to bill on credit.' AS Error; RETURN; END;
            DECLARE @outstanding DECIMAL(18,2) = ISNULL((SELECT SUM(BalanceDue) FROM dbo.PhSale WHERE CustomerId = @CustomerId AND Status = 'POSTED'), 0);
            IF @outstanding + @due > @custLimit
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Credit limit ₹' + FORMAT(@custLimit, '0.00') + N' would be crossed (outstanding ₹' + FORMAT(@outstanding, '0.00') + N' + this bill ₹' + FORMAT(@due, '0.00') + N').' AS Error; RETURN; END;
        END

        -- header
        DECLARE @saleNo NVARCHAR(40) = NULL, @saleId INT;
        IF @Hold = 0 EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'SALE', @DocDate = @today, @DocNo = @saleNo OUTPUT;
        IF ISNULL(@HoldId, 0) > 0
        BEGIN
            UPDATE dbo.PhSale SET SaleNo = @saleNo, SaleDate = GETDATE(), Status = CASE WHEN @Hold = 1 THEN 'HOLD' ELSE 'POSTED' END, CustomerKind = @CustomerKind, PatientId = @PatientId,
                   CustomerId = @CustomerId, CustomerName = @CustomerName, Mobile = @Mobile, Email = @Email, Address = @Address, DoctorId = @DoctorId, DoctorName = @DoctorName,
                   DoctorRegNo = @DoctorRegNo, RxNo = @RxNo, RxDate = @RxDate, PriceType = @priceType, BillDiscPercent = @BillDiscPercent, MrpAmount = @mrpAmt,
                   DiscountAmount = @mrpAmt - @lineTotal, TaxableAmount = @taxable, CgstAmount = @cgst, SgstAmount = @sgst, RoundOff = @net - @lineTotal, NetAmount = @net,
                   PaidAmount = @paid, BalanceDue = @due, CostAmount = @cost, HoldLabel = @HoldLabel, Remarks = @Remarks, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE SaleId = @HoldId AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status = 'HOLD';
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'The held bill was already finished or discarded.' AS Error; RETURN; END;
            DELETE dbo.PhSaleDtl WHERE SaleId = @HoldId;
            SET @saleId = @HoldId;
        END
        ELSE
        BEGIN
            INSERT dbo.PhSale (CompanyId, BranchId, SaleNo, Status, CustomerKind, PatientId, CustomerId, CustomerName, Mobile, Email, Address,
                   DoctorId, DoctorName, DoctorRegNo, RxNo, RxDate, PriceType, BillDiscPercent, MrpAmount, DiscountAmount, TaxableAmount, CgstAmount, SgstAmount, RoundOff,
                   NetAmount, PaidAmount, BalanceDue, CostAmount, HoldLabel, Remarks, CreatedBy)
            VALUES (@CompanyId, @BranchId, @saleNo, CASE WHEN @Hold = 1 THEN 'HOLD' ELSE 'POSTED' END, @CustomerKind, @PatientId, @CustomerId, @CustomerName, @Mobile, @Email, @Address,
                   @DoctorId, @DoctorName, @DoctorRegNo, @RxNo, @RxDate, @priceType, @BillDiscPercent, @mrpAmt, @mrpAmt - @lineTotal, @taxable, @cgst, @sgst, @net - @lineTotal,
                   @net, @paid, @due, @cost, @HoldLabel, @Remarks, @UserId);
            SET @saleId = CAST(SCOPE_IDENTITY() AS INT);
        END

        UPDATE dbo.PhSale SET StoreId = @StoreId WHERE SaleId = @saleId;
        DECLARE @ps INT = (SELECT MIN(Seq) FROM @P), @dtl INT;
        DECLARE @pItem INT, @pBatch INT, @pQty DECIMAL(18,6), @pReg BIT, @pSch VARCHAR(10);
        WHILE @ps IS NOT NULL
        BEGIN
            INSERT dbo.PhSaleDtl (SaleId, ItemId, BatchId, Qty, UnitMrp, UnitPrice, DiscPercent, Amount, GstPercent, TaxableAmount, GstAmount, UnitCost)
            SELECT @saleId, ItemId, BatchId, Qty, UnitMrp, UnitPrice, Disc, Amount, Gst, Taxable, GstAmt, Cost FROM @P WHERE Seq = @ps;
            SET @dtl = CAST(SCOPE_IDENTITY() AS INT);
            IF @Hold = 0
            BEGIN
                SELECT @pItem = ItemId, @pBatch = BatchId, @pQty = Qty, @pReg = Register, @pSch = Schedule FROM @P WHERE Seq = @ps;
                SET @pQty = -@pQty;
                EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @pBatch, @Qty = @pQty, @DocType = 'SALE', @DocId = @saleId, @DocNo = @saleNo, @UserId = @UserId, @AllowNegative = @neg, @StoreId = @StoreId;
                IF @pReg = 1
                    INSERT dbo.PhScheduleRegister (CompanyId, BranchId, SaleId, SaleDtlId, EntryDate, ScheduleCode, ItemId, BatchId, Qty, PatientName, PatientAddress, PrescriberName, PrescriberRegNo, RxNo, DispensedBy)
                    VALUES (@CompanyId, @BranchId, @saleId, @dtl, GETDATE(), @pSch, @pItem, @pBatch, -@pQty, @CustomerName, @Address, @DoctorName, @DoctorRegNo, @RxNo, @UserId);
            END
            SET @ps = (SELECT MIN(Seq) FROM @P WHERE Seq > @ps);
        END
        IF @Hold = 1
        BEGIN
            COMMIT;
            SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(500)) AS Error, @saleId AS SaleId, CAST(NULL AS NVARCHAR(40)) AS SaleNo, CAST(NULL AS NVARCHAR(50)) AS ReceiptNo,
                   @net AS NetAmount, CAST(0 AS DECIMAL(18,2)) AS Change, CAST(0 AS DECIMAL(18,2)) AS BalanceDue;
            RETURN;
        END

        -- money: like OPD / LAB (PaymentHeader / PaymentDetail, module PHR)
        DECLARE @patient INT = @PatientId;
        IF @patient IS NULL EXEC dbo.usp_Ph_WalkinPatient @CompanyId = @CompanyId, @BranchId = @BranchId, @PatientId = @patient OUTPUT;
        INSERT dbo.PaymentHeader (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, LineDiscountTotal, HeaderDiscountType, HeaderDiscountValue,
               HeaderDiscountAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive, TotalCgstAmount, TotalSgstAmount, TotalIgstAmount, CompanyId, RoundOffAmount)
        VALUES ('PHR', @saleId, @BranchId, @patient, @mrpAmt, @mrpAmt - @lineTotal, 'P', 0, 0, @net, @paid, @due, CASE WHEN @due > 0 THEN 'U' ELSE 'P' END,
               N'Pharmacy bill ' + @saleNo, GETDATE(), @UserId, 1, @cgst, @sgst, 0, @CompanyId, @net - @lineTotal);
        DECLARE @headerId INT = CAST(SCOPE_IDENTITY() AS INT), @receiptNo NVARCHAR(50) = NULL, @pd INT;
        IF @paid > 0
        BEGIN
            EXEC dbo.usp_Receipt_GetNextNo @BranchId = @BranchId, @ReceiptNo = @receiptNo OUTPUT;
            DECLARE @py INT = (SELECT MIN(Seq) FROM @Pay WHERE Amount > 0), @pm VARCHAR(10), @pamt DECIMAL(18,2), @pref NVARCHAR(200);
            WHILE @py IS NOT NULL
            BEGIN
                SELECT @pm = Method, @pamt = Amount, @pref = Ref FROM @Pay WHERE Seq = @py;
                INSERT dbo.PaymentDetail (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, UPIRefNo, CardLast4, ChequeNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo, CompanyId)
                SELECT @headerId, PaymentMethodId, @pamt, @pref, CASE WHEN @pm = 'UPI' THEN @pref END, CASE WHEN @pm = 'CARD' THEN RIGHT(@pref, 4) END, CASE WHEN @pm = 'CHEQUE' THEN @pref END,
                       GETDATE(), N'Pharmacy bill ' + @saleNo, GETDATE(), @UserId, 1, @receiptNo, @CompanyId
                  FROM dbo.PaymentMethodMaster WHERE UPPER(MethodCode) = @pm;
                SET @pd = CAST(SCOPE_IDENTITY() AS INT);
                EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SRCPT', @RefId = @pd, @UserId = @UserId;
                SET @py = (SELECT MIN(Seq) FROM @Pay WHERE Amount > 0 AND Seq > @py);
            END
        END
        EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SALE', @RefId = @saleId, @UserId = @UserId;
        COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(500)) AS Error, @saleId AS SaleId, @saleNo AS SaleNo, @receiptNo AS ReceiptNo, @net AS NetAmount, @change AS Change, @due AS BalanceDue;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── sale return ──────────────────────────────────────────────────────────────────────────────────────────
-- @Lines: [{ "SaleDtlId", "Qty" }] (quantities above zero, checked in EMR.Web). Answers Id, DocNo, Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_SaveReturn
    @CompanyId INT, @BranchId INT, @UserId INT, @SaleId INT, @ReasonId INT, @RefundMode VARCHAR(10), @RefundRef NVARCHAR(4000) = NULL, @Remarks NVARCHAR(4000) = NULL, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @days INT = 7, @loose BIT = 0, @roundOff BIT = 1;
    SELECT TOP 1 @days = PharmacySaleReturnDays, @loose = PharmacyLooseReturnAllowed, @roundOff = PharmacyRoundOffBill FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
    DECLARE @In TABLE (Seq INT PRIMARY KEY, SaleDtlId INT, Qty DECIMAL(18,6));
    INSERT @In SELECT CAST([key] AS INT), JSON_VALUE(value, '$.SaleDtlId'), JSON_VALUE(value, '$.Qty') FROM OPENJSON(@Lines);
    DECLARE @R TABLE (Seq INT PRIMARY KEY, SaleDtlId INT, ItemId INT, BatchId INT, Q DECIMAL(18,6), Amt DECIMAL(18,2), Tax DECIMAL(18,2), G DECIMAL(18,2), UnitCost DECIMAL(12,4));
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @saleDate DATETIME, @balance DECIMAL(18,2);
        DECLARE @saleStore INT = (SELECT StoreId FROM dbo.PhSale WHERE SaleId = @SaleId AND BranchId = @BranchId);
        SELECT @status = Status, @saleDate = SaleDate, @balance = BalanceDue FROM dbo.PhSale WITH (UPDLOCK) WHERE SaleId = @SaleId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF ISNULL(@status, '') <> 'POSTED' BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a saved, not cancelled, bill can take a return.' AS Error; RETURN; END;
        IF DATEADD(DAY, @days, CAST(@saleDate AS DATE)) < @today
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Returns are taken within ' + CAST(@days AS NVARCHAR(10)) + N' days of the bill; this bill is of ' + FORMAT(@saleDate, 'dd-MMM-yyyy', 'en-US') + N'.' AS Error; RETURN; END;

        DECLARE @L TABLE (SaleDtlId INT PRIMARY KEY, ItemId INT, ItemName NVARCHAR(200), ScheduleCode VARCHAR(10), BatchId INT, ExpiryDate DATE, ConversionQty INT,
                          IsReturnable BIT, IsColdChain BIT, Qty DECIMAL(14,3), Amount DECIMAL(14,2), TaxableAmount DECIMAL(14,2), UnitCost DECIMAL(12,4), ReturnedQty DECIMAL(14,3));
        INSERT @L SELECT d.SaleDtlId, d.ItemId, i.ItemName, i.ScheduleCode, d.BatchId, b.ExpiryDate, i.ConversionQty, i.IsReturnable, i.IsColdChain, d.Qty, d.Amount, d.TaxableAmount, d.UnitCost, d.ReturnedQty
                    FROM dbo.PhSaleDtl d WITH (UPDLOCK) JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhBatch b ON b.BatchId = d.BatchId
                   WHERE d.SaleId = @SaleId AND d.SaleDtlId IN (SELECT SaleDtlId FROM @In);
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @In), @dtlId INT, @q DECIMAL(18,6), @found BIT, @nm NVARCHAR(200), @sch VARCHAR(10), @ret BIT, @cold BIT,
                @exp DATE, @lq DECIMAL(14,3), @rq DECIMAL(14,3), @conv INT, @lamt DECIMAL(14,2), @ltax DECIMAL(14,2), @amt DECIMAL(18,2), @tax DECIMAL(18,2);
        WHILE @seq IS NOT NULL
        BEGIN
            SELECT @dtlId = SaleDtlId, @q = Qty FROM @In WHERE Seq = @seq;
            SET @found = 0;
            SELECT @found = 1, @nm = ItemName, @sch = ScheduleCode, @ret = IsReturnable, @cold = IsColdChain, @exp = ExpiryDate, @lq = Qty, @rq = ReturnedQty, @conv = ConversionQty,
                   @lamt = Amount, @ltax = TaxableAmount FROM @L WHERE SaleDtlId = @dtlId;
            IF @found = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'An item is not on this bill.' AS Error; RETURN; END;
            IF @ret = 0 OR @sch IN ('X', 'NDPS') BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N' is not returnable.' AS Error; RETURN; END;
            IF @cold = 1 BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N' is a cold-chain item and cannot be taken back.' AS Error; RETURN; END;
            IF @exp <= @today BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N': the batch has expired.' AS Error; RETURN; END;
            IF @q > @lq - @rq BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N': only ' + FORMAT(@lq - @rq, '0.##') + N' can still be returned.' AS Error; RETURN; END;
            IF @loose = 0 AND @q % @conv <> 0
            BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N': loose / cut strips are not taken back (full packs of ' + CAST(@conv AS NVARCHAR(10)) + N').' AS Error; RETURN; END;
            SET @amt = ROUND(CAST(@lamt AS DECIMAL(38,18)) * @q / @lq, 2);
            SET @tax = ROUND(CAST(@ltax AS DECIMAL(38,18)) * @q / @lq, 2);
            INSERT @R SELECT @seq, @dtlId, ItemId, BatchId, @q, @amt, @tax, @amt - @tax, UnitCost FROM @L WHERE SaleDtlId = @dtlId;
            SET @seq = (SELECT MIN(Seq) FROM @In WHERE Seq > @seq);
        END
        DECLARE @amount DECIMAL(18,2) = (SELECT SUM(Amt) FROM @R), @taxable DECIMAL(18,2) = (SELECT SUM(Tax) FROM @R), @gst DECIMAL(18,2) = (SELECT SUM(G) FROM @R);
        DECLARE @cost DECIMAL(18,2) = (SELECT SUM(ROUND(CAST(UnitCost AS DECIMAL(38,18)) * Q, 2)) FROM @R);
        DECLARE @net DECIMAL(18,2) = CASE WHEN @roundOff = 1 THEN ROUND(@amount, 0) ELSE @amount END;
        DECLARE @adjusted DECIMAL(18,2) = CASE WHEN @net < @balance THEN @net ELSE @balance END;
        DECLARE @refund DECIMAL(18,2) = @net - @adjusted;
        SET @RefundMode = UPPER(@RefundMode);
        IF @refund > 0 AND ISNULL(@RefundMode, '') NOT IN ('CASH', 'CARD', 'UPI', 'NEFT', 'CHEQUE')
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Pick how the money is paid back.' AS Error; RETURN; END;
        IF @refund = 0 SET @RefundMode = 'ADJUST';

        DECLARE @no NVARCHAR(40), @refundId INT = NULL, @cnId INT, @rid INT;
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'SRET', @DocDate = @today, @DocNo = @no OUTPUT;
        IF @refund > 0
        BEGIN
            -- money paid back is recorded like an OPD / LAB partial cancellation: BillCancellation (P) + BillRefund
            INSERT dbo.BillCancellation (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate, CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
            VALUES ('PHR', @SaleId, N'CN-PHR/' + @no, 'P', GETDATE(), @net, 0, N'Sale return ' + @no + CASE WHEN LTRIM(RTRIM(ISNULL(@Remarks, N''))) = N'' THEN N'' ELSE N': ' + @Remarks END, 'C', @UserId, GETDATE(), 1);
            SET @cnId = CAST(SCOPE_IDENTITY() AS INT);
            INSERT dbo.BillRefund (CancellationId, ModuleCode, ModuleRefId, RefundAmount, RefundMode, RefundDate, TransactionRef, Notes, Status, CreatedBy, CreatedDate, IsActive)
            VALUES (@cnId, 'PHR', @SaleId, @refund, @RefundMode, GETDATE(), @RefundRef, N'Pharmacy sale return ' + @no, 'P', @UserId, GETDATE(), 1);
            SET @refundId = CAST(SCOPE_IDENTITY() AS INT);
        END
        INSERT dbo.PhSaleReturn (CompanyId, BranchId, ReturnNo, SaleId, ReasonId, RefundMode, RefundRef, TaxableAmount, GstAmount, RoundOff, NetAmount, AdjustedAmount, RefundAmount, CostAmount, RefundId, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @no, @SaleId, @ReasonId, @RefundMode, @RefundRef, @taxable, @gst, @net - @amount, @net, @adjusted, @refund, @cost, @refundId, @Remarks, @UserId);
        SET @rid = CAST(SCOPE_IDENTITY() AS INT);
        DECLARE @rs INT = (SELECT MIN(Seq) FROM @R), @rBatch INT;
        WHILE @rs IS NOT NULL
        BEGIN
            INSERT dbo.PhSaleReturnDtl (ReturnId, SaleDtlId, ItemId, BatchId, Qty, Amount, TaxableAmount, GstAmount, UnitCost)
            SELECT @rid, SaleDtlId, ItemId, BatchId, Q, Amt, Tax, G, UnitCost FROM @R WHERE Seq = @rs;
            SELECT @dtlId = SaleDtlId, @q = Q, @rBatch = BatchId FROM @R WHERE Seq = @rs;
            UPDATE dbo.PhSaleDtl SET ReturnedQty = ReturnedQty + @q WHERE SaleDtlId = @dtlId;
            EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @rBatch, @Qty = @q, @DocType = 'SRET', @DocId = @rid, @DocNo = @no, @UserId = @UserId, @AllowNegative = 1,
                 @StoreId = @saleStore;
            SET @rs = (SELECT MIN(Seq) FROM @R WHERE Seq > @rs);
        END
        UPDATE dbo.PhSale SET ReturnedAmount = ReturnedAmount + @net, BalanceDue = BalanceDue - @adjusted, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE SaleId = @SaleId;
        UPDATE dbo.PaymentHeader SET BalanceDue = (SELECT BalanceDue FROM dbo.PhSale WHERE SaleId = @SaleId),
               PaymentStatus = CASE WHEN (SELECT BalanceDue FROM dbo.PhSale WHERE SaleId = @SaleId) > 0 THEN 'U' ELSE 'P' END,
               LastModifiedDate = GETDATE(), LastModifiedBy = @UserId
         WHERE RTRIM(ModuleCode) = 'PHR' AND ModuleRefId = @SaleId;
        EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SRET', @RefId = @rid, @UserId = @UserId;
        IF @refundId IS NOT NULL EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SREFUND', @RefId = @refundId, @UserId = @UserId;
        COMMIT;
        SELECT @rid AS Id, @no AS DocNo, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT 0 AS Id, ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── cancellation ─────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @SaleId INT, @Reason NVARCHAR(4000)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @saleDate DATETIME, @createdBy INT, @returned DECIMAL(18,2), @saleNo NVARCHAR(40), @net DECIMAL(18,2);
        DECLARE @saleStore INT = (SELECT StoreId FROM dbo.PhSale WHERE SaleId = @SaleId AND BranchId = @BranchId);
        SELECT @status = Status, @saleDate = SaleDate, @createdBy = CreatedBy, @returned = ReturnedAmount, @saleNo = SaleNo, @net = NetAmount
          FROM dbo.PhSale WITH (UPDLOCK) WHERE SaleId = @SaleId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF ISNULL(@status, '') <> 'POSTED' BEGIN ROLLBACK; SELECT N'Only a saved bill can be cancelled.' AS Error; RETURN; END;
        IF CAST(@saleDate AS DATE) <> CAST(GETDATE() AS DATE) BEGIN ROLLBACK; SELECT N'A bill can be cancelled only on the day it was made; take a sale return instead.' AS Error; RETURN; END;
        IF @returned > 0 BEGIN ROLLBACK; SELECT N'Medicines of this bill were already returned; take a sale return for the rest.' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM dbo.CashClosing WHERE BranchId = @BranchId AND UserId = @createdBy AND Module = 'PHR' AND BusinessDate = CAST(@saleDate AS DATE) AND CutoffAt >= @saleDate)
        BEGIN ROLLBACK; SELECT N'The cashier has already closed the day for this bill; it cannot be cancelled. Take a sale return instead.' AS Error; RETURN; END;

        DECLARE @l TABLE (Rn INT IDENTITY PRIMARY KEY, BatchId INT, Qty DECIMAL(14,3));
        INSERT @l (BatchId, Qty) SELECT BatchId, Qty FROM dbo.PhSaleDtl WHERE SaleId = @SaleId;
        DECLARE @rn INT = (SELECT MIN(Rn) FROM @l), @b INT, @q DECIMAL(14,3);
        WHILE @rn IS NOT NULL
        BEGIN
            SELECT @b = BatchId, @q = Qty FROM @l WHERE Rn = @rn;
            EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @q, @DocType = 'SCAN', @DocId = @SaleId, @DocNo = @saleNo, @UserId = @UserId, @AllowNegative = 1,
                 @StoreId = @saleStore;
            SET @rn = (SELECT MIN(Rn) FROM @l WHERE Rn > @rn);
        END
        INSERT dbo.BillCancellation (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate, CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
        VALUES ('PHR', @SaleId, N'CN-PHR/' + @saleNo, 'F', GETDATE(), @net, 0, @Reason, 'C', @UserId, GETDATE(), 1);
        DECLARE @cnId INT = CAST(SCOPE_IDENTITY() AS INT);
        -- the money taken goes back the way it came (counted as refunds in the cashier's day closing)
        INSERT dbo.BillRefund (CancellationId, ModuleCode, ModuleRefId, RefundAmount, RefundMode, RefundDate, Notes, Status, CreatedBy, CreatedDate, IsActive)
        SELECT @cnId, 'PHR', @SaleId, x.Amount, x.Mode, GETDATE(), N'Pharmacy bill cancelled ' + @saleNo, 'P', @UserId, GETDATE(), 1
          FROM (SELECT UPPER(pm.MethodCode) Mode, SUM(pd.PaidAmount) Amount FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
                  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
                 WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.ModuleRefId = @SaleId AND pd.IsActive = 1 GROUP BY pm.MethodCode) x
         WHERE x.Amount > 0;
        UPDATE dbo.PhSale SET Status = 'CANCELLED', BalanceDue = 0, CancelReason = @Reason, CancelledBy = @UserId, CancelledDate = GETDATE() WHERE SaleId = @SaleId;
        UPDATE dbo.PhScheduleRegister SET IsCancelled = 1 WHERE SaleId = @SaleId;
        UPDATE dbo.PaymentHeader SET BalanceDue = 0, LastModifiedDate = GETDATE(), LastModifiedBy = @UserId WHERE RTRIM(ModuleCode) = 'PHR' AND ModuleRefId = @SaleId;
        EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SCANCEL', @RefId = @SaleId, @UserId = @UserId;
        COMMIT;
        SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- @Lines: [{ "BatchId", "DispatchQty" }] (above zero, from EMR.Web). Answers Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Dispatch @CompanyId INT, @BranchId INT, @UserId INT, @Id INT, @Remarks NVARCHAR(4000) = NULL, @Lines NVARCHAR(MAX), @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @StoreId = ISNULL(@StoreId, dbo.fn_PhDefaultStore(@BranchId, 'RECEIVE'));
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'ANY') = 0 BEGIN SELECT N'Choose the store of this branch the stock is sent from.' AS Error; RETURN; END;
    DECLARE @L TABLE (Seq INT PRIMARY KEY, BatchId INT, DispatchQty DECIMAL(18,6), ItemId INT, UnitCost DECIMAL(12,4), Exp DATE, Blocked BIT);
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @from INT;
        SELECT @status = Status, @from = FromBranchId FROM dbo.PhTransfer WITH (UPDLOCK) WHERE TransferId = @Id AND CompanyId = @CompanyId;
        IF ISNULL(@status, '') <> 'REQUESTED' OR @from <> @BranchId
        BEGIN ROLLBACK; SELECT N'Only an indent asked of this branch, not yet sent, can be dispatched.' AS Error; RETURN; END;
        DECLARE @Req TABLE (ItemId INT PRIMARY KEY, Qty DECIMAL(18,6));
        INSERT @Req SELECT ItemId, SUM(RequestQty) FROM dbo.PhTransferDtl WHERE TransferId = @Id GROUP BY ItemId;
        INSERT @L (Seq, BatchId, DispatchQty, ItemId, UnitCost, Exp, Blocked)
        SELECT CAST(j.[key] AS INT), JSON_VALUE(j.value, '$.BatchId'), JSON_VALUE(j.value, '$.DispatchQty'), b.ItemId, b.LandedCost, b.ExpiryDate, b.IsBlocked
          FROM OPENJSON(@Lines) j LEFT JOIN dbo.PhBatch b ON b.BatchId = JSON_VALUE(j.value, '$.BatchId') AND b.CompanyId = @CompanyId;
        -- per line in order: batch of an item on the indent, then not expired / blocked
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @L), @bad1 BIT, @bad2 BIT;
        WHILE @seq IS NOT NULL
        BEGIN
            SELECT @bad1 = CASE WHEN l.ItemId IS NULL OR r.ItemId IS NULL THEN 1 ELSE 0 END,
                   @bad2 = CASE WHEN l.Blocked = 1 OR l.Exp <= CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END
              FROM @L l LEFT JOIN @Req r ON r.ItemId = l.ItemId WHERE l.Seq = @seq;
            IF @bad1 = 1 BEGIN ROLLBACK; SELECT N'A batch is not of an item on this indent.' AS Error; RETURN; END;
            IF @bad2 = 1 BEGIN ROLLBACK; SELECT N'An expired or blocked batch cannot be sent.' AS Error; RETURN; END;
            SET @seq = (SELECT MIN(Seq) FROM @L WHERE Seq > @seq);
        END
        IF EXISTS (SELECT 1 FROM (SELECT ItemId, SUM(DispatchQty) Q FROM @L GROUP BY ItemId) g JOIN @Req r ON r.ItemId = g.ItemId WHERE g.Q > r.Qty)
        BEGIN ROLLBACK; SELECT N'More is being sent than was asked for.' AS Error; RETURN; END;
        DECLARE @no NVARCHAR(40);
        DECLARE @tdy DATE = CAST(GETDATE() AS DATE);
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'TRF', @DocDate = @tdy, @DocNo = @no OUTPUT;
        -- the request lines stay (one per item); the batches sent are added
        DELETE dbo.PhTransferDtl WHERE TransferId = @Id AND RequestQty = 0;
        DECLARE @b INT, @q DECIMAL(14,3), @mq DECIMAL(14,3);
        SET @seq = (SELECT MIN(Seq) FROM @L);
        WHILE @seq IS NOT NULL
        BEGIN
            INSERT dbo.PhTransferDtl (TransferId, ItemId, RequestQty, BatchId, DispatchQty, UnitCost) SELECT @Id, ItemId, 0, BatchId, DispatchQty, UnitCost FROM @L WHERE Seq = @seq;
            SELECT @b = BatchId, @q = DispatchQty FROM @L WHERE Seq = @seq;
            SET @mq = -@q;
            EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @mq, @DocType = 'TRFO', @DocId = @Id, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0, @StoreId = @StoreId;
            SET @seq = (SELECT MIN(Seq) FROM @L WHERE Seq > @seq);
        END
        UPDATE dbo.PhTransfer SET Status = 'DISPATCHED', FromStoreId = @StoreId, TransferNo = @no, DispatchDate = GETDATE(), DispatchedBy = @UserId, DispatchRemarks = @Remarks,
               CostValue = (SELECT ROUND(SUM(CAST(DispatchQty AS DECIMAL(38,18)) * UnitCost), 2) FROM @L)
         WHERE TransferId = @Id;
        COMMIT;
        SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- @Received: [{ "LineId", "Qty", "Reason" }] - lines not given are taken as received in full. Answers Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Receive @CompanyId INT, @BranchId INT, @UserId INT, @Id INT, @Remarks NVARCHAR(4000) = NULL, @Received NVARCHAR(MAX) = N'[]', @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @StoreId = ISNULL(@StoreId, dbo.fn_PhDefaultStore(@BranchId, 'RECEIVE'));
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'RECEIVE') = 0 BEGIN SELECT N'Choose a store of this branch that receives goods.' AS Error; RETURN; END;
    DECLARE @R TABLE (LineId INT PRIMARY KEY, Qty DECIMAL(18,6), HasQty BIT, Reason NVARCHAR(4000));
    INSERT @R SELECT JSON_VALUE(value, '$.LineId'), JSON_VALUE(value, '$.Qty'), CASE WHEN JSON_VALUE(value, '$.Qty') IS NULL THEN 0 ELSE 1 END,
                     NULLIF(LTRIM(RTRIM(JSON_VALUE(value, '$.Reason'))), N'')
                FROM OPENJSON(ISNULL(@Received, N'[]'));
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @to INT, @no NVARCHAR(40);
        SELECT @status = Status, @to = ToBranchId, @no = TransferNo FROM dbo.PhTransfer WITH (UPDLOCK) WHERE TransferId = @Id AND CompanyId = @CompanyId;
        IF ISNULL(@status, '') <> 'DISPATCHED' OR @to <> @BranchId BEGIN ROLLBACK; SELECT N'Only a transfer sent to this branch can be received.' AS Error; RETURN; END;
        DECLARE @S TABLE (Rn INT IDENTITY PRIMARY KEY, DtlId INT, BatchId INT, Qty DECIMAL(14,3), Cost DECIMAL(12,4));
        INSERT @S (DtlId, BatchId, Qty, Cost) SELECT TransferDtlId, BatchId, DispatchQty, UnitCost FROM dbo.PhTransferDtl WHERE TransferId = @Id AND DispatchQty > 0 ORDER BY TransferDtlId;
        DECLARE @rn INT = (SELECT MIN(Rn) FROM @S), @dtl INT, @b INT, @sent DECIMAL(14,3), @cost DECIMAL(12,4), @got DECIMAL(18,6), @why NVARCHAR(4000), @variance DECIMAL(38,8) = 0;
        WHILE @rn IS NOT NULL
        BEGIN
            SELECT @dtl = DtlId, @b = BatchId, @sent = Qty, @cost = Cost FROM @S WHERE Rn = @rn;
            SELECT @got = @sent, @why = NULL;
            SELECT @got = CASE WHEN HasQty = 1 THEN Qty ELSE @sent END, @why = Reason FROM @R WHERE LineId = @dtl;
            IF @got < 0 OR @got > @sent BEGIN ROLLBACK; SELECT N'Received quantity cannot be more than what was sent.' AS Error; RETURN; END;
            IF @got < @sent AND @why IS NULL BEGIN ROLLBACK; SELECT N'Give the reason for every quantity received short (broken, missing ...).' AS Error; RETURN; END;
            UPDATE dbo.PhTransferDtl SET ReceivedQty = @got, VarianceReason = @why WHERE TransferDtlId = @dtl;
            IF @got > 0 EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @got, @DocType = 'TRFI', @DocId = @Id, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0, @StoreId = @StoreId;
            SET @variance = @variance + (@sent - @got) * @cost;
            SET @rn = (SELECT MIN(Rn) FROM @S WHERE Rn > @rn);
        END
        UPDATE dbo.PhTransfer SET Status = 'RECEIVED', ToStoreId = @StoreId, ReceiveDate = GETDATE(), ReceivedBy = @UserId, ReceiveRemarks = @Remarks, VarianceValue = ROUND(@variance, 2) WHERE TransferId = @Id;
        EXEC dbo.usp_Ph_PostInventoryLedger @Kind = 'TRFLOSS', @RefId = @Id, @UserId = @UserId;
        COMMIT;
        SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- @Lines: [{ "BatchId", "Qty" (change, - out), "Remarks" }] (write-off already made negative in EMR.Web). Answers Id, Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_SaveAdjustment
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @Kind VARCHAR(10), @DocDate DATE, @ReasonId INT, @Remarks NVARCHAR(4000) = NULL, @DisposalMethod NVARCHAR(4000) = NULL,
    @DisposalAgency NVARCHAR(4000) = NULL, @DisposalDate DATE = NULL, @Witness1 NVARCHAR(4000) = NULL, @Witness2 NVARCHAR(4000) = NULL, @CertificateNo NVARCHAR(4000) = NULL, @Lines NVARCHAR(MAX), @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @StoreId = ISNULL(@StoreId, dbo.fn_PhDefaultStore(@BranchId, 'RECEIVE'));
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'ANY') = 0 BEGIN SELECT 0 AS Id, N'Choose a store of this branch.' AS Error; RETURN; END;
    DECLARE @L TABLE (Seq INT PRIMARY KEY, BatchId INT, Qty DECIMAL(18,6), Remarks NVARCHAR(4000), ItemId INT, Cost DECIMAL(12,4), Stock DECIMAL(14,3));
    BEGIN TRY
        BEGIN TRAN;
        INSERT @L (Seq, BatchId, Qty, Remarks, ItemId, Cost, Stock)
        SELECT CAST(j.[key] AS INT), JSON_VALUE(j.value, '$.BatchId'), JSON_VALUE(j.value, '$.Qty'), JSON_VALUE(j.value, '$.Remarks'), b.ItemId, b.LandedCost, ISNULL(s.QtyOnHand, 0)
          FROM OPENJSON(@Lines) j
          LEFT JOIN dbo.PhBatch b ON b.BatchId = JSON_VALUE(j.value, '$.BatchId') AND b.CompanyId = @CompanyId
          LEFT JOIN dbo.PhStoreStock s ON s.BatchId = b.BatchId AND s.StoreId = @StoreId;
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @L), @item INT, @qty DECIMAL(18,6), @stock DECIMAL(14,3);
        WHILE @seq IS NOT NULL
        BEGIN
            SELECT @item = ItemId, @qty = Qty, @stock = Stock FROM @L WHERE Seq = @seq;
            IF @item IS NULL BEGIN ROLLBACK; SELECT 0 AS Id, N'A batch was not found.' AS Error; RETURN; END;
            IF @qty < 0 AND -@qty > @stock
            BEGIN ROLLBACK; SELECT 0 AS Id, N'A batch has only ' + FORMAT(@stock, '0.##') + N' in stock; it cannot go below zero.' AS Error; RETURN; END;
            SET @seq = (SELECT MIN(Seq) FROM @L WHERE Seq > @seq);
        END
        IF @Id > 0
        BEGIN
            IF ISNULL((SELECT Status FROM dbo.PhAdjustment WITH (UPDLOCK) WHERE AdjustmentId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId AND Kind = @Kind), '') <> 'DRAFT'
            BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a draft can be changed.' AS Error; RETURN; END;
            UPDATE dbo.PhAdjustment SET DocDate = @DocDate, ReasonId = @ReasonId, Remarks = @Remarks, DisposalMethod = @DisposalMethod, DisposalAgency = @DisposalAgency, DisposalDate = @DisposalDate,
                   Witness1 = @Witness1, Witness2 = @Witness2, CertificateNo = @CertificateNo, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE AdjustmentId = @Id;
            DELETE dbo.PhAdjustmentDtl WHERE AdjustmentId = @Id;
        END
        ELSE
        BEGIN
            INSERT dbo.PhAdjustment (CompanyId, BranchId, Kind, DocDate, ReasonId, Remarks, DisposalMethod, DisposalAgency, DisposalDate, Witness1, Witness2, CertificateNo, CreatedBy)
            VALUES (@CompanyId, @BranchId, @Kind, @DocDate, @ReasonId, @Remarks, @DisposalMethod, @DisposalAgency, @DisposalDate, @Witness1, @Witness2, @CertificateNo, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        UPDATE dbo.PhAdjustment SET StoreId = @StoreId WHERE AdjustmentId = @Id;
        INSERT dbo.PhAdjustmentDtl (AdjustmentId, BatchId, ItemId, QtyChange, UnitCost, Remarks) SELECT @Id, BatchId, ItemId, Qty, Cost, Remarks FROM @L ORDER BY Seq;
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_AdjustmentAction @CompanyId INT, @BranchId INT, @UserId INT, @Id INT, @Action VARCHAR(10), @Remarks NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @kind VARCHAR(10), @maker INT, @method NVARCHAR(100), @ddate DATE, @w1 NVARCHAR(100), @no NVARCHAR(40);
        SELECT @status = Status, @kind = Kind, @maker = CreatedBy, @method = DisposalMethod, @ddate = DisposalDate, @w1 = Witness1
          FROM dbo.PhAdjustment WITH (UPDLOCK) WHERE AdjustmentId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL BEGIN ROLLBACK; SELECT N'Not found.' AS Error; RETURN; END;
        IF @Action = 'submit'
        BEGIN
            IF @status <> 'DRAFT' BEGIN ROLLBACK; SELECT N'Only a draft can be submitted.' AS Error; RETURN; END;
            IF @kind = 'WRITEOFF' AND (LTRIM(RTRIM(ISNULL(@method, N''))) = N'' OR @ddate IS NULL OR LTRIM(RTRIM(ISNULL(@w1, N''))) = N'')
            BEGIN ROLLBACK; SELECT N'Enter how and when the stock is destroyed and at least one witness before submitting.' AS Error; RETURN; END;
            DECLARE @dt VARCHAR(10) = CASE WHEN @kind = 'WRITEOFF' THEN 'WOF' ELSE 'ADJ' END;
            DECLARE @tdy DATE = CAST(GETDATE() AS DATE);
            EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = @dt, @DocDate = @tdy, @DocNo = @no OUTPUT;
            UPDATE dbo.PhAdjustment SET Status = 'SUBMITTED', DocNo = @no, SubmittedBy = @UserId, SubmittedDate = GETDATE() WHERE AdjustmentId = @Id;
        END
        ELSE IF @Action = 'approve'
        BEGIN
            IF @status <> 'SUBMITTED' BEGIN ROLLBACK; SELECT N'Only a submitted document can be approved.' AS Error; RETURN; END;
            IF @maker = @UserId BEGIN ROLLBACK; SELECT N'You made this document; another user must approve it.' AS Error; RETURN; END;
            SET @no = (SELECT DocNo FROM dbo.PhAdjustment WHERE AdjustmentId = @Id);
            DECLARE @store INT = (SELECT StoreId FROM dbo.PhAdjustment WHERE AdjustmentId = @Id);
            DECLARE @mt VARCHAR(10) = CASE WHEN @kind = 'WRITEOFF' THEN 'WOF' ELSE 'ADJ' END;
            DECLARE @A TABLE (Rn INT IDENTITY PRIMARY KEY, BatchId INT, Qty DECIMAL(14,3), Cost DECIMAL(12,4));
            INSERT @A (BatchId, Qty, Cost) SELECT BatchId, QtyChange, UnitCost FROM dbo.PhAdjustmentDtl WHERE AdjustmentId = @Id ORDER BY AdjustmentDtlId;
            DECLARE @rn INT = (SELECT MIN(Rn) FROM @A), @b INT, @q DECIMAL(14,3);
            WHILE @rn IS NOT NULL
            BEGIN
                SELECT @b = BatchId, @q = Qty FROM @A WHERE Rn = @rn;
                EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @q, @DocType = @mt, @DocId = @Id, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0,
                     @StoreId = @store;
                SET @rn = (SELECT MIN(Rn) FROM @A WHERE Rn > @rn);
            END
            UPDATE dbo.PhAdjustment SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedDate = GETDATE(), ActionRemarks = @Remarks,
                   PlusValue = ISNULL((SELECT ROUND(SUM(CAST(Qty AS DECIMAL(38,18)) * Cost), 2) FROM @A WHERE Qty > 0), 0),
                   MinusValue = ISNULL((SELECT ROUND(-SUM(CAST(Qty AS DECIMAL(38,18)) * Cost), 2) FROM @A WHERE Qty < 0), 0)
             WHERE AdjustmentId = @Id;
            EXEC dbo.usp_Ph_PostInventoryLedger @Kind = 'ADJ', @RefId = @Id, @UserId = @UserId;
        END
        ELSE IF @Action = 'reject'
        BEGIN
            IF @status <> 'SUBMITTED' BEGIN ROLLBACK; SELECT N'Only a submitted document can be rejected.' AS Error; RETURN; END;
            IF @maker = @UserId BEGIN ROLLBACK; SELECT N'You made this document; another user must decide on it.' AS Error; RETURN; END;
            IF LTRIM(RTRIM(ISNULL(@Remarks, N''))) = N'' BEGIN ROLLBACK; SELECT N'Give the reason for rejecting.' AS Error; RETURN; END;
            UPDATE dbo.PhAdjustment SET Status = 'REJECTED', ApprovedBy = @UserId, ApprovedDate = GETDATE(), ActionRemarks = @Remarks WHERE AdjustmentId = @Id;
        END
        ELSE IF @Action = 'cancel'
        BEGIN
            IF @status NOT IN ('DRAFT', 'SUBMITTED') BEGIN ROLLBACK; SELECT N'Only a draft or submitted document can be cancelled.' AS Error; RETURN; END;
            UPDATE dbo.PhAdjustment SET Status = 'CANCELLED', ActionRemarks = ISNULL(@Remarks, ActionRemarks), ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE AdjustmentId = @Id;
        END
        ELSE BEGIN ROLLBACK; SELECT N'Unknown action.' AS Error; RETURN; END;
        COMMIT;
        SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- one adjustment: 1 header (no row = not found), 2 lines
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_GetAdjustment @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhAdjustment WHERE AdjustmentId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId) SET @Id = -1;
    SELECT a.AdjustmentId Id, a.StoreId, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = a.StoreId) StoreName, a.Kind, a.DocNo, a.DocDate, a.Status, a.ReasonId, r.ReasonName, a.Remarks, a.ActionRemarks, a.DisposalMethod, a.DisposalAgency,
           a.DisposalDate, a.Witness1, a.Witness2, a.CertificateNo, a.PlusValue, a.MinusValue, a.CreatedBy,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = a.CreatedBy) CreatedByName, a.CreatedDate,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = a.ApprovedBy) ApprovedByName, a.ApprovedDate
      FROM dbo.PhAdjustment a LEFT JOIN dbo.PhReason r ON r.ReasonId = a.ReasonId WHERE a.AdjustmentId = @Id;
    SELECT x.AdjustmentDtlId LineId, x.ItemId, i.ItemName, i.ItemCode, df.ShortName FormShort, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
           x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.QtyChange Qty, x.UnitCost, x.Remarks, ISNULL(s.QtyOnHand, 0) Stock
      FROM dbo.PhAdjustmentDtl x JOIN dbo.PhItem i ON i.ItemId = x.ItemId JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
      LEFT JOIN dbo.PhStoreStock s ON s.BatchId = x.BatchId AND s.StoreId = (SELECT ISNULL(a.StoreId, dbo.fn_PhDefaultStore(a.BranchId, 'RECEIVE')) FROM dbo.PhAdjustment a WHERE a.AdjustmentId = @Id) WHERE x.AdjustmentId = @Id ORDER BY x.AdjustmentDtlId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_CreateCount
    @CompanyId INT, @BranchId INT, @UserId INT, @RackPrefix NVARCHAR(30) = NULL, @CategoryId INT = NULL, @IncludeZero BIT = 0, @Remarks NVARCHAR(4000) = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @StoreId = ISNULL(@StoreId, dbo.fn_PhDefaultStore(@BranchId, 'RECEIVE'));
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'ANY') = 0 BEGIN SELECT 0 AS Id, N'Choose a store of this branch to count.' AS Error; RETURN; END;
    BEGIN TRY
        BEGIN TRAN;
        IF EXISTS (SELECT 1 FROM dbo.PhStockCount WHERE BranchId = @BranchId AND ISNULL(StoreId, dbo.fn_PhDefaultStore(BranchId, 'RECEIVE')) = @StoreId AND Status IN ('COUNTING', 'SUBMITTED'))
        BEGIN ROLLBACK; SELECT 0 AS Id, N'A verification of this store is still open; finish or cancel it first.' AS Error; RETURN; END;
        SET @RackPrefix = UPPER(NULLIF(LTRIM(RTRIM(@RackPrefix)), N''));
        DECLARE @scope NVARCHAR(400) = CONCAT_WS(N' · ',
            CASE WHEN @RackPrefix IS NOT NULL THEN N'racks ' + @RackPrefix + N'*' END,
            CASE WHEN @CategoryId IS NOT NULL THEN N'category ' + ISNULL((SELECT CategoryName FROM dbo.PhCategory WHERE CategoryId = @CategoryId), N'') END,
            CASE WHEN @IncludeZero = 1 THEN N'including zero stock' END);
        DECLARE @no NVARCHAR(40), @id INT;
        DECLARE @tdy DATE = CAST(GETDATE() AS DATE);
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'PCNT', @DocDate = @tdy, @DocNo = @no OUTPUT;
        INSERT dbo.PhStockCount (CompanyId, BranchId, StoreId, CountNo, FrozenAt, Scope, Status, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @StoreId, @no, GETDATE(), CASE WHEN LEN(@scope) = 0 THEN N'All stock' ELSE @scope END, 'COUNTING', @Remarks, @UserId);
        SET @id = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.PhStockCountDtl (StockCountId, BatchId, ItemId, RackNo, SystemQty, UnitCost)
        SELECT @id, s.BatchId, s.ItemId, ib.RackNo, s.QtyOnHand, b.LandedCost
          FROM dbo.PhStoreStock s WITH (HOLDLOCK) JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = s.ItemId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
          LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = s.ItemId AND ib.BranchId = s.BranchId
         WHERE s.StoreId = @StoreId AND b.CompanyId = @CompanyId AND (@IncludeZero = 1 OR s.QtyOnHand <> 0)
           AND (@RackPrefix IS NULL OR ib.RackNo LIKE @RackPrefix + '%') AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId);
        IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Nothing in stock matches; widen the selection.' AS Error; RETURN; END;
        COMMIT;
        SELECT @id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_CountAction @CompanyId INT, @BranchId INT, @UserId INT, @Id INT, @Action VARCHAR(10), @Remarks NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @maker INT, @no NVARCHAR(40), @uncounted INT, @store INT = (SELECT StoreId FROM dbo.PhStockCount WHERE StockCountId = @Id);
        SELECT @status = Status, @maker = CreatedBy, @no = CountNo,
               @uncounted = (SELECT COUNT(*) FROM dbo.PhStockCountDtl d WHERE d.StockCountId = c.StockCountId AND d.CountedQty IS NULL)
          FROM dbo.PhStockCount c WITH (UPDLOCK) WHERE StockCountId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL BEGIN ROLLBACK; SELECT N'Not found.' AS Error; RETURN; END;
        IF @Action = 'submit'
        BEGIN
            IF @status <> 'COUNTING' BEGIN ROLLBACK; SELECT N'Only an open verification can be submitted.' AS Error; RETURN; END;
            IF @uncounted > 0 BEGIN ROLLBACK; SELECT CAST(@uncounted AS NVARCHAR(10)) + N' batch(es) are not counted yet. Enter a count for every line (0 if none found).' AS Error; RETURN; END;
            UPDATE dbo.PhStockCount SET Status = 'SUBMITTED', SubmittedBy = @UserId, SubmittedDate = GETDATE() WHERE StockCountId = @Id;
        END
        ELSE IF @Action = 'approve'
        BEGIN
            IF @status <> 'SUBMITTED' BEGIN ROLLBACK; SELECT N'Only a submitted verification can be approved.' AS Error; RETURN; END;
            IF @maker = @UserId BEGIN ROLLBACK; SELECT N'You started this verification; another user must approve it.' AS Error; RETURN; END;
            -- the difference found is applied to today's stock (sales after the freeze are kept)
            DECLARE @D TABLE (Rn INT IDENTITY PRIMARY KEY, BatchId INT, ItemId INT, Diff DECIMAL(14,3), Cost DECIMAL(12,4));
            INSERT @D (BatchId, ItemId, Diff, Cost) SELECT BatchId, ItemId, CountedQty - SystemQty, UnitCost FROM dbo.PhStockCountDtl
             WHERE StockCountId = @Id AND CountedQty IS NOT NULL AND CountedQty <> SystemQty ORDER BY StockCountDtlId;
            DECLARE @adjId INT = NULL;
            IF EXISTS (SELECT 1 FROM @D)
            BEGIN
                DECLARE @reason INT = (SELECT TOP 1 ReasonId FROM dbo.PhReason WHERE CompanyId = @CompanyId AND ReasonType = 'ADJUSTMENT' AND ReasonName LIKE '%count%' ORDER BY SortOrder);
                INSERT dbo.PhAdjustment (CompanyId, BranchId, StoreId, Kind, DocNo, DocDate, ReasonId, Status, Remarks, StockCountId, CreatedBy, SubmittedBy, SubmittedDate)
                VALUES (@CompanyId, @BranchId, @store, 'PHYSICAL', @no, CAST(GETDATE() AS DATE), @reason, 'SUBMITTED', N'Physical stock verification ' + @no, @Id, @maker, @maker, GETDATE());
                SET @adjId = CAST(SCOPE_IDENTITY() AS INT);
                INSERT dbo.PhAdjustmentDtl (AdjustmentId, BatchId, ItemId, QtyChange, UnitCost) SELECT @adjId, BatchId, ItemId, Diff, Cost FROM @D ORDER BY Rn;
                DECLARE @rn INT = (SELECT MIN(Rn) FROM @D), @b INT, @q DECIMAL(14,3);
                WHILE @rn IS NOT NULL
                BEGIN
                    SELECT @b = BatchId, @q = Diff FROM @D WHERE Rn = @rn;
                    EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @q, @DocType = 'PCNT', @DocId = @Id, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0,
                         @StoreId = @store;
                    SET @rn = (SELECT MIN(Rn) FROM @D WHERE Rn > @rn);
                END
                UPDATE dbo.PhAdjustment SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedDate = GETDATE(),
                       PlusValue = ISNULL((SELECT ROUND(SUM(CAST(Diff AS DECIMAL(38,18)) * Cost), 2) FROM @D WHERE Diff > 0), 0),
                       MinusValue = ISNULL((SELECT ROUND(-SUM(CAST(Diff AS DECIMAL(38,18)) * Cost), 2) FROM @D WHERE Diff < 0), 0)
                 WHERE AdjustmentId = @adjId;
                EXEC dbo.usp_Ph_PostInventoryLedger @Kind = 'ADJ', @RefId = @adjId, @UserId = @UserId;
            END
            UPDATE dbo.PhStockCount SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedDate = GETDATE(), ActionRemarks = @Remarks, AdjustmentId = @adjId WHERE StockCountId = @Id;
        END
        ELSE IF @Action = 'reject'
        BEGIN
            IF @status <> 'SUBMITTED' BEGIN ROLLBACK; SELECT N'Only a submitted verification can be sent back.' AS Error; RETURN; END;
            IF LTRIM(RTRIM(ISNULL(@Remarks, N''))) = N'' BEGIN ROLLBACK; SELECT N'Say what is to be recounted.' AS Error; RETURN; END;
            UPDATE dbo.PhStockCount SET Status = 'COUNTING', ActionRemarks = @Remarks WHERE StockCountId = @Id;
        END
        ELSE IF @Action = 'cancel'
        BEGIN
            IF @status NOT IN ('COUNTING', 'SUBMITTED') BEGIN ROLLBACK; SELECT N'Only an open verification can be cancelled.' AS Error; RETURN; END;
            UPDATE dbo.PhStockCount SET Status = 'CANCELLED', ActionRemarks = @Remarks WHERE StockCountId = @Id;
        END
        ELSE BEGIN ROLLBACK; SELECT N'Unknown action.' AS Error; RETURN; END;
        COMMIT;
        SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- one verification: 1 header (no row = not found), 2 lines
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_GetCount @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhStockCount WHERE StockCountId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId) SET @Id = -1;
    SELECT c.StockCountId Id, c.StoreId, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = c.StoreId) StoreName, 'COUNT' Kind, c.CountNo DocNo, c.FrozenAt DocDate, c.FrozenAt, c.Scope, c.Status, c.Remarks, c.ActionRemarks, c.AdjustmentId,
           c.CreatedBy, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.CreatedBy) CreatedByName, c.CreatedDate,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.ApprovedBy) ApprovedByName, c.ApprovedDate
      FROM dbo.PhStockCount c WHERE c.StockCountId = @Id;
    SELECT x.StockCountDtlId LineId, x.ItemId, i.ItemName, i.ItemCode, df.ShortName FormShort, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
           x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.RackNo, x.SystemQty, x.CountedQty, x.UnitCost, x.Remarks, ISNULL(s.QtyOnHand, 0) Stock
      FROM dbo.PhStockCountDtl x JOIN dbo.PhItem i ON i.ItemId = x.ItemId JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
      LEFT JOIN dbo.PhStoreStock s ON s.BatchId = x.BatchId AND s.StoreId = (SELECT ISNULL(k.StoreId, dbo.fn_PhDefaultStore(k.BranchId, 'RECEIVE')) FROM dbo.PhStockCount k WHERE k.StockCountId = @Id)
     WHERE x.StockCountId = @Id ORDER BY ISNULL(x.RackNo, 'zzz'), i.ItemName, b.ExpiryDate;
END
GO

-- @Filter: in-stock (default) | expired | near (90 days) | zero | all
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Stock @CompanyId INT, @BranchId INT, @Search NVARCHAR(200) = NULL, @CategoryId INT = NULL, @Filter VARCHAR(10) = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(210) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE);
    SELECT BatchId, ItemId, ItemCode, ItemName, FormShort, GenericName, ManufacturerName, CategoryName, ScheduleCode, RackNo, BatchNo, ExpiryDate, Mrp, LandedCost, GstPercent,
           Stock, SaleUom, PurchaseUom, ConversionQty, IsBlocked, SupplierName
      FROM (SELECT * FROM dbo.fn_PhStockRows(@CompanyId, @BranchId) WHERE @StoreId IS NULL
            UNION ALL SELECT * FROM dbo.fn_PhStoreStockRows(@CompanyId, @BranchId, @StoreId) WHERE @StoreId IS NOT NULL) x
     WHERE (   (@Filter = 'expired' AND x.QtyOnHand > 0 AND x.ExpiryDate <= @today)
            OR (@Filter = 'near'    AND x.QtyOnHand > 0 AND x.ExpiryDate > @today AND x.ExpiryDate <= DATEADD(DAY, 90, @today))
            OR (@Filter = 'zero'    AND ISNULL(x.QtyOnHand, 0) = 0 AND x.StockBatchId IS NOT NULL)
            OR (@Filter = 'all'     AND x.StockBatchId IS NOT NULL)
            OR (ISNULL(@Filter, '') NOT IN ('expired', 'near', 'zero', 'all') AND x.QtyOnHand > 0))
       AND (@Search IS NULL OR x.ItemName LIKE @like OR x.ItemCode = @Search OR x.BatchNo LIKE @like OR x.GenericName LIKE @like OR x.Barcode = @Search)
       AND (@CategoryId IS NULL OR x.CategoryId = @CategoryId OR x.ParentCategoryId = @CategoryId)
     ORDER BY x.ItemName, x.ExpiryDate;
END
GO

-- one document: 1 header (no row = not found), 2 lines, 3 item details of the lines
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_Get @Kind VARCHAR(10), @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Kind = 'indent'
    BEGIN
        SELECT d.IndentId Id, d.IndentNo DocNo, d.IndentDate DocDate, d.Status, d.Priority, d.Remarks, d.ActionRemarks,
               cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.ApprovedDate
          FROM dbo.PhPurchaseIndent d
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.CreatedBy) cb
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.ApprovedBy) ab
         WHERE d.IndentId = @Id AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId;
        SELECT x.IndentDtlId LineId, x.ItemId, x.Qty, x.Remarks, x.StockAtIndent Stock FROM dbo.PhPurchaseIndentDtl x
          JOIN dbo.PhPurchaseIndent d ON d.IndentId = x.IndentId AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId
         WHERE x.IndentId = @Id ORDER BY x.IndentDtlId;
        SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f WHERE f.ItemId IN (SELECT ItemId FROM dbo.PhPurchaseIndentDtl WHERE IndentId = @Id);
    END
    ELSE IF @Kind = 'po'
    BEGIN
        SELECT d.PoId Id, d.PoNo DocNo, d.PoDate DocDate, d.Status, d.SupplierId, s.SupplierName, d.IndentId RefId, i.IndentNo RefNo,
               d.ExpectedDate, d.IsInterState, d.IsDirect, d.InvoiceNo, d.InvoiceDate, ISNULL(d.InvoiceAmount, 0) InvoiceAmount, d.OtherCharges, d.Terms, d.Remarks,
               d.TaxableAmount, d.GstAmount, d.NetAmount, d.EmailedTo, d.EmailedDate, cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.ApprovedDate
          FROM dbo.PhPurchaseOrder d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhPurchaseIndent i ON i.IndentId = d.IndentId
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.CreatedBy) cb
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.ApprovedBy) ab
         WHERE d.PoId = @Id AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId;
        SELECT x.PoDtlId LineId, x.ItemId, x.Qty, x.FreeQty, x.Rate, x.DiscPercent, x.GstPercent, x.TaxableAmount, x.GstAmount, x.ReceivedQty, x.Qty - x.ReceivedQty PendingQty,
               x.BatchNo, x.ExpiryDate, ISNULL(x.Mrp, 0) Mrp
          FROM dbo.PhPurchaseOrderDtl x JOIN dbo.PhPurchaseOrder d ON d.PoId = x.PoId AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId
         WHERE x.PoId = @Id ORDER BY x.PoDtlId;
        SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f WHERE f.ItemId IN (SELECT ItemId FROM dbo.PhPurchaseOrderDtl WHERE PoId = @Id);
    END
    ELSE IF @Kind = 'grn'
    BEGIN
        SELECT d.GrnId Id, d.GrnNo DocNo, d.GrnDate DocDate, d.Status, d.StoreId, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = d.StoreId) StoreName, d.SupplierId, s.SupplierName, d.PoId RefId, po.PoNo RefNo,
               d.InvoiceNo, d.InvoiceDate, d.InvoiceAmount, d.IsInterState, d.OtherCharges, d.Remarks, d.TaxableAmount, d.CgstAmount + d.SgstAmount + d.IgstAmount GstAmount,
               d.DiscountAmount, d.RoundOff, d.NetAmount, d.DueDate, d.AttachmentPath, d.AttachmentName, cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.PostedDate ApprovedDate
          FROM dbo.PhGrn d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhPurchaseOrder po ON po.PoId = d.PoId
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.CreatedBy) cb
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.PostedBy) ab
         WHERE d.GrnId = @Id AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId;
        SELECT x.GrnDtlId LineId, x.ItemId, x.PoDtlId, x.BatchNo, x.MfgDate, x.ExpiryDate, x.Mrp, x.Qty, x.FreeQty, x.Rate, x.DiscPercent, x.GstPercent, x.TaxableAmount, x.GstAmount,
               ISNULL(pd.Qty - pd.ReceivedQty, 0) PendingQty
          FROM dbo.PhGrnDtl x JOIN dbo.PhGrn d ON d.GrnId = x.GrnId AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId
          LEFT JOIN dbo.PhPurchaseOrderDtl pd ON pd.PoDtlId = x.PoDtlId
         WHERE x.GrnId = @Id ORDER BY x.GrnDtlId;
        SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f WHERE f.ItemId IN (SELECT ItemId FROM dbo.PhGrnDtl WHERE GrnId = @Id);
    END
    ELSE IF @Kind = 'return'
    BEGIN
        SELECT d.ReturnId Id, d.ReturnNo DocNo, d.ReturnDate DocDate, d.Status, d.StoreId, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = d.StoreId) StoreName, d.SupplierId, s.SupplierName, d.ReasonId, d.IsInterState,
               d.Remarks, d.TaxableAmount, d.GstAmount, d.RoundOff, d.NetAmount, cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.PostedDate ApprovedDate
          FROM dbo.PhPurchaseReturn d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.CreatedBy) cb
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.PostedBy) ab
         WHERE d.ReturnId = @Id AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId;
        SELECT x.ReturnDtlId LineId, x.ItemId, x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.Qty, x.Rate, x.GstPercent, x.TaxableAmount, x.GstAmount,
               ISNULL((SELECT QtyOnHand FROM dbo.PhStoreStock st WHERE st.BatchId = x.BatchId AND st.StoreId = (SELECT ISNULL(r.StoreId, dbo.fn_PhDefaultStore(r.BranchId, 'RECEIVE')) FROM dbo.PhPurchaseReturn r WHERE r.ReturnId = @Id)), 0) Stock
          FROM dbo.PhPurchaseReturnDtl x JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
          JOIN dbo.PhPurchaseReturn d ON d.ReturnId = x.ReturnId AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId
         WHERE x.ReturnId = @Id ORDER BY x.ReturnDtlId;
        SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f WHERE f.ItemId IN (SELECT ItemId FROM dbo.PhPurchaseReturnDtl WHERE ReturnId = @Id);
    END
    ELSE IF @Kind = 'payment'
    BEGIN
        SELECT d.PaymentId Id, d.PaymentNo DocNo, d.PaymentDate DocDate, d.Status, d.SupplierId, s.SupplierName,
               d.PaymentMode Priority, d.ReferenceNo InvoiceNo, d.Remarks, d.Amount NetAmount, cb.N CreatedByName, d.CreatedDate
          FROM dbo.PhSupplierPayment d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.CreatedBy) cb
         WHERE d.PaymentId = @Id AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId;
        SELECT a.AllocId LineId, 0 ItemId, g.GrnNo ItemName, g.InvoiceNo ItemCode, g.InvoiceDate ExpiryDate, g.NetAmount Mrp, a.Amount TaxableAmount
          FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhGrn g ON g.GrnId = a.GrnId
          JOIN dbo.PhSupplierPayment d ON d.PaymentId = a.PaymentId AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId
         WHERE a.PaymentId = @Id ORDER BY a.AllocId;
        SELECT TOP 0 f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f;
    END
    ELSE THROW 55300, 'Unknown purchase document.', 1;
END
GO

-- one transfer: 1 header (no row = not found), 2 lines
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_GetTransfer @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from INT = (SELECT FromBranchId FROM dbo.PhTransfer t
                          WHERE t.TransferId = @Id AND t.CompanyId = @CompanyId AND (t.ToBranchId = @BranchId OR (t.FromBranchId = @BranchId AND t.Status <> 'DRAFT')));
    IF @from IS NULL SET @Id = -1;
    SELECT t.TransferId Id, 'TRANSFER' Kind, t.RequestNo DocNo, ISNULL(t.RequestDate, t.CreatedDate) DocDate, t.Status, t.Remarks, t.FromBranchId, t.ToBranchId,
           fb.BranchName FromBranch, tb.BranchName ToBranch, t.TransferNo, t.DispatchDate, t.ReceiveDate, t.Priority, t.IsOtherGstin, t.DispatchRemarks, t.ReceiveRemarks, t.CostValue, t.VarianceValue,
           t.FromStoreId, t.ToStoreId, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = t.FromStoreId) FromStore, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = t.ToStoreId) ToStore,
           t.CreatedBy, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = t.CreatedBy) CreatedByName, t.CreatedDate
      FROM dbo.PhTransfer t JOIN dbo.Branchmaster fb ON fb.BranchID = t.FromBranchId JOIN dbo.Branchmaster tb ON tb.BranchID = t.ToBranchId
     WHERE t.TransferId = @Id;
    SELECT x.TransferDtlId LineId, x.ItemId, i.ItemName, i.ItemCode, df.ShortName FormShort, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
           x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.RequestQty Qty, x.DispatchQty, x.ReceivedQty, x.UnitCost, x.VarianceReason Remarks,
           ISNULL((SELECT SUM(QtyOnHand) FROM dbo.PhStock s WHERE s.BranchId = @from AND s.ItemId = x.ItemId), 0) Stock
      FROM dbo.PhTransferDtl x JOIN dbo.PhItem i ON i.ItemId = x.ItemId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
      LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId LEFT JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
     WHERE x.TransferId = @Id ORDER BY i.ItemName, b.ExpiryDate;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_BatchSearch @CompanyId INT, @BranchId INT, @Q NVARCHAR(200), @ExpiredOnly BIT = 0, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @like NVARCHAR(210) = N'%' + @Q + N'%';
    SELECT TOP 30 BatchId, ItemId, ItemCode, ItemName, FormShort, GenericName, ManufacturerName, CategoryName, ScheduleCode, RackNo, BatchNo, ExpiryDate, Mrp, LandedCost, GstPercent,
           Stock, SaleUom, PurchaseUom, ConversionQty, IsBlocked, SupplierName
      FROM (SELECT * FROM dbo.fn_PhStockRows(@CompanyId, @BranchId) WHERE @StoreId IS NULL
            UNION ALL SELECT * FROM dbo.fn_PhStoreStockRows(@CompanyId, @BranchId, @StoreId) WHERE @StoreId IS NOT NULL) x
     WHERE x.QtyOnHand > 0 AND (x.ItemName LIKE @like OR x.ItemCode = @Q OR x.BatchNo LIKE @like OR x.Barcode = @Q)
       AND (@ExpiredOnly = 0 OR x.ExpiryDate <= DATEADD(DAY, 90, CAST(GETDATE() AS DATE)))
     ORDER BY x.ItemName, x.ExpiryDate;
END
GO


-- ── seed standard sample data for a company (and number series for a branch) ─────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Pharmacy_EnsureMasters @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhUom WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhUom (CompanyId, UomCode, UomName, SortOrder)
        SELECT @CompanyId, c, n, o FROM (VALUES ('TAB',N'Tablet',10),('CAP',N'Capsule',20),('STRIP',N'Strip',30),('BOX',N'Box',40),
            ('BTL',N'Bottle',50),('VIAL',N'Vial',60),('AMP',N'Ampoule',70),('TUBE',N'Tube',80),('SACHET',N'Sachet',90),
            ('NOS',N'Numbers (each)',100),('PAIR',N'Pair',110),('PKT',N'Packet',120),('ROLL',N'Roll',130),('ML',N'Millilitre',140)) v (c, n, o);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhDosageForm WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhDosageForm (CompanyId, DosageFormName, ShortName, SortOrder)
        SELECT @CompanyId, n, s, o FROM (VALUES (N'Tablet','TAB',10),(N'Capsule','CAP',20),(N'Syrup','SYP',30),(N'Suspension','SUSP',40),
            (N'Injection','INJ',50),(N'Infusion / IV Fluid','INF',60),(N'Ointment','OINT',70),(N'Cream','CRM',80),(N'Gel','GEL',90),
            (N'Drops','DRP',100),(N'Inhaler','INH',110),(N'Respules / Nebuliser','RESP',120),(N'Powder / Sachet','PWD',130),
            (N'Lotion','LOT',140),(N'Spray','SPR',150),(N'Suppository','SUPP',160),(N'Surgical / Device','SURG',170)) v (n, s, o);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhCategory WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhCategory (CompanyId, CategoryName, SortOrder)
        SELECT @CompanyId, n, o FROM (VALUES (N'Drugs / Medicines',10),(N'Surgical',20),(N'Consumables',30),(N'Implants',40),
            (N'OTC / FMCG',50),(N'Nutrition & Supplements',60),(N'Cosmetics & Personal Care',70),(N'Medical Devices',80)) v (n, o);
        DECLARE @drug INT = (SELECT CategoryId FROM dbo.PhCategory WHERE CompanyId = @CompanyId AND CategoryName = N'Drugs / Medicines');
        INSERT dbo.PhCategory (CompanyId, CategoryName, ParentCategoryId, SortOrder)
        SELECT @CompanyId, n, @drug, o FROM (VALUES (N'Antibiotics',11),(N'Analgesics & Antipyretics',12),(N'Antacids & PPIs',13),
            (N'Antidiabetics',14),(N'Insulins',15),(N'Cardiac & Antihypertensives',16),(N'Respiratory',17),(N'IV Fluids',18),
            (N'Vitamins & Minerals',19),(N'Antiemetics',20)) v (n, o);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhHsn WHERE CompanyId = @CompanyId)
    BEGIN
        -- GST rates as revised from 22-Sep-2025 (most medicines and medical goods 12% -> 5%). Check with your CA.
        INSERT dbo.PhHsn (CompanyId, HsnCode, Description, GstPercent, EffectiveFrom)
        SELECT @CompanyId, h, d, g, '2025-09-22' FROM (VALUES
            ('3004', N'Medicaments in measured doses (tablets, capsules, syrups, injections)', 5.00),
            ('3003', N'Medicaments not in measured doses', 5.00),
            ('3002', N'Vaccines, sera, blood fractions, insulin-type biologicals', 5.00),
            ('3005', N'Wadding, gauze, bandages, dressings', 5.00),
            ('3006', N'Pharmaceutical goods (sutures, blood-grouping reagents, ostomy)', 5.00),
            ('9018', N'Medical / surgical instruments (syringes, needles, catheters, cannulae)', 5.00),
            ('4015', N'Surgical / examination gloves of rubber', 5.00),
            ('9021', N'Orthopaedic appliances and implants', 5.00),
            ('3304', N'Beauty / skin-care preparations', 18.00)) v (h, d, g);
        INSERT dbo.PhHsnRateHistory (HsnId, GstPercent, CessPercent, EffectiveFrom)
        SELECT HsnId, GstPercent, CessPercent, EffectiveFrom FROM dbo.PhHsn WHERE CompanyId = @CompanyId;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhManufacturer WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhManufacturer (CompanyId, ManufacturerName, ShortCode)
        SELECT @CompanyId, n, s FROM (VALUES (N'Micro Labs Ltd','MICRO'),(N'Alkem Laboratories Ltd','ALKEM'),(N'Alembic Pharmaceuticals Ltd','ALEMB'),
            (N'GlaxoSmithKline Pharmaceuticals Ltd','GSK'),(N'USV Pvt Ltd','USV'),(N'Glenmark Pharmaceuticals Ltd','GLEN'),
            (N'Zydus Lifesciences Ltd','ZYDUS'),(N'Cipla Ltd','CIPLA'),(N'Aristo Pharmaceuticals Pvt Ltd','ARIS'),
            (N'Novo Nordisk India Pvt Ltd','NOVO'),(N'Baxter India Pvt Ltd','BAXT'),(N'Becton Dickinson India Pvt Ltd','BD'),
            (N'Torrent Pharmaceuticals Ltd','TORR'),(N'Franco-Indian Pharmaceuticals Pvt Ltd','FDC'),(N'Sun Pharmaceutical Industries Ltd','SUN'),
            (N'Mankind Pharma Ltd','MANK'),(N'Dr. Reddy''s Laboratories Ltd','DRL'),(N'Lupin Ltd','LUPIN')) v (n, s);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhGeneric WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhGeneric (CompanyId, GenericName, TherapeuticClass)
        SELECT @CompanyId, n, c FROM (VALUES (N'Paracetamol 650 mg',N'Analgesic / Antipyretic'),(N'Pantoprazole 40 mg',N'Proton pump inhibitor'),
            (N'Azithromycin 500 mg',N'Macrolide antibiotic'),(N'Amoxicillin 500 mg + Clavulanic Acid 125 mg',N'Penicillin antibiotic'),
            (N'Cefixime 200 mg',N'Cephalosporin antibiotic'),(N'Metformin 500 mg',N'Antidiabetic (biguanide)'),
            (N'Telmisartan 40 mg',N'Antihypertensive (ARB)'),(N'Aspirin 75 mg',N'Antiplatelet'),(N'Atorvastatin 10 mg',N'Statin'),
            (N'Montelukast 10 mg + Levocetirizine 5 mg',N'Anti-allergic'),(N'Ondansetron 4 mg',N'Antiemetic'),
            (N'Ambroxol + Levosalbutamol + Guaifenesin',N'Cough expectorant'),(N'Ceftriaxone 1 g',N'Cephalosporin antibiotic'),
            (N'Pantoprazole 40 mg (injection)',N'Proton pump inhibitor'),(N'Sodium Chloride 0.9%',N'IV fluid'),
            (N'Human Insulin (regular) 40 IU/ml',N'Insulin'),(N'Calcium Carbonate 1250 mg + Vitamin D3 250 IU',N'Calcium supplement'),
            (N'Oral Rehydration Salts (WHO)',N'Electrolyte replenisher')) v (n, c);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhReason WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhReason (CompanyId, ReasonType, ReasonName, SortOrder)
        SELECT @CompanyId, t, n, o FROM (VALUES
            ('SALE_RETURN',N'Doctor changed prescription',10),('SALE_RETURN',N'Excess quantity bought',20),('SALE_RETURN',N'Wrong item given',30),
            ('IPD_RETURN',N'Medicine discontinued',10),('IPD_RETURN',N'Patient discharged',20),('IPD_RETURN',N'Excess issued',30),('IPD_RETURN',N'Patient expired',40),
            ('PURCHASE_RETURN',N'Expired / near expiry',10),('PURCHASE_RETURN',N'Damaged in transit',20),('PURCHASE_RETURN',N'Wrong item supplied',30),('PURCHASE_RETURN',N'Rate difference',40),
            ('ADJUSTMENT',N'Breakage / damage',10),('ADJUSTMENT',N'Expired - write off',20),('ADJUSTMENT',N'Physical count difference',30),('ADJUSTMENT',N'Theft / pilferage',40),
            ('CANCEL',N'Wrong patient / customer',10),('CANCEL',N'Billing error',20),('CANCEL',N'Customer refused',30)) v (t, n, o);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhPriceRule WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhPriceRule (CompanyId, RuleName, PatientType, PriceBasis, RatePercent, Priority)
        VALUES (@CompanyId, N'Walk-in at MRP', 'WALKIN', 'MRP', 0, 100),
               (@CompanyId, N'IPD cash at MRP', 'IPD_CASH', 'MRP', 0, 100),
               (@CompanyId, N'IPD insurance at MRP', 'IPD_INSURANCE', 'MRP', 0, 100),
               (@CompanyId, N'IPD corporate at MRP', 'IPD_CORPORATE', 'MRP', 0, 100),
               (@CompanyId, N'Staff at MRP less 10%', 'STAFF', 'MRP_LESS', 10, 100);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhDiscountScheme WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhDiscountScheme (CompanyId, SchemeName, DiscountType, DiscountValue, AppliesTo, CustomerType, MinBillAmount)
        VALUES (@CompanyId, N'Senior citizen 5%', 'PERCENT', 5, 'ALL', NULL, 0),
               (@CompanyId, N'Staff 10%', 'PERCENT', 10, 'CUSTOMER_TYPE', 'STAFF', 0),
               (@CompanyId, N'Bill above 2000 - 3%', 'PERCENT', 3, 'ALL', NULL, 2000);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhItem WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhItem (CompanyId, ItemCode, ItemName, GenericId, ManufacturerId, CategoryId, DosageFormId, Strength, PackSize, ScheduleCode, HsnId,
                           PurchaseUomId, SaleUomId, ConversionQty, AllowLooseSale, IsColdChain, IsHighAlert, ReorderLevel, MinQty, MaxQty)
        SELECT @CompanyId, 'PH' + RIGHT('00000' + CAST(v.n AS VARCHAR(6)), 5), v.item,
               g.GenericId, m.ManufacturerId, c.CategoryId, f.DosageFormId, v.strength, v.pack, v.sch, h.HsnId, pu.UomId, su.UomId, v.conv, v.loose, v.cold, v.alert,
               v.reorder, v.reorder / 2, v.reorder * 4
        FROM (VALUES
            (1, N'Dolo 650', N'Paracetamol 650 mg', N'Micro Labs Ltd', N'Analgesics & Antipyretics', N'Tablet', N'650 mg', N'Strip of 15 tablets', 'H', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 20),
            (2, N'Pan 40', N'Pantoprazole 40 mg', N'Alkem Laboratories Ltd', N'Antacids & PPIs', N'Tablet', N'40 mg', N'Strip of 15 tablets', 'H', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 20),
            (3, N'Azithral 500', N'Azithromycin 500 mg', N'Alembic Pharmaceuticals Ltd', N'Antibiotics', N'Tablet', N'500 mg', N'Strip of 5 tablets', 'H1', '3004', 'STRIP', 'TAB', 5, 1, 0, 0, 10),
            (4, N'Augmentin 625 Duo', N'Amoxicillin 500 mg + Clavulanic Acid 125 mg', N'GlaxoSmithKline Pharmaceuticals Ltd', N'Antibiotics', N'Tablet', N'625 mg', N'Strip of 10 tablets', 'H1', '3004', 'STRIP', 'TAB', 10, 1, 0, 0, 10),
            (5, N'Taxim-O 200', N'Cefixime 200 mg', N'Alkem Laboratories Ltd', N'Antibiotics', N'Tablet', N'200 mg', N'Strip of 10 tablets', 'H1', '3004', 'STRIP', 'TAB', 10, 1, 0, 0, 10),
            (6, N'Glycomet 500', N'Metformin 500 mg', N'USV Pvt Ltd', N'Antidiabetics', N'Tablet', N'500 mg', N'Strip of 10 tablets', 'H', '3004', 'STRIP', 'TAB', 10, 1, 0, 0, 20),
            (7, N'Telma 40', N'Telmisartan 40 mg', N'Glenmark Pharmaceuticals Ltd', N'Cardiac & Antihypertensives', N'Tablet', N'40 mg', N'Strip of 15 tablets', 'H', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 15),
            (8, N'Ecosprin 75', N'Aspirin 75 mg', N'USV Pvt Ltd', N'Cardiac & Antihypertensives', N'Tablet', N'75 mg', N'Strip of 14 tablets', 'H', '3004', 'STRIP', 'TAB', 14, 1, 0, 0, 15),
            (9, N'Atorva 10', N'Atorvastatin 10 mg', N'Zydus Lifesciences Ltd', N'Cardiac & Antihypertensives', N'Tablet', N'10 mg', N'Strip of 15 tablets', 'H', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 15),
            (10, N'Montair LC', N'Montelukast 10 mg + Levocetirizine 5 mg', N'Cipla Ltd', N'Respiratory', N'Tablet', N'10 mg / 5 mg', N'Strip of 15 tablets', 'H', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 10),
            (11, N'Emeset 4', N'Ondansetron 4 mg', N'Cipla Ltd', N'Antiemetics', N'Tablet', N'4 mg', N'Strip of 10 tablets', 'H', '3004', 'STRIP', 'TAB', 10, 1, 0, 0, 10),
            (12, N'Ascoril LS Syrup', N'Ambroxol + Levosalbutamol + Guaifenesin', N'Glenmark Pharmaceuticals Ltd', N'Respiratory', N'Syrup', N'100 ml', N'100 ml bottle', 'H', '3004', 'BTL', 'BTL', 1, 0, 0, 0, 10),
            (13, N'Monocef 1 g Injection', N'Ceftriaxone 1 g', N'Aristo Pharmaceuticals Pvt Ltd', N'Antibiotics', N'Injection', N'1 g', N'1 vial', 'H', '3004', 'VIAL', 'VIAL', 1, 0, 0, 0, 20),
            (14, N'Pan 40 Injection', N'Pantoprazole 40 mg (injection)', N'Alkem Laboratories Ltd', N'Antacids & PPIs', N'Injection', N'40 mg', N'1 vial', 'H', '3004', 'VIAL', 'VIAL', 1, 0, 0, 0, 20),
            (15, N'Sodium Chloride 0.9% 500 ml', N'Sodium Chloride 0.9%', N'Baxter India Pvt Ltd', N'IV Fluids', N'Infusion / IV Fluid', N'0.9% w/v', N'500 ml bottle', 'H', '3004', 'BTL', 'BTL', 1, 0, 0, 0, 50),
            (16, N'Human Actrapid 40 IU/ml', N'Human Insulin (regular) 40 IU/ml', N'Novo Nordisk India Pvt Ltd', N'Insulins', N'Injection', N'40 IU/ml', N'10 ml vial', 'H', '3004', 'VIAL', 'VIAL', 1, 0, 1, 1, 5),
            (17, N'Shelcal 500', N'Calcium Carbonate 1250 mg + Vitamin D3 250 IU', N'Torrent Pharmaceuticals Ltd', N'Vitamins & Minerals', N'Tablet', N'500 mg', N'Strip of 15 tablets', 'OTC', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 10),
            (18, N'Electral Powder 21.8 g', N'Oral Rehydration Salts (WHO)', N'Franco-Indian Pharmaceuticals Pvt Ltd', N'OTC / FMCG', N'Powder / Sachet', N'21.8 g', N'1 sachet', 'OTC', '3004', 'SACHET', 'SACHET', 1, 0, 0, 0, 30),
            (19, N'BD Emerald Syringe 5 ml', NULL, N'Becton Dickinson India Pvt Ltd', N'Surgical', N'Surgical / Device', N'5 ml', N'Box of 100', 'OTC', '9018', 'BOX', 'NOS', 100, 1, 0, 0, 2),
            (20, N'Surgical Gloves Sterile 7.0', NULL, N'Becton Dickinson India Pvt Ltd', N'Surgical', N'Surgical / Device', N'Size 7.0', N'Box of 50 pairs', 'OTC', '4015', 'BOX', 'PAIR', 50, 1, 0, 0, 2)
        ) v (n, item, generic, mfr, cat, form, strength, pack, sch, hsn, puom, suom, conv, loose, cold, alert, reorder)
        JOIN dbo.PhCategory c      ON c.CompanyId = @CompanyId AND c.CategoryName = v.cat
        JOIN dbo.PhHsn h           ON h.CompanyId = @CompanyId AND h.HsnCode = v.hsn
        JOIN dbo.PhUom pu          ON pu.CompanyId = @CompanyId AND pu.UomCode = v.puom
        JOIN dbo.PhUom su          ON su.CompanyId = @CompanyId AND su.UomCode = v.suom
        LEFT JOIN dbo.PhGeneric g  ON g.CompanyId = @CompanyId AND g.GenericName = v.generic
        LEFT JOIN dbo.PhManufacturer m ON m.CompanyId = @CompanyId AND m.ManufacturerName = v.mfr
        LEFT JOIN dbo.PhDosageForm f   ON f.CompanyId = @CompanyId AND f.DosageFormName = v.form;
        UPDATE i SET PrescriptionRequired = s.RxRequired FROM dbo.PhItem i JOIN dbo.PhDrugSchedule s ON s.ScheduleCode = i.ScheduleCode WHERE i.CompanyId = @CompanyId;   -- 2350
    END
    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhNumberSeries WHERE BranchId = @BranchId)
    BEGIN
        INSERT dbo.PhNumberSeries (CompanyId, BranchId, DocType, DocName, Prefix)
        SELECT @CompanyId, @BranchId, t, n, p FROM (VALUES ('SALE',N'Pharmacy Sale Bill','PS'),('SRET',N'Sale Return','PSR'),
            ('IPDI',N'IPD Issue','PII'),('IPDR',N'IPD Return','PIR'),('INDT',N'IPD / Ward Indent','PIN'),('PO',N'Purchase Order','PO'),
            ('GRN',N'Goods Receipt (GRN)','GRN'),('PRET',N'Purchase Return','PRT'),('TRF',N'Stock Transfer','TRF'),('ADJ',N'Stock Adjustment','ADJ'),('PIND',N'Purchase Indent','PRQ'),('SPAY',N'Supplier Payment','SPY'),('BIND',N'Branch Indent','BIN'),('WOF',N'Expiry / Damage Write-off','WOF'),('PCNT',N'Physical Stock Verification','PSV'),('BCOR',N'Batch Correction','BCR')) v (t, n, p);
    END
    -- 2364: the branch's Main Store and the store issue series
    IF @BranchId IS NOT NULL
    BEGIN
        EXEC dbo.usp_PhStore_Ensure @CompanyId, @BranchId;
        IF NOT EXISTS (SELECT 1 FROM dbo.PhNumberSeries WHERE BranchId = @BranchId AND DocType = 'SISS')
            INSERT dbo.PhNumberSeries (CompanyId, BranchId, DocType, DocName, Prefix) VALUES (@CompanyId, @BranchId, 'SISS', N'Store Issue (godown to counter)', 'SIS');
    END
END;
GO

-- ── pages: Master > Pharmacy Master > Store / Godown; Pharmacy > Inventory > Store Issue ───────────────────
DECLARE @co INT, @menu INT, @inv INT, @page INT, @view INT, @ctl INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.PHARMACY_MASTER';
OPEN c; FETCH NEXT FROM c INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.PHARMACY_MASTER' AND CompanyId = @co;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'MASTER.PH_STORES', @Title = N'Store / Godown', @Controller = N'PharmacyMasters',
         @Action = N'Stores', @Show_In_Menu = 1, @Sort_Order = 135, @Icon = N'bi bi-shop-window me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PharmacyMasters', @Action = N'Stores', @Source = 'SEED';
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Add / edit', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PharmacyMasters', @Action = N'SaveStore', @Source = 'SEED';
    FETCH NEXT FROM c INTO @co;
END
CLOSE c; DEALLOCATE c;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY.INVENTORY';
OPEN c; FETCH NEXT FROM c INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @inv = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY.INVENTORY' AND CompanyId = @co;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @inv, @Page_Code = N'PHARMACY.STOREISSUE', @Title = N'Store Issue (Godown to Counter)', @Controller = N'PhStoreIssues',
         @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 25, @Icon = N'bi bi-box-arrow-in-right me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    DECLARE @a NVARCHAR(40);
    DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT('Index,Form,Print,ItemSearch,Batches', ',');
    OPEN v; FETCH NEXT FROM v INTO @a;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhStoreIssues', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
    CLOSE v; DEALLOCATE v;
    DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT;
    DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT * FROM (VALUES ('REQUEST', N'Raise / edit / send a store request', 20, N'Save'), ('ISSUE', N'Issue stock from the godown', 30, N'Issue'),
                                                               ('RECEIVE', N'Receive into the counter (variance)', 40, N'Receive'), ('CANCEL', N'Cancel a request not yet issued', 50, N'Cancel')) x (c, t, s, a);
    OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @a;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhStoreIssues', @Action = @a, @Source = 'SEED';
        FETCH NEXT FROM k INTO @cc, @ct, @cs, @a;
    END
    CLOSE k; DEALLOCATE k;
    FETCH NEXT FROM c INTO @co;
END
CLOSE c; DEALLOCATE c;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2364 applied: pharmacy stores / godowns (Main Store per branch, store-wise stock, store issue, store-aware stock procedures).';
GO
