-- ============================================================================
-- Migration: 2232_ledger_receipts_discounts_refunds.sql
-- Description: Complete double entry for LAB (B2C / B2B spot payment) and OPD bills. Until now only the bill
--   (Dr Patient Receivable / Cr Revenue, at gross) and a cancellation (Dr Revenue / Cr Patient Receivable) were posted;
--   money received, discounts, round-off and refunds were not, so Patient Receivable never came down.
--   usp_Ledger_PostBillMoney posts, idempotently (one entry per receipt / refund; discount and round-off brought in
--   line with the bill, so a later change - discount at due collection, a full cancellation - posts only the difference):
--     RECEIPT  (PaymentDetailId)  Dr Cash Account (Cash) / Bank Account (other modes)   Cr Patient Receivable
--                                 (a B2B bill: Cr Franchise / Corporate Receivable)
--     ADJUST   (PaymentHeaderId)  discount:  Dr Discount Allowed  Cr Patient Receivable
--                                 round-off: + Dr Patient Receivable Cr Round Off / - the other way
--     REFUND   (RefundId)         Dr Patient Receivable (B2B: partner receivable)  Cr Cash Account / Bank Account
--   With the bill and cancellation entries, a bill's receivable = bill - discount +/- round-off - cancelled
--   - received + refunded = what is still due.
--     CANCEL   (CancellationId)   Dr LAB / OPD Revenue  Cr the bill's receivable (gross of the cancelled lines; moved here
--                                 from EMR.Web CancellationService so it is posted before the discount is re-checked)
--   The discount still standing is worked out from what is posted (bill - cancellations + round-off - bill now).
--   Called by PaymentService (receipts, discount), usp_Bill_Refund (refunds) and usp_Bill_Cancel (cancellation +
--   discount re-check); B2B wallet payments and B2B settlements keep their own entries and are not posted again.
--   Backfill: bills never posted, then every past receipt / discount / round-off / refund (dated as they happened).
--   Safe to re-run (nothing is posted twice).
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── ledgers ─────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Indirect Expenses')
    INSERT INTO dbo.Acc_LedgerGroup (GroupName, GroupType) VALUES ('Indirect Expenses', 'Expense');
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Indirect Income')
    INSERT INTO dbo.Acc_LedgerGroup (GroupName, GroupType) VALUES ('Indirect Income', 'Income');
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Discount Allowed')
    INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
    SELECT 'Discount Allowed', LedgerGroupId, 0, 'Dr', 1, GETDATE() FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Indirect Expenses';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Round Off')
    INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
    SELECT 'Round Off', LedgerGroupId, 0, 'Cr', 1, GETDATE() FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Indirect Income';
GO

-- ── the posting procedure ───────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ledger_PostBillMoney
    @Kind     VARCHAR(10),          -- RECEIPT | ADJUST | REFUND | CANCEL
    @RefId    INT,                  -- PaymentDetailId | PaymentHeaderId | RefundId | CancellationId
    @UserId   INT = 1,
    @TxDate   DATETIME = NULL       -- default: when it happened (receipt / refund) or now (adjust)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Receivable INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable');
    DECLARE @Cash INT       = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Cash Account');
    DECLARE @Bank INT       = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Bank Account');
    DECLARE @Disc INT       = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Discount Allowed');
    DECLARE @RoundOff INT   = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Round Off');
    DECLARE @Receipt INT    = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
    DECLARE @Journal INT    = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Credit Note');
    IF @Receivable IS NULL OR @Cash IS NULL OR @Bank IS NULL OR @Receipt IS NULL RETURN;

    DECLARE @Module VARCHAR(5), @ModuleRefId INT, @HeaderId INT, @BranchId INT, @IsB2B BIT, @AgentType VARCHAR(5),
            @BillNo NVARCHAR(60), @Party INT, @NewId BIGINT, @Amt DECIMAL(18,2), @RefType NVARCHAR(50), @Narr NVARCHAR(500),
            @When DATETIME, @Dr INT, @Cr INT;

    IF @Kind = 'RECEIPT'
    BEGIN
        DECLARE @MethodCode NVARCHAR(30), @Ref NVARCHAR(200), @ReceiptNo NVARCHAR(50);
        SELECT @HeaderId = ph.PaymentHeaderId, @Module = RTRIM(ph.ModuleCode), @ModuleRefId = ph.ModuleRefId, @BranchId = ph.BranchId,
               @Amt = pd.PaidAmount, @When = COALESCE(pd.PaymentDate, pd.CreatedDate), @MethodCode = UPPER(pm.MethodCode),
               @Ref = pd.TransactionRef, @ReceiptNo = pd.ReceiptNo
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE pd.PaymentDetailId = @RefId AND pd.IsActive = 1 AND pd.PaidAmount > 0;
        IF @HeaderId IS NULL OR @Module NOT IN ('LAB', 'OPD') RETURN;
        IF ISNULL(@Ref, '') LIKE 'WALLET-DEBIT-%' RETURN;                     -- franchise wallet: posted as B2B_WALLET_PAY
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t                  -- B2B settlement: posted as B2B_SETTLEMENT
                   WHERE t.ReferenceType = 'B2B_SETTLEMENT' AND t.Narration LIKE '%Receipt: ' + @ReceiptNo + ')%') RETURN;
        SET @RefType = @Module + '_RECEIPT';
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @RefType AND ReferenceId = @RefId AND IsActive = 1) RETURN;
    END
    ELSE IF @Kind = 'REFUND'
    BEGIN
        DECLARE @Mode NVARCHAR(50);
        SELECT @Module = RTRIM(r.ModuleCode), @ModuleRefId = r.ModuleRefId, @Amt = r.RefundAmount, @When = r.RefundDate, @Mode = UPPER(LTRIM(RTRIM(r.RefundMode)))
        FROM dbo.BillRefund r WHERE r.RefundId = @RefId AND r.IsActive = 1;
        IF @Module IS NULL OR @Module NOT IN ('LAB', 'OPD') OR ISNULL(@Amt, 0) <= 0 RETURN;
        SELECT @HeaderId = PaymentHeaderId, @BranchId = BranchId FROM dbo.PaymentHeader WHERE RTRIM(ModuleCode) = @Module AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        SET @RefType = @Module + '_REFUND';
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @RefType AND ReferenceId = @RefId AND IsActive = 1) RETURN;
        SET @MethodCode = CASE WHEN @Mode = 'CASH' THEN 'CASH' ELSE 'BANK' END;
    END
    ELSE IF @Kind = 'CANCEL'
    BEGIN
        DECLARE @CnNo NVARCHAR(50);
        SELECT @Module = RTRIM(c.ModuleCode), @ModuleRefId = c.ModuleRefId, @Amt = c.CancelledAmount, @When = c.CancellationDate, @CnNo = c.CancellationNo
        FROM dbo.BillCancellation c WHERE c.CancellationId = @RefId AND c.IsActive = 1;
        IF @Module IS NULL OR @Module NOT IN ('LAB', 'OPD') OR ISNULL(@Amt, 0) <= 0 RETURN;
        SET @RefType = @Module + '_CANCEL';
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @RefType AND ReferenceId = @ModuleRefId AND IsActive = 1
                   AND Narration LIKE '%' + @CnNo + '%') RETURN;
        SELECT @BranchId = BranchId FROM dbo.PaymentHeader WHERE RTRIM(ModuleCode) = @Module AND ModuleRefId = @ModuleRefId AND IsActive = 1;
    END
    ELSE IF @Kind = 'ADJUST'
    BEGIN
        SELECT @HeaderId = PaymentHeaderId, @Module = RTRIM(ModuleCode), @ModuleRefId = ModuleRefId, @BranchId = BranchId
        FROM dbo.PaymentHeader WHERE PaymentHeaderId = @RefId;
        IF @HeaderId IS NULL OR @Module NOT IN ('LAB', 'OPD') RETURN;
    END
    ELSE RETURN;

    -- whose receivable: the patient's, or the B2B partner's
    IF @Module = 'LAB'
        SELECT @IsB2B = CAST(ISNULL(IsB2B, 0) AS BIT), @AgentType = AgentType, @BillNo = BillNo FROM dbo.LabOrder WHERE LabOrderId = @ModuleRefId;
    ELSE
        SELECT @IsB2B = 0, @BillNo = OPDBillNo FROM dbo.PatientOPDService WHERE OPDServiceId = @ModuleRefId;
    SET @Party = @Receivable;
    IF @IsB2B = 1
        SET @Party = COALESCE((SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster
                               WHERE LedgerName = CASE WHEN @AgentType = 'C' THEN 'Corporate Receivable' ELSE 'Franchise Receivable' END), @Receivable);
    SET @BranchId = ISNULL(@BranchId, 1);
    SET @BillNo = ISNULL(@BillNo, CONVERT(NVARCHAR(20), @ModuleRefId));

    IF @Kind = 'RECEIPT'
    BEGIN
        SET @Dr = CASE WHEN @MethodCode = 'CASH' THEN @Cash ELSE @Bank END;
        SET @Narr = N'Payment received on ' + @Module + N' Bill ' + @BillNo + N' (Receipt: ' + ISNULL(@ReceiptNo, '-') + N')';
        SET @When = ISNULL(@TxDate, @When);
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Party,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        RETURN;
    END

    IF @Kind = 'CANCEL'
    BEGIN
        -- Dr the revenue booked for the bill / Cr the receivable it was booked to (the gross of the cancelled lines)
        DECLARE @Revenue INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = CASE WHEN @Module = 'LAB' THEN 'LAB Revenue' ELSE 'OPD Revenue' END);
        IF @Revenue IS NULL OR @Journal IS NULL RETURN;
        SET @Narr = N'Cancellation reversal for ' + @Module + N' Bill ' + @BillNo + N' [' + @CnNo + N']';
        SET @When = ISNULL(@TxDate, @When);
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Journal, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @ModuleRefId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Revenue, @CreditLedgerId = @Party,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        RETURN;
    END

    IF @Kind = 'REFUND'
    BEGIN
        SET @Cr = CASE WHEN @MethodCode = 'CASH' THEN @Cash ELSE @Bank END;
        SET @Narr = N'Refund on ' + @Module + N' Bill ' + @BillNo + N' (Refund #' + CONVERT(NVARCHAR(20), @RefId) + N')';
        SET @When = ISNULL(@TxDate, @When);
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Party, @CreditLedgerId = @Cr,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        RETURN;
    END

    -- ADJUST: B2B bills are posted at their B2B total by usp_B2B_PostBillLedger (no patient discount / round-off)
    IF @IsB2B = 1 OR @Disc IS NULL OR @RoundOff IS NULL OR @Journal IS NULL RETURN;
    DECLARE @TargetDisc DECIMAL(18,2), @TargetRound DECIMAL(18,2), @PostedDisc DECIMAL(18,2), @PostedRound DECIMAL(18,2), @Diff DECIMAL(18,2);
    -- the discount still standing on the bill, from what is posted: bill - cancellations + round-off - bill now
    -- (a cancellation takes its share of the discount with it), so the receivable always equals what is due
    DECLARE @NetNow DECIMAL(18,2), @BillPosted DECIMAL(18,2), @CancelPosted DECIMAL(18,2);
    SELECT @NetNow = ISNULL(NetAmount, 0), @TargetRound = ISNULL(RoundOffAmount, 0), @When = ISNULL(@TxDate, GETDATE())
    FROM dbo.PaymentHeader WHERE PaymentHeaderId = @HeaderId;
    SELECT @BillPosted = ISNULL(SUM(TotalAmount), 0) FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @Module + '_BILL' AND ReferenceId = @ModuleRefId AND IsActive = 1;
    SELECT @CancelPosted = ISNULL(SUM(TotalAmount), 0) FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @Module + '_CANCEL' AND ReferenceId = @ModuleRefId AND IsActive = 1;
    IF @BillPosted <= 0 RETURN;                       -- bill never posted: nothing to adjust against
    SET @TargetDisc = @BillPosted - @CancelPosted + @TargetRound - @NetNow;

    SELECT @PostedDisc = ISNULL(SUM(d.DebitAmount - d.CreditAmount), 0)
    FROM dbo.Acc_LedgerTransaction t INNER JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId AND d.LedgerId = @Disc
    WHERE t.ReferenceType = @Module + '_DISCOUNT' AND t.ReferenceId = @HeaderId AND t.IsActive = 1;
    SET @Diff = @TargetDisc - @PostedDisc;
    IF ABS(@Diff) >= 0.01
    BEGIN
        SET @RefType = @Module + '_DISCOUNT';
        SET @Narr = N'Discount on ' + @Module + N' Bill ' + @BillNo + CASE WHEN @Diff < 0 THEN N' (reversed / reduced)' ELSE N'' END;
        SET @Amt = ABS(@Diff);
        SET @Dr = CASE WHEN @Diff > 0 THEN @Disc ELSE @Receivable END;
        SET @Cr = CASE WHEN @Diff > 0 THEN @Receivable ELSE @Disc END;
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Journal, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @HeaderId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Cr,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
    END

    -- round-off raises (+) or lowers (-) what the patient owes
    SELECT @PostedRound = ISNULL(SUM(d.CreditAmount - d.DebitAmount), 0)
    FROM dbo.Acc_LedgerTransaction t INNER JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId AND d.LedgerId = @RoundOff
    WHERE t.ReferenceType = @Module + '_ROUNDOFF' AND t.ReferenceId = @HeaderId AND t.IsActive = 1;
    SET @Diff = @TargetRound - @PostedRound;
    IF ABS(@Diff) >= 0.01
    BEGIN
        SET @RefType = @Module + '_ROUNDOFF';
        SET @Narr = N'Round-off on ' + @Module + N' Bill ' + @BillNo;
        SET @Amt = ABS(@Diff);
        SET @Dr = CASE WHEN @Diff > 0 THEN @Receivable ELSE @RoundOff END;
        SET @Cr = CASE WHEN @Diff > 0 THEN @RoundOff ELSE @Receivable END;
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Journal, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @HeaderId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Cr,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Bill_Refund
    @ModuleCode    CHAR(3),
    @ModuleRefId   INT,
    @CancellationId INT,
    @RefundAmount  DECIMAL(10,2),
    @RefundMode    NVARCHAR(50),
    @TransactionRef NVARCHAR(200),
    @Notes         NVARCHAR(500),
    @UserId        INT,
    @RefundId      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Validate cancellation exists for this bill
        IF NOT EXISTS (
            SELECT 1 FROM dbo.BillCancellation 
            WHERE CancellationId = @CancellationId 
              AND ModuleCode = @ModuleCode 
              AND ModuleRefId = @ModuleRefId 
              AND IsActive = 1
        )
            THROW 50010, 'No valid cancellation found. Please cancel the bill first.', 1;

        -- 2231: a refund gives back only what the patient paid over the bill as it stands now:
        --   refundable = (receipts - refunds already given) - bill amount after cancellations   (never negative)
        -- and never more than this cancellation's own (net) amount less what was already refunded against it.
        -- The bill's payment row is locked, so two refunds cannot both pass the check.
        IF ISNULL(@RefundAmount, 0) <= 0
            THROW 50013, 'Refund amount must be greater than zero.', 1;

        DECLARE @Net DECIMAL(18,2), @Receipts DECIMAL(18,2), @AlreadyRefunded DECIMAL(18,2), @Msg NVARCHAR(400);
        SELECT @Net = ISNULL(ph.NetAmount, 0),
               @Receipts = ISNULL((SELECT SUM(d.PaidAmount) FROM dbo.PaymentDetail d WHERE d.PaymentHeaderId = ph.PaymentHeaderId AND d.IsActive = 1), 0)
        FROM dbo.PaymentHeader ph WITH (UPDLOCK, HOLDLOCK)
        WHERE ph.ModuleCode = @ModuleCode AND ph.ModuleRefId = @ModuleRefId AND ph.IsActive = 1;
        SELECT @AlreadyRefunded = ISNULL(SUM(RefundAmount), 0)
        FROM dbo.BillRefund
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        DECLARE @Refundable DECIMAL(18,2) = ISNULL(@Receipts, 0) - @AlreadyRefunded - ISNULL(@Net, 0);
        IF @Refundable < 0 SET @Refundable = 0;
        IF @RefundAmount > @Refundable + 0.001
        BEGIN
            SET @Msg = N'Refund amount is more than the refundable Rs ' + CONVERT(NVARCHAR(30), @Refundable)
                     + N' (received Rs ' + CONVERT(NVARCHAR(30), ISNULL(@Receipts, 0) - @AlreadyRefunded)
                     + N' against a bill of Rs ' + CONVERT(NVARCHAR(30), ISNULL(@Net, 0)) + N').';
            THROW 50011, @Msg, 1;
        END

        DECLARE @CancelledAmount DECIMAL(18,2) = 0, @RefundedOnThis DECIMAL(18,2) = 0;
        SELECT @CancelledAmount = ISNULL(CancelledAmount, 0) - ISNULL(DiscountAdjusted, 0)
        FROM dbo.BillCancellation
        WHERE CancellationId = @CancellationId AND ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        SELECT @RefundedOnThis = ISNULL(SUM(RefundAmount), 0) FROM dbo.BillRefund WHERE CancellationId = @CancellationId AND IsActive = 1;
        IF @RefundedOnThis + @RefundAmount > @CancelledAmount + 0.001
            THROW 50012, 'Refund amount exceeds what is left of this cancellation.', 1;

        -- Insert BillRefund
        INSERT INTO dbo.BillRefund 
            (CancellationId, ModuleCode, ModuleRefId, RefundAmount, RefundMode, RefundDate, TransactionRef, Notes, Status, CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@CancellationId, @ModuleCode, @ModuleRefId, @RefundAmount, @RefundMode, GETDATE(), @TransactionRef, @Notes, 'P', @UserId, GETDATE(), 1);

        SET @RefundId = SCOPE_IDENTITY();

        -- 2232: Dr Patient Receivable / Cr Cash or Bank
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'REFUND', @RefId = @RefundId, @UserId = @UserId;

        -- Reduce TotalPaid in PaymentHeader
        UPDATE dbo.PaymentHeader
        SET TotalPaid = TotalPaid - @RefundAmount,
            -- 2230: a refund gives back money the patient paid over the (reduced) bill, so what is due stays
            -- "bill - what is kept", never "old balance + refund"
            BalanceDue = CASE WHEN NetAmount - (TotalPaid - @RefundAmount) > 0 THEN NetAmount - (TotalPaid - @RefundAmount) ELSE 0 END,
            PaymentStatus = CASE WHEN NetAmount - (TotalPaid - @RefundAmount) > 0
                                 THEN CASE WHEN TotalPaid - @RefundAmount > 0 THEN 'R' ELSE 'U' END ELSE 'P' END,
            LastModifiedDate = GETDATE(),
            LastModifiedBy   = @UserId
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Bill_Cancel
    @ModuleCode          CHAR(3),
    @ModuleRefId         INT,
    @BranchId            INT,
    @LineItemsJson       NVARCHAR(MAX),
    @Reason              NVARCHAR(500),
    @DiscountAdjusted    DECIMAL(10,2),
    @UserId              INT,
    @CancellationId      INT OUTPUT,
    @CancellationNo      NVARCHAR(50) OUTPUT,
    @AcknowledgeLabWarnings BIT = 0      -- LAB: user confirmed that collected samples / draft results will be discarded
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate cancellation number
        EXEC dbo.usp_Bill_GetNextCancellationNo @ModuleCode, @BranchId, @CancellationNo OUTPUT;

        -- Parse line items from JSON
        DECLARE @Items TABLE (LineRefId INT, Amount DECIMAL(10,2));
        INSERT INTO @Items (LineRefId, Amount)
        SELECT 
            CAST(JSON_VALUE(j.value, '$.lineRefId') AS INT),
            CAST(JSON_VALUE(j.value, '$.amount') AS DECIMAL(10,2))
        FROM OPENJSON(@LineItemsJson) j;

        DECLARE @TotalItems INT = (SELECT COUNT(*) FROM @Items);
        IF @TotalItems = 0
            THROW 50001, 'No items selected for cancellation.', 1;

        -- LAB: a test whose result is already submitted / validated / approved cannot be cancelled from billing;
        -- the lab has to withdraw the result first (reject the sample on Report Entry, or Un-Authorize an approved report).
        IF @ModuleCode = 'LAB'
        BEGIN
            DECLARE @LabMsg NVARCHAR(2048);

            SELECT @LabMsg = STRING_AGG(CAST(
                       ISNULL(pkg.Profile_Name, lm.Test_Name) + ' ('
                       + CASE WHEN cs.ApprovedCount > 0 THEN 'report approved'
                              WHEN cs.ValidatedCount > 0 THEN 'result validated'
                              ELSE 'result submitted' END + ')' AS NVARCHAR(MAX)), '; ')
            FROM @Items i
            INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = i.LineRefId AND loi.LabOrderId = @ModuleRefId
            INNER JOIN dbo.ufn_LabOrderItemCancelState(@ModuleRefId) cs ON cs.LabOrderItemId = loi.LabOrderItemId
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster lm ON lm.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
            WHERE cs.CancelStage = 'BLOCKED';

            IF @LabMsg IS NOT NULL
            BEGIN
                SET @LabMsg = LEFT(N'Cannot cancel: ' + @LabMsg
                    + N'. The lab must first withdraw the result (reject the sample on Report Entry; an approved report has to be Un-Authorized first).', 2048);
                THROW 50003, @LabMsg, 1;
            END

            IF ISNULL(@AcknowledgeLabWarnings, 0) = 0
               AND EXISTS (SELECT 1 FROM @Items i
                           INNER JOIN dbo.ufn_LabOrderItemCancelState(@ModuleRefId) cs ON cs.LabOrderItemId = i.LineRefId
                           WHERE cs.CancelStage = 'WARN')
                THROW 50004, 'Some selected tests already have a collected sample or a draft result. Confirm that they will be discarded to continue.', 1;
        END

        -- Validate: check items are not already cancelled
        IF EXISTS (
            SELECT 1 FROM @Items i
            INNER JOIN dbo.BillCancellationItem bci ON bci.LineRefId = i.LineRefId
            INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
            WHERE bc.ModuleCode = @ModuleCode AND bc.IsActive = 1
        )
            THROW 50002, 'One or more selected items are already cancelled.', 1;

        DECLARE @CancelledAmount DECIMAL(10,2) = (SELECT SUM(Amount) FROM @Items);

        -- Determine full or partial
        DECLARE @TotalBillItems INT;
        DECLARE @CancellationType CHAR(1);

        IF @ModuleCode = 'LAB'
        BEGIN
            SELECT @TotalBillItems = COUNT(*) FROM dbo.LabOrderItem 
            WHERE LabOrderId = @ModuleRefId AND IsActive = 1;
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            SELECT @TotalBillItems = COUNT(*) FROM dbo.PatientOPDServiceItem 
            WHERE OPDServiceId = @ModuleRefId AND IsActive = 1;
        END

        SET @CancellationType = CASE WHEN @TotalItems >= @TotalBillItems THEN 'F' ELSE 'P' END;

        -- Insert BillCancellation header
        INSERT INTO dbo.BillCancellation 
            (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate,
             CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@ModuleCode, @ModuleRefId, @CancellationNo, @CancellationType, GETDATE(),
             @CancelledAmount, ISNULL(@DiscountAdjusted, 0), @Reason, 'C', @UserId, GETDATE(), 1);

        SET @CancellationId = SCOPE_IDENTITY();

        -- Insert BillCancellationItem rows
        INSERT INTO dbo.BillCancellationItem (CancellationId, LineRefId, OriginalAmount, CancelledAmount, IsActive)
        SELECT @CancellationId, LineRefId, Amount, Amount, 1
        FROM @Items;

        -- Mark items as inactive in source table
        IF @ModuleCode = 'LAB'
        BEGIN
            -- the samples of the cancelled lines leave every lab worklist, and a draft result is discarded
            DECLARE @CancelledSamples TABLE (SampleCollectionId BIGINT PRIMARY KEY);
            INSERT INTO @CancelledSamples (SampleCollectionId)
            SELECT DISTINCT m.SampleCollectionId
            FROM dbo.ufn_LabOrderItemSamples(@ModuleRefId) m
            WHERE m.LabOrderItemId IN (SELECT LineRefId FROM @Items);

            UPDATE led SET led.IsActive = 0, led.ModifiedBy = @UserId, led.ModifiedDate = GETDATE()
            FROM dbo.labentrydetails led
            INNER JOIN @CancelledSamples x ON x.SampleCollectionId = led.SamplecollectionID
            WHERE led.IsActive = 1;

            UPDATE sc SET sc.Iscancelled = 1, sc.ModifiedBy = @UserId, sc.ModifiedDate = GETDATE()
            FROM dbo.SampleCollection sc
            INNER JOIN @CancelledSamples x ON x.SampleCollectionId = sc.samplecollectionID;

            UPDATE dbo.LabOrderItem 
            SET IsActive = 0
            WHERE LabOrderItemId IN (SELECT LineRefId FROM @Items);
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            UPDATE dbo.PatientOPDServiceItem 
            SET IsActive = 0
            WHERE ItemId IN (SELECT LineRefId FROM @Items);
        END

        -- Update PaymentHeader
        IF @CancellationType = 'F'
        BEGIN
            -- Full cancellation: NetAmount and BalanceDue become 0
            UPDATE dbo.PaymentHeader
            SET NetAmount            = 0,
                BalanceDue           = 0,
                HeaderDiscountAmount = 0,
                RoundOffAmount       = 0,
                LineDiscountTotal    = 0,
                LastModifiedDate     = GETDATE(),
                LastModifiedBy       = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END
        ELSE
        BEGIN
            -- Partial cancellation: reduce NetAmount by (CancelledAmount - DiscountAdjusted)
            UPDATE dbo.PaymentHeader
            SET NetAmount    = CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0 ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END,
                -- 2230: due = the reduced bill - what has been paid (an overpayment stays visible for the refund)
                BalanceDue   = CASE WHEN (CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0
                                               ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END) - TotalPaid > 0
                                    THEN (CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0
                                               ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END) - TotalPaid
                                    ELSE 0 END,
                HeaderDiscountAmount = CASE WHEN (HeaderDiscountAmount - ISNULL(@DiscountAdjusted, 0)) < 0 THEN 0 ELSE (HeaderDiscountAmount - ISNULL(@DiscountAdjusted, 0)) END,
                -- 2231: status follows the reduced bill: covered = Paid (any excess is for refund), else Partial / Unpaid
                PaymentStatus = CASE WHEN TotalPaid >= (CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0
                                                           ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END) THEN 'P'
                                     WHEN TotalPaid > 0 THEN 'R' ELSE 'U' END,
                LastModifiedDate = GETDATE(),
                LastModifiedBy   = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END

        -- 2232: the cancellation entry (Dr Revenue / Cr the bill's receivable), then discount / round-off follow the bill
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'CANCEL', @RefId = @CancellationId, @UserId = @UserId;
        DECLARE @AdjHeaderId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1);
        IF @AdjHeaderId IS NOT NULL
            EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'ADJUST', @RefId = @AdjHeaderId, @UserId = @UserId;

        -- If full cancellation, mark LabOrder/OPDService as inactive
        IF @CancellationType = 'F'
        BEGIN
            IF @ModuleCode = 'LAB'
                UPDATE dbo.LabOrder SET IsActive = 0 WHERE LabOrderId = @ModuleRefId;
            IF @ModuleCode = 'OPD'
                UPDATE dbo.PatientOPDService SET IsActive = 0 WHERE OPDServiceId = @ModuleRefId;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── Backfill (once; nothing is posted twice) ───────────────────────────────
SET NOCOUNT ON;
DECLARE @id INT, @amt DECIMAL(18,2), @when DATETIME, @br INT, @bill NVARCHAR(60), @at VARCHAR(5), @ag INT, @co INT, @new BIGINT, @n INT = 0;
DECLARE @Recv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable');
DECLARE @LabRev INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'LAB Revenue');
DECLARE @OpdRev INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'OPD Revenue');
DECLARE @Sales INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Sales');
DECLARE @narr NVARCHAR(400);

-- 1. bills that were never posted (gross, as at billing)
DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR
    SELECT lo.LabOrderId, ISNULL(lo.TotalAmount, 0), lo.CreatedDate, ISNULL(lo.BranchId, 1), lo.BillNo
    FROM dbo.LabOrder lo INNER JOIN dbo.PaymentHeader ph ON RTRIM(ph.ModuleCode) = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE ISNULL(lo.IsB2B, 0) = 0 AND ISNULL(lo.TotalAmount, 0) > 0
      AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'LAB_BILL' AND t.ReferenceId = lo.LabOrderId);
OPEN c1; FETCH NEXT FROM c1 INTO @id, @amt, @when, @br, @bill;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @narr = N'Revenue recognized for LAB Bill ' + ISNULL(@bill, CONVERT(NVARCHAR(20), @id)) + N' (backfill)';
    EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Sales, @TransactionDate = @when, @ReferenceType = 'LAB_BILL', @ReferenceId = @id, @BranchId = @br,
         @CompanyId = 1, @TotalAmount = @amt, @Narration = @narr, @DebitLedgerId = @Recv, @CreditLedgerId = @LabRev, @CreatedBy = 1, @NewTransactionId = @new OUTPUT;
    SET @n += 1; FETCH NEXT FROM c1 INTO @id, @amt, @when, @br, @bill;
END
CLOSE c1; DEALLOCATE c1;

DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR
    SELECT s.OPDServiceId, ISNULL(s.TotalAmount, 0), ISNULL(s.VisitDate, ph.CreatedDate), ISNULL(s.BranchId, 1), s.OPDBillNo
    FROM dbo.PatientOPDService s INNER JOIN dbo.PaymentHeader ph ON RTRIM(ph.ModuleCode) = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    WHERE ISNULL(s.TotalAmount, 0) > 0
      AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'OPD_BILL' AND t.ReferenceId = s.OPDServiceId);
OPEN c2; FETCH NEXT FROM c2 INTO @id, @amt, @when, @br, @bill;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @narr = N'Revenue recognized for OPD Bill ' + ISNULL(@bill, CONVERT(NVARCHAR(20), @id)) + N' (backfill)';
    EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Sales, @TransactionDate = @when, @ReferenceType = 'OPD_BILL', @ReferenceId = @id, @BranchId = @br,
         @CompanyId = 1, @TotalAmount = @amt, @Narration = @narr, @DebitLedgerId = @Recv, @CreditLedgerId = @OpdRev, @CreatedBy = 1, @NewTransactionId = @new OUTPUT;
    SET @n += 1; FETCH NEXT FROM c2 INTO @id, @amt, @when, @br, @bill;
END
CLOSE c2; DEALLOCATE c2;

DECLARE c3 CURSOR LOCAL FAST_FORWARD FOR
    SELECT lo.LabOrderId, ISNULL(lo.B2BTotal, lo.TotalAmount), lo.AgentType, lo.B2BAgentID, ISNULL(lo.BranchId, 1), lo.BillNo
    FROM dbo.LabOrder lo
    WHERE lo.IsB2B = 1 AND lo.B2BAgentID IS NOT NULL AND ISNULL(lo.B2BTotal, lo.TotalAmount) > 0
      AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'B2B_LAB_BILL' AND t.ReferenceId = lo.LabOrderId);
OPEN c3; FETCH NEXT FROM c3 INTO @id, @amt, @at, @ag, @br, @bill;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_B2B_PostBillLedger @LabOrderId = @id, @Amount = @amt, @AgentType = @at, @AgentId = @ag, @BranchId = @br, @CompanyId = 1, @UserId = 1, @BillNo = @bill;
    SET @n += 1; FETCH NEXT FROM c3 INTO @id, @amt, @at, @ag, @br, @bill;
END
CLOSE c3; DEALLOCATE c3;
PRINT CONCAT('Backfill - bills posted: ', @n);

-- 1b. cancellations never posted
DECLARE c7 CURSOR LOCAL FAST_FORWARD FOR SELECT CancellationId FROM dbo.BillCancellation WHERE IsActive = 1 ORDER BY CancellationId;
OPEN c7; FETCH NEXT FROM c7 INTO @id;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'CANCEL', @RefId = @id; FETCH NEXT FROM c7 INTO @id; END
CLOSE c7; DEALLOCATE c7;

-- 2. receipts (B2B wallet / settlement receipts are skipped inside the procedure)
SET @n = 0;
DECLARE c4 CURSOR LOCAL FAST_FORWARD FOR
    SELECT pd.PaymentDetailId FROM dbo.PaymentDetail pd INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
    WHERE pd.IsActive = 1 AND pd.PaidAmount > 0 AND RTRIM(ph.ModuleCode) IN ('LAB', 'OPD') ORDER BY pd.PaymentDetailId;
OPEN c4; FETCH NEXT FROM c4 INTO @id;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'RECEIPT', @RefId = @id; SET @n += 1; FETCH NEXT FROM c4 INTO @id; END
CLOSE c4; DEALLOCATE c4;
PRINT CONCAT('Backfill - receipts checked: ', @n);

-- 3. discounts and round-off (dated when the discount was approved, else when the bill was saved)
SET @n = 0;
DECLARE c5 CURSOR LOCAL FAST_FORWARD FOR
    SELECT PaymentHeaderId, COALESCE(DiscountApprovedDate, CreatedDate) FROM dbo.PaymentHeader WHERE IsActive = 1 AND RTRIM(ModuleCode) IN ('LAB', 'OPD');
OPEN c5; FETCH NEXT FROM c5 INTO @id, @when;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'ADJUST', @RefId = @id, @TxDate = @when; SET @n += 1; FETCH NEXT FROM c5 INTO @id, @when; END
CLOSE c5; DEALLOCATE c5;
PRINT CONCAT('Backfill - bills checked for discount / round-off: ', @n);

-- 4. refunds
SET @n = 0;
DECLARE c6 CURSOR LOCAL FAST_FORWARD FOR SELECT RefundId FROM dbo.BillRefund WHERE IsActive = 1 ORDER BY RefundId;
OPEN c6; FETCH NEXT FROM c6 INTO @id;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'REFUND', @RefId = @id; SET @n += 1; FETCH NEXT FROM c6 INTO @id; END
CLOSE c6; DEALLOCATE c6;
PRINT CONCAT('Backfill - refunds checked: ', @n);
GO

PRINT 'Script 2232 applied: receipts, discounts, round-off and refunds in the ledger.';
GO
