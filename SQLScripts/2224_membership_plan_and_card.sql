-- ============================================================================
-- Migration: 2224_membership_plan_and_card.sql
-- Description:
--   Patient Membership Card - masters configuration and card distribution.
--   1. Tables (the five of the membership design, nothing else):
--        MembershipPlan          one plan per company (fee, validity, member limit, points settings)
--        MembershipPlanBenefit   discount / exclusion rules of a plan (all tests, lab department, test category)
--        MembershipCard          an issued card (number, validity, fee payment, print / send tracking)
--        MembershipCardMember    patients covered by a card
--        MembershipLedger        every amount / point movement of a card
--   2. The card fee is posted to the EXISTING payment tables under module code 'MEM'
--        (PaymentHeader / PaymentLineItem / PaymentDetail, receipt no from usp_Receipt_GetNextNo)
--        and to the EXISTING accounting ledger (Acc_LedgerTransaction / Acc_LedgerTransactionDetail,
--        through usp_Ledger_PostEntry):
--            Sales   voucher  Dr Patient Receivable        Cr Membership Revenue   (reference MEM_CARD)
--            Receipt voucher  Dr Cash Account / Bank Account  Cr Patient Receivable  (reference MEM_RECEIPT)
--        Only a ledger head 'Membership Revenue' (and 'Bank Account' if missing) is added to Acc_LedgerMaster.
--   3. Hospital Settings (per branch): card number prefix, send card by WhatsApp / email,
--        send automatically on issue, card message text.
--   4. Procedures: usp_Api_MembershipPlan_* (master) and usp_Api_MembershipCard_* (issue, list, detail,
--        add member, status, print / send tracking). usp_Api_MembershipCard_Issue saves the card, its
--        members, the fee payment and the ledger rows in one transaction.
--   5. Seed: four starter plans per company (a starter kit - every value is editable on the master).
--   6. Authorization: pages MASTER.MEMBERSHIPPLANS and MASTER.MEMBERSHIPCARDS under Master > General.
--   Business-rule failures are raised with THROW 51000..51099 so the API can show the message as is.
--   Run after 2223.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Tables ---------------------------------------------------------------------
IF OBJECT_ID(N'dbo.MembershipPlan', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MembershipPlan
    (
        PlanId              INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MembershipPlan PRIMARY KEY,
        CompanyId           INT            NOT NULL,
        PlanCode            NVARCHAR(20)   NOT NULL,
        PlanName            NVARCHAR(150)  NOT NULL,
        PlanType            VARCHAR(20)    NOT NULL,   -- Individual | Family | Senior | Corporate
        CardFee             DECIMAL(10,2)  NOT NULL CONSTRAINT DF_MembershipPlan_CardFee DEFAULT 0,
        GstPercent          DECIMAL(5,2)   NULL,       -- GST on the card fee (split CGST / SGST), NULL = none
        ValidityDays        INT            NOT NULL CONSTRAINT DF_MembershipPlan_ValidityDays DEFAULT 365,
        MaxMembers          INT            NOT NULL CONSTRAINT DF_MembershipPlan_MaxMembers DEFAULT 1,
        MinAge              INT            NULL,       -- primary member must be at least this old at issue
        WelcomePoints       DECIMAL(12,2)  NOT NULL CONSTRAINT DF_MembershipPlan_WelcomePoints DEFAULT 0,
        PointsEarnPercent   DECIMAL(5,2)   NOT NULL CONSTRAINT DF_MembershipPlan_PointsEarnPercent DEFAULT 0,
        PointValue          DECIMAL(10,2)  NOT NULL CONSTRAINT DF_MembershipPlan_PointValue DEFAULT 1,
        MaxRedeemPercent    DECIMAL(5,2)   NOT NULL CONSTRAINT DF_MembershipPlan_MaxRedeemPercent DEFAULT 0,
        PointsExpiryDays    INT            NOT NULL CONSTRAINT DF_MembershipPlan_PointsExpiryDays DEFAULT 365,
        FreeHomeCollection  BIT            NOT NULL CONSTRAINT DF_MembershipPlan_FreeHomeCollection DEFAULT 0,
        Terms               NVARCHAR(1000) NULL,       -- printed on the back of the card
        IsActive            BIT            NOT NULL CONSTRAINT DF_MembershipPlan_IsActive DEFAULT 1,
        IsDeleted           BIT            NOT NULL CONSTRAINT DF_MembershipPlan_IsDeleted DEFAULT 0,
        CreatedBy           INT            NULL,
        CreatedDate         DATETIME       NOT NULL CONSTRAINT DF_MembershipPlan_CreatedDate DEFAULT GETDATE(),
        ModifiedBy          INT            NULL,
        ModifiedDate        DATETIME       NULL,
        CONSTRAINT CK_MembershipPlan_PlanType CHECK (PlanType IN ('Individual', 'Family', 'Senior', 'Corporate'))
    );
    CREATE UNIQUE INDEX UX_MembershipPlan_Company_Code ON dbo.MembershipPlan (CompanyId, PlanCode);
    PRINT 'Created dbo.MembershipPlan.';
END
ELSE PRINT 'dbo.MembershipPlan already exists.';
GO

IF OBJECT_ID(N'dbo.MembershipPlanBenefit', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MembershipPlanBenefit
    (
        BenefitId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MembershipPlanBenefit PRIMARY KEY,
        PlanId          INT            NOT NULL CONSTRAINT FK_MembershipPlanBenefit_Plan REFERENCES dbo.MembershipPlan (PlanId),
        Scope           VARCHAR(20)    NOT NULL,   -- All | Department | Category | Test | Package
        ScopeRefId      INT            NULL,       -- DeptId / Category_ID / Test_ID / Profile_ID (NULL for All)
        DiscountFlag    CHAR(1)        NOT NULL CONSTRAINT DF_MembershipPlanBenefit_DiscountFlag DEFAULT 'P',   -- P = %, A = amount
        DiscountValue   DECIMAL(10,2)  NOT NULL CONSTRAINT DF_MembershipPlanBenefit_DiscountValue DEFAULT 0,
        IsExcluded      BIT            NOT NULL CONSTRAINT DF_MembershipPlanBenefit_IsExcluded DEFAULT 0,       -- 1 = no benefit on this scope
        FreeQuantity    INT            NULL,       -- counted free items per validity period
        IsActive        BIT            NOT NULL CONSTRAINT DF_MembershipPlanBenefit_IsActive DEFAULT 1,
        CreatedBy       INT            NULL,
        CreatedDate     DATETIME       NOT NULL CONSTRAINT DF_MembershipPlanBenefit_CreatedDate DEFAULT GETDATE(),
        CONSTRAINT CK_MembershipPlanBenefit_Scope CHECK (Scope IN ('All', 'Department', 'Category', 'Test', 'Package')),
        CONSTRAINT CK_MembershipPlanBenefit_DiscountFlag CHECK (DiscountFlag IN ('P', 'A'))
    );
    CREATE INDEX IX_MembershipPlanBenefit_Plan ON dbo.MembershipPlanBenefit (PlanId, IsActive);
    PRINT 'Created dbo.MembershipPlanBenefit.';
END
ELSE PRINT 'dbo.MembershipPlanBenefit already exists.';
GO

IF OBJECT_ID(N'dbo.MembershipCard', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MembershipCard
    (
        CardId              INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MembershipCard PRIMARY KEY,
        CompanyId           INT            NOT NULL,
        CardSeq             INT            NOT NULL,   -- running number per company, the digits of CardNo
        CardNo              NVARCHAR(30)   NOT NULL,
        PlanId              INT            NOT NULL CONSTRAINT FK_MembershipCard_Plan REFERENCES dbo.MembershipPlan (PlanId),
        IssueBranchId       INT            NOT NULL,
        PrimaryPatientId    INT            NOT NULL CONSTRAINT FK_MembershipCard_Patient REFERENCES dbo.PatientMaster (PatientId),
        ValidFrom           DATE           NOT NULL,
        ValidTo             DATE           NOT NULL,
        Status              VARCHAR(15)    NOT NULL CONSTRAINT DF_MembershipCard_Status DEFAULT 'Active',   -- Active | Blocked | Cancelled (expiry comes from ValidTo)
        StatusReason        NVARCHAR(250)  NULL,
        FeeAmount           DECIMAL(10,2)  NOT NULL CONSTRAINT DF_MembershipCard_FeeAmount DEFAULT 0,       -- amount collected, GST included
        FeePaymentHeaderId  INT            NULL,
        ReceiptNo           NVARCHAR(50)   NULL,
        RenewedFromCardId   INT            NULL,
        PointsBalance       DECIMAL(12,2)  NOT NULL CONSTRAINT DF_MembershipCard_PointsBalance DEFAULT 0,   -- = BalanceAfter of the last ledger row
        Remarks             NVARCHAR(250)  NULL,
        PrintCount          INT            NOT NULL CONSTRAINT DF_MembershipCard_PrintCount DEFAULT 0,
        LastPrintedOn       DATETIME       NULL,
        LastPrintedBy       INT            NULL,
        WhatsAppSentOn      DATETIME       NULL,
        EmailSentOn         DATETIME       NULL,
        CreatedBy           INT            NULL,
        CreatedDate         DATETIME       NOT NULL CONSTRAINT DF_MembershipCard_CreatedDate DEFAULT GETDATE(),
        ModifiedBy          INT            NULL,
        ModifiedDate        DATETIME       NULL,
        CONSTRAINT CK_MembershipCard_Status CHECK (Status IN ('Active', 'Blocked', 'Cancelled'))
    );
    CREATE UNIQUE INDEX UX_MembershipCard_Company_CardNo ON dbo.MembershipCard (CompanyId, CardNo);
    CREATE UNIQUE INDEX UX_MembershipCard_Company_Seq    ON dbo.MembershipCard (CompanyId, CardSeq);
    CREATE INDEX IX_MembershipCard_Patient ON dbo.MembershipCard (PrimaryPatientId);
    CREATE INDEX IX_MembershipCard_Plan    ON dbo.MembershipCard (PlanId, Status);
    PRINT 'Created dbo.MembershipCard.';
END
ELSE PRINT 'dbo.MembershipCard already exists.';
GO

IF OBJECT_ID(N'dbo.MembershipCardMember', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MembershipCardMember
    (
        CardMemberId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MembershipCardMember PRIMARY KEY,
        CardId          INT            NOT NULL CONSTRAINT FK_MembershipCardMember_Card REFERENCES dbo.MembershipCard (CardId),
        PatientId       INT            NOT NULL CONSTRAINT FK_MembershipCardMember_Patient REFERENCES dbo.PatientMaster (PatientId),
        Relation        NVARCHAR(50)   NOT NULL,   -- Self for the primary member
        IsPrimary       BIT            NOT NULL CONSTRAINT DF_MembershipCardMember_IsPrimary DEFAULT 0,
        IsActive        BIT            NOT NULL CONSTRAINT DF_MembershipCardMember_IsActive DEFAULT 1,
        CreatedBy       INT            NULL,
        CreatedDate     DATETIME       NOT NULL CONSTRAINT DF_MembershipCardMember_CreatedDate DEFAULT GETDATE()
    );
    CREATE INDEX IX_MembershipCardMember_Card    ON dbo.MembershipCardMember (CardId, IsActive);
    CREATE INDEX IX_MembershipCardMember_Patient ON dbo.MembershipCardMember (PatientId, IsActive);
    PRINT 'Created dbo.MembershipCardMember.';
END
ELSE PRINT 'dbo.MembershipCardMember already exists.';
GO

IF OBJECT_ID(N'dbo.MembershipLedger', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MembershipLedger
    (
        LedgerId        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MembershipLedger PRIMARY KEY,
        CardId          INT            NOT NULL CONSTRAINT FK_MembershipLedger_Card REFERENCES dbo.MembershipCard (CardId),
        PatientId       INT            NULL,
        BranchId        INT            NOT NULL,
        PaymentHeaderId INT            NULL,
        ReceiptNo       NVARCHAR(50)   NULL,
        TxnType         VARCHAR(15)    NOT NULL,   -- ISSUE | EARN | REDEEM | EXPIRE | REVERSE | ADJUST | DISCOUNT | MEMBER | STATUS
        Points          DECIMAL(12,2)  NOT NULL CONSTRAINT DF_MembershipLedger_Points DEFAULT 0,   -- + earned, - redeemed / expired
        Amount          DECIMAL(12,2)  NOT NULL CONSTRAINT DF_MembershipLedger_Amount DEFAULT 0,   -- fee collected / discount given
        ExpiresOn       DATE           NULL,       -- for EARN rows: when these points lapse
        BalanceAfter    DECIMAL(12,2)  NOT NULL CONSTRAINT DF_MembershipLedger_BalanceAfter DEFAULT 0,   -- points balance after this row
        Narration       NVARCHAR(300)  NULL,
        CreatedBy       INT            NULL,
        CreatedDate     DATETIME       NOT NULL CONSTRAINT DF_MembershipLedger_CreatedDate DEFAULT GETDATE(),
        CONSTRAINT CK_MembershipLedger_TxnType CHECK (TxnType IN ('ISSUE', 'EARN', 'REDEEM', 'EXPIRE', 'REVERSE', 'ADJUST', 'DISCOUNT', 'MEMBER', 'STATUS'))
    );
    CREATE INDEX IX_MembershipLedger_Card ON dbo.MembershipLedger (CardId, LedgerId);
    PRINT 'Created dbo.MembershipLedger.';
END
ELSE PRINT 'dbo.MembershipLedger already exists.';
GO

-- 2. Payment tables accept the membership module ('MEM') ------------------------
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE parent_object_id = OBJECT_ID(N'dbo.PaymentHeader') AND definition LIKE '%ModuleCode%' AND definition LIKE '%''MEM''%')
BEGIN
    DECLARE @ck SYSNAME, @sql NVARCHAR(400);
    DECLARE ckc CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.check_constraints
        WHERE parent_object_id = OBJECT_ID(N'dbo.PaymentHeader') AND definition LIKE '%ModuleCode%';
    OPEN ckc; FETCH NEXT FROM ckc INTO @ck;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE dbo.PaymentHeader DROP CONSTRAINT ' + QUOTENAME(@ck) + N';';
        EXEC sys.sp_executesql @sql;
        FETCH NEXT FROM ckc INTO @ck;
    END
    CLOSE ckc; DEALLOCATE ckc;

    ALTER TABLE dbo.PaymentHeader WITH CHECK ADD CONSTRAINT CK_PaymentHeader_ModuleCode
        CHECK (ModuleCode IN ('OPD', 'IPD', 'LAB', 'MED', 'MEM'));
    PRINT 'PaymentHeader.ModuleCode now accepts MEM.';
END
ELSE PRINT 'PaymentHeader.ModuleCode already accepts MEM.';
GO

-- 2b. Accounting ledger heads used when a card is issued (rows in the existing masters) ----
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Direct Income' OR GroupType = 'Income')
    INSERT INTO dbo.Acc_LedgerGroup (GroupName, GroupType, IsActive, CreatedDate) VALUES ('Direct Income', 'Income', 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Current Assets' OR GroupType = 'Asset')
    INSERT INTO dbo.Acc_LedgerGroup (GroupName, GroupType, IsActive, CreatedDate) VALUES ('Current Assets', 'Asset', 1, GETDATE());
GO
DECLARE @IncomeGroupId INT = (SELECT TOP 1 LedgerGroupId FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Direct Income' OR GroupType = 'Income' ORDER BY CASE WHEN GroupName = 'Direct Income' THEN 0 ELSE 1 END);
DECLARE @AssetGroupId  INT = (SELECT TOP 1 LedgerGroupId FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Current Assets' OR GroupType = 'Asset' ORDER BY CASE WHEN GroupName = 'Current Assets' THEN 0 ELSE 1 END);
DECLARE @CashGroupId   INT = ISNULL((SELECT TOP 1 LedgerGroupId FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Cash In Hand'), @AssetGroupId);

IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Revenue')
    INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate) VALUES ('Membership Revenue', @IncomeGroupId, 0, 'Cr', 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable')
    INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate) VALUES ('Patient Receivable', @AssetGroupId, 0, 'Dr', 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Cash Account')
    INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate) VALUES ('Cash Account', @CashGroupId, 0, 'Dr', 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Bank Account')
    INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate) VALUES ('Bank Account', @AssetGroupId, 0, 'Dr', 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Sales')
    INSERT INTO dbo.Acc_VoucherType (VoucherTypeName, Prefix, IsActive) VALUES ('Sales', 'SLS', 1);
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Receipt')
    INSERT INTO dbo.Acc_VoucherType (VoucherTypeName, Prefix, IsActive) VALUES ('Receipt', 'RCT', 1);
GO

-- 3. Hospital Settings parameters -----------------------------------------------
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipCardNoPrefix') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipCardNoPrefix VARCHAR(10) NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipCardNoPrefix DEFAULT 'MC';
GO
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipCardWhatsAppRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipCardWhatsAppRequired BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipCardWhatsAppRequired DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipCardEmailRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipCardEmailRequired BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipCardEmailRequired DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipCardAutoSendOnIssue') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipCardAutoSendOnIssue BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipCardAutoSendOnIssue DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'MembershipCardMessageTemplate') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD MembershipCardMessageTemplate NVARCHAR(1000) NOT NULL
        CONSTRAINT DF_HospitalSettings_MembershipCardMessageTemplate
        DEFAULT N'Dear {PatientName}, welcome to the {PlanName} membership of {HospitalName}. Your card number is {CardNo}, valid from {ValidFrom} to {ValidTo}. Your membership card is attached.';
GO

-- 4. Membership Plan master -----------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipPlan_GetList
    @CompanyId INT,
    @Status    BIT = NULL,
    @Search    NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');

    SELECT p.PlanId, p.PlanCode, p.PlanName, p.PlanType, p.CardFee, p.GstPercent, p.ValidityDays, p.MaxMembers,
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

    SELECT p.PlanId, p.CompanyId, p.PlanCode, p.PlanName, p.PlanType, p.CardFee, p.GstPercent, p.ValidityDays, p.MaxMembers,
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

-- What a benefit rule can point at. Result 1: lab departments. Result 2: test categories of the company.
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
END
GO

-- @PlanId = 0 creates (plan code generated per company: MP0001...), otherwise updates.
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
    @UserId             INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

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
            (CompanyId, PlanCode, PlanName, PlanType, CardFee, GstPercent, ValidityDays, MaxMembers, MinAge, WelcomePoints,
             PointsEarnPercent, PointValue, MaxRedeemPercent, PointsExpiryDays, FreeHomeCollection, Terms, IsActive, CreatedBy)
        VALUES
            (@CompanyId, 'MP' + RIGHT('0000' + CAST(@Next AS VARCHAR(10)), 4), @PlanName, @PlanType, @CardFee, NULLIF(@GstPercent, 0),
             @ValidityDays, @MaxMembers, @MinAge, @WelcomePoints, @PointsEarnPercent, @PointValue, @MaxRedeemPercent, @PointsExpiryDays,
             @FreeHomeCollection, NULLIF(LTRIM(RTRIM(@Terms)), ''), @IsActive, @UserId);
        SET @PlanId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.MembershipPlan
        SET PlanName = @PlanName, PlanType = @PlanType, CardFee = @CardFee, GstPercent = NULLIF(@GstPercent, 0),
            ValidityDays = @ValidityDays, MaxMembers = @MaxMembers, MinAge = @MinAge, WelcomePoints = @WelcomePoints,
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

-- A plan that has issued cards is only deactivated; an unused plan is removed from the master.
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipPlan_Delete
    @PlanId    INT,
    @CompanyId INT,
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @HasCards BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.MembershipCard WHERE PlanId = @PlanId) THEN 1 ELSE 0 END;

    UPDATE dbo.MembershipPlan
    SET IsActive = 0, IsDeleted = CASE WHEN @HasCards = 1 THEN 0 ELSE 1 END, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE PlanId = @PlanId AND CompanyId = @CompanyId AND IsDeleted = 0;
    IF @@ROWCOUNT = 0 THROW 51017, 'Membership plan not found.', 1;

    SELECT CAST(CASE WHEN @HasCards = 1 THEN 0 ELSE 1 END AS BIT) AS Removed;
END
GO

-- 5. Membership Cards -----------------------------------------------------------
-- Patient lookup of the card desk: code, name or mobile; shows the card the patient is already on, if any.
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
           ac.CardNo AS ActiveCardNo, ac.PlanName AS ActivePlanName, ac.ValidTo AS ActiveValidTo
    FROM dbo.PatientMaster pm
    OUTER APPLY (SELECT TOP 1 c.CardNo, p.PlanName, c.ValidTo
                 FROM dbo.MembershipCardMember m
                 INNER JOIN dbo.MembershipCard c ON c.CardId = m.CardId
                 INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
                 WHERE m.PatientId = pm.PatientId AND m.IsActive = 1 AND c.Status = 'Active'
                   AND c.ValidTo >= CAST(GETDATE() AS DATE) AND c.CompanyId = @CompanyId
                 ORDER BY c.ValidTo DESC) ac
    WHERE pm.CompanyId = @CompanyId AND pm.IsActive = 1
      AND (pm.PatientCode LIKE @Search + '%' OR pm.PhoneNumber LIKE @Search + '%'
           OR pm.FirstName LIKE @Search + '%' OR pm.LastName LIKE @Search + '%'
           OR CONCAT(pm.FirstName, ' ', pm.LastName) LIKE @Search + '%')
    ORDER BY pm.FirstName, pm.LastName;
END
GO

-- Issues a card: card + members + fee payment (existing payment tables, module MEM) + ledger rows, one transaction.
-- @MembersJson: [{"patientId":12,"relation":"Spouse"}] - the other members; the primary patient is added as Self.
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
        INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy)
        VALUES (@CardId, @PrimaryPatientId, @BranchId, NULL, NULL, 'EARN', @WelcomePoints, 0, DATEADD(DAY, @PointsExpiryDays, @ValidFrom), @WelcomePoints,
                'Welcome points on card issue', @UserId);
        UPDATE dbo.MembershipCard SET PointsBalance = @WelcomePoints WHERE CardId = @CardId;
    END

    COMMIT TRANSACTION;

    SELECT @CardId AS CardId, @CardNo AS CardNo, @ReceiptNo AS ReceiptNo, @PaymentHeaderId AS PaymentHeaderId, @Net AS FeeAmount;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipCard_GetList
    @CompanyId INT,
    @BranchId  INT = NULL,
    @PlanId    INT = NULL,
    @Status    VARCHAR(15) = NULL,   -- Active | Expired | Blocked | Cancelled
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
           c.ValidFrom, c.ValidTo, c.FeeAmount, c.ReceiptNo, c.PointsBalance, b.BranchName AS IssueBranchName,
           CASE WHEN c.Status = 'Active' AND c.ValidTo < @Today THEN 'Expired' ELSE c.Status END AS Status,
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

-- Result 1: the card with its plan, primary member and issuing branch. Result 2: members. Result 3: card ledger (newest first).
-- Result 4: the accounting vouchers posted for the card (Acc_LedgerTransaction), one row per debit / credit line.
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
           c.ValidFrom, c.ValidTo,
           CASE WHEN c.Status = 'Active' AND c.ValidTo < @Today THEN 'Expired' ELSE c.Status END AS Status, c.StatusReason,
           c.FeeAmount, c.FeePaymentHeaderId, c.ReceiptNo, c.PointsBalance, c.Remarks,
           c.PrintCount, c.LastPrintedOn, c.WhatsAppSentOn, c.EmailSentOn, c.CreatedDate,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS IssuedByName,
           (SELECT TOP 1 pmm.MethodName FROM dbo.PaymentDetail pd INNER JOIN dbo.PaymentMethodMaster pmm ON pmm.PaymentMethodId = pd.PaymentMethodId
            WHERE pd.PaymentHeaderId = c.FeePaymentHeaderId AND pd.IsActive = 1) AS PaymentMethodName
    FROM dbo.MembershipCard c
    INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
    INNER JOIN dbo.PatientMaster pm ON pm.PatientId = c.PrimaryPatientId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.IssueBranchId
    LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
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

    DECLARE @PlanId INT, @MaxMembers INT, @Status VARCHAR(15), @ValidTo DATE, @CardNo NVARCHAR(30), @Balance DECIMAL(12,2);
    BEGIN TRANSACTION;

    SELECT @PlanId = c.PlanId, @MaxMembers = p.MaxMembers, @Status = c.Status, @ValidTo = c.ValidTo, @CardNo = c.CardNo, @Balance = c.PointsBalance
    FROM dbo.MembershipCard c WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
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

    SET @Relation = ISNULL(NULLIF(LTRIM(RTRIM(@Relation)), ''), N'Family');
    INSERT INTO dbo.MembershipCardMember (CardId, PatientId, Relation, IsPrimary, CreatedBy) VALUES (@CardId, @PatientId, @Relation, 0, @UserId);

    INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, TxnType, Points, Amount, BalanceAfter, Narration, CreatedBy)
    SELECT @CardId, @PatientId, @BranchId, 'MEMBER', 0, 0, @Balance,
           CONCAT('Member added: ', LTRIM(RTRIM(CONCAT(pm.FirstName, ' ', pm.LastName))), ' (', @Relation, ')'), @UserId
    FROM dbo.PatientMaster pm WHERE pm.PatientId = @PatientId;

    UPDATE dbo.MembershipCard SET ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE CardId = @CardId;
    COMMIT TRANSACTION;
END
GO

-- Block a card (lost / misuse) or bring a blocked card back. Cancelled is final.
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
    IF @Old = 'Cancelled' THROW 51052, 'A cancelled card cannot be changed.', 1;
    IF @Old = @Status BEGIN COMMIT TRANSACTION; RETURN; END

    UPDATE dbo.MembershipCard SET Status = @Status, StatusReason = @Reason, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE CardId = @CardId;
    INSERT INTO dbo.MembershipLedger (CardId, BranchId, TxnType, Points, Amount, BalanceAfter, Narration, CreatedBy)
    VALUES (@CardId, @BranchId, 'STATUS', 0, 0, @Balance, LEFT(CONCAT('Card ', @Old, ' -> ', @Status, ISNULL('. ' + @Reason, '')), 300), @UserId);
    COMMIT TRANSACTION;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipCard_MarkPrinted
    @CardId    INT,
    @CompanyId INT,
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.MembershipCard
    SET PrintCount = PrintCount + 1, LastPrintedOn = GETDATE(), LastPrintedBy = @UserId
    WHERE CardId = @CardId AND CompanyId = @CompanyId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipCard_MarkSent
    @CardId    INT,
    @CompanyId INT,
    @Channel   VARCHAR(10)   -- WhatsApp | Email
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.MembershipCard
    SET WhatsAppSentOn = CASE WHEN @Channel = 'WhatsApp' THEN GETDATE() ELSE WhatsAppSentOn END,
        EmailSentOn    = CASE WHEN @Channel = 'Email'    THEN GETDATE() ELSE EmailSentOn END
    WHERE CardId = @CardId AND CompanyId = @CompanyId;
END
GO

-- 6. Starter plans (seed = starter kit; a company that already has plans is left alone) ----
DECLARE @co INT;
DECLARE sc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN sc; FETCH NEXT FROM sc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.MembershipPlan WHERE CompanyId = @co)
    BEGIN
        DECLARE @terms NVARCHAR(1000) = N'Valid at our own centres on walk-in and home-collection bills. Not valid with any other offer, package or corporate rate. Non-transferable; fee is non-refundable.';
        EXEC dbo.usp_Api_MembershipPlan_Save @PlanId = 0, @CompanyId = @co, @PlanName = N'Individual', @PlanType = 'Individual', @CardFee = 300,
             @ValidityDays = 365, @MaxMembers = 1, @PointsEarnPercent = 5, @MaxRedeemPercent = 50, @Terms = @terms,
             @BenefitsJson = N'[{"scope":"All","discountFlag":"P","discountValue":10}]';
        EXEC dbo.usp_Api_MembershipPlan_Save @PlanId = 0, @CompanyId = @co, @PlanName = N'Family', @PlanType = 'Family', @CardFee = 500,
             @ValidityDays = 365, @MaxMembers = 6, @PointsEarnPercent = 5, @MaxRedeemPercent = 50, @FreeHomeCollection = 1, @Terms = @terms,
             @BenefitsJson = N'[{"scope":"All","discountFlag":"P","discountValue":15}]';
        EXEC dbo.usp_Api_MembershipPlan_Save @PlanId = 0, @CompanyId = @co, @PlanName = N'Senior Citizen', @PlanType = 'Senior', @CardFee = 300,
             @ValidityDays = 365, @MaxMembers = 1, @MinAge = 60, @PointsEarnPercent = 5, @MaxRedeemPercent = 50, @FreeHomeCollection = 1, @Terms = @terms,
             @BenefitsJson = N'[{"scope":"All","discountFlag":"P","discountValue":20}]';
        EXEC dbo.usp_Api_MembershipPlan_Save @PlanId = 0, @CompanyId = @co, @PlanName = N'Family Plus', @PlanType = 'Family', @CardFee = 1000,
             @ValidityDays = 365, @MaxMembers = 6, @PointsEarnPercent = 10, @MaxRedeemPercent = 50, @FreeHomeCollection = 1, @Terms = @terms,
             @BenefitsJson = N'[{"scope":"All","discountFlag":"P","discountValue":20}]';
    END
    FETCH NEXT FROM sc INTO @co;
END
CLOSE sc; DEALLOCATE sc;
GO

-- 7. Authorization: two pages under Master > General ------------------------------
DECLARE @co INT, @menu INT, @page INT, @ctl INT;
DECLARE @Pages TABLE (PageCode NVARCHAR(150), Title NVARCHAR(150), Controller NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
    (N'MASTER.MEMBERSHIPPLANS', N'Membership Plan Master', N'MembershipPlans', 92, N'bi bi-award-fill me-2 text-warning'),
    (N'MASTER.MEMBERSHIPCARDS', N'Membership Cards',       N'MembershipCards', 93, N'bi bi-credit-card-2-front-fill me-2 text-primary');
DECLARE @Controls TABLE (PageCode NVARCHAR(150), Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES
    (N'MASTER.MEMBERSHIPPLANS', 'ADD', N'Add New', 20), (N'MASTER.MEMBERSHIPPLANS', 'DETAILS', N'View details', 30),
    (N'MASTER.MEMBERSHIPPLANS', 'EDIT', N'Edit', 40),   (N'MASTER.MEMBERSHIPPLANS', 'DELETE', N'Delete', 60),
    (N'MASTER.MEMBERSHIPCARDS', 'ISSUE', N'Issue card', 20),     (N'MASTER.MEMBERSHIPCARDS', 'DETAILS', N'View card', 30),
    (N'MASTER.MEMBERSHIPCARDS', 'PRINT', N'Print card', 40),     (N'MASTER.MEMBERSHIPCARDS', 'SEND', N'Send card (WhatsApp / email)', 50),
    (N'MASTER.MEMBERSHIPCARDS', 'ADDMEMBER', N'Add member', 60), (N'MASTER.MEMBERSHIPCARDS', 'STATUS', N'Block / unblock / cancel card', 70);
DECLARE @Map TABLE (PageCode NVARCHAR(150), Method VARCHAR(10), Action NVARCHAR(150), Control VARCHAR(30));
INSERT INTO @Map VALUES
    (N'MASTER.MEMBERSHIPPLANS', 'GET',  N'Index',   'VIEW'),    (N'MASTER.MEMBERSHIPPLANS', 'GET',  N'Create', 'ADD'),
    (N'MASTER.MEMBERSHIPPLANS', 'POST', N'Create',  'ADD'),     (N'MASTER.MEMBERSHIPPLANS', 'GET',  N'Edit',   'EDIT'),
    (N'MASTER.MEMBERSHIPPLANS', 'POST', N'Edit',    'EDIT'),    (N'MASTER.MEMBERSHIPPLANS', 'GET',  N'Details', 'DETAILS'),
    (N'MASTER.MEMBERSHIPPLANS', 'POST', N'Delete',  'DELETE'),
    (N'MASTER.MEMBERSHIPCARDS', 'GET',  N'Index',   'VIEW'),    (N'MASTER.MEMBERSHIPCARDS', 'GET',  N'Issue',  'ISSUE'),
    (N'MASTER.MEMBERSHIPCARDS', 'POST', N'Issue',   'ISSUE'),   (N'MASTER.MEMBERSHIPCARDS', 'GET',  N'PatientSearch', 'VIEW'),
    (N'MASTER.MEMBERSHIPCARDS', 'GET',  N'Details', 'DETAILS'), (N'MASTER.MEMBERSHIPCARDS', 'GET',  N'Card',   'PRINT'),
    (N'MASTER.MEMBERSHIPCARDS', 'POST', N'Send',    'SEND'),    (N'MASTER.MEMBERSHIPCARDS', 'POST', N'AddMember', 'ADDMEMBER'),
    (N'MASTER.MEMBERSHIPCARDS', 'POST', N'SetStatus', 'STATUS');

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.GENERAL' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        DECLARE @pc NVARCHAR(150), @pt NVARCHAR(150), @pctl NVARCHAR(100), @ps INT, @pi NVARCHAR(100);
        DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT PageCode, Title, Controller, Sort, Icon FROM @Pages;
        OPEN pg; FETCH NEXT FROM pg INTO @pc, @pt, @pctl, @ps, @pi;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @pc, @Title = @pt,
                 @Controller = @pctl, @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = @ps, @Icon = @pi, @Page_ID = @page OUTPUT;

            DECLARE @c VARCHAR(30), @t NVARCHAR(150), @s INT;
            DECLARE ctl CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls WHERE PageCode = @pc;
            OPEN ctl; FETCH NEXT FROM ctl INTO @c, @t, @s;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @c, @Title = @t, @Sort_Order = @s, @Control_ID = @ctl OUTPUT;
                FETCH NEXT FROM ctl INTO @c, @t, @s;
            END
            CLOSE ctl; DEALLOCATE ctl;

            DECLARE @m VARCHAR(10), @a NVARCHAR(150), @k VARCHAR(30);
            DECLARE mp CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Action, Control FROM @Map WHERE PageCode = @pc;
            OPEN mp; FETCH NEXT FROM mp INTO @m, @a, @k;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @ctl = NULL;
                SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @k;
                EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @m,
                     @Controller = @pctl, @Action = @a, @Source = 'SEED';
                FETCH NEXT FROM mp INTO @m, @a, @k;
            END
            CLOSE mp; DEALLOCATE mp;

            FETCH NEXT FROM pg INTO @pc, @pt, @pctl, @ps, @pi;
        END
        CLOSE pg; DEALLOCATE pg;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

PRINT '2224_membership_plan_and_card.sql applied.';
GO
