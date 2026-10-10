-- ============================================================================
-- Migration: 2226_payment_double_collection_guard.sql
-- Description: Every payment is checked again inside its transaction, so a bill can never be collected twice
--   (double click, retried request, two counters at once, a stale screen):
--   * usp_B2B_DeductWalletPayment (B2B booking, pay from franchise wallet): the bill is locked and must be an active B2B
--     bill of that franchise, not already paid from the wallet, with the amount still due; the wallet row is locked
--     before its balance is checked, so two deductions can never both pass.
--   * usp_B2B_SettleBillsPayment (B2B settlement): the amount must equal the selected bills; each bill must be an active
--     B2B bill of the partner with that much still due (bills locked, paid-so-far read from the receipts); a bank / UPI
--     reference already recorded is refused. A settlement that no longer fits is refused instead of being cut down
--     silently (which still issued a receipt and posted the full amount to the ledger).
--   The rest of both procedures is unchanged. OPD / B2C LAB payments are checked in PaymentService (no SQL change).
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

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

        -- 0. Double-payment guard (2226): the bill is locked, must be an active B2B bill of this franchise, must not be
        --    paid from the wallet already, and the amount cannot be more than what is still due on it
        DECLARE @BillActive BIT, @BillIsB2B BIT, @BillAgentType VARCHAR(10), @BillAgentId INT, @BillTotal DECIMAL(18,2), @GuardMsg NVARCHAR(400);
        SELECT @BillActive = CAST(ISNULL(IsActive, 0) AS BIT), @BillIsB2B = CAST(ISNULL(IsB2B, 0) AS BIT), @BillAgentType = AgentType,
               @BillAgentId = B2BAgentID, @BillTotal = ISNULL(B2BTotal, TotalAmount)
        FROM dbo.LabOrder WITH (UPDLOCK, ROWLOCK) WHERE LabOrderId = @LabOrderId;
        IF @BillActive IS NULL THROW 50010, 'The bill was not found. Nothing was deducted from the wallet.', 1;
        IF @BillActive = 0 THROW 50010, 'This bill has been cancelled. Nothing was deducted from the wallet.', 1;
        IF @BillIsB2B = 0 OR ISNULL(@BillAgentType, '') <> 'F' OR ISNULL(@BillAgentId, 0) <> @FranchiseId
            THROW 50010, 'This bill does not belong to the selected franchise. Nothing was deducted from the wallet.', 1;
        IF @Amount IS NULL OR @Amount <= 0 THROW 50010, 'The wallet deduction amount must be greater than zero.', 1;

        DECLARE @PrevWalletReceipt NVARCHAR(50) = (SELECT TOP 1 ReceiptNo FROM dbo.LabFranchiseWalletTransaction
            WHERE ReferenceType = 'LAB_BILL' AND TransactionType = 'DEBIT' AND ReferenceId = @LabOrderId ORDER BY TransactionId DESC);
        IF @PrevWalletReceipt IS NOT NULL
        BEGIN
            SET @GuardMsg = N'Bill ' + ISNULL(@BillNo, N'') + N' is already paid from the franchise wallet (receipt ' + @PrevWalletReceipt + N'). Nothing was deducted again.';
            THROW 50011, @GuardMsg, 1;
        END

        DECLARE @AlreadyPaid DECIMAL(18,2) = ISNULL((SELECT SUM(pd.PaidAmount) FROM dbo.PaymentDetail pd
            INNER JOIN dbo.PaymentHeader ph WITH (UPDLOCK, HOLDLOCK) ON ph.PaymentHeaderId = pd.PaymentHeaderId
            WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @LabOrderId AND ph.IsActive = 1 AND pd.IsActive = 1), 0);
        IF @Amount > ISNULL(@BillTotal, 0) - @AlreadyPaid + 0.001
        BEGIN
            SET @GuardMsg = N'The wallet deduction (Rs ' + CONVERT(NVARCHAR(30), @Amount) + N') is more than the Rs '
                          + CONVERT(NVARCHAR(30), CASE WHEN ISNULL(@BillTotal, 0) - @AlreadyPaid < 0 THEN 0 ELSE ISNULL(@BillTotal, 0) - @AlreadyPaid END)
                          + N' still due on bill ' + ISNULL(@BillNo, N'') + N'. Nothing was deducted.';
            THROW 50012, @GuardMsg, 1;
        END

        -- 1. Check wallet balance (row locked, so two deductions cannot both pass the check)
        DECLARE @CurrentBalance DECIMAL(18,2) = 0.00;
        SELECT @CurrentBalance = CurrentBalance FROM dbo.LabFranchiseWallet WITH (UPDLOCK, HOLDLOCK) WHERE Franchise_ID = @FranchiseId;

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

        -- 0. Double-payment guard (2226): the amount must match the bills, every bill must be an active B2B bill of this
        --    partner with that much still due (bills are locked, and paid-so-far is read from the receipts), and a bank /
        --    UPI reference cannot be recorded twice. Nothing is written when any check fails.
        DECLARE @Chk TABLE (LabOrderId INT, PayAmount DECIMAL(18,2));
        INSERT INTO @Chk (LabOrderId, PayAmount)
        SELECT CAST(JSON_VALUE(value, '$.LabOrderId') AS INT), CAST(JSON_VALUE(value, '$.PayAmount') AS DECIMAL(18,2))
        FROM OPENJSON(@SelectedBillsJson);
        DECLARE @GuardMsg NVARCHAR(500), @GuardBill NVARCHAR(50), @GuardDue DECIMAL(18,2);

        IF ISNULL(@PaidAmount, 0) <= 0 THROW 50020, 'The settlement amount must be greater than zero.', 1;
        IF EXISTS (SELECT 1 FROM @Chk WHERE PayAmount < 0) THROW 50020, 'A bill amount cannot be negative.', 1;
        IF EXISTS (SELECT LabOrderId FROM @Chk WHERE PayAmount > 0 GROUP BY LabOrderId HAVING COUNT(*) > 1)
            THROW 50020, 'A bill is selected twice in this settlement.', 1;
        IF ABS(ISNULL((SELECT SUM(PayAmount) FROM @Chk WHERE PayAmount > 0), 0) - @PaidAmount) >= 0.01
            THROW 50020, 'The settlement amount does not match the amounts of the selected bills. Reload the bills and try again.', 1;

        IF NULLIF(LTRIM(RTRIM(@TransactionRef)), '') IS NOT NULL
        BEGIN
            DECLARE @UsedOn NVARCHAR(50) = (SELECT TOP 1 ReceiptNo FROM dbo.PaymentDetail
                WHERE IsActive = 1 AND (LTRIM(RTRIM(TransactionRef)) = LTRIM(RTRIM(@TransactionRef)) OR LTRIM(RTRIM(UPIRefNo)) = LTRIM(RTRIM(@TransactionRef))));
            IF @UsedOn IS NOT NULL
            BEGIN
                SET @GuardMsg = N'Reference ' + LTRIM(RTRIM(@TransactionRef)) + N' is already recorded on receipt ' + @UsedOn + N'. The same bank / UPI transaction cannot be settled twice.';
                THROW 50021, @GuardMsg, 1;
            END
        END

        -- lock the bills and their payment headers, then check each one against what its receipts add up to
        DECLARE @Locked INT = (SELECT COUNT(*) FROM dbo.LabOrder lo WITH (UPDLOCK, ROWLOCK) INNER JOIN @Chk c ON c.LabOrderId = lo.LabOrderId);
        DECLARE @LockedPh INT = (SELECT COUNT(*) FROM dbo.PaymentHeader ph WITH (UPDLOCK, HOLDLOCK) INNER JOIN @Chk c ON c.LabOrderId = ph.ModuleRefId
                                 WHERE ph.ModuleCode = 'LAB' AND ph.IsActive = 1);

        SELECT TOP 1 @GuardBill = ISNULL(lo.BillNo, CONVERT(NVARCHAR(20), c.LabOrderId))
        FROM @Chk c LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = c.LabOrderId
        WHERE c.PayAmount > 0 AND (lo.LabOrderId IS NULL OR ISNULL(lo.IsActive, 0) = 0 OR ISNULL(lo.IsB2B, 0) = 0
                                   OR ISNULL(lo.AgentType, '') <> @AgentType OR ISNULL(lo.B2BAgentID, 0) <> @AgentId);
        IF @GuardBill IS NOT NULL
        BEGIN
            SET @GuardMsg = N'Bill ' + @GuardBill + N' is cancelled, missing, or not a bill of this partner. Nothing was settled.';
            THROW 50022, @GuardMsg, 1;
        END

        SELECT TOP 1 @GuardBill = lo.BillNo, @GuardDue = x.Due
        FROM @Chk c
        INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = c.LabOrderId
        CROSS APPLY (SELECT CASE WHEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL((SELECT SUM(pd.PaidAmount) FROM dbo.PaymentDetail pd
                                         INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
                                         WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1 AND pd.IsActive = 1), 0) < 0 THEN 0
                                 ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL((SELECT SUM(pd.PaidAmount) FROM dbo.PaymentDetail pd
                                         INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
                                         WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1 AND pd.IsActive = 1), 0) END AS Due) x
        WHERE c.PayAmount > x.Due + 0.001;
        IF @GuardBill IS NOT NULL
        BEGIN
            SET @GuardMsg = CASE WHEN @GuardDue <= 0
                THEN N'Bill ' + @GuardBill + N' is already fully paid. Nothing was settled - reload the outstanding bills.'
                ELSE N'Bill ' + @GuardBill + N' has only Rs ' + CONVERT(NVARCHAR(30), @GuardDue) + N' due now. Nothing was settled - reload the outstanding bills.' END;
            THROW 50023, @GuardMsg, 1;
        END

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

PRINT 'Script 2226 applied: double-collection guards on B2B wallet deduction and B2B settlement.';
GO
