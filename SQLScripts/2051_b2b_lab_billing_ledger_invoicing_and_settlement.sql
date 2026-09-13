-- ============================================================================
-- Migration: 2051_b2b_lab_billing_ledger_invoicing_and_settlement.sql
-- Description:
--   1. Create tables: LabFranchiseWallet, LabFranchiseWalletTransaction,
--      B2BInvoice, B2BInvoiceItem.
--   2. Add DueDate to LabOrder if not exists.
--   3. Create Stored Procedures:
--      - usp_B2B_GetPartnerCreditStatus
--      - usp_B2B_PostBillLedger
--      - usp_B2B_DeductWalletPayment
--      - usp_B2B_FranchiseWallet_TopUp
--      - usp_B2B_GetFranchiseWalletStatement
--      - usp_B2B_GetUninvoicedOrders
--      - usp_B2B_GenerateInvoice
--      - usp_B2B_GetInvoiceList
--      - usp_B2B_GetInvoiceDetail
--      - usp_B2B_GetOutstandingBillsForSettlement
--      - usp_B2B_SettleBillsPayment
-- ============================================================================

USE [Dev_EMR];
GO

-- ── 1. Create Tables ─────────────────────────────────────────────────────────

-- 1.1 LabFranchiseWallet
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabFranchiseWallet' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabFranchiseWallet
    (
        WalletId        INT IDENTITY(1,1) PRIMARY KEY,
        Franchise_ID    INT NOT NULL UNIQUE,
        CurrentBalance  DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        LastUpdatedDate DATETIME2 NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_LabFranchiseWallet_Franchise FOREIGN KEY (Franchise_ID) REFERENCES dbo.LabFranchiseMaster(Franchise_ID) ON DELETE CASCADE
    );
    CREATE INDEX IX_LabFranchiseWallet_FranchiseID ON dbo.LabFranchiseWallet(Franchise_ID);
    PRINT 'Created table dbo.LabFranchiseWallet';
END
GO

-- 1.2 LabFranchiseWalletTransaction
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabFranchiseWalletTransaction' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabFranchiseWalletTransaction
    (
        TransactionId   BIGINT IDENTITY(1,1) PRIMARY KEY,
        Franchise_ID    INT NOT NULL,
        TransactionType VARCHAR(20) NOT NULL, -- 'CREDIT' (Top-Up), 'DEBIT' (Bill Deduction)
        Amount          DECIMAL(18,2) NOT NULL,
        BalanceAfter    DECIMAL(18,2) NOT NULL,
        ReferenceType   VARCHAR(50) NOT NULL, -- 'TOPUP', 'LAB_BILL'
        ReferenceId     INT NULL,             -- LabOrderId or TopUp Id
        ReceiptNo       NVARCHAR(50) NULL,
        Narration       NVARCHAR(500) NULL,
        CreatedBy       INT NULL,
        CreatedDate     DATETIME2 NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_LabFranchiseWalletTx_Franchise FOREIGN KEY (Franchise_ID) REFERENCES dbo.LabFranchiseMaster(Franchise_ID)
    );
    CREATE INDEX IX_LabFranchiseWalletTx_FranchiseID ON dbo.LabFranchiseWalletTransaction(Franchise_ID, CreatedDate DESC);
    PRINT 'Created table dbo.LabFranchiseWalletTransaction';
END
GO

-- 1.3 B2BInvoice
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'B2BInvoice' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.B2BInvoice
    (
        InvoiceId       INT IDENTITY(1,1) PRIMARY KEY,
        InvoiceNo       NVARCHAR(50) NOT NULL UNIQUE,
        PartnerType     VARCHAR(10) NOT NULL, -- 'F' (Franchise), 'C' (Corporate)
        PartnerId       INT NOT NULL,
        BranchId        INT NOT NULL,
        BillingCycle    NVARCHAR(50) NULL,    -- Monthly, Weekly, Fortnightly, On-Demand
        InvoiceDate     DATETIME2 NOT NULL DEFAULT GETDATE(),
        DueDate         DATETIME2 NOT NULL,
        TotalAmount     DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        DiscountAmount  DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        TaxAmount       DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        NetAmount       DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        PaidAmount      DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        BalanceAmount   DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        Status          VARCHAR(10) NOT NULL DEFAULT 'U', -- 'U' = Unpaid, 'R' = Partial, 'P' = Paid, 'C' = Cancelled
        Notes           NVARCHAR(MAX) NULL,
        CreatedBy       INT NULL,
        CreatedDate     DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy      INT NULL,
        ModifiedDate    DATETIME2 NULL
    );
    CREATE INDEX IX_B2BInvoice_Partner ON dbo.B2BInvoice(PartnerType, PartnerId, Status);
    CREATE INDEX IX_B2BInvoice_InvoiceDate ON dbo.B2BInvoice(InvoiceDate DESC);
    PRINT 'Created table dbo.B2BInvoice';
END
GO

-- 1.4 B2BInvoiceItem
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'B2BInvoiceItem' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.B2BInvoiceItem
    (
        InvoiceItemId   INT IDENTITY(1,1) PRIMARY KEY,
        InvoiceId       INT NOT NULL,
        LabOrderId      INT NOT NULL,
        BillNo          NVARCHAR(50) NULL,
        OrderDate       DATETIME2 NOT NULL,
        PatientName     NVARCHAR(200) NULL,
        B2BTotal        DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        Amount          DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        CONSTRAINT FK_B2BInvoiceItem_Invoice FOREIGN KEY (InvoiceId) REFERENCES dbo.B2BInvoice(InvoiceId) ON DELETE CASCADE,
        CONSTRAINT FK_B2BInvoiceItem_LabOrder FOREIGN KEY (LabOrderId) REFERENCES dbo.LabOrder(LabOrderId)
    );
    CREATE INDEX IX_B2BInvoiceItem_InvoiceId ON dbo.B2BInvoiceItem(InvoiceId);
    CREATE INDEX IX_B2BInvoiceItem_LabOrderId ON dbo.B2BInvoiceItem(LabOrderId);
    PRINT 'Created table dbo.B2BInvoiceItem';
END
GO

-- 1.5 Add DueDate column to LabOrder if not exists
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabOrder') AND name = 'DueDate')
BEGIN
    ALTER TABLE dbo.LabOrder ADD DueDate DATETIME2 NULL;
    PRINT 'Added DueDate column to dbo.LabOrder';
END
GO

-- ── 2. Ensure Required Ledgers Exist in Acc_LedgerMaster ───────────────────────

-- Ensure groups
IF NOT EXISTS (SELECT 1 FROM Acc_LedgerGroup WHERE GroupName = 'Current Assets' OR GroupType = 'Asset')
    INSERT INTO Acc_LedgerGroup (GroupName, GroupType, IsActive, CreatedDate) VALUES ('Current Assets', 'Asset', 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM Acc_LedgerGroup WHERE GroupName = 'Current Liabilities' OR GroupType = 'Liability')
    INSERT INTO Acc_LedgerGroup (GroupName, GroupType, IsActive, CreatedDate) VALUES ('Current Liabilities', 'Liability', 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM Acc_LedgerGroup WHERE GroupName = 'Bank Accounts')
    INSERT INTO Acc_LedgerGroup (GroupName, GroupType, IsActive, CreatedDate) VALUES ('Bank Accounts', 'Asset', 1, GETDATE());

-- Ensure ledgers
DECLARE @AssetGrp INT = (SELECT TOP 1 LedgerGroupId FROM Acc_LedgerGroup WHERE GroupName = 'Current Assets' OR GroupType = 'Asset');
DECLARE @LiabGrp INT = (SELECT TOP 1 LedgerGroupId FROM Acc_LedgerGroup WHERE GroupName = 'Current Liabilities' OR GroupType = 'Liability');
DECLARE @BankGrp INT = (SELECT TOP 1 LedgerGroupId FROM Acc_LedgerGroup WHERE GroupName = 'Bank Accounts' OR GroupType = 'Asset');

IF NOT EXISTS (SELECT 1 FROM Acc_LedgerMaster WHERE LedgerName = 'Franchise Receivable')
    INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
    VALUES ('Franchise Receivable', @AssetGrp, 0, 'Dr', 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM Acc_LedgerMaster WHERE LedgerName = 'Corporate Receivable')
    INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
    VALUES ('Corporate Receivable', @AssetGrp, 0, 'Dr', 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM Acc_LedgerMaster WHERE LedgerName = 'Franchise Wallet (Advance)')
    INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
    VALUES ('Franchise Wallet (Advance)', @LiabGrp, 0, 'Cr', 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM Acc_LedgerMaster WHERE LedgerName = 'Bank Account')
    INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
    VALUES ('Bank Account', ISNULL(@BankGrp, @AssetGrp), 0, 'Dr', 1, GETDATE());
GO

-- ── 3. Stored Procedure: usp_B2B_GetPartnerCreditStatus ────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetPartnerCreditStatus
    @AgentType VARCHAR(10), -- 'F' or 'C'
    @AgentId   INT,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @AgentType = 'F'
    BEGIN
        -- Franchise Details
        DECLARE @FranchiseName NVARCHAR(100), @FranchiseCode NVARCHAR(50), @IsActive BIT, @IsSuspended BIT;
        DECLARE @CreditFacilityType INT = 1; -- Default 1: Prepaid
        DECLARE @CreditLimit DECIMAL(18,2) = 0.00;
        DECLARE @TempLimit DECIMAL(18,2) = 0.00;
        DECLARE @TempValidTill DATE = NULL;
        DECLARE @CreditDays INT = 0;
        DECLARE @GraceDays INT = 0;
        DECLARE @WalletBalance DECIMAL(18,2) = 0.00;
        DECLARE @CurrentOutstanding DECIMAL(18,2) = 0.00;

        SELECT 
            @FranchiseName = f.Franchise_Name,
            @FranchiseCode = f.Franchise_Code,
            @IsActive = f.IsActive,
            @IsSuspended = f.Status,
            @CreditFacilityType = ISNULL(c.Credit_Facility_Type, 1),
            @CreditLimit = ISNULL(c.Credit_Limit, 0.00),
            @TempLimit = ISNULL(c.Temporary_Limit_Increase, 0.00),
            @TempValidTill = c.Temp_Limit_Valid_Till,
            @CreditDays = ISNULL(c.Credit_Days, 0),
            @GraceDays = ISNULL(c.Grace_Days, 0),
            @WalletBalance = ISNULL(w.CurrentBalance, 0.00)
        FROM dbo.LabFranchiseMaster f
        LEFT JOIN dbo.LabFranchiseCreditLimitMaster c ON c.Franchise_ID = f.Franchise_ID
        LEFT JOIN dbo.LabFranchiseWallet w ON w.Franchise_ID = f.Franchise_ID
        WHERE f.Franchise_ID = @AgentId;

        IF @FranchiseName IS NULL
        BEGIN
            SELECT 0 AS Found, 'Franchise not found.' AS Message;
            RETURN;
        END

        -- Add temporary limit if valid
        IF @TempValidTill IS NOT NULL AND @TempValidTill >= CAST(GETDATE() AS DATE)
            SET @CreditLimit = @CreditLimit + @TempLimit;

        -- Calculate Current Outstanding from all unpaid/partial B2B LabOrders for this franchise
        SELECT @CurrentOutstanding = ISNULL(SUM(
            CASE 
                WHEN ph.PaymentHeaderId IS NOT NULL THEN ph.BalanceDue
                ELSE ISNULL(lo.B2BTotal, lo.TotalAmount)
            END
        ), 0.00)
        FROM dbo.LabOrder lo
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        WHERE lo.IsB2B = 1 
          AND lo.AgentType = 'F' 
          AND lo.B2BAgentID = @AgentId 
          AND lo.IsActive = 1
          AND (ph.PaymentStatus IS NULL OR ph.PaymentStatus IN ('U', 'R'));

        DECLARE @AvailableCredit DECIMAL(18,2) = CASE 
            WHEN @CreditFacilityType = 1 THEN 0.00
            ELSE (@CreditLimit - @CurrentOutstanding)
        END;

        DECLARE @CanBook BIT = 1;
        DECLARE @BlockReason NVARCHAR(500) = NULL;

        IF @IsActive = 0
        BEGIN
            SET @CanBook = 0;
            SET @BlockReason = 'Franchise account is inactive.';
        END
        ELSE IF @IsSuspended = 1
        BEGIN
            SET @CanBook = 0;
            SET @BlockReason = 'Franchise account is suspended.';
        END
        ELSE IF @CreditFacilityType = 2 AND @CreditLimit > 0 AND @AvailableCredit <= 0
        BEGIN
            SET @CanBook = 0;
            SET @BlockReason = 'Credit limit exhausted. Outstanding (₹' + FORMAT(@CurrentOutstanding, 'N2') + ') meets or exceeds limit (₹' + FORMAT(@CreditLimit, 'N2') + ').';
        END

        SELECT 
            1 AS Found,
            @AgentType AS AgentType,
            @AgentId AS AgentId,
            @FranchiseName AS PartnerName,
            @FranchiseCode AS PartnerCode,
            @CreditFacilityType AS CreditFacilityType,
            CASE @CreditFacilityType
                WHEN 1 THEN 'Prepaid (Wallet)'
                WHEN 2 THEN 'Postpaid (Credit)'
                WHEN 3 THEN 'Hybrid'
                ELSE 'Prepaid (Wallet)'
            END AS CreditFacilityTypeName,
            @CreditLimit AS CreditLimit,
            @CreditDays AS CreditDays,
            @GraceDays AS GraceDays,
            CAST(NULL AS NVARCHAR(50)) AS BillingCycle,
            CAST(NULL AS DATETIME2) AS EffectiveFrom,
            CAST(NULL AS DATETIME2) AS EffectiveTo,
            CAST(1 AS BIT) AS IsContractValid,
            @WalletBalance AS WalletBalance,
            @CurrentOutstanding AS CurrentOutstanding,
            @AvailableCredit AS AvailableCredit,
            @CanBook AS CanBook,
            @BlockReason AS BlockReason;
    END
    ELSE IF @AgentType = 'C'
    BEGIN
        -- Corporate Details
        DECLARE @CorpName NVARCHAR(200), @CorpCode NVARCHAR(50), @CorpActive BIT;
        DECLARE @EffectiveFrom DATETIME2, @EffectiveTo DATETIME2;
        DECLARE @CorpCreditLimit DECIMAL(18,2) = 0.00;
        DECLARE @CorpCreditDays INT = 0;
        DECLARE @BillingCycle NVARCHAR(50) = 'Monthly';
        DECLARE @CorpOutstanding DECIMAL(18,2) = 0.00;

        SELECT 
            @CorpName = c.Corporate_Name,
            @CorpCode = c.Corporate_Code,
            @CorpActive = c.Status,
            @EffectiveFrom = c.Effective_From,
            @EffectiveTo = c.Effective_To,
            @CorpCreditLimit = ISNULL(c.Credit_Limit, 0.00),
            @CorpCreditDays = ISNULL(c.Credit_Days, 0),
            @BillingCycle = ISNULL(c.BillingCycle, 'Monthly')
        FROM dbo.CorporateMaster c
        WHERE c.Corporate_ID = @AgentId;

        IF @CorpName IS NULL
        BEGIN
            SELECT 0 AS Found, 'Corporate company not found.' AS Message;
            RETURN;
        END

        -- Calculate Outstanding
        SELECT @CorpOutstanding = ISNULL(SUM(
            CASE 
                WHEN ph.PaymentHeaderId IS NOT NULL THEN ph.BalanceDue
                ELSE ISNULL(lo.B2BTotal, lo.TotalAmount)
            END
        ), 0.00)
        FROM dbo.LabOrder lo
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        WHERE lo.IsB2B = 1 
          AND lo.AgentType = 'C' 
          AND lo.B2BAgentID = @AgentId 
          AND lo.IsActive = 1
          AND (ph.PaymentStatus IS NULL OR ph.PaymentStatus IN ('U', 'R'));

        DECLARE @CorpAvailableCredit DECIMAL(18,2) = @CorpCreditLimit - @CorpOutstanding;
        DECLARE @IsContractValid BIT = 0;

        IF CAST(GETDATE() AS DATE) BETWEEN CAST(@EffectiveFrom AS DATE) AND CAST(@EffectiveTo AS DATE)
            SET @IsContractValid = 1;

        DECLARE @CorpCanBook BIT = 1;
        DECLARE @CorpBlockReason NVARCHAR(500) = NULL;

        IF @CorpActive = 0
        BEGIN
            SET @CorpCanBook = 0;
            SET @CorpBlockReason = 'Corporate tie-up account is inactive.';
        END
        ELSE IF @IsContractValid = 0
        BEGIN
            SET @CorpCanBook = 0;
            SET @CorpBlockReason = 'Corporate tie-up contract is not active (Valid from ' + FORMAT(@EffectiveFrom, 'dd/MM/yyyy') + ' to ' + FORMAT(@EffectiveTo, 'dd/MM/yyyy') + ').';
        END
        ELSE IF @CorpCreditLimit > 0 AND @CorpAvailableCredit <= 0
        BEGIN
            SET @CorpCanBook = 0;
            SET @CorpBlockReason = 'Corporate credit limit exhausted. Outstanding (₹' + FORMAT(@CorpOutstanding, 'N2') + ') meets or exceeds limit (₹' + FORMAT(@CorpCreditLimit, 'N2') + ').';
        END

        SELECT 
            1 AS Found,
            @AgentType AS AgentType,
            @AgentId AS AgentId,
            @CorpName AS PartnerName,
            @CorpCode AS PartnerCode,
            2 AS CreditFacilityType, -- Corporate is postpaid
            'Postpaid (Credit)' AS CreditFacilityTypeName,
            @CorpCreditLimit AS CreditLimit,
            @CorpCreditDays AS CreditDays,
            0 AS GraceDays,
            @BillingCycle AS BillingCycle,
            @EffectiveFrom AS EffectiveFrom,
            @EffectiveTo AS EffectiveTo,
            @IsContractValid AS IsContractValid,
            0.00 AS WalletBalance,
            @CorpOutstanding AS CurrentOutstanding,
            @CorpAvailableCredit AS AvailableCredit,
            @CorpCanBook AS CanBook,
            @CorpBlockReason AS BlockReason;
    END
END;
GO

-- ── 4. Stored Procedure: usp_B2B_PostBillLedger ────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_PostBillLedger
    @LabOrderId INT,
    @Amount     DECIMAL(18,2),
    @AgentType  VARCHAR(10), -- 'F' or 'C'
    @AgentId    INT,
    @BranchId   INT,
    @CompanyId  INT = 1,
    @UserId     INT = 1,
    @BillNo     NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Amount <= 0 RETURN;

    -- Avoid duplicate posting
    IF EXISTS (SELECT 1 FROM Acc_LedgerTransaction WHERE ReferenceType = 'B2B_LAB_BILL' AND ReferenceId = @LabOrderId)
        RETURN;

    DECLARE @VoucherTypeId INT = (SELECT TOP 1 VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = 'Sales');
    IF @VoucherTypeId IS NULL
    BEGIN
        INSERT INTO Acc_VoucherType (VoucherTypeName, Prefix, IsActive) VALUES ('Sales', 'SLS', 1);
        SET @VoucherTypeId = SCOPE_IDENTITY();
    END

    DECLARE @DebitLedgerName NVARCHAR(100);
    SET @DebitLedgerName = CASE WHEN @AgentType = 'C' THEN 'Corporate Receivable' ELSE 'Franchise Receivable' END;
    
    DECLARE @DebitLedgerId INT;
    SELECT TOP 1 @DebitLedgerId = LedgerId FROM Acc_LedgerMaster WHERE LedgerName = @DebitLedgerName;
    IF @DebitLedgerId IS NULL
    BEGIN
        DECLARE @AssetGrp INT;
        SELECT TOP 1 @AssetGrp = LedgerGroupId FROM Acc_LedgerGroup WHERE GroupName = 'Current Assets' OR GroupType = 'Asset';
        INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
        VALUES (@DebitLedgerName, @AssetGrp, 0, 'Dr', 1, GETDATE());
        SET @DebitLedgerId = SCOPE_IDENTITY();
    END

    DECLARE @CreditLedgerId INT;
    SELECT TOP 1 @CreditLedgerId = LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'LAB Revenue';
    IF @CreditLedgerId IS NULL
    BEGIN
        DECLARE @IncomeGrp INT;
        SELECT TOP 1 @IncomeGrp = LedgerGroupId FROM Acc_LedgerGroup WHERE GroupName = 'Direct Income' OR GroupType = 'Income';
        INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
        VALUES ('LAB Revenue', @IncomeGrp, 0, 'Cr', 1, GETDATE());
        SET @CreditLedgerId = SCOPE_IDENTITY();
    END

    DECLARE @Narration NVARCHAR(MAX);
    SET @Narration = 'Revenue recognized for B2B LAB Bill ' + ISNULL(@BillNo, '') + ' (' + @DebitLedgerName + ' #' + CAST(@AgentId AS NVARCHAR(20)) + ')';
    DECLARE @NewTxId BIGINT;
    DECLARE @TxDate DATETIME = GETDATE();

    EXEC dbo.usp_Ledger_PostEntry
        @VoucherTypeId   = @VoucherTypeId,
        @TransactionDate = @TxDate,
        @ReferenceType   = 'B2B_LAB_BILL',
        @ReferenceId     = @LabOrderId,
        @BranchId        = @BranchId,
        @CompanyId       = @CompanyId,
        @TotalAmount     = @Amount,
        @Narration       = @Narration,
        @DebitLedgerId   = @DebitLedgerId,
        @CreditLedgerId  = @CreditLedgerId,
        @CreatedBy       = @UserId,
        @NewTransactionId = @NewTxId OUTPUT;

    SELECT @NewTxId AS TransactionId;
END;
GO

-- ── 5. Stored Procedure: usp_B2B_DeductWalletPayment ───────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_DeductWalletPayment
    @LabOrderId   INT,
    @FranchiseId  INT,
    @Amount       DECIMAL(18,2),
    @BranchId     INT,
    @UserId       INT,
    @BillNo       NVARCHAR(50),
    @ReceiptNo    NVARCHAR(50) OUTPUT,
    @TokenNo      NVARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Check wallet balance
        DECLARE @CurrentBalance DECIMAL(18,2) = 0.00;
        SELECT @CurrentBalance = CurrentBalance FROM dbo.LabFranchiseWallet WHERE Franchise_ID = @FranchiseId;

        IF @CurrentBalance < @Amount
        BEGIN
            THROW 50001, 'Insufficient franchise wallet balance for deduction.', 1;
        END

        -- 2. Deduct from wallet
        DECLARE @NewBalance DECIMAL(18,2) = @CurrentBalance - @Amount;
        UPDATE dbo.LabFranchiseWallet
        SET CurrentBalance = @NewBalance,
            LastUpdatedDate = GETDATE()
        WHERE Franchise_ID = @FranchiseId;

        -- 3. Generate Receipt Number
        DECLARE @BranchCode NVARCHAR(20) = (SELECT TOP 1 BranchCode FROM dbo.Branchmaster WHERE BranchId = @BranchId);
        IF @BranchCode IS NULL SET @BranchCode = 'BR';
        DECLARE @FinYear NVARCHAR(20) = CASE WHEN MONTH(GETDATE()) >= 4 THEN CAST(YEAR(GETDATE()) AS VARCHAR(4)) + '-' + CAST(YEAR(GETDATE()) + 1 AS VARCHAR(4)) ELSE CAST(YEAR(GETDATE()) - 1 AS VARCHAR(4)) + '-' + CAST(YEAR(GETDATE()) AS VARCHAR(4)) END;
        DECLARE @DatePart NVARCHAR(20) = FORMAT(GETDATE(), 'ddMMyyyy');

        DECLARE @NextSeq INT;
        UPDATE ReceiptSequence SET @NextSeq = LastSeq = LastSeq + 1 WHERE BranchId = @BranchId AND FinancialYear = @FinYear;
        IF @NextSeq IS NULL
        BEGIN
            SET @NextSeq = 1;
            INSERT INTO ReceiptSequence (BranchId, FinancialYear, LastSeq) VALUES (@BranchId, @FinYear, @NextSeq);
        END
        SET @ReceiptNo = @BranchCode + @DatePart + RIGHT('000000' + CAST(@NextSeq AS VARCHAR(10)), 6);

        -- 4. Record Wallet Transaction
        INSERT INTO dbo.LabFranchiseWalletTransaction
            (Franchise_ID, TransactionType, Amount, BalanceAfter, ReferenceType, ReferenceId, ReceiptNo, Narration, CreatedBy, CreatedDate)
        VALUES
            (@FranchiseId, 'DEBIT', @Amount, @NewBalance, 'LAB_BILL', @LabOrderId, @ReceiptNo, 'Bill payment deducted for LAB Bill ' + @BillNo, @UserId, GETDATE());

        -- 5. Insert or Update PaymentHeader
        DECLARE @PaymentHeaderId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = 'LAB' AND ModuleRefId = @LabOrderId AND IsActive = 1);
        DECLARE @PatientId INT = (SELECT TOP 1 PatientId FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId);

        IF @PaymentHeaderId IS NULL
        BEGIN
            INSERT INTO dbo.PaymentHeader
                (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive)
            VALUES
                ('LAB', @LabOrderId, @BranchId, @PatientId, @Amount, @Amount, @Amount, 0.00, 'P', 'Paid via Franchise Wallet', GETDATE(), @UserId, 1);
            SET @PaymentHeaderId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE dbo.PaymentHeader
            SET TotalPaid = TotalPaid + @Amount,
                BalanceDue = 0.00,
                PaymentStatus = 'P',
                LastModifiedDate = GETDATE(),
                LastModifiedBy = @UserId
            WHERE PaymentHeaderId = @PaymentHeaderId;
        END

        -- 6. Insert PaymentDetail
        DECLARE @WalletMethodId INT = (SELECT TOP 1 PaymentMethodId FROM PaymentMethodMaster WHERE MethodCode = 'WALLET');
        IF @WalletMethodId IS NULL SET @WalletMethodId = 1;

        INSERT INTO dbo.PaymentDetail
            (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo)
        VALUES
            (@PaymentHeaderId, @WalletMethodId, @Amount, 'WALLET-DEBIT-' + @ReceiptNo, GETDATE(), 'Franchise Wallet Auto-Deduction', GETDATE(), @UserId, 1, @ReceiptNo);

        -- 7. Assign Token
        EXEC dbo.usp_LAB_AssignTokenOnPayment @LabOrderId = @LabOrderId, @TokenNo = @TokenNo OUTPUT;

        -- 8. Post Payment Ledger (Dr Franchise Wallet (Advance), Cr Franchise Receivable)
        DECLARE @VoucherTypeId INT = (SELECT TOP 1 VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
        IF @VoucherTypeId IS NULL
        BEGIN
            INSERT INTO Acc_VoucherType (VoucherTypeName, Prefix, IsActive) VALUES ('Receipt', 'RCT', 1);
            SET @VoucherTypeId = SCOPE_IDENTITY();
        END

        DECLARE @DebitLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Franchise Wallet (Advance)');
        DECLARE @CreditLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Franchise Receivable');
        DECLARE @NewTxId BIGINT;
        DECLARE @TxDate DATETIME = GETDATE();

        DECLARE @WalletNarration NVARCHAR(500) = 'Wallet payment settlement for LAB Bill ' + @BillNo + ' (Receipt: ' + @ReceiptNo + ')';

        IF @DebitLedgerId IS NOT NULL AND @CreditLedgerId IS NOT NULL
        BEGIN
            EXEC dbo.usp_Ledger_PostEntry
                @VoucherTypeId   = @VoucherTypeId,
                @TransactionDate = @TxDate,
                @ReferenceType   = 'B2B_WALLET_PAY',
                @ReferenceId     = @LabOrderId,
                @BranchId        = @BranchId,
                @CompanyId       = 1,
                @TotalAmount     = @Amount,
                @Narration       = @WalletNarration,
                @DebitLedgerId   = @DebitLedgerId,
                @CreditLedgerId  = @CreditLedgerId,
                @CreatedBy       = @UserId,
                @NewTransactionId = @NewTxId OUTPUT;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── 6. Stored Procedure: usp_B2B_FranchiseWallet_TopUp ─────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_FranchiseWallet_TopUp
    @FranchiseId      INT,
    @Amount           DECIMAL(18,2),
    @PaymentMethodId  INT,
    @TransactionRef   NVARCHAR(100) = NULL,
    @BranchId         INT = 1,
    @UserId           INT = 1,
    @Narration        NVARCHAR(500) = NULL,
    @ReceiptNo        NVARCHAR(50) OUTPUT,
    @NewBalance       DECIMAL(18,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Amount <= 0
    BEGIN
        THROW 50002, 'Top-up amount must be greater than zero.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Ensure wallet exists
        IF NOT EXISTS (SELECT 1 FROM dbo.LabFranchiseWallet WHERE Franchise_ID = @FranchiseId)
        BEGIN
            INSERT INTO dbo.LabFranchiseWallet (Franchise_ID, CurrentBalance, LastUpdatedDate)
            VALUES (@FranchiseId, 0.00, GETDATE());
        END

        -- Update balance
        UPDATE dbo.LabFranchiseWallet
        SET CurrentBalance = CurrentBalance + @Amount,
            LastUpdatedDate = GETDATE()
        WHERE Franchise_ID = @FranchiseId;

        SELECT @NewBalance = CurrentBalance FROM dbo.LabFranchiseWallet WHERE Franchise_ID = @FranchiseId;

        -- Generate Receipt No
        DECLARE @BranchCode NVARCHAR(20) = (SELECT TOP 1 BranchCode FROM dbo.Branchmaster WHERE BranchId = @BranchId);
        IF @BranchCode IS NULL SET @BranchCode = 'BR';
        DECLARE @FinYear NVARCHAR(20) = CASE WHEN MONTH(GETDATE()) >= 4 THEN CAST(YEAR(GETDATE()) AS VARCHAR(4)) + '-' + CAST(YEAR(GETDATE()) + 1 AS VARCHAR(4)) ELSE CAST(YEAR(GETDATE()) - 1 AS VARCHAR(4)) + '-' + CAST(YEAR(GETDATE()) AS VARCHAR(4)) END;
        DECLARE @DatePart NVARCHAR(20) = FORMAT(GETDATE(), 'ddMMyyyy');

        DECLARE @NextSeq INT;
        UPDATE ReceiptSequence SET @NextSeq = LastSeq = LastSeq + 1 WHERE BranchId = @BranchId AND FinancialYear = @FinYear;
        IF @NextSeq IS NULL
        BEGIN
            SET @NextSeq = 1;
            INSERT INTO ReceiptSequence (BranchId, FinancialYear, LastSeq) VALUES (@BranchId, @FinYear, @NextSeq);
        END
        SET @ReceiptNo = @BranchCode + @DatePart + RIGHT('000000' + CAST(@NextSeq AS VARCHAR(10)), 6);

        -- Record transaction
        INSERT INTO dbo.LabFranchiseWalletTransaction
            (Franchise_ID, TransactionType, Amount, BalanceAfter, ReferenceType, ReferenceId, ReceiptNo, Narration, CreatedBy, CreatedDate)
        VALUES
            (@FranchiseId, 'CREDIT', @Amount, @NewBalance, 'TOPUP', NULL, @ReceiptNo, ISNULL(@Narration, 'Wallet balance recharged/top-up'), @UserId, GETDATE());

        -- Ledger: Dr Bank Account (or Cash), Cr Franchise Wallet (Advance Deposit)
        DECLARE @VoucherTypeId INT = (SELECT TOP 1 VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
        DECLARE @DebitLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Bank Account');
        IF @DebitLedgerId IS NULL SET @DebitLedgerId = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Cash Account');
        DECLARE @CreditLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Franchise Wallet (Advance)');
        DECLARE @NewTxId BIGINT;
        DECLARE @TxDate DATETIME = GETDATE();

        DECLARE @TopUpNarration NVARCHAR(500) = 'Franchise Wallet Top-Up #' + CAST(@FranchiseId AS NVARCHAR(20)) + ' (Receipt: ' + @ReceiptNo + ')';

        IF @DebitLedgerId IS NOT NULL AND @CreditLedgerId IS NOT NULL AND @VoucherTypeId IS NOT NULL
        BEGIN
            EXEC dbo.usp_Ledger_PostEntry
                @VoucherTypeId   = @VoucherTypeId,
                @TransactionDate = @TxDate,
                @ReferenceType   = 'B2B_WALLET_TOPUP',
                @ReferenceId     = @FranchiseId,
                @BranchId        = @BranchId,
                @CompanyId       = 1,
                @TotalAmount     = @Amount,
                @Narration       = @TopUpNarration,
                @DebitLedgerId   = @DebitLedgerId,
                @CreditLedgerId  = @CreditLedgerId,
                @CreatedBy       = @UserId,
                @NewTransactionId = @NewTxId OUTPUT;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── 7. Stored Procedure: usp_B2B_GetFranchiseWalletStatement ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetFranchiseWalletStatement
    @FranchiseId INT,
    @FromDate    DATETIME2 = NULL,
    @ToDate      DATETIME2 = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        t.TransactionId,
        t.Franchise_ID,
        t.TransactionType,
        t.Amount,
        t.BalanceAfter,
        t.ReferenceType,
        t.ReferenceId,
        t.ReceiptNo,
        t.Narration,
        t.CreatedDate,
        u.FullName AS CreatedByName
    FROM dbo.LabFranchiseWalletTransaction t
    LEFT JOIN dbo.UserMaster u ON u.Id = t.CreatedBy
    WHERE t.Franchise_ID = @FranchiseId
      AND (@FromDate IS NULL OR t.CreatedDate >= @FromDate)
      AND (@ToDate IS NULL OR t.CreatedDate <= @ToDate)
    ORDER BY t.CreatedDate DESC, t.TransactionId DESC;
END;
GO

-- ── 8. Stored Procedure: usp_B2B_GetUninvoicedOrders ────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetUninvoicedOrders
    @AgentType VARCHAR(10), -- 'F' or 'C'
    @AgentId   INT,
    @FromDate  DATETIME2 = NULL,
    @ToDate    DATETIME2 = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        lo.LabOrderId,
        lo.BillNo,
        lo.OrderDate,
        lo.DueDate,
        ISNULL(lo.B2BTotal, lo.TotalAmount) AS BillAmount,
        ISNULL(ph.TotalPaid, 0.00) AS PaidAmount,
        ISNULL(ph.BalanceDue, ISNULL(lo.B2BTotal, lo.TotalAmount)) AS BalanceDue,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber AS PatientPhone,
        (SELECT COUNT(1) FROM dbo.LabOrderItem WHERE LabOrderId = lo.LabOrderId AND IsActive = 1) AS ItemCount,
        STUFF((
            SELECT ', ' + CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Profile') ELSE ISNULL(sm.Test_Name, 'Test') END
            FROM dbo.LabOrderItem si
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster sm ON sm.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
            WHERE si.LabOrderId = lo.LabOrderId AND si.IsActive = 1
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS TestNames
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.IsB2B = 1
      AND lo.AgentType = @AgentType
      AND lo.B2BAgentID = @AgentId
      AND lo.IsActive = 1
      AND (@FromDate IS NULL OR lo.OrderDate >= @FromDate)
      AND (@ToDate IS NULL OR lo.OrderDate <= @ToDate)
      -- Exclude orders already tied to an active invoice
      AND NOT EXISTS (SELECT 1 FROM dbo.B2BInvoiceItem bii INNER JOIN dbo.B2BInvoice bi ON bi.InvoiceId = bii.InvoiceId WHERE bii.LabOrderId = lo.LabOrderId AND bi.Status <> 'C')
    ORDER BY lo.OrderDate ASC;
END;
GO

-- ── 9. Stored Procedure: usp_B2B_GenerateInvoice ────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GenerateInvoice
    @AgentType        VARCHAR(10), -- 'F' or 'C'
    @AgentId          INT,
    @BranchId         INT,
    @SelectedOrderIds NVARCHAR(MAX), -- comma-separated list of LabOrderIds
    @BillingCycle     NVARCHAR(50) = 'On-Demand',
    @Notes            NVARCHAR(MAX) = NULL,
    @UserId           INT = 1,
    @InvoiceId        INT OUTPUT,
    @InvoiceNo        NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Determine Credit Days
        DECLARE @CreditDays INT = 0;
        IF @AgentType = 'F'
        BEGIN
            SELECT @CreditDays = ISNULL(c.Credit_Days, 0)
            FROM dbo.LabFranchiseCreditLimitMaster c
            WHERE c.Franchise_ID = @AgentId;
        END
        ELSE IF @AgentType = 'C'
        BEGIN
            SELECT @CreditDays = ISNULL(c.Credit_Days, 0), @BillingCycle = ISNULL(@BillingCycle, c.BillingCycle)
            FROM dbo.CorporateMaster c
            WHERE c.Corporate_ID = @AgentId;
        END

        IF @CreditDays <= 0 SET @CreditDays = 30; -- Default 30 days if not set

        -- 2. Generate Invoice Number: B2B-INV-YYYYMM-XXXX
        DECLARE @YearMonth NVARCHAR(6) = FORMAT(GETDATE(), 'yyyyMM');
        DECLARE @NextNum INT;
        SELECT @NextNum = ISNULL(MAX(InvoiceId), 0) + 1 FROM dbo.B2BInvoice;
        SET @InvoiceNo = 'B2B-INV-' + @YearMonth + '-' + RIGHT('00000' + CAST(@NextNum AS VARCHAR(10)), 5);

        -- 3. Calculate Totals from selected orders
        DECLARE @TotalAmount DECIMAL(18,2) = 0.00;
        DECLARE @DueDate DATETIME2 = DATEADD(DAY, @CreditDays, GETDATE());

        -- Split order IDs table
        DECLARE @OrderList TABLE (LabOrderId INT);
        INSERT INTO @OrderList (LabOrderId)
        SELECT CAST(value AS INT) 
        FROM STRING_SPLIT(@SelectedOrderIds, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

        SELECT @TotalAmount = ISNULL(SUM(ISNULL(lo.B2BTotal, lo.TotalAmount)), 0.00)
        FROM dbo.LabOrder lo
        INNER JOIN @OrderList ol ON ol.LabOrderId = lo.LabOrderId
        WHERE lo.IsB2B = 1 AND lo.IsActive = 1;

        IF @TotalAmount <= 0
        BEGIN
            THROW 50003, 'No valid orders found or total amount is zero.', 1;
        END

        -- 4. Insert Invoice Header
        INSERT INTO dbo.B2BInvoice
            (InvoiceNo, PartnerType, PartnerId, BranchId, BillingCycle, InvoiceDate, DueDate, TotalAmount, DiscountAmount, TaxAmount, NetAmount, PaidAmount, BalanceAmount, Status, Notes, CreatedBy, CreatedDate)
        VALUES
            (@InvoiceNo, @AgentType, @AgentId, @BranchId, @BillingCycle, GETDATE(), @DueDate, @TotalAmount, 0.00, 0.00, @TotalAmount, 0.00, @TotalAmount, 'U', @Notes, @UserId, GETDATE());

        SET @InvoiceId = SCOPE_IDENTITY();

        -- 5. Insert Invoice Items
        INSERT INTO dbo.B2BInvoiceItem
            (InvoiceId, LabOrderId, BillNo, OrderDate, PatientName, B2BTotal, Amount)
        SELECT 
            @InvoiceId,
            lo.LabOrderId,
            lo.BillNo,
            lo.OrderDate,
            LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName, ''))),
            ISNULL(lo.B2BTotal, lo.TotalAmount),
            ISNULL(lo.B2BTotal, lo.TotalAmount)
        FROM dbo.LabOrder lo
        INNER JOIN @OrderList ol ON ol.LabOrderId = lo.LabOrderId
        INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
        WHERE lo.IsB2B = 1 AND lo.IsActive = 1;

        -- Update DueDate on LabOrders
        UPDATE lo
        SET DueDate = @DueDate
        FROM dbo.LabOrder lo
        INNER JOIN @OrderList ol ON ol.LabOrderId = lo.LabOrderId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── 10. Stored Procedure: usp_B2B_GetInvoiceList ────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetInvoiceList
    @AgentType    VARCHAR(10) = NULL,
    @AgentId      INT = NULL,
    @Status       VARCHAR(10) = NULL,
    @FromDate     DATETIME2 = NULL,
    @ToDate       DATETIME2 = NULL,
    @Search       NVARCHAR(100) = NULL,
    @PageNumber   INT = 1,
    @PageSize     INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    ;WITH FilteredInvoices AS (
        SELECT 
            inv.InvoiceId,
            inv.InvoiceNo,
            inv.PartnerType,
            inv.PartnerId,
            CASE inv.PartnerType 
                WHEN 'F' THEN f.Franchise_Name 
                WHEN 'C' THEN corp.Corporate_Name 
                ELSE 'Unknown' 
            END AS PartnerName,
            CASE inv.PartnerType 
                WHEN 'F' THEN f.Franchise_Code 
                WHEN 'C' THEN corp.Corporate_Code 
                ELSE '' 
            END AS PartnerCode,
            inv.BranchId,
            inv.BillingCycle,
            inv.InvoiceDate,
            inv.DueDate,
            inv.TotalAmount,
            inv.NetAmount,
            inv.PaidAmount,
            inv.BalanceAmount,
            inv.Status,
            CASE inv.Status 
                WHEN 'P' THEN 'Paid' 
                WHEN 'R' THEN 'Partially Paid' 
                WHEN 'U' THEN 'Unpaid' 
                WHEN 'C' THEN 'Cancelled' 
                ELSE 'Unpaid' 
            END AS StatusName,
            (SELECT COUNT(1) FROM dbo.B2BInvoiceItem WHERE InvoiceId = inv.InvoiceId) AS OrderCount
        FROM dbo.B2BInvoice inv
        LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = inv.PartnerId AND inv.PartnerType = 'F'
        LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = inv.PartnerId AND inv.PartnerType = 'C'
        WHERE (@AgentType IS NULL OR inv.PartnerType = @AgentType)
          AND (@AgentId IS NULL OR inv.PartnerId = @AgentId)
          AND (@Status IS NULL OR inv.Status = @Status)
          AND (@FromDate IS NULL OR inv.InvoiceDate >= @FromDate)
          AND (@ToDate IS NULL OR inv.InvoiceDate <= @ToDate)
          AND (@Search IS NULL OR inv.InvoiceNo LIKE '%' + @Search + '%' 
                               OR f.Franchise_Name LIKE '%' + @Search + '%' 
                               OR corp.Corporate_Name LIKE '%' + @Search + '%')
    )
    SELECT *, (SELECT COUNT(1) FROM FilteredInvoices) AS TotalCount
    FROM FilteredInvoices
    ORDER BY InvoiceDate DESC, InvoiceId DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- ── 11. Stored Procedure: usp_B2B_GetInvoiceDetail ──────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetInvoiceDetail
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Header
    SELECT 
        inv.InvoiceId,
        inv.InvoiceNo,
        inv.PartnerType,
        inv.PartnerId,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Franchise_Name 
            WHEN 'C' THEN corp.Corporate_Name 
            ELSE 'Unknown' 
        END AS PartnerName,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Franchise_Code 
            WHEN 'C' THEN corp.Corporate_Code 
            ELSE '' 
        END AS PartnerCode,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Mobile_No 
            WHEN 'C' THEN corp.Contact_No 
            ELSE '' 
        END AS PartnerPhone,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Email 
            WHEN 'C' THEN corp.Email 
            ELSE '' 
        END AS PartnerEmail,
        CASE inv.PartnerType 
            WHEN 'F' THEN '' 
            WHEN 'C' THEN corp.Address 
            ELSE '' 
        END AS PartnerAddress,
        inv.BranchId,
        b.BranchName,
        b.BranchCode,
        inv.BillingCycle,
        inv.InvoiceDate,
        inv.DueDate,
        inv.TotalAmount,
        inv.DiscountAmount,
        inv.TaxAmount,
        inv.NetAmount,
        inv.PaidAmount,
        inv.BalanceAmount,
        inv.Status,
        inv.Notes,
        inv.CreatedDate,
        u.FullName AS CreatedByName
    FROM dbo.B2BInvoice inv
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = inv.PartnerId AND inv.PartnerType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = inv.PartnerId AND inv.PartnerType = 'C'
    LEFT JOIN dbo.Branchmaster b ON b.BranchId = inv.BranchId
    LEFT JOIN dbo.UserMaster u ON u.Id = inv.CreatedBy
    WHERE inv.InvoiceId = @InvoiceId;

    -- Line items
    SELECT 
        bii.InvoiceItemId,
        bii.InvoiceId,
        bii.LabOrderId,
        bii.BillNo,
        bii.OrderDate,
        bii.PatientName,
        p.PatientCode,
        p.PhoneNumber AS PatientPhone,
        bii.B2BTotal,
        bii.Amount,
        STUFF((
            SELECT ', ' + CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Profile') ELSE ISNULL(sm.Test_Name, 'Test') END
            FROM dbo.LabOrderItem si
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster sm ON sm.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
            WHERE si.LabOrderId = bii.LabOrderId AND si.IsActive = 1
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS TestNames
    FROM dbo.B2BInvoiceItem bii
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bii.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    WHERE bii.InvoiceId = @InvoiceId
    ORDER BY bii.OrderDate ASC;
END;
GO

-- ── 12. Stored Procedure: usp_B2B_GetOutstandingBillsForSettlement ──────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetOutstandingBillsForSettlement
    @AgentType VARCHAR(10), -- 'F' or 'C'
    @AgentId   INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Return all unpaid/partially paid B2B LabOrders
    SELECT 
        lo.LabOrderId,
        lo.BillNo,
        lo.OrderDate,
        ISNULL(lo.DueDate, DATEADD(DAY, 30, lo.OrderDate)) AS DueDate,
        ISNULL(lo.B2BTotal, lo.TotalAmount) AS BillAmount,
        ISNULL(ph.TotalPaid, 0.00) AS PaidAmount,
        ISNULL(ph.BalanceDue, ISNULL(lo.B2BTotal, lo.TotalAmount)) AS BalanceDue,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber AS PatientPhone,
        bii.InvoiceId,
        bi.InvoiceNo,
        CASE WHEN ISNULL(lo.DueDate, DATEADD(DAY, 30, lo.OrderDate)) < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END AS IsOverdue,
        DATEDIFF(DAY, ISNULL(lo.DueDate, DATEADD(DAY, 30, lo.OrderDate)), CAST(GETDATE() AS DATE)) AS OverdueDays,
        STUFF((
            SELECT ', ' + CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Profile') ELSE ISNULL(sm.Test_Name, 'Test') END
            FROM dbo.LabOrderItem si
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster sm ON sm.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
            WHERE si.LabOrderId = lo.LabOrderId AND si.IsActive = 1
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS TestNames
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.B2BInvoiceItem bii ON bii.LabOrderId = lo.LabOrderId
    LEFT JOIN dbo.B2BInvoice bi ON bi.InvoiceId = bii.InvoiceId AND bi.Status <> 'C'
    WHERE lo.IsB2B = 1
      AND lo.AgentType = @AgentType
      AND lo.B2BAgentID = @AgentId
      AND lo.IsActive = 1
      AND (ph.PaymentStatus IS NULL OR ph.PaymentStatus IN ('U', 'R'))
      AND ISNULL(ph.BalanceDue, ISNULL(lo.B2BTotal, lo.TotalAmount)) > 0
    ORDER BY lo.OrderDate ASC;
END;
GO

-- ── 13. Stored Procedure: usp_B2B_SettleBillsPayment ────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_SettleBillsPayment
    @AgentType        VARCHAR(10), -- 'F' or 'C'
    @AgentId          INT,
    @BranchId         INT,
    @PaymentMethodId  INT,
    @PaidAmount       DECIMAL(18,2),
    @TransactionRef   NVARCHAR(100) = NULL,
    @BankName         NVARCHAR(100) = NULL,
    @ChequeNo         NVARCHAR(50) = NULL,
    @ChequeDate       DATE = NULL,
    @PaymentDate      DATETIME2 = NULL,
    @SelectedBillsJson NVARCHAR(MAX), -- JSON array: [{"LabOrderId": 12, "PayAmount": 1500.00}]
    @Notes            NVARCHAR(500) = NULL,
    @UserId           INT = 1,
    @BatchReceiptNo   NVARCHAR(50) OUTPUT,
    @SettledBillCount INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @PaidAmount <= 0
    BEGIN
        THROW 50004, 'Payment amount must be greater than zero.', 1;
    END

    IF @PaymentDate IS NULL SET @PaymentDate = GETDATE();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Generate consolidated Receipt No
        DECLARE @BranchCode NVARCHAR(20) = (SELECT TOP 1 BranchCode FROM dbo.Branchmaster WHERE BranchId = @BranchId);
        IF @BranchCode IS NULL SET @BranchCode = 'BR';
        DECLARE @FinYear NVARCHAR(20) = CASE WHEN MONTH(GETDATE()) >= 4 THEN CAST(YEAR(GETDATE()) AS VARCHAR(4)) + '-' + CAST(YEAR(GETDATE()) + 1 AS VARCHAR(4)) ELSE CAST(YEAR(GETDATE()) - 1 AS VARCHAR(4)) + '-' + CAST(YEAR(GETDATE()) AS VARCHAR(4)) END;
        DECLARE @DatePart NVARCHAR(20) = FORMAT(GETDATE(), 'ddMMyyyy');

        DECLARE @NextSeq INT;
        UPDATE ReceiptSequence SET @NextSeq = LastSeq = LastSeq + 1 WHERE BranchId = @BranchId AND FinancialYear = @FinYear;
        IF @NextSeq IS NULL
        BEGIN
            SET @NextSeq = 1;
            INSERT INTO ReceiptSequence (BranchId, FinancialYear, LastSeq) VALUES (@BranchId, @FinYear, @NextSeq);
        END
        SET @BatchReceiptNo = @BranchCode + @DatePart + RIGHT('000000' + CAST(@NextSeq AS VARCHAR(10)), 6);

        -- Parse JSON
        DECLARE @BillsTable TABLE (LabOrderId INT, PayAmount DECIMAL(18,2));
        INSERT INTO @BillsTable (LabOrderId, PayAmount)
        SELECT 
            CAST(JSON_VALUE(value, '$.LabOrderId') AS INT),
            CAST(JSON_VALUE(value, '$.PayAmount') AS DECIMAL(18,2))
        FROM OPENJSON(@SelectedBillsJson);

        SET @SettledBillCount = (SELECT COUNT(1) FROM @BillsTable WHERE PayAmount > 0);

        -- 2. Process each bill
        DECLARE @CurOrderId INT, @CurPayAmt DECIMAL(18,2);
        DECLARE bill_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT LabOrderId, PayAmount FROM @BillsTable WHERE PayAmount > 0;

        OPEN bill_cursor;
        FETCH NEXT FROM bill_cursor INTO @CurOrderId, @CurPayAmt;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @PhId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = 'LAB' AND ModuleRefId = @CurOrderId AND IsActive = 1);
            DECLARE @OrderBillTotal DECIMAL(18,2) = (SELECT TOP 1 ISNULL(B2BTotal, TotalAmount) FROM dbo.LabOrder WHERE LabOrderId = @CurOrderId);
            DECLARE @PatientId INT = (SELECT TOP 1 PatientId FROM dbo.LabOrder WHERE LabOrderId = @CurOrderId);

            IF @PhId IS NULL
            BEGIN
                INSERT INTO dbo.PaymentHeader
                    (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive)
                VALUES
                    ('LAB', @CurOrderId, @BranchId, @PatientId, @OrderBillTotal, @OrderBillTotal, @CurPayAmt, @OrderBillTotal - @CurPayAmt, 
                     CASE WHEN @CurPayAmt >= @OrderBillTotal THEN 'P' ELSE 'R' END, @Notes, GETDATE(), @UserId, 1);
                SET @PhId = SCOPE_IDENTITY();
            END
            ELSE
            BEGIN
                UPDATE dbo.PaymentHeader
                SET TotalPaid = TotalPaid + @CurPayAmt,
                    BalanceDue = CASE WHEN BalanceDue - @CurPayAmt < 0 THEN 0.00 ELSE BalanceDue - @CurPayAmt END,
                    PaymentStatus = CASE WHEN BalanceDue - @CurPayAmt <= 0 THEN 'P' ELSE 'R' END,
                    LastModifiedDate = GETDATE(),
                    LastModifiedBy = @UserId
                WHERE PaymentHeaderId = @PhId;
            END

            -- Insert PaymentDetail
            INSERT INTO dbo.PaymentDetail
                (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, BankName, ChequeNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo)
            VALUES
                (@PhId, @PaymentMethodId, @CurPayAmt, @TransactionRef, @BankName, @ChequeNo, @PaymentDate, @Notes, GETDATE(), @UserId, 1, @BatchReceiptNo);

            -- Assign Token if bill is fully paid
            DECLARE @CurBal DECIMAL(18,2) = (SELECT BalanceDue FROM dbo.PaymentHeader WHERE PaymentHeaderId = @PhId);
            IF @CurBal <= 0
            BEGIN
                DECLARE @AssignedToken NVARCHAR(20);
                EXEC dbo.usp_LAB_AssignTokenOnPayment @LabOrderId = @CurOrderId, @TokenNo = @AssignedToken OUTPUT;
            END

            FETCH NEXT FROM bill_cursor INTO @CurOrderId, @CurPayAmt;
        END

        CLOSE bill_cursor;
        DEALLOCATE bill_cursor;

        -- 3. Update any affected B2B Invoices
        UPDATE bi
        SET PaidAmount = (
                SELECT ISNULL(SUM(ISNULL(ph.TotalPaid, 0)), 0)
                FROM dbo.B2BInvoiceItem bii
                LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = bii.LabOrderId AND ph.IsActive = 1
                WHERE bii.InvoiceId = bi.InvoiceId
            ),
            BalanceAmount = bi.NetAmount - (
                SELECT ISNULL(SUM(ISNULL(ph.TotalPaid, 0)), 0)
                FROM dbo.B2BInvoiceItem bii
                LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = bii.LabOrderId AND ph.IsActive = 1
                WHERE bii.InvoiceId = bi.InvoiceId
            ),
            Status = CASE 
                WHEN (bi.NetAmount - (
                    SELECT ISNULL(SUM(ISNULL(ph.TotalPaid, 0)), 0)
                    FROM dbo.B2BInvoiceItem bii
                    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = bii.LabOrderId AND ph.IsActive = 1
                    WHERE bii.InvoiceId = bi.InvoiceId
                )) <= 0 THEN 'P'
                WHEN (
                    SELECT ISNULL(SUM(ISNULL(ph.TotalPaid, 0)), 0)
                    FROM dbo.B2BInvoiceItem bii
                    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = bii.LabOrderId AND ph.IsActive = 1
                    WHERE bii.InvoiceId = bi.InvoiceId
                ) > 0 THEN 'R'
                ELSE 'U'
            END
        FROM dbo.B2BInvoice bi
        WHERE bi.InvoiceId IN (
            SELECT DISTINCT bii.InvoiceId 
            FROM dbo.B2BInvoiceItem bii
            INNER JOIN @BillsTable bt ON bt.LabOrderId = bii.LabOrderId
        );

        -- 4. Post Consolidated Ledger Entry
        -- Dr: Bank Account / Cash Account
        -- Cr: Franchise Receivable / Corporate Receivable
        DECLARE @VoucherTypeId INT = (SELECT TOP 1 VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
        IF @VoucherTypeId IS NULL
        BEGIN
            INSERT INTO Acc_VoucherType (VoucherTypeName, Prefix, IsActive) VALUES ('Receipt', 'RCT', 1);
            SET @VoucherTypeId = SCOPE_IDENTITY();
        END

        DECLARE @DebitLedgerName NVARCHAR(100) = 'Bank Account';
        -- If Cash payment method
        IF EXISTS (SELECT 1 FROM PaymentMethodMaster WHERE PaymentMethodId = @PaymentMethodId AND (MethodCode = 'CASH' OR MethodName = 'Cash'))
            SET @DebitLedgerName = 'Cash Account';

        DECLARE @DebitLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = @DebitLedgerName);
        IF @DebitLedgerId IS NULL
        BEGIN
            DECLARE @AssetGrp INT = (SELECT TOP 1 LedgerGroupId FROM Acc_LedgerGroup WHERE GroupName = 'Current Assets' OR GroupType = 'Asset');
            INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
            VALUES (@DebitLedgerName, @AssetGrp, 0, 'Dr', 1, GETDATE());
            SET @DebitLedgerId = SCOPE_IDENTITY();
        END

        DECLARE @CreditLedgerName NVARCHAR(100) = CASE WHEN @AgentType = 'C' THEN 'Corporate Receivable' ELSE 'Franchise Receivable' END;
        DECLARE @CreditLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = @CreditLedgerName);

        DECLARE @PartnerTitle NVARCHAR(100) = CASE 
            WHEN @AgentType = 'F' THEN (SELECT Franchise_Name FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @AgentId)
            WHEN @AgentType = 'C' THEN (SELECT Corporate_Name FROM dbo.CorporateMaster WHERE Corporate_ID = @AgentId)
            ELSE 'B2B Partner'
        END;

        DECLARE @SettleNarration NVARCHAR(500) = 'B2B settlement payment for ' + @PartnerTitle + ' (' + CAST(@SettledBillCount AS NVARCHAR(10)) + ' bills, Receipt: ' + @BatchReceiptNo + ')';
        DECLARE @NewTxId BIGINT;
        IF @DebitLedgerId IS NOT NULL AND @CreditLedgerId IS NOT NULL AND @VoucherTypeId IS NOT NULL
        BEGIN
            EXEC dbo.usp_Ledger_PostEntry
                @VoucherTypeId   = @VoucherTypeId,
                @TransactionDate = @PaymentDate,
                @ReferenceType   = 'B2B_SETTLEMENT',
                @ReferenceId     = @AgentId,
                @BranchId        = @BranchId,
                @CompanyId       = 1,
                @TotalAmount     = @PaidAmount,
                @Narration       = @SettleNarration,
                @DebitLedgerId   = @DebitLedgerId,
                @CreditLedgerId  = @CreditLedgerId,
                @CreatedBy       = @UserId,
                @NewTransactionId = @NewTxId OUTPUT;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
