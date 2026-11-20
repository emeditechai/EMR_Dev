-- ============================================================================================================
-- Migration: 2498_qc_stock_core.sql
-- Description: Quality & Compliance > Stock Management - core (Phase 2 of the "Quality & Compliance Module Plan -
--   BOM & Costing"). Lab reagent / consumable stock, fully separate from the pharmacy (no Ph* table is used).
--
--   Masters reused: InvItem, InvItemCategory, InvSupplier, InvStore, InvUnit (SQLScripts/2247).
--   New tables:
--     InvSettings            per company: PO / adjustment / count approval, near-expiry days, lot acceptance,
--                            stock deduction on lab consumption
--     InvLot                 item + lot no + expiry; status QUARANTINE | ACCEPTED | REJECTED | BLOCKED
--     InvStockBalance        store x lot quantity (consumption units) + opened-on (open-vial stability)
--     InvStockLedger         every movement, never edited (OPN GRN PRET ISSO ISSI ADJ CNT CONS)
--     InvDoc / InvDocLine    documents: OPN opening stock, PO purchase order, GRN goods receipt, PRET purchase return,
--                            IND indent, ISS issue / transfer, ADJ adjustment / write-off, CNT physical count
--     InvAdjReason           adjustment reasons (direction, usage or loss)
--     InvDocCounter          document numbers per branch, type and financial year (QGR/HO/2627/00001)
--     InvConsumptionPosting  one accounts voucher per branch per day for lab consumption
--   Rules:
--     * Quantities in stock are in the item's consumption unit; documents may be entered in packs (UnitMode 'P').
--     * Valuation: weighted average per item (InvItem.AvgUnitCost, per consumption unit), recalculated on
--       receipts (GRN, opening stock) and purchase returns; issues, consumption and write-offs go out at average.
--     * dbo.usp_Inv_Move is the only writer of InvStockBalance / InvStockLedger; negative stock is refused.
--     * A lot of a category that needs acceptance (reagent, kit, control) arrives in QUARANTINE and can be issued or
--       consumed only once ACCEPTED (ISO 15189 6.6.3 lot-to-lot verification).
--     * Lab consumption (usp_Qc_Consume_Sync, 2249) now takes its BOM lines out of the department's bench store
--       (else the branch Main Store), opened lots first then FEFO. Short stock never stops a result: the line waits
--       as PENDING. A store that has never had stock is NOT_TRACKED (stock tracking starts with its first stock).
--     * Accounts (dbo.usp_Acc_PostVoucher): GRN = Purchase, return = Debit Note, opening / adjustment / count /
--       transit loss / daily consumption = Journal. Ledgers created here; supplier ledgers on first use.
--   Business-rule failures: THROW 53500-53799 (shown to the user as is). Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Columns on the existing masters ───────────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.InvItemCategory', 'RequiresAcceptance') IS NULL
BEGIN
    ALTER TABLE dbo.InvItemCategory ADD RequiresAcceptance BIT NOT NULL CONSTRAINT DF_InvItemCategory_Accept DEFAULT 0;
END
GO
UPDATE dbo.InvItemCategory SET RequiresAcceptance = 1
WHERE CategoryName IN (N'Reagent', N'Kit', N'Control / Calibrator') AND RequiresAcceptance = 0
  AND NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'InvLot');   -- first run only: later the user's choice stands
GO
IF COL_LENGTH('dbo.InvSupplier', 'LedgerId') IS NULL
    ALTER TABLE dbo.InvSupplier ADD LedgerId INT NULL;
GO
IF COL_LENGTH('dbo.QcConsumptionLine', 'StoreId') IS NULL
    ALTER TABLE dbo.QcConsumptionLine ADD StoreId INT NULL, StockStatus VARCHAR(12) NULL, StockPostedOn DATETIME NULL, StockNote NVARCHAR(300) NULL;
GO
-- lines consumed before stock existed are history only
UPDATE dbo.QcConsumptionLine SET StockStatus = 'BEFORE' WHERE StockStatus IS NULL
  AND NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'InvStockLedger');
GO

-- ── 2. Tables ──────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID(N'dbo.InvSettings', N'U') IS NULL
CREATE TABLE dbo.InvSettings
(
    CompanyId              INT NOT NULL CONSTRAINT PK_InvSettings PRIMARY KEY,
    PoApprovalRequired     BIT NOT NULL CONSTRAINT DF_InvSettings_Po DEFAULT 1,
    AdjApprovalRequired    BIT NOT NULL CONSTRAINT DF_InvSettings_Adj DEFAULT 1,
    CountApprovalRequired  BIT NOT NULL CONSTRAINT DF_InvSettings_Cnt DEFAULT 1,
    LotAcceptanceRequired  BIT NOT NULL CONSTRAINT DF_InvSettings_Lot DEFAULT 1,
    DeductOnConsumption    BIT NOT NULL CONSTRAINT DF_InvSettings_Ded DEFAULT 1,
    NearExpiryDays         INT NOT NULL CONSTRAINT DF_InvSettings_Near DEFAULT 60,
    ModifiedBy             INT NULL,
    ModifiedOn             DATETIME NULL
);
GO

IF OBJECT_ID(N'dbo.InvAdjReason', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvAdjReason
    (
        ReasonCode  VARCHAR(12) NOT NULL CONSTRAINT PK_InvAdjReason PRIMARY KEY,
        ReasonName  NVARCHAR(80) NOT NULL,
        Direction   SMALLINT NOT NULL,          -- -1 stock out, +1 stock in
        IsUsage     BIT NOT NULL,               -- out for use (QC, calibration): consumption, not a loss
        SortOrder   INT NOT NULL,
        IsActive    BIT NOT NULL CONSTRAINT DF_InvAdjReason_Active DEFAULT 1
    );
    INSERT INTO dbo.InvAdjReason (ReasonCode, ReasonName, Direction, IsUsage, SortOrder) VALUES
        ('QC_RUN',  N'QC / control run',               -1, 1, 10),
        ('CALIB',   N'Calibration',                    -1, 1, 20),
        ('MAINT',   N'Maintenance / wash / priming',   -1, 1, 30),
        ('DEMO',    N'Training / validation run',      -1, 1, 40),
        ('EXPIRED', N'Expired',                        -1, 0, 50),
        ('BREAK',   N'Breakage / damage',              -1, 0, 60),
        ('SPILL',   N'Spillage / leakage',             -1, 0, 70),
        ('TEMP',    N'Temperature excursion',          -1, 0, 80),
        ('RECALL',  N'Manufacturer recall',            -1, 0, 90),
        ('OPENSTAB',N'Open-vial stability over',       -1, 0, 100),
        ('LOSS',    N'Lost / not traceable',           -1, 0, 110),
        ('FOUND',   N'Found / excess stock',            1, 0, 200),
        ('OTHER_IN',N'Other increase',                  1, 0, 210);
END
GO

IF OBJECT_ID(N'dbo.InvLot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvLot
    (
        LotId          INT IDENTITY(1,1) CONSTRAINT PK_InvLot PRIMARY KEY,
        CompanyId      INT NOT NULL,
        ItemId         INT NOT NULL CONSTRAINT FK_InvLot_Item REFERENCES dbo.InvItem(ItemId),
        LotNo          NVARCHAR(50) NOT NULL,          -- 'NA' for an item that is not lot tracked
        ExpiryDate     DATE NULL,
        MfgDate        DATE NULL,
        Status         VARCHAR(12) NOT NULL,           -- QUARANTINE | ACCEPTED | REJECTED | BLOCKED
        UnitCost       DECIMAL(18,6) NULL,             -- landed cost per consumption unit at first receipt
        SupplierId     INT NULL,
        FirstDocId     INT NULL,                       -- the GRN / opening stock that created it
        DecisionBy     INT NULL,
        DecisionOn     DATETIME NULL,
        DecisionNote   NVARCHAR(1000) NULL,            -- lot-to-lot verification result, rejection or block reason
        CreatedBy      INT NULL,
        CreatedOn      DATETIME NOT NULL CONSTRAINT DF_InvLot_Created DEFAULT GETDATE(),
        CONSTRAINT CK_InvLot_Status CHECK (Status IN ('QUARANTINE', 'ACCEPTED', 'REJECTED', 'BLOCKED'))
    );
    CREATE UNIQUE INDEX UX_InvLot ON dbo.InvLot(CompanyId, ItemId, LotNo, ExpiryDate);
    CREATE INDEX IX_InvLot_Status ON dbo.InvLot(CompanyId, Status);
END
GO

IF OBJECT_ID(N'dbo.InvStockBalance', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvStockBalance
    (
        StoreId    INT NOT NULL CONSTRAINT FK_InvStockBalance_Store REFERENCES dbo.InvStore(StoreId),
        LotId      INT NOT NULL CONSTRAINT FK_InvStockBalance_Lot REFERENCES dbo.InvLot(LotId),
        ItemId     INT NOT NULL,
        Qty        DECIMAL(18,4) NOT NULL,
        OpenedOn   DATE NULL,                          -- first container of this lot opened in this store
        OpenedBy   INT NULL,
        LastMoveOn DATETIME NULL,
        CONSTRAINT PK_InvStockBalance PRIMARY KEY (StoreId, LotId),
        CONSTRAINT CK_InvStockBalance_Qty CHECK (Qty >= 0)
    );
    CREATE INDEX IX_InvStockBalance_Item ON dbo.InvStockBalance(ItemId) INCLUDE (Qty, StoreId);
END
GO

IF OBJECT_ID(N'dbo.InvStockLedger', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvStockLedger
    (
        LedgerId     BIGINT IDENTITY(1,1) CONSTRAINT PK_InvStockLedger PRIMARY KEY,
        CompanyId    INT NOT NULL,
        BranchId     INT NOT NULL,
        StoreId      INT NOT NULL,
        ItemId       INT NOT NULL,
        LotId        INT NOT NULL,
        TxnOn        DATETIME NOT NULL,
        DocType      VARCHAR(6) NOT NULL,              -- OPN GRN PRET ISSO ISSI ADJ CNT CONS
        DocId        INT NOT NULL,                     -- InvDoc.DocId; CONS: QcConsumption.ConsumptionId
        DocNo        NVARCHAR(40) NULL,
        DocLineId    INT NULL,                         -- InvDocLine.LineId; CONS: QcConsumptionLine.ConsumptionLineId
        QtyIn        DECIMAL(18,4) NOT NULL,
        QtyOut       DECIMAL(18,4) NOT NULL,
        UnitCost     DECIMAL(18,6) NOT NULL,
        Value        DECIMAL(18,2) NOT NULL,           -- + in / - out
        BalanceAfter DECIMAL(18,4) NOT NULL,           -- store x lot balance after this row
        Remarks      NVARCHAR(300) NULL,
        UserId       INT NULL,
        CreatedOn    DATETIME NOT NULL CONSTRAINT DF_InvStockLedger_Created DEFAULT GETDATE()
    );
    CREATE INDEX IX_InvStockLedger_Item ON dbo.InvStockLedger(ItemId, StoreId, TxnOn);
    CREATE INDEX IX_InvStockLedger_Doc ON dbo.InvStockLedger(DocType, DocId);
    CREATE INDEX IX_InvStockLedger_Branch ON dbo.InvStockLedger(BranchId, TxnOn) INCLUDE (DocType, Value);
    CREATE INDEX IX_InvStockLedger_Lot ON dbo.InvStockLedger(LotId);
END
GO

IF OBJECT_ID(N'dbo.InvDoc', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvDoc
    (
        DocId           INT IDENTITY(1,1) CONSTRAINT PK_InvDoc PRIMARY KEY,
        CompanyId       INT NOT NULL,
        BranchId        INT NOT NULL,                  -- the branch of StoreId (the branch that works on it)
        DocType         VARCHAR(6) NOT NULL,           -- OPN PO GRN PRET IND ISS ADJ CNT
        DocNo           NVARCHAR(40) NOT NULL,
        DocDate         DATE NOT NULL,
        Status          VARCHAR(12) NOT NULL,          -- DRAFT SUBMITTED APPROVED REJECTED PARTIAL CLOSED POSTED INTRANSIT RECEIVED CANCELLED
        StoreId         INT NOT NULL,                  -- OPN/PO/GRN/PRET/ADJ/CNT: the store; IND: requesting store; ISS: from store
        ToStoreId       INT NULL,                      -- IND: store asked from; ISS: receiving store
        SupplierId      INT NULL,
        RefDocId        INT NULL,                      -- GRN -> PO, PRET -> GRN, ISS -> IND
        SupplierInvNo   NVARCHAR(50) NULL,
        SupplierInvDate DATE NULL,
        ExpectedDate    DATE NULL,                     -- PO delivery / IND needed by
        IsInterState    BIT NOT NULL CONSTRAINT DF_InvDoc_Igst DEFAULT 0,
        ReasonCode      VARCHAR(12) NULL,              -- ADJ / PRET reason
        CategoryId      INT NULL,                      -- CNT: counted category (NULL = all)
        Priority        VARCHAR(10) NULL,              -- IND: Normal | Urgent
        Terms           NVARCHAR(1000) NULL,           -- PO terms
        GrossAmount     DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDoc_Gross DEFAULT 0,
        DiscountAmount  DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDoc_Disc DEFAULT 0,
        TaxableAmount   DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDoc_Taxable DEFAULT 0,
        GstAmount       DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDoc_Gst DEFAULT 0,
        OtherCharges    DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDoc_Other DEFAULT 0,
        RoundOff        DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDoc_Round DEFAULT 0,
        NetAmount       DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDoc_Net DEFAULT 0,
        StockValue      DECIMAL(18,2) NULL,            -- value moved when posted (ADJ / CNT / OPN / ISS)
        Remarks         NVARCHAR(1000) NULL,
        CreatedBy       INT NULL,
        CreatedOn       DATETIME NOT NULL CONSTRAINT DF_InvDoc_Created DEFAULT GETDATE(),
        ModifiedBy      INT NULL,
        ModifiedOn      DATETIME NULL,
        SubmittedBy     INT NULL,
        SubmittedOn     DATETIME NULL,
        ApprovedBy      INT NULL,
        ApprovedOn      DATETIME NULL,
        RejectedBy      INT NULL,
        RejectedOn      DATETIME NULL,
        RejectReason    NVARCHAR(500) NULL,
        PostedBy        INT NULL,                      -- GRN/PRET/OPN/ADJ/CNT posted, ISS dispatched
        PostedOn        DATETIME NULL,
        ReceivedBy      INT NULL,
        ReceivedOn      DATETIME NULL,
        ClosedBy        INT NULL,
        ClosedOn        DATETIME NULL,
        CancelledBy     INT NULL,
        CancelledOn     DATETIME NULL,
        CancelReason    NVARCHAR(500) NULL,
        VoucherNo       NVARCHAR(50) NULL,
        CONSTRAINT CK_InvDoc_Type CHECK (DocType IN ('OPN', 'PO', 'GRN', 'PRET', 'IND', 'ISS', 'ADJ', 'CNT'))
    );
    CREATE UNIQUE INDEX UX_InvDoc_No ON dbo.InvDoc(CompanyId, DocNo);
    CREATE INDEX IX_InvDoc_Branch ON dbo.InvDoc(BranchId, DocType, Status, DocDate);
    CREATE INDEX IX_InvDoc_Ref ON dbo.InvDoc(RefDocId) WHERE RefDocId IS NOT NULL;
    CREATE INDEX IX_InvDoc_ToStore ON dbo.InvDoc(ToStoreId, DocType, Status) WHERE ToStoreId IS NOT NULL;
END
GO

IF OBJECT_ID(N'dbo.InvDocLine', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvDocLine
    (
        LineId          INT IDENTITY(1,1) CONSTRAINT PK_InvDocLine PRIMARY KEY,
        DocId           INT NOT NULL CONSTRAINT FK_InvDocLine_Doc REFERENCES dbo.InvDoc(DocId),
        SeqNo           INT NOT NULL,
        ItemId          INT NOT NULL CONSTRAINT FK_InvDocLine_Item REFERENCES dbo.InvItem(ItemId),
        LotId           INT NULL,                      -- the lot moved (posted GRN / OPN: the lot created)
        LotNo           NVARCHAR(50) NULL,             -- GRN / OPN entry
        ExpiryDate      DATE NULL,
        MfgDate         DATE NULL,
        UnitMode        CHAR(1) NOT NULL CONSTRAINT DF_InvDocLine_Mode DEFAULT 'P',   -- P = purchase unit (pack), C = consumption unit
        Factor          DECIMAL(18,4) NOT NULL CONSTRAINT DF_InvDocLine_Factor DEFAULT 1,   -- consumption units per entry unit
        Qty             DECIMAL(18,4) NOT NULL,        -- in the entry unit
        FreeQty         DECIMAL(18,4) NOT NULL CONSTRAINT DF_InvDocLine_Free DEFAULT 0,
        BaseQty         DECIMAL(18,4) NOT NULL,        -- consumption units (Qty x Factor)
        BaseFreeQty     DECIMAL(18,4) NOT NULL CONSTRAINT DF_InvDocLine_BaseFree DEFAULT 0,
        Sign            SMALLINT NOT NULL CONSTRAINT DF_InvDocLine_Sign DEFAULT 1,     -- ADJ: -1 out, +1 in
        Rate            DECIMAL(18,4) NOT NULL CONSTRAINT DF_InvDocLine_Rate DEFAULT 0,   -- per entry unit, before GST
        DiscPct         DECIMAL(9,4) NOT NULL CONSTRAINT DF_InvDocLine_DiscPct DEFAULT 0,
        GstPct          DECIMAL(9,4) NOT NULL CONSTRAINT DF_InvDocLine_GstPct DEFAULT 0,
        GrossAmount     DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDocLine_Gross DEFAULT 0,
        DiscountAmount  DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDocLine_Disc DEFAULT 0,
        TaxableAmount   DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDocLine_Taxable DEFAULT 0,
        GstAmount       DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDocLine_Gst DEFAULT 0,
        LineAmount      DECIMAL(18,2) NOT NULL CONSTRAINT DF_InvDocLine_Amount DEFAULT 0,
        UnitCost        DECIMAL(18,6) NULL,            -- per consumption unit as posted
        RefLineId       INT NULL,                      -- GRN -> PO line, ISS -> IND line
        DoneBaseQty     DECIMAL(18,4) NOT NULL CONSTRAINT DF_InvDocLine_Done DEFAULT 0,   -- PO: received; IND: issued; ISS: received
        SystemBaseQty   DECIMAL(18,4) NULL,            -- CNT: book stock at the snapshot
        CountedBaseQty  DECIMAL(18,4) NULL,            -- CNT: counted (NULL = not counted)
        Remarks         NVARCHAR(300) NULL,
        CONSTRAINT CK_InvDocLine_Qty CHECK (Qty >= 0 AND FreeQty >= 0)
    );
    CREATE INDEX IX_InvDocLine_Doc ON dbo.InvDocLine(DocId);
    CREATE INDEX IX_InvDocLine_Item ON dbo.InvDocLine(ItemId);
    CREATE INDEX IX_InvDocLine_Ref ON dbo.InvDocLine(RefLineId) WHERE RefLineId IS NOT NULL;
END
GO

IF OBJECT_ID(N'dbo.InvDocCounter', N'U') IS NULL
CREATE TABLE dbo.InvDocCounter
(
    BranchId INT NOT NULL,
    DocType  VARCHAR(6) NOT NULL,
    FinYear  CHAR(4) NOT NULL,
    LastNo   INT NOT NULL,
    CONSTRAINT PK_InvDocCounter PRIMARY KEY (BranchId, DocType, FinYear)
);
GO

IF OBJECT_ID(N'dbo.InvConsumptionPosting', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InvConsumptionPosting
    (
        PostingId  INT IDENTITY(1,1) CONSTRAINT PK_InvConsumptionPosting PRIMARY KEY,
        CompanyId  INT NOT NULL,
        BranchId   INT NOT NULL,
        PostDate   DATE NOT NULL,
        Amount     DECIMAL(18,2) NOT NULL,
        VoucherNo  NVARCHAR(50) NULL,
        PostedBy   INT NULL,
        PostedOn   DATETIME NOT NULL CONSTRAINT DF_InvConsumptionPosting_On DEFAULT GETDATE()
    );
    CREATE UNIQUE INDEX UX_InvConsumptionPosting ON dbo.InvConsumptionPosting(BranchId, PostDate);
END
GO

-- ── 3. Accounts: ledgers ───────────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'QC_STOCK')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT N'Lab Stock-in-Hand', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'QC_STOCK', 'Asset', 1, N'Lab reagent and consumable stock at cost (Quality & Compliance > Stock Management).'
    FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Current Assets';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'QC_CONSUMPTION')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT N'Lab Reagent & Consumables Consumption', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'QC_CONSUMPTION', 'EXPENSE', 1, N'Reagents and consumables used by tests, QC runs and calibration.'
    FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Direct Expenses';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'QC_WRITEOFF')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT N'Lab Stock Loss / Write-off', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'QC_WRITEOFF', 'EXPENSE', 1, N'Expiry, breakage, count differences and transit loss of lab stock.'
    FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Indirect Expenses';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'GST Input Credit')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerType, IsSystem)
    SELECT 'GST Input Credit', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'Asset', 1 FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Current Assets';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_VoucherType WHERE VoucherTypeCode = 'PUR')
    INSERT dbo.Acc_VoucherType (VoucherTypeName, Prefix, IsActive, VoucherTypeCode, IsManual) VALUES ('Purchase', 'PUR', 1, 'PUR', 0);
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_VoucherType WHERE VoucherTypeCode = 'DN')
    INSERT dbo.Acc_VoucherType (VoucherTypeName, Prefix, IsActive, VoucherTypeCode, IsManual) VALUES ('Debit Note', 'DN', 1, 'DN', 0);
GO

-- ── 4. Helpers ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER FUNCTION dbo.ufn_Inv_Settings (@CompanyId INT)
RETURNS TABLE
AS RETURN
(
    SELECT TOP 1 * FROM (
        SELECT PoApprovalRequired, AdjApprovalRequired, CountApprovalRequired, LotAcceptanceRequired, DeductOnConsumption, NearExpiryDays, 0 AS Pref
        FROM dbo.InvSettings WHERE CompanyId = @CompanyId
        UNION ALL
        SELECT CAST(1 AS BIT), CAST(1 AS BIT), CAST(1 AS BIT), CAST(1 AS BIT), CAST(1 AS BIT), 60, 1) s
    ORDER BY Pref
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_Inv_NextNumber @BranchId INT, @DocType VARCHAR(6), @DocDate DATE, @DocNo NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @y INT = CASE WHEN MONTH(@DocDate) >= 4 THEN YEAR(@DocDate) ELSE YEAR(@DocDate) - 1 END, @no INT;
    DECLARE @fy CHAR(4) = RIGHT(CAST(@y AS VARCHAR(4)), 2) + RIGHT(CAST(@y + 1 AS VARCHAR(4)), 2);
    DECLARE @prefix VARCHAR(4) = CASE @DocType WHEN 'OPN' THEN 'QOS' WHEN 'PO' THEN 'QPO' WHEN 'GRN' THEN 'QGR' WHEN 'PRET' THEN 'QPR'
                                              WHEN 'IND' THEN 'QIN' WHEN 'ISS' THEN 'QIS' WHEN 'ADJ' THEN 'QAD' WHEN 'CNT' THEN 'QSC' END;
    IF @prefix IS NULL THROW 53500, 'Unknown stock document type.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.InvDocCounter WITH (UPDLOCK, HOLDLOCK) WHERE BranchId = @BranchId AND DocType = @DocType AND FinYear = @fy)
        INSERT dbo.InvDocCounter (BranchId, DocType, FinYear, LastNo) VALUES (@BranchId, @DocType, @fy, 0);
    UPDATE dbo.InvDocCounter SET @no = LastNo = LastNo + 1 WHERE BranchId = @BranchId AND DocType = @DocType AND FinYear = @fy;
    DECLARE @bc NVARCHAR(20) = ISNULL((SELECT NULLIF(LTRIM(RTRIM(BranchCode)), '') FROM dbo.Branchmaster WHERE BranchID = @BranchId), CAST(@BranchId AS NVARCHAR(10)));
    SET @DocNo = CONCAT(@prefix, '/', @bc, '/', @fy, '/', RIGHT('00000' + CAST(@no AS VARCHAR(12)), 5));
END;
GO

-- find or create a lot (an item that is not lot tracked keeps one lot 'NA' per expiry)
CREATE OR ALTER PROCEDURE dbo.usp_Inv_GetLot
    @CompanyId INT, @ItemId INT, @LotNo NVARCHAR(50), @ExpiryDate DATE, @MfgDate DATE, @UnitCost DECIMAL(18,6),
    @SupplierId INT, @DocId INT, @Quarantine BIT, @UserId INT, @LotId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @LotNo = ISNULL(NULLIF(LTRIM(RTRIM(@LotNo)), ''), N'NA');
    SELECT @LotId = LotId FROM dbo.InvLot WITH (UPDLOCK, HOLDLOCK)
    WHERE CompanyId = @CompanyId AND ItemId = @ItemId AND LotNo = @LotNo AND ((ExpiryDate IS NULL AND @ExpiryDate IS NULL) OR ExpiryDate = @ExpiryDate);
    IF @LotId IS NOT NULL RETURN;
    INSERT dbo.InvLot (CompanyId, ItemId, LotNo, ExpiryDate, MfgDate, Status, UnitCost, SupplierId, FirstDocId, CreatedBy)
    VALUES (@CompanyId, @ItemId, @LotNo, @ExpiryDate, @MfgDate, CASE WHEN @Quarantine = 1 THEN 'QUARANTINE' ELSE 'ACCEPTED' END,
            @UnitCost, @SupplierId, @DocId, @UserId);
    SET @LotId = SCOPE_IDENTITY();
END;
GO

-- ── 5. The only stock writer ───────────────────────────────────────────────────────────────────────────────
-- @Qty signed (+ in, - out) in consumption units. @UnitCost: in = cost of what comes in; NULL = the item's
-- average. @UpdateAvg = 1 re-averages the item (receipts, opening stock, purchase returns).
CREATE OR ALTER PROCEDURE dbo.usp_Inv_Move
    @CompanyId INT, @StoreId INT, @ItemId INT, @LotId INT, @Qty DECIMAL(18,4), @UnitCost DECIMAL(18,6) = NULL, @UpdateAvg BIT = 0,
    @DocType VARCHAR(6), @DocId INT, @DocNo NVARCHAR(40) = NULL, @DocLineId INT = NULL, @Remarks NVARCHAR(300) = NULL,
    @UserId INT = NULL, @TxnOn DATETIME = NULL, @ValueOut DECIMAL(18,2) = NULL OUTPUT, @CostOut DECIMAL(18,6) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @ValueOut = 0;
    IF @Qty = 0 RETURN;
    DECLARE @branch INT, @bal DECIMAL(18,4), @avg DECIMAL(18,6), @cost DECIMAL(18,6), @q0 DECIMAL(18,4), @new DECIMAL(18,6), @msg NVARCHAR(500);
    SELECT @branch = BranchId FROM dbo.InvStore WHERE StoreId = @StoreId AND CompanyId = @CompanyId AND IsDeleted = 0;
    IF @branch IS NULL THROW 53501, 'The store was not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.InvLot WHERE LotId = @LotId AND ItemId = @ItemId AND CompanyId = @CompanyId) THROW 53502, 'The lot does not belong to this item.', 1;

    SELECT @avg = AvgUnitCost FROM dbo.InvItem WITH (UPDLOCK, ROWLOCK) WHERE ItemId = @ItemId AND CompanyId = @CompanyId;   -- serialises the item
    SELECT @bal = Qty FROM dbo.InvStockBalance WITH (UPDLOCK, HOLDLOCK) WHERE StoreId = @StoreId AND LotId = @LotId;
    SET @bal = ISNULL(@bal, 0);
    IF @Qty < 0 AND @bal + @Qty < 0
    BEGIN
        SELECT @msg = CONCAT(N'Not enough stock of ', i.ItemName, CASE WHEN l.LotNo <> N'NA' THEN N' lot ' + l.LotNo ELSE N'' END, N' in ', s.StoreName,
                             N': available ', FORMAT(@bal, '0.####'), N' ', u.UnitName, N', needed ', FORMAT(-@Qty, '0.####'), N'.')
        FROM dbo.InvItem i JOIN dbo.InvLot l ON l.LotId = @LotId JOIN dbo.InvStore s ON s.StoreId = @StoreId JOIN dbo.InvUnit u ON u.UnitId = i.ConsumptionUnitId
        WHERE i.ItemId = @ItemId;
        THROW 53503, @msg, 1;
    END

    SET @cost = ISNULL(@UnitCost, ISNULL(@avg, dbo.ufn_Qc_ItemUnitCost(@ItemId)));
    IF @UpdateAvg = 1
    BEGIN
        SELECT @q0 = ISNULL(SUM(b.Qty), 0) FROM dbo.InvStockBalance b JOIN dbo.InvStore s ON s.StoreId = b.StoreId
        WHERE b.ItemId = @ItemId AND s.CompanyId = @CompanyId;
        IF @avg IS NULL OR @q0 <= 0 SET @new = CASE WHEN @Qty > 0 THEN @cost ELSE ISNULL(@avg, @cost) END;
        ELSE IF @q0 + @Qty > 0 SET @new = (@q0 * @avg + @Qty * @cost) / (@q0 + @Qty);
        ELSE SET @new = @avg;
        IF @new IS NULL OR @new < 0 SET @new = ISNULL(@avg, @cost);
        UPDATE dbo.InvItem SET AvgUnitCost = CAST(@new AS DECIMAL(14,4)) WHERE ItemId = @ItemId;
    END

    IF EXISTS (SELECT 1 FROM dbo.InvStockBalance WHERE StoreId = @StoreId AND LotId = @LotId)
        UPDATE dbo.InvStockBalance SET Qty = Qty + @Qty, LastMoveOn = GETDATE() WHERE StoreId = @StoreId AND LotId = @LotId;
    ELSE
        INSERT dbo.InvStockBalance (StoreId, LotId, ItemId, Qty, LastMoveOn) VALUES (@StoreId, @LotId, @ItemId, @Qty, GETDATE());

    SET @ValueOut = ROUND(@Qty * @cost, 2);
    SET @CostOut = @cost;
    INSERT dbo.InvStockLedger (CompanyId, BranchId, StoreId, ItemId, LotId, TxnOn, DocType, DocId, DocNo, DocLineId, QtyIn, QtyOut, UnitCost, Value, BalanceAfter, Remarks, UserId)
    VALUES (@CompanyId, @branch, @StoreId, @ItemId, @LotId, ISNULL(@TxnOn, GETDATE()), @DocType, @DocId, @DocNo, @DocLineId,
            CASE WHEN @Qty > 0 THEN @Qty ELSE 0 END, CASE WHEN @Qty < 0 THEN -@Qty ELSE 0 END, @cost, @ValueOut, @bal + @Qty, @Remarks, @UserId);
END;
GO

-- ── 6. Accounts posting ────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Inv_SupplierLedger @SupplierId INT, @LedgerId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @LedgerId = s.LedgerId FROM dbo.InvSupplier s JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = s.LedgerId WHERE s.SupplierId = @SupplierId;
    IF @LedgerId IS NOT NULL RETURN;
    DECLARE @name NVARCHAR(200), @code NVARCHAR(50) = CONCAT('QC_SUP_', @SupplierId);
    SELECT @name = LEFT(SupplierName, 160) + N' (' + SupplierCode + N', lab)' FROM dbo.InvSupplier WHERE SupplierId = @SupplierId;
    SELECT @LedgerId = LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = @code;
    IF @LedgerId IS NULL
    BEGIN
        INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
        SELECT @name, LedgerGroupId, 0, 'Cr', 1, GETDATE(), @code, 'PARTY', 1, N'Lab supplier (Quality & Compliance > Supplier Master).'
        FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Sundry Creditors';
        SET @LedgerId = SCOPE_IDENTITY();
    END
    UPDATE dbo.InvSupplier SET LedgerId = @LedgerId WHERE SupplierId = @SupplierId;
END;
GO

-- @Kind: GRN | PRET | OPN | ADJ | CNT | TLOSS (issue received short) ; posts once per reference
CREATE OR ALTER PROCEDURE dbo.usp_Inv_PostLedger @Kind VARCHAR(6), @DocId INT, @UserId INT = NULL, @Amount DECIMAL(18,2) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @stock INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'QC_STOCK'),
            @use INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'QC_CONSUMPTION'),
            @loss INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'QC_WRITEOFF'),
            @gstIn INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'GST Input Credit'),
            @round INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Round Off'),
            @opening INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Opening Balance Difference');
    IF @stock IS NULL OR @use IS NULL OR @loss IS NULL OR @gstIn IS NULL THROW 53590, 'Accounts ledgers for lab stock are missing (run SQLScripts/2498).', 1;
    DECLARE @co INT, @br INT, @date DATETIME, @no NVARCHAR(40), @sup INT, @supName NVARCHAR(200), @supLedger INT, @lines NVARCHAR(MAX), @narr NVARCHAR(500),
            @taxable DECIMAL(18,2), @gst DECIMAL(18,2), @other DECIMAL(18,2), @ro DECIMAL(18,2), @net DECIMAL(18,2), @tid BIGINT, @vno NVARCHAR(50),
            @vtype VARCHAR(10), @ref NVARCHAR(50);
    SELECT @co = d.CompanyId, @br = d.BranchId, @date = ISNULL(d.PostedOn, d.DocDate), @no = d.DocNo, @sup = d.SupplierId, @supName = s.SupplierName,
           @taxable = d.TaxableAmount, @gst = d.GstAmount, @other = d.OtherCharges, @ro = d.RoundOff, @net = d.NetAmount
    FROM dbo.InvDoc d LEFT JOIN dbo.InvSupplier s ON s.SupplierId = d.SupplierId WHERE d.DocId = @DocId;
    IF @co IS NULL RETURN;
    SET @date = CAST(CAST(@date AS DATE) AS DATETIME);

    IF @Kind = 'GRN'
    BEGIN
        IF @net = 0 RETURN;
        EXEC dbo.usp_Inv_SupplierLedger @sup, @supLedger OUTPUT;
        SELECT @vtype = 'PUR', @ref = 'QC_GRN', @narr = (SELECT CONCAT(N'Lab stock purchase ', d.DocNo, N' - ', @supName, N' bill ', d.SupplierInvNo,
                       CASE WHEN d.SupplierInvDate IS NOT NULL THEN N' dt ' + FORMAT(d.SupplierInvDate, 'dd-MMM-yyyy') ELSE N'' END) FROM dbo.InvDoc d WHERE d.DocId = @DocId);
        SET @lines = (SELECT * FROM (VALUES
                (@stock, @taxable + @other, 0, N'Lab stock at cost'),
                (@gstIn, @gst, 0, N'Input GST'),
                (@round, CASE WHEN @ro > 0 THEN @ro ELSE 0 END, CASE WHEN @ro < 0 THEN -@ro ELSE 0 END, N'Round off'),
                (@supLedger, 0, @net, N'Supplier bill')) v (LedgerId, Dr, Cr, Narration)
            WHERE v.Dr > 0 OR v.Cr > 0 FOR JSON PATH);
    END
    ELSE IF @Kind = 'PRET'
    BEGIN
        IF @net = 0 RETURN;
        EXEC dbo.usp_Inv_SupplierLedger @sup, @supLedger OUTPUT;
        SELECT @vtype = 'DN', @ref = 'QC_PRET', @narr = CONCAT(N'Lab stock purchase return (debit note) ', @no, N' - ', @supName);
        SET @lines = (SELECT * FROM (VALUES
                (@supLedger, @net, 0, N'Debit note'),
                (@stock, 0, @taxable, N'Stock returned'),
                (@gstIn, 0, @gst, N'Input GST reversed'),
                (@round, CASE WHEN @ro < 0 THEN -@ro ELSE 0 END, CASE WHEN @ro > 0 THEN @ro ELSE 0 END, N'Round off')) v (LedgerId, Dr, Cr, Narration)
            WHERE v.Dr > 0 OR v.Cr > 0 FOR JSON PATH);
    END
    ELSE IF @Kind = 'OPN'
    BEGIN
        IF @opening IS NULL THROW 53591, 'The ledger "Opening Balance Difference" is missing (Accounts).', 1;
        SET @net = (SELECT ISNULL(SUM(Value), 0) FROM dbo.InvStockLedger WHERE DocType = 'OPN' AND DocId = @DocId);
        IF @net <= 0 RETURN;
        SELECT @vtype = 'JRN', @ref = 'QC_OPN', @narr = CONCAT(N'Lab opening stock ', @no);
        SET @lines = (SELECT * FROM (VALUES (@stock, @net, 0, N'Opening stock'), (@opening, 0, @net, N'Opening stock')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
    END
    ELSE IF @Kind IN ('ADJ', 'CNT', 'TLOSS')
    BEGIN
        DECLARE @u DECIMAL(18,2) = 0, @l DECIMAL(18,2) = 0;   -- usage out; loss out (negative = gain)
        IF @Kind = 'ADJ'
            SELECT @u = ISNULL(SUM(CASE WHEN r.IsUsage = 1 THEN -g.Value ELSE 0 END), 0),
                   @l = ISNULL(SUM(CASE WHEN r.IsUsage = 0 THEN -g.Value ELSE 0 END), 0)
            FROM dbo.InvStockLedger g JOIN dbo.InvDoc d ON d.DocId = g.DocId JOIN dbo.InvAdjReason r ON r.ReasonCode = d.ReasonCode
            WHERE g.DocType = 'ADJ' AND g.DocId = @DocId;
        ELSE IF @Kind = 'CNT'
            SELECT @l = ISNULL(-SUM(Value), 0) FROM dbo.InvStockLedger WHERE DocType = 'CNT' AND DocId = @DocId;
        ELSE
            SET @l = ISNULL(@Amount, 0);
        IF @u = 0 AND @l = 0 RETURN;
        SELECT @vtype = 'JRN', @ref = 'QC_' + @Kind,
               @narr = CONCAT(CASE @Kind WHEN 'ADJ' THEN N'Lab stock adjustment ' WHEN 'CNT' THEN N'Lab physical stock count ' ELSE N'Lab stock transit shortage ' END, @no);
        SET @lines = (SELECT * FROM (VALUES
                (@use, CASE WHEN @u > 0 THEN @u ELSE 0 END, CASE WHEN @u < 0 THEN -@u ELSE 0 END, N'Used (QC / calibration / maintenance)'),
                (@loss, CASE WHEN @l > 0 THEN @l ELSE 0 END, CASE WHEN @l < 0 THEN -@l ELSE 0 END, CASE WHEN @l > 0 THEN N'Stock loss / write-off' ELSE N'Stock found / excess' END),
                (@stock, CASE WHEN @u + @l < 0 THEN -(@u + @l) ELSE 0 END, CASE WHEN @u + @l > 0 THEN @u + @l ELSE 0 END, N'Lab stock')) v (LedgerId, Dr, Cr, Narration)
            WHERE v.Dr > 0 OR v.Cr > 0 FOR JSON PATH);
    END
    ELSE THROW 53592, 'Unknown posting kind.', 1;

    EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = @vtype, @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = @ref, @ReferenceId = @DocId,
         @Narration = @narr, @PayeeName = @supName, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    IF @Kind <> 'TLOSS' UPDATE dbo.InvDoc SET VoucherNo = @vno WHERE DocId = @DocId;
END;
GO

-- one journal per branch per day for lab consumption (tests, from usp_Inv_ConsumeLines), days before @UpTo
CREATE OR ALTER PROCEDURE dbo.usp_Inv_PostConsumptionAccounts @CompanyId INT, @BranchId INT, @UpTo DATE, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @stock INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'QC_STOCK'),
            @use INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'QC_CONSUMPTION');
    IF @stock IS NULL OR @use IS NULL RETURN;
    DECLARE @d DATE, @amt DECIMAL(18,2), @pid INT, @lines NVARCHAR(MAX), @tid BIGINT, @vno NVARCHAR(50), @narr NVARCHAR(300);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT CAST(g.TxnOn AS DATE), -SUM(g.Value) FROM dbo.InvStockLedger g
        WHERE g.BranchId = @BranchId AND g.CompanyId = @CompanyId AND g.DocType = 'CONS' AND g.TxnOn < @UpTo
          AND NOT EXISTS (SELECT 1 FROM dbo.InvConsumptionPosting p WHERE p.BranchId = @BranchId AND p.PostDate = CAST(g.TxnOn AS DATE))
        GROUP BY CAST(g.TxnOn AS DATE) ORDER BY 1;
    OPEN c; FETCH NEXT FROM c INTO @d, @amt;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRANSACTION;
            INSERT dbo.InvConsumptionPosting (CompanyId, BranchId, PostDate, Amount, PostedBy) VALUES (@CompanyId, @BranchId, @d, @amt, @UserId);
            SET @pid = SCOPE_IDENTITY();
            IF @amt > 0
            BEGIN
                SET @narr = CONCAT(N'Lab reagent consumption by tests on ', FORMAT(@d, 'dd-MMM-yyyy'));
                SET @lines = (SELECT * FROM (VALUES (@use, @amt, 0, N'Reagents used by tests'), (@stock, 0, @amt, N'Lab stock')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
                SET @tid = NULL; SET @vno = NULL;
                EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'JRN', @TransactionDate = @d, @CompanyId = @CompanyId, @BranchId = @BranchId, @ReferenceType = 'QC_CONS',
                     @ReferenceId = @pid, @Narration = @narr, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
                UPDATE dbo.InvConsumptionPosting SET VoucherNo = @vno WHERE PostingId = @pid;
            END
        COMMIT TRANSACTION;
        FETCH NEXT FROM c INTO @d, @amt;
    END
    CLOSE c; DEALLOCATE c;
END;
GO

-- ── 7. Lab consumption -> stock ────────────────────────────────────────────────────────────────────────────
-- the store a run takes from: the department's bench store when it has had stock, else the branch Main Store
CREATE OR ALTER FUNCTION dbo.ufn_Inv_ConsumeStore (@BranchId INT, @DepartmentId INT)
RETURNS INT
AS
BEGIN
    DECLARE @s INT;
    SELECT TOP 1 @s = s.StoreId FROM dbo.InvStore s
    WHERE s.BranchId = @BranchId AND s.StoreType = 'Bench' AND s.DepartmentId = @DepartmentId AND s.Status = 1 AND s.IsDeleted = 0
      AND EXISTS (SELECT 1 FROM dbo.InvStockLedger g WHERE g.StoreId = s.StoreId)
    ORDER BY s.StoreId;
    IF @s IS NULL
        SELECT TOP 1 @s = s.StoreId FROM dbo.InvStore s
        WHERE s.BranchId = @BranchId AND s.StoreType = 'Main' AND s.Status = 1 AND s.IsDeleted = 0
        ORDER BY s.StoreId;
    RETURN @s;
END;
GO

-- takes consumption lines out of stock: all lines of a bill (@LabOrderId) not yet processed, or given lines (retry).
-- A line is all-or-nothing: enough stock in accepted, unexpired lots -> POSTED; else PENDING (nothing taken).
CREATE OR ALTER PROCEDURE dbo.usp_Inv_ConsumeLines @LabOrderId INT = NULL, @LineIds NVARCHAR(MAX) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    CREATE TABLE #C (LineId INT PRIMARY KEY, ConsumptionId INT, CompanyId INT, BranchId INT, ItemId INT, Qty DECIMAL(18,4), DepartmentId INT, DocNo NVARCHAR(40));
    INSERT #C
    SELECT l.ConsumptionLineId, c.ConsumptionId, c.CompanyId, c.BranchId, l.ItemId, l.Qty, m.Department_ID,
           LEFT(ISNULL(lo.BillNo, CONCAT(N'Order ', c.LabOrderId)), 40)
    FROM dbo.QcConsumptionLine l
    JOIN dbo.QcConsumption c ON c.ConsumptionId = l.ConsumptionId
    LEFT JOIN dbo.LabInvestigationMaster m ON m.Test_ID = c.TestId
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = c.LabOrderId
    WHERE c.Status = 'CONSUMED' AND l.Qty > 0
      AND ((@LabOrderId IS NOT NULL AND c.LabOrderId = @LabOrderId AND l.StockStatus IS NULL)
        OR (@LineIds IS NOT NULL AND l.ConsumptionLineId IN (SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(@LineIds, ',')) AND l.StockStatus IN ('PENDING')));
    IF NOT EXISTS (SELECT 1 FROM #C) RETURN;

    DECLARE @line INT, @cid INT, @co INT, @br INT, @item INT, @qty DECIMAL(18,4), @dept INT, @no NVARCHAR(40), @store INT, @avail DECIMAL(18,4),
            @lot INT, @take DECIMAL(18,4), @left DECIMAL(18,4), @ded BIT, @v DECIMAL(18,2), @k DECIMAL(18,6);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT LineId, ConsumptionId, CompanyId, BranchId, ItemId, Qty, DepartmentId, DocNo FROM #C ORDER BY LineId;
    OPEN c; FETCH NEXT FROM c INTO @line, @cid, @co, @br, @item, @qty, @dept, @no;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @ded = DeductOnConsumption FROM dbo.ufn_Inv_Settings(@co);
        SET @store = dbo.ufn_Inv_ConsumeStore(@br, @dept);
        IF @ded = 0
            UPDATE dbo.QcConsumptionLine SET StockStatus = 'OFF', StockNote = N'Stock deduction on consumption is switched off.' WHERE ConsumptionLineId = @line;
        ELSE IF @store IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.InvStockLedger WHERE StoreId = @store)
            UPDATE dbo.QcConsumptionLine SET StockStatus = 'NOT_TRACKED', StoreId = @store, StockNote = N'The store has no stock yet (stock tracking not started).' WHERE ConsumptionLineId = @line;
        ELSE
        BEGIN
            BEGIN TRANSACTION;
                SELECT @avail = ISNULL(SUM(b.Qty), 0)
                FROM dbo.InvStockBalance b WITH (UPDLOCK, HOLDLOCK) JOIN dbo.InvLot l ON l.LotId = b.LotId
                WHERE b.StoreId = @store AND b.ItemId = @item AND b.Qty > 0 AND l.Status = 'ACCEPTED' AND (l.ExpiryDate IS NULL OR l.ExpiryDate >= CAST(GETDATE() AS DATE));
                IF @avail < @qty
                    UPDATE dbo.QcConsumptionLine SET StockStatus = 'PENDING', StoreId = @store,
                           StockNote = CONCAT(N'Short of stock: available ', FORMAT(@avail, '0.####'), N', needed ', FORMAT(@qty, '0.####'), N'.')
                    WHERE ConsumptionLineId = @line;
                ELSE
                BEGIN
                    SET @left = @qty;
                    WHILE @left > 0
                    BEGIN
                        SELECT TOP 1 @lot = b.LotId, @take = CASE WHEN b.Qty < @left THEN b.Qty ELSE @left END
                        FROM dbo.InvStockBalance b JOIN dbo.InvLot l ON l.LotId = b.LotId
                        WHERE b.StoreId = @store AND b.ItemId = @item AND b.Qty > 0 AND l.Status = 'ACCEPTED' AND (l.ExpiryDate IS NULL OR l.ExpiryDate >= CAST(GETDATE() AS DATE))
                        ORDER BY CASE WHEN b.OpenedOn IS NOT NULL THEN 0 ELSE 1 END, ISNULL(l.ExpiryDate, '99991231'), l.LotId;
                        SET @take = -@take;
                        EXEC dbo.usp_Inv_Move @CompanyId = @co, @StoreId = @store, @ItemId = @item, @LotId = @lot, @Qty = @take, @DocType = 'CONS',
                             @DocId = @cid, @DocNo = @no, @DocLineId = @line, @Remarks = N'Lab test consumption (BOM)', @UserId = @UserId, @ValueOut = @v OUTPUT, @CostOut = @k OUTPUT;
                        SET @left = @left + @take;
                    END
                    UPDATE dbo.QcConsumptionLine SET StockStatus = 'POSTED', StoreId = @store, StockPostedOn = GETDATE(), StockNote = NULL WHERE ConsumptionLineId = @line;
                    UPDATE dbo.QcConsumption SET StoreId = @store WHERE ConsumptionId = @cid AND StoreId IS NULL;
                END
            COMMIT TRANSACTION;
        END
        FETCH NEXT FROM c INTO @line, @cid, @co, @br, @item, @qty, @dept, @no;
    END
    CLOSE c; DEALLOCATE c;
END;
GO

-- hook: usp_Qc_Consume_Sync takes the new runs out of stock after it commits (never stops the result)
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_Qc_Consume_Sync'));
IF @def IS NULL THROW 53599, 'usp_Qc_Consume_Sync is missing (run SQLScripts/2249 first).', 1;
IF CHARINDEX(N'usp_Inv_ConsumeLines', @def) = 0
BEGIN
    DECLARE @tail INT = LEN(@def) - CHARINDEX(REVERSE(N'COMMIT TRANSACTION;'), REVERSE(@def)) - LEN(N'COMMIT TRANSACTION;') + 2;
    IF @tail <= 0 THROW 53598, 'usp_Qc_Consume_Sync: the final COMMIT was not found; stock hook not added.', 1;
    DECLARE @hook NVARCHAR(MAX) = N'COMMIT TRANSACTION;

    -- 2498: take the new runs out of stock (bench / main store, FEFO); short stock waits as PENDING, never blocks the result
    BEGIN TRY
        EXEC dbo.usp_Inv_ConsumeLines @LabOrderId = @LabOrderId, @UserId = @UserId;
        DECLARE @InvCo INT, @InvBr INT, @InvToday DATE = CAST(GETDATE() AS DATE);
        SELECT TOP 1 @InvCo = CompanyId, @InvBr = BranchId FROM dbo.QcConsumption WHERE LabOrderId = @LabOrderId ORDER BY ConsumptionId DESC;
        IF @InvBr IS NOT NULL EXEC dbo.usp_Inv_PostConsumptionAccounts @CompanyId = @InvCo, @BranchId = @InvBr, @UpTo = @InvToday, @UserId = @UserId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        BEGIN TRY
            INSERT INTO dbo.QcConsumptionLog (LabOrderId, ErrorNumber, ErrorMessage) VALUES (@LabOrderId, ERROR_NUMBER(), LEFT(N''Stock: '' + ERROR_MESSAGE(), 2000));
        END TRY
        BEGIN CATCH
        END CATCH
    END CATCH';
    SET @def = STUFF(@def, @tail, LEN(N'COMMIT TRANSACTION;'), @hook);
    DECLARE @p INT = PATINDEX(N'%CREATE%PROC%usp_Qc_Consume_Sync%', @def);
    DECLARE @q INT = CHARINDEX(N'usp_Qc_Consume_Sync', @def, @p);
    IF @p = 0 OR @q = 0 THROW 53597, 'usp_Qc_Consume_Sync: the CREATE line was not found; stock hook not added.', 1;
    SET @def = STUFF(@def, @p, @q - @p, N'CREATE OR ALTER PROCEDURE dbo.');
    IF @def IS NULL THROW 53596, 'usp_Qc_Consume_Sync: the patched definition is empty; stock hook not added.', 1;
    EXEC sys.sp_executesql @def;
    IF CHARINDEX(N'usp_Inv_ConsumeLines', OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_Qc_Consume_Sync'))) = 0
        THROW 53595, 'usp_Qc_Consume_Sync: the stock hook was not added.', 1;
END
GO

PRINT 'Script 2498 applied: Quality & Compliance stock management core (lots, stock ledger, documents, consumption from stock, accounts).';
GO
