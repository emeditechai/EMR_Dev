-- ============================================================================
-- Migration: 2228_membership_family_from_patient_master.sql
-- Description:
--   Membership card - who can be on a card comes from Patient Master, not from the card screen.
--   * Primary member = the head of a family: a patient registered with relation Self (RelationId 1).
--   * Family members = the other patients registered on the head's mobile number (PhoneNumber),
--     with a relation other than Self. Nobody else can be added.
--   * The relation stored on the card is the member's own PatientMaster.RelationId -> RelationMaster.RelationName.
--     What the screen sends is ignored.
--     usp_Api_MembershipCard_PatientSearch   heads only (by code / name / mobile), with the relation name
--     usp_Api_MembershipCard_GetFamily       the head's family, with relation and any card they are already on
--     usp_Api_MembershipCard_Issue           51032 primary is not a head; 51033 member not of the head's family
--     usp_Api_MembershipCard_AddMember       51033, relation from Patient Master
--   A renewal copies the members of the card being renewed, as before.
--   Run after 2227.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- Head-of-family lookup for the card desk: code, name or mobile; shows the card the patient is already on, if any.
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipCard_PatientSearch
    @CompanyId INT,
    @Search    NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = LTRIM(RTRIM(ISNULL(@Search, '')));
    IF LEN(@Search) < 2 BEGIN SELECT TOP 0 0 AS PatientId; RETURN; END

    SELECT TOP 20
           pm.PatientId, pm.PatientCode,
           LTRIM(RTRIM(CONCAT(pm.Salutation + ' ', pm.FirstName, ' ', pm.LastName))) AS PatientName,
           pm.PhoneNumber, pm.EmailId, pm.Gender, pm.DateOfBirth,
           DATEDIFF(YEAR, pm.DateOfBirth, GETDATE())
             - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, pm.DateOfBirth, GETDATE()), pm.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END AS Age,
           rm.RelationName,
           (SELECT COUNT(1) FROM dbo.PatientMaster f
            WHERE f.CompanyId = @CompanyId AND f.IsActive = 1 AND f.PatientId <> pm.PatientId AND ISNULL(f.RelationId, 0) <> 1
              AND NULLIF(LTRIM(RTRIM(pm.PhoneNumber)), '') IS NOT NULL AND LTRIM(RTRIM(f.PhoneNumber)) = LTRIM(RTRIM(pm.PhoneNumber))) AS FamilyCount,
           ac.CardNo AS ActiveCardNo, ac.PlanName AS ActivePlanName, ac.ValidTo AS ActiveValidTo
    FROM dbo.PatientMaster pm
    LEFT JOIN dbo.RelationMaster rm ON rm.RelationId = pm.RelationId
    OUTER APPLY (SELECT TOP 1 c.CardNo, p.PlanName, c.ValidTo
                 FROM dbo.MembershipCardMember m
                 INNER JOIN dbo.MembershipCard c ON c.CardId = m.CardId
                 INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
                 WHERE m.PatientId = pm.PatientId AND m.IsActive = 1 AND c.Status = 'Active'
                   AND c.ValidTo >= CAST(GETDATE() AS DATE) AND c.CompanyId = @CompanyId
                 ORDER BY c.ValidTo DESC) ac
    WHERE pm.CompanyId = @CompanyId AND pm.IsActive = 1
      AND pm.RelationId = 1                                   -- heads of family only
      AND (pm.PatientCode LIKE @Search + '%' OR pm.PhoneNumber LIKE @Search + '%'
           OR pm.FirstName LIKE @Search + '%' OR pm.LastName LIKE @Search + '%'
           OR CONCAT(pm.FirstName, ' ', pm.LastName) LIKE @Search + '%')
    ORDER BY pm.FirstName, pm.LastName;
END
GO

-- The family of a head: the other patients on the head's mobile number, relation other than Self.
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipCard_GetFamily
    @CompanyId INT,
    @PatientId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Phone NVARCHAR(30);
    SELECT @Phone = NULLIF(LTRIM(RTRIM(PhoneNumber)), '') FROM dbo.PatientMaster WHERE PatientId = @PatientId AND CompanyId = @CompanyId;

    SELECT pm.PatientId, pm.PatientCode,
           LTRIM(RTRIM(CONCAT(pm.Salutation + ' ', pm.FirstName, ' ', pm.LastName))) AS PatientName,
           pm.PhoneNumber, pm.EmailId, pm.Gender, pm.DateOfBirth,
           DATEDIFF(YEAR, pm.DateOfBirth, GETDATE())
             - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, pm.DateOfBirth, GETDATE()), pm.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END AS Age,
           ISNULL(rm.RelationName, N'Family') AS RelationName, CAST(0 AS INT) AS FamilyCount,
           ac.CardNo AS ActiveCardNo, ac.PlanName AS ActivePlanName, ac.ValidTo AS ActiveValidTo
    FROM dbo.PatientMaster pm
    LEFT JOIN dbo.RelationMaster rm ON rm.RelationId = pm.RelationId
    OUTER APPLY (SELECT TOP 1 c.CardNo, p.PlanName, c.ValidTo
                 FROM dbo.MembershipCardMember m
                 INNER JOIN dbo.MembershipCard c ON c.CardId = m.CardId
                 INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
                 WHERE m.PatientId = pm.PatientId AND m.IsActive = 1 AND c.Status = 'Active'
                   AND c.ValidTo >= CAST(GETDATE() AS DATE) AND c.CompanyId = @CompanyId
                 ORDER BY c.ValidTo DESC) ac
    WHERE @Phone IS NOT NULL
      AND pm.CompanyId = @CompanyId AND pm.IsActive = 1
      AND pm.PatientId <> @PatientId
      AND LTRIM(RTRIM(pm.PhoneNumber)) = @Phone
      AND ISNULL(pm.RelationId, 0) <> 1
    ORDER BY ISNULL(rm.SortOrder, 999), pm.FirstName;
END
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
        INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy)
        VALUES (@CardId, @PrimaryPatientId, @BranchId, @PaymentHeaderId, @ReceiptNo, 'RENEW', @OldBalance, @Net,
                CASE WHEN @OldBalance > 0 THEN DATEADD(DAY, @PointsExpiryDays, @Today) END, @OldBalance,
                CONCAT('Card ', @CardNo, ' issued in renewal of card ', @OldCardNo, ' on plan ', @PlanName, ', valid ', @ValidText,
                       CASE WHEN @OldBalance > 0 THEN CONCAT('. ', CAST(@OldBalance AS VARCHAR(20)), ' points carried forward') ELSE '' END, @FeeText),
                @UserId);
        UPDATE dbo.MembershipCard SET PointsBalance = @OldBalance WHERE CardId = @CardId;

        -- Old card: closed as Renewed, its points moved out
        INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, TxnType, Points, Amount, BalanceAfter, Narration, CreatedBy)
        VALUES (@RenewFromCardId, @PrimaryPatientId, @BranchId, 'RENEW', -@OldBalance, 0, 0,
                CONCAT('Renewed as card ', @CardNo, CASE WHEN @OldBalance > 0 THEN CONCAT('. ', CAST(@OldBalance AS VARCHAR(20)), ' points carried forward to it') ELSE '' END), @UserId);
        UPDATE dbo.MembershipCard
        SET Status = 'Renewed', StatusReason = CONCAT('Renewed as card ', @CardNo), PointsBalance = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE CardId = @RenewFromCardId;
    END
    ELSE
    BEGIN
        -- Fresh issue: the issue itself, then the welcome points (if the plan gives any)
        INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy)
        VALUES (@CardId, @PrimaryPatientId, @BranchId, @PaymentHeaderId, @ReceiptNo, 'ISSUE', 0, @Net, NULL, 0,
                CONCAT('Card ', @CardNo, ' issued on plan ', @PlanName, ', valid ', @ValidText, @FeeText), @UserId);

        IF @WelcomePoints > 0
        BEGIN
            INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy)
            VALUES (@CardId, @PrimaryPatientId, @BranchId, NULL, NULL, 'EARN', @WelcomePoints, 0, DATEADD(DAY, @PointsExpiryDays, @ValidFrom), @WelcomePoints,
                    'Welcome points on card issue', @UserId);
            UPDATE dbo.MembershipCard SET PointsBalance = @WelcomePoints WHERE CardId = @CardId;
        END
    END

    COMMIT TRANSACTION;

    SELECT @CardId AS CardId, @CardNo AS CardNo, @ReceiptNo AS ReceiptNo, @PaymentHeaderId AS PaymentHeaderId, @Net AS FeeAmount;
END
GO


CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipCard_AddMember
    @CardId    INT,
    @CompanyId INT,
    @BranchId  INT,
    @PatientId INT,
    @Relation  NVARCHAR(50),
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PlanId INT, @MaxMembers INT, @Status VARCHAR(15), @ValidTo DATE, @CardNo NVARCHAR(30), @Balance DECIMAL(12,2), @HeadPhone NVARCHAR(30);
    BEGIN TRANSACTION;

    SELECT @PlanId = c.PlanId, @MaxMembers = p.MaxMembers, @Status = c.Status, @ValidTo = c.ValidTo, @CardNo = c.CardNo, @Balance = c.PointsBalance,
           @HeadPhone = NULLIF(LTRIM(RTRIM(hp.PhoneNumber)), '')
    FROM dbo.MembershipCard c WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
    INNER JOIN dbo.PatientMaster hp ON hp.PatientId = c.PrimaryPatientId
    WHERE c.CardId = @CardId AND c.CompanyId = @CompanyId;

    IF @PlanId IS NULL THROW 51040, 'Membership card not found.', 1;
    IF @Status <> 'Active' OR @ValidTo < CAST(GETDATE() AS DATE) THROW 51041, 'Members can be added only to an active card.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.PatientMaster WHERE PatientId = @PatientId AND CompanyId = @CompanyId AND IsActive = 1)
        THROW 51028, 'A family member is not a registered patient of this company.', 1;
    IF EXISTS (SELECT 1 FROM dbo.MembershipCardMember WHERE CardId = @CardId AND PatientId = @PatientId AND IsActive = 1)
        THROW 51042, 'This patient is already a member of the card.', 1;
    IF (SELECT COUNT(1) FROM dbo.MembershipCardMember WHERE CardId = @CardId AND IsActive = 1) >= @MaxMembers
    BEGIN
        DECLARE @MaxMsg NVARCHAR(200) = CONCAT('This plan covers at most ', @MaxMembers, ' member(s).');
        THROW 51027, @MaxMsg, 1;
    END
    IF EXISTS (SELECT 1 FROM dbo.MembershipCardMember cm
               INNER JOIN dbo.MembershipCard c ON c.CardId = cm.CardId AND c.PlanId = @PlanId AND c.Status = 'Active' AND c.ValidTo >= CAST(GETDATE() AS DATE)
               WHERE cm.PatientId = @PatientId AND cm.IsActive = 1 AND cm.CardId <> @CardId)
        THROW 51043, 'This patient is already on another active card of the same plan.', 1;

    -- Family = patients registered on the head's mobile number, other than a second head (Self).
    -- The relation is the one on the member's own patient record; @Relation from the screen is not used.
    IF NOT EXISTS (SELECT 1 FROM dbo.PatientMaster fm
                   WHERE fm.PatientId = @PatientId AND @HeadPhone IS NOT NULL
                     AND LTRIM(RTRIM(fm.PhoneNumber)) = @HeadPhone AND ISNULL(fm.RelationId, 0) <> 1)
        THROW 51033, 'A family member must be a patient registered on the primary member''s mobile number, with a relation other than Self.', 1;
    SELECT @Relation = ISNULL(rm.RelationName, N'Family')
    FROM dbo.PatientMaster fm LEFT JOIN dbo.RelationMaster rm ON rm.RelationId = fm.RelationId
    WHERE fm.PatientId = @PatientId;
    INSERT INTO dbo.MembershipCardMember (CardId, PatientId, Relation, IsPrimary, CreatedBy) VALUES (@CardId, @PatientId, @Relation, 0, @UserId);

    INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, TxnType, Points, Amount, BalanceAfter, Narration, CreatedBy)
    SELECT @CardId, @PatientId, @BranchId, 'MEMBER', 0, 0, @Balance,
           CONCAT('Member added: ', LTRIM(RTRIM(CONCAT(pm.FirstName, ' ', pm.LastName))), ' (', @Relation, ')'), @UserId
    FROM dbo.PatientMaster pm WHERE pm.PatientId = @PatientId;

    UPDATE dbo.MembershipCard SET ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE CardId = @CardId;
    COMMIT TRANSACTION;
END
GO

-- Authorization: the family lookup is part of opening the card screens
DECLARE @page INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.MEMBERSHIPCARDS';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'MembershipCards', @Action = N'FamilyMembers', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT '2228_membership_family_from_patient_master.sql applied.';
GO
