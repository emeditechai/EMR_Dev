-- ============================================================================
-- Migration: 2242_membership_expire_no_resultset.sql
-- Description: Fix for 2241 - usp_Membership_ExpirePoints called for one card (inside usp_Membership_CardForBilling and
--   usp_Membership_RedeemOtpCreate) returned its "CardsExpired" count as a result set, so the card look-up returned that
--   first and the booking page / payment screen found no membership card. The count is now returned only to the
--   expiry job (no card given). Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Membership_ExpirePoints
    @UserId INT = 1,
    @CardId_Only INT = NULL   -- 2241: one card (before it is shown / redeemed); NULL = every card (the job)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @NowDt DATETIME = GETDATE();
    DECLARE @Today DATE = CAST(GETDATE() AS DATE), @CardId INT, @Pts DECIMAL(12,2), @Pv DECIMAL(12,2), @Amt DECIMAL(12,2), @Bal DECIMAL(12,2),
            @Primary INT, @Branch INT, @LedgerId BIGINT, @AccId BIGINT, @Narr NVARCHAR(400), @n INT = 0;
    DECLARE @Liab INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Liability');
    DECLARE @Exp INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Expense');
    DECLARE @Jv INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Credit Note');

    DECLARE cc CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT CardId FROM dbo.MembershipLedger WHERE RemainingPoints > 0 AND ExpiresOn < @Today AND (@CardId_Only IS NULL OR CardId = @CardId_Only);
    OPEN cc; FETCH NEXT FROM cc INTO @CardId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRAN;
            SELECT @Pts = ISNULL(SUM(RemainingPoints), 0) FROM dbo.MembershipLedger WITH (UPDLOCK) WHERE CardId = @CardId AND RemainingPoints > 0 AND ExpiresOn < @Today;
            IF @Pts > 0
            BEGIN
                UPDATE dbo.MembershipLedger SET RemainingPoints = 0 WHERE CardId = @CardId AND RemainingPoints > 0 AND ExpiresOn < @Today;
                SELECT @Pv = ISNULL(pl.PointValue, 1), @Primary = c.PrimaryPatientId, @Branch = c.IssueBranchId
                FROM dbo.MembershipCard c INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId WHERE c.CardId = @CardId;
                UPDATE dbo.MembershipCard SET PointsBalance = CASE WHEN PointsBalance - @Pts < 0 THEN 0 ELSE PointsBalance - @Pts END WHERE CardId = @CardId;
                SELECT @Bal = PointsBalance FROM dbo.MembershipCard WHERE CardId = @CardId;
                SET @Amt = ROUND(@Pts * @Pv, 2);
                INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy)
                VALUES (@CardId, @Primary, ISNULL(@Branch, 1), NULL, NULL, 'EXPIRE', -@Pts, @Amt, NULL, @Bal,
                        CONCAT(CAST(@Pts AS VARCHAR(20)), ' points expired (not used by their expiry date)'), @UserId);
                SET @LedgerId = SCOPE_IDENTITY();
                IF @Liab IS NOT NULL AND @Exp IS NOT NULL AND @Jv IS NOT NULL AND @Amt > 0
                BEGIN
                    SET @Narr = CONCAT('Membership points expired - card ', (SELECT CardNo FROM dbo.MembershipCard WHERE CardId = @CardId));
                    SET @Branch = ISNULL(@Branch, 1);
                    EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Jv, @TransactionDate = @NowDt, @ReferenceType = 'MEM_EXPIRE', @ReferenceId = @LedgerId,
                         @BranchId = @Branch, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Liab, @CreditLedgerId = @Exp,
                         @CreatedBy = @UserId, @NewTransactionId = @AccId OUTPUT;
                END
                EXEC dbo.usp_Membership_SyncPatientTotals @CardId = @CardId;
                SET @n += 1;
            END
        COMMIT;
        FETCH NEXT FROM cc INTO @CardId;
    END
    CLOSE cc; DEALLOCATE cc;
    -- 2242: the count is for the expiry job only; a one-card call (card look-up, OTP) must return no result set
    IF @CardId_Only IS NULL SELECT @n AS CardsExpired;
END;
GO

PRINT 'Script 2242 applied: points expiry returns no result set for a one-card call.';
GO
