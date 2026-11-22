-- ============================================================================================================
-- Migration: 2526_fund_and_doctor_payout_ledger.sql   (application database; needs 2213, 2522, 2525)
-- Fund Master and OPD doctor share payout post to the Accounts ledger (Utility > Accounts), through dbo.usp_Acc_PostVoucher
-- (shared numbering, financial year, balanced lines, books lock, posted once per reference) and dbo.usp_Acc_CancelVoucher
-- (reversal entry, nothing deleted). Every posting happens inside the transaction of its action: if the voucher cannot
-- be posted (books locked for that date), the action is not saved either.
--   Fund opening          OPN  (FUND_OPEN, FundId)          Dr Fund ledger                     Cr Opening Balance Difference
--   Fund top-up           CTR  (FUND_TOPUP, FundTxnId)      Dr Fund ledger                     Cr Cash / Bank (payment-mode ledger)
--   Settlement approved   JRN  (DOC_SETTLE, SettlementId)   Dr Doctor Professional Fees (taxable share)
--                                                           Cr Doctor Fees Payable (net payable) + Cr TDS Payable (194J) (TDS)
--   Settlement paid       PMT  (DOC_PAY, SettlementId)      Dr Doctor Fees Payable (net)       Cr Fund ledger (or Cash / Bank when paid without a fund)
--   Approved settlement rejected: the DOC_SETTLE journal is reversed.
--   A fund's opening balance corrected (no movement yet): the old opening voucher is reversed and the new one posted.
-- Ledgers: one per fund ("Fund - <name> (<code>)", Bank Accounts for a bank fund / Cash In Hand for a wallet; Fund.LedgerId,
-- renamed with the fund), Doctor Professional Fees (Direct Expenses), Doctor Fees Payable and TDS Payable (194J) (Current Liabilities).
-- Backfill: funds, top-ups and settlements already there get their vouchers, dated as they happened. Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF OBJECT_ID(N'dbo.Fund', N'U') IS NULL OR COL_LENGTH('dbo.DoctorSettlement', 'FundId') IS NULL
BEGIN
    RAISERROR('Script 2526 needs scripts 2522 and 2525 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ── ledgers ────────────────────────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'DOC_FEES')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT N'Doctor Professional Fees', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'DOC_FEES', 'EXPENSE', 1, N'OPD doctor share - recognised when a settlement is approved.'
      FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Direct Expenses';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'DOC_PAYABLE')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT N'Doctor Fees Payable', LedgerGroupId, 0, 'Cr', 1, GETDATE(), 'DOC_PAYABLE', 'PARTY', 1, N'Approved doctor settlements not yet paid.'
      FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Current Liabilities';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'TDS_194J')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT N'TDS Payable (194J)', LedgerGroupId, 0, 'Cr', 1, GETDATE(), 'TDS_194J', 'TAX', 1, N'TDS deducted on doctor professional fees, to be deposited.'
      FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Current Liabilities';
GO
IF COL_LENGTH('dbo.Fund', 'LedgerId') IS NULL ALTER TABLE dbo.Fund ADD LedgerId INT NULL;
GO

-- the fund's ledger (made on first use; its name follows the fund)
CREATE OR ALTER PROCEDURE dbo.usp_Fund_Ledger @FundId INT, @LedgerId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @name NVARCHAR(200), @type VARCHAR(10), @code NVARCHAR(50) = CONCAT('FUND_', @FundId);
    SELECT @name = LEFT(N'Fund - ' + FundName + N' (' + FundCode + N')', 200), @type = FundType, @LedgerId = LedgerId FROM dbo.Fund WHERE FundId = @FundId;
    IF @type IS NULL RETURN;
    IF @LedgerId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerId = @LedgerId)
        SET @LedgerId = (SELECT LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = @code);
    IF @LedgerId IS NULL
    BEGIN
        INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
        SELECT @name, LedgerGroupId, 0, 'Dr', 1, GETDATE(), @code, CASE WHEN @type = 'BANK' THEN 'BANK' ELSE 'CASH' END, 1,
               N'Fund (Utility > Accounts > Fund Master): opening, top-ups and payouts.'
          FROM dbo.Acc_LedgerGroup WHERE GroupName = CASE WHEN @type = 'BANK' THEN 'Bank Accounts' ELSE 'Cash In Hand' END;
        SET @LedgerId = SCOPE_IDENTITY();
    END
    ELSE
        -- the name and group follow the fund (renamed, or Wallet <-> Bank)
        UPDATE l SET LedgerName = @name, LedgerGroupId = g.LedgerGroupId, LedgerType = CASE WHEN @type = 'BANK' THEN 'BANK' ELSE 'CASH' END
          FROM dbo.Acc_LedgerMaster l
          JOIN dbo.Acc_LedgerGroup g ON g.GroupName = CASE WHEN @type = 'BANK' THEN 'Bank Accounts' ELSE 'Cash In Hand' END
         WHERE l.LedgerId = @LedgerId AND (l.LedgerName <> @name OR l.LedgerGroupId <> g.LedgerGroupId);
    UPDATE dbo.Fund SET LedgerId = @LedgerId WHERE FundId = @FundId AND ISNULL(LedgerId, -1) <> @LedgerId;
END
GO

-- the Cash / Bank ledger of a payment mode (Accounts settings: payment mode ledger of the branch, else of the company)
CREATE OR ALTER FUNCTION dbo.ufn_Acc_ModeLedger (@CompanyId INT, @BranchId INT, @Mode NVARCHAR(30))
RETURNS INT
AS
BEGIN
    DECLARE @m VARCHAR(20) = CASE UPPER(LTRIM(RTRIM(@Mode))) WHEN 'CASH' THEN 'CASH' WHEN 'UPI' THEN 'UPI' WHEN 'CHEQUE' THEN 'CHEQUE' WHEN 'CARD' THEN 'CARD' ELSE 'NEFT' END;
    RETURN COALESCE(
        (SELECT TOP 1 LedgerId FROM dbo.Acc_PaymentModeLedger WHERE CompanyId = @CompanyId AND MethodCode = @m AND BranchId = @BranchId),
        (SELECT TOP 1 LedgerId FROM dbo.Acc_PaymentModeLedger WHERE CompanyId = @CompanyId AND MethodCode = @m AND BranchId IS NULL),
        (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = CASE WHEN @m = 'CASH' THEN 'LGR0003' ELSE 'LGR0008' END));
END
GO

-- a branch to post on: the given one, else the company's Head Office
CREATE OR ALTER FUNCTION dbo.ufn_Acc_PostingBranch (@CompanyId INT, @BranchId INT)
RETURNS INT
AS
BEGIN
    RETURN COALESCE(NULLIF(@BranchId, 0),
        (SELECT TOP 1 BranchID FROM dbo.Branchmaster WHERE CompanyId = @CompanyId AND IsHOBranch = 1 ORDER BY BranchID),
        (SELECT TOP 1 BranchID FROM dbo.Branchmaster WHERE CompanyId = @CompanyId ORDER BY BranchID));
END
GO

-- ── fund postings ──────────────────────────────────────────────────────────────────────────────────────────
-- @Kind OPENING (@RefId = FundId; a changed opening re-posts) | TOPUP (@RefId = FundTxnId)
CREATE OR ALTER PROCEDURE dbo.usp_Fund_PostLedger @Kind VARCHAR(10), @RefId BIGINT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tid BIGINT, @vno NVARCHAR(50), @rev BIGINT, @lines NVARCHAR(MAX), @fl INT, @co INT, @br INT, @amt DECIMAL(18, 2), @date DATE,
            @fund INT, @name NVARCHAR(150), @mode NVARCHAR(30), @ref NVARCHAR(100), @narr NVARCHAR(500);
    IF @Kind = 'OPENING'
    BEGIN
        SELECT @fund = FundId, @co = CompanyId, @br = dbo.ufn_Acc_PostingBranch(CompanyId, BranchId), @amt = OpeningBalance, @date = OpeningDate, @name = FundName
          FROM dbo.Fund WHERE FundId = @RefId;
        IF @fund IS NULL RETURN;
        EXEC dbo.usp_Fund_Ledger @fund, @fl OUTPUT;
        -- the opening already posted: kept when unchanged, else reversed and posted again
        SELECT TOP 1 @tid = t.TransactionId FROM dbo.Acc_LedgerTransaction t
         WHERE t.ReferenceType = 'FUND_OPEN' AND t.ReferenceId = @fund AND t.IsActive = 1 AND t.Status = 'P' AND t.ReversalOfTransactionId IS NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction r WHERE r.ReversalOfTransactionId = t.TransactionId);
        IF @tid IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE TransactionId = @tid AND TotalAmount = @amt AND CAST(TransactionDate AS DATE) = @date) RETURN;
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @tid, @Reason = N'Fund opening balance corrected', @UserId = @UserId, @ReversalId = @rev OUTPUT;
            SET @tid = NULL;
        END
        IF @amt <= 0 RETURN;
        DECLARE @obd INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = N'Opening Balance Difference');
        SET @narr = N'Opening balance of fund ' + @name;
        SET @lines = (SELECT * FROM (VALUES (@fl, @amt, CAST(0 AS DECIMAL(18, 2)), @narr), (@obd, CAST(0 AS DECIMAL(18, 2)), @amt, @narr)) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        -- the old opening (if any) is cancelled above, so the reference posts again as a new entry
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'OPN', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br,
             @ReferenceType = 'FUND_OPEN', @ReferenceId = @fund, @Narration = @narr, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'TOPUP'
    BEGIN
        SELECT @fund = t.FundId, @co = t.CompanyId, @br = dbo.ufn_Acc_PostingBranch(t.CompanyId, t.BranchId), @amt = t.Amount, @date = t.TxnDate,
               @mode = t.PaymentMode, @ref = t.ReferenceNo, @name = f.FundName
          FROM dbo.FundTransaction t JOIN dbo.Fund f ON f.FundId = t.FundId WHERE t.FundTxnId = @RefId AND t.TxnType = 'TOPUP';
        IF @fund IS NULL OR @amt <= 0 RETURN;
        EXEC dbo.usp_Fund_Ledger @fund, @fl OUTPUT;
        DECLARE @src INT = dbo.ufn_Acc_ModeLedger(@co, @br, @mode);
        SET @narr = N'Top-up of fund ' + @name + ISNULL(N' (' + @mode + ISNULL(N' ' + @ref, N'') + N')', N'');
        SET @lines = (SELECT * FROM (VALUES (@fl, @amt, CAST(0 AS DECIMAL(18, 2)), @narr), (@src, CAST(0 AS DECIMAL(18, 2)), @amt, @narr)) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        DECLARE @rid INT = CAST(@RefId AS INT);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'CTR', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br,
             @ReferenceType = 'FUND_TOPUP', @ReferenceId = @rid, @Narration = @narr, @PaymentMode = @mode, @InstrumentNo = @ref, @LinesJson = @lines,
             @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
END
GO

-- ── doctor settlement postings ─────────────────────────────────────────────────────────────────────────────
-- @Kind APPROVE (the expense) | PAY (the payment) | REJECT (the approval journal reversed)
CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_PostLedger @Kind VARCHAR(10), @SettlementId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @co INT, @br INT, @no NVARCHAR(30), @doc NVARCHAR(200), @tax DECIMAL(18, 2), @tds DECIMAL(18, 2), @net DECIMAL(18, 2),
            @appDate DATE, @payDate DATE, @mode NVARCHAR(30), @ref NVARCHAR(100), @fund INT, @tid BIGINT, @vno NVARCHAR(50), @rev BIGINT,
            @lines NVARCHAR(MAX), @narr NVARCHAR(500), @fl INT, @payee NVARCHAR(150);
    SELECT @co = ds.CompanyId, @br = ds.BranchId, @no = ds.SettlementNo, @tax = ds.TaxableAmount, @tds = ds.TdsAmount, @net = ds.NetPayable,
           @appDate = CAST(ds.ApprovedOn AS DATE), @payDate = ds.PaymentDate, @mode = ds.PaymentMode, @ref = ds.PaymentReference, @fund = ds.FundId,
           @payee = LEFT(ISNULL(NULLIF(ds.PayeeName, N''), d.FullName), 150),
           @doc = ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor')
      FROM dbo.DoctorSettlement ds LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = ds.DoctorId WHERE ds.SettlementId = @SettlementId;
    IF @co IS NULL RETURN;
    DECLARE @feesL INT = (SELECT LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'DOC_FEES'),
            @payL  INT = (SELECT LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'DOC_PAYABLE'),
            @tdsL  INT = (SELECT LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'TDS_194J');

    IF @Kind = 'APPROVE'
    BEGIN
        IF ISNULL(@tax, 0) <= 0 RETURN;                         -- nothing to recognise
        SET @narr = N'Doctor share settlement ' + @no + N' - ' + @doc;
        SET @lines = (SELECT * FROM (VALUES
                        (@feesL, @tax, CAST(0 AS DECIMAL(18, 2)), @narr),
                        (@payL, CAST(0 AS DECIMAL(18, 2)), @net, N'Payable to ' + @doc),
                        (@tdsL, CAST(0 AS DECIMAL(18, 2)), @tds, N'TDS 194J on ' + @no)) v (LedgerId, Dr, Cr, Narration)
                       WHERE Dr > 0 OR Cr > 0 FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'JRN', @TransactionDate = @appDate, @CompanyId = @co, @BranchId = @br,
             @ReferenceType = 'DOC_SETTLE', @ReferenceId = @SettlementId, @Narration = @narr, @PayeeName = @payee, @LinesJson = @lines,
             @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'PAY'
    BEGIN
        IF ISNULL(@net, 0) <= 0 RETURN;
        IF @fund IS NOT NULL EXEC dbo.usp_Fund_Ledger @fund, @fl OUTPUT;
        ELSE SET @fl = dbo.ufn_Acc_ModeLedger(@co, @br, @mode);
        SET @narr = N'Doctor payout ' + @no + N' - ' + @doc + ISNULL(N' (' + @mode + ISNULL(N' ' + @ref, N'') + N')', N'');
        SET @lines = (SELECT * FROM (VALUES (@payL, @net, CAST(0 AS DECIMAL(18, 2)), @narr), (@fl, CAST(0 AS DECIMAL(18, 2)), @net, @narr)) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'PMT', @TransactionDate = @payDate, @CompanyId = @co, @BranchId = @br,
             @ReferenceType = 'DOC_PAY', @ReferenceId = @SettlementId, @Narration = @narr, @PayeeName = @payee, @PaymentMode = @mode, @InstrumentNo = @ref,
             @InstrumentDate = @payDate, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'REJECT'
    BEGIN
        SELECT TOP 1 @tid = t.TransactionId FROM dbo.Acc_LedgerTransaction t
         WHERE t.ReferenceType = 'DOC_SETTLE' AND t.ReferenceId = @SettlementId AND t.IsActive = 1 AND t.Status = 'P' AND t.ReversalOfTransactionId IS NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction r WHERE r.ReversalOfTransactionId = t.TransactionId);
        IF @tid IS NOT NULL
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @tid, @Reason = N'Doctor settlement rejected', @UserId = @UserId, @ReversalId = @rev OUTPUT;
    END
END
GO

-- ── hooks: the actions post as they happen ─────────────────────────────────────────────────────────────────
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_DoctorPayout_Action'));
DECLARE @a1 NVARCHAR(MAX) = N'            UPDATE dbo.DoctorDisbursal SET ApprovalStatus = ''APPROVED'', ApprovedBy = @UserId, ApprovedDate = GETDATE(), ModifiedDate = GETDATE(), ModifiedBy = @UserId
            WHERE SettlementId = @SettlementId;';
DECLARE @a2 NVARCHAR(MAX) = N'            -- its lines go back to be settled again';
DECLARE @a3 NVARCHAR(MAX) = N'            UPDATE dbo.DoctorDisbursal SET PaymentStatus = ''Paid'', PaymentMethod = @PaymentMode, PaymentReference = @PaymentReference,';
IF @def LIKE N'%usp_DoctorPayout_PostLedger%' PRINT '2526: usp_DoctorPayout_Action already posts to the ledger.';
ELSE IF CHARINDEX(@a1, @def) = 0 OR CHARINDEX(@a2, @def) = 0 OR CHARINDEX(@a3, @def) = 0
    PRINT '2526: usp_DoctorPayout_Action has changed - ledger posting was NOT added. Add it by hand.';
ELSE
BEGIN
    SET @def = REPLACE(@def, @a1, @a1 + N'
            EXEC dbo.usp_DoctorPayout_PostLedger ''APPROVE'', @SettlementId, @UserId;   -- 2526: the expense');
    SET @def = REPLACE(@def, @a2, N'            -- 2526: an approved settlement rejected - its approval journal is reversed
            IF @Action = ''REJECT'' AND @Status = ''APPROVED'' EXEC dbo.usp_DoctorPayout_PostLedger ''REJECT'', @SettlementId, @UserId;
' + @a2);
    SET @def = REPLACE(@def, @a3, N'            EXEC dbo.usp_DoctorPayout_PostLedger ''PAY'', @SettlementId, @UserId;   -- 2526: the payment (fund / cash / bank)
' + @a3);
    SET @def = REPLACE(@def, N'CREATE   PROCEDURE', N'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
    PRINT '2526: usp_DoctorPayout_Action posts to the ledger.';
END
GO
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_Api_Fund_Save'));
DECLARE @f1 NVARCHAR(MAX) = N'        VALUES (@FundId, @CompanyId, @BranchId, ''OPENING'', @OpeningDate, @OpeningBalance, @OpeningBalance, N''Opening balance'', @UserId);';
DECLARE @f2 NVARCHAR(MAX) = N'            UPDATE dbo.FundTransaction SET TxnDate = @OpeningDate, Amount = @OpeningBalance, BalanceAfter = @OpeningBalance
             WHERE FundId = @FundId AND TxnType = ''OPENING'';';
IF @def LIKE N'%usp_Fund_PostLedger%' PRINT '2526: usp_Api_Fund_Save already posts to the ledger.';
ELSE IF CHARINDEX(@f1, @def) = 0 OR CHARINDEX(@f2, @def) = 0 PRINT '2526: usp_Api_Fund_Save has changed - ledger posting was NOT added.';
ELSE
BEGIN
    SET @def = REPLACE(@def, @f1, @f1 + N'
        EXEC dbo.usp_Fund_PostLedger ''OPENING'', @FundId, @UserId;   -- 2526');
    SET @def = REPLACE(@def, @f2, @f2 + N'
        -- 2526: the ledger follows (the fund''s name, and a corrected opening balance re-posted)
        DECLARE @fl INT; EXEC dbo.usp_Fund_Ledger @FundId, @fl OUTPUT;
        IF @moved = 0 EXEC dbo.usp_Fund_PostLedger ''OPENING'', @FundId, @UserId;');
    SET @def = REPLACE(@def, N'CREATE   PROCEDURE', N'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
    PRINT '2526: usp_Api_Fund_Save posts to the ledger.';
END
GO
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_Api_Fund_TopUp'));
DECLARE @t1 NVARCHAR(MAX) = N'    DECLARE @tx BIGINT = SCOPE_IDENTITY();';
IF @def LIKE N'%usp_Fund_PostLedger%' PRINT '2526: usp_Api_Fund_TopUp already posts to the ledger.';
ELSE IF CHARINDEX(@t1, @def) = 0 PRINT '2526: usp_Api_Fund_TopUp has changed - ledger posting was NOT added.';
ELSE
BEGIN
    SET @def = REPLACE(@def, @t1, @t1 + N'
    EXEC dbo.usp_Fund_PostLedger ''TOPUP'', @tx, @UserId;   -- 2526: Dr fund, Cr cash / bank');
    SET @def = REPLACE(@def, N'CREATE   PROCEDURE', N'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
    PRINT '2526: usp_Api_Fund_TopUp posts to the ledger.';
END
GO

-- ── backfill: what is already there gets its vouchers (dated as it happened); one that cannot post is reported ──
DECLARE @id BIGINT, @u INT, @k VARCHAR(10), @n INT = 0, @skip INT = 0;
DECLARE b CURSOR LOCAL FAST_FORWARD FOR
    SELECT 'OPENING', CAST(FundId AS BIGINT), CreatedBy FROM dbo.Fund WHERE IsDeleted = 0 AND OpeningBalance > 0
       AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'FUND_OPEN' AND t.ReferenceId = Fund.FundId)
    UNION ALL
    SELECT 'TOPUP', FundTxnId, CreatedBy FROM dbo.FundTransaction WHERE TxnType = 'TOPUP'
       AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'FUND_TOPUP' AND t.ReferenceId = FundTransaction.FundTxnId);
OPEN b; FETCH NEXT FROM b INTO @k, @id, @u;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY BEGIN TRAN; EXEC dbo.usp_Fund_PostLedger @k, @id, @u; COMMIT; SET @n += 1; END TRY
    BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK; SET @skip += 1; PRINT CONCAT('2526: fund ', @k, ' #', @id, ' not posted - ', ERROR_MESSAGE()); END CATCH
    FETCH NEXT FROM b INTO @k, @id, @u;
END
CLOSE b; DEALLOCATE b;
DECLARE s CURSOR LOCAL FAST_FORWARD FOR
    SELECT 'APPROVE', SettlementId, ApprovedBy FROM dbo.DoctorSettlement WHERE Status IN ('APPROVED', 'PAID') AND ApprovedOn IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'DOC_SETTLE' AND t.ReferenceId = DoctorSettlement.SettlementId)
    UNION ALL
    SELECT 'PAY', SettlementId, PaidBy FROM dbo.DoctorSettlement WHERE Status = 'PAID' AND PaymentDate IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'DOC_PAY' AND t.ReferenceId = DoctorSettlement.SettlementId)
    ORDER BY 2, 1;
OPEN s; FETCH NEXT FROM s INTO @k, @id, @u;
WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @sid INT = CAST(@id AS INT);
    BEGIN TRY BEGIN TRAN; EXEC dbo.usp_DoctorPayout_PostLedger @k, @sid, @u; COMMIT; SET @n += 1; END TRY
    BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK; SET @skip += 1; PRINT CONCAT('2526: settlement ', @k, ' #', @sid, ' not posted - ', ERROR_MESSAGE()); END CATCH
    FETCH NEXT FROM s INTO @k, @id, @u;
END
CLOSE s; DEALLOCATE s;
PRINT CONCAT('2526: backfill - ', @n, ' voucher(s) posted, ', @skip, ' skipped.');
GO
PRINT 'Script 2526 applied: Fund Master and doctor payout post to the Accounts ledger.';
GO
SET NOEXEC OFF;
GO
