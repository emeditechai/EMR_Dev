-- ============================================================================
-- Migration: 2241_membership_benefits_b2c_lab.sql
-- Description: Membership plan configuration applied on B2C LAB bills.
--   * Free Home Collection = Yes: Home Collection misc charges (Misc Charges Master type 'Home Collection') of a member's
--     bill are free - a 100 percent membership discount on those lines (their GST becomes 0).
--   * Benefit rules: tests of a member's bill get the plan's discount - Category rule, else Department rule, else
--     "All tests"; Excluded = none; % of the price, or Rs off each test (never more than its price). The rate card's
--     "Discount Allowed" still decides which tests can be discounted at all; packages get no membership discount.
--     When a benefit rule gives a discount, no manual discount can be added to that bill.
--   * The member: the bill's patient is an active member of an Active card, valid today, on an active plan.
--   * Stored: PaymentHeader.MembershipDiscountAmount / MembershipTestDiscount, PaymentLineItem.MembershipDiscountAmount,
--     LabOrderMiscCharge.MembershipDiscountAmount; the line discounts include it. Ledger: Dr Membership Discount /
--     Cr receivable (reference LAB_MEMDISC), kept in step by usp_Ledger_PostBillMoney ADJUST; the manual discount
--     keeps posting to Discount Allowed.
--   * Points expiry: points past their expiry date are expired before the card is shown or points are redeemed
--     (not only by the 6-hourly job), and are never consumed; Points Expire After must be 1 to 3650 days.
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.PaymentHeader', 'MembershipDiscountAmount') IS NULL
    ALTER TABLE dbo.PaymentHeader ADD MembershipDiscountAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_PaymentHeader_MemDisc DEFAULT 0;
GO
IF COL_LENGTH('dbo.PaymentHeader', 'MembershipTestDiscount') IS NULL
    ALTER TABLE dbo.PaymentHeader ADD MembershipTestDiscount DECIMAL(18,2) NOT NULL CONSTRAINT DF_PaymentHeader_MemTestDisc DEFAULT 0;
GO
IF COL_LENGTH('dbo.PaymentLineItem', 'MembershipDiscountAmount') IS NULL
    ALTER TABLE dbo.PaymentLineItem ADD MembershipDiscountAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_PaymentLineItem_MemDisc DEFAULT 0;
GO
IF COL_LENGTH('dbo.LabOrderMiscCharge', 'MembershipDiscountAmount') IS NULL
    ALTER TABLE dbo.LabOrderMiscCharge ADD MembershipDiscountAmount DECIMAL(12,2) NOT NULL CONSTRAINT DF_LabOrderMiscCharge_MemDisc DEFAULT 0;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Discount')
    INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
    SELECT TOP 1 'Membership Discount', LedgerGroupId, 0, 'Dr', 1, GETDATE() FROM dbo.Acc_LedgerGroup
    WHERE GroupName IN ('Indirect Expenses', 'Direct Expenses') ORDER BY CASE GroupName WHEN 'Indirect Expenses' THEN 0 ELSE 1 END;
GO

-- The membership benefits of a B2C LAB bill. @LinesJson: [{ "key": "...", "kind": "T" | "P" | "M", "itemId": n, "price": n }]
--   T = test / profile (itemId = InvestigationId), P = package, M = misc charge (itemId = Misc_Charge_ID).
-- RS1: the card (no row = not a member); RS2: every line with its membership discount and the rule that gave it.
CREATE OR ALTER PROCEDURE dbo.usp_Membership_LabBenefits
    @PatientId INT,
    @BranchId  INT,
    @LinesJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE), @CardId INT, @PlanId INT, @FreeHc BIT,
            @Company INT = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId);

    -- the bill's patient must be an active member of a live card (Active, valid today, plan active)
    SELECT TOP 1 @CardId = c.CardId, @PlanId = c.PlanId, @FreeHc = pl.FreeHomeCollection
    FROM dbo.MembershipCardMember m
    INNER JOIN dbo.MembershipCard c ON c.CardId = m.CardId AND c.Status = 'Active' AND @Today BETWEEN c.ValidFrom AND c.ValidTo
    INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId AND pl.IsActive = 1 AND ISNULL(pl.IsDeleted, 0) = 0
    WHERE m.PatientId = @PatientId AND m.IsActive = 1 AND (@Company IS NULL OR c.CompanyId = @Company)
    ORDER BY c.ValidTo DESC, c.CardId DESC;

    DECLARE @L TABLE (LineKey NVARCHAR(40), Kind CHAR(1), ItemId INT, Price DECIMAL(18,2), Discount DECIMAL(18,2) NOT NULL DEFAULT 0, RuleText NVARCHAR(200) NULL);
    INSERT INTO @L (LineKey, Kind, ItemId, Price)
    SELECT j.[key], UPPER(j.kind), j.itemId, ISNULL(j.price, 0)
    FROM OPENJSON(ISNULL(@LinesJson, '[]')) WITH ([key] NVARCHAR(40) '$.key', kind CHAR(1) '$.kind', itemId INT '$.itemId', price DECIMAL(18,2) '$.price') j;

    IF @CardId IS NOT NULL
    BEGIN
        -- Free Home Collection: the plan's Home Collection charges are free
        IF @FreeHc = 1
            UPDATE l SET Discount = l.Price, RuleText = N'Free Home Collection (membership)'
            FROM @L l INNER JOIN dbo.LabMiscChargeMaster mc ON mc.Misc_Charge_ID = l.ItemId AND mc.Charge_Type = 'Home Collection'
            WHERE l.Kind = 'M' AND l.Price > 0;

        -- Benefit rules on tests the rate card lets be discounted: category rule, else department rule, else "All tests"
        ;WITH t AS (
            SELECT l.LineKey, l.Price, lim.Category_ID, lim.Department_ID
            FROM @L l
            INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = l.ItemId
            WHERE l.Kind = 'T' AND l.Price > 0
              AND EXISTS (SELECT 1 FROM dbo.LabRateCardMaster m
                          INNER JOIN dbo.LabRateCardDetail dd ON dd.RateCard_ID = m.RateCard_ID AND dd.IsDeleted = 0
                          WHERE m.Branch_ID = @BranchId AND m.Rate_Type = 'B2C' AND m.Status = 1 AND m.IsDeleted = 0
                            AND @Today BETWEEN m.Effective_From AND m.Effective_To
                            AND dd.Item_ID = l.ItemId
                            AND dd.Item_Type = CASE WHEN lim.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END
                            AND ISNULL(dd.Is_Discount_Allowed, 0) = 1)),
        r AS (
            SELECT t.LineKey, t.Price, x.DiscountFlag, x.DiscountValue, x.IsExcluded, x.Scope, x.ScopeName
            FROM t
            OUTER APPLY (SELECT TOP 1 b.DiscountFlag, b.DiscountValue, b.IsExcluded, b.Scope,
                                CASE b.Scope WHEN 'Category' THEN (SELECT Category_Name FROM dbo.LabTestCategoryMaster WHERE Category_ID = b.ScopeRefId)
                                             WHEN 'Department' THEN (SELECT DeptName FROM dbo.DepartmentMaster WHERE DeptId = b.ScopeRefId)
                                             ELSE N'All tests' END AS ScopeName
                         FROM dbo.MembershipPlanBenefit b
                         WHERE b.PlanId = @PlanId AND b.IsActive = 1
                           AND ((b.Scope = 'Category' AND b.ScopeRefId = t.Category_ID)
                             OR (b.Scope = 'Department' AND b.ScopeRefId = t.Department_ID)
                             OR b.Scope = 'All')
                         ORDER BY CASE b.Scope WHEN 'Category' THEN 0 WHEN 'Department' THEN 1 ELSE 2 END) x)
        UPDATE l SET
            Discount = CASE WHEN r.DiscountFlag IS NULL OR r.IsExcluded = 1 THEN 0
                            WHEN r.DiscountFlag = 'P' THEN ROUND(r.Price * CASE WHEN r.DiscountValue > 100 THEN 100 ELSE r.DiscountValue END / 100.0, 2)
                            ELSE CASE WHEN r.DiscountValue > r.Price THEN r.Price ELSE r.DiscountValue END END,
            RuleText = CASE WHEN r.DiscountFlag IS NULL OR r.IsExcluded = 1 THEN NULL
                            ELSE CONCAT(r.ScopeName, ' ', CASE WHEN r.DiscountFlag = 'P' THEN FORMAT(r.DiscountValue, '0.##') + '%' ELSE 'Rs ' + FORMAT(r.DiscountValue, '0.##') + ' off' END) END
        FROM @L l INNER JOIN r ON r.LineKey = l.LineKey;
    END

    SELECT c.CardId, c.CardNo, pl.PlanId, pl.PlanName, CAST(pl.FreeHomeCollection AS BIT) AS FreeHomeCollection,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.MembershipPlanBenefit b WHERE b.PlanId = pl.PlanId AND b.IsActive = 1 AND b.IsExcluded = 0) THEN 1 ELSE 0 END AS BIT) AS HasTestRules
    FROM dbo.MembershipCard c INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId
    WHERE c.CardId = @CardId;

    SELECT LineKey, Kind, ItemId, Price, Discount, RuleText FROM @L;
END;
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
    SELECT @n AS CardsExpired;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Membership_ConsumePoints
    @CardId INT,
    @Points DECIMAL(12,2),
    @PreferLedgerId BIGINT = NULL,      -- use this credit row first (reversing an earn takes back those points)
    @Taken DECIMAL(12,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Taken = 0;
    DECLARE @left DECIMAL(12,2) = @Points, @id BIGINT, @rem DECIMAL(12,2), @use DECIMAL(12,2);
    WHILE @left > 0
    BEGIN
        SET @id = NULL;
        SELECT TOP 1 @id = LedgerId, @rem = RemainingPoints
        FROM dbo.MembershipLedger WITH (UPDLOCK, ROWLOCK)
        WHERE CardId = @CardId AND RemainingPoints > 0
          AND (ExpiresOn IS NULL OR ExpiresOn >= CAST(GETDATE() AS DATE))   -- 2241: expired points are never used
        ORDER BY CASE WHEN LedgerId = @PreferLedgerId THEN 0 ELSE 1 END, ISNULL(ExpiresOn, '9999-12-31'), LedgerId;
        IF @id IS NULL BREAK;
        SET @use = CASE WHEN @rem < @left THEN @rem ELSE @left END;
        UPDATE dbo.MembershipLedger SET RemainingPoints = RemainingPoints - @use WHERE LedgerId = @id;
        SET @left -= @use; SET @Taken += @use;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Membership_CardForBilling
    @PatientId INT = NULL,
    @Phone     NVARCHAR(30) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CardId INT;
    EXEC dbo.usp_Membership_CardForPatient @PatientId = @PatientId, @Phone = @Phone, @CompanyId = @CompanyId, @CardId = @CardId OUTPUT;
    -- 2241: points past their expiry date leave the balance before it is shown
    IF @CardId IS NOT NULL EXEC dbo.usp_Membership_ExpirePoints @UserId = 1, @CardId_Only = @CardId;
    DECLARE @NextExp DATE, @NextExpPts DECIMAL(12,2);
    SELECT TOP 1 @NextExp = ExpiresOn FROM dbo.MembershipLedger WHERE CardId = @CardId AND RemainingPoints > 0 AND ExpiresOn IS NOT NULL ORDER BY ExpiresOn;
    SELECT @NextExpPts = SUM(RemainingPoints) FROM dbo.MembershipLedger WHERE CardId = @CardId AND RemainingPoints > 0 AND ExpiresOn = @NextExp;
    SELECT c.CardId, c.CardNo, c.ValidFrom, c.ValidTo, c.Status,
           pl.PlanCode, pl.PlanName, pl.PlanType,
           CAST(c.PointsBalance AS DECIMAL(12,2)) AS PointsBalance,
           CAST(ISNULL(pl.PointValue, 1) AS DECIMAL(12,2)) AS PointValue,
           CAST(ROUND(c.PointsBalance * ISNULL(pl.PointValue, 1), 2) AS DECIMAL(12,2)) AS PointsValue,
           CAST(ISNULL(pl.PointsEarnPercent, 0) AS DECIMAL(6,2)) AS PointsEarnPercent,
           CAST(ISNULL(pl.MaxRedeemPercent, 0) AS DECIMAL(6,2)) AS MaxRedeemPercent,
           CAST(ISNULL(pl.MinRedeemBillAmount, 0) AS DECIMAL(12,2)) AS MinRedeemBillAmount,
           ISNULL(pl.PointsExpiryDays, 365) AS PointsExpiryDays,
           @NextExp AS NextExpiryDate, CAST(ISNULL(@NextExpPts, 0) AS DECIMAL(12,2)) AS NextExpiryPoints,
           CAST(pl.FreeHomeCollection AS BIT) AS FreeHomeCollection,
           LTRIM(RTRIM(ISNULL(pp.FirstName, '') + ' ' + ISNULL(pp.LastName, ''))) AS PrimaryName,
           -- the OTP goes to this mobile; shown masked
           CASE WHEN LEN(LTRIM(RTRIM(pp.PhoneNumber))) >= 4 THEN REPLICATE('x', LEN(LTRIM(RTRIM(pp.PhoneNumber))) - 4) + RIGHT(LTRIM(RTRIM(pp.PhoneNumber)), 4) END AS PrimaryPhoneMasked
    FROM dbo.MembershipCard c
    INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId
    LEFT JOIN dbo.PatientMaster pp ON pp.PatientId = c.PrimaryPatientId
    WHERE c.CardId = @CardId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Membership_RedeemOtpCreate
    @CardId   INT,
    @Points   DECIMAL(12,2),
    @BranchId INT = NULL,
    @UserId   INT = NULL,
    @OtpId    INT OUTPUT,
    @Code     VARCHAR(6) OUTPUT,
    @SentTo   NVARCHAR(30) OUTPUT,
    @Email    NVARCHAR(200) OUTPUT,
    @Name     NVARCHAR(200) OUTPUT,
    @CardNo   NVARCHAR(50) OUTPUT,
    @ValueRs  DECIMAL(12,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    -- 2241: points past their expiry date are expired first, so the balance checked below is what can be used
    EXEC dbo.usp_Membership_ExpirePoints @UserId = 1, @CardId_Only = @CardId;
    -- checks first; the OTP row is written in its own short transaction below
    DECLARE @Bal DECIMAL(12,2), @Status VARCHAR(20), @From DATE, @To DATE, @Pv DECIMAL(12,2), @Msg NVARCHAR(300), @Today DATE = CAST(GETDATE() AS DATE),
            @MaxPct DECIMAL(6,2), @PlanOn BIT;
    SELECT @Bal = c.PointsBalance, @Status = c.Status, @From = c.ValidFrom, @To = c.ValidTo, @CardNo = c.CardNo, @Pv = ISNULL(pl.PointValue, 0),
           @MaxPct = ISNULL(pl.MaxRedeemPercent, 0), @PlanOn = CASE WHEN pl.IsActive = 1 AND ISNULL(pl.IsDeleted, 0) = 0 THEN 1 ELSE 0 END,
           @SentTo = NULLIF(LTRIM(RTRIM(pp.PhoneNumber)), ''), @Email = NULLIF(LTRIM(RTRIM(pp.EmailId)), ''),
           @Name = LTRIM(RTRIM(ISNULL(pp.FirstName, '') + ' ' + ISNULL(pp.LastName, '')))
    FROM dbo.MembershipCard c INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId
    LEFT JOIN dbo.PatientMaster pp ON pp.PatientId = c.PrimaryPatientId
    WHERE c.CardId = @CardId;
    IF @Status IS NULL THROW 50300, 'Membership card not found.', 1;
    IF @Status <> 'Active' OR @Today NOT BETWEEN @From AND @To THROW 50301, 'The membership card is not active or not valid today.', 1;
    -- plan settings (Membership Plan configuration): the plan must be active and allow redemption
    IF @PlanOn = 0 THROW 50305, 'The membership plan of this card is not active.', 1;
    IF @MaxPct <= 0 THROW 50306, 'This membership plan does not allow redeeming points (Max Redeem percent is 0).', 1;
    IF @Pv <= 0 THROW 50307, 'This membership plan has no point value set, so points cannot be redeemed.', 1;
    IF @Points IS NULL OR @Points <= 0 OR @Points <> FLOOR(@Points) THROW 50302, 'Enter the points to redeem as a whole number.', 1;
    IF @Points > @Bal
    BEGIN
        SET @Msg = CONCAT(N'The card has only ', CAST(@Bal AS VARCHAR(20)), N' points.'); THROW 50302, @Msg, 1;
    END
    IF @SentTo IS NULL THROW 50303, 'The card holder has no mobile number to send the OTP to.', 1;
    IF (SELECT COUNT(*) FROM dbo.MembershipRedeemOtp WHERE CardId = @CardId AND CreatedDate > DATEADD(MINUTE, -10, GETDATE())) >= 5
        THROW 50304, 'Too many OTPs for this card in the last 10 minutes. Please wait and try again.', 1;

    BEGIN TRAN;
        UPDATE dbo.MembershipRedeemOtp SET Status = 'SUPERSEDED' WHERE CardId = @CardId AND Status IN ('SENT', 'VERIFIED');
        SET @Code = RIGHT('000000' + CAST(ABS(CAST(CRYPT_GEN_RANDOM(4) AS INT)) % 1000000 AS VARCHAR(10)), 6);
        INSERT INTO dbo.MembershipRedeemOtp (CardId, Points, SentTo, ExpiresOn, BranchId, CreatedBy)
        VALUES (@CardId, @Points, @SentTo, DATEADD(MINUTE, 10, GETDATE()), @BranchId, @UserId);
        SET @OtpId = SCOPE_IDENTITY();
        UPDATE dbo.MembershipRedeemOtp SET CodeHash = HASHBYTES('SHA2_256', CONCAT(@OtpId, ':', @Code)) WHERE OtpId = @OtpId;
    COMMIT;
    SET @ValueRs = ROUND(@Points * @Pv, 2);
END;
GO

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
    @IsLifetime         BIT = 0,
    @MinRedeemBillAmount DECIMAL(10,2) = 0
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
    SET @MinRedeemBillAmount = ISNULL(@MinRedeemBillAmount, 0);
    IF @WelcomePoints < 0 OR @PointValue < 0 OR @PointsExpiryDays < 1 OR @MinRedeemBillAmount < 0 THROW 51010, 'Points settings are not valid.', 1;
    -- 2241
    IF @PointsExpiryDays > 3650 THROW 51018, 'Points Expire After must be between 1 and 3650 days.', 1;
    IF @MaxRedeemPercent > 0 AND @PointValue <= 0 THROW 51019, 'Value of 1 Point must be more than 0 when points can pay a bill.', 1;

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
        THROW 51013, 'Pick the department, category, test or package for every benefit rule.', 1;
    IF EXISTS (SELECT 1 FROM @Benefits b WHERE b.Scope = 'Test'
               AND NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster t WHERE t.Test_ID = b.ScopeRefId AND t.CompanyId = @CompanyId AND t.IsDeleted = 0))
       OR EXISTS (SELECT 1 FROM @Benefits b WHERE b.Scope = 'Package'
               AND NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationProfileHeader k WHERE k.Profile_ID = b.ScopeRefId AND k.CompanyId = @CompanyId AND k.IsDeleted = 0))
        THROW 51018, 'A benefit rule points at a test or package that does not exist.', 1;
    IF EXISTS (SELECT 1 FROM @Benefits WHERE DiscountFlag NOT IN ('P', 'A') OR DiscountValue < 0 OR (DiscountFlag = 'P' AND DiscountValue > 100))
        THROW 51014, 'A benefit discount must be 0 to 100 percent, or an amount of zero or more.', 1;
    IF EXISTS (SELECT 1 FROM @Benefits WHERE IsExcluded = 0 AND DiscountValue = 0 AND ISNULL(FreeQuantity, 0) = 0)
        THROW 51015, 'Every benefit rule needs a discount, a free quantity, or to be marked excluded.', 1;
    IF EXISTS (SELECT 1 FROM @Benefits GROUP BY Scope, ISNULL(ScopeRefId, 0) HAVING COUNT(1) > 1)
        THROW 51016, 'The same department, category, test or package appears in more than one benefit rule.', 1;

    BEGIN TRANSACTION;

    IF ISNULL(@PlanId, 0) = 0
    BEGIN
        DECLARE @Next INT;
        SELECT @Next = ISNULL(MAX(TRY_CAST(SUBSTRING(PlanCode, 3, 18) AS INT)), 0) + 1
        FROM dbo.MembershipPlan WITH (UPDLOCK, HOLDLOCK)
        WHERE CompanyId = @CompanyId AND PlanCode LIKE 'MP%';

        INSERT INTO dbo.MembershipPlan
            (CompanyId, PlanCode, PlanName, PlanType, CardFee, GstPercent, ValidityDays, IsLifetime, MaxMembers, MinAge, WelcomePoints,
             PointsEarnPercent, PointValue, MaxRedeemPercent, MinRedeemBillAmount, PointsExpiryDays, FreeHomeCollection, Terms, IsActive, CreatedBy)
        VALUES
            (@CompanyId, 'MP' + RIGHT('0000' + CAST(@Next AS VARCHAR(10)), 4), @PlanName, @PlanType, @CardFee, NULLIF(@GstPercent, 0),
             @ValidityDays, @IsLifetime, @MaxMembers, @MinAge, @WelcomePoints, @PointsEarnPercent, @PointValue, @MaxRedeemPercent, @MinRedeemBillAmount, @PointsExpiryDays,
             @FreeHomeCollection, NULLIF(LTRIM(RTRIM(@Terms)), ''), @IsActive, @UserId);
        SET @PlanId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.MembershipPlan
        SET PlanName = @PlanName, PlanType = @PlanType, CardFee = @CardFee, GstPercent = NULLIF(@GstPercent, 0),
            ValidityDays = @ValidityDays, IsLifetime = @IsLifetime, MaxMembers = @MaxMembers, MinAge = @MinAge, WelcomePoints = @WelcomePoints,
            PointsEarnPercent = @PointsEarnPercent, PointValue = @PointValue, MaxRedeemPercent = @MaxRedeemPercent, MinRedeemBillAmount = @MinRedeemBillAmount,
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
        DECLARE @Items TABLE (LineRefId INT, Amount DECIMAL(10,2), GstAmount DECIMAL(12,2) NULL);   -- 2240: GstAmount of a misc line
        INSERT INTO @Items (LineRefId, Amount)
        SELECT 
            CAST(JSON_VALUE(j.value, '$.lineRefId') AS INT),
            CAST(JSON_VALUE(j.value, '$.amount') AS DECIMAL(10,2))
        FROM OPENJSON(@LineItemsJson) j;

        DECLARE @TotalItems INT = (SELECT COUNT(*) FROM @Items);
        IF @TotalItems = 0
            THROW 50001, 'No items selected for cancellation.', 1;

        -- 2235: every line must belong to this bill, and is valued from the bill itself (not from the screen):
        -- LAB B2C at its price, LAB B2B at the franchise / company contract rate (B2BRate), OPD at its charges
        IF @ModuleCode = 'LAB'
        BEGIN
            -- 2240: a negative LineRefId is a misc line of the bill (LabOrderMiscCharge), still active
            IF EXISTS (SELECT 1 FROM @Items i WHERE ISNULL(i.LineRefId, 0) = 0
                          OR (i.LineRefId > 0 AND NOT EXISTS (SELECT 1 FROM dbo.LabOrderItem loi WHERE loi.LabOrderItemId = i.LineRefId AND loi.LabOrderId = @ModuleRefId))
                          OR (i.LineRefId < 0 AND NOT EXISTS (SELECT 1 FROM dbo.LabOrderMiscCharge m WHERE m.LabOrderMiscChargeId = -i.LineRefId AND m.LabOrderId = @ModuleRefId AND m.IsActive = 1)))
                THROW 50003, 'A selected item does not belong to this bill.', 1;
            UPDATE i SET Amount = CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(loi.B2BRate, ISNULL(loi.Price, 0)) ELSE ISNULL(loi.Price, 0) END
            FROM @Items i
            INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = i.LineRefId
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId;
            -- 2240: a misc line is cancelled at what it was billed: amount + its GST (B2C and B2B alike)
            UPDATE i SET Amount = m.Amount + m.GstAmount, GstAmount = m.GstAmount
            FROM @Items i INNER JOIN dbo.LabOrderMiscCharge m ON m.LabOrderMiscChargeId = -i.LineRefId
            WHERE i.LineRefId < 0;
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            IF EXISTS (SELECT 1 FROM @Items i WHERE NOT EXISTS (SELECT 1 FROM dbo.PatientOPDServiceItem si WHERE si.ItemId = i.LineRefId AND si.OPDServiceId = @ModuleRefId))
                THROW 50003, 'A selected item does not belong to this bill.', 1;
            UPDATE i SET Amount = ISNULL(si.ServiceCharges, 0)
            FROM @Items i INNER JOIN dbo.PatientOPDServiceItem si ON si.ItemId = i.LineRefId;
        END

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
            -- 2240: + the active misc lines (a bill is fully cancelled only with them)
            SET @TotalBillItems = @TotalBillItems + (SELECT COUNT(*) FROM dbo.LabOrderMiscCharge WHERE LabOrderId = @ModuleRefId AND IsActive = 1);
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
        INSERT INTO dbo.BillCancellationItem (CancellationId, LineRefId, OriginalAmount, CancelledAmount, IsActive, GstAmount)
        SELECT @CancellationId, LineRefId, Amount, Amount, 1, GstAmount
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

            -- 2240: cancelled misc lines
            UPDATE m SET IsActive = 0, CancellationId = @CancellationId, CancelledBy = @UserId, CancelledDate = GETDATE()
            FROM dbo.LabOrderMiscCharge m INNER JOIN @Items i ON -i.LineRefId = m.LabOrderMiscChargeId
            WHERE i.LineRefId < 0 AND m.LabOrderId = @ModuleRefId;
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            UPDATE dbo.PatientOPDServiceItem 
            SET IsActive = 0
            WHERE ItemId IN (SELECT LineRefId FROM @Items);
        END

        -- 2241: the membership discount on the cancelled lines (tests: LabOrderItemId, misc lines: - misc line id)
        DECLARE @MemCancelled DECIMAL(18,2) = 0, @MemTestCancelled DECIMAL(18,2) = 0;
        IF @ModuleCode = 'LAB'
            SELECT @MemCancelled = ISNULL(SUM(pli.MembershipDiscountAmount), 0),
                   @MemTestCancelled = ISNULL(SUM(CASE WHEN pli.ModuleLineRefId > 0 THEN pli.MembershipDiscountAmount ELSE 0 END), 0)
            FROM dbo.PaymentLineItem pli
            INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pli.PaymentHeaderId AND ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @ModuleRefId AND ph.IsActive = 1
            WHERE pli.IsActive = 1 AND pli.ModuleLineRefId IN (SELECT LineRefId FROM @Items);
        IF @MemCancelled > ISNULL(@DiscountAdjusted, 0) SET @MemCancelled = ISNULL(@DiscountAdjusted, 0);

        -- Update PaymentHeader
        IF @CancellationType = 'F'
        BEGIN
            -- Full cancellation: NetAmount and BalanceDue become 0
            UPDATE dbo.PaymentHeader
            SET NetAmount            = 0,
                BalanceDue           = 0,
                HeaderDiscountAmount = 0,
                MembershipDiscountAmount = 0,   -- 2241
                MembershipTestDiscount   = 0,
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
                HeaderDiscountAmount = CASE WHEN (HeaderDiscountAmount - (ISNULL(@DiscountAdjusted, 0) - @MemCancelled)) < 0 THEN 0 ELSE (HeaderDiscountAmount - (ISNULL(@DiscountAdjusted, 0) - @MemCancelled)) END,
                -- 2241: the membership share of the discount leaves with its lines
                MembershipDiscountAmount = CASE WHEN MembershipDiscountAmount - @MemCancelled < 0 THEN 0 ELSE MembershipDiscountAmount - @MemCancelled END,
                MembershipTestDiscount = CASE WHEN MembershipTestDiscount - @MemTestCancelled < 0 THEN 0 ELSE MembershipTestDiscount - @MemTestCancelled END,
                -- 2231: status follows the reduced bill: covered = Paid (any excess is for refund), else Partial / Unpaid
                PaymentStatus = CASE WHEN TotalPaid >= (CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0
                                                           ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END) THEN 'P'
                                     WHEN TotalPaid > 0 THEN 'R' ELSE 'U' END,
                LastModifiedDate = GETDATE(),
                LastModifiedBy   = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END

        -- 2240: the bill's misc totals / GST follow its active misc lines (header GST and the GST ledger)
        IF @ModuleCode = 'LAB'
        BEGIN
            EXEC dbo.usp_LabOrder_MiscSyncTotals @LabOrderId = @ModuleRefId;
            UPDATE ph SET TotalCgstAmount = ISNULL(x.Cgst, 0), TotalSgstAmount = ISNULL(x.Sgst, 0)
            FROM dbo.PaymentHeader ph
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = ph.ModuleRefId AND ISNULL(lo.IsB2B, 0) = 0
            OUTER APPLY (SELECT SUM(CgstAmount) AS Cgst, SUM(SgstAmount) AS Sgst FROM dbo.LabOrderMiscCharge
                         WHERE LabOrderId = @ModuleRefId AND IsActive = 1) x
            WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @ModuleRefId AND ph.IsActive = 1
              AND EXISTS (SELECT 1 FROM dbo.LabOrderMiscCharge WHERE LabOrderId = @ModuleRefId);
            EXEC dbo.usp_Ledger_SyncLabGst @LabOrderId = @ModuleRefId, @UserId = @UserId;
        END

        -- 2232: the cancellation entry (Dr Revenue / Cr the bill's receivable), then discount / round-off follow the bill
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'CANCEL', @RefId = @CancellationId, @UserId = @UserId;
        DECLARE @AdjHeaderId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1);
        IF @AdjHeaderId IS NOT NULL
            EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'ADJUST', @RefId = @AdjHeaderId, @UserId = @UserId;
        -- 2236: membership points of a B2C LAB bill - points used beyond the reduced bill go back to the card,
        -- points earned follow what is paid on the bill as it stands
        IF @AdjHeaderId IS NOT NULL AND @ModuleCode = 'LAB'
            EXEC dbo.usp_Membership_SyncBill @PaymentHeaderId = @AdjHeaderId, @UserId = @UserId;

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

CREATE OR ALTER PROCEDURE dbo.usp_Bill_GetDetailForCancellation
    @ModuleCode  NVARCHAR(20),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ModuleCode = 'LAB'
    BEGIN
        SELECT
            lo.LabOrderId        AS ModuleRefId,
            'LAB'                AS ModuleCode,
            lo.BillNo,
            lo.OrderDate         AS BillDate,
            CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0) END AS TotalAmount,   -- 2235, 2240 + misc
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.EmailId,
            p.Address,
            CASE WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentHeaderId, 0)   AS PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U')   AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)         AS TotalPaid,
            ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, lo.TotalAmount)  AS NetAmount,
            ISNULL(ph.HeaderDiscountAmount, 0) + ISNULL(ph.MembershipDiscountAmount, 0) AS TotalDiscountAmount,   -- 2241: + membership
            ISNULL(ph.LineDiscountTotal, 0)       AS LineDiscountTotal,
            ISNULL(ph.RoundOffAmount, 0)          AS RoundOffAmount,
            b.BranchName
        FROM dbo.LabOrder lo
        INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = lo.BranchId
        WHERE lo.LabOrderId = @ModuleRefId;

        SELECT
            loi.LabOrderItemId   AS LineRefId,
            loi.LabOrderId       AS ModuleRefId,
            ISNULL(pkg.Profile_Name, lm.Test_Name) AS ItemName,
            ISNULL(pkg.Profile_Code, lm.Test_Code) AS ItemCode,
            -- 2235: a B2B bill is charged at the franchise / company contract rate
            CASE WHEN ISNULL(lo2.IsB2B, 0) = 1 THEN ISNULL(loi.B2BRate, loi.Price) ELSE loi.Price END AS OriginalAmount,
            CASE WHEN ISNULL(lo2.IsB2B, 0) = 1 THEN ISNULL(loi.B2BRate, loi.Price) ELSE ISNULL(pli.NetLineAmount, loi.Price) END AS NetAmount,
            loi.Price            AS Mrp,
            ISNULL(pli.LineDiscountAmount, 0)    AS DiscountAmount,
            loi.IsActive,
            ISNULL(
                (SELECT SUM(bci.CancelledAmount) 
                 FROM dbo.BillCancellationItem bci
                 INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                 WHERE bci.LineRefId = loi.LabOrderItemId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1)
            , 0) AS CancelledAmount,
            CASE WHEN loi.IsActive = 0 THEN 1
                 WHEN EXISTS (SELECT 1 FROM dbo.BillCancellationItem bci
                              INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                              WHERE bci.LineRefId = loi.LabOrderItemId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS IsCancelled,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE lst.Sample_Name END AS SampleTypeName,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE dm.DeptName END AS DepartmentName,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE lc.Category_Name END AS CategoryName,
            -- Lab progress of this line's tests: decides whether it may be cancelled (dbo.ufn_LabOrderItemCancelState)
            ISNULL(cs.TestCount, 0)          AS TestCount,
            ISNULL(cs.NotCollectedCount, 0)  AS NotCollectedCount,
            ISNULL(cs.RejectedCount, 0)      AS RejectedCount,
            ISNULL(cs.CollectedCount, 0)     AS CollectedCount,
            ISNULL(cs.DraftCount, 0)         AS DraftCount,
            ISNULL(cs.SubmittedCount, 0)     AS SubmittedCount,
            ISNULL(cs.ValidatedCount, 0)     AS ValidatedCount,
            ISNULL(cs.ApprovedCount, 0)      AS ApprovedCount,
            ISNULL(cs.TransferredCount, 0)   AS TransferredCount,
            ISNULL(cs.OutsourcedCount, 0)    AS OutsourcedCount,
            CASE WHEN loi.IsActive = 0 THEN 'CANCELLED' ELSE ISNULL(cs.CancelStage, 'ALLOWED') END AS CancelStage,
            0 AS LineSort, loi.LabOrderItemId AS LineSortId
        FROM dbo.LabOrderItem loi
        INNER JOIN dbo.LabOrder lo2 ON lo2.LabOrderId = loi.LabOrderId
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
        LEFT JOIN dbo.LabInvestigationMaster lm ON lm.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
        LEFT JOIN dbo.LabSampleTypeMaster lst ON lst.Sample_Type_ID = lm.Sample_Type_ID
        LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lm.Department_ID
        LEFT JOIN dbo.LabTestCategoryMaster lc ON lc.Category_ID = lm.Category_ID
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = loi.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId 
            AND (pli.ModuleLineRefId = loi.LabOrderItemId OR pli.ModuleLineRefId = loi.InvestigationId)
            AND pli.IsActive = 1
        LEFT JOIN dbo.ufn_LabOrderItemCancelState(@ModuleRefId) cs ON cs.LabOrderItemId = loi.LabOrderItemId
        WHERE loi.LabOrderId = @ModuleRefId
        
        -- 2240: misc lines (LineRefId = - misc line id), billed amount = amount + GST; no lab work, always cancellable
        UNION ALL
        SELECT -m.LabOrderMiscChargeId, m.LabOrderId,
               m.ChargeName + CASE WHEN m.Quantity > 1 THEN ' x ' + CAST(m.Quantity AS NVARCHAR(5)) ELSE '' END,
               CASE WHEN m.ChargeType = 'Home Collection' THEN 'HOME-COLL' ELSE 'MISC' END,
               m.Amount + m.GstAmount, m.NetAmount, m.Amount + m.GstAmount, m.DiscountAmount, m.IsActive,
               ISNULL((SELECT SUM(bci.CancelledAmount) FROM dbo.BillCancellationItem bci
                       INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                       WHERE bci.LineRefId = -m.LabOrderMiscChargeId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1), 0),
               CASE WHEN m.IsActive = 0 THEN 1 ELSE 0 END,
               m.ChargeType, 'Misc Charge', CASE WHEN m.IsGstRequired = 1 THEN 'incl. GST ' + FORMAT(m.GstPercentage, '0.##') + '%' ELSE 'Misc' END,
               0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               CASE WHEN m.IsActive = 0 THEN 'CANCELLED' ELSE 'ALLOWED' END,
               1, m.LabOrderMiscChargeId
        FROM dbo.LabOrderMiscCharge m
        WHERE m.LabOrderId = @ModuleRefId
        ORDER BY LineSort, LineSortId;

        SELECT
            pd.PaymentDetailId,
            pm.MethodName,
            pm.MethodCode,
            pd.PaidAmount,
            pd.PaymentDate,
            pd.ReceiptNo,
            pd.TransactionRef
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @ModuleRefId AND pd.IsActive = 1;
    END

    IF @ModuleCode = 'OPD'
    BEGIN
        SELECT
            os.OPDServiceId         AS ModuleRefId,
            'OPD'                   AS ModuleCode,
            os.OPDBillNo            AS BillNo,
            os.VisitDate            AS BillDate,
            os.TotalAmount,
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.EmailId,
            p.Address,
            CASE WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentHeaderId, 0)   AS PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U')   AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)         AS TotalPaid,
            ISNULL(ph.BalanceDue, os.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, os.TotalAmount)  AS NetAmount,
            ISNULL(ph.HeaderDiscountAmount, 0)    AS TotalDiscountAmount,
            ISNULL(ph.LineDiscountTotal, 0)       AS LineDiscountTotal,
            ISNULL(ph.RoundOffAmount, 0)          AS RoundOffAmount,
            b.BranchName
        FROM dbo.PatientOPDService os
        INNER JOIN dbo.PatientMaster p ON p.PatientId = os.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = os.OPDServiceId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = os.BranchId
        WHERE os.OPDServiceId = @ModuleRefId;

        SELECT
            si.ItemId             AS LineRefId,
            si.OPDServiceId       AS ModuleRefId,
            ISNULL(sm.ItemName, si.ServiceType) AS ItemName,
            si.ServiceType        AS ItemCode,
            si.ServiceCharges     AS OriginalAmount,
            ISNULL(pli.NetLineAmount, si.ServiceCharges) AS NetAmount,
            ISNULL(pli.LineDiscountAmount, 0)           AS DiscountAmount,
            si.IsActive,
            ISNULL(
                (SELECT SUM(bci.CancelledAmount) 
                 FROM dbo.BillCancellationItem bci
                 INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                 WHERE bci.LineRefId = si.ItemId AND bc.ModuleCode = 'OPD' AND bc.IsActive = 1)
            , 0) AS CancelledAmount,
            CASE WHEN si.IsActive = 0 THEN 1
                 WHEN EXISTS (SELECT 1 FROM dbo.BillCancellationItem bci
                              INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                              WHERE bci.LineRefId = si.ItemId AND bc.ModuleCode = 'OPD' AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS IsCancelled,
            NULL AS SampleTypeName,
            NULL AS DepartmentName,
            NULL AS CategoryName
        FROM dbo.PatientOPDServiceItem si
        LEFT JOIN dbo.ServiceMaster sm    ON sm.ServiceId = si.ServiceId
        LEFT JOIN dbo.PaymentHeader ph     ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = si.OPDServiceId AND ph.IsActive = 1
        LEFT JOIN dbo.PaymentLineItem pli  ON pli.PaymentHeaderId = ph.PaymentHeaderId 
                                           AND pli.ModuleLineRefId = si.ItemId 
                                           AND pli.IsActive = 1
        WHERE si.OPDServiceId = @ModuleRefId
        ORDER BY si.ItemId;

        SELECT
            pd.PaymentDetailId,
            pm.MethodName,
            pm.MethodCode,
            pd.PaidAmount,
            pd.PaymentDate,
            pd.ReceiptNo,
            pd.TransactionRef
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE ph.ModuleCode = 'OPD' AND ph.ModuleRefId = @ModuleRefId AND pd.IsActive = 1;
    END
END;
GO

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
        WHERE pd.PaymentDetailId = @RefId AND pd.IsActive = 1 AND (pd.PaidAmount > 0 OR (pd.PaidAmount < 0 AND pm.MethodCode = 'POINTS'));
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
        -- 2240: the GST inside cancelled misc lines is reversed by usp_Ledger_SyncLabGst, not against revenue
        SET @Amt = ISNULL(@Amt, 0) - ISNULL((SELECT SUM(GstAmount) FROM dbo.BillCancellationItem WHERE CancellationId = @RefId AND IsActive = 1), 0);
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

    IF @Kind = 'RECEIPT' AND @MethodCode = 'POINTS'
    BEGIN
        -- 2236: membership points paid part of the bill - Dr Membership Points Liability / Cr the receivable;
        -- points given back (a negative line after a cancellation) the other way
        DECLARE @PtsLiab INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Liability');
        IF @PtsLiab IS NULL RETURN;
        SET @Narr = CASE WHEN @Amt > 0 THEN N'Membership points redeemed on ' ELSE N'Membership points given back on ' END + @Module + N' Bill ' + @BillNo
                  + N' (' + ISNULL(@ReceiptNo, 'no receipt') + N')';
        SET @When = ISNULL(@TxDate, @When);
        IF @Amt > 0
            EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
                 @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @PtsLiab, @CreditLedgerId = @Party,
                 @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        ELSE
        BEGIN
            SET @Amt = -@Amt;
            EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
                 @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Party, @CreditLedgerId = @PtsLiab,
                 @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        END
        RETURN;
    END

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

    -- 2240: GST on misc charges (B2C and B2B) follows the bill's active misc lines
    IF @Module = 'LAB' EXEC dbo.usp_Ledger_SyncLabGst @LabOrderId = @ModuleRefId, @UserId = @UserId;

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
    -- 2240: the bill now includes the misc GST (posted to GST Output Payable, not to revenue); 0 for every other bill
    DECLARE @GstNow DECIMAL(18,2) = CASE WHEN @Module = 'LAB' THEN ISNULL((SELECT MiscGstAmount FROM dbo.LabOrder WHERE LabOrderId = @ModuleRefId), 0) ELSE 0 END;
    SET @TargetDisc = @BillPosted - @CancelPosted + @TargetRound + @GstNow - @NetNow;
    -- 2241: the membership share of the discount goes to Membership Discount; the rest stays Discount Allowed
    DECLARE @MemLedger INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Discount');
    DECLARE @TargetMem DECIMAL(18,2) = CASE WHEN @MemLedger IS NULL THEN 0 ELSE ISNULL((SELECT MembershipDiscountAmount FROM dbo.PaymentHeader WHERE PaymentHeaderId = @HeaderId), 0) END,
            @PostedMem DECIMAL(18,2);
    IF @TargetMem > @TargetDisc SET @TargetMem = CASE WHEN @TargetDisc > 0 THEN @TargetDisc ELSE 0 END;
    SET @TargetDisc = @TargetDisc - @TargetMem;
    IF @MemLedger IS NOT NULL
    BEGIN
        SELECT @PostedMem = ISNULL(SUM(d.DebitAmount - d.CreditAmount), 0)
        FROM dbo.Acc_LedgerTransaction t INNER JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId AND d.LedgerId = @MemLedger
        WHERE t.ReferenceType = @Module + '_MEMDISC' AND t.ReferenceId = @HeaderId AND t.IsActive = 1;
        SET @Diff = @TargetMem - @PostedMem;
        IF ABS(@Diff) >= 0.01
        BEGIN
            SET @RefType = @Module + '_MEMDISC';
            SET @Narr = N'Membership discount on ' + @Module + N' Bill ' + @BillNo + CASE WHEN @Diff < 0 THEN N' (reversed / reduced)' ELSE N'' END;
            SET @Amt = ABS(@Diff);
            SET @Dr = CASE WHEN @Diff > 0 THEN @MemLedger ELSE @Receivable END;
            SET @Cr = CASE WHEN @Diff > 0 THEN @Receivable ELSE @MemLedger END;
            EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Journal, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @HeaderId,
                 @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Cr,
                 @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        END
    END

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

CREATE OR ALTER PROCEDURE [dbo].[usp_Api_PaymentSummary_GetByBill]
    @ModuleCode  NVARCHAR(20),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    IF @ModuleCode = 'OPD'
    BEGIN
        SELECT
            s.OPDServiceId          AS ModuleRefId,
            'OPD'                   AS ModuleCode,
            s.OPDServiceId,
            s.OPDBillNo,
            s.TokenNo,
            p.PatientId,
            p.PatientCode,
            (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
            p.PhoneNumber           AS PatientPhone,
            ISNULL(s.BranchId, 0)  AS BranchId,
            ISNULL(s.TotalAmount, 0) AS SubTotal
        FROM PatientOPDService s
        INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
        WHERE s.OPDServiceId = @ModuleRefId;

        DECLARE @PaymentHeaderId_OPD INT;
        SELECT @PaymentHeaderId_OPD = PaymentHeaderId 
        FROM PaymentHeader 
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        SELECT
            si.ItemId                        AS LineRefId,
            si.ServiceType,
            ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
            ISNULL(si.ServiceCharges, 0)     AS OriginalAmount,
            ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
            ISNULL(pli.NetLineAmount, ISNULL(si.ServiceCharges, 0)) AS NetLineAmount,
            ISNULL(sm.IsGstRequired, 0)      AS IsGstRequired,
            sm.GstPercentage                 AS GstPercentage,
            ISNULL(pli.CgstAmount, 0)        AS CgstAmount,
            ISNULL(pli.SgstAmount, 0)        AS SgstAmount,
            ISNULL(pli.IgstAmount, 0)        AS IgstAmount,
            CAST(ISNULL(sm.IsDiscountable, 1) AS BIT) AS IsDiscountAllowed   -- 2228: Service Master "Is Discountable"
        FROM PatientOPDServiceItem si
        LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
        LEFT JOIN PaymentLineItem pli ON pli.PaymentHeaderId = @PaymentHeaderId_OPD AND pli.ModuleLineRefId = si.ItemId AND pli.IsActive = 1
        WHERE si.OPDServiceId = @ModuleRefId AND si.IsActive = 1
        ORDER BY si.ItemId;

        SELECT
            PaymentHeaderId,
            ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
            HeaderDiscountType,
            HeaderDiscountValue,
            ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
            ISNULL(NetAmount, 0)              AS NetAmount,
            ISNULL(TotalPaid, 0)              AS TotalPaid,
            ISNULL(BalanceDue, 0)             AS BalanceDue,
            ISNULL(PaymentStatus, 'U')        AS PaymentStatus,
            DiscountReason,
            DiscountApprovedBy,
            (SELECT ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) FROM Users u WHERE u.Id = PaymentHeader.DiscountApprovedBy) AS DiscountApprovedByName
        FROM PaymentHeader
        WHERE PaymentHeaderId = @PaymentHeaderId_OPD;
    END
    ELSE IF @ModuleCode = 'LAB'
    BEGIN
        SELECT
            s.LabOrderId            AS ModuleRefId,
            'LAB'                   AS ModuleCode,
            s.LabOrderId            AS OPDServiceId, 
            s.BillNo                AS OPDBillNo,
            s.TokenNo               AS TokenNo,
            p.PatientId,
            p.PatientCode,
            (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
            p.PhoneNumber           AS PatientPhone,
            ISNULL(s.BranchId, 0)   AS BranchId,
            ISNULL(s.TotalAmount, 0) + ISNULL(s.MiscAmount, 0)
              + CASE WHEN ISNULL(s.IsB2B, 0) = 1 THEN ISNULL(s.MiscGstAmount, 0) ELSE 0 END AS SubTotal   -- 2240: + misc charges
        FROM LabOrder s
        INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
        WHERE s.LabOrderId = @ModuleRefId;

        DECLARE @PaymentHeaderId_LAB INT;
        SELECT @PaymentHeaderId_LAB = PaymentHeaderId 
        FROM PaymentHeader 
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        SELECT
            si.LabOrderItemId                AS LineRefId,
            CASE WHEN si.Type = 'P' THEN 'Package' ELSE 'Test' END AS ServiceType,
            CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, '(Unknown Package)') ELSE ISNULL(im.Test_Name, '(Unknown)') END AS ItemName,
            ISNULL(si.Price, 0)              AS OriginalAmount,
            ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
            ISNULL(pli.NetLineAmount, ISNULL(si.Price, 0)) AS NetLineAmount,
            0                                AS IsGstRequired,
            0                                AS GstPercentage,
            0                                AS CgstAmount,
            0                                AS SgstAmount,
            0                                AS IgstAmount,
            CAST(ISNULL(e.Allowed, 0) AS BIT) AS IsDiscountAllowed,          -- 2228: branch B2C rate card "Discount Allowed"
            0 AS LineSort, si.LabOrderItemId AS LineSortId
        FROM LabOrderItem si
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
        LEFT JOIN dbo.LabInvestigationMaster im ON im.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
        OUTER APPLY (
            SELECT TOP 1 CAST(ISNULL(d.Is_Discount_Allowed, 0) AS BIT) AS Allowed
            FROM dbo.LabRateCardMaster m
            INNER JOIN dbo.LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID AND d.IsDeleted = 0
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = si.LabOrderId
            WHERE m.Branch_ID = lo.BranchId AND m.Rate_Type = 'B2C' AND m.Status = 1 AND m.IsDeleted = 0
              AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
              AND d.Item_ID = si.InvestigationId
              AND d.Item_Type = CASE WHEN si.Type = 'P' THEN 'Package' WHEN im.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END
            ORDER BY m.Effective_From DESC, m.RateCard_ID DESC) e
        LEFT JOIN PaymentLineItem pli ON pli.PaymentHeaderId = @PaymentHeaderId_LAB AND pli.ModuleLineRefId = si.LabOrderItemId AND pli.IsActive = 1
        WHERE si.LabOrderId = @ModuleRefId AND si.IsActive = 1
        
        -- 2240: misc lines. B2C: GST on top (a saved bill's due-collection discount never touches a GST line);
        -- B2B: the partner's amount already includes the GST
        UNION ALL
        SELECT -m.LabOrderMiscChargeId, 'Misc',
               m.ChargeName + CASE WHEN m.Quantity > 1 THEN ' x ' + CAST(m.Quantity AS NVARCHAR(5)) ELSE '' END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN m.Amount + m.GstAmount ELSE m.Amount END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE m.DiscountAmount END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN m.Amount + m.GstAmount ELSE m.Amount - m.DiscountAmount END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE m.IsGstRequired END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(m.GstPercentage, 0) END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE m.CgstAmount END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE m.SgstAmount END,
               0,
               CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 0 AND m.IsDiscountable = 1 AND (m.IsGstRequired = 0 OR @PaymentHeaderId_LAB IS NULL) THEN 1 ELSE 0 END AS BIT),
               1, m.LabOrderMiscChargeId
        FROM dbo.LabOrderMiscCharge m
        INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = m.LabOrderId
        WHERE m.LabOrderId = @ModuleRefId AND m.IsActive = 1
        ORDER BY LineSort, LineSortId;

        SELECT
            PaymentHeaderId,
            ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
            HeaderDiscountType,
            HeaderDiscountValue,
            ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
            ISNULL(NetAmount, 0)              AS NetAmount,
            ISNULL(TotalPaid, 0)              AS TotalPaid,
            ISNULL(BalanceDue, 0)             AS BalanceDue,
            ISNULL(PaymentStatus, 'U')        AS PaymentStatus,
            DiscountReason,
            DiscountApprovedBy,
            (SELECT ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) FROM Users u WHERE u.Id = PaymentHeader.DiscountApprovedBy) AS DiscountApprovedByName,
            ISNULL(MembershipDiscountAmount, 0) AS MembershipDiscountAmount,   -- 2241
            ISNULL(MembershipTestDiscount, 0)   AS MembershipTestDiscount
        FROM PaymentHeader
        WHERE PaymentHeaderId = @PaymentHeaderId_LAB;
    END
END;
GO

PRINT 'Script 2241 applied: Free Home Collection and benefit rules on B2C LAB bills, Membership Discount ledger, points expiry checks.';
GO

-- The payment screen's benefit preview on the B2C booking page (VIEW of the page); no grants are changed
DECLARE @page INT, @ctl INT;
SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABORDERBOOKING.B2CBOOKING';
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABORDERBOOKING.B2CBOOKING';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabOrderBooking', @Action = N'MembershipBenefitPreview', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
