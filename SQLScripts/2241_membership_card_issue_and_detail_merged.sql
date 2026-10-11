-- ============================================================================
-- Migration: 2241_membership_card_issue_and_detail_merged.sql
-- Description:
--   Two pieces of membership work changed the same two procedures. This script is the one version of each
--   that carries both, and must be the last to define them:
--     * lifetime plans, renewal with points carried forward, head-of-family and family rules
--       (2225_membership_lifetime_and_renewal, 2228_membership_family_from_patient_master)
--     * points on B2C LAB billing: spendable credits (RemainingPoints), welcome points valued and posted,
--       patient running totals, points entries in the card's Accounting Entries (2236, 2237, 2238)
--   usp_Api_MembershipCard_Issue
--     - fresh issue: welcome points are written spendable, posted and added to the patient totals (2238)
--     - renewal: the carried-forward points are spendable on the next card; the old card's credits are
--       closed (RemainingPoints = 0) so they are neither spent nor expired twice; patient totals refreshed
--   usp_Api_MembershipCard_GetById
--     - lifetime flag and renewal links, and the points accounting entries
--   Run after 2240. Safe to re-run.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- credits written by a renewal before this script: what is left of them is what the card still holds
UPDATE l SET RemainingPoints = CASE WHEN c.PointsBalance < l.Points THEN c.PointsBalance ELSE l.Points END
FROM dbo.MembershipLedger l INNER JOIN dbo.MembershipCard c ON c.CardId = l.CardId
WHERE l.TxnType = 'RENEW' AND l.Points > 0 AND l.RemainingPoints IS NULL AND c.Status <> 'Renewed';
UPDATE l SET RemainingPoints = 0
FROM dbo.MembershipLedger l INNER JOIN dbo.MembershipCard c ON c.CardId = l.CardId
WHERE c.Status = 'Renewed' AND l.RemainingPoints > 0;
GO



-- 3. Issue / renew -----------------------------------------------------------------
-- Issues a card: card + members + fee payment (existing payment tables, module MEM) + accounting ledger
-- + card ledger rows, one transaction.
-- Fresh issue : @PrimaryPatientId, @PlanId and @MembersJson ([{"patientId":12,"relation":"Spouse"}]; the
--               primary patient is added as Self).
-- Renewal     : @RenewFromCardId = the card being renewed. Primary member and members come from that card;
--               @PlanId = 0 / NULL keeps its plan, another plan id moves the member to that plan.
--               The old card becomes 'Renewed' and its points balance moves to the next card.
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
    @UserId           INT = NULL,
    @RenewFromCardId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @Lifetime DATE = '99991231';
    DECLARE @IsRenewal BIT = CASE WHEN ISNULL(@RenewFromCardId, 0) > 0 THEN 1 ELSE 0 END;

    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND CompanyId = @CompanyId)
        THROW 51021, 'Branch does not belong to this company.', 1;

    BEGIN TRANSACTION;

    -- Renewal: read (and hold) the card being renewed
    DECLARE @OldPlanId INT, @OldStatus VARCHAR(15), @OldValidTo DATE, @OldCardNo NVARCHAR(30), @OldBalance DECIMAL(12,2), @OldPrimary INT;
    IF @IsRenewal = 1
    BEGIN
        SELECT @OldPlanId = PlanId, @OldStatus = Status, @OldValidTo = ValidTo, @OldCardNo = CardNo, @OldBalance = PointsBalance, @OldPrimary = PrimaryPatientId
        FROM dbo.MembershipCard WITH (UPDLOCK, HOLDLOCK)
        WHERE CardId = @RenewFromCardId AND CompanyId = @CompanyId;

        IF @OldPlanId IS NULL THROW 51040, 'Membership card not found.', 1;
        IF @OldStatus = 'Renewed' THROW 51060, 'This card has already been renewed.', 1;
        IF @OldStatus <> 'Active' THROW 51061, 'A blocked or cancelled card cannot be renewed.', 1;
        IF @OldValidTo >= @Lifetime THROW 51062, 'A lifetime card does not expire and is not renewed.', 1;

        DECLARE @Window INT;
        SELECT TOP 1 @Window = MembershipRenewalWindowDays FROM dbo.HospitalSettings WHERE BranchID = @BranchId;
        SET @Window = ISNULL(@Window, 30);
        IF @OldValidTo > DATEADD(DAY, @Window, @Today)
        BEGIN
            DECLARE @WindowMsg NVARCHAR(250) = CONCAT('This card is valid to ', CONVERT(VARCHAR(11), @OldValidTo, 106), '. It can be renewed from ',
                                                      CONVERT(VARCHAR(11), DATEADD(DAY, -@Window, @OldValidTo), 106), ' (', @Window, ' days before it expires).');
            THROW 51063, @WindowMsg, 1;
        END

        SET @PrimaryPatientId = @OldPrimary;
        SET @PlanId = ISNULL(NULLIF(@PlanId, 0), @OldPlanId);
        SET @ValidFrom = @Today;
    END

    SET @ValidFrom = ISNULL(@ValidFrom, @Today);
    IF @ValidFrom < DATEADD(DAY, -30, @Today) OR @ValidFrom > DATEADD(DAY, 90, @Today)
        THROW 51020, 'Card start date must be within the last 30 days or the next 90 days.', 1;

    DECLARE @PlanName NVARCHAR(150), @PlanType VARCHAR(20), @CardFee DECIMAL(10,2), @GstPercent DECIMAL(5,2), @ValidityDays INT, @IsLifetime BIT,
            @MaxMembers INT, @MinAge INT, @WelcomePoints DECIMAL(12,2), @PointsExpiryDays INT;
    SELECT @PlanName = PlanName, @PlanType = PlanType, @CardFee = CardFee, @GstPercent = ISNULL(GstPercent, 0), @ValidityDays = ValidityDays,
           @IsLifetime = IsLifetime, @MaxMembers = MaxMembers, @MinAge = MinAge, @WelcomePoints = WelcomePoints, @PointsExpiryDays = PointsExpiryDays
    FROM dbo.MembershipPlan
    WHERE PlanId = @PlanId AND CompanyId = @CompanyId AND IsDeleted = 0 AND IsActive = 1;
    IF @PlanName IS NULL THROW 51022, 'Membership plan not found or not active.', 1;

    DECLARE @Dob DATE, @PatientName NVARCHAR(250), @HeadRelationId INT, @HeadPhone NVARCHAR(30);
    SELECT @Dob = DateOfBirth, @PatientName = LTRIM(RTRIM(CONCAT(FirstName, ' ', LastName))),
           @HeadRelationId = RelationId, @HeadPhone = NULLIF(LTRIM(RTRIM(PhoneNumber)), '')
    FROM dbo.PatientMaster WHERE PatientId = @PrimaryPatientId AND CompanyId = @CompanyId AND IsActive = 1;
    IF @PatientName IS NULL THROW 51023, 'Primary member (patient) not found.', 1;
    -- A card is issued to the head of a family: the patient registered with relation Self (RelationId 1)
    IF @IsRenewal = 0 AND ISNULL(@HeadRelationId, 0) <> 1
        THROW 51032, 'The primary member must be the head of the family: a patient registered with relation Self.', 1;

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
    IF @IsRenewal = 1
        INSERT INTO @Members (PatientId, Relation, IsPrimary)
        SELECT PatientId, Relation, IsPrimary FROM dbo.MembershipCardMember WHERE CardId = @RenewFromCardId AND IsActive = 1;
    ELSE
    BEGIN
        INSERT INTO @Members VALUES (@PrimaryPatientId, N'Self', 1);
        IF NULLIF(LTRIM(RTRIM(@MembersJson)), '') IS NOT NULL
        BEGIN
            -- The relation is the one on the member's own patient record (RelationMaster), never what the screen sent
            INSERT INTO @Members (PatientId, Relation, IsPrimary)
            SELECT j.patientId, ISNULL(rm.RelationName, N'Family'), 0
            FROM OPENJSON(@MembersJson) WITH (patientId INT '$.patientId') j
            LEFT JOIN dbo.PatientMaster fm ON fm.PatientId = j.patientId
            LEFT JOIN dbo.RelationMaster rm ON rm.RelationId = fm.RelationId
            WHERE j.patientId IS NOT NULL;

            -- Family = patients registered on the head's mobile number, other than a second head (Self)
            IF EXISTS (SELECT 1 FROM @Members m
                       INNER JOIN dbo.PatientMaster fm ON fm.PatientId = m.PatientId
                       WHERE m.IsPrimary = 0
                         AND (@HeadPhone IS NULL OR NULLIF(LTRIM(RTRIM(fm.PhoneNumber)), '') IS NULL
                              OR LTRIM(RTRIM(fm.PhoneNumber)) <> @HeadPhone OR ISNULL(fm.RelationId, 0) = 1))
                THROW 51033, 'A family member must be a patient registered on the primary member''s mobile number, with a relation other than Self.', 1;
        END
    END

    IF EXISTS (SELECT 1 FROM @Members GROUP BY PatientId HAVING COUNT(1) > 1)
        THROW 51026, 'The same patient is added to the card more than once.', 1;
    IF (SELECT COUNT(1) FROM @Members) > @MaxMembers
    BEGIN
        DECLARE @MaxMsg NVARCHAR(200) = CONCAT('This plan covers at most ', @MaxMembers, ' member(s); the card has ', (SELECT COUNT(1) FROM @Members), '.');
        THROW 51027, @MaxMsg, 1;
    END
    IF EXISTS (SELECT 1 FROM @Members m
               WHERE NOT EXISTS (SELECT 1 FROM dbo.PatientMaster pm WHERE pm.PatientId = m.PatientId AND pm.CompanyId = @CompanyId AND pm.IsActive = 1))
        THROW 51028, 'A family member is not a registered patient of this company.', 1;

    IF @CardFee > 0 AND NOT EXISTS (SELECT 1 FROM dbo.PaymentMethodMaster WHERE PaymentMethodId = @PaymentMethodId AND IsActive = 1)
        THROW 51029, 'Select the payment method for the card fee.', 1;

    -- One active card of a plan per patient (checked under the card-number lock so two desks cannot both pass)
    DECLARE @CardSeq INT;
    SELECT @CardSeq = ISNULL(MAX(CardSeq), 0) + 1 FROM dbo.MembershipCard WITH (UPDLOCK, HOLDLOCK) WHERE CompanyId = @CompanyId;

    DECLARE @Dup NVARCHAR(300);
    SELECT TOP 1 @Dup = CONCAT(LTRIM(RTRIM(CONCAT(pm.FirstName, ' ', pm.LastName))), ' is already on card ', c.CardNo, ' of this plan (',
                               CASE WHEN c.ValidTo >= @Lifetime THEN 'lifetime' ELSE 'valid to ' + CONVERT(VARCHAR(11), c.ValidTo, 106) END, ').')
    FROM @Members m
    INNER JOIN dbo.MembershipCardMember cm ON cm.PatientId = m.PatientId AND cm.IsActive = 1
    INNER JOIN dbo.MembershipCard c ON c.CardId = cm.CardId AND c.PlanId = @PlanId AND c.Status = 'Active' AND c.ValidTo >= @ValidFrom
                                   AND c.CardId <> ISNULL(@RenewFromCardId, 0)
    INNER JOIN dbo.PatientMaster pm ON pm.PatientId = m.PatientId;
    IF @Dup IS NOT NULL THROW 51030, @Dup, 1;

    DECLARE @Prefix VARCHAR(10);
    SELECT TOP 1 @Prefix = NULLIF(LTRIM(RTRIM(MembershipCardNoPrefix)), '') FROM dbo.HospitalSettings WHERE BranchID = @BranchId;
    DECLARE @CardNo NVARCHAR(30) = UPPER(ISNULL(@Prefix, 'MC')) + RIGHT('000000' + CAST(@CardSeq AS VARCHAR(10)), CASE WHEN @CardSeq > 999999 THEN 10 ELSE 6 END);

    -- Validity: lifetime never ends; a renewal keeps the days left on the old card; a fresh issue runs the plan's days
    DECLARE @ValidTo DATE = CASE
        WHEN @IsLifetime = 1 THEN @Lifetime
        WHEN @IsRenewal = 1 THEN DATEADD(DAY, @ValidityDays, CASE WHEN @OldValidTo >= @Today THEN @OldValidTo ELSE DATEADD(DAY, -1, @Today) END)
        ELSE DATEADD(DAY, @ValidityDays - 1, @ValidFrom) END;
    DECLARE @ValidText NVARCHAR(60) = CONCAT(CONVERT(VARCHAR(11), @ValidFrom, 106), CASE WHEN @IsLifetime = 1 THEN ' for lifetime' ELSE ' to ' + CONVERT(VARCHAR(11), @ValidTo, 106) END);

    -- Fee: GST on top of the card fee, bill rounded to the rupee like every other counter bill
    DECLARE @Cgst DECIMAL(18,2) = ROUND(@CardFee * @GstPercent / 200.0, 2);
    DECLARE @Sgst DECIMAL(18,2) = @Cgst;
    DECLARE @Unrounded DECIMAL(18,2) = @CardFee + @Cgst + @Sgst;
    DECLARE @Net DECIMAL(10,2) = ROUND(@Unrounded, 0);
    DECLARE @RoundOff DECIMAL(10,2) = @Net - @Unrounded;

    INSERT INTO dbo.MembershipCard
        (CompanyId, CardSeq, CardNo, PlanId, IssueBranchId, PrimaryPatientId, ValidFrom, ValidTo, Status, FeeAmount, RenewedFromCardId, Remarks, CreatedBy)
    VALUES
        (@CompanyId, @CardSeq, @CardNo, @PlanId, @BranchId, @PrimaryPatientId, @ValidFrom, @ValidTo, 'Active', @Net,
         CASE WHEN @IsRenewal = 1 THEN @RenewFromCardId END, NULLIF(LTRIM(RTRIM(@Remarks)), ''), @UserId);
    DECLARE @CardId INT = SCOPE_IDENTITY();

    INSERT INTO dbo.MembershipCardMember (CardId, PatientId, Relation, IsPrimary, CreatedBy)
    SELECT @CardId, PatientId, Relation, IsPrimary, @UserId FROM @Members ORDER BY IsPrimary DESC, PatientId;

    DECLARE @What NVARCHAR(20) = CASE WHEN @IsRenewal = 1 THEN 'renewal' ELSE 'card' END;
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
             @RoundOff, @Net, @Net, 0, 'P', CONCAT('Membership ', @What, ' ', @CardNo, ' - ', @PlanName), GETDATE(), @UserId, 1);
        SET @PaymentHeaderId = SCOPE_IDENTITY();

        INSERT INTO dbo.PaymentLineItem
            (PaymentHeaderId, ModuleLineRefId, ItemDescription, ServiceType, OriginalAmount, LineDiscountType, LineDiscountValue,
             LineDiscountAmount, NetLineAmount, IsGstApplicable, GstPercentage, CgstAmount, SgstAmount, IgstAmount, CreatedDate, CreatedBy, IsActive)
        VALUES
            (@PaymentHeaderId, @PlanId, LEFT(CONCAT('Membership Card ', CASE WHEN @IsRenewal = 1 THEN 'Renewal ' ELSE '' END, '- ', @PlanName), 200), 'Membership', @CardFee, NULL, 0,
             0, @CardFee, CASE WHEN @GstPercent > 0 THEN 1 ELSE 0 END, NULLIF(@GstPercent, 0), @Cgst, @Sgst, 0, GETDATE(), @UserId, 1);

        EXEC dbo.usp_Receipt_GetNextNo @BranchId = @BranchId, @ReceiptNo = @ReceiptNo OUTPUT;

        INSERT INTO dbo.PaymentDetail
            (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo)
        VALUES
            (@PaymentHeaderId, @PaymentMethodId, @Net, NULLIF(LTRIM(RTRIM(@TransactionRef)), ''), GETDATE(),
             CONCAT('Membership ', @What, ' fee ', @CardNo), GETDATE(), @UserId, 1, @ReceiptNo);

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
        DECLARE @SaleNarration NVARCHAR(MAX)    = CONCAT('Membership card ', @CardNo, ' (', @PlanName, ') ',
                                                         CASE WHEN @IsRenewal = 1 THEN CONCAT('renewed from card ', @OldCardNo, ' for ') ELSE 'issued to ' END, @PatientName);
        DECLARE @ReceiptNarration NVARCHAR(MAX) = CONCAT('Membership ', @What, ' fee received for card ', @CardNo, ', receipt ', @ReceiptNo);

        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @SalesVoucherId, @TransactionDate = @Now, @ReferenceType = 'MEM_CARD', @ReferenceId = @CardId,
             @BranchId = @BranchId, @CompanyId = @CompanyId, @TotalAmount = @Net, @Narration = @SaleNarration,
             @DebitLedgerId = @ReceivableLedgerId, @CreditLedgerId = @RevenueLedgerId, @CreatedBy = @UserId, @NewTransactionId = @AccTxId OUTPUT;

        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @ReceiptVoucherId, @TransactionDate = @Now, @ReferenceType = 'MEM_RECEIPT', @ReferenceId = @CardId,
             @BranchId = @BranchId, @CompanyId = @CompanyId, @TotalAmount = @Net, @Narration = @ReceiptNarration,
             @DebitLedgerId = @MoneyLedgerId, @CreditLedgerId = @ReceivableLedgerId, @CreatedBy = @UserId, @NewTransactionId = @AccTxId OUTPUT;
    END

    DECLARE @FeeText NVARCHAR(120) = CASE WHEN @Net > 0 THEN CONCAT('. Fee Rs. ', CAST(@Net AS VARCHAR(20)), ', receipt ', @ReceiptNo) ELSE '. No fee' END;

    IF @IsRenewal = 1
    BEGIN
        -- Next card: the renewal itself, carrying the points of the old card forward
        SET @OldBalance = ISNULL(@OldBalance, 0);
        -- RemainingPoints (2236): the carried points are spendable on the next card, oldest-first like any credit
        INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy, RemainingPoints)
        VALUES (@CardId, @PrimaryPatientId, @BranchId, @PaymentHeaderId, @ReceiptNo, 'RENEW', @OldBalance, @Net,
                CASE WHEN @OldBalance > 0 THEN DATEADD(DAY, @PointsExpiryDays, @Today) END, @OldBalance,
                CONCAT('Card ', @CardNo, ' issued in renewal of card ', @OldCardNo, ' on plan ', @PlanName, ', valid ', @ValidText,
                       CASE WHEN @OldBalance > 0 THEN CONCAT('. ', CAST(@OldBalance AS VARCHAR(20)), ' points carried forward') ELSE '' END, @FeeText),
                @UserId, CASE WHEN @OldBalance > 0 THEN @OldBalance END);
        UPDATE dbo.MembershipCard SET PointsBalance = @OldBalance WHERE CardId = @CardId;

        -- Old card: closed as Renewed, its points moved out
        INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, TxnType, Points, Amount, BalanceAfter, Narration, CreatedBy)
        VALUES (@RenewFromCardId, @PrimaryPatientId, @BranchId, 'RENEW', -@OldBalance, 0, 0,
                CONCAT('Renewed as card ', @CardNo, CASE WHEN @OldBalance > 0 THEN CONCAT('. ', CAST(@OldBalance AS VARCHAR(20)), ' points carried forward to it') ELSE '' END), @UserId);
        -- nothing is left to spend or expire on the old card: its credits moved to the next card
        UPDATE dbo.MembershipLedger SET RemainingPoints = 0 WHERE CardId = @RenewFromCardId AND RemainingPoints > 0;
        UPDATE dbo.MembershipCard
        SET Status = 'Renewed', StatusReason = CONCAT('Renewed as card ', @CardNo), PointsBalance = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE CardId = @RenewFromCardId;
        EXEC dbo.usp_Membership_SyncPatientTotals @CardId = @CardId;
    END
    ELSE
    BEGIN
        -- Fresh issue: the issue itself, then the welcome points (if the plan gives any)
        INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy)
        VALUES (@CardId, @PrimaryPatientId, @BranchId, @PaymentHeaderId, @ReceiptNo, 'ISSUE', 0, @Net, NULL, 0,
                CONCAT('Card ', @CardNo, ' issued on plan ', @PlanName, ', valid ', @ValidText, @FeeText), @UserId);

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
    END

    COMMIT TRANSACTION;

    SELECT @CardId AS CardId, @CardNo AS CardNo, @ReceiptNo AS ReceiptNo, @PaymentHeaderId AS PaymentHeaderId, @Net AS FeeAmount;
END
GO


-- Result 1: the card with its plan, primary member, issuing branch and renewal links. Result 2: members.
-- Result 3: card ledger (newest first). Result 4: accounting vouchers of the card, one row per debit / credit line.
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipCard_GetById
    @CardId    INT,
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT c.CardId, c.CompanyId, c.CardNo, c.PlanId, p.PlanCode, p.PlanName, p.PlanType, p.MaxMembers, p.Terms, p.FreeHomeCollection,
           c.IssueBranchId, b.BranchName AS IssueBranchName, c.PrimaryPatientId, pm.PatientCode,
           LTRIM(RTRIM(CONCAT(pm.Salutation + ' ', pm.FirstName, ' ', pm.LastName))) AS PatientName,
           pm.PhoneNumber, pm.EmailId, pm.Gender, pm.DateOfBirth,
           c.ValidFrom, c.ValidTo, CAST(CASE WHEN c.ValidTo >= '99990101' THEN 1 ELSE 0 END AS BIT) AS IsLifetime,
           CASE WHEN c.Status = 'Active' AND c.ValidTo < @Today THEN 'Expired' ELSE c.Status END AS Status, c.StatusReason,
           c.FeeAmount, c.FeePaymentHeaderId, c.ReceiptNo, c.PointsBalance, c.Remarks,
           c.PrintCount, c.LastPrintedOn, c.WhatsAppSentOn, c.EmailSentOn, c.CreatedDate,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS IssuedByName,
           (SELECT TOP 1 pmm.MethodName FROM dbo.PaymentDetail pd INNER JOIN dbo.PaymentMethodMaster pmm ON pmm.PaymentMethodId = pd.PaymentMethodId
            WHERE pd.PaymentHeaderId = c.FeePaymentHeaderId AND pd.IsActive = 1) AS PaymentMethodName,
           c.RenewedFromCardId, prev.CardNo AS RenewedFromCardNo, nxt.CardId AS RenewedToCardId, nxt.CardNo AS RenewedToCardNo
    FROM dbo.MembershipCard c
    INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
    INNER JOIN dbo.PatientMaster pm ON pm.PatientId = c.PrimaryPatientId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.IssueBranchId
    LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
    LEFT JOIN dbo.MembershipCard prev ON prev.CardId = c.RenewedFromCardId
    OUTER APPLY (SELECT TOP 1 n.CardId, n.CardNo FROM dbo.MembershipCard n WHERE n.RenewedFromCardId = c.CardId ORDER BY n.CardId DESC) nxt
    WHERE c.CardId = @CardId AND c.CompanyId = @CompanyId;

    SELECT m.CardMemberId, m.PatientId, pm.PatientCode, LTRIM(RTRIM(CONCAT(pm.FirstName, ' ', pm.LastName))) AS PatientName,
           pm.PhoneNumber, pm.Gender, pm.DateOfBirth, m.Relation, m.IsPrimary, m.CreatedDate
    FROM dbo.MembershipCardMember m
    INNER JOIN dbo.MembershipCard c ON c.CardId = m.CardId AND c.CompanyId = @CompanyId
    INNER JOIN dbo.PatientMaster pm ON pm.PatientId = m.PatientId
    WHERE m.CardId = @CardId AND m.IsActive = 1
    ORDER BY m.IsPrimary DESC, m.CardMemberId;

    SELECT l.LedgerId, l.TxnType, l.Points, l.Amount, l.ExpiresOn, l.BalanceAfter, l.ReceiptNo, l.Narration, l.CreatedDate,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS CreatedByName
    FROM dbo.MembershipLedger l
    INNER JOIN dbo.MembershipCard c ON c.CardId = l.CardId AND c.CompanyId = @CompanyId
    LEFT JOIN dbo.Users u ON u.Id = l.CreatedBy
    WHERE l.CardId = @CardId
    ORDER BY l.LedgerId DESC;

    SELECT t.TransactionId, t.VoucherNo, vt.VoucherTypeName, t.TransactionDate, t.ReferenceType, lm.LedgerName,
           d.DebitAmount, d.CreditAmount, t.Narration
    FROM dbo.Acc_LedgerTransaction t
    INNER JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId
    INNER JOIN dbo.Acc_LedgerMaster lm ON lm.LedgerId = d.LedgerId
    LEFT JOIN dbo.Acc_VoucherType vt ON vt.VoucherTypeId = t.VoucherTypeId
    WHERE t.CompanyId = @CompanyId AND t.IsActive = 1
      AND (   (t.ReferenceType IN ('MEM_CARD', 'MEM_RECEIPT') AND t.ReferenceId = @CardId)
           -- 2237: points earned / taken back / expired (per history row of this card)
           OR (t.ReferenceType IN ('MEM_EARN', 'MEM_REVERSE', 'MEM_EXPIRE')
               AND t.ReferenceId IN (SELECT CAST(l.LedgerId AS INT) FROM dbo.MembershipLedger l WHERE l.CardId = @CardId))
           -- points used as payment on a bill (and given back): the POINTS payment lines of this card
           OR (t.ReferenceType = 'LAB_RECEIPT'
               AND t.ReferenceId IN (SELECT l.PaymentDetailId FROM dbo.MembershipLedger l WHERE l.CardId = @CardId AND l.PaymentDetailId IS NOT NULL)))
    ORDER BY t.TransactionId, d.TransactionDetailId;
END
GO

PRINT '2241_membership_card_issue_and_detail_merged.sql applied.';
GO
