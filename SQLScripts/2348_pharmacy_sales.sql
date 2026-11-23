-- ============================================================================================================
-- 2348  Pharmacy > Sales (after 2347): counter sale (POS), sale return, cancellation, credit collection, day closing,
--       Schedule H1 / X / NDPS register.
--   * Money is kept like OPD / LAB: PaymentHeader / PaymentDetail with ModuleCode 'PHR' (ModuleRefId = PhSale.SaleId),
--     receipt numbers from usp_Receipt_GetNextNo; refunds in BillRefund, cancellations in BillCancellation (module 'PHR').
--   * Day closing: module 'PHR' added to the cashier day closing (fn_CashClosing_Txns, summary, submit, verify rights).
--   * Ledger (usp_Ph_PostLedger, as purchases):
--       SALE     Sales voucher       Dr receivable (patient receivable / credit customer)  Cr Pharmacy Sales  Cr GST Output  +/- Round Off
--                                    Dr Pharmacy Cost of Goods Sold  Cr Pharmacy Inventory (landed cost)
--       SRCPT    Receipt voucher     Dr Cash / Bank (payment mode ledger)  Cr receivable
--       SRET     Credit Note         the sale entry reversed for the returned quantity
--       SREFUND  Payment voucher     Dr receivable  Cr Cash / Bank
--       SCANCEL  reversal of the sale voucher and of every receipt voucher of the bill
-- Additive and re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO

-- ── tables ─────────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhSale') IS NULL
CREATE TABLE dbo.PhSale (
    SaleId          INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId       INT NOT NULL,
    BranchId        INT NOT NULL,
    SaleNo          NVARCHAR(40) NULL,                 -- given when the bill is saved (a held bill has none)
    SaleDate        DATETIME NOT NULL DEFAULT GETDATE(),
    Status          VARCHAR(10) NOT NULL,              -- HOLD | POSTED | CANCELLED
    CustomerKind    VARCHAR(10) NOT NULL,              -- WALKIN | PATIENT | CUSTOMER
    PatientId       INT NULL,
    CustomerId      INT NULL REFERENCES dbo.PhCustomer (CustomerId),
    CustomerName    NVARCHAR(150) NULL,
    Mobile          NVARCHAR(15) NULL,
    Email           NVARCHAR(150) NULL,
    Address         NVARCHAR(300) NULL,
    DoctorId        INT NULL,
    DoctorName      NVARCHAR(150) NULL,
    DoctorRegNo     NVARCHAR(50) NULL,
    RxNo            NVARCHAR(50) NULL,
    RxDate          DATE NULL,
    PriceType       VARCHAR(20) NOT NULL DEFAULT 'WALKIN',
    BillDiscPercent DECIMAL(5,2) NOT NULL DEFAULT 0,
    MrpAmount       DECIMAL(14,2) NOT NULL DEFAULT 0,  -- value at MRP
    DiscountAmount  DECIMAL(14,2) NOT NULL DEFAULT 0,  -- MRP value - bill value (price rule + discounts)
    TaxableAmount   DECIMAL(14,2) NOT NULL DEFAULT 0,
    CgstAmount      DECIMAL(14,2) NOT NULL DEFAULT 0,
    SgstAmount      DECIMAL(14,2) NOT NULL DEFAULT 0,
    RoundOff        DECIMAL(8,2) NOT NULL DEFAULT 0,
    NetAmount       DECIMAL(14,2) NOT NULL DEFAULT 0,
    PaidAmount      DECIMAL(14,2) NOT NULL DEFAULT 0,
    ReturnedAmount  DECIMAL(14,2) NOT NULL DEFAULT 0,  -- credit notes adjusted against this bill
    BalanceDue      DECIMAL(14,2) NOT NULL DEFAULT 0,  -- credit sale outstanding
    CostAmount      DECIMAL(14,2) NOT NULL DEFAULT 0,
    HoldLabel       NVARCHAR(60) NULL,
    Remarks         NVARCHAR(300) NULL,
    CancelReason    NVARCHAR(300) NULL,
    CancelledBy INT NULL, CancelledDate DATETIME NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhSale_Branch')
    CREATE INDEX IX_PhSale_Branch ON dbo.PhSale (BranchId, Status, SaleDate) INCLUDE (SaleNo, CustomerName, NetAmount, BalanceDue);
GO
IF OBJECT_ID('dbo.PhSaleDtl') IS NULL
CREATE TABLE dbo.PhSaleDtl (
    SaleDtlId     INT IDENTITY(1,1) PRIMARY KEY,
    SaleId        INT NOT NULL REFERENCES dbo.PhSale (SaleId),
    ItemId        INT NOT NULL REFERENCES dbo.PhItem (ItemId),
    BatchId       INT NOT NULL REFERENCES dbo.PhBatch (BatchId),
    Qty           DECIMAL(14,3) NOT NULL,          -- sale units
    UnitMrp       DECIMAL(12,4) NOT NULL,          -- per sale unit, GST inclusive
    UnitPrice     DECIMAL(12,4) NOT NULL,          -- per sale unit after the price rule, GST inclusive (never above MRP)
    DiscPercent   DECIMAL(5,2) NOT NULL DEFAULT 0, -- line + bill discount
    Amount        DECIMAL(14,2) NOT NULL,          -- charged, GST inclusive
    GstPercent    DECIMAL(5,2) NOT NULL,
    TaxableAmount DECIMAL(14,2) NOT NULL,
    GstAmount     DECIMAL(14,2) NOT NULL,
    UnitCost      DECIMAL(12,4) NOT NULL,          -- landed cost per sale unit
    ReturnedQty   DECIMAL(14,3) NOT NULL DEFAULT 0
);
GO
IF OBJECT_ID('dbo.PhSaleReturn') IS NULL
CREATE TABLE dbo.PhSaleReturn (
    ReturnId      INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId     INT NOT NULL,
    BranchId      INT NOT NULL,
    ReturnNo      NVARCHAR(40) NOT NULL,
    ReturnDate    DATETIME NOT NULL DEFAULT GETDATE(),
    SaleId        INT NOT NULL REFERENCES dbo.PhSale (SaleId),
    ReasonId      INT NULL REFERENCES dbo.PhReason (ReasonId),
    RefundMode    VARCHAR(10) NOT NULL,            -- CASH | CARD | UPI | NEFT | ADJUST (set off against the credit bill)
    RefundRef     NVARCHAR(50) NULL,
    TaxableAmount DECIMAL(14,2) NOT NULL,
    GstAmount     DECIMAL(14,2) NOT NULL,
    RoundOff      DECIMAL(8,2) NOT NULL DEFAULT 0,
    NetAmount     DECIMAL(14,2) NOT NULL,
    AdjustedAmount DECIMAL(14,2) NOT NULL DEFAULT 0, -- part set off against the bill's balance
    RefundAmount  DECIMAL(14,2) NOT NULL DEFAULT 0,  -- part paid back
    CostAmount    DECIMAL(14,2) NOT NULL DEFAULT 0,
    RefundId      INT NULL,                        -- BillRefund row of the money paid back
    Status        VARCHAR(10) NOT NULL DEFAULT 'POSTED',
    Remarks       NVARCHAR(300) NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF OBJECT_ID('dbo.PhSaleReturnDtl') IS NULL
CREATE TABLE dbo.PhSaleReturnDtl (
    ReturnDtlId   INT IDENTITY(1,1) PRIMARY KEY,
    ReturnId      INT NOT NULL REFERENCES dbo.PhSaleReturn (ReturnId),
    SaleDtlId     INT NOT NULL REFERENCES dbo.PhSaleDtl (SaleDtlId),
    ItemId        INT NOT NULL,
    BatchId       INT NOT NULL,
    Qty           DECIMAL(14,3) NOT NULL,
    Amount        DECIMAL(14,2) NOT NULL,
    TaxableAmount DECIMAL(14,2) NOT NULL,
    GstAmount     DECIMAL(14,2) NOT NULL,
    UnitCost      DECIMAL(12,4) NOT NULL
);
GO
IF OBJECT_ID('dbo.PhScheduleRegister') IS NULL
CREATE TABLE dbo.PhScheduleRegister (            -- Schedule H1 / X / NDPS register (Drugs & Cosmetics Rules r.65; NDPS Act)
    RegisterId     INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    BranchId       INT NOT NULL,
    SaleId         INT NOT NULL REFERENCES dbo.PhSale (SaleId),
    SaleDtlId      INT NOT NULL,
    EntryDate      DATETIME NOT NULL,
    ScheduleCode   VARCHAR(10) NOT NULL,
    ItemId         INT NOT NULL,
    BatchId        INT NOT NULL,
    Qty            DECIMAL(14,3) NOT NULL,
    PatientName    NVARCHAR(150) NOT NULL,
    PatientAddress NVARCHAR(300) NOT NULL,
    PrescriberName NVARCHAR(150) NOT NULL,
    PrescriberRegNo NVARCHAR(50) NULL,
    RxNo           NVARCHAR(50) NOT NULL,
    DispensedBy    INT NULL,
    IsCancelled    BIT NOT NULL DEFAULT 0
);
GO
IF COL_LENGTH('dbo.PhCustomer', 'LedgerId') IS NULL
    ALTER TABLE dbo.PhCustomer ADD LedgerId INT NULL;
GO

-- ── ledgers ────────────────────────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Sundry Debtors')
    INSERT dbo.Acc_LedgerGroup (GroupName, GroupType) VALUES ('Sundry Debtors', 'Asset');
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Sales')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT 'Pharmacy Sales', LedgerGroupId, 0, 'Cr', 1, GETDATE(), 'PH_SALES', 'Income', 1, 'Counter sale of medicines (value before GST).' FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Direct Income';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Cost of Goods Sold')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT 'Pharmacy Cost of Goods Sold', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'PH_COGS', 'Expense', 1, 'Landed cost of medicines sold.' FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Direct Expenses';
GO

CREATE OR ALTER PROCEDURE dbo.usp_Ph_CustomerLedger @CustomerId INT, @LedgerId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @LedgerId = c.LedgerId FROM dbo.PhCustomer c JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = c.LedgerId WHERE c.CustomerId = @CustomerId;
    IF @LedgerId IS NOT NULL RETURN;
    DECLARE @code NVARCHAR(50) = CONCAT('PH_CUS_', @CustomerId), @name NVARCHAR(200);
    SELECT @name = LEFT(CustomerName, 160) + N' (' + Mobile + N')' FROM dbo.PhCustomer WHERE CustomerId = @CustomerId;
    SELECT @LedgerId = LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = @code;
    IF @LedgerId IS NULL
    BEGIN
        INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
        SELECT @name, LedgerGroupId, 0, 'Dr', 1, GETDATE(), @code, 'PARTY', 1, N'Pharmacy credit customer (Master > Pharmacy Master > Pharmacy Customer).'
        FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Sundry Debtors';
        SET @LedgerId = SCOPE_IDENTITY();
    END
    UPDATE dbo.PhCustomer SET LedgerId = @LedgerId WHERE CustomerId = @CustomerId;
END;
GO

-- ── sales ledger postings (added to usp_Ph_PostLedger by wrapping it) ──────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ph_PostSaleLedger
    @Kind   VARCHAR(10),     -- SALE | SRCPT | SRET | SREFUND | SCANCEL
    @RefId  INT,             -- SaleId | PaymentDetailId | ReturnId | BillRefund.RefundId | SaleId
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @inv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Inventory'),
            @sales INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Sales'),
            @cogs INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Cost of Goods Sold'),
            @gstOut INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'GST Output Payable'),
            @round INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Round Off'),
            @patRec INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable'),
            @cash INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Cash Account'),
            @bank INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Bank Account');
    IF @inv IS NULL OR @sales IS NULL OR @cogs IS NULL OR @gstOut IS NULL OR @patRec IS NULL THROW 51110, 'Accounts ledgers for pharmacy sales are missing (run SQLScripts/2348).', 1;

    DECLARE @saleId INT, @co INT, @br INT, @date DATETIME, @rec INT, @cust INT, @party NVARCHAR(150), @no NVARCHAR(40), @lines NVARCHAR(MAX), @narr NVARCHAR(400),
            @tid BIGINT, @vno NVARCHAR(50), @taxable DECIMAL(18,2), @gst DECIMAL(18,2), @ro DECIMAL(18,2), @net DECIMAL(18,2), @cost DECIMAL(18,2), @mode VARCHAR(30), @modeLedger INT;

    SET @saleId = CASE @Kind WHEN 'SALE' THEN @RefId WHEN 'SCANCEL' THEN @RefId
                             WHEN 'SRCPT' THEN (SELECT ph.ModuleRefId FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId WHERE pd.PaymentDetailId = @RefId AND RTRIM(ph.ModuleCode) = 'PHR')
                             WHEN 'SRET' THEN (SELECT SaleId FROM dbo.PhSaleReturn WHERE ReturnId = @RefId)
                             WHEN 'SREFUND' THEN (SELECT ModuleRefId FROM dbo.BillRefund WHERE RefundId = @RefId AND RTRIM(ModuleCode) = 'PHR') END;
    IF @saleId IS NULL RETURN;
    SELECT @co = CompanyId, @br = BranchId, @cust = CustomerId, @party = ISNULL(NULLIF(CustomerName, ''), 'Walk-in'), @no = SaleNo FROM dbo.PhSale WHERE SaleId = @saleId;
    IF @cust IS NOT NULL EXEC dbo.usp_Ph_CustomerLedger @cust, @rec OUTPUT; ELSE SET @rec = @patRec;

    IF @Kind = 'SALE'
    BEGIN
        SELECT @date = SaleDate, @taxable = TaxableAmount, @gst = CgstAmount + SgstAmount, @ro = RoundOff, @net = NetAmount, @cost = CostAmount,
               @narr = CONCAT(N'Pharmacy sale ', SaleNo, N' - ', @party, N' (CGST ', CgstAmount, N', SGST ', SgstAmount, N')')
        FROM dbo.PhSale WHERE SaleId = @saleId AND Status IN ('POSTED', 'CANCELLED');
        IF @date IS NULL OR @net = 0 RETURN;
        SET @lines = (SELECT * FROM (VALUES
                (@rec, @net, 0, N'Bill amount'), (@sales, 0, @taxable, N'Sale value'), (@gstOut, 0, @gst, N'Output GST'),
                (@round, CASE WHEN @ro < 0 THEN -@ro ELSE 0 END, CASE WHEN @ro > 0 THEN @ro ELSE 0 END, N'Round off'),
                (@cogs, @cost, 0, N'Cost of medicines sold'), (@inv, 0, @cost, N'Stock out at cost')) v (LedgerId, Dr, Cr, Narration)
            WHERE v.Dr > 0 OR v.Cr > 0 FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'SLS', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'PH_SALE', @ReferenceId = @saleId,
             @Narration = @narr, @PayeeName = @party, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'SRCPT'
    BEGIN
        DECLARE @rno NVARCHAR(50), @ref NVARCHAR(100);
        SELECT @date = COALESCE(pd.PaymentDate, pd.CreatedDate), @net = pd.PaidAmount, @mode = UPPER(pm.MethodCode), @rno = pd.ReceiptNo,
               @ref = COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''), pd.ChequeNo)
        FROM dbo.PaymentDetail pd LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId WHERE pd.PaymentDetailId = @RefId AND pd.IsActive = 1;
        IF @net IS NULL OR @net <= 0 RETURN;
        SET @modeLedger = dbo.fn_Acc_ModeLedger(@br, @mode, CASE WHEN @mode = 'CASH' THEN @cash ELSE @bank END);
        SET @narr = CONCAT(N'Pharmacy receipt ', @rno, N' against bill ', @no, N' - ', @party, N' (', @mode, ISNULL(N' ' + @ref, N''), N')');
        SET @lines = (SELECT * FROM (VALUES (@modeLedger, @net, 0, N'Received by ' + @mode), (@rec, 0, @net, N'Against bill')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'RCT', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'PH_RECEIPT', @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @PaymentMode = @mode, @InstrumentNo = @ref, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'SRET'
    BEGIN
        SELECT @date = ReturnDate, @taxable = TaxableAmount, @gst = GstAmount, @ro = RoundOff, @net = NetAmount, @cost = CostAmount,
               @narr = CONCAT(N'Pharmacy sale return ', ReturnNo, N' against bill ', @no, N' - ', @party)
        FROM dbo.PhSaleReturn WHERE ReturnId = @RefId AND Status = 'POSTED';
        IF @date IS NULL OR @net = 0 RETURN;
        SET @lines = (SELECT * FROM (VALUES
                (@sales, @taxable, 0, N'Sale value returned'), (@gstOut, @gst, 0, N'Output GST reversed'),
                (@round, CASE WHEN @ro > 0 THEN @ro ELSE 0 END, CASE WHEN @ro < 0 THEN -@ro ELSE 0 END, N'Round off'),
                (@rec, 0, @net, N'Credit note'), (@inv, @cost, 0, N'Stock back at cost'), (@cogs, 0, @cost, N'Cost reversed')) v (LedgerId, Dr, Cr, Narration)
            WHERE v.Dr > 0 OR v.Cr > 0 FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'CN', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'PH_SRET', @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'SREFUND'
    BEGIN
        SELECT @date = RefundDate, @net = RefundAmount, @mode = UPPER(LTRIM(RTRIM(RefundMode))) FROM dbo.BillRefund WHERE RefundId = @RefId AND IsActive = 1;
        IF @net IS NULL OR @net <= 0 RETURN;
        SET @modeLedger = dbo.fn_Acc_ModeLedger(@br, @mode, CASE WHEN @mode = 'CASH' THEN @cash ELSE @bank END);
        SET @narr = CONCAT(N'Pharmacy refund against bill ', @no, N' - ', @party, N' (', @mode, N')');
        SET @lines = (SELECT * FROM (VALUES (@rec, @net, 0, N'Refund'), (@modeLedger, 0, @net, N'Paid back by ' + @mode)) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'PMT', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'PH_REFUND', @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @PaymentMode = @mode, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'SCANCEL'
    BEGIN
        DECLARE @rev BIGINT, @t BIGINT;
        DECLARE v CURSOR LOCAL FAST_FORWARD FOR
            SELECT t.TransactionId FROM dbo.Acc_LedgerTransaction t
            WHERE t.IsActive = 1 AND t.Status = 'P' AND t.ReversalOfTransactionId IS NULL
              AND ((t.ReferenceType = 'PH_SALE' AND t.ReferenceId = @saleId)
                   OR (t.ReferenceType = 'PH_RECEIPT' AND t.ReferenceId IN (SELECT pd.PaymentDetailId FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
                                                                          WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.ModuleRefId = @saleId)));
        OPEN v; FETCH NEXT FROM v INTO @t;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @t, @Reason = N'Pharmacy bill cancelled', @UserId = @UserId, @ReversalId = @rev OUTPUT;
            FETCH NEXT FROM v INTO @t;
        END
        CLOSE v; DEALLOCATE v;
    END
END;
GO

-- PaymentHeader takes the pharmacy's module code PHR beside OPD / LAB / IPD / MEM / MED
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_PaymentHeader_ModuleCode' AND definition NOT LIKE '%PHR%')
BEGIN
    ALTER TABLE dbo.PaymentHeader DROP CONSTRAINT CK_PaymentHeader_ModuleCode;
    ALTER TABLE dbo.PaymentHeader ADD CONSTRAINT CK_PaymentHeader_ModuleCode CHECK (ModuleCode IN ('OPD', 'LAB', 'IPD', 'MEM', 'MED', 'PHR'));
END
GO

-- ── day closing: module PHR beside OPD and LAB ─────────────────────────────────────────────────────────────
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_CashClosing_Module' AND definition NOT LIKE '%PHR%')
BEGIN
    ALTER TABLE dbo.CashClosing DROP CONSTRAINT CK_CashClosing_Module;
    ALTER TABLE dbo.CashClosing ADD CONSTRAINT CK_CashClosing_Module CHECK (Module IN ('OPD', 'LAB', 'PHR'));
END
GO
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.fn_CashClosing_Txns'));
IF @def NOT LIKE '%PhSale%'
BEGIN
    SET @def = REPLACE(@def, 'CREATE FUNCTION', 'CREATE OR ALTER FUNCTION');
    SET @def = REPLACE(@def, 'CREATE   FUNCTION', 'CREATE OR ALTER FUNCTION');
    SET @def = REPLACE(@def, 'IN (''OPD'', ''LAB'')', 'IN (''OPD'', ''LAB'', ''PHR'')');
    SET @def = REPLACE(@def, 'CAST(COALESCE(pos.OPDBillNo, lo.BillNo) AS NVARCHAR(60))', 'CAST(COALESCE(pos.OPDBillNo, lo.BillNo, phs.SaleNo) AS NVARCHAR(60))');
    SET @def = REPLACE(@def, 'CAST(LTRIM(RTRIM(ISNULL(p.FirstName + '' '', '''') + ISNULL(p.LastName, ''''))) AS NVARCHAR(250))',
                             'CAST(COALESCE(NULLIF(phs.CustomerName, ''''), NULLIF(LTRIM(RTRIM(ISNULL(p.FirstName + '' '', '''') + ISNULL(p.LastName, ''''))), ''''), N''Walk-in'') AS NVARCHAR(250))');
    SET @def = REPLACE(@def, 'LEFT  JOIN dbo.LabOrder lo ON ph.ModuleCode = ''LAB'' AND lo.LabOrderId = ph.ModuleRefId',
                             'LEFT  JOIN dbo.LabOrder lo ON ph.ModuleCode = ''LAB'' AND lo.LabOrderId = ph.ModuleRefId
    LEFT  JOIN dbo.PhSale phs ON ph.ModuleCode = ''PHR'' AND phs.SaleId = ph.ModuleRefId');
    SET @def = REPLACE(@def, 'LEFT  JOIN dbo.LabOrder lo ON r.ModuleCode = ''LAB'' AND lo.LabOrderId = r.ModuleRefId',
                             'LEFT  JOIN dbo.LabOrder lo ON r.ModuleCode = ''LAB'' AND lo.LabOrderId = r.ModuleRefId
    LEFT  JOIN dbo.PhSale phs ON r.ModuleCode = ''PHR'' AND phs.SaleId = r.ModuleRefId');
    SET @def = REPLACE(@def, 'COALESCE(ph.BranchId, pos.BranchId, lo.BranchId)', 'COALESCE(ph.BranchId, pos.BranchId, lo.BranchId, phs.BranchId)');
    IF (LEN(@def) - LEN(REPLACE(@def, 'phs.', ''))) / 4 < 6 THROW 51195, 'Could not add the pharmacy to fn_CashClosing_Txns.', 1;
    EXEC (@def);
END
GO
DECLARE @p SYSNAME, @def NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM (VALUES ('usp_CashClosing_Summary'), ('usp_CashClosing_Submit')) v (name);
OPEN c; FETCH NEXT FROM c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @def = OBJECT_DEFINITION(OBJECT_ID('dbo.' + @p));
    IF @def LIKE '%NOT IN (''OPD'', ''LAB'')%'
    BEGIN
        SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
        SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
        SET @def = REPLACE(@def, 'NOT IN (''OPD'', ''LAB'')', 'NOT IN (''OPD'', ''LAB'', ''PHR'')');
        EXEC (@def);
    END
    FETCH NEXT FROM c INTO @p;
END
CLOSE c; DEALLOCATE c;
GO
-- the verify right of module PHR is the page PHARMACY.DAYCLOSINGVERIFY
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_CashClosing_CanVerify'));
IF @def NOT LIKE '%PHARMACY.DAYCLOSINGVERIFY%'
BEGIN
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'Page_Code = @Module + ''.DAYCLOSINGVERIFY''', 'Page_Code = CASE WHEN @Module = ''PHR'' THEN ''PHARMACY.DAYCLOSINGVERIFY'' ELSE @Module + ''.DAYCLOSINGVERIFY'' END');
    IF @def NOT LIKE '%PHARMACY.DAYCLOSINGVERIFY%' THROW 51196, 'Could not add the pharmacy to usp_CashClosing_CanVerify.', 1;
    EXEC (@def);
END
GO

-- ── pages: Pharmacy > Sales ───────────────────────────────────────────────────────────────────────────────
DECLARE @co INT, @nav INT, @menu INT, @page INT, @view INT, @ctl INT, @i INT = 1;
SELECT @nav = Menu_ID, @co = CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY';
SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY.SALES';
EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @nav, @Menu_Type = 'MENU', @Menu_Code = N'PHARMACY.SALES',
     @Title = N'Sales', @Icon = N'bi bi-cart-check me-2', @Sort_Order = 5, @UserId = NULL, @Menu_ID = @menu OUTPUT;

DECLARE @pages TABLE (n INT IDENTITY, Code NVARCHAR(60), Title NVARCHAR(100), Ctl NVARCHAR(60), Act NVARCHAR(60), Sort INT, Icon NVARCHAR(60), ViewActs NVARCHAR(400));
INSERT @pages (Code, Title, Ctl, Act, Sort, Icon, ViewActs) VALUES
 (N'PHARMACY.POS',               N'Pharmacy Sale (POS)',        N'PhSales',            N'Pos',     10, N'bi bi-upc-scan me-2',          N'Pos,ItemSearch,Batches,Customers,Patients,Doctors,Held,Recall,PriceFor'),
 (N'PHARMACY.SALEBILLS',         N'Sale Bills',                 N'PhSales',            N'Index',   20, N'bi bi-receipt me-2',           N'Index,Bill'),
 (N'PHARMACY.SALERETURN',        N'Sale Return',                N'PhSaleReturns',      N'Index',   30, N'bi bi-arrow-return-left me-2', N'Index,Form,FindBill,Print'),
 (N'PHARMACY.CREDITCOLLECTION',  N'Credit Collection',          N'PhCreditCollection', N'Index',   40, N'bi bi-wallet2 me-2',           N'Index,Collect,Receipt'),
 (N'PHARMACY.DAYCLOSING',        N'Pharmacy Day Closing',       N'PhDayClosing',       N'Index',   50, N'bi bi-calendar2-check me-2',   N'Index,Summary,Receivers'),
 (N'PHARMACY.DAYCLOSINGVERIFY',  N'Pharmacy Day Closing Verification', N'PhDayClosing', N'Verify', 60, N'bi bi-shield-check me-2',      N'Verify,Board,Detail,VerifySlip'),
 (N'PHARMACY.SCHEDULEREGISTER',  N'Schedule H1 / X Register',   N'PhScheduleRegister', N'Index',   70, N'bi bi-journal-medical me-2',   N'Index');
DECLARE @controls TABLE (Code NVARCHAR(60), Control VARCHAR(30), Title NVARCHAR(150), Sort INT, Method VARCHAR(4), Acts NVARCHAR(200));
INSERT @controls VALUES
 (N'PHARMACY.POS',              'SAVE',     N'Save a bill (stock out, payment)', 20, 'POST', N'Save'),
 (N'PHARMACY.POS',              'HOLD',     N'Hold / recall / discard a bill', 30, 'POST', N'Hold,DiscardHold'),
 (N'PHARMACY.POS',              'DISCOUNT', N'Discount above the branch limit (checked when the bill is saved)', 40, 'POST', N''),
 (N'PHARMACY.POS',              'CREDIT',   N'Credit sale to a credit customer (checked when the bill is saved)', 50, 'POST', N''),
 (N'PHARMACY.SALEBILLS',        'PRINT',    N'Print / re-print a bill', 20, 'GET',  N'Print,Pdf'),
 (N'PHARMACY.SALEBILLS',        'SEND',     N'Send the bill by WhatsApp / e-mail', 30, 'POST', N'Send'),
 (N'PHARMACY.SALEBILLS',        'CANCEL',   N'Cancel a bill (same day, before day closing)', 40, 'POST', N'Cancel'),
 (N'PHARMACY.SALERETURN',       'SAVE',     N'Take back medicines (sale return)', 20, 'POST', N'Save'),
 (N'PHARMACY.CREDITCOLLECTION', 'COLLECT',  N'Receive payment from a credit customer', 20, 'POST', N'Save'),
 (N'PHARMACY.DAYCLOSING',       'CREATE',   N'Submit a day closing', 20, 'POST', N'Submit'),
 (N'PHARMACY.DAYCLOSING',       'PRINT',    N'Print the hand-over slip', 30, 'GET',  N'Slip'),
 (N'PHARMACY.DAYCLOSINGVERIFY', 'VERIFY',   N'Verify / send back a day closing', 20, 'POST', N'VerifyAction');

DECLARE @code NVARCHAR(60), @title NVARCHAR(100), @c NVARCHAR(60), @a NVARCHAR(60), @sort INT, @icon NVARCHAR(60), @va NVARCHAR(400), @act NVARCHAR(60),
        @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @cm VARCHAR(4), @ca NVARCHAR(200);
WHILE @i <= (SELECT COUNT(*) FROM @pages)
BEGIN
    SELECT @code = Code, @title = Title, @c = Ctl, @a = Act, @sort = Sort, @icon = Icon, @va = ViewActs FROM @pages WHERE n = @i;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title, @Controller = @c, @Action = @a,
         @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@va, ',');
    OPEN a; FETCH NEXT FROM a INTO @act;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = @c, @Action = @act, @Source = 'SEED'; FETCH NEXT FROM a INTO @act; END
    CLOSE a; DEALLOCATE a;
    DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Control, Title, Sort, Method, Acts FROM @controls WHERE Code = @code;
    OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @cm, @ca;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
        DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@ca, ',') WHERE value <> '';
        OPEN a; FETCH NEXT FROM a INTO @act;
        WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @cm, @Controller = @c, @Action = @act, @Source = 'SEED'; FETCH NEXT FROM a INTO @act; END
        CLOSE a; DEALLOCATE a;
        FETCH NEXT FROM k INTO @cc, @ct, @cs, @cm, @ca;
    END
    CLOSE k; DEALLOCATE k;
    SET @i += 1;
END
GO

-- fix-up for databases patched by an earlier run: the buyer's name on the pharmacy bill comes before the (walk-in) patient's
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.fn_CashClosing_Txns'));
IF @def LIKE '%phs.CustomerName, N''Walk-in'')%'
BEGIN
    SET @def = REPLACE(@def, 'CREATE FUNCTION', 'CREATE OR ALTER FUNCTION');
    SET @def = REPLACE(@def, 'CREATE   FUNCTION', 'CREATE OR ALTER FUNCTION');
    SET @def = REPLACE(@def, 'COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(p.FirstName + '' '', '''') + ISNULL(p.LastName, ''''))), ''''), phs.CustomerName, N''Walk-in'')',
                             'COALESCE(NULLIF(phs.CustomerName, ''''), NULLIF(LTRIM(RTRIM(ISNULL(p.FirstName + '' '', '''') + ISNULL(p.LastName, ''''))), ''''), N''Walk-in'')');
    EXEC (@def);
END
GO
-- earlier run: placeholder / view-level print mappings of Sale Bills
DELETE m FROM dbo.PageEndpointMap m JOIN dbo.PageMaster p ON p.Page_ID = m.Page_ID WHERE p.Page_Code = N'PHARMACY.SALEBILLS' AND m.Action IN ('Reprint');
DELETE m FROM dbo.PageEndpointMap m JOIN dbo.PageMaster p ON p.Page_ID = m.Page_ID JOIN dbo.PageControlMaster c ON c.Control_ID = m.Control_ID
WHERE p.Page_Code = N'PHARMACY.SALEBILLS' AND c.Control_Code = 'VIEW' AND m.Action IN ('Print', 'Pdf');
GO

-- PaymentHeader needs a patient: a walk-in sale points at one inactive placeholder patient per company
-- (inactive = never offered in patient search); the buyer's own name and mobile stay on the pharmacy bill.
CREATE OR ALTER PROCEDURE dbo.usp_Ph_WalkinPatient @CompanyId INT, @BranchId INT, @PatientId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @code NVARCHAR(30) = CONCAT('PHWALKIN', @CompanyId);
    SELECT @PatientId = PatientId FROM dbo.PatientMaster WHERE PatientCode = @code;
    IF @PatientId IS NOT NULL RETURN;
    INSERT dbo.PatientMaster (PatientCode, PhoneNumber, FirstName, LastName, Gender, BranchId, CompanyId, IsActive, Address)
    VALUES (@code, '0000000000', N'Pharmacy', N'Walk-in', 'Other', @BranchId, @CompanyId, 0, N'Pharmacy counter sale (placeholder; not a real patient)');
    SET @PatientId = SCOPE_IDENTITY();
END;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2348 applied: Pharmacy > Sales (POS, return, cancellation, credit collection, day closing, H1 register; ledger postings).';
GO
