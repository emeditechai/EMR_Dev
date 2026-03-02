-- ============================================================
-- 14_payment_tables.sql
-- Payment Method Master + Payment Header + Payment Line Item + Payment Detail
-- Module-agnostic: ModuleCode = 'OPD' | 'IPD' | 'LAB' | 'MED'
-- Discount can be applied at HEADER level (overall bill) AND
-- at LINE ITEM level (per service). Both coexist so future
-- line-item-wise discount can be added without schema change.
-- ============================================================

-- ── 1. Payment Method Master ──────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'PaymentMethodMaster')
BEGIN
    CREATE TABLE PaymentMethodMaster (
        PaymentMethodId   INT           IDENTITY(1,1) PRIMARY KEY,
        MethodName        NVARCHAR(100) NOT NULL,
        MethodCode        NVARCHAR(20)  NOT NULL,           -- CASH, CARD, UPI, CHEQUE, NEFT, WALLET
        RequiresRef       BIT           NOT NULL DEFAULT 0,  -- generic transaction ref
        RequiresChequeNo  BIT           NOT NULL DEFAULT 0,
        RequiresBankName  BIT           NOT NULL DEFAULT 0,
        RequiresUPIRef    BIT           NOT NULL DEFAULT 0,
        RequiresCardLast4 BIT           NOT NULL DEFAULT 0,
        DisplayOrder      INT           NOT NULL DEFAULT 0,
        IsActive          BIT           NOT NULL DEFAULT 1,
        CreatedDate       DATETIME      NOT NULL DEFAULT GETUTCDATE()
    );
END;
GO

-- Seed default payment methods (idempotent)
IF NOT EXISTS (SELECT 1 FROM PaymentMethodMaster WHERE MethodCode = 'CASH')
    INSERT INTO PaymentMethodMaster (MethodName, MethodCode, RequiresRef, RequiresChequeNo, RequiresBankName, RequiresUPIRef, RequiresCardLast4, DisplayOrder)
    VALUES ('Cash', 'CASH', 0, 0, 0, 0, 0, 1);

IF NOT EXISTS (SELECT 1 FROM PaymentMethodMaster WHERE MethodCode = 'CARD')
    INSERT INTO PaymentMethodMaster (MethodName, MethodCode, RequiresRef, RequiresChequeNo, RequiresBankName, RequiresUPIRef, RequiresCardLast4, DisplayOrder)
    VALUES ('Card (Debit/Credit)', 'CARD', 1, 0, 1, 0, 1, 2);

IF NOT EXISTS (SELECT 1 FROM PaymentMethodMaster WHERE MethodCode = 'UPI')
    INSERT INTO PaymentMethodMaster (MethodName, MethodCode, RequiresRef, RequiresChequeNo, RequiresBankName, RequiresUPIRef, RequiresCardLast4, DisplayOrder)
    VALUES ('UPI / QR', 'UPI', 0, 0, 0, 1, 0, 3);

IF NOT EXISTS (SELECT 1 FROM PaymentMethodMaster WHERE MethodCode = 'NEFT')
    INSERT INTO PaymentMethodMaster (MethodName, MethodCode, RequiresRef, RequiresChequeNo, RequiresBankName, RequiresUPIRef, RequiresCardLast4, DisplayOrder)
    VALUES ('NEFT / RTGS', 'NEFT', 1, 0, 1, 0, 0, 4);

IF NOT EXISTS (SELECT 1 FROM PaymentMethodMaster WHERE MethodCode = 'CHEQUE')
    INSERT INTO PaymentMethodMaster (MethodName, MethodCode, RequiresRef, RequiresChequeNo, RequiresBankName, RequiresUPIRef, RequiresCardLast4, DisplayOrder)
    VALUES ('Cheque', 'CHEQUE', 0, 1, 1, 0, 0, 5);

IF NOT EXISTS (SELECT 1 FROM PaymentMethodMaster WHERE MethodCode = 'WALLET')
    INSERT INTO PaymentMethodMaster (MethodName, MethodCode, RequiresRef, RequiresChequeNo, RequiresBankName, RequiresUPIRef, RequiresCardLast4, DisplayOrder)
    VALUES ('Wallet / Paytm', 'WALLET', 1, 0, 0, 1, 0, 6);
GO

-- ── 2. Payment Header (module-agnostic, one per bill session) ─
-- ModuleCode  : 'OPD' | 'IPD' | 'LAB' | 'MED'
-- ModuleRefId : FK to the module's primary bill row
--               OPD  → PatientOPDService.OPDServiceId
--               IPD  → (future) IPDAdmission.AdmissionId
--               LAB  → (future) LabOrder.LabOrderId
--               MED  → (future) PharmacyBill.BillId
-- Discount design:
--   LineDiscountTotal   = SUM of per-line discounts (from PaymentLineItem)
--   HeaderDiscountType/Value/Amount = overall bill-level discount on top
--   NetAmount = SubTotal - LineDiscountTotal - HeaderDiscountAmount
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'PaymentHeader')
BEGIN
    CREATE TABLE PaymentHeader (
        PaymentHeaderId      INT            IDENTITY(1,1) PRIMARY KEY,

        -- Module identification
        ModuleCode           CHAR(3)        NOT NULL,           -- 'OPD','IPD','LAB','MED'
        ModuleRefId          INT            NOT NULL,

        -- OPD-specific direct reference (populated when ModuleCode = 'OPD')
        -- A payment in OPD always ties to both PatientId AND OPDServiceId.
        -- Keeping it as a dedicated column allows simple joins without CASE on ModuleCode.
        OPDServiceId         INT            NULL,               -- FK → PatientOPDService.OPDServiceId

        BranchId             INT            NOT NULL,
        PatientId            INT            NOT NULL,

        -- Financial (gross)
        SubTotal             DECIMAL(10,2)  NOT NULL DEFAULT 0,  -- sum of all line OriginalAmount

        -- Line-item discount aggregate (computed from PaymentLineItem rows)
        LineDiscountTotal    DECIMAL(10,2)  NOT NULL DEFAULT 0,

        -- Header-level (overall bill) discount
        HeaderDiscountType   CHAR(1)        NULL,                -- 'P' = %, 'F' = fixed Rs
        HeaderDiscountValue  DECIMAL(10,2)  NULL    DEFAULT 0,   -- value as entered
        HeaderDiscountAmount DECIMAL(10,2)  NOT NULL DEFAULT 0,  -- computed Rs amount

        -- Final
        NetAmount            DECIMAL(10,2)  NOT NULL DEFAULT 0,  -- SubTotal - LineDiscountTotal - HeaderDiscountAmount
        TotalPaid            DECIMAL(10,2)  NOT NULL DEFAULT 0,  -- SUM of PaymentDetail.PaidAmount
        BalanceDue           DECIMAL(10,2)  NOT NULL DEFAULT 0,  -- NetAmount - TotalPaid

        -- Status: P = Paid, R = Partial, U = Unpaid
        PaymentStatus        CHAR(1)        NOT NULL DEFAULT 'U',
        Notes                NVARCHAR(500)  NULL,

        CreatedDate          DATETIME       NOT NULL DEFAULT GETUTCDATE(),
        CreatedBy            INT            NULL,
        LastModifiedDate     DATETIME       NULL,
        LastModifiedBy       INT            NULL,
        IsActive             BIT            NOT NULL DEFAULT 1,

        CONSTRAINT FK_PaymentHeader_Branch
            FOREIGN KEY (BranchId)    REFERENCES Branchmaster(BranchID),
        CONSTRAINT FK_PaymentHeader_Patient
            FOREIGN KEY (PatientId)   REFERENCES PatientMaster(PatientId),
        CONSTRAINT FK_PaymentHeader_OPDService
            FOREIGN KEY (OPDServiceId) REFERENCES PatientOPDService(OPDServiceId),
        CONSTRAINT CK_PaymentHeader_ModuleCode
            CHECK (ModuleCode IN ('OPD','IPD','LAB','MED'))
    );

    CREATE INDEX IX_PaymentHeader_Module     ON PaymentHeader(ModuleCode, ModuleRefId);
    CREATE INDEX IX_PaymentHeader_Branch     ON PaymentHeader(BranchId, CreatedDate);
    CREATE INDEX IX_PaymentHeader_Patient    ON PaymentHeader(PatientId);
    CREATE INDEX IX_PaymentHeader_OPDService ON PaymentHeader(OPDServiceId);
END;
GO

-- ── 3. Payment Line Item (one row per service/charge line) ────
-- Mirrors the bill's service lines and holds PER-LINE discount.
-- Phase 1: auto-populated with 0 discount (header discount used).
-- Phase 2: UI can allow per-line discount editing.
-- ModuleLineRefId: OPD → PatientOPDServiceItem.ItemId
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'PaymentLineItem')
BEGIN
    CREATE TABLE PaymentLineItem (
        PaymentLineItemId INT            IDENTITY(1,1) PRIMARY KEY,
        PaymentHeaderId   INT            NOT NULL,
        ModuleLineRefId   INT            NOT NULL,           -- e.g., PatientOPDServiceItem.ItemId
        ItemDescription   NVARCHAR(200)  NULL,               -- snapshot of item name
        ServiceType       NVARCHAR(50)   NULL,               -- snapshot of type (Consulting/Service)
        OriginalAmount    DECIMAL(10,2)  NOT NULL DEFAULT 0, -- snapshot of item charge

        -- Per-line discount (null = no line-level discount applied)
        LineDiscountType  CHAR(1)        NULL,               -- 'P' = %, 'F' = fixed Rs
        LineDiscountValue DECIMAL(10,2)  NULL DEFAULT 0,
        LineDiscountAmount DECIMAL(10,2) NOT NULL DEFAULT 0, -- computed Rs discount
        NetLineAmount     DECIMAL(10,2)  NOT NULL DEFAULT 0, -- OriginalAmount - LineDiscountAmount

        CreatedDate       DATETIME       NOT NULL DEFAULT GETUTCDATE(),
        CreatedBy         INT            NULL,
        IsActive          BIT            NOT NULL DEFAULT 1,

        CONSTRAINT FK_PaymentLineItem_Header
            FOREIGN KEY (PaymentHeaderId) REFERENCES PaymentHeader(PaymentHeaderId)
    );

    CREATE INDEX IX_PaymentLineItem_HeaderId ON PaymentLineItem(PaymentHeaderId);
END;
GO

-- ── 4. Payment Detail (one row per payment instrument) ────────
-- Supports split payments: Cash + UPI etc. in one session.
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'PaymentDetail')
BEGIN
    CREATE TABLE PaymentDetail (
        PaymentDetailId  INT            IDENTITY(1,1) PRIMARY KEY,
        PaymentHeaderId  INT            NOT NULL,
        PaymentMethodId  INT            NOT NULL,
        PaidAmount       DECIMAL(10,2)  NOT NULL DEFAULT 0,

        -- Method-specific fields (nullable; filled per method used)
        TransactionRef   NVARCHAR(100)  NULL,    -- CARD/NEFT/WALLET ref no.
        ChequeNo         NVARCHAR(50)   NULL,
        BankName         NVARCHAR(100)  NULL,
        UPIRefNo         NVARCHAR(100)  NULL,    -- UPI UTR or VPA
        CardLast4        CHAR(4)        NULL,

        PaymentDate      DATETIME       NOT NULL DEFAULT GETUTCDATE(),
        Notes            NVARCHAR(300)  NULL,

        CreatedDate      DATETIME       NOT NULL DEFAULT GETUTCDATE(),
        CreatedBy        INT            NULL,
        IsActive         BIT            NOT NULL DEFAULT 1,

        CONSTRAINT FK_PaymentDetail_Header
            FOREIGN KEY (PaymentHeaderId) REFERENCES PaymentHeader(PaymentHeaderId),
        CONSTRAINT FK_PaymentDetail_Method
            FOREIGN KEY (PaymentMethodId) REFERENCES PaymentMethodMaster(PaymentMethodId)
    );

    CREATE INDEX IX_PaymentDetail_HeaderId ON PaymentDetail(PaymentHeaderId);
END;
GO

PRINT '14_payment_tables.sql applied successfully.';
