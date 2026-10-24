-- ============================================================================================================
-- Migration: 2322_accounts_phase1_numbering_modes_opening_recon.sql
-- Accounts Phase 1 - trustworthy books. Needs the Accounts scripts (104, 2244 - 2250). Safe to re-run.
--
-- 1. Voucher numbers: every automatic posting (bills, receipts, discounts, refunds, B2B, membership, petty cash...)
--    now gets a unique number per voucher type / branch / financial year, from the same sequence the manual vouchers
--    use (e.g. RCT/HO/26-27/00042) - it used to be a time stamp ("VCH-20261010230643") shared by many entries.
--    Old entries are renumbered after the numbers already issued; their old number is kept in LegacyVoucherNo.
-- 2. Financial year: stamped on every posting (it was blank on automatic ones) and filled in for the old ones.
-- 3. Payment mode -> ledger: Accounts Settings maps each payment method (Cash, Card, UPI, NEFT...) to a cash or bank
--    ledger, for all branches or one branch. Receipts, refunds, B2B settlements, wallet top-ups and membership card
--    payments post to the mapped ledger. Seeded exactly as today (Cash -> Cash Account, the rest -> Bank Account), so
--    nothing changes until a mapping is edited. "Bank Account" moves to the Bank Accounts group.
--    (A cash wallet top-up used to post to Bank Account; it now follows the mapping, i.e. Cash Account.)
-- 4. Opening balances: per branch, posted as an Opening Balance voucher (type OPN) on the go-live date, so the Trial
--    Balance, Ledger Statement and every report include them. A difference goes to "Opening Balance Difference".
-- 5. Reconciliation: bills vs the receivable ledgers (patient / franchise / corporate), with each difference explained,
--    and a repair that posts what was missed (bill, receipt, refund, cancellation) and reverses old duplicate entries
--    (B2B bills posted once as patient bills before B2B posting existed). Nothing is deleted: fixes are new entries.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── schema ──────────────────────────────────────────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.Acc_LedgerTransaction', 'LegacyVoucherNo') IS NULL
    ALTER TABLE dbo.Acc_LedgerTransaction ADD LegacyVoucherNo NVARCHAR(50) NULL;
GO

IF OBJECT_ID(N'dbo.Acc_PaymentModeLedger', N'U') IS NULL
CREATE TABLE dbo.Acc_PaymentModeLedger
(
    ModeLedgerId  INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Acc_PaymentModeLedger PRIMARY KEY,
    CompanyId     INT           NOT NULL,
    BranchId      INT           NULL,            -- NULL = every branch
    MethodCode    NVARCHAR(30)  NOT NULL,        -- PaymentMethodMaster.MethodCode (CASH, CARD, UPI, NEFT, CHEQUE, WALLET...)
    LedgerId      INT           NOT NULL,
    ModifiedBy    INT           NULL,
    ModifiedDate  DATETIME      NOT NULL CONSTRAINT DF_Acc_PaymentModeLedger_Modified DEFAULT (GETDATE())
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Acc_PaymentModeLedger' AND object_id = OBJECT_ID(N'dbo.Acc_PaymentModeLedger'))
    CREATE UNIQUE INDEX UX_Acc_PaymentModeLedger ON dbo.Acc_PaymentModeLedger (CompanyId, BranchId, MethodCode);
GO

-- Opening Balance voucher type and the difference ledger
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_VoucherType WHERE VoucherTypeCode = 'OPN')
    INSERT dbo.Acc_VoucherType (VoucherTypeName, Prefix, IsActive, VoucherTypeCode, IsManual) VALUES (N'Opening Balance', N'OPN', 1, 'OPN', 0);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = N'Opening Balance Difference')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerType, IsSystem, Remarks)
    SELECT N'Opening Balance Difference', g.LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'Liability', 1,
           N'Takes the difference of the opening balances until it is corrected (Opening Balances screen).'
    FROM dbo.Acc_LedgerGroup g WHERE g.GroupName = N'Capital Account';
GO

-- "Bank Account" belongs to the Bank Accounts group (it was under Current Assets)
UPDATE l SET LedgerGroupId = g.LedgerGroupId
FROM dbo.Acc_LedgerMaster l CROSS JOIN dbo.Acc_LedgerGroup g
WHERE l.LedgerName = N'Bank Account' AND g.GroupName = N'Bank Accounts' AND l.LedgerGroupId <> g.LedgerGroupId;
GO

-- seed the mapping exactly as the posting worked so far
INSERT dbo.Acc_PaymentModeLedger (CompanyId, BranchId, MethodCode, LedgerId)
SELECT c.CompanyId, NULL, UPPER(m.MethodCode),
       CASE WHEN UPPER(m.MethodCode) = 'CASH' THEN cash.LedgerId ELSE bank.LedgerId END
FROM dbo.CompanyMaster c
CROSS JOIN dbo.PaymentMethodMaster m
CROSS APPLY (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = N'Cash Account') cash
CROSS APPLY (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = N'Bank Account') bank
WHERE c.IsActive = 1 AND UPPER(m.MethodCode) NOT IN ('POINTS')
  AND NOT EXISTS (SELECT 1 FROM dbo.Acc_PaymentModeLedger x WHERE x.CompanyId = c.CompanyId AND x.BranchId IS NULL AND x.MethodCode = UPPER(m.MethodCode));
GO

-- ── payment mode -> ledger ──────────────────────────────────────────────────────────────────────────────────
-- the ledger a payment method posts to: the branch's mapping, else the company's, else @Default (the old rule)
CREATE OR ALTER FUNCTION dbo.fn_Acc_ModeLedger (@BranchId INT, @MethodCode NVARCHAR(30), @Default INT)
RETURNS INT
AS
BEGIN
    DECLARE @co INT = ISNULL((SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId), 1), @id INT;
    SET @MethodCode = UPPER(LTRIM(RTRIM(@MethodCode)));
    SELECT TOP 1 @id = m.LedgerId
    FROM dbo.Acc_PaymentModeLedger m
    INNER JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = m.LedgerId AND l.IsActive = 1
    WHERE m.CompanyId = @co AND m.MethodCode = @MethodCode AND (m.BranchId = @BranchId OR m.BranchId IS NULL)
    ORDER BY CASE WHEN m.BranchId IS NULL THEN 1 ELSE 0 END;
    RETURN ISNULL(@id, @Default);
END
GO

CREATE OR ALTER FUNCTION dbo.fn_Acc_ModeLedgerByMethodId (@BranchId INT, @PaymentMethodId INT, @Default INT)
RETURNS INT
AS
BEGIN
    RETURN dbo.fn_Acc_ModeLedger(@BranchId, (SELECT MethodCode FROM dbo.PaymentMethodMaster WHERE PaymentMethodId = @PaymentMethodId), @Default);
END
GO

-- ── voucher numbering for automatic postings ────────────────────────────────────────────────────────────────
-- Same parameters as before; the number now comes from Acc_VoucherSequence (shared with manual vouchers) and the
-- financial year is stamped. Period locks are not checked here: an automatic posting is never refused (billing goes on).
CREATE OR ALTER PROCEDURE dbo.usp_Ledger_PostEntry
    @VoucherTypeId INT,
    @TransactionDate DATETIME,
    @ReferenceType NVARCHAR(50),
    @ReferenceId INT,
    @BranchId INT,
    @CompanyId INT,
    @TotalAmount DECIMAL(18,2),
    @Narration NVARCHAR(MAX),
    @DebitLedgerId INT,
    @CreditLedgerId INT,
    @CreatedBy INT,
    @NewTransactionId BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @co INT = ISNULL(@CompanyId, 1), @br INT = ISNULL(@BranchId, 0), @no INT;
    DECLARE @fyStart TINYINT = ISNULL((SELECT TOP 1 FinancialYearStartMonth FROM dbo.Acc_Settings WHERE CompanyId = @co), 4);
    DECLARE @fy VARCHAR(7) = dbo.fn_Acc_FinancialYear(ISNULL(@TransactionDate, GETDATE()), @fyStart);
    DECLARE @prefix NVARCHAR(10) = ISNULL((SELECT ISNULL(NULLIF(Prefix, ''), VoucherTypeCode) FROM dbo.Acc_VoucherType WHERE VoucherTypeId = @VoucherTypeId), N'VCH');
    DECLARE @branchCode NVARCHAR(20) = ISNULL((SELECT NULLIF(BranchCode, '') FROM dbo.Branchmaster WHERE BranchID = @br), CAST(@br AS NVARCHAR(10)));
    DECLARE @VoucherNo NVARCHAR(50);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.Acc_VoucherSequence WITH (UPDLOCK, HOLDLOCK) SET @no = LastNo = LastNo + 1
        WHERE CompanyId = @co AND BranchId = @br AND VoucherTypeId = @VoucherTypeId AND FinancialYear = @fy;
        IF @@ROWCOUNT = 0
        BEGIN
            SET @no = 1;
            INSERT INTO dbo.Acc_VoucherSequence (CompanyId, BranchId, VoucherTypeId, FinancialYear, LastNo) VALUES (@co, @br, @VoucherTypeId, @fy, 1);
        END
        SET @VoucherNo = CONCAT(@prefix, '/', @branchCode, '/', @fy, '/', RIGHT('00000' + CAST(@no AS VARCHAR(10)), 5));

        INSERT INTO dbo.Acc_LedgerTransaction
            (VoucherTypeId, VoucherNo, TransactionDate, ReferenceType, ReferenceId, BranchId, CompanyId, TotalAmount, Narration, CreatedBy, CreatedDate,
             Status, IsManual, FinancialYear)
        VALUES
            (@VoucherTypeId, @VoucherNo, @TransactionDate, @ReferenceType, @ReferenceId, @BranchId, @CompanyId, @TotalAmount, @Narration, @CreatedBy, GETDATE(),
             'P', 0, @fy);

        SET @NewTransactionId = SCOPE_IDENTITY();

        INSERT INTO dbo.Acc_LedgerTransactionDetail (TransactionId, LedgerId, DebitAmount, CreditAmount, Narration)
        VALUES (@NewTransactionId, @DebitLedgerId, @TotalAmount, 0, @Narration);

        INSERT INTO dbo.Acc_LedgerTransactionDetail (TransactionId, LedgerId, DebitAmount, CreditAmount, Narration)
        VALUES (@NewTransactionId, @CreditLedgerId, 0, @TotalAmount, @Narration);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── backfill: financial year, then unique numbers for the old automatic entries ─────────────────────────────
UPDATE t SET FinancialYear = dbo.fn_Acc_FinancialYear(t.TransactionDate, ISNULL(s.FinancialYearStartMonth, 4))
FROM dbo.Acc_LedgerTransaction t
LEFT JOIN dbo.Acc_Settings s ON s.CompanyId = ISNULL(t.CompanyId, 1)
WHERE t.FinancialYear IS NULL;
GO

BEGIN TRANSACTION;
    SELECT t.TransactionId, ISNULL(t.CompanyId, 1) AS Co, ISNULL(t.BranchId, 0) AS Br, t.VoucherTypeId, t.FinancialYear AS Fy,
           ROW_NUMBER() OVER (PARTITION BY ISNULL(t.CompanyId, 1), ISNULL(t.BranchId, 0), t.VoucherTypeId, t.FinancialYear
                              ORDER BY t.TransactionDate, t.TransactionId) AS Rn
    INTO #old
    FROM dbo.Acc_LedgerTransaction t WITH (UPDLOCK, HOLDLOCK)
    WHERE t.VoucherNo LIKE 'VCH-%' AND t.LegacyVoucherNo IS NULL;

    -- the groups that have no sequence row yet start at 0
    INSERT dbo.Acc_VoucherSequence (CompanyId, BranchId, VoucherTypeId, FinancialYear, LastNo)
    SELECT DISTINCT o.Co, o.Br, o.VoucherTypeId, o.Fy, 0 FROM #old o
    WHERE NOT EXISTS (SELECT 1 FROM dbo.Acc_VoucherSequence s WHERE s.CompanyId = o.Co AND s.BranchId = o.Br AND s.VoucherTypeId = o.VoucherTypeId AND s.FinancialYear = o.Fy);

    UPDATE t SET LegacyVoucherNo = t.VoucherNo,
                 VoucherNo = CONCAT(ISNULL(NULLIF(vt.Prefix, ''), ISNULL(vt.VoucherTypeCode, 'VCH')), '/',
                                    ISNULL(NULLIF(b.BranchCode, ''), CAST(o.Br AS NVARCHAR(10))), '/', o.Fy, '/',
                                    RIGHT('00000' + CAST(s.LastNo + o.Rn AS VARCHAR(10)), 5))
    FROM dbo.Acc_LedgerTransaction t
    INNER JOIN #old o ON o.TransactionId = t.TransactionId
    INNER JOIN dbo.Acc_VoucherSequence s ON s.CompanyId = o.Co AND s.BranchId = o.Br AND s.VoucherTypeId = o.VoucherTypeId AND s.FinancialYear = o.Fy
    LEFT JOIN dbo.Acc_VoucherType vt ON vt.VoucherTypeId = t.VoucherTypeId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = o.Br;

    UPDATE s SET LastNo = s.LastNo + x.Cnt
    FROM dbo.Acc_VoucherSequence s
    INNER JOIN (SELECT Co, Br, VoucherTypeId, Fy, COUNT(*) AS Cnt FROM #old GROUP BY Co, Br, VoucherTypeId, Fy) x
            ON x.Co = s.CompanyId AND x.Br = s.BranchId AND x.VoucherTypeId = s.VoucherTypeId AND x.Fy = s.FinancialYear;

    DECLARE @renumbered INT = (SELECT COUNT(*) FROM #old);
    PRINT CONCAT('Old automatic entries renumbered: ', @renumbered);
    DROP TABLE #old;
COMMIT TRANSACTION;
GO

-- a voucher number is unique within a company from now on
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Acc_LedgerTransaction_VoucherNo' AND object_id = OBJECT_ID(N'dbo.Acc_LedgerTransaction'))
   AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction GROUP BY CompanyId, VoucherNo HAVING COUNT(*) > 1)
    CREATE UNIQUE INDEX UX_Acc_LedgerTransaction_VoucherNo ON dbo.Acc_LedgerTransaction (CompanyId, VoucherNo);
GO

-- ── the money procedures follow the payment mode mapping ────────────────────────────────────────────────────
-- Each live procedure is changed only at the exact line below; a procedure that does not contain that line (already
-- changed, or different on this database) is left as it is and a message says so.
DECLARE @Patches TABLE (Seq INT IDENTITY(1, 1), Proc_ SYSNAME, OldText NVARCHAR(MAX), NewText NVARCHAR(MAX), Marker NVARCHAR(200));
INSERT @Patches (Proc_, OldText, NewText, Marker) VALUES
(N'usp_Ledger_PostBillMoney',
 N'SET @Dr = CASE WHEN @MethodCode = ''CASH'' THEN @Cash ELSE @Bank END;',
 N'SET @Dr = dbo.fn_Acc_ModeLedger(@BranchId, @MethodCode, CASE WHEN @MethodCode = ''CASH'' THEN @Cash ELSE @Bank END);   -- 2322: payment mode -> ledger',
 N'SET @Dr = dbo.fn_Acc_ModeLedger('),
(N'usp_Ledger_PostBillMoney',
 N'SET @MethodCode = CASE WHEN @Mode = ''CASH'' THEN ''CASH'' ELSE ''BANK'' END;',
 N'SET @MethodCode = ISNULL((SELECT TOP 1 UPPER(MethodCode) FROM dbo.PaymentMethodMaster WHERE UPPER(MethodCode) = @Mode OR UPPER(MethodName) = @Mode),
                               CASE WHEN @Mode = ''CASH'' THEN ''CASH'' ELSE ''BANK'' END);   -- 2322: the refund''s payment method',
 N'-- 2322: the refund''s payment method'),
(N'usp_Ledger_PostBillMoney',
 N'SET @Cr = CASE WHEN @MethodCode = ''CASH'' THEN @Cash ELSE @Bank END;',
 N'SET @Cr = dbo.fn_Acc_ModeLedger(@BranchId, @MethodCode, CASE WHEN @MethodCode = ''CASH'' THEN @Cash ELSE @Bank END);   -- 2322: payment mode -> ledger',
 N'SET @Cr = dbo.fn_Acc_ModeLedger('),
(N'usp_B2B_SettleBillsPayment',
 N'DECLARE @SettleNarration NVARCHAR(500)',
 N'SET @DebitLedgerId = dbo.fn_Acc_ModeLedgerByMethodId(@BranchId, @PaymentMethodId, @DebitLedgerId);   -- 2322: payment mode -> ledger
        DECLARE @SettleNarration NVARCHAR(500)',
 N'fn_Acc_ModeLedgerByMethodId'),
(N'usp_B2B_FranchiseWallet_TopUp',
 N'DECLARE @DebitLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = ''Bank Account'');',
 N'DECLARE @DebitLedgerId INT = dbo.fn_Acc_ModeLedgerByMethodId(@BranchId, @PaymentMethodId, (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = ''Bank Account''));   -- 2322',
 N'fn_Acc_ModeLedgerByMethodId'),
(N'usp_Api_MembershipCard_Issue',
 N'THEN ''Cash Account'' ELSE ''Bank Account'' END);',
 N'THEN ''Cash Account'' ELSE ''Bank Account'' END);
        SET @MoneyLedgerId = dbo.fn_Acc_ModeLedgerByMethodId(@BranchId, @PaymentMethodId, @MoneyLedgerId);   -- 2322: payment mode -> ledger',
 N'fn_Acc_ModeLedgerByMethodId');

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @Patches), @proc SYSNAME, @old NVARCHAR(MAX), @new NVARCHAR(MAX), @marker NVARCHAR(200), @def NVARCHAR(MAX), @pos INT;
WHILE @i <= @n
BEGIN
    SELECT @proc = Proc_, @old = OldText, @new = NewText, @marker = Marker FROM @Patches WHERE Seq = @i;
    SET @def = OBJECT_DEFINITION(OBJECT_ID(N'dbo.' + @proc));
    IF @def IS NULL PRINT CONCAT('2322: ', @proc, ' not found - skipped.');
    ELSE IF CHARINDEX(@marker, @def) > 0 PRINT CONCAT('2322: ', @proc, ' already follows the mapping (', LEFT(@marker, 40), ').');
    ELSE IF CHARINDEX(@old, @def) = 0 PRINT CONCAT('2322: WARNING ', @proc, ' does not contain the expected line - not changed: ', LEFT(@old, 80));
    ELSE
    BEGIN
        SET @def = REPLACE(@def, @old, @new);
        SET @pos = PATINDEX(N'%CREATE%PROC%', @def);
        SET @def = STUFF(@def, @pos, 6, N'ALTER ');
        EXEC sys.sp_executesql @def;
        PRINT CONCAT('2322: ', @proc, ' now follows the payment mode mapping.');
    END
    SET @i += 1;
END
GO

-- ── opening balances ────────────────────────────────────────────────────────────────────────────────────────
-- the branch's opening entry (if any) with every active ledger and its opening amount
CREATE OR ALTER PROCEDURE dbo.usp_Acc_Opening_Get
    @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tx BIGINT = (SELECT TOP 1 TransactionId FROM dbo.Acc_LedgerTransaction
                          WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND ReferenceType = 'OPENING' AND IsActive = 1 ORDER BY TransactionId DESC);
    SELECT t.TransactionId, t.VoucherNo, t.TransactionDate AS AsOfDate, t.CreatedDate, COALESCE(NULLIF(u.FullName, ''), u.Username) AS ByUser
    FROM dbo.Acc_LedgerTransaction t LEFT JOIN dbo.Users u ON u.Id = t.CreatedBy
    WHERE t.TransactionId = @tx;

    SELECT l.LedgerId, l.LedgerName, l.LedgerCode, g.GroupName, g.GroupType,
           CAST(ISNULL(SUM(d.DebitAmount), 0) AS DECIMAL(18,2)) AS Debit, CAST(ISNULL(SUM(d.CreditAmount), 0) AS DECIMAL(18,2)) AS Credit
    FROM dbo.Acc_LedgerMaster l
    INNER JOIN dbo.Acc_LedgerGroup g ON g.LedgerGroupId = l.LedgerGroupId
    LEFT JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = @tx AND d.LedgerId = l.LedgerId
    WHERE l.IsActive = 1 AND g.GroupType IN ('Asset', 'Liability')        -- income and expense start at zero
    GROUP BY l.LedgerId, l.LedgerName, l.LedgerCode, g.GroupName, g.GroupType
    ORDER BY CASE g.GroupType WHEN 'Asset' THEN 1 ELSE 2 END, g.GroupName, l.LedgerName;
END
GO

-- save the opening balances of a branch: the previous opening entry is cancelled and a new one posted
-- (@LinesJson = [{"LedgerId":1,"Dr":100,"Cr":0}, ...]); a difference goes to "Opening Balance Difference"
CREATE OR ALTER PROCEDURE dbo.usp_Acc_Opening_Save
    @CompanyId INT, @BranchId INT, @AsOfDate DATE, @LinesJson NVARCHAR(MAX), @UserId INT,
    @TransactionId BIGINT OUTPUT, @VoucherNo NVARCHAR(50) OUTPUT, @Difference DECIMAL(18,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @BranchId IS NULL OR @BranchId <= 0 THROW 53101, 'Choose the branch.', 1;
    IF @AsOfDate IS NULL THROW 53102, 'Enter the opening date.', 1;

    DECLARE @lines TABLE (LedgerId INT PRIMARY KEY, Dr DECIMAL(18,2), Cr DECIMAL(18,2));
    INSERT @lines (LedgerId, Dr, Cr)
    SELECT LedgerId, SUM(ISNULL(Dr, 0)), SUM(ISNULL(Cr, 0))
    FROM OPENJSON(@LinesJson) WITH (LedgerId INT '$.LedgerId', Dr DECIMAL(18,2) '$.Dr', Cr DECIMAL(18,2) '$.Cr')
    WHERE LedgerId IS NOT NULL
    GROUP BY LedgerId;
    -- a ledger with both sides keeps the net
    UPDATE @lines SET Dr = CASE WHEN Dr > Cr THEN Dr - Cr ELSE 0 END, Cr = CASE WHEN Cr > Dr THEN Cr - Dr ELSE 0 END;
    DELETE @lines WHERE Dr = 0 AND Cr = 0;
    IF EXISTS (SELECT 1 FROM @lines WHERE Dr < 0 OR Cr < 0) THROW 53103, 'Opening amounts cannot be negative - use the other side.', 1;

    DECLARE @diffLedger INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = N'Opening Balance Difference');
    IF EXISTS (SELECT 1 FROM @lines WHERE LedgerId = @diffLedger) DELETE @lines WHERE LedgerId = @diffLedger;
    SET @Difference = ISNULL((SELECT SUM(Dr) - SUM(Cr) FROM @lines), 0);
    IF @Difference > 0 INSERT @lines (LedgerId, Dr, Cr) VALUES (@diffLedger, 0, @Difference);
    ELSE IF @Difference < 0 INSERT @lines (LedgerId, Dr, Cr) VALUES (@diffLedger, -@Difference, 0);

    BEGIN TRANSACTION;
        UPDATE dbo.Acc_LedgerTransaction
        SET IsActive = 0, Status = 'C', CancelledBy = @UserId, CancelledDate = GETDATE(), CancelReason = N'Replaced by a new opening balance entry'
        WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND ReferenceType = 'OPENING' AND IsActive = 1;

        SET @TransactionId = NULL; SET @VoucherNo = NULL;
        IF EXISTS (SELECT 1 FROM @lines)
        BEGIN
            DECLARE @json NVARCHAR(MAX) = (SELECT LedgerId, Dr, Cr FROM @lines FOR JSON PATH);
            EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'OPN', @TransactionDate = @AsOfDate, @CompanyId = @CompanyId, @BranchId = @BranchId,
                 @ReferenceType = N'OPENING', @ReferenceId = @BranchId, @Narration = N'Opening balances', @LinesJson = @json,
                 @IsManual = 1, @UserId = @UserId, @TransactionId = @TransactionId OUTPUT, @VoucherNo = @VoucherNo OUTPUT;
        END
    COMMIT TRANSACTION;
END
GO

-- ── reconciliation: bills vs the receivable ledgers ─────────────────────────────────────────────────────────
-- RS1 per receivable ledger: the ledger balance and what the bills say is owed
-- RS2 every bill whose patient-receivable entries differ from what it should be, with the reason and whether the
--     repair can fix it; documents never posted (bills, receipts, refunds, cancellations) are included
CREATE OR ALTER PROCEDURE dbo.usp_Acc_Recon_Bills
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @R INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = N'Patient Receivable'),
            @F INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = N'Franchise Receivable'),
            @C INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = N'Corporate Receivable');

    -- patient-receivable movements, each tied back to its bill
    SELECT x.Module, x.RefId, SUM(x.Amt) AS LedgerDue,
           SUM(CASE WHEN x.RefType IN ('LAB_BILL', 'OPD_BILL') THEN 1 ELSE 0 END) AS BillPosts
    INTO #led
    FROM (
        SELECT d.DebitAmount - d.CreditAmount AS Amt, t.ReferenceType AS RefType,
               CASE WHEN t.ReferenceType LIKE 'OPD[_]%' THEN 'OPD' ELSE 'LAB' END AS Module,
               CASE
                   WHEN t.ReferenceType IN ('LAB_BILL', 'OPD_BILL', 'LAB_CANCEL', 'OPD_CANCEL', 'LAB_BILL_REVERSAL', 'OPD_BILL_REVERSAL') THEN t.ReferenceId
                   WHEN t.ReferenceType IN ('LAB_RECEIPT', 'OPD_RECEIPT') THEN (SELECT ph.ModuleRefId FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId WHERE pd.PaymentDetailId = t.ReferenceId)
                   WHEN t.ReferenceType IN ('LAB_REFUND', 'OPD_REFUND') THEN (SELECT r.ModuleRefId FROM dbo.BillRefund r WHERE r.RefundId = t.ReferenceId)
                   WHEN t.ReferenceType IN ('LAB_DISCOUNT', 'OPD_DISCOUNT', 'LAB_ROUNDOFF', 'OPD_ROUNDOFF', 'LAB_MEMDISC', 'OPD_MEMDISC') THEN (SELECT ph.ModuleRefId FROM dbo.PaymentHeader ph WHERE ph.PaymentHeaderId = t.ReferenceId)
               END AS RefId
        FROM dbo.Acc_LedgerTransaction t
        INNER JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId AND d.LedgerId = @R
        WHERE t.IsActive = 1 AND ISNULL(t.CompanyId, 1) = @CompanyId AND (@BranchId IS NULL OR t.BranchId = @BranchId)
          AND (t.ReferenceType LIKE 'LAB[_]%' OR t.ReferenceType LIKE 'OPD[_]%')
    ) x
    WHERE x.RefId IS NOT NULL
    GROUP BY x.Module, x.RefId;

    -- what each B2C bill should leave on the patient receivable: net - money received + refunds (negative = patient credit)
    SELECT b.Module, b.RefId, b.BillNo, b.BillDate, b.BranchId, b.IsActive, b.IsB2B, b.Gross, ph.PaymentHeaderId, ph.NetAmount,
           ISNULL(pay.Received, 0) AS Received, ISNULL(rf.Refunded, 0) AS Refunded,
           CASE WHEN b.IsB2B = 1 THEN 0
                WHEN ph.PaymentHeaderId IS NULL THEN CASE WHEN b.IsActive = 1 THEN b.Gross ELSE 0 END
                ELSE ph.NetAmount - ISNULL(ph.TotalPaid, 0) END AS ExpectedDue,
           -- the payment rows do not add up to the bill's Total Paid (e.g. test rows): never posted automatically
           CAST(CASE WHEN b.IsB2B = 0 AND ph.PaymentHeaderId IS NOT NULL AND ABS(ISNULL(pay.Received, 0) - ISNULL(rf.Refunded, 0) - ISNULL(ph.TotalPaid, 0)) >= 0.01
                     THEN 1 ELSE 0 END AS BIT) AS PaymentMismatch,
           pay.Unposted AS ReceiptsUnposted, rf.Unposted AS RefundsUnposted, cn.Unposted AS CancelsUnposted
    INTO #bill
    FROM (
        SELECT 'LAB' AS Module, lo.LabOrderId AS RefId, lo.BillNo, ISNULL(lo.BookingDate, lo.OrderDate) AS BillDate, lo.BranchId,
               CAST(lo.IsActive AS BIT) AS IsActive, CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, ISNULL(lo.TotalAmount, 0) AS Gross
        FROM dbo.LabOrder lo INNER JOIN dbo.Branchmaster br ON br.BranchID = lo.BranchId AND br.CompanyId = @CompanyId
        WHERE (@BranchId IS NULL OR lo.BranchId = @BranchId) AND ISNULL(lo.TotalAmount, 0) > 0
        UNION ALL
        SELECT 'OPD', o.OPDServiceId, o.OPDBillNo, o.VisitDate, o.BranchId, CAST(o.IsActive AS BIT), CAST(0 AS BIT), ISNULL(o.TotalAmount, 0)
        FROM dbo.PatientOPDService o INNER JOIN dbo.Branchmaster br ON br.BranchID = o.BranchId AND br.CompanyId = @CompanyId
        WHERE (@BranchId IS NULL OR o.BranchId = @BranchId) AND o.OPDBillNo IS NOT NULL AND ISNULL(o.TotalAmount, 0) > 0
    ) b
    OUTER APPLY (SELECT TOP 1 * FROM dbo.PaymentHeader p WHERE RTRIM(p.ModuleCode) = b.Module AND p.ModuleRefId = b.RefId AND p.IsActive = 1 ORDER BY p.PaymentHeaderId DESC) ph
    OUTER APPLY (SELECT SUM(pd.PaidAmount) AS Received, SUM(CASE WHEN posted.TransactionId IS NULL THEN 1 ELSE 0 END) AS Unposted
                 FROM dbo.PaymentDetail pd
                 OUTER APPLY (SELECT TOP 1 t.TransactionId FROM dbo.Acc_LedgerTransaction t
                              WHERE t.ReferenceType = b.Module + '_RECEIPT' AND t.ReferenceId = pd.PaymentDetailId AND t.IsActive = 1) posted
                 WHERE pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1 AND ISNULL(pd.TransactionRef, '') NOT LIKE 'WALLET-DEBIT-%') pay
    OUTER APPLY (SELECT SUM(r.RefundAmount) AS Refunded, SUM(CASE WHEN posted.TransactionId IS NULL THEN 1 ELSE 0 END) AS Unposted
                 FROM dbo.BillRefund r
                 OUTER APPLY (SELECT TOP 1 t.TransactionId FROM dbo.Acc_LedgerTransaction t
                              WHERE t.ReferenceType = b.Module + '_REFUND' AND t.ReferenceId = r.RefundId AND t.IsActive = 1) posted
                 WHERE RTRIM(r.ModuleCode) = b.Module AND r.ModuleRefId = b.RefId AND r.IsActive = 1) rf
    OUTER APPLY (SELECT SUM(CASE WHEN posted.TransactionId IS NULL THEN 1 ELSE 0 END) AS Unposted
                 FROM dbo.BillCancellation c
                 OUTER APPLY (SELECT TOP 1 t.TransactionId FROM dbo.Acc_LedgerTransaction t
                              WHERE t.ReferenceType = b.Module + '_CANCEL' AND t.ReferenceId = b.RefId AND t.IsActive = 1 AND t.Narration LIKE '%' + c.CancellationNo + '%') posted
                 WHERE RTRIM(c.ModuleCode) = b.Module AND c.ModuleRefId = b.RefId AND c.IsActive = 1) cn;

    -- RS1: the receivable ledgers
    SELECT N'Patient Receivable' AS Ledger,
           CAST(ISNULL((SELECT SUM(d.DebitAmount - d.CreditAmount) FROM dbo.Acc_LedgerTransactionDetail d JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId
                         WHERE d.LedgerId = @R AND t.IsActive = 1 AND ISNULL(t.CompanyId, 1) = @CompanyId AND (@BranchId IS NULL OR t.BranchId = @BranchId)), 0) AS DECIMAL(18,2)) AS LedgerBalance,
           CAST(ISNULL((SELECT SUM(ExpectedDue) FROM #bill WHERE IsB2B = 0), 0) AS DECIMAL(18,2)) AS BillsBalance,
           CAST(ISNULL((SELECT SUM(ExpectedDue) FROM #bill WHERE IsB2B = 0 AND ExpectedDue < 0), 0) AS DECIMAL(18,2)) AS PatientCredits
    UNION ALL
    SELECT N'Franchise Receivable',
           CAST(ISNULL((SELECT SUM(d.DebitAmount - d.CreditAmount) FROM dbo.Acc_LedgerTransactionDetail d JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId
                         WHERE d.LedgerId = @F AND t.IsActive = 1 AND ISNULL(t.CompanyId, 1) = @CompanyId AND (@BranchId IS NULL OR t.BranchId = @BranchId)), 0) AS DECIMAL(18,2)),
           NULL, NULL
    UNION ALL
    SELECT N'Corporate Receivable',
           CAST(ISNULL((SELECT SUM(d.DebitAmount - d.CreditAmount) FROM dbo.Acc_LedgerTransactionDetail d JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId
                         WHERE d.LedgerId = @C AND t.IsActive = 1 AND ISNULL(t.CompanyId, 1) = @CompanyId AND (@BranchId IS NULL OR t.BranchId = @BranchId)), 0) AS DECIMAL(18,2)),
           NULL, NULL;

    -- RS2: the bills that do not agree, and why
    CREATE TABLE #issues (Module VARCHAR(5), RefId INT, BillNo NVARCHAR(100) NULL, BillDate DATETIME2 NULL, BranchName NVARCHAR(200) NULL,
                          IsActive BIT NULL, IsB2B BIT NULL, LedgerDue DECIMAL(18,2), ExpectedDue DECIMAL(18,2), Difference DECIMAL(18,2), Reason VARCHAR(30));
    INSERT #issues (Module, RefId, BillNo, BillDate, BranchName, IsActive, IsB2B, LedgerDue, ExpectedDue, Difference, Reason)
    SELECT b.Module, b.RefId, b.BillNo, b.BillDate, br.BranchName, b.IsActive, b.IsB2B,
           CAST(ISNULL(l.LedgerDue, 0) AS DECIMAL(18,2)) AS LedgerDue, CAST(b.ExpectedDue AS DECIMAL(18,2)) AS ExpectedDue,
           CAST(ISNULL(l.LedgerDue, 0) - b.ExpectedDue AS DECIMAL(18,2)) AS Difference,
           CASE
               WHEN b.PaymentMismatch = 1 THEN 'PAYMENT_RECORD_MISMATCH'
               WHEN b.IsB2B = 1 AND ISNULL(l.BillPosts, 0) > 0 THEN 'DUPLICATE_B2B'
               WHEN b.IsB2B = 0 AND b.PaymentHeaderId IS NOT NULL AND ISNULL(l.BillPosts, 0) = 0 THEN 'BILL_NOT_POSTED'
               WHEN ISNULL(b.ReceiptsUnposted, 0) > 0 THEN 'RECEIPT_NOT_POSTED'
               WHEN ISNULL(b.RefundsUnposted, 0) > 0 THEN 'REFUND_NOT_POSTED'
               WHEN ISNULL(b.CancelsUnposted, 0) > 0 THEN 'CANCEL_NOT_POSTED'
               WHEN b.IsB2B = 0 AND b.PaymentHeaderId IS NULL THEN 'NO_PAYMENT_RECORD'
               ELSE 'OTHER'
           END AS Reason
    FROM #bill b
    LEFT JOIN #led l ON l.Module = b.Module AND l.RefId = b.RefId
    LEFT JOIN dbo.Branchmaster br ON br.BranchID = b.BranchId
    WHERE ABS(ISNULL(l.LedgerDue, 0) - b.ExpectedDue) >= 0.01
       OR (b.IsB2B = 0 AND b.PaymentHeaderId IS NULL AND b.IsActive = 1)
       OR b.PaymentMismatch = 1;

    -- entries of bills that no longer exist (the bill row was deleted)
    INSERT #issues (Module, RefId, BillNo, BillDate, BranchName, IsActive, IsB2B, LedgerDue, ExpectedDue, Difference, Reason)
    SELECT l.Module, l.RefId, N'(deleted bill #' + CAST(l.RefId AS NVARCHAR(20)) + N')', NULL, NULL, CAST(0 AS BIT), CAST(0 AS BIT),
           CAST(l.LedgerDue AS DECIMAL(18,2)), CAST(0 AS DECIMAL(18,2)), CAST(l.LedgerDue AS DECIMAL(18,2)), 'BILL_DELETED'
    FROM #led l
    WHERE ABS(l.LedgerDue) >= 0.01
      AND NOT EXISTS (SELECT 1 FROM #bill b WHERE b.Module = l.Module AND b.RefId = l.RefId)
      AND NOT EXISTS (SELECT 1 FROM dbo.LabOrder lo WHERE l.Module = 'LAB' AND lo.LabOrderId = l.RefId)
      AND NOT EXISTS (SELECT 1 FROM dbo.PatientOPDService o WHERE l.Module = 'OPD' AND o.OPDServiceId = l.RefId);

    SELECT i.*, CAST(CASE WHEN i.Reason IN ('DUPLICATE_B2B', 'BILL_NOT_POSTED', 'RECEIPT_NOT_POSTED', 'REFUND_NOT_POSTED', 'CANCEL_NOT_POSTED', 'BILL_DELETED') THEN 1 ELSE 0 END AS BIT) AS Fixable
    FROM #issues i
    ORDER BY CASE i.Reason WHEN 'OTHER' THEN 9 WHEN 'NO_PAYMENT_RECORD' THEN 8 WHEN 'PAYMENT_RECORD_MISMATCH' THEN 7 ELSE 1 END, ABS(i.Difference) DESC, i.BillDate DESC;

    DROP TABLE #issues; DROP TABLE #bill; DROP TABLE #led;
END
GO

-- Post what is missing and reverse the old duplicates (idempotent; existing entries are never changed or deleted).
CREATE OR ALTER PROCEDURE dbo.usp_Acc_Recon_Repair
    @CompanyId INT, @BranchId INT = NULL, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @R INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = N'Patient Receivable'),
            @Sales INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Sales'),
            @CN INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Credit Note'),
            @LabRev INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = N'LAB Revenue'),
            @OpdRev INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = N'OPD Revenue');
    DECLARE @bills INT = 0, @receipts INT = 0, @refunds INT = 0, @cancels INT = 0, @reversed INT = 0;
    DECLARE @id INT, @id2 INT, @amt DECIMAL(18,2), @when DATETIME, @br INT, @no NVARCHAR(60), @mod VARCHAR(5), @narr NVARCHAR(500), @tx BIGINT, @orig BIGINT, @before INT;

    -- 1. B2C bills with a payment record whose revenue entry was never posted (e.g. OPD > New Service Booking)
    DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR
        SELECT 'OPD', o.OPDServiceId, o.TotalAmount, o.CreatedDate, o.BranchId, o.OPDBillNo, ph.PaymentHeaderId
        FROM dbo.PatientOPDService o
        INNER JOIN dbo.Branchmaster b ON b.BranchID = o.BranchId AND b.CompanyId = @CompanyId
        INNER JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = o.OPDServiceId AND ph.IsActive = 1
        WHERE (@BranchId IS NULL OR o.BranchId = @BranchId) AND ISNULL(o.TotalAmount, 0) > 0 AND o.OPDBillNo IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'OPD_BILL' AND t.ReferenceId = o.OPDServiceId)
        UNION ALL
        SELECT 'LAB', lo.LabOrderId, lo.TotalAmount, lo.CreatedDate, lo.BranchId, lo.BillNo, ph.PaymentHeaderId
        FROM dbo.LabOrder lo
        INNER JOIN dbo.Branchmaster b ON b.BranchID = lo.BranchId AND b.CompanyId = @CompanyId
        INNER JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        WHERE (@BranchId IS NULL OR lo.BranchId = @BranchId) AND ISNULL(lo.TotalAmount, 0) > 0 AND ISNULL(lo.IsB2B, 0) = 0
          AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType IN ('LAB_BILL', 'B2B_LAB_BILL') AND t.ReferenceId = lo.LabOrderId);
    OPEN c1; FETCH NEXT FROM c1 INTO @mod, @id, @amt, @when, @br, @no, @id2;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @narr = N'Revenue recognized for ' + @mod + N' Bill ' + @no + N' (posted by reconciliation)';
        DECLARE @rev INT = CASE WHEN @mod = 'LAB' THEN @LabRev ELSE @OpdRev END, @rt NVARCHAR(50) = @mod + '_BILL';
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Sales, @TransactionDate = @when, @ReferenceType = @rt, @ReferenceId = @id,
             @BranchId = @br, @CompanyId = @CompanyId, @TotalAmount = @amt, @Narration = @narr, @DebitLedgerId = @R, @CreditLedgerId = @rev,
             @CreatedBy = @UserId, @NewTransactionId = @tx OUTPUT;
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'ADJUST', @RefId = @id2, @UserId = @UserId, @TxDate = @when;   -- its discount / round-off
        SET @bills += 1;
        FETCH NEXT FROM c1 INTO @mod, @id, @amt, @when, @br, @no, @id2;
    END
    CLOSE c1; DEALLOCATE c1;

    -- 2. receipts, refunds and cancellations never posted (usp_Ledger_PostBillMoney skips what is already posted)
    DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR
        SELECT pd.PaymentDetailId FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.IsActive = 1
        INNER JOIN dbo.Branchmaster b ON b.BranchID = ph.BranchId AND b.CompanyId = @CompanyId
        WHERE pd.IsActive = 1 AND ph.ModuleCode IN ('LAB', 'OPD') AND (@BranchId IS NULL OR ph.BranchId = @BranchId)
          AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = RTRIM(ph.ModuleCode) + '_RECEIPT' AND t.ReferenceId = pd.PaymentDetailId AND t.IsActive = 1)
          -- only when the bill's payment rows add up to its Total Paid (stray / test rows are left for a person to check)
          AND ABS(ISNULL((SELECT SUM(x.PaidAmount) FROM dbo.PaymentDetail x WHERE x.PaymentHeaderId = ph.PaymentHeaderId AND x.IsActive = 1
                                 AND ISNULL(x.TransactionRef, '') NOT LIKE 'WALLET-DEBIT-%'), 0)
                  - ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.BillRefund r WHERE RTRIM(r.ModuleCode) = RTRIM(ph.ModuleCode) AND r.ModuleRefId = ph.ModuleRefId AND r.IsActive = 1), 0)
                  - ISNULL(ph.TotalPaid, 0)) < 0.01;
    OPEN c2; FETCH NEXT FROM c2 INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @before = (SELECT COUNT(*) FROM dbo.Acc_LedgerTransaction);
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'RECEIPT', @RefId = @id, @UserId = @UserId;
        IF (SELECT COUNT(*) FROM dbo.Acc_LedgerTransaction) > @before SET @receipts += 1;
        FETCH NEXT FROM c2 INTO @id;
    END
    CLOSE c2; DEALLOCATE c2;

    DECLARE c3 CURSOR LOCAL FAST_FORWARD FOR
        SELECT r.RefundId FROM dbo.BillRefund r
        WHERE r.IsActive = 1 AND RTRIM(r.ModuleCode) IN ('LAB', 'OPD')
          AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = RTRIM(r.ModuleCode) + '_REFUND' AND t.ReferenceId = r.RefundId AND t.IsActive = 1);
    OPEN c3; FETCH NEXT FROM c3 INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @before = (SELECT COUNT(*) FROM dbo.Acc_LedgerTransaction);
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'REFUND', @RefId = @id, @UserId = @UserId;
        IF (SELECT COUNT(*) FROM dbo.Acc_LedgerTransaction) > @before SET @refunds += 1;
        FETCH NEXT FROM c3 INTO @id;
    END
    CLOSE c3; DEALLOCATE c3;

    DECLARE c4 CURSOR LOCAL FAST_FORWARD FOR
        SELECT c.CancellationId FROM dbo.BillCancellation c
        WHERE c.IsActive = 1 AND RTRIM(c.ModuleCode) IN ('LAB', 'OPD')
          AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = RTRIM(c.ModuleCode) + '_CANCEL' AND t.ReferenceId = c.ModuleRefId
                          AND t.IsActive = 1 AND t.Narration LIKE '%' + c.CancellationNo + '%');
    OPEN c4; FETCH NEXT FROM c4 INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @before = (SELECT COUNT(*) FROM dbo.Acc_LedgerTransaction);
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'CANCEL', @RefId = @id, @UserId = @UserId;
        IF (SELECT COUNT(*) FROM dbo.Acc_LedgerTransaction) > @before SET @cancels += 1;
        FETCH NEXT FROM c4 INTO @id;
    END
    CLOSE c4; DEALLOCATE c4;

    -- 3. B2B bills posted twice: once as a patient bill (before B2B posting existed) and once as a B2B bill -
    --    the patient bill entry is reversed (Dr LAB Revenue / Cr Patient Receivable), linked to the entry it reverses
    DECLARE c5 CURSOR LOCAL FAST_FORWARD FOR
        SELECT t.TransactionId, t.ReferenceId, t.TotalAmount, t.BranchId, lo.BillNo
        FROM dbo.Acc_LedgerTransaction t
        INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = t.ReferenceId AND ISNULL(lo.IsB2B, 0) = 1
        INNER JOIN dbo.Branchmaster b ON b.BranchID = lo.BranchId AND b.CompanyId = @CompanyId
        WHERE t.ReferenceType = 'LAB_BILL' AND t.IsActive = 1 AND (@BranchId IS NULL OR t.BranchId = @BranchId)
          AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction x WHERE x.ReferenceType = 'B2B_LAB_BILL' AND x.ReferenceId = t.ReferenceId AND x.IsActive = 1)
          AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction r WHERE r.ReversalOfTransactionId = t.TransactionId AND r.IsActive = 1);
    OPEN c5; FETCH NEXT FROM c5 INTO @orig, @id, @amt, @br, @no;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @narr = N'Reversal of duplicate patient-bill entry for B2B LAB Bill ' + @no + N' (it is posted as a B2B bill)';
        SET @when = GETDATE();
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @CN, @TransactionDate = @when, @ReferenceType = N'LAB_BILL_REVERSAL', @ReferenceId = @id,
             @BranchId = @br, @CompanyId = @CompanyId, @TotalAmount = @amt, @Narration = @narr, @DebitLedgerId = @LabRev, @CreditLedgerId = @R,
             @CreatedBy = @UserId, @NewTransactionId = @tx OUTPUT;
        UPDATE dbo.Acc_LedgerTransaction SET ReversalOfTransactionId = @orig WHERE TransactionId = @tx;
        SET @reversed += 1;
        FETCH NEXT FROM c5 INTO @orig, @id, @amt, @br, @no;
    END
    CLOSE c5; DEALLOCATE c5;

    -- 4. revenue entries of bills that no longer exist (the bill row was deleted): reversed
    DECLARE @rt2 NVARCHAR(50);
    DECLARE c6 CURSOR LOCAL FAST_FORWARD FOR
        SELECT t.TransactionId, t.ReferenceId, t.TotalAmount, t.BranchId, t.ReferenceType
        FROM dbo.Acc_LedgerTransaction t
        WHERE t.ReferenceType IN ('LAB_BILL', 'OPD_BILL') AND t.IsActive = 1 AND ISNULL(t.CompanyId, 1) = @CompanyId AND (@BranchId IS NULL OR t.BranchId = @BranchId)
          AND ((t.ReferenceType = 'LAB_BILL' AND NOT EXISTS (SELECT 1 FROM dbo.LabOrder lo WHERE lo.LabOrderId = t.ReferenceId))
            OR (t.ReferenceType = 'OPD_BILL' AND NOT EXISTS (SELECT 1 FROM dbo.PatientOPDService o WHERE o.OPDServiceId = t.ReferenceId)))
          AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction r WHERE r.ReversalOfTransactionId = t.TransactionId AND r.IsActive = 1);
    OPEN c6; FETCH NEXT FROM c6 INTO @orig, @id, @amt, @br, @rt2;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @mod = LEFT(@rt2, 3);
        DECLARE @revType NVARCHAR(50) = @mod + N'_BILL_REVERSAL', @revLedger INT = CASE WHEN @mod = 'LAB' THEN @LabRev ELSE @OpdRev END;
        SET @narr = N'Reversal of the entry of deleted ' + @mod + N' bill #' + CAST(@id AS NVARCHAR(20));
        SET @when = GETDATE();
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @CN, @TransactionDate = @when, @ReferenceType = @revType, @ReferenceId = @id,
             @BranchId = @br, @CompanyId = @CompanyId, @TotalAmount = @amt, @Narration = @narr, @DebitLedgerId = @revLedger, @CreditLedgerId = @R,
             @CreatedBy = @UserId, @NewTransactionId = @tx OUTPUT;
        UPDATE dbo.Acc_LedgerTransaction SET ReversalOfTransactionId = @orig WHERE TransactionId = @tx;
        SET @reversed += 1;
        FETCH NEXT FROM c6 INTO @orig, @id, @amt, @br, @rt2;
    END
    CLOSE c6; DEALLOCATE c6;

    SELECT @bills AS BillsPosted, @receipts AS ReceiptsPosted, @refunds AS RefundsPosted, @cancels AS CancellationsPosted, @reversed AS DuplicatesReversed;
END
GO

-- ── pages, controls and endpoints ───────────────────────────────────────────────────────────────────────────
DECLARE @co INT, @menu INT, @page INT, @ctl INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = (SELECT TOP 1 Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'UTILITY.ACCOUNTS' AND CompanyId = @co);
    IF @menu IS NOT NULL
    BEGIN
        -- Utility > Accounts > Opening Balances
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'UTILITY.ACCOUNTS.OPENING', @Title = N'Opening Balances',
             @Controller = N'AccOpening', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 65, @Icon = N'bi bi-journal-arrow-up me-2',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'View', @Sort_Order = 10, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Enter / change opening balances', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
        SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'AccOpening', @Action = N'Index', @Source = 'SEED';
        SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'EDIT';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'AccOpening', @Action = N'Save', @Source = 'SEED';
    END

    -- Accounts Settings: payment mode -> ledger (EDIT)
    SET @page = (SELECT TOP 1 Page_ID FROM dbo.PageMaster WHERE Page_Code = N'UTILITY.ACCOUNTS.SETTINGS' AND CompanyId = @co);
    IF @page IS NOT NULL
    BEGIN
        SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'EDIT';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'AccSettings', @Action = N'SaveModeLedgers', @Source = 'SEED';
    END

    -- Reports > Accounts: Reconciliation (VIEW) and its repair (REPAIR - no role is granted it here)
    SET @page = (SELECT TOP 1 Page_ID FROM dbo.PageMaster WHERE Page_Code = N'REPORTS.ACCOUNTS' AND CompanyId = @co);
    IF @page IS NOT NULL
    BEGIN
        SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'AccReports', @Action = N'Reconciliation', @Source = 'SEED';
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'REPAIR', @Title = N'Post missing entries / reverse duplicates (Reconciliation)', @Sort_Order = 60, @Control_ID = @ctl OUTPUT;
        SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'REPAIR';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'AccReports', @Action = N'Repair', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2322 applied: Accounts Phase 1 (voucher numbering, financial year, payment mode ledgers, opening balances, reconciliation).';
GO
