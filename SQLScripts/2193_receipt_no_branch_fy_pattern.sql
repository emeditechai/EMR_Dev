-- ============================================================================
-- Migration: 2193_receipt_no_branch_fy_pattern.sql
-- Description: Money receipt numbers follow one pattern for every module (OPD, LAB, B2B wallet / settlement and
--   any module added later):  <Branch Code><Financial Year><8-digit serial>   e.g. HO262700000001
--   * Financial year runs April-March: Apr 2026 - Mar 2027 = '2627' (same as bill numbers).
--   * The serial is per branch per financial year, kept in ReceiptSequence (unchanged table, same counters),
--     and starts again at 00000001 every 1 April.
--   * dbo.usp_Receipt_GetNextNo is the only generator; PaymentService (OPD / LAB counter payments) and the
--     B2B procedures below call it. Only the number format changes - payment logic is untouched.
--   * Existing receipts are converted in place, keeping their serial: HO03102026000218 -> HO262700000218.
--     The financial year comes from the date inside the old number. Text that quotes a receipt number
--     (transaction ref, ledger narrations, wallet narrations, activity log) is converted the same way.
--     Every conversion is kept in dbo.ReceiptNoFormatMap (old -> new). Re-running the script is safe.
--   Run after 2192.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Shared generator ──────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Receipt_GetNextNo
    @BranchId   INT,
    @ReceiptNo  NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchCode NVARCHAR(20), @CompanyId INT;
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode))), @CompanyId = CompanyId
    FROM dbo.Branchmaster WHERE BranchId = @BranchId;
    IF @BranchCode IS NULL OR @BranchCode = '' SET @BranchCode = 'BR';

    -- Financial year April-March: the counter key stays '2026-2027' (existing rows), the number shows '2627'
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @FYStart INT = CASE WHEN MONTH(@Today) >= 4 THEN YEAR(@Today) ELSE YEAR(@Today) - 1 END;
    DECLARE @FinancialYear NVARCHAR(10) = CAST(@FYStart AS NVARCHAR(4)) + '-' + CAST(@FYStart + 1 AS NVARCHAR(4));
    DECLARE @FY NVARCHAR(4) = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2) + RIGHT(CAST(@FYStart + 1 AS NVARCHAR(4)), 2);

    DECLARE @NextSeq INT;
    UPDATE dbo.ReceiptSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
    SET @NextSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND FinancialYear = @FinancialYear;

    IF @NextSeq IS NULL
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.ReceiptSequence (BranchId, FinancialYear, LastSeq, CompanyId)
            VALUES (@BranchId, @FinancialYear, 1, ISNULL(@CompanyId, 1));
            SET @NextSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
                UPDATE dbo.ReceiptSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
                SET @NextSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND FinancialYear = @FinancialYear;
            ELSE THROW;
        END CATCH
    END

    SET @ReceiptNo = @BranchCode + @FY + RIGHT('00000000' + CAST(@NextSeq AS NVARCHAR(10)), 8);
END
GO

-- ── 2. Convert existing receipt numbers ──────────────────────────────────────
IF OBJECT_ID('dbo.ReceiptNoFormatMap') IS NULL
    CREATE TABLE dbo.ReceiptNoFormatMap (
        OldReceiptNo NVARCHAR(50) NOT NULL CONSTRAINT PK_ReceiptNoFormatMap PRIMARY KEY,
        NewReceiptNo NVARCHAR(50) NOT NULL,
        ConvertedOn  DATETIME     NOT NULL CONSTRAINT DF_ReceiptNoFormatMap_ConvertedOn DEFAULT GETDATE()
    );
GO

SET XACT_ABORT ON;
BEGIN TRANSACTION;

-- old pattern: <Branch Code><ddMMyyyy><6-digit serial>, branch code matching a branch
;WITH r AS (
    SELECT ReceiptNo FROM dbo.PaymentDetail WHERE ReceiptNo IS NOT NULL
    UNION SELECT ReceiptNo FROM dbo.LabFranchiseWalletTransaction WHERE ReceiptNo IS NOT NULL
    UNION SELECT ReceiptNo FROM dbo.InvoicePayment WHERE ReceiptNo IS NOT NULL
), p AS (
    SELECT ReceiptNo,
           LEFT(ReceiptNo, LEN(ReceiptNo) - 14)             AS Code,
           SUBSTRING(ReceiptNo, LEN(ReceiptNo) - 13, 2)     AS DD,
           SUBSTRING(ReceiptNo, LEN(ReceiptNo) - 11, 2)     AS MM,
           SUBSTRING(ReceiptNo, LEN(ReceiptNo) - 9, 4)      AS YYYY,
           RIGHT(ReceiptNo, 6)                              AS Serial
    FROM r
    WHERE LEN(ReceiptNo) > 14
      AND RIGHT(ReceiptNo, 14) NOT LIKE '%[^0-9]%'
)
INSERT INTO dbo.ReceiptNoFormatMap (OldReceiptNo, NewReceiptNo)
SELECT p.ReceiptNo,
       p.Code
       + RIGHT(CAST(CASE WHEN CAST(p.MM AS INT) >= 4 THEN CAST(p.YYYY AS INT) ELSE CAST(p.YYYY AS INT) - 1 END AS NVARCHAR(4)), 2)
       + RIGHT(CAST(CASE WHEN CAST(p.MM AS INT) >= 4 THEN CAST(p.YYYY AS INT) + 1 ELSE CAST(p.YYYY AS INT) END AS NVARCHAR(4)), 2)
       + '00' + p.Serial
FROM p
WHERE EXISTS (SELECT 1 FROM dbo.Branchmaster b WHERE UPPER(LTRIM(RTRIM(b.BranchCode))) = p.Code)
  AND ISDATE(p.YYYY + '-' + p.MM + '-' + p.DD) = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.ReceiptNoFormatMap m WHERE m.OldReceiptNo = p.ReceiptNo);

-- a new number must not already be in use
IF EXISTS (SELECT NewReceiptNo FROM dbo.ReceiptNoFormatMap GROUP BY NewReceiptNo HAVING COUNT(*) > 1)
   OR EXISTS (SELECT 1 FROM dbo.ReceiptNoFormatMap m JOIN dbo.PaymentDetail pd ON pd.ReceiptNo = m.NewReceiptNo
              WHERE EXISTS (SELECT 1 FROM dbo.PaymentDetail o WHERE o.ReceiptNo = m.OldReceiptNo))
    THROW 50001, 'Receipt number conversion would create duplicate receipt numbers - nothing changed.', 1;

-- receipt number columns
UPDATE pd SET ReceiptNo = m.NewReceiptNo FROM dbo.PaymentDetail pd JOIN dbo.ReceiptNoFormatMap m ON m.OldReceiptNo = pd.ReceiptNo;
UPDATE t  SET ReceiptNo = m.NewReceiptNo FROM dbo.LabFranchiseWalletTransaction t JOIN dbo.ReceiptNoFormatMap m ON m.OldReceiptNo = t.ReceiptNo;
UPDATE ip SET ReceiptNo = m.NewReceiptNo FROM dbo.InvoicePayment ip JOIN dbo.ReceiptNoFormatMap m ON m.OldReceiptNo = ip.ReceiptNo;

-- text that quotes a receipt number
DECLARE @Old NVARCHAR(50), @New NVARCHAR(50);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT OldReceiptNo, NewReceiptNo FROM dbo.ReceiptNoFormatMap;
OPEN cur;
FETCH NEXT FROM cur INTO @Old, @New;
WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @Like NVARCHAR(60) = N'%' + @Old + N'%';
    UPDATE dbo.PaymentDetail                SET TransactionRef = REPLACE(TransactionRef, @Old, @New) WHERE TransactionRef LIKE @Like;
    UPDATE dbo.LabFranchiseWalletTransaction SET Narration      = REPLACE(Narration, @Old, @New)      WHERE Narration LIKE @Like;
    UPDATE dbo.Acc_LedgerTransaction        SET Narration      = REPLACE(Narration, @Old, @New)      WHERE Narration LIKE @Like;
    UPDATE dbo.Acc_LedgerTransactionDetail  SET Narration      = REPLACE(Narration, @Old, @New)      WHERE Narration LIKE @Like;
    UPDATE dbo.AuditLogs                    SET ReferenceNo    = REPLACE(ReferenceNo, @Old, @New)    WHERE ReferenceNo LIKE @Like;
    UPDATE dbo.AuditLogs                    SET Description    = REPLACE(Description, @Old, @New)    WHERE Description LIKE @Like;
    UPDATE dbo.AuditLogs                    SET MetadataJson   = REPLACE(MetadataJson, @Old, @New)   WHERE MetadataJson LIKE @Like;
    FETCH NEXT FROM cur INTO @Old, @New;
END
CLOSE cur; DEALLOCATE cur;

COMMIT TRANSACTION;
GO

-- ── 3. B2B procedures use the shared generator (bodies otherwise unchanged) ──

-- ── 5. Stored Procedure: usp_B2B_DeductWalletPayment ───────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_DeductWalletPayment
    @LabOrderId   INT,
    @FranchiseId  INT,
    @Amount       DECIMAL(18,2),
    @BranchId     INT,
    @UserId       INT,
    @BillNo       NVARCHAR(50),
    @ReceiptNo    NVARCHAR(50) OUTPUT,
    @TokenNo      NVARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Check wallet balance
        DECLARE @CurrentBalance DECIMAL(18,2) = 0.00;
        SELECT @CurrentBalance = CurrentBalance FROM dbo.LabFranchiseWallet WHERE Franchise_ID = @FranchiseId;

        IF @CurrentBalance < @Amount
        BEGIN
            THROW 50001, 'Insufficient franchise wallet balance for deduction.', 1;
        END

        -- 2. Deduct from wallet
        DECLARE @NewBalance DECIMAL(18,2) = @CurrentBalance - @Amount;
        UPDATE dbo.LabFranchiseWallet
        SET CurrentBalance = @NewBalance,
            LastUpdatedDate = GETDATE()
        WHERE Franchise_ID = @FranchiseId;

        -- 3. Generate Receipt Number
        -- Receipt number: <Branch Code><FY><8-digit serial>, e.g. HO262700000001 (shared generator, script 2193)
        EXEC dbo.usp_Receipt_GetNextNo @BranchId = @BranchId, @ReceiptNo = @ReceiptNo OUTPUT;

        -- 4. Record Wallet Transaction
        INSERT INTO dbo.LabFranchiseWalletTransaction
            (Franchise_ID, TransactionType, Amount, BalanceAfter, ReferenceType, ReferenceId, ReceiptNo, Narration, CreatedBy, CreatedDate)
        VALUES
            (@FranchiseId, 'DEBIT', @Amount, @NewBalance, 'LAB_BILL', @LabOrderId, @ReceiptNo, 'Bill payment deducted for LAB Bill ' + @BillNo, @UserId, GETDATE());

        -- 5. Insert or Update PaymentHeader
        DECLARE @PaymentHeaderId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = 'LAB' AND ModuleRefId = @LabOrderId AND IsActive = 1);
        DECLARE @PatientId INT = (SELECT TOP 1 PatientId FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId);

        IF @PaymentHeaderId IS NULL
        BEGIN
            INSERT INTO dbo.PaymentHeader
                (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive)
            VALUES
                ('LAB', @LabOrderId, @BranchId, @PatientId, @Amount, @Amount, @Amount, 0.00, 'P', 'Paid via Franchise Wallet', GETDATE(), @UserId, 1);
            SET @PaymentHeaderId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE dbo.PaymentHeader
            SET TotalPaid = TotalPaid + @Amount,
                BalanceDue = 0.00,
                PaymentStatus = 'P',
                LastModifiedDate = GETDATE(),
                LastModifiedBy = @UserId
            WHERE PaymentHeaderId = @PaymentHeaderId;
        END

        -- 6. Insert PaymentDetail
        DECLARE @WalletMethodId INT = (SELECT TOP 1 PaymentMethodId FROM PaymentMethodMaster WHERE MethodCode = 'WALLET');
        IF @WalletMethodId IS NULL SET @WalletMethodId = 1;

        INSERT INTO dbo.PaymentDetail
            (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo)
        VALUES
            (@PaymentHeaderId, @WalletMethodId, @Amount, 'WALLET-DEBIT-' + @ReceiptNo, GETDATE(), 'Franchise Wallet Auto-Deduction', GETDATE(), @UserId, 1, @ReceiptNo);

        -- 7. Assign Token
        EXEC dbo.usp_LAB_AssignTokenOnPayment @LabOrderId = @LabOrderId, @TokenNo = @TokenNo OUTPUT;

        -- 8. Post Payment Ledger (Dr Franchise Wallet (Advance), Cr Franchise Receivable)
        DECLARE @VoucherTypeId INT = (SELECT TOP 1 VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
        IF @VoucherTypeId IS NULL
        BEGIN
            INSERT INTO Acc_VoucherType (VoucherTypeName, Prefix, IsActive) VALUES ('Receipt', 'RCT', 1);
            SET @VoucherTypeId = SCOPE_IDENTITY();
        END

        DECLARE @DebitLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Franchise Wallet (Advance)');
        DECLARE @CreditLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Franchise Receivable');
        DECLARE @NewTxId BIGINT;
        DECLARE @TxDate DATETIME = GETDATE();

        DECLARE @WalletNarration NVARCHAR(500) = 'Wallet payment settlement for LAB Bill ' + @BillNo + ' (Receipt: ' + @ReceiptNo + ')';

        IF @DebitLedgerId IS NOT NULL AND @CreditLedgerId IS NOT NULL
        BEGIN
            EXEC dbo.usp_Ledger_PostEntry
                @VoucherTypeId   = @VoucherTypeId,
                @TransactionDate = @TxDate,
                @ReferenceType   = 'B2B_WALLET_PAY',
                @ReferenceId     = @LabOrderId,
                @BranchId        = @BranchId,
                @CompanyId       = 1,
                @TotalAmount     = @Amount,
                @Narration       = @WalletNarration,
                @DebitLedgerId   = @DebitLedgerId,
                @CreditLedgerId  = @CreditLedgerId,
                @CreatedBy       = @UserId,
                @NewTransactionId = @NewTxId OUTPUT;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── 6. Stored Procedure: usp_B2B_FranchiseWallet_TopUp ─────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_FranchiseWallet_TopUp
    @FranchiseId      INT,
    @Amount           DECIMAL(18,2),
    @PaymentMethodId  INT,
    @TransactionRef   NVARCHAR(100) = NULL,
    @BranchId         INT = 1,
    @UserId           INT = 1,
    @Narration        NVARCHAR(500) = NULL,
    @ReceiptNo        NVARCHAR(50) OUTPUT,
    @NewBalance       DECIMAL(18,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Amount <= 0
    BEGIN
        THROW 50002, 'Top-up amount must be greater than zero.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Ensure wallet exists
        IF NOT EXISTS (SELECT 1 FROM dbo.LabFranchiseWallet WHERE Franchise_ID = @FranchiseId)
        BEGIN
            INSERT INTO dbo.LabFranchiseWallet (Franchise_ID, CurrentBalance, LastUpdatedDate)
            VALUES (@FranchiseId, 0.00, GETDATE());
        END

        -- Update balance
        UPDATE dbo.LabFranchiseWallet
        SET CurrentBalance = CurrentBalance + @Amount,
            LastUpdatedDate = GETDATE()
        WHERE Franchise_ID = @FranchiseId;

        SELECT @NewBalance = CurrentBalance FROM dbo.LabFranchiseWallet WHERE Franchise_ID = @FranchiseId;

        -- Generate Receipt No
        -- Receipt number: <Branch Code><FY><8-digit serial>, e.g. HO262700000001 (shared generator, script 2193)
        EXEC dbo.usp_Receipt_GetNextNo @BranchId = @BranchId, @ReceiptNo = @ReceiptNo OUTPUT;

        -- Record transaction
        INSERT INTO dbo.LabFranchiseWalletTransaction
            (Franchise_ID, TransactionType, Amount, BalanceAfter, ReferenceType, ReferenceId, ReceiptNo, Narration, CreatedBy, CreatedDate)
        VALUES
            (@FranchiseId, 'CREDIT', @Amount, @NewBalance, 'TOPUP', NULL, @ReceiptNo, ISNULL(@Narration, 'Wallet balance recharged/top-up'), @UserId, GETDATE());

        -- Ledger: Dr Bank Account (or Cash), Cr Franchise Wallet (Advance Deposit)
        DECLARE @VoucherTypeId INT = (SELECT TOP 1 VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
        DECLARE @DebitLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Bank Account');
        IF @DebitLedgerId IS NULL SET @DebitLedgerId = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Cash Account');
        DECLARE @CreditLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Franchise Wallet (Advance)');
        DECLARE @NewTxId BIGINT;
        DECLARE @TxDate DATETIME = GETDATE();

        DECLARE @TopUpNarration NVARCHAR(500) = 'Franchise Wallet Top-Up #' + CAST(@FranchiseId AS NVARCHAR(20)) + ' (Receipt: ' + @ReceiptNo + ')';

        IF @DebitLedgerId IS NOT NULL AND @CreditLedgerId IS NOT NULL AND @VoucherTypeId IS NOT NULL
        BEGIN
            EXEC dbo.usp_Ledger_PostEntry
                @VoucherTypeId   = @VoucherTypeId,
                @TransactionDate = @TxDate,
                @ReferenceType   = 'B2B_WALLET_TOPUP',
                @ReferenceId     = @FranchiseId,
                @BranchId        = @BranchId,
                @CompanyId       = 1,
                @TotalAmount     = @Amount,
                @Narration       = @TopUpNarration,
                @DebitLedgerId   = @DebitLedgerId,
                @CreditLedgerId  = @CreditLedgerId,
                @CreatedBy       = @UserId,
                @NewTransactionId = @NewTxId OUTPUT;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_B2B_SettleBillsPayment
    @AgentType        VARCHAR(10), -- 'F' or 'C'
    @AgentId          INT,
    @BranchId         INT,
    @PaymentMethodId  INT,
    @PaidAmount       DECIMAL(18,2),
    @TransactionRef   NVARCHAR(100) = NULL,
    @BankName         NVARCHAR(100) = NULL,
    @ChequeNo         NVARCHAR(50) = NULL,
    @ChequeDate       DATETIME2 = NULL,
    @PaymentDate      DATETIME2 = NULL,
    @SelectedBillsJson NVARCHAR(MAX), -- JSON array: [{"LabOrderId": 1, "PayAmount": 150.00}, ...]
    @Notes            NVARCHAR(500) = NULL,
    @UserId           INT = 1,
    @BatchReceiptNo   NVARCHAR(50) OUTPUT,
    @SettledBillCount INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @PaymentDate IS NULL SET @PaymentDate = GETDATE();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Generate Batch Receipt Number
        -- Receipt number: <Branch Code><FY><8-digit serial>, e.g. HO262700000001 (shared generator, script 2193)
        EXEC dbo.usp_Receipt_GetNextNo @BranchId = @BranchId, @ReceiptNo = @BatchReceiptNo OUTPUT;

        -- Parse JSON array of bills
        DECLARE @BillsTable TABLE (LabOrderId INT, PayAmount DECIMAL(18,2));
        INSERT INTO @BillsTable (LabOrderId, PayAmount)
        SELECT 
            CAST(JSON_VALUE(value, '$.LabOrderId') AS INT),
            CAST(JSON_VALUE(value, '$.PayAmount') AS DECIMAL(18,2))
        FROM OPENJSON(@SelectedBillsJson);

        SET @SettledBillCount = (SELECT COUNT(1) FROM @BillsTable WHERE PayAmount > 0);

        -- 2. Process each bill
        DECLARE @CurOrderId INT, @CurPayAmt DECIMAL(18,2);
        DECLARE bill_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT LabOrderId, PayAmount FROM @BillsTable WHERE PayAmount > 0;

        OPEN bill_cursor;
        FETCH NEXT FROM bill_cursor INTO @CurOrderId, @CurPayAmt;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @PhId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = 'LAB' AND ModuleRefId = @CurOrderId AND IsActive = 1);
            DECLARE @OrderBillTotal DECIMAL(18,2) = (SELECT TOP 1 ISNULL(B2BTotal, TotalAmount) FROM dbo.LabOrder WHERE LabOrderId = @CurOrderId);
            DECLARE @PatientId INT = (SELECT TOP 1 PatientId FROM dbo.LabOrder WHERE LabOrderId = @CurOrderId);
            DECLARE @PaidSoFar DECIMAL(18,2) = (SELECT TOP 1 ISNULL(TotalPaid, 0.00) FROM dbo.PaymentHeader WHERE PaymentHeaderId = @PhId);
            DECLARE @RemainingB2BDue DECIMAL(18,2) = CASE WHEN @OrderBillTotal - @PaidSoFar <= 0 THEN 0.00 ELSE @OrderBillTotal - @PaidSoFar END;

            -- Validation / Capping: A bill payment can never exceed its remaining B2B payable amount
            IF @CurPayAmt > @RemainingB2BDue
                SET @CurPayAmt = @RemainingB2BDue;

            IF @CurPayAmt > 0
            BEGIN
                IF @PhId IS NULL
                BEGIN
                    INSERT INTO dbo.PaymentHeader
                        (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive)
                    VALUES
                        ('LAB', @CurOrderId, @BranchId, @PatientId, @OrderBillTotal, @OrderBillTotal, @CurPayAmt, 
                         CASE WHEN @OrderBillTotal - @CurPayAmt <= 0 THEN 0.00 ELSE @OrderBillTotal - @CurPayAmt END, 
                         CASE WHEN @CurPayAmt >= @OrderBillTotal THEN 'P' ELSE 'R' END, @Notes, GETDATE(), @UserId, 1);
                    SET @PhId = SCOPE_IDENTITY();
                END
                ELSE
                BEGIN
                    UPDATE dbo.PaymentHeader
                    SET TotalPaid = TotalPaid + @CurPayAmt,
                        BalanceDue = CASE WHEN @OrderBillTotal - (TotalPaid + @CurPayAmt) <= 0 THEN 0.00 ELSE @OrderBillTotal - (TotalPaid + @CurPayAmt) END,
                        PaymentStatus = CASE WHEN (TotalPaid + @CurPayAmt) >= @OrderBillTotal THEN 'P' ELSE 'R' END,
                        LastModifiedDate = GETDATE(),
                        LastModifiedBy = @UserId
                    WHERE PaymentHeaderId = @PhId;
                END

                -- Insert PaymentDetail
                INSERT INTO dbo.PaymentDetail
                    (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, BankName, ChequeNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo)
                VALUES
                    (@PhId, @PaymentMethodId, @CurPayAmt, @TransactionRef, @BankName, @ChequeNo, @PaymentDate, @Notes, GETDATE(), @UserId, 1, @BatchReceiptNo);

                -- Assign Token if bill is fully paid
                DECLARE @CurBal DECIMAL(18,2) = (SELECT BalanceDue FROM dbo.PaymentHeader WHERE PaymentHeaderId = @PhId);
                IF @CurBal <= 0
                BEGIN
                    DECLARE @AssignedToken NVARCHAR(20);
                    EXEC dbo.usp_LAB_AssignTokenOnPayment @LabOrderId = @CurOrderId, @TokenNo = @AssignedToken OUTPUT;
                END
            END

            FETCH NEXT FROM bill_cursor INTO @CurOrderId, @CurPayAmt;
        END

        CLOSE bill_cursor;
        DEALLOCATE bill_cursor;

        -- 3. Update any affected B2B Invoices (Strictly Capped to NetAmount)
        UPDATE bi
        SET PaidAmount = CASE 
                WHEN ISNULL(c.CappedPaid, 0) >= bi.NetAmount THEN bi.NetAmount 
                ELSE ISNULL(c.CappedPaid, 0) 
            END,
            BalanceAmount = CASE 
                WHEN bi.NetAmount - ISNULL(c.CappedPaid, 0) <= 0 THEN 0.00 
                ELSE bi.NetAmount - ISNULL(c.CappedPaid, 0) 
            END,
            Status = CASE 
                WHEN bi.NetAmount - ISNULL(c.CappedPaid, 0) <= 0 THEN 'P'
                WHEN ISNULL(c.CappedPaid, 0) > 0 THEN 'R'
                ELSE 'U'
            END
        FROM dbo.B2BInvoice bi
        OUTER APPLY (
            SELECT SUM(
                CASE 
                    WHEN ISNULL(ph.TotalPaid, 0) >= bii.Amount THEN bii.Amount 
                    ELSE ISNULL(ph.TotalPaid, 0) 
                END
            ) AS CappedPaid
            FROM dbo.B2BInvoiceItem bii
            LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = bii.LabOrderId AND ph.IsActive = 1
            WHERE bii.InvoiceId = bi.InvoiceId
        ) c
        WHERE bi.InvoiceId IN (
            SELECT DISTINCT bii.InvoiceId 
            FROM dbo.B2BInvoiceItem bii
            INNER JOIN @BillsTable bt ON bt.LabOrderId = bii.LabOrderId
        );

        -- 4. Post Consolidated Ledger Entry
        -- Dr: Bank Account / Cash Account
        -- Cr: Franchise Receivable / Corporate Receivable
        DECLARE @VoucherTypeId INT = (SELECT TOP 1 VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
        IF @VoucherTypeId IS NULL
        BEGIN
            INSERT INTO Acc_VoucherType (VoucherTypeName, Prefix, IsActive) VALUES ('Receipt', 'RCT', 1);
            SET @VoucherTypeId = SCOPE_IDENTITY();
        END

        DECLARE @DebitLedgerName NVARCHAR(100) = 'Bank Account';
        IF EXISTS (SELECT 1 FROM PaymentMethodMaster WHERE PaymentMethodId = @PaymentMethodId AND (MethodCode = 'CASH' OR MethodName = 'Cash'))
            SET @DebitLedgerName = 'Cash Account';

        DECLARE @DebitLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = @DebitLedgerName);
        IF @DebitLedgerId IS NULL
        BEGIN
            DECLARE @AssetGrp INT = (SELECT TOP 1 LedgerGroupId FROM Acc_LedgerGroup WHERE GroupName = 'Current Assets' OR GroupType = 'Asset');
            INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
            VALUES (@DebitLedgerName, @AssetGrp, 0, 'Dr', 1, GETDATE());
            SET @DebitLedgerId = SCOPE_IDENTITY();
        END

        DECLARE @CreditLedgerName NVARCHAR(100) = CASE WHEN @AgentType = 'C' THEN 'Corporate Receivable' ELSE 'Franchise Receivable' END;
        DECLARE @CreditLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = @CreditLedgerName);

        DECLARE @PartnerTitle NVARCHAR(100) = CASE 
            WHEN @AgentType = 'F' THEN (SELECT Franchise_Name FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @AgentId)
            WHEN @AgentType = 'C' THEN (SELECT Corporate_Name FROM dbo.CorporateMaster WHERE Corporate_ID = @AgentId)
            ELSE 'B2B Partner'
        END;

        DECLARE @SettleNarration NVARCHAR(500) = 'B2B settlement payment for ' + @PartnerTitle + ' (' + CAST(@SettledBillCount AS NVARCHAR(10)) + ' bills, Receipt: ' + @BatchReceiptNo + ')';
        DECLARE @NewTxId BIGINT;
        IF @DebitLedgerId IS NOT NULL AND @CreditLedgerId IS NOT NULL AND @VoucherTypeId IS NOT NULL
        BEGIN
            EXEC dbo.usp_Ledger_PostEntry
                @VoucherTypeId   = @VoucherTypeId,
                @TransactionDate = @PaymentDate,
                @ReferenceType   = 'B2B_SETTLEMENT',
                @ReferenceId     = @AgentId,
                @BranchId        = @BranchId,
                @CompanyId       = 1,
                @TotalAmount     = @PaidAmount,
                @Narration       = @SettleNarration,
                @DebitLedgerId   = @DebitLedgerId,
                @CreditLedgerId  = @CreditLedgerId,
                @CreatedBy       = @UserId,
                @NewTransactionId = @NewTxId OUTPUT;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
