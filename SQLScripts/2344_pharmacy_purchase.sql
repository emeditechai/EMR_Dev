-- ============================================================================================================
-- 2344  Pharmacy module - Purchase (after 2343). Top menu "Pharmacy" (beside IPD) > Purchase:
--   Purchase Indent -> Purchase Order -> Goods Receipt (GRN) -> Purchase Return, and Supplier Payments.
--   * Stock foundation: PhBatch (item + batch + expiry + MRP), PhStock (branch x batch, in sale units),
--     PhStockLedger (every movement). Stock changes only through dbo.usp_PhStock_Move.
--   * Numbers PREFIX/BRANCH/FY/serial from PhNumberSeries, given when a document is posted / approved.
--   * Posted documents are never edited: a GRN is corrected by a purchase return.
-- Additive and re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO

-- ── stock foundation ────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhBatch') IS NULL
CREATE TABLE dbo.PhBatch (
    BatchId        INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    ItemId         INT NOT NULL REFERENCES dbo.PhItem (ItemId),
    BatchNo        NVARCHAR(30) NOT NULL,
    MfgDate        DATE NULL,
    ExpiryDate     DATE NOT NULL,                  -- last day of the expiry month
    Mrp            DECIMAL(12,2) NOT NULL,         -- per purchase unit (pack), GST inclusive
    PurchaseRate   DECIMAL(12,4) NOT NULL,         -- per pack, before GST, after discount (first GRN)
    LandedCost     DECIMAL(12,4) NOT NULL,         -- per sale unit, before GST, free goods spread
    GstPercent     DECIMAL(5,2) NOT NULL,
    SupplierId     INT NULL,
    IsBlocked      BIT NOT NULL DEFAULT 0,         -- recalled / quarantined: never sold or issued
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT UQ_PhBatch UNIQUE (ItemId, BatchNo, Mrp)
);
GO
IF OBJECT_ID('dbo.PhStock') IS NULL
CREATE TABLE dbo.PhStock (
    BranchId   INT NOT NULL,
    BatchId    INT NOT NULL REFERENCES dbo.PhBatch (BatchId),
    ItemId     INT NOT NULL,
    QtyOnHand  DECIMAL(14,3) NOT NULL DEFAULT 0,   -- sale units
    ModifiedDate DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_PhStock PRIMARY KEY (BranchId, BatchId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhStock_Item')
    CREATE INDEX IX_PhStock_Item ON dbo.PhStock (BranchId, ItemId) INCLUDE (QtyOnHand);
GO
IF OBJECT_ID('dbo.PhStockLedger') IS NULL
CREATE TABLE dbo.PhStockLedger (
    LedgerId    BIGINT IDENTITY(1,1) PRIMARY KEY,
    BranchId    INT NOT NULL,
    ItemId      INT NOT NULL,
    BatchId     INT NOT NULL,
    TxnDate     DATETIME NOT NULL DEFAULT GETDATE(),
    DocType     VARCHAR(10) NOT NULL,              -- GRN, PRET, OPEN, SALE, SRET, IPDI, IPDR, TRFO, TRFI, ADJ
    DocId       INT NOT NULL,
    DocNo       NVARCHAR(40) NULL,
    QtyIn       DECIMAL(14,3) NOT NULL DEFAULT 0,
    QtyOut      DECIMAL(14,3) NOT NULL DEFAULT 0,
    BalanceAfter DECIMAL(14,3) NOT NULL,           -- of this batch at this branch
    UnitCost    DECIMAL(12,4) NOT NULL,            -- per sale unit
    CreatedBy   INT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhStockLedger_Item')
    CREATE INDEX IX_PhStockLedger_Item ON dbo.PhStockLedger (BranchId, ItemId, TxnDate);
GO

-- the one place stock changes
CREATE OR ALTER PROCEDURE dbo.usp_PhStock_Move
    @BranchId INT, @BatchId INT, @Qty DECIMAL(14,3),      -- + in, - out (sale units)
    @DocType VARCHAR(10), @DocId INT, @DocNo NVARCHAR(40), @UserId INT, @AllowNegative BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @item INT, @cost DECIMAL(12,4), @bal DECIMAL(14,3);
    SELECT @item = ItemId, @cost = LandedCost FROM dbo.PhBatch WHERE BatchId = @BatchId;
    IF @item IS NULL THROW 51001, 'Batch not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhStock WITH (UPDLOCK, HOLDLOCK) WHERE BranchId = @BranchId AND BatchId = @BatchId)
        INSERT dbo.PhStock (BranchId, BatchId, ItemId, QtyOnHand) VALUES (@BranchId, @BatchId, @item, 0);
    UPDATE dbo.PhStock WITH (UPDLOCK) SET @bal = QtyOnHand = QtyOnHand + @Qty, ModifiedDate = GETDATE()
    WHERE BranchId = @BranchId AND BatchId = @BatchId;
    IF @bal < 0 AND @AllowNegative = 0
    BEGIN
        DECLARE @msg NVARCHAR(300) = CONCAT(N'Not enough stock of ', (SELECT i.ItemName + N' batch ' + b.BatchNo FROM dbo.PhBatch b JOIN dbo.PhItem i ON i.ItemId = b.ItemId WHERE b.BatchId = @BatchId),
                                            N': short by ', CAST(-@bal AS DECIMAL(14,2)), N'.');
        THROW 51002, @msg, 1;
    END
    INSERT dbo.PhStockLedger (BranchId, ItemId, BatchId, DocType, DocId, DocNo, QtyIn, QtyOut, BalanceAfter, UnitCost, CreatedBy)
    VALUES (@BranchId, @item, @BatchId, @DocType, @DocId, @DocNo, CASE WHEN @Qty > 0 THEN @Qty ELSE 0 END, CASE WHEN @Qty < 0 THEN -@Qty ELSE 0 END, @bal, @cost, @UserId);
END;
GO

-- ── numbering ──────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ph_NextNumber @BranchId INT, @DocType VARCHAR(10), @DocDate DATE, @DocNo NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sid INT, @prefix VARCHAR(10), @pad INT, @reset BIT, @fy VARCHAR(4), @no INT;
    SELECT @sid = SeriesId, @prefix = Prefix, @pad = Padding, @reset = ResetYearly FROM dbo.PhNumberSeries WHERE BranchId = @BranchId AND DocType = @DocType AND IsActive = 1;
    IF @sid IS NULL THROW 51010, 'Number series for this document is missing or inactive (Master > Pharmacy Master > Document Number Series).', 1;
    DECLARE @y INT = CASE WHEN MONTH(@DocDate) >= 4 THEN YEAR(@DocDate) ELSE YEAR(@DocDate) - 1 END;
    SET @fy = CASE WHEN @reset = 1 THEN RIGHT(CAST(@y AS VARCHAR(4)), 2) + RIGHT(CAST(@y + 1 AS VARCHAR(4)), 2) ELSE '0000' END;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhNumberCounter WITH (UPDLOCK, HOLDLOCK) WHERE SeriesId = @sid AND FinYear = @fy)
        INSERT dbo.PhNumberCounter (SeriesId, FinYear, LastNo) VALUES (@sid, @fy, 0);
    UPDATE dbo.PhNumberCounter SET @no = LastNo = LastNo + 1 WHERE SeriesId = @sid AND FinYear = @fy;
    DECLARE @bc VARCHAR(20) = ISNULL((SELECT BranchCode FROM dbo.BranchMaster WHERE BranchID = @BranchId), CAST(@BranchId AS VARCHAR(10)));
    SET @DocNo = CONCAT(@prefix, '/', @bc, '/', @fy, '/', RIGHT(REPLICATE('0', @pad) + CAST(@no AS VARCHAR(12)), @pad));
END;
GO

-- new series: purchase indent and supplier payment (existing branches + the seed procedure below)
INSERT dbo.PhNumberSeries (CompanyId, BranchId, DocType, DocName, Prefix)
SELECT s.CompanyId, s.BranchId, v.t, v.n, v.p
FROM (SELECT DISTINCT CompanyId, BranchId FROM dbo.PhNumberSeries) s
CROSS JOIN (VALUES ('PIND', N'Purchase Indent', 'PRQ'), ('SPAY', N'Supplier Payment', 'SPY')) v (t, n, p)
WHERE NOT EXISTS (SELECT 1 FROM dbo.PhNumberSeries x WHERE x.BranchId = s.BranchId AND x.DocType = v.t);
GO

-- ── purchase indent (requisition) ──────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhPurchaseIndent') IS NULL
CREATE TABLE dbo.PhPurchaseIndent (
    IndentId     INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId    INT NOT NULL,
    BranchId     INT NOT NULL,
    IndentNo     NVARCHAR(40) NULL,                -- given on submit
    IndentDate   DATE NOT NULL,
    Priority     VARCHAR(10) NOT NULL DEFAULT 'NORMAL',   -- NORMAL | URGENT
    Status       VARCHAR(10) NOT NULL DEFAULT 'DRAFT',    -- DRAFT | SUBMITTED | APPROVED | REJECTED | ORDERED | CANCELLED
    Remarks      NVARCHAR(300) NULL,
    ActionRemarks NVARCHAR(300) NULL,              -- approver's note / rejection reason
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
    SubmittedBy INT NULL, SubmittedDate DATETIME NULL,
    ApprovedBy INT NULL, ApprovedDate DATETIME NULL,
    ModifiedBy INT NULL, ModifiedDate DATETIME NULL
);
GO
IF OBJECT_ID('dbo.PhPurchaseIndentDtl') IS NULL
CREATE TABLE dbo.PhPurchaseIndentDtl (
    IndentDtlId  INT IDENTITY(1,1) PRIMARY KEY,
    IndentId     INT NOT NULL REFERENCES dbo.PhPurchaseIndent (IndentId),
    ItemId       INT NOT NULL REFERENCES dbo.PhItem (ItemId),
    Qty          DECIMAL(12,2) NOT NULL,           -- purchase units
    StockAtIndent DECIMAL(14,3) NULL,              -- sale units, when raised
    Remarks      NVARCHAR(200) NULL
);
GO

-- ── purchase order ─────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhPurchaseOrder') IS NULL
CREATE TABLE dbo.PhPurchaseOrder (
    PoId          INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId     INT NOT NULL,
    BranchId      INT NOT NULL,
    PoNo          NVARCHAR(40) NULL,               -- given on approval
    PoDate        DATE NOT NULL,
    SupplierId    INT NOT NULL REFERENCES dbo.PhSupplier (SupplierId),
    IndentId      INT NULL REFERENCES dbo.PhPurchaseIndent (IndentId),
    ExpectedDate  DATE NULL,
    IsInterState  BIT NOT NULL DEFAULT 0,          -- IGST instead of CGST + SGST
    Status        VARCHAR(10) NOT NULL DEFAULT 'DRAFT',   -- DRAFT | APPROVED | PARTIAL | CLOSED | CANCELLED
    TaxableAmount DECIMAL(14,2) NOT NULL DEFAULT 0,
    GstAmount     DECIMAL(14,2) NOT NULL DEFAULT 0,
    NetAmount     DECIMAL(14,2) NOT NULL DEFAULT 0,
    Terms         NVARCHAR(500) NULL,
    Remarks       NVARCHAR(300) NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
    ApprovedBy INT NULL, ApprovedDate DATETIME NULL,
    ModifiedBy INT NULL, ModifiedDate DATETIME NULL
);
GO
IF OBJECT_ID('dbo.PhPurchaseOrderDtl') IS NULL
CREATE TABLE dbo.PhPurchaseOrderDtl (
    PoDtlId      INT IDENTITY(1,1) PRIMARY KEY,
    PoId         INT NOT NULL REFERENCES dbo.PhPurchaseOrder (PoId),
    ItemId       INT NOT NULL REFERENCES dbo.PhItem (ItemId),
    Qty          DECIMAL(12,2) NOT NULL,           -- purchase units
    FreeQty      DECIMAL(12,2) NOT NULL DEFAULT 0,
    Rate         DECIMAL(12,4) NOT NULL,           -- per pack before GST
    DiscPercent  DECIMAL(5,2) NOT NULL DEFAULT 0,
    GstPercent   DECIMAL(5,2) NOT NULL,
    TaxableAmount DECIMAL(14,2) NOT NULL,
    GstAmount    DECIMAL(14,2) NOT NULL,
    ReceivedQty  DECIMAL(12,2) NOT NULL DEFAULT 0  -- billed qty received on GRNs
);
GO

-- ── goods receipt (purchase entry) ─────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhGrn') IS NULL
CREATE TABLE dbo.PhGrn (
    GrnId          INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    BranchId       INT NOT NULL,
    GrnNo          NVARCHAR(40) NULL,              -- given on posting
    GrnDate        DATE NOT NULL,
    SupplierId     INT NOT NULL REFERENCES dbo.PhSupplier (SupplierId),
    PoId           INT NULL REFERENCES dbo.PhPurchaseOrder (PoId),
    InvoiceNo      NVARCHAR(40) NOT NULL,
    InvoiceDate    DATE NOT NULL,
    InvoiceAmount  DECIMAL(14,2) NOT NULL,         -- as printed on the supplier's bill (checked against the lines)
    IsInterState   BIT NOT NULL DEFAULT 0,
    Status         VARCHAR(10) NOT NULL DEFAULT 'DRAFT',   -- DRAFT | POSTED | CANCELLED
    GrossAmount    DECIMAL(14,2) NOT NULL DEFAULT 0,
    DiscountAmount DECIMAL(14,2) NOT NULL DEFAULT 0,
    TaxableAmount  DECIMAL(14,2) NOT NULL DEFAULT 0,
    CgstAmount     DECIMAL(14,2) NOT NULL DEFAULT 0,
    SgstAmount     DECIMAL(14,2) NOT NULL DEFAULT 0,
    IgstAmount     DECIMAL(14,2) NOT NULL DEFAULT 0,
    OtherCharges   DECIMAL(14,2) NOT NULL DEFAULT 0,   -- freight etc. on the bill (spread into cost)
    RoundOff       DECIMAL(8,2) NOT NULL DEFAULT 0,
    NetAmount      DECIMAL(14,2) NOT NULL DEFAULT 0,
    DueDate        DATE NULL,                      -- invoice date + supplier credit days
    Remarks        NVARCHAR(300) NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
    PostedBy INT NULL, PostedDate DATETIME NULL,
    ModifiedBy INT NULL, ModifiedDate DATETIME NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_PhGrn_Invoice')
    CREATE UNIQUE INDEX UX_PhGrn_Invoice ON dbo.PhGrn (CompanyId, SupplierId, InvoiceNo) WHERE Status <> 'CANCELLED';
GO
IF OBJECT_ID('dbo.PhGrnDtl') IS NULL
CREATE TABLE dbo.PhGrnDtl (
    GrnDtlId      INT IDENTITY(1,1) PRIMARY KEY,
    GrnId         INT NOT NULL REFERENCES dbo.PhGrn (GrnId),
    PoDtlId       INT NULL REFERENCES dbo.PhPurchaseOrderDtl (PoDtlId),
    ItemId        INT NOT NULL REFERENCES dbo.PhItem (ItemId),
    BatchNo       NVARCHAR(30) NOT NULL,
    MfgDate       DATE NULL,
    ExpiryDate    DATE NOT NULL,
    Mrp           DECIMAL(12,2) NOT NULL,          -- per pack
    Qty           DECIMAL(12,2) NOT NULL,          -- billed packs
    FreeQty       DECIMAL(12,2) NOT NULL DEFAULT 0,
    Rate          DECIMAL(12,4) NOT NULL,          -- per pack before GST
    DiscPercent   DECIMAL(5,2) NOT NULL DEFAULT 0,
    GstPercent    DECIMAL(5,2) NOT NULL,
    TaxableAmount DECIMAL(14,2) NOT NULL,
    GstAmount     DECIMAL(14,2) NOT NULL,
    LandedCost    DECIMAL(12,4) NOT NULL DEFAULT 0,   -- per sale unit (set on posting)
    BatchId       INT NULL REFERENCES dbo.PhBatch (BatchId)
);
GO

-- ── purchase return (debit note) ───────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhPurchaseReturn') IS NULL
CREATE TABLE dbo.PhPurchaseReturn (
    ReturnId       INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    BranchId       INT NOT NULL,
    ReturnNo       NVARCHAR(40) NULL,
    ReturnDate     DATE NOT NULL,
    SupplierId     INT NOT NULL REFERENCES dbo.PhSupplier (SupplierId),
    ReasonId       INT NULL REFERENCES dbo.PhReason (ReasonId),
    IsInterState   BIT NOT NULL DEFAULT 0,
    Status         VARCHAR(10) NOT NULL DEFAULT 'DRAFT',   -- DRAFT | POSTED | CANCELLED
    TaxableAmount  DECIMAL(14,2) NOT NULL DEFAULT 0,
    GstAmount      DECIMAL(14,2) NOT NULL DEFAULT 0,
    RoundOff       DECIMAL(8,2) NOT NULL DEFAULT 0,
    NetAmount      DECIMAL(14,2) NOT NULL DEFAULT 0,
    Remarks        NVARCHAR(300) NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
    PostedBy INT NULL, PostedDate DATETIME NULL,
    ModifiedBy INT NULL, ModifiedDate DATETIME NULL
);
GO
IF OBJECT_ID('dbo.PhPurchaseReturnDtl') IS NULL
CREATE TABLE dbo.PhPurchaseReturnDtl (
    ReturnDtlId   INT IDENTITY(1,1) PRIMARY KEY,
    ReturnId      INT NOT NULL REFERENCES dbo.PhPurchaseReturn (ReturnId),
    BatchId       INT NOT NULL REFERENCES dbo.PhBatch (BatchId),
    ItemId        INT NOT NULL,
    Qty           DECIMAL(14,3) NOT NULL,          -- sale units
    Rate          DECIMAL(12,4) NOT NULL,          -- per sale unit before GST (batch purchase rate)
    GstPercent    DECIMAL(5,2) NOT NULL,
    TaxableAmount DECIMAL(14,2) NOT NULL,
    GstAmount     DECIMAL(14,2) NOT NULL
);
GO

-- ── supplier payments ─────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhSupplierPayment') IS NULL
CREATE TABLE dbo.PhSupplierPayment (
    PaymentId     INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId     INT NOT NULL,
    BranchId      INT NOT NULL,
    PaymentNo     NVARCHAR(40) NOT NULL,
    PaymentDate   DATE NOT NULL,
    SupplierId    INT NOT NULL REFERENCES dbo.PhSupplier (SupplierId),
    PaymentMode   VARCHAR(10) NOT NULL,            -- CASH | CHEQUE | NEFT | UPI | CARD
    ReferenceNo   NVARCHAR(50) NULL,
    Amount        DECIMAL(14,2) NOT NULL,
    Remarks       NVARCHAR(300) NULL,
    Status        VARCHAR(10) NOT NULL DEFAULT 'POSTED',   -- POSTED | CANCELLED
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF OBJECT_ID('dbo.PhSupplierPaymentAlloc') IS NULL
CREATE TABLE dbo.PhSupplierPaymentAlloc (
    AllocId    INT IDENTITY(1,1) PRIMARY KEY,
    PaymentId  INT NOT NULL REFERENCES dbo.PhSupplierPayment (PaymentId),
    GrnId      INT NOT NULL REFERENCES dbo.PhGrn (GrnId),
    Amount     DECIMAL(14,2) NOT NULL
);
GO

-- ── posting procedures ────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhGrn_Post @GrnId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DECLARE @branch INT, @company INT, @status VARCHAR(10), @date DATE, @no NVARCHAR(40), @supplier INT, @po INT, @inv DATE, @neg BIT;
    SELECT @branch = BranchId, @company = CompanyId, @status = Status, @date = GrnDate, @supplier = SupplierId, @po = PoId, @inv = InvoiceDate
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
        EXEC dbo.usp_PhStock_Move @branch, @bid, @q, 'GRN', @GrnId, @no, @UserId;
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
    COMMIT;
    SELECT @no AS DocNo;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_PhPurchaseReturn_Post @ReturnId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DECLARE @branch INT, @status VARCHAR(10), @date DATE, @no NVARCHAR(40);
    SELECT @branch = BranchId, @status = Status, @date = ReturnDate FROM dbo.PhPurchaseReturn WITH (UPDLOCK) WHERE ReturnId = @ReturnId;
    IF @status IS NULL OR @status <> 'DRAFT' THROW 51030, 'Only a draft return can be posted.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhPurchaseReturnDtl WHERE ReturnId = @ReturnId) THROW 51031, 'The return has no items.', 1;
    EXEC dbo.usp_Ph_NextNumber @branch, 'PRET', @date, @no OUTPUT;
    DECLARE @bid INT, @q DECIMAL(14,3);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT BatchId, Qty FROM dbo.PhPurchaseReturnDtl WHERE ReturnId = @ReturnId;
    OPEN c; FETCH NEXT FROM c INTO @bid, @q;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @q = -@q;
        EXEC dbo.usp_PhStock_Move @branch, @bid, @q, 'PRET', @ReturnId, @no, @UserId, 0;   -- never below zero
        FETCH NEXT FROM c INTO @bid, @q;
    END
    CLOSE c; DEALLOCATE c;
    UPDATE dbo.PhPurchaseReturn SET ReturnNo = @no, Status = 'POSTED', PostedBy = @UserId, PostedDate = GETDATE() WHERE ReturnId = @ReturnId;
    COMMIT;
    SELECT @no AS DocNo;
END;
GO

-- ── seed procedure: add the two new series for branches seeded later ───────────────────────────────────
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Pharmacy_EnsureMasters'));
IF @def NOT LIKE '%PIND%'
BEGIN
    SET @def = REPLACE(@def, '(''ADJ'',N''Stock Adjustment'',''ADJ'')', '(''ADJ'',N''Stock Adjustment'',''ADJ''),(''PIND'',N''Purchase Indent'',''PRQ''),(''SPAY'',N''Supplier Payment'',''SPY'')');
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
GO

-- ── navbar: Pharmacy (beside IPD) > Purchase ───────────────────────────────────────────────────────────
DECLARE @co INT, @nav INT, @menu INT, @page INT, @view INT, @ctl INT, @i INT = 1;
SELECT TOP 1 @co = CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'IPD' ORDER BY Menu_ID;
SELECT @nav = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY';
EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = NULL, @Menu_Type = 'NAV', @Menu_Code = N'PHARMACY',
     @Title = N'Pharmacy', @Icon = N'bi bi-capsule-pill me-2', @Sort_Order = 45, @UserId = NULL, @Menu_ID = @nav OUTPUT;
EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @nav, @Menu_Type = 'MENU', @Menu_Code = N'PHARMACY.PURCHASE',
     @Title = N'Purchase', @Icon = N'bi bi-cart-plus me-2', @Sort_Order = 10, @UserId = NULL, @Menu_ID = @menu OUTPUT;

-- one control per screen action (sensitive ones - APPROVE, REJECT, CANCEL, CLOSE, DELETE, POST - are granted per role explicitly)
DECLARE @pages TABLE (n INT IDENTITY, Code NVARCHAR(60), Title NVARCHAR(100), Ctl NVARCHAR(60), Sort INT, Icon NVARCHAR(60), ViewActs NVARCHAR(400));
INSERT @pages (Code, Title, Ctl, Sort, Icon, ViewActs) VALUES
 (N'PHARMACY.PURCHASEINDENT',  N'Purchase Indent',     N'PhPurchaseIndents',  10, N'bi bi-clipboard-plus me-2',   N'Index,Form,Print,ItemSearch,ReorderSuggest'),
 (N'PHARMACY.PURCHASEORDER',   N'Purchase Order',      N'PhPurchaseOrders',   20, N'bi bi-file-earmark-text me-2', N'Index,Form,Print,ItemSearch,IndentLines,SupplierInfo'),
 (N'PHARMACY.GRN',             N'Goods Receipt (GRN)', N'PhGrns',             30, N'bi bi-box-arrow-in-down me-2', N'Index,Form,Print,ItemSearch,PoLines,SupplierInfo,OpenPos'),
 (N'PHARMACY.PURCHASERETURN',  N'Purchase Return',     N'PhPurchaseReturns',  40, N'bi bi-box-arrow-up me-2',     N'Index,Form,Print,BatchSearch,SupplierInfo'),
 (N'PHARMACY.SUPPLIERPAYMENT', N'Supplier Payments',   N'PhSupplierPayments', 50, N'bi bi-cash-coin me-2',        N'Index,Outstanding,Pay,Print');
DECLARE @controls TABLE (Code NVARCHAR(60), Control VARCHAR(30), Title NVARCHAR(150), Sort INT, Acts NVARCHAR(200));
INSERT @controls VALUES
 (N'PHARMACY.PURCHASEINDENT', 'SAVE',    N'Create / edit a draft indent', 20, N'Save'),
 (N'PHARMACY.PURCHASEINDENT', 'SUBMIT',  N'Submit an indent for approval', 30, N'Submit'),
 (N'PHARMACY.PURCHASEINDENT', 'APPROVE', N'Approve an indent', 40, N'Approve'),
 (N'PHARMACY.PURCHASEINDENT', 'REJECT',  N'Reject an indent', 50, N'Reject'),
 (N'PHARMACY.PURCHASEINDENT', 'CANCEL',  N'Cancel an indent', 60, N'Cancel'),
 (N'PHARMACY.PURCHASEORDER',  'SAVE',    N'Create / edit a draft order', 20, N'Save'),
 (N'PHARMACY.PURCHASEORDER',  'APPROVE', N'Approve an order (gives the PO number)', 30, N'Approve'),
 (N'PHARMACY.PURCHASEORDER',  'CANCEL',  N'Cancel an order', 40, N'Cancel'),
 (N'PHARMACY.PURCHASEORDER',  'CLOSE',   N'Short-close a part-received order', 50, N'Close'),
 (N'PHARMACY.GRN',            'SAVE',    N'Enter / edit a draft GRN', 20, N'Save'),
 (N'PHARMACY.GRN',            'DELETE',  N'Delete a draft GRN', 30, N'Delete'),
 (N'PHARMACY.GRN',            'POST',    N'Post a GRN (stock in)', 40, N'Post'),
 (N'PHARMACY.PURCHASERETURN', 'SAVE',    N'Enter / edit a draft return', 20, N'Save'),
 (N'PHARMACY.PURCHASERETURN', 'DELETE',  N'Delete a draft return', 30, N'Delete'),
 (N'PHARMACY.PURCHASERETURN', 'POST',    N'Post a return (stock out, debit note)', 40, N'Post'),
 (N'PHARMACY.SUPPLIERPAYMENT','SAVE',    N'Record a supplier payment', 20, N'Save'),
 (N'PHARMACY.SUPPLIERPAYMENT','CANCEL',  N'Cancel a supplier payment', 30, N'Cancel');

-- remove the earlier generic EDIT / APPROVE controls of these pages (first draft of this script), if present
DELETE m FROM dbo.PageEndpointMap m JOIN dbo.PageControlMaster c ON c.Control_ID = m.Control_ID JOIN dbo.PageMaster p ON p.Page_ID = c.Page_ID
WHERE p.Page_Code IN (SELECT Code FROM @pages) AND c.Control_Code IN ('EDIT');
DELETE m FROM dbo.PageEndpointMap m JOIN dbo.PageControlMaster c ON c.Control_ID = m.Control_ID JOIN dbo.PageMaster p ON p.Page_ID = c.Page_ID
WHERE p.Page_Code IN (SELECT Code FROM @pages) AND c.Control_Code = 'APPROVE' AND m.Action NOT IN ('Approve');

DECLARE @code NVARCHAR(60), @title NVARCHAR(100), @c NVARCHAR(60), @sort INT, @icon NVARCHAR(60), @va NVARCHAR(400), @act NVARCHAR(60), @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @ca NVARCHAR(200);
WHILE @i <= (SELECT COUNT(*) FROM @pages)
BEGIN
    SELECT @code = Code, @title = Title, @c = Ctl, @sort = Sort, @icon = Icon, @va = ViewActs FROM @pages WHERE n = @i;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title, @Controller = @c, @Action = N'Index',
         @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@va, ',');
    OPEN a; FETCH NEXT FROM a INTO @act;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = @c, @Action = @act, @Source = 'SEED'; FETCH NEXT FROM a INTO @act; END
    CLOSE a; DEALLOCATE a;
    DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Control, Title, Sort, Acts FROM @controls WHERE Code = @code;
    OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
        DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@ca, ',');
        OPEN a; FETCH NEXT FROM a INTO @act;
        WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = @c, @Action = @act, @Source = 'SEED'; FETCH NEXT FROM a INTO @act; END
        CLOSE a; DEALLOCATE a;
        FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
    END
    CLOSE k; DEALLOCATE k;
    SET @i += 1;
END
-- generic EDIT controls of the first draft are no longer used by these pages
DELETE c FROM dbo.PageControlMaster c JOIN dbo.PageMaster p ON p.Page_ID = c.Page_ID
WHERE p.Page_Code IN (SELECT Code FROM @pages) AND c.Control_Code IN ('EDIT', 'APPROVE')
  AND NOT EXISTS (SELECT 1 FROM dbo.PageEndpointMap m WHERE m.Control_ID = c.Control_ID);
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2344 applied: Pharmacy > Purchase (indent, PO, GRN, purchase return, supplier payments; batch stock and ledger).';
GO
