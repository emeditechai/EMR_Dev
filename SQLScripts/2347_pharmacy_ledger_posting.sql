-- ============================================================================================================
-- 2347  Pharmacy > Purchase: automatic ledger postings, the same way OPD / LAB bills post (after 2346).
--   Vouchers go through dbo.usp_Acc_PostVoucher (shared numbering, financial year, balanced lines, posted once per
--   reference) and are cancelled with dbo.usp_Acc_CancelVoucher (reversal entry, nothing deleted).
--     GRN posted        PURCHASE   (PH_GRN)   Dr Pharmacy Inventory (taxable + freight)  Dr GST Input Credit (GST)
--                                             +/- Round Off                               Cr Supplier ledger (net)
--     Return posted     DEBIT NOTE (PH_PRET)  Dr Supplier ledger (net)  Cr Pharmacy Inventory (taxable)  Cr GST Input Credit  +/- Round Off
--     Supplier payment  PAYMENT    (PH_SPAY)  Dr Supplier ledger  Cr Cash / Bank (Accounts > payment mode ledger of the branch)
--     Payment cancelled reversal of the payment voucher
--   Supplier ledgers are created on first use under Sundry Creditors ("<Supplier name> (<code>)"), linked by PhSupplier.LedgerId.
--   Posting happens inside the GRN / return / payment transaction: if the voucher cannot be posted (books locked for that
--   date), the document is not posted either.
--   Backfill: documents already posted before this script get their vouchers (dated as posted). Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO

-- ── voucher types, ledgers ────────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_VoucherType WHERE VoucherTypeCode = 'PUR')
    INSERT dbo.Acc_VoucherType (VoucherTypeName, Prefix, IsActive, VoucherTypeCode, IsManual) VALUES ('Purchase', 'PUR', 1, 'PUR', 0);
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_VoucherType WHERE VoucherTypeCode = 'DN')
    INSERT dbo.Acc_VoucherType (VoucherTypeName, Prefix, IsActive, VoucherTypeCode, IsManual) VALUES ('Debit Note', 'DN', 1, 'DN', 0);
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Sundry Creditors')
    INSERT dbo.Acc_LedgerGroup (GroupName, GroupType) VALUES ('Sundry Creditors', 'Liability');
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Inventory')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT 'Pharmacy Inventory', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'PH_INVENTORY', 'Asset', 1, 'Pharmacy stock at cost (GRN in, purchase return out).'
    FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Current Assets';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'GST Input Credit')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerType, IsSystem)
    SELECT 'GST Input Credit', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'Asset', 1 FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Current Assets';
GO
IF COL_LENGTH('dbo.PhSupplier', 'LedgerId') IS NULL
    ALTER TABLE dbo.PhSupplier ADD LedgerId INT NULL;
GO

-- ── supplier ledger (created on first use) ────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ph_SupplierLedger @SupplierId INT, @LedgerId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @LedgerId = s.LedgerId FROM dbo.PhSupplier s JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = s.LedgerId WHERE s.SupplierId = @SupplierId;
    IF @LedgerId IS NOT NULL RETURN;
    DECLARE @name NVARCHAR(200), @code NVARCHAR(50) = CONCAT('PH_SUP_', @SupplierId);
    SELECT @name = LEFT(SupplierName, 170) + N' (' + SupplierCode + N')' FROM dbo.PhSupplier WHERE SupplierId = @SupplierId;
    SELECT @LedgerId = LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = @code;
    IF @LedgerId IS NULL
    BEGIN
        INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
        SELECT @name, LedgerGroupId, 0, 'Cr', 1, GETDATE(), @code, 'PARTY', 1, N'Pharmacy supplier (Master > Pharmacy Master > Supplier).'
        FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Sundry Creditors';
        SET @LedgerId = SCOPE_IDENTITY();
    END
    UPDATE dbo.PhSupplier SET LedgerId = @LedgerId WHERE SupplierId = @SupplierId;
END;
GO

-- ── the posting procedure ─────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ph_PostLedger
    @Kind   VARCHAR(10),     -- GRN | PRET | SPAY | SPAYX (payment cancelled)
    @RefId  INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @inv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Inventory'),
            @gstIn INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'GST Input Credit'),
            @round INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Round Off'),
            @cash INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Cash Account'),
            @bank INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Bank Account');
    IF @inv IS NULL OR @gstIn IS NULL OR @round IS NULL THROW 51100, 'Accounts ledgers for pharmacy are missing (run SQLScripts/2347).', 1;

    DECLARE @co INT, @br INT, @date DATETIME, @sup INT, @supLedger INT, @no NVARCHAR(40), @supName NVARCHAR(200), @lines NVARCHAR(MAX), @narr NVARCHAR(400),
            @tid BIGINT, @vno NVARCHAR(50), @taxable DECIMAL(18,2), @gst DECIMAL(18,2), @other DECIMAL(18,2), @ro DECIMAL(18,2), @net DECIMAL(18,2);

    IF @Kind = 'GRN'
    BEGIN
        SELECT @co = g.CompanyId, @br = g.BranchId, @date = g.GrnDate, @sup = g.SupplierId, @no = g.GrnNo, @supName = s.SupplierName,
               @taxable = g.TaxableAmount, @gst = g.CgstAmount + g.SgstAmount + g.IgstAmount, @other = g.OtherCharges, @ro = g.RoundOff, @net = g.NetAmount,
               @narr = CONCAT(N'Pharmacy purchase ', g.GrnNo, N' - ', s.SupplierName, N' bill ', g.InvoiceNo, N' dt ', FORMAT(g.InvoiceDate, 'dd-MMM-yyyy'),
                              CASE WHEN g.IgstAmount > 0 THEN CONCAT(N' (IGST ', g.IgstAmount, N')') ELSE CONCAT(N' (CGST ', g.CgstAmount, N', SGST ', g.SgstAmount, N')') END)
        FROM dbo.PhGrn g JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId WHERE g.GrnId = @RefId AND g.Status = 'POSTED';
        IF @co IS NULL OR @net = 0 RETURN;
        EXEC dbo.usp_Ph_SupplierLedger @sup, @supLedger OUTPUT;
        SET @lines = (SELECT * FROM (VALUES
                (@inv, @taxable + @other, 0, N'Stock at cost'),
                (@gstIn, @gst, 0, N'Input GST'),
                (@round, CASE WHEN @ro > 0 THEN @ro ELSE 0 END, CASE WHEN @ro < 0 THEN -@ro ELSE 0 END, N'Round off'),
                (@supLedger, 0, @net, N'Supplier bill')) v (LedgerId, Dr, Cr, Narration)
            WHERE v.Dr > 0 OR v.Cr > 0 FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'PUR', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'PH_GRN', @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @supName, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'PRET'
    BEGIN
        SELECT @co = r.CompanyId, @br = r.BranchId, @date = r.ReturnDate, @sup = r.SupplierId, @no = r.ReturnNo, @supName = s.SupplierName,
               @taxable = r.TaxableAmount, @gst = r.GstAmount, @ro = r.RoundOff, @net = r.NetAmount,
               @narr = CONCAT(N'Pharmacy purchase return (debit note) ', r.ReturnNo, N' - ', s.SupplierName)
        FROM dbo.PhPurchaseReturn r JOIN dbo.PhSupplier s ON s.SupplierId = r.SupplierId WHERE r.ReturnId = @RefId AND r.Status = 'POSTED';
        IF @co IS NULL OR @net = 0 RETURN;
        EXEC dbo.usp_Ph_SupplierLedger @sup, @supLedger OUTPUT;
        SET @lines = (SELECT * FROM (VALUES
                (@supLedger, @net, 0, N'Debit note'),
                (@inv, 0, @taxable, N'Stock returned at cost'),
                (@gstIn, 0, @gst, N'Input GST reversed'),
                (@round, CASE WHEN @ro < 0 THEN -@ro ELSE 0 END, CASE WHEN @ro > 0 THEN @ro ELSE 0 END, N'Round off')) v (LedgerId, Dr, Cr, Narration)
            WHERE v.Dr > 0 OR v.Cr > 0 FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'DN', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'PH_PRET', @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @supName, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'SPAY'
    BEGIN
        DECLARE @mode VARCHAR(10), @ref NVARCHAR(50), @modeLedger INT;
        SELECT @co = p.CompanyId, @br = p.BranchId, @date = p.PaymentDate, @sup = p.SupplierId, @no = p.PaymentNo, @supName = s.SupplierName, @net = p.Amount,
               @mode = p.PaymentMode, @ref = p.ReferenceNo,
               @narr = CONCAT(N'Payment to pharmacy supplier ', s.SupplierName, N' - ', p.PaymentNo, N' (', p.PaymentMode, ISNULL(N' ' + p.ReferenceNo, N''), N')')
        FROM dbo.PhSupplierPayment p JOIN dbo.PhSupplier s ON s.SupplierId = p.SupplierId WHERE p.PaymentId = @RefId AND p.Status = 'POSTED';
        IF @co IS NULL OR @net = 0 RETURN;
        EXEC dbo.usp_Ph_SupplierLedger @sup, @supLedger OUTPUT;
        SET @modeLedger = dbo.fn_Acc_ModeLedger(@br, @mode, CASE WHEN @mode = 'CASH' THEN @cash ELSE @bank END);
        IF @modeLedger IS NULL THROW 51101, 'No ledger is set for this payment mode (Accounts > payment mode ledgers).', 1;
        SET @lines = (SELECT * FROM (VALUES (@supLedger, @net, 0, N'Paid to supplier'), (@modeLedger, 0, @net, N'Paid by ' + @mode)) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'PMT', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'PH_SPAY', @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @supName, @PaymentMode = @mode, @InstrumentNo = @ref, @InstrumentDate = @date, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'SPAYX'
    BEGIN
        SELECT TOP 1 @tid = TransactionId FROM dbo.Acc_LedgerTransaction
        WHERE ReferenceType = 'PH_SPAY' AND ReferenceId = @RefId AND IsActive = 1 AND Status = 'P' AND ReversalOfTransactionId IS NULL;
        IF @tid IS NOT NULL
        BEGIN
            DECLARE @rev BIGINT;
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @tid, @Reason = N'Pharmacy supplier payment cancelled', @UserId = @UserId, @ReversalId = @rev OUTPUT;
        END
    END
END;
GO

-- ── hook the postings into GRN / return posting (inside their transaction) ────────────────────────────────
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_PhGrn_Post'));
IF @def NOT LIKE '%usp_Ph_PostLedger%'
BEGIN
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'WHERE g.GrnId = @GrnId;
    COMMIT;', 'WHERE g.GrnId = @GrnId;
    EXEC dbo.usp_Ph_PostLedger ''GRN'', @GrnId, @UserId;   -- 2347: Purchase voucher
    COMMIT;');
    IF @def NOT LIKE '%usp_Ph_PostLedger%' THROW 51190, 'Could not hook the ledger posting into usp_PhGrn_Post.', 1;
    EXEC (@def);
END
GO
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_PhPurchaseReturn_Post'));
IF @def NOT LIKE '%usp_Ph_PostLedger%'
BEGIN
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'WHERE ReturnId = @ReturnId;
    COMMIT;', 'WHERE ReturnId = @ReturnId;
    EXEC dbo.usp_Ph_PostLedger ''PRET'', @ReturnId, @UserId;   -- 2347: Debit Note voucher
    COMMIT;');
    IF @def NOT LIKE '%usp_Ph_PostLedger%' THROW 51191, 'Could not hook the ledger posting into usp_PhPurchaseReturn_Post.', 1;
    EXEC (@def);
END
GO

-- ── backfill: documents posted before this script ─────────────────────────────────────────────────────────
DECLARE @id INT, @u INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT GrnId, PostedBy FROM dbo.PhGrn g WHERE Status = 'POSTED' AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'PH_GRN' AND t.ReferenceId = g.GrnId);
OPEN c; FETCH NEXT FROM c INTO @id, @u;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Ph_PostLedger 'GRN', @id, @u; FETCH NEXT FROM c INTO @id, @u; END
CLOSE c; DEALLOCATE c;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT ReturnId, PostedBy FROM dbo.PhPurchaseReturn r WHERE Status = 'POSTED' AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'PH_PRET' AND t.ReferenceId = r.ReturnId);
OPEN c; FETCH NEXT FROM c INTO @id, @u;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Ph_PostLedger 'PRET', @id, @u; FETCH NEXT FROM c INTO @id, @u; END
CLOSE c; DEALLOCATE c;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT PaymentId, CreatedBy FROM dbo.PhSupplierPayment p WHERE NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'PH_SPAY' AND t.ReferenceId = p.PaymentId);
OPEN c; FETCH NEXT FROM c INTO @id, @u;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- a payment cancelled before this script: post it and reverse it, so the books show both
    IF EXISTS (SELECT 1 FROM dbo.PhSupplierPayment WHERE PaymentId = @id AND Status = 'CANCELLED')
    BEGIN
        UPDATE dbo.PhSupplierPayment SET Status = 'POSTED' WHERE PaymentId = @id;
        EXEC dbo.usp_Ph_PostLedger 'SPAY', @id, @u;
        UPDATE dbo.PhSupplierPayment SET Status = 'CANCELLED' WHERE PaymentId = @id;
        EXEC dbo.usp_Ph_PostLedger 'SPAYX', @id, @u;
    END
    ELSE EXEC dbo.usp_Ph_PostLedger 'SPAY', @id, @u;
    FETCH NEXT FROM c INTO @id, @u;
END
CLOSE c; DEALLOCATE c;
GO

PRINT 'Script 2347 applied: pharmacy purchase ledger postings (Purchase, Debit Note, Payment vouchers; supplier ledgers).';
GO
