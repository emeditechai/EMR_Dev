-- ============================================================================
-- Migration: 2225_membership_lifetime_and_renewal.sql
-- Description:
--   Membership card - lifetime plans and renewal.
--   1. MembershipPlan.IsLifetime: a card of a lifetime plan never expires (ValidTo = 9999-12-31)
--      and is never renewed.
--   2. Renewal of every other card: usp_Api_MembershipCard_Issue takes @RenewFromCardId and issues
--      the NEXT card (new number, MembershipCard.RenewedFromCardId = the old card) on the same or
--      another plan, with the same members. The fee is posted exactly like a fresh issue (payment
--      tables + accounting ledger). The points balance is carried forward to the next card and the
--      old card becomes 'Renewed'. Days left on the old card are kept: the next card runs
--      from today to (old expiry + plan validity).
--   3. Hospital Settings > MembershipRenewalWindowDays (default 30): a card can be renewed from
--      this many days before it expires, and any time after.
--   4. Card status 'Renewed', ledger type 'RENEW', authorization control RENEW on MASTER.MEMBERSHIPCARDS.
--   Run after 2224.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Columns and constraints ------------------------------------------------------
IF COL_LENGTH('dbo.MembershipPlan', 'IsLifetime') IS NULL
    ALTER TABLE dbo.MembershipPlan ADD IsLifetime BIT NOT NULL CONSTRAINT DF_MembershipPlan_IsLifetime DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipRenewalWindowDays') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipRenewalWindowDays INT NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipRenewalWindowDays DEFAULT (30);
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_MembershipCard_Status' AND definition NOT LIKE '%Renewed%')
    ALTER TABLE dbo.MembershipCard DROP CONSTRAINT CK_MembershipCard_Status;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_MembershipCard_Status')
    ALTER TABLE dbo.MembershipCard WITH CHECK ADD CONSTRAINT CK_MembershipCard_Status
        CHECK (Status IN ('Active', 'Blocked', 'Cancelled', 'Renewed'));
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_MembershipLedger_TxnType' AND definition NOT LIKE '%RENEW%')
    ALTER TABLE dbo.MembershipLedger DROP CONSTRAINT CK_MembershipLedger_TxnType;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_MembershipLedger_TxnType')
    ALTER TABLE dbo.MembershipLedger WITH CHECK ADD CONSTRAINT CK_MembershipLedger_TxnType
        CHECK (TxnType IN ('ISSUE', 'RENEW', 'EARN', 'REDEEM', 'EXPIRE', 'REVERSE', 'ADJUST', 'DISCOUNT', 'MEMBER', 'STATUS'));
GO

-- 2. Membership Plan master (IsLifetime) -------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipPlan_GetList
    @CompanyId INT,
    @Status    BIT = NULL,
    @Search    NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');

    SELECT p.PlanId, p.PlanCode, p.PlanName, p.PlanType, p.CardFee, p.GstPercent, p.ValidityDays, p.IsLifetime, p.MaxMembers,
           p.MinAge, p.WelcomePoints, p.PointsEarnPercent, p.IsActive,
           (SELECT COUNT(1) FROM dbo.MembershipPlanBenefit b WHERE b.PlanId = p.PlanId AND b.IsActive = 1) AS BenefitCount,
           (SELECT COUNT(1) FROM dbo.MembershipCard c WHERE c.PlanId = p.PlanId) AS CardsIssued
    FROM dbo.MembershipPlan p
    WHERE p.CompanyId = @CompanyId AND p.IsDeleted = 0
      AND (@Status IS NULL OR p.IsActive = @Status)
      AND (@Search IS NULL OR p.PlanName LIKE '%' + @Search + '%' OR p.PlanCode LIKE '%' + @Search + '%')
    ORDER BY p.IsActive DESC, p.PlanName;
END
GO

-- Result 1: the plan. Result 2: its benefit rules with the scope name.
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipPlan_GetById
    @PlanId    INT,
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.PlanId, p.CompanyId, p.PlanCode, p.PlanName, p.PlanType, p.CardFee, p.GstPercent, p.ValidityDays, p.IsLifetime, p.MaxMembers,
           p.MinAge, p.WelcomePoints, p.PointsEarnPercent, p.PointValue, p.MaxRedeemPercent, p.PointsExpiryDays,
           p.FreeHomeCollection, p.Terms, p.IsActive, p.CreatedDate, p.ModifiedDate,
           (SELECT COUNT(1) FROM dbo.MembershipCard c WHERE c.PlanId = p.PlanId) AS CardsIssued
    FROM dbo.MembershipPlan p
    WHERE p.PlanId = @PlanId AND p.CompanyId = @CompanyId AND p.IsDeleted = 0;

    SELECT b.BenefitId, b.Scope, b.ScopeRefId, b.DiscountFlag, b.DiscountValue, b.IsExcluded, b.FreeQuantity,
           CASE b.Scope WHEN 'All' THEN N'All tests'
                        WHEN 'Department' THEN d.DeptName
                        WHEN 'Category' THEN c.Category_Name
                        ELSE CONCAT(b.Scope, N' #', b.ScopeRefId) END AS ScopeName
    FROM dbo.MembershipPlanBenefit b
    INNER JOIN dbo.MembershipPlan p ON p.PlanId = b.PlanId AND p.CompanyId = @CompanyId
    LEFT JOIN dbo.DepartmentMaster d ON b.Scope = 'Department' AND d.DeptId = b.ScopeRefId
    LEFT JOIN dbo.LabTestCategoryMaster c ON b.Scope = 'Category' AND c.Category_ID = b.ScopeRefId
    WHERE b.PlanId = @PlanId AND b.IsActive = 1
    ORDER BY CASE b.Scope WHEN 'All' THEN 0 WHEN 'Department' THEN 1 WHEN 'Category' THEN 2 ELSE 3 END, b.BenefitId;
END
GO

-- @PlanId = 0 creates (plan code generated per company: MP0001...), otherwise updates.
-- @IsLifetime = 1: cards of the plan never expire; @ValidityDays is then not used (kept at its default).
-- @BenefitsJson: [{"scope":"All|Department|Category","scopeRefId":1,"discountFlag":"P|A","discountValue":10,"isExcluded":false,"freeQuantity":null}]
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipPlan_Save
    @PlanId             INT,
    @CompanyId          INT,
    @PlanName           NVARCHAR(150),
    @PlanType           VARCHAR(20),
    @CardFee            DECIMAL(10,2),
    @GstPercent         DECIMAL(5,2) = NULL,
    @ValidityDays       INT,
    @MaxMembers         INT,
    @MinAge             INT = NULL,
    @WelcomePoints      DECIMAL(12,2) = 0,
    @PointsEarnPercent  DECIMAL(5,2) = 0,
    @PointValue         DECIMAL(10,2) = 1,
    @MaxRedeemPercent   DECIMAL(5,2) = 0,
    @PointsExpiryDays   INT = 365,
    @FreeHomeCollection BIT = 0,
    @Terms              NVARCHAR(1000) = NULL,
    @IsActive           BIT = 1,
    @BenefitsJson       NVARCHAR(MAX) = NULL,
    @UserId             INT = NULL,
    @IsLifetime         BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @IsLifetime = ISNULL(@IsLifetime, 0);
    IF @IsLifetime = 1 AND ISNULL(@ValidityDays, 0) < 1 SET @ValidityDays = 365;

    SET @PlanName = LTRIM(RTRIM(@PlanName));
    IF @PlanName IS NULL OR @PlanName = '' THROW 51001, 'Plan name is required.', 1;
    IF @PlanType NOT IN ('Individual', 'Family', 'Senior', 'Corporate') THROW 51002, 'Plan type is not valid.', 1;
    IF @CardFee < 0 THROW 51003, 'Card fee cannot be negative.', 1;
    IF @GstPercent IS NOT NULL AND (@GstPercent < 0 OR @GstPercent > 28) THROW 51004, 'GST must be between 0 and 28 percent.', 1;
    IF @ValidityDays < 1 OR @ValidityDays > 36500 THROW 51005, 'Validity must be between 1 and 36500 days.', 1;
    IF @PlanType IN ('Individual', 'Senior') SET @MaxMembers = 1;
    IF @MaxMembers < 1 OR @MaxMembers > 20 THROW 51006, 'Maximum members must be between 1 and 20.', 1;
    IF @PlanType IN ('Family', 'Corporate') AND @MaxMembers < 2 THROW 51007, 'A family or corporate plan needs at least 2 members.', 1;
    IF @MinAge IS NOT NULL AND (@MinAge < 0 OR @MinAge > 120) THROW 51008, 'Minimum age must be between 0 and 120.', 1;
    IF @PointsEarnPercent < 0 OR @PointsEarnPercent > 100 OR @MaxRedeemPercent < 0 OR @MaxRedeemPercent > 100
        THROW 51009, 'Points earn and redemption percentages must be between 0 and 100.', 1;
    IF @WelcomePoints < 0 OR @PointValue < 0 OR @PointsExpiryDays < 1 THROW 51010, 'Points settings are not valid.', 1;

    IF EXISTS (SELECT 1 FROM dbo.MembershipPlan
               WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND PlanName = @PlanName AND PlanId <> ISNULL(@PlanId, 0))
        THROW 51011, 'A membership plan with this name already exists.', 1;

    DECLARE @Benefits TABLE (Scope VARCHAR(20), ScopeRefId INT NULL, DiscountFlag CHAR(1), DiscountValue DECIMAL(10,2), IsExcluded BIT, FreeQuantity INT NULL);
    IF NULLIF(LTRIM(RTRIM(@BenefitsJson)), '') IS NOT NULL
        INSERT INTO @Benefits (Scope, ScopeRefId, DiscountFlag, DiscountValue, IsExcluded, FreeQuantity)
        SELECT j.scope, CASE WHEN j.scope = 'All' THEN NULL ELSE j.scopeRefId END, ISNULL(j.discountFlag, 'P'),
               CASE WHEN ISNULL(j.isExcluded, 0) = 1 THEN 0 ELSE ISNULL(j.discountValue, 0) END, ISNULL(j.isExcluded, 0), j.freeQuantity
        FROM OPENJSON(@BenefitsJson)
             WITH (scope VARCHAR(20) '$.scope', scopeRefId INT '$.scopeRefId', discountFlag CHAR(1) '$.discountFlag',
                   discountValue DECIMAL(10,2) '$.discountValue', isExcluded BIT '$.isExcluded', freeQuantity INT '$.freeQuantity') j;

    IF EXISTS (SELECT 1 FROM @Benefits WHERE Scope NOT IN ('All', 'Department', 'Category', 'Test', 'Package') OR Scope IS NULL)
        THROW 51012, 'A benefit rule has an invalid scope.', 1;
    IF EXISTS (SELECT 1 FROM @Benefits WHERE Scope <> 'All' AND ISNULL(ScopeRefId, 0) <= 0)
        THROW 51013, 'Pick the department or category for every benefit rule.', 1;
    IF EXISTS (SELECT 1 FROM @Benefits WHERE DiscountFlag NOT IN ('P', 'A') OR DiscountValue < 0 OR (DiscountFlag = 'P' AND DiscountValue > 100))
        THROW 51014, 'A benefit discount must be 0 to 100 percent, or an amount of zero or more.', 1;
    IF EXISTS (SELECT 1 FROM @Benefits WHERE IsExcluded = 0 AND DiscountValue = 0 AND ISNULL(FreeQuantity, 0) = 0)
        THROW 51015, 'Every benefit rule needs a discount, a free quantity, or to be marked excluded.', 1;
    IF EXISTS (SELECT 1 FROM @Benefits GROUP BY Scope, ISNULL(ScopeRefId, 0) HAVING COUNT(1) > 1)
        THROW 51016, 'The same department or category appears in more than one benefit rule.', 1;

    BEGIN TRANSACTION;

    IF ISNULL(@PlanId, 0) = 0
    BEGIN
        DECLARE @Next INT;
        SELECT @Next = ISNULL(MAX(TRY_CAST(SUBSTRING(PlanCode, 3, 18) AS INT)), 0) + 1
        FROM dbo.MembershipPlan WITH (UPDLOCK, HOLDLOCK)
        WHERE CompanyId = @CompanyId AND PlanCode LIKE 'MP%';

        INSERT INTO dbo.MembershipPlan
            (CompanyId, PlanCode, PlanName, PlanType, CardFee, GstPercent, ValidityDays, IsLifetime, MaxMembers, MinAge, WelcomePoints,
             PointsEarnPercent, PointValue, MaxRedeemPercent, PointsExpiryDays, FreeHomeCollection, Terms, IsActive, CreatedBy)
        VALUES
            (@CompanyId, 'MP' + RIGHT('0000' + CAST(@Next AS VARCHAR(10)), 4), @PlanName, @PlanType, @CardFee, NULLIF(@GstPercent, 0),
             @ValidityDays, @IsLifetime, @MaxMembers, @MinAge, @WelcomePoints, @PointsEarnPercent, @PointValue, @MaxRedeemPercent, @PointsExpiryDays,
             @FreeHomeCollection, NULLIF(LTRIM(RTRIM(@Terms)), ''), @IsActive, @UserId);
        SET @PlanId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.MembershipPlan
        SET PlanName = @PlanName, PlanType = @PlanType, CardFee = @CardFee, GstPercent = NULLIF(@GstPercent, 0),
            ValidityDays = @ValidityDays, IsLifetime = @IsLifetime, MaxMembers = @MaxMembers, MinAge = @MinAge, WelcomePoints = @WelcomePoints,
            PointsEarnPercent = @PointsEarnPercent, PointValue = @PointValue, MaxRedeemPercent = @MaxRedeemPercent,
            PointsExpiryDays = @PointsExpiryDays, FreeHomeCollection = @FreeHomeCollection,
            Terms = NULLIF(LTRIM(RTRIM(@Terms)), ''), IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE PlanId = @PlanId AND CompanyId = @CompanyId AND IsDeleted = 0;
        IF @@ROWCOUNT = 0 THROW 51017, 'Membership plan not found.', 1;
    END

    -- Benefit rules are replaced as a set; the old rows stay (inactive) for history
    UPDATE dbo.MembershipPlanBenefit SET IsActive = 0 WHERE PlanId = @PlanId AND IsActive = 1;
    INSERT INTO dbo.MembershipPlanBenefit (PlanId, Scope, ScopeRefId, DiscountFlag, DiscountValue, IsExcluded, FreeQuantity, CreatedBy)
    SELECT @PlanId, Scope, ScopeRefId, DiscountFlag, DiscountValue, IsExcluded, NULLIF(FreeQuantity, 0), @UserId FROM @Benefits;

    COMMIT TRANSACTION;
    SELECT @PlanId AS PlanId;
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
    IF @IsRenewal = 1
        INSERT INTO @Members (PatientId, Relation, IsPrimary)
        SELECT PatientId, Relation, IsPrimary FROM dbo.MembershipCardMember WHERE CardId = @RenewFromCardId AND IsActive = 1;
    ELSE
    BEGIN
        INSERT INTO @Members VALUES (@PrimaryPatientId, N'Self', 1);
        IF NULLIF(LTRIM(RTRIM(@MembersJson)), '') IS NOT NULL
            INSERT INTO @Members (PatientId, Relation, IsPrimary)
            SELECT j.patientId, ISNULL(NULLIF(LTRIM(RTRIM(j.relation)), ''), N'Family'), 0
            FROM OPENJSON(@MembersJson) WITH (patientId INT '$.patientId', relation NVARCHAR(50) '$.relation') j
            WHERE j.patientId IS NOT NULL;
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

-- 4. Card list / detail / status (lifetime and renewal links) -------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipCard_GetList
    @CompanyId INT,
    @BranchId  INT = NULL,
    @PlanId    INT = NULL,
    @Status    VARCHAR(15) = NULL,   -- Active | Expired | Blocked | Cancelled | Renewed
    @Search    NVARCHAR(100) = NULL,
    @FromDate  DATE = NULL,
    @ToDate    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT TOP 1000
           c.CardId, c.CardNo, p.PlanName, p.PlanType,
           pm.PatientCode, LTRIM(RTRIM(CONCAT(pm.FirstName, ' ', pm.LastName))) AS PatientName, pm.PhoneNumber,
           (SELECT COUNT(1) FROM dbo.MembershipCardMember m WHERE m.CardId = c.CardId AND m.IsActive = 1) AS MemberCount,
           c.ValidFrom, c.ValidTo, CAST(CASE WHEN c.ValidTo >= '99990101' THEN 1 ELSE 0 END AS BIT) AS IsLifetime,
           c.FeeAmount, c.ReceiptNo, c.PointsBalance, b.BranchName AS IssueBranchName,
           CASE WHEN c.Status = 'Active' AND c.ValidTo < @Today THEN 'Expired' ELSE c.Status END AS Status,
           CAST(CASE WHEN c.RenewedFromCardId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsRenewal,
           c.PrintCount, c.WhatsAppSentOn, c.EmailSentOn, c.CreatedDate
    FROM dbo.MembershipCard c
    INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
    INNER JOIN dbo.PatientMaster pm ON pm.PatientId = c.PrimaryPatientId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.IssueBranchId
    WHERE c.CompanyId = @CompanyId
      AND (@BranchId IS NULL OR c.IssueBranchId = @BranchId)
      AND (@PlanId IS NULL OR c.PlanId = @PlanId)
      AND (@FromDate IS NULL OR CAST(c.CreatedDate AS DATE) >= @FromDate)
      AND (@ToDate IS NULL OR CAST(c.CreatedDate AS DATE) <= @ToDate)
      AND (@Status IS NULL OR @Status = CASE WHEN c.Status = 'Active' AND c.ValidTo < @Today THEN 'Expired' ELSE c.Status END)
      AND (@Search IS NULL OR c.CardNo LIKE '%' + @Search + '%' OR pm.PatientCode LIKE @Search + '%' OR pm.PhoneNumber LIKE @Search + '%'
           OR CONCAT(pm.FirstName, ' ', pm.LastName) LIKE '%' + @Search + '%'
           OR EXISTS (SELECT 1 FROM dbo.MembershipCardMember m INNER JOIN dbo.PatientMaster mp ON mp.PatientId = m.PatientId
                      WHERE m.CardId = c.CardId AND m.IsActive = 1
                        AND (mp.PatientCode LIKE @Search + '%' OR mp.PhoneNumber LIKE @Search + '%' OR CONCAT(mp.FirstName, ' ', mp.LastName) LIKE '%' + @Search + '%')))
    ORDER BY c.CardId DESC;
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
    WHERE t.ReferenceType IN ('MEM_CARD', 'MEM_RECEIPT') AND t.ReferenceId = @CardId AND t.CompanyId = @CompanyId AND t.IsActive = 1
    ORDER BY t.TransactionId, d.TransactionDetailId;
END
GO

-- Block a card (lost / misuse) or bring a blocked card back. Cancelled and Renewed are final.
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipCard_SetStatus
    @CardId    INT,
    @CompanyId INT,
    @BranchId  INT,
    @Status    VARCHAR(15),
    @Reason    NVARCHAR(250) = NULL,
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Status NOT IN ('Active', 'Blocked', 'Cancelled') THROW 51050, 'Card status is not valid.', 1;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), '');
    IF @Status <> 'Active' AND @Reason IS NULL THROW 51051, 'Give the reason for blocking or cancelling the card.', 1;

    DECLARE @Old VARCHAR(15), @Balance DECIMAL(12,2);
    BEGIN TRANSACTION;
    SELECT @Old = Status, @Balance = PointsBalance FROM dbo.MembershipCard WITH (UPDLOCK, HOLDLOCK) WHERE CardId = @CardId AND CompanyId = @CompanyId;
    IF @Old IS NULL THROW 51040, 'Membership card not found.', 1;
    IF @Old IN ('Cancelled', 'Renewed') THROW 51052, 'A cancelled or renewed card cannot be changed.', 1;
    IF @Old = @Status BEGIN COMMIT TRANSACTION; RETURN; END

    UPDATE dbo.MembershipCard SET Status = @Status, StatusReason = @Reason, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE CardId = @CardId;
    INSERT INTO dbo.MembershipLedger (CardId, BranchId, TxnType, Points, Amount, BalanceAfter, Narration, CreatedBy)
    VALUES (@CardId, @BranchId, 'STATUS', 0, 0, @Balance, LEFT(CONCAT('Card ', @Old, ' -> ', @Status, ISNULL('. ' + @Reason, '')), 300), @UserId);
    COMMIT TRANSACTION;
END
GO

-- 5. Authorization: Renew control on Membership Cards ----------------------------------
DECLARE @page INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.MEMBERSHIPCARDS';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'RENEW', @Title = N'Renew card', @Sort_Order = 25, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'MembershipCards', @Action = N'Renew', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT '2225_membership_lifetime_and_renewal.sql applied.';
GO
