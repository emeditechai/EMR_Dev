-- ============================================================================================================
-- Migration: 2375_bill_refund_round_off.sql
-- Refunds follow the round off concept: the refundable is rounded to the rupee (Rs 127.50 -> Rs 128), refunds are
-- whole rupees, and when the full rounded amount is refunded the paise difference is booked as the bill's round off
-- (NetAmount / RoundOffAmount, ledger re-synced) so nothing is left due or in excess.
-- usp_Bill_Refund as in 2236_membership_points_b2c_lab.sql + the "2375" blocks.
-- ============================================================================================================
SET ANSI_NULLS ON;
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
        -- 2375: refunds are paid in whole rupees; the refundable is rounded like a bill (Rs 127.50 -> Rs 128)
        IF @RefundAmount <> ROUND(@RefundAmount, 0)
            THROW 50014, 'Refund amount must be in whole rupees (round off applies).', 1;
        DECLARE @RawRefundable DECIMAL(18,2) = @Refundable;
        SET @Refundable = ROUND(@Refundable, 0);
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
        IF @RefundedOnThis + @RefundAmount > ROUND(@CancelledAmount, 0) + 0.001
            THROW 50012, 'Refund amount exceeds what is left of this cancellation.', 1;

        -- Insert BillRefund
        INSERT INTO dbo.BillRefund 
            (CancellationId, ModuleCode, ModuleRefId, RefundAmount, RefundMode, RefundDate, TransactionRef, Notes, Status, CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@CancellationId, @ModuleCode, @ModuleRefId, @RefundAmount, @RefundMode, GETDATE(), @TransactionRef, @Notes, 'P', @UserId, GETDATE(), 1);

        SET @RefundId = SCOPE_IDENTITY();

        -- 2232: Dr Patient Receivable / Cr Cash or Bank
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'REFUND', @RefId = @RefundId, @UserId = @UserId;

        -- 2236: money given back - the bill's earned membership points follow what is now paid
        IF @ModuleCode = 'LAB'
        BEGIN
            DECLARE @MemHeaderId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1);
            IF @MemHeaderId IS NOT NULL EXEC dbo.usp_Membership_SyncBill @PaymentHeaderId = @MemHeaderId, @UserId = @UserId;
        END

        -- 2375: the full rounded refund settles the paise: the difference goes to the bill's round off, so the bill
        -- equals what the patient keeps (e.g. refundable 127.50, refunded 128 -> bill 935.00 - 0.50 = 934.50)
        IF @RefundAmount = @Refundable AND @Refundable <> @RawRefundable
        BEGIN
            UPDATE dbo.PaymentHeader
            SET NetAmount      = NetAmount + (@RawRefundable - @RefundAmount),
                RoundOffAmount = ISNULL(RoundOffAmount, 0) + (@RawRefundable - @RefundAmount)
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
            DECLARE @RoHeaderId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1);
            IF @RoHeaderId IS NOT NULL EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'ADJUST', @RefId = @RoHeaderId, @UserId = @UserId;
        END

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
