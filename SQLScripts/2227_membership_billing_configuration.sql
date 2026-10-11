-- ============================================================================
-- Migration: 2227_membership_billing_configuration.sql
-- Description:
--   Membership card - the configuration the billing side needs (no billing change in this script).
--   1. Benefit rules can point at a single test or a single package / profile, as well as all tests,
--      a lab department or a test category. Most specific rule wins: Test / Package > Category > Department > All.
--        usp_Api_MembershipPlan_GetBenefitScopes  also returns the tests and packages of the company
--        usp_Api_MembershipPlan_GetById           names the test / package of a rule; returns MinRedeemBillAmount
--        usp_Api_MembershipPlan_Save              checks the test / package exists; saves MinRedeemBillAmount
--   2. MembershipPlan.MinRedeemBillAmount: points can be redeemed only on a bill of at least this amount (0 = any bill).
--   3. Hospital Settings (per branch):
--        MembershipDiscountWithManualDiscount  No (default): a bill takes the membership discount OR a manual discount.
--                                              Yes: a manual discount may be given on top of the membership discount.
--        MembershipRedeemOtpRequired           Yes (default): redeeming points needs an OTP sent to the primary member.
--        MembershipPointsExpiryTime            time of day the points-expiry job runs (default 01:00)
--   Run after 2226.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Columns --------------------------------------------------------------------
IF COL_LENGTH('dbo.MembershipPlan', 'MinRedeemBillAmount') IS NULL
    ALTER TABLE dbo.MembershipPlan ADD MinRedeemBillAmount DECIMAL(10,2) NOT NULL CONSTRAINT DF_MembershipPlan_MinRedeemBillAmount DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipDiscountWithManualDiscount') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipDiscountWithManualDiscount BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipDiscountWithManualDiscount DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipRedeemOtpRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipRedeemOtpRequired BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipRedeemOtpRequired DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipPointsExpiryTime') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipPointsExpiryTime TIME(0) NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipPointsExpiryTime DEFAULT ('01:00');
GO

-- 2. Plan master procedures -------------------------------------------------------
-- What a benefit rule can point at. Result 1: lab departments. Result 2: test categories.
-- Result 3: tests. Result 4: packages / profiles. All of the company, active only.
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipPlan_GetBenefitScopes
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.DeptId AS Id, d.DeptName AS Name
    FROM dbo.DepartmentMaster d
    WHERE d.IsActive = 1 AND (UPPER(d.DeptType) = 'LAB' OR d.DeptType LIKE '%Lab%')
    ORDER BY d.DeptName;

    SELECT c.Category_ID AS Id, c.Category_Name AS Name
    FROM dbo.LabTestCategoryMaster c
    WHERE c.CompanyId = @CompanyId AND c.Status = 1 AND c.IsDeleted = 0
    ORDER BY c.Category_Name;

    SELECT t.Test_ID AS Id, CONCAT(t.Test_Name, N' (', t.Test_Code, N')') AS Name
    FROM dbo.LabInvestigationMaster t
    WHERE t.CompanyId = @CompanyId AND t.Status = 1 AND t.IsDeleted = 0
    ORDER BY t.Test_Name;

    SELECT k.Profile_ID AS Id, CONCAT(k.Profile_Name, N' (', k.Profile_Code, N')') AS Name
    FROM dbo.LabInvestigationProfileHeader k
    WHERE k.CompanyId = @CompanyId AND k.Status = 1 AND k.IsDeleted = 0
    ORDER BY k.Profile_Name;
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
           p.MinAge, p.WelcomePoints, p.PointsEarnPercent, p.PointValue, p.MaxRedeemPercent, p.MinRedeemBillAmount, p.PointsExpiryDays,
           p.FreeHomeCollection, p.Terms, p.IsActive, p.CreatedDate, p.ModifiedDate,
           (SELECT COUNT(1) FROM dbo.MembershipCard c WHERE c.PlanId = p.PlanId) AS CardsIssued
    FROM dbo.MembershipPlan p
    WHERE p.PlanId = @PlanId AND p.CompanyId = @CompanyId AND p.IsDeleted = 0;

    SELECT b.BenefitId, b.Scope, b.ScopeRefId, b.DiscountFlag, b.DiscountValue, b.IsExcluded, b.FreeQuantity,
           CASE b.Scope WHEN 'All' THEN N'All tests'
                        WHEN 'Department' THEN d.DeptName
                        WHEN 'Category' THEN c.Category_Name
                        WHEN 'Test' THEN t.Test_Name
                        WHEN 'Package' THEN pk.Profile_Name
                        ELSE CONCAT(b.Scope, N' #', b.ScopeRefId) END AS ScopeName
    FROM dbo.MembershipPlanBenefit b
    INNER JOIN dbo.MembershipPlan p ON p.PlanId = b.PlanId AND p.CompanyId = @CompanyId
    LEFT JOIN dbo.DepartmentMaster d ON b.Scope = 'Department' AND d.DeptId = b.ScopeRefId
    LEFT JOIN dbo.LabTestCategoryMaster c ON b.Scope = 'Category' AND c.Category_ID = b.ScopeRefId
    LEFT JOIN dbo.LabInvestigationMaster t ON b.Scope = 'Test' AND t.Test_ID = b.ScopeRefId
    LEFT JOIN dbo.LabInvestigationProfileHeader pk ON b.Scope = 'Package' AND pk.Profile_ID = b.ScopeRefId
    WHERE b.PlanId = @PlanId AND b.IsActive = 1
    ORDER BY CASE b.Scope WHEN 'All' THEN 0 WHEN 'Department' THEN 1 WHEN 'Category' THEN 2 WHEN 'Test' THEN 3 ELSE 4 END, b.BenefitId;
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

PRINT '2227_membership_billing_configuration.sql applied.';
GO
