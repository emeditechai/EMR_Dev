-- ============================================================================
-- Migration: 2238_membership_welcome_points_fix.sql
-- Description: Welcome points (given when a card is issued, 2224) could not be redeemed: the card showed them in its
--   balance, but the history row had no RemainingPoints, so usp_Membership_ConsumePoints (2236) found nothing to use
--   and refused with "The card does not have enough points left". They were also valued at Rs 0 with no accounting.
--   * usp_Membership_PostWelcomePoints: values a welcome-points row (points x plan point value) and posts it
--     (Dr Membership Points Expense / Cr Membership Points Liability, MEM_EARN), once.
--   * usp_Api_MembershipCard_Issue: welcome points are written spendable and posted (only that part changed).
--   * Repair: every card whose spendable points differ from its balance gets them recomputed - points already used
--     come off the earliest-expiring credits first (the rule redemption uses); patient totals refreshed.
--   * Backfill: existing welcome points valued and posted.
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Membership_PostWelcomePoints
    @LedgerId BIGINT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CardId INT, @Pts DECIMAL(12,2), @Amt DECIMAL(12,2), @BranchId INT, @CardNo NVARCHAR(50), @When DATETIME, @Co INT;
    SELECT @CardId = l.CardId, @Pts = l.Points, @BranchId = ISNULL(l.BranchId, c.IssueBranchId), @CardNo = c.CardNo, @When = l.CreatedDate,
           @Co = c.CompanyId, @Amt = CAST(ROUND(l.Points * ISNULL(p.PointValue, 0), 2) AS DECIMAL(12,2))
    FROM dbo.MembershipLedger l
    INNER JOIN dbo.MembershipCard c ON c.CardId = l.CardId
    INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
    WHERE l.LedgerId = @LedgerId AND l.TxnType = 'EARN' AND l.Points > 0;
    IF @CardId IS NULL RETURN;

    UPDATE dbo.MembershipLedger SET Amount = @Amt WHERE LedgerId = @LedgerId AND ISNULL(Amount, 0) = 0;

    DECLARE @Liab INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Liability');
    DECLARE @Exp INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Expense');
    DECLARE @Jv INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Credit Note');
    DECLARE @Ref INT = CAST(@LedgerId AS INT), @Narr NVARCHAR(300), @AccId INT, @U INT = ISNULL(@UserId, 1);
    IF @Liab IS NULL OR @Exp IS NULL OR @Jv IS NULL OR @Amt <= 0 RETURN;
    IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = 'MEM_EARN' AND ReferenceId = @Ref AND IsActive = 1) RETURN;
    SET @Narr = CONCAT('Welcome points on membership card ', @CardNo, ' (', CAST(@Pts AS VARCHAR(20)), ' points)');
    EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Jv, @TransactionDate = @When, @ReferenceType = 'MEM_EARN', @ReferenceId = @Ref,
         @BranchId = @BranchId, @CompanyId = @Co, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Exp, @CreditLedgerId = @Liab,
         @CreatedBy = @U, @NewTransactionId = @AccId OUTPUT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipCard_Issue
    @CompanyId        INT,
    @BranchId         INT,
    @PlanId           INT,
    @PrimaryPatientId INT,
    @ValidFrom        DATE = NULL,
    @MembersJson      NVARCHAR(MAX) = NULL,
    @PaymentMethodId  INT = NULL,
    @TransactionRef   NVARCHAR(100) = NULL,
    @Remarks          NVARCHAR(250) = NULL,
    @UserId           INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    SET @ValidFrom = ISNULL(@ValidFrom, @Today);
    IF @ValidFrom < DATEADD(DAY, -30, @Today) OR @ValidFrom > DATEADD(DAY, 90, @Today)
        THROW 51020, 'Card start date must be within the last 30 days or the next 90 days.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND CompanyId = @CompanyId)
        THROW 51021, 'Branch does not belong to this company.', 1;

    DECLARE @PlanName NVARCHAR(150), @PlanType VARCHAR(20), @CardFee DECIMAL(10,2), @GstPercent DECIMAL(5,2), @ValidityDays INT,
            @MaxMembers INT, @MinAge INT, @WelcomePoints DECIMAL(12,2), @PointsExpiryDays INT;
    SELECT @PlanName = PlanName, @PlanType = PlanType, @CardFee = CardFee, @GstPercent = ISNULL(GstPercent, 0), @ValidityDays = ValidityDays,
           @MaxMembers = MaxMembers, @MinAge = MinAge, @WelcomePoints = WelcomePoints, @PointsExpiryDays = PointsExpiryDays
    FROM dbo.MembershipPlan
    WHERE PlanId = @PlanId AND CompanyId = @CompanyId AND IsDeleted = 0 AND IsActive = 1;
    IF @PlanName IS NULL THROW 51022, 'Membership plan not found or not active.', 1;

    DECLARE @Dob DATE, @PatientName NVARCHAR(250);
    SELECT @Dob = DateOfBirth, @PatientName = LTRIM(RTRIM(CONCAT(FirstName, ' ', LastName)))
    FROM dbo.PatientMaster WHERE PatientId = @PrimaryPatientId AND CompanyId = @CompanyId AND IsActive = 1;
    IF @PatientName IS NULL THROW 51023, 'Primary member (patient) not found.', 1;

    IF @MinAge IS NOT NULL
    BEGIN
        IF @Dob IS NULL THROW 51024, 'This plan has a minimum age; the patient has no date of birth on record.', 1;
        IF DATEADD(YEAR, @MinAge, @Dob) > @Today
        BEGIN
            DECLARE @AgeMsg NVARCHAR(200) = CONCAT('The primary member must be at least ', @MinAge, ' years old for this plan.');
            THROW 51025, @AgeMsg, 1;
        END
    END

    DECLARE @Members TABLE (PatientId INT NOT NULL, Relation NVARCHAR(50) NOT NULL, IsPrimary BIT NOT NULL);
    INSERT INTO @Members VALUES (@PrimaryPatientId, N'Self', 1);
    IF NULLIF(LTRIM(RTRIM(@MembersJson)), '') IS NOT NULL
        INSERT INTO @Members (PatientId, Relation, IsPrimary)
        SELECT j.patientId, ISNULL(NULLIF(LTRIM(RTRIM(j.relation)), ''), N'Family'), 0
        FROM OPENJSON(@MembersJson) WITH (patientId INT '$.patientId', relation NVARCHAR(50) '$.relation') j
        WHERE j.patientId IS NOT NULL;

    IF EXISTS (SELECT 1 FROM @Members GROUP BY PatientId HAVING COUNT(1) > 1)
        THROW 51026, 'The same patient is added to the card more than once.', 1;
    IF (SELECT COUNT(1) FROM @Members) > @MaxMembers
    BEGIN
        DECLARE @MaxMsg NVARCHAR(200) = CONCAT('This plan covers at most ', @MaxMembers, ' member(s).');
        THROW 51027, @MaxMsg, 1;
    END
    IF EXISTS (SELECT 1 FROM @Members m
               WHERE NOT EXISTS (SELECT 1 FROM dbo.PatientMaster pm WHERE pm.PatientId = m.PatientId AND pm.CompanyId = @CompanyId AND pm.IsActive = 1))
        THROW 51028, 'A family member is not a registered patient of this company.', 1;

    IF @CardFee > 0 AND NOT EXISTS (SELECT 1 FROM dbo.PaymentMethodMaster WHERE PaymentMethodId = @PaymentMethodId AND IsActive = 1)
        THROW 51029, 'Select the payment method for the card fee.', 1;

    BEGIN TRANSACTION;

    -- One active card of a plan per patient (checked under the card-number lock so two desks cannot both pass)
    DECLARE @CardSeq INT;
    SELECT @CardSeq = ISNULL(MAX(CardSeq), 0) + 1 FROM dbo.MembershipCard WITH (UPDLOCK, HOLDLOCK) WHERE CompanyId = @CompanyId;

    DECLARE @Dup NVARCHAR(300);
    SELECT TOP 1 @Dup = CONCAT(LTRIM(RTRIM(CONCAT(pm.FirstName, ' ', pm.LastName))), ' is already on card ', c.CardNo, ' of this plan (valid to ', CONVERT(VARCHAR(11), c.ValidTo, 106), ').')
    FROM @Members m
    INNER JOIN dbo.MembershipCardMember cm ON cm.PatientId = m.PatientId AND cm.IsActive = 1
    INNER JOIN dbo.MembershipCard c ON c.CardId = cm.CardId AND c.PlanId = @PlanId AND c.Status = 'Active' AND c.ValidTo >= @ValidFrom
    INNER JOIN dbo.PatientMaster pm ON pm.PatientId = m.PatientId;
    IF @Dup IS NOT NULL THROW 51030, @Dup, 1;

    DECLARE @Prefix VARCHAR(10);
    SELECT TOP 1 @Prefix = NULLIF(LTRIM(RTRIM(MembershipCardNoPrefix)), '') FROM dbo.HospitalSettings WHERE BranchID = @BranchId;
    DECLARE @CardNo NVARCHAR(30) = UPPER(ISNULL(@Prefix, 'MC')) + RIGHT('000000' + CAST(@CardSeq AS VARCHAR(10)), CASE WHEN @CardSeq > 999999 THEN 10 ELSE 6 END);
    DECLARE @ValidTo DATE = DATEADD(DAY, @ValidityDays - 1, @ValidFrom);

    -- Fee: GST on top of the card fee, bill rounded to the rupee like every other counter bill
    DECLARE @Cgst DECIMAL(18,2) = ROUND(@CardFee * @GstPercent / 200.0, 2);
    DECLARE @Sgst DECIMAL(18,2) = @Cgst;
    DECLARE @Unrounded DECIMAL(18,2) = @CardFee + @Cgst + @Sgst;
    DECLARE @Net DECIMAL(10,2) = ROUND(@Unrounded, 0);
    DECLARE @RoundOff DECIMAL(10,2) = @Net - @Unrounded;

    INSERT INTO dbo.MembershipCard
        (CompanyId, CardSeq, CardNo, PlanId, IssueBranchId, PrimaryPatientId, ValidFrom, ValidTo, Status, FeeAmount, Remarks, CreatedBy)
    VALUES
        (@CompanyId, @CardSeq, @CardNo, @PlanId, @BranchId, @PrimaryPatientId, @ValidFrom, @ValidTo, 'Active', @Net, NULLIF(LTRIM(RTRIM(@Remarks)), ''), @UserId);
    DECLARE @CardId INT = SCOPE_IDENTITY();

    INSERT INTO dbo.MembershipCardMember (CardId, PatientId, Relation, IsPrimary, CreatedBy)
    SELECT @CardId, PatientId, Relation, IsPrimary, @UserId FROM @Members ORDER BY IsPrimary DESC, PatientId;

    DECLARE @PaymentHeaderId INT = NULL, @ReceiptNo NVARCHAR(50) = NULL;
    IF @Net > 0
    BEGIN
        INSERT INTO dbo.PaymentHeader
            (ModuleCode, ModuleRefId, OPDServiceId, BranchId, PatientId, SubTotal, LineDiscountTotal,
             HeaderDiscountType, HeaderDiscountValue, HeaderDiscountAmount, TotalCgstAmount, TotalSgstAmount, TotalIgstAmount,
             RoundOffAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive)
        VALUES
            ('MEM', @CardId, NULL, @BranchId, @PrimaryPatientId, @CardFee, 0,
             NULL, 0, 0, @Cgst, @Sgst, 0,
             @RoundOff, @Net, @Net, 0, 'P', CONCAT('Membership card ', @CardNo, ' - ', @PlanName), GETDATE(), @UserId, 1);
        SET @PaymentHeaderId = SCOPE_IDENTITY();

        INSERT INTO dbo.PaymentLineItem
            (PaymentHeaderId, ModuleLineRefId, ItemDescription, ServiceType, OriginalAmount, LineDiscountType, LineDiscountValue,
             LineDiscountAmount, NetLineAmount, IsGstApplicable, GstPercentage, CgstAmount, SgstAmount, IgstAmount, CreatedDate, CreatedBy, IsActive)
        VALUES
            (@PaymentHeaderId, @PlanId, LEFT(CONCAT('Membership Card - ', @PlanName), 200), 'Membership', @CardFee, NULL, 0,
             0, @CardFee, CASE WHEN @GstPercent > 0 THEN 1 ELSE 0 END, NULLIF(@GstPercent, 0), @Cgst, @Sgst, 0, GETDATE(), @UserId, 1);

        EXEC dbo.usp_Receipt_GetNextNo @BranchId = @BranchId, @ReceiptNo = @ReceiptNo OUTPUT;

        INSERT INTO dbo.PaymentDetail
            (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo)
        VALUES
            (@PaymentHeaderId, @PaymentMethodId, @Net, NULLIF(LTRIM(RTRIM(@TransactionRef)), ''), GETDATE(),
             CONCAT('Membership card fee ', @CardNo), GETDATE(), @UserId, 1, @ReceiptNo);

        UPDATE dbo.MembershipCard SET FeePaymentHeaderId = @PaymentHeaderId, ReceiptNo = @ReceiptNo WHERE CardId = @CardId;

        -- Accounting ledger (existing Acc_ tables): the sale, then the money received against it
        DECLARE @SalesVoucherId INT   = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Sales');
        DECLARE @ReceiptVoucherId INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
        DECLARE @ReceivableLedgerId INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable');
        DECLARE @RevenueLedgerId INT    = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Revenue');
        DECLARE @MoneyLedgerId INT      = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster
                                           WHERE LedgerName = CASE WHEN (SELECT MethodCode FROM dbo.PaymentMethodMaster WHERE PaymentMethodId = @PaymentMethodId) = 'CASH'
                                                                   THEN 'Cash Account' ELSE 'Bank Account' END);
        IF @SalesVoucherId IS NULL OR @ReceiptVoucherId IS NULL OR @ReceivableLedgerId IS NULL OR @RevenueLedgerId IS NULL OR @MoneyLedgerId IS NULL
            THROW 51031, 'Accounting ledgers for membership cards are not set up (Membership Revenue, Patient Receivable, Cash Account, Bank Account; vouchers Sales and Receipt).', 1;

        DECLARE @Now DATETIME = GETDATE(), @AccTxId BIGINT;
        DECLARE @SaleNarration NVARCHAR(MAX)    = CONCAT('Membership card ', @CardNo, ' (', @PlanName, ') issued to ', @PatientName);
        DECLARE @ReceiptNarration NVARCHAR(MAX) = CONCAT('Membership card fee received for card ', @CardNo, ', receipt ', @ReceiptNo);

        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @SalesVoucherId, @TransactionDate = @Now, @ReferenceType = 'MEM_CARD', @ReferenceId = @CardId,
             @BranchId = @BranchId, @CompanyId = @CompanyId, @TotalAmount = @Net, @Narration = @SaleNarration,
             @DebitLedgerId = @ReceivableLedgerId, @CreditLedgerId = @RevenueLedgerId, @CreatedBy = @UserId, @NewTransactionId = @AccTxId OUTPUT;

        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @ReceiptVoucherId, @TransactionDate = @Now, @ReferenceType = 'MEM_RECEIPT', @ReferenceId = @CardId,
             @BranchId = @BranchId, @CompanyId = @CompanyId, @TotalAmount = @Net, @Narration = @ReceiptNarration,
             @DebitLedgerId = @MoneyLedgerId, @CreditLedgerId = @ReceivableLedgerId, @CreatedBy = @UserId, @NewTransactionId = @AccTxId OUTPUT;
    END

    -- Ledger: the issue itself, then the welcome points (if the plan gives any)
    INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy)
    VALUES (@CardId, @PrimaryPatientId, @BranchId, @PaymentHeaderId, @ReceiptNo, 'ISSUE', 0, @Net, NULL, 0,
            CONCAT('Card ', @CardNo, ' issued on plan ', @PlanName, ', valid ', CONVERT(VARCHAR(11), @ValidFrom, 106), ' to ', CONVERT(VARCHAR(11), @ValidTo, 106),
                   CASE WHEN @Net > 0 THEN CONCAT('. Fee Rs. ', CAST(@Net AS VARCHAR(20)), ', receipt ', @ReceiptNo) ELSE '. No fee' END),
            @UserId);

    IF @WelcomePoints > 0
    BEGIN
        -- 2238: spendable like any earned points (RemainingPoints), valued at the plan's point value, and accounted
        INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy, RemainingPoints)
        VALUES (@CardId, @PrimaryPatientId, @BranchId, NULL, NULL, 'EARN', @WelcomePoints, 0, DATEADD(DAY, @PointsExpiryDays, @ValidFrom), @WelcomePoints,
                'Welcome points on card issue', @UserId, @WelcomePoints);
        DECLARE @WelcomeLedgerId BIGINT = SCOPE_IDENTITY();
        UPDATE dbo.MembershipCard SET PointsBalance = @WelcomePoints WHERE CardId = @CardId;
        EXEC dbo.usp_Membership_PostWelcomePoints @LedgerId = @WelcomeLedgerId, @UserId = @UserId;
        EXEC dbo.usp_Membership_SyncPatientTotals @CardId = @CardId;
    END

    COMMIT TRANSACTION;

    SELECT @CardId AS CardId, @CardNo AS CardNo, @ReceiptNo AS ReceiptNo, @PaymentHeaderId AS PaymentHeaderId, @Net AS FeeAmount;
END
GO

-- Repair: spendable points of each card = its balance, used points taken off the earliest-expiring credits first
;WITH credits AS (
    SELECT l.LedgerId, l.CardId, l.Points,
           SUM(l.Points) OVER (PARTITION BY l.CardId ORDER BY ISNULL(l.ExpiresOn, '9999-12-31'), l.LedgerId
                               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS Before,
           SUM(l.Points) OVER (PARTITION BY l.CardId) AS TotalCredit,
           SUM(ISNULL(l.RemainingPoints, 0)) OVER (PARTITION BY l.CardId) AS Spendable
    FROM dbo.MembershipLedger l
    WHERE l.TxnType IN ('EARN', 'RESTORE') AND l.Points > 0),
fix AS (
    SELECT cr.LedgerId,
           CASE WHEN TotalCredit - c.PointsBalance - ISNULL(cr.Before, 0) <= 0 THEN cr.Points                -- untouched
                WHEN TotalCredit - c.PointsBalance - ISNULL(cr.Before, 0) >= cr.Points THEN 0                 -- fully used
                ELSE cr.Points - (TotalCredit - c.PointsBalance - ISNULL(cr.Before, 0)) END AS NewRemaining
    FROM credits cr
    INNER JOIN dbo.MembershipCard c ON c.CardId = cr.CardId
    WHERE cr.Spendable <> c.PointsBalance AND cr.TotalCredit >= c.PointsBalance)
UPDATE l SET RemainingPoints = f.NewRemaining
FROM dbo.MembershipLedger l INNER JOIN fix f ON f.LedgerId = l.LedgerId;
GO

-- Backfill: welcome points valued and posted
DECLARE @id BIGINT;
DECLARE w CURSOR LOCAL FAST_FORWARD FOR
    SELECT LedgerId FROM dbo.MembershipLedger WHERE TxnType = 'EARN' AND Points > 0 AND Narration = 'Welcome points on card issue';
OPEN w; FETCH NEXT FROM w INTO @id;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Membership_PostWelcomePoints @LedgerId = @id, @UserId = 1;
    FETCH NEXT FROM w INTO @id;
END
CLOSE w; DEALLOCATE w;
GO

DECLARE @c INT;
DECLARE s CURSOR LOCAL FAST_FORWARD FOR SELECT CardId FROM dbo.MembershipCard;
OPEN s; FETCH NEXT FROM s INTO @c;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Membership_SyncPatientTotals @CardId = @c; FETCH NEXT FROM s INTO @c; END
CLOSE s; DEALLOCATE s;
GO

PRINT 'Script 2238 applied: welcome points spendable, valued and accounted; card spendable points repaired.';
GO
