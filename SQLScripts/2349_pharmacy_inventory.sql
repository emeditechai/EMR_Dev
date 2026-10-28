-- ============================================================================================================
-- 2349  Pharmacy > Inventory (after 2348): dashboard, stock enquiry, branch indent & transfer, stock adjustment,
--       expiry / damage write-off, physical stock verification, batch correction.
--   * Maker-checker: Approval Matrix modules PHARMACY.STOCKADJUST / WRITEOFF / STOCKCOUNT / BATCHCORRECTION. With a matrix
--     for the module, only its approvers may approve; without one, a user with the page's APPROVE control. Never the maker.
--   * Stock moves only through usp_PhStock_Move; posted documents are never edited.
--   * Ledger (Journal voucher, usp_Acc_PostVoucher):
--       adjustment / physical count  Dr Pharmacy Inventory / Cr Pharmacy Stock Adjustment (gain)  or the reverse (loss)
--       write-off                    Dr Pharmacy Expiry & Damage Write-off  Cr Pharmacy Inventory
--       transfer short received      Dr Pharmacy Stock Adjustment  Cr Pharmacy Inventory (transit loss)
-- Additive and re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO

-- ── number series for the new documents ────────────────────────────────────────────────────────────────────
INSERT dbo.PhNumberSeries (CompanyId, BranchId, DocType, DocName, Prefix)
SELECT s.CompanyId, s.BranchId, v.t, v.n, v.p
FROM (SELECT DISTINCT CompanyId, BranchId FROM dbo.PhNumberSeries) s
CROSS JOIN (VALUES ('BIND', N'Branch Indent', 'BIN'), ('WOF', N'Expiry / Damage Write-off', 'WOF'), ('PCNT', N'Physical Stock Verification', 'PSV'), ('BCOR', N'Batch Correction', 'BCR')) v (t, n, p)
WHERE NOT EXISTS (SELECT 1 FROM dbo.PhNumberSeries x WHERE x.BranchId = s.BranchId AND x.DocType = v.t);
GO
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Pharmacy_EnsureMasters'));
IF @def NOT LIKE '%BIND%'
BEGIN
    SET @def = REPLACE(@def, '(''SPAY'',N''Supplier Payment'',''SPY'')', '(''SPAY'',N''Supplier Payment'',''SPY''),(''BIND'',N''Branch Indent'',''BIN''),(''WOF'',N''Expiry / Damage Write-off'',''WOF''),(''PCNT'',N''Physical Stock Verification'',''PSV''),(''BCOR'',N''Batch Correction'',''BCR'')');
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    IF @def NOT LIKE '%BIND%' THROW 51290, 'Could not add the inventory number series to usp_Pharmacy_EnsureMasters.', 1;
    EXEC (@def);
END
GO

-- ── ledgers ────────────────────────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Stock Adjustment')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT 'Pharmacy Stock Adjustment', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'PH_STOCK_ADJ', 'Expense', 1, 'Stock found short (Dr) or excess (Cr) on adjustment, physical count or transfer.'
    FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Indirect Expenses';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Expiry & Damage Write-off')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT 'Pharmacy Expiry & Damage Write-off', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'PH_WRITEOFF', 'Expense', 1, 'Expired / damaged medicines destroyed (at cost).'
    FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Indirect Expenses';
GO

-- ── branch indent & transfer ───────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhTransfer') IS NULL
CREATE TABLE dbo.PhTransfer (
    TransferId     INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    ToBranchId     INT NOT NULL,                   -- the branch that asks and receives
    FromBranchId   INT NOT NULL,                   -- the branch that sends
    RequestNo      NVARCHAR(40) NULL,              -- receiving branch's BIND series
    RequestDate    DATETIME NULL,
    TransferNo     NVARCHAR(40) NULL,              -- sending branch's TRF series, on dispatch
    DispatchDate   DATETIME NULL,
    ReceiveDate    DATETIME NULL,
    Status         VARCHAR(10) NOT NULL DEFAULT 'DRAFT',   -- DRAFT | REQUESTED | DISPATCHED | RECEIVED | CANCELLED
    Priority       VARCHAR(10) NOT NULL DEFAULT 'NORMAL',
    IsOtherGstin   BIT NOT NULL DEFAULT 0,         -- branches with different GSTINs (tax invoice: phase 2)
    Remarks        NVARCHAR(300) NULL,
    DispatchRemarks NVARCHAR(300) NULL,
    ReceiveRemarks NVARCHAR(300) NULL,
    CostValue      DECIMAL(14,2) NOT NULL DEFAULT 0,
    VarianceValue  DECIMAL(14,2) NOT NULL DEFAULT 0,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
    DispatchedBy INT NULL, ReceivedBy INT NULL, CancelledBy INT NULL, CancelledDate DATETIME NULL
);
GO
IF OBJECT_ID('dbo.PhTransferDtl') IS NULL
CREATE TABLE dbo.PhTransferDtl (
    TransferDtlId  INT IDENTITY(1,1) PRIMARY KEY,
    TransferId     INT NOT NULL REFERENCES dbo.PhTransfer (TransferId),
    ItemId         INT NOT NULL REFERENCES dbo.PhItem (ItemId),
    RequestQty     DECIMAL(14,3) NOT NULL DEFAULT 0,   -- sale units asked for
    BatchId        INT NULL REFERENCES dbo.PhBatch (BatchId),
    DispatchQty    DECIMAL(14,3) NOT NULL DEFAULT 0,   -- sale units sent from this batch
    ReceivedQty    DECIMAL(14,3) NULL,
    UnitCost       DECIMAL(12,4) NOT NULL DEFAULT 0,
    VarianceReason NVARCHAR(150) NULL
);
GO

-- ── adjustment / write-off / physical-count adjustment ─────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhAdjustment') IS NULL
CREATE TABLE dbo.PhAdjustment (
    AdjustmentId   INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    BranchId       INT NOT NULL,
    Kind           VARCHAR(10) NOT NULL,           -- ADJUST | WRITEOFF | PHYSICAL
    DocNo          NVARCHAR(40) NULL,
    DocDate        DATE NOT NULL,
    ReasonId       INT NULL REFERENCES dbo.PhReason (ReasonId),
    Status         VARCHAR(10) NOT NULL DEFAULT 'DRAFT',   -- DRAFT | SUBMITTED | APPROVED | REJECTED | CANCELLED
    Remarks        NVARCHAR(300) NULL,
    ActionRemarks  NVARCHAR(300) NULL,
    -- write-off: destruction record (Drugs & Cosmetics Rules / Bio-Medical Waste Rules)
    DisposalMethod NVARCHAR(100) NULL,             -- incineration through the BMW agency, etc.
    DisposalAgency NVARCHAR(150) NULL,
    DisposalDate   DATE NULL,
    Witness1       NVARCHAR(100) NULL,
    Witness2       NVARCHAR(100) NULL,
    CertificateNo  NVARCHAR(60) NULL,
    StockCountId   INT NULL,                       -- PHYSICAL: the verification it came from
    PlusValue      DECIMAL(14,2) NOT NULL DEFAULT 0,
    MinusValue     DECIMAL(14,2) NOT NULL DEFAULT 0,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
    SubmittedBy INT NULL, SubmittedDate DATETIME NULL,
    ApprovedBy INT NULL, ApprovedDate DATETIME NULL, ModifiedBy INT NULL, ModifiedDate DATETIME NULL
);
GO
IF OBJECT_ID('dbo.PhAdjustmentDtl') IS NULL
CREATE TABLE dbo.PhAdjustmentDtl (
    AdjustmentDtlId INT IDENTITY(1,1) PRIMARY KEY,
    AdjustmentId    INT NOT NULL REFERENCES dbo.PhAdjustment (AdjustmentId),
    BatchId         INT NOT NULL REFERENCES dbo.PhBatch (BatchId),
    ItemId          INT NOT NULL,
    QtyChange       DECIMAL(14,3) NOT NULL,        -- sale units: + found / - lost (write-off always -)
    UnitCost        DECIMAL(12,4) NOT NULL,
    Remarks         NVARCHAR(200) NULL
);
GO

-- ── physical stock verification ─────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhStockCount') IS NULL
CREATE TABLE dbo.PhStockCount (
    StockCountId   INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    BranchId       INT NOT NULL,
    CountNo        NVARCHAR(40) NOT NULL,
    FrozenAt       DATETIME NOT NULL,              -- system stock taken at this moment
    Scope          NVARCHAR(150) NULL,             -- what was counted (all / racks / category)
    Status         VARCHAR(10) NOT NULL,           -- COUNTING | SUBMITTED | APPROVED | REJECTED | CANCELLED
    Remarks        NVARCHAR(300) NULL,
    ActionRemarks  NVARCHAR(300) NULL,
    AdjustmentId   INT NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
    SubmittedBy INT NULL, SubmittedDate DATETIME NULL, ApprovedBy INT NULL, ApprovedDate DATETIME NULL
);
GO
IF OBJECT_ID('dbo.PhStockCountDtl') IS NULL
CREATE TABLE dbo.PhStockCountDtl (
    StockCountDtlId INT IDENTITY(1,1) PRIMARY KEY,
    StockCountId    INT NOT NULL REFERENCES dbo.PhStockCount (StockCountId),
    BatchId         INT NOT NULL REFERENCES dbo.PhBatch (BatchId),
    ItemId          INT NOT NULL,
    RackNo          NVARCHAR(30) NULL,
    SystemQty       DECIMAL(14,3) NOT NULL,        -- at FrozenAt
    CountedQty      DECIMAL(14,3) NULL,            -- NULL = not counted yet
    UnitCost        DECIMAL(12,4) NOT NULL,
    Remarks         NVARCHAR(200) NULL
);
GO

-- ── batch correction ───────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhBatchCorrection') IS NULL
CREATE TABLE dbo.PhBatchCorrection (
    CorrectionId   INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    BranchId       INT NOT NULL,
    DocNo          NVARCHAR(40) NOT NULL,
    BatchId        INT NOT NULL REFERENCES dbo.PhBatch (BatchId),
    OldBatchNo NVARCHAR(30) NOT NULL, NewBatchNo NVARCHAR(30) NOT NULL,
    OldExpiry DATE NOT NULL,          NewExpiry DATE NOT NULL,
    OldMrp DECIMAL(12,2) NOT NULL,    NewMrp DECIMAL(12,2) NOT NULL,
    Reason         NVARCHAR(300) NOT NULL,
    Status         VARCHAR(10) NOT NULL DEFAULT 'SUBMITTED',   -- SUBMITTED | APPROVED | REJECTED | CANCELLED
    ActionRemarks  NVARCHAR(300) NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ApprovedBy INT NULL, ApprovedDate DATETIME NULL
);
GO

-- ── ledger postings for inventory documents ────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ph_PostInventoryLedger
    @Kind   VARCHAR(10),     -- ADJ (PhAdjustment, any kind) | TRFLOSS (PhTransfer)
    @RefId  INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @inv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Inventory'),
            @adj INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Stock Adjustment'),
            @wof INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Expiry & Damage Write-off');
    IF @inv IS NULL OR @adj IS NULL OR @wof IS NULL THROW 51300, 'Accounts ledgers for pharmacy inventory are missing (run SQLScripts/2349).', 1;
    DECLARE @co INT, @br INT, @date DATETIME, @no NVARCHAR(40), @kindDoc VARCHAR(10), @plus DECIMAL(18,2), @minus DECIMAL(18,2), @lines NVARCHAR(MAX), @narr NVARCHAR(400),
            @tid BIGINT, @vno NVARCHAR(50), @other INT, @ref NVARCHAR(50);
    IF @Kind = 'ADJ'
    BEGIN
        SELECT @co = CompanyId, @br = BranchId, @date = ISNULL(ApprovedDate, GETDATE()), @no = DocNo, @kindDoc = Kind, @plus = PlusValue, @minus = MinusValue
        FROM dbo.PhAdjustment WHERE AdjustmentId = @RefId AND Status = 'APPROVED';
        IF @co IS NULL OR (@plus = 0 AND @minus = 0) RETURN;
        SET @other = CASE WHEN @kindDoc = 'WRITEOFF' THEN @wof ELSE @adj END;
        SET @ref = CASE @kindDoc WHEN 'WRITEOFF' THEN 'PH_WRITEOFF' WHEN 'PHYSICAL' THEN 'PH_PHYSICAL' ELSE 'PH_ADJUST' END;
        SET @narr = CONCAT(CASE @kindDoc WHEN 'WRITEOFF' THEN N'Pharmacy expiry / damage write-off ' WHEN 'PHYSICAL' THEN N'Pharmacy physical stock difference ' ELSE N'Pharmacy stock adjustment ' END, @no);
        SET @lines = (SELECT * FROM (VALUES
                (@inv, @plus, @minus, N'Stock at cost'), (@other, @minus, @plus, CASE WHEN @kindDoc = 'WRITEOFF' THEN N'Written off' ELSE N'Found excess / short' END)) v (LedgerId, Dr, Cr, Narration)
            WHERE v.Dr > 0 OR v.Cr > 0 FOR JSON PATH);
        -- one ledger may carry both directions: net them per ledger
        SET @lines = (SELECT LedgerId, CASE WHEN SUM(Dr - Cr) > 0 THEN SUM(Dr - Cr) ELSE 0 END Dr, CASE WHEN SUM(Dr - Cr) < 0 THEN -SUM(Dr - Cr) ELSE 0 END Cr, MIN(Narration) Narration
                      FROM OPENJSON(@lines) WITH (LedgerId INT, Dr DECIMAL(18,2), Cr DECIMAL(18,2), Narration NVARCHAR(300)) GROUP BY LedgerId HAVING SUM(Dr - Cr) <> 0 FOR JSON PATH);
        IF @lines IS NULL RETURN;
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'JRN', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = @ref, @ReferenceId = @RefId,
             @Narration = @narr, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'TRFLOSS'
    BEGIN
        SELECT @co = CompanyId, @br = ToBranchId, @date = ReceiveDate, @no = TransferNo, @minus = VarianceValue FROM dbo.PhTransfer WHERE TransferId = @RefId AND Status = 'RECEIVED';
        IF @co IS NULL OR @minus = 0 RETURN;
        SET @narr = CONCAT(N'Pharmacy transfer ', @no, N': short received in transit');
        SET @lines = (SELECT * FROM (VALUES (@adj, CASE WHEN @minus > 0 THEN @minus ELSE 0 END, CASE WHEN @minus < 0 THEN -@minus ELSE 0 END, N'Transit difference'),
                                            (@inv, CASE WHEN @minus < 0 THEN -@minus ELSE 0 END, CASE WHEN @minus > 0 THEN @minus ELSE 0 END, N'Stock at cost')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'JRN', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'PH_TRFLOSS', @ReferenceId = @RefId,
             @Narration = @narr, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
END;
GO

-- ── Approval Matrix modules ────────────────────────────────────────────────────────────────────────────────
MERGE dbo.ApprovalModule AS t
USING (VALUES ('PHARMACY.STOCKADJUST', N'Pharmacy Stock Adjustment', 110), ('PHARMACY.WRITEOFF', N'Pharmacy Expiry / Damage Write-off', 120),
              ('PHARMACY.STOCKCOUNT', N'Pharmacy Physical Stock Verification', 130), ('PHARMACY.BATCHCORRECTION', N'Pharmacy Batch Correction', 140)) s (Code, Name, Sort)
ON t.Module_Code = s.Code
WHEN NOT MATCHED THEN INSERT (Module_Code, Module_Name, Sort_Order, IsActive) VALUES (s.Code, s.Name, s.Sort, 1);
GO

-- ── pages: Pharmacy > Inventory ────────────────────────────────────────────────────────────────────────────
DECLARE @co INT, @nav INT, @menu INT, @page INT, @view INT, @ctl INT, @i INT = 1;
SELECT @nav = Menu_ID, @co = CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY';
SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY.INVENTORY';
EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @nav, @Menu_Type = 'MENU', @Menu_Code = N'PHARMACY.INVENTORY',
     @Title = N'Inventory', @Icon = N'bi bi-boxes me-2', @Sort_Order = 20, @UserId = NULL, @Menu_ID = @menu OUTPUT;

DECLARE @pages TABLE (n INT IDENTITY, Code NVARCHAR(60), Title NVARCHAR(100), Ctl NVARCHAR(60), Act NVARCHAR(60), Sort INT, Icon NVARCHAR(60), ViewActs NVARCHAR(400));
INSERT @pages (Code, Title, Ctl, Act, Sort, Icon, ViewActs) VALUES
 (N'PHARMACY.DASHBOARD',       N'Pharmacy Dashboard',              N'PhDashboard',       N'Index', 10, N'bi bi-speedometer2 me-2',   N'Index'),
 (N'PHARMACY.STOCK',           N'Stock Enquiry',                   N'PhStock',           N'Index', 20, N'bi bi-search me-2',          N'Index,Ledger,BatchSearch'),
 (N'PHARMACY.TRANSFER',        N'Branch Indent & Transfer',        N'PhTransfers',       N'Index', 30, N'bi bi-arrow-left-right me-2', N'Index,Form,Print,ItemSearch,Batches'),
 (N'PHARMACY.STOCKADJUST',     N'Stock Adjustment',                N'PhAdjustments',     N'Index', 40, N'bi bi-plus-slash-minus me-2', N'Index,Form,Print,BatchSearch'),
 (N'PHARMACY.WRITEOFF',        N'Expiry / Damage Write-off',       N'PhWriteOffs',       N'Index', 50, N'bi bi-trash3 me-2',          N'Index,Form,Print,BatchSearch,Expiry'),
 (N'PHARMACY.STOCKCOUNT',      N'Physical Stock Verification',     N'PhStockCounts',     N'Index', 60, N'bi bi-clipboard-check me-2', N'Index,Form,Sheet,Variance'),
 (N'PHARMACY.BATCHCORRECTION', N'Batch Correction',                N'PhBatchCorrections', N'Index', 70, N'bi bi-pencil-square me-2', N'Index,BatchSearch');
DECLARE @controls TABLE (Code NVARCHAR(60), Control VARCHAR(30), Title NVARCHAR(150), Sort INT, Acts NVARCHAR(200));
INSERT @controls VALUES
 (N'PHARMACY.TRANSFER', 'REQUEST',  N'Raise / edit / send a branch indent', 20, N'Save'),
 (N'PHARMACY.TRANSFER', 'DISPATCH', N'Send stock against an indent (stock out, in transit)', 30, N'Dispatch'),
 (N'PHARMACY.TRANSFER', 'RECEIVE',  N'Receive a transfer (stock in, variance)', 40, N'Receive'),
 (N'PHARMACY.TRANSFER', 'CANCEL',   N'Cancel an indent not yet dispatched', 50, N'Cancel'),
 (N'PHARMACY.STOCKADJUST', 'SAVE',    N'Enter / edit a draft adjustment', 20, N'Save'),
 (N'PHARMACY.STOCKADJUST', 'SUBMIT',  N'Submit for approval', 30, N'Submit'),
 (N'PHARMACY.STOCKADJUST', 'APPROVE', N'Approve (stock and books change)', 40, N'Approve'),
 (N'PHARMACY.STOCKADJUST', 'REJECT',  N'Reject', 50, N'Reject'),
 (N'PHARMACY.STOCKADJUST', 'CANCEL',  N'Cancel a draft / submitted adjustment', 60, N'Cancel'),
 (N'PHARMACY.WRITEOFF', 'SAVE',    N'Enter / edit a draft write-off', 20, N'Save'),
 (N'PHARMACY.WRITEOFF', 'SUBMIT',  N'Submit for approval', 30, N'Submit'),
 (N'PHARMACY.WRITEOFF', 'APPROVE', N'Approve (stock out, written off)', 40, N'Approve'),
 (N'PHARMACY.WRITEOFF', 'REJECT',  N'Reject', 50, N'Reject'),
 (N'PHARMACY.WRITEOFF', 'CANCEL',  N'Cancel a draft / submitted write-off', 60, N'Cancel'),
 (N'PHARMACY.STOCKCOUNT', 'CREATE',  N'Start a verification (freeze stock)', 20, N'Create'),
 (N'PHARMACY.STOCKCOUNT', 'COUNT',   N'Enter counted quantities', 30, N'SaveCounts'),
 (N'PHARMACY.STOCKCOUNT', 'SUBMIT',  N'Submit counts for approval', 40, N'Submit'),
 (N'PHARMACY.STOCKCOUNT', 'APPROVE', N'Approve (differences adjusted)', 50, N'Approve'),
 (N'PHARMACY.STOCKCOUNT', 'REJECT',  N'Reject (back to counting)', 60, N'Reject'),
 (N'PHARMACY.STOCKCOUNT', 'CANCEL',  N'Cancel a verification', 70, N'Cancel'),
 (N'PHARMACY.BATCHCORRECTION', 'SAVE',    N'Request a correction', 20, N'Save'),
 (N'PHARMACY.BATCHCORRECTION', 'APPROVE', N'Approve a correction', 30, N'Approve'),
 (N'PHARMACY.BATCHCORRECTION', 'REJECT',  N'Reject a correction', 40, N'Reject');

DECLARE @code NVARCHAR(60), @title NVARCHAR(100), @c NVARCHAR(60), @a NVARCHAR(60), @sort INT, @icon NVARCHAR(60), @va NVARCHAR(400), @act NVARCHAR(60),
        @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @ca NVARCHAR(200);
WHILE @i <= (SELECT COUNT(*) FROM @pages)
BEGIN
    SELECT @code = Code, @title = Title, @c = Ctl, @a = Act, @sort = Sort, @icon = Icon, @va = ViewActs FROM @pages WHERE n = @i;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title, @Controller = @c, @Action = @a,
         @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@va, ',') WHERE value <> '';
    OPEN a; FETCH NEXT FROM a INTO @act;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = @c, @Action = @act, @Source = 'SEED'; FETCH NEXT FROM a INTO @act; END
    CLOSE a; DEALLOCATE a;
    DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Control, Title, Sort, Acts FROM @controls WHERE Code = @code;
    OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
        DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@ca, ',') WHERE value <> '';
        OPEN a; FETCH NEXT FROM a INTO @act;
        WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = @c, @Action = @act, @Source = 'SEED'; FETCH NEXT FROM a INTO @act; END
        CLOSE a; DEALLOCATE a;
        FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
    END
    CLOSE k; DEALLOCATE k;
    SET @i += 1;
END
GO

DELETE m FROM dbo.PageEndpointMap m JOIN dbo.PageMaster p ON p.Page_ID = m.Page_ID WHERE p.Page_Code = N'PHARMACY.TRANSFER' AND m.Action = 'Request';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2349 applied: Pharmacy > Inventory (dashboard, stock, transfer, adjustment, write-off, physical verification, batch correction).';
GO
