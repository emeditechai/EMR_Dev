-- ============================================================================
-- Migration: 2231_cancel_refund_standard_rule.sql
-- Description: Cancellation & refund follow one standard rule for LAB B2C, LAB B2B and OPD:
--     bill after cancellation = the tests / services still on it
--     due        = max(0, bill - received)          received = receipts - refunds
--     refundable = max(0, received - bill)          a bill is either due or refundable, never both
--   * usp_Bill_Cancel (partial): the payment status follows the reduced bill (covered = Paid).
--   * usp_Bill_Refund: a refund is allowed only up to what the patient paid over the bill (and up to what is left of
--     that cancellation); the bill row is locked while checking (it used to check only "refund <= cancelled amount").
--   * Repair: payment status of partly cancelled bills.
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
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

-- Repair: status of bills with a partial cancellation follows the bill as it stands
;WITH x AS (
    SELECT ph.PaymentHeaderId, ph.NetAmount,
           ISNULL((SELECT SUM(d.PaidAmount) FROM dbo.PaymentDetail d WHERE d.PaymentHeaderId = ph.PaymentHeaderId AND d.IsActive = 1), 0)
         - ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.BillRefund r WHERE r.ModuleCode = ph.ModuleCode AND r.ModuleRefId = ph.ModuleRefId AND r.IsActive = 1), 0) AS Received
    FROM dbo.PaymentHeader ph
    WHERE ph.IsActive = 1
      AND EXISTS (SELECT 1 FROM dbo.BillCancellation c WHERE c.ModuleCode = ph.ModuleCode AND c.ModuleRefId = ph.ModuleRefId AND c.IsActive = 1 AND c.CancellationType = 'P'))
UPDATE ph SET
    TotalPaid     = x.Received,
    BalanceDue    = CASE WHEN x.NetAmount - x.Received > 0 THEN x.NetAmount - x.Received ELSE 0 END,
    PaymentStatus = CASE WHEN x.Received >= x.NetAmount THEN 'P' WHEN x.Received > 0 THEN 'R' ELSE 'U' END
FROM dbo.PaymentHeader ph INNER JOIN x ON x.PaymentHeaderId = ph.PaymentHeaderId;
PRINT CONCAT('Partly cancelled bills re-checked: ', @@ROWCOUNT);
GO

PRINT 'Script 2231 applied: cancellation / refund standard rule.';
GO
