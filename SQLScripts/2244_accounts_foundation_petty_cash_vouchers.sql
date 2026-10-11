-- ====================================================================================================
-- Script: 2244_accounts_foundation_petty_cash_vouchers.sql
-- Description: Utility > Accounts - petty cash (imprest), manual voucher entry and the ledger posting behind them.
--   Works on the ledger tables LAB / OPD billing already posts to (Acc_LedgerTransaction), so there is one set of books.
--
--   1. Columns on the existing Acc_* tables (codes, ledger type, system flag, voucher status / reversal link).
--      The 15 ledgers billing uses are marked IsSystem: they cannot be renamed or switched off, because the billing
--      procedures find them by name. Existing rows and procedures are not changed.
--   2. New tables: Acc_Settings (per company), Acc_BranchLock (books locked up to a date, per branch),
--      Acc_VoucherSequence, Acc_ExpenseHead, Acc_Payee, Acc_PettyCashCounter, Acc_PettyCashFloat,
--      Acc_PettyExpense(+Line), Acc_PettyCashClosing, Acc_Voucher(+Line), Acc_Attachment (bill scans).
--   3. Posting: usp_Acc_PostVoucher (any number of lines, must balance, one entry per reference) and
--      usp_Acc_CancelVoucher (reversal, nothing deleted). Everything is branch-wise: a voucher belongs to one
--      branch, its number runs per branch / voucher type / financial year (PCV/KOL/26-27/00001), and the books
--      are locked branch by branch.
--   4. Masters: ledger group, ledger, expense head, payee, petty cash counter, settings, branch lock.
--   5. Petty cash: float issue / replenish / return (Contra), expense save / approve / reject / cancel (Petty Cash
--      voucher: Dr expense ledgers, Cr the counter; with the company's GST input credit setting on, the GST part of
--      a bill goes to GST Input Credit instead of the expense), daily closing (shortage / excess by Journal).
--   6. Manual vouchers: Payment, Receipt, Contra, Journal - save / approve / reject / cancel.
--   7. Starter kit: ledger groups, system ledgers, voucher types, 14 expense heads with their ledgers.
--   Safe to re-run.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Columns on the existing tables ───────────────────────────────────────
IF COL_LENGTH('dbo.Acc_LedgerGroup', 'IsSystem') IS NULL
    ALTER TABLE dbo.Acc_LedgerGroup ADD IsSystem BIT NOT NULL CONSTRAINT DF_Acc_LedgerGroup_IsSystem DEFAULT 0;
IF COL_LENGTH('dbo.Acc_LedgerGroup', 'ModifiedBy') IS NULL
    ALTER TABLE dbo.Acc_LedgerGroup ADD ModifiedBy INT NULL, ModifiedDate DATETIME NULL;

IF COL_LENGTH('dbo.Acc_LedgerMaster', 'LedgerCode') IS NULL
    ALTER TABLE dbo.Acc_LedgerMaster ADD LedgerCode NVARCHAR(30) NULL;
IF COL_LENGTH('dbo.Acc_LedgerMaster', 'LedgerType') IS NULL
    ALTER TABLE dbo.Acc_LedgerMaster ADD LedgerType VARCHAR(10) NOT NULL CONSTRAINT DF_Acc_LedgerMaster_Type DEFAULT 'GENERAL';
IF COL_LENGTH('dbo.Acc_LedgerMaster', 'IsSystem') IS NULL
    ALTER TABLE dbo.Acc_LedgerMaster ADD IsSystem BIT NOT NULL CONSTRAINT DF_Acc_LedgerMaster_IsSystem DEFAULT 0;
IF COL_LENGTH('dbo.Acc_LedgerMaster', 'Remarks') IS NULL
    ALTER TABLE dbo.Acc_LedgerMaster ADD Remarks NVARCHAR(300) NULL, ModifiedBy INT NULL, ModifiedDate DATETIME NULL;

IF COL_LENGTH('dbo.Acc_VoucherType', 'VoucherTypeCode') IS NULL
    ALTER TABLE dbo.Acc_VoucherType ADD VoucherTypeCode VARCHAR(10) NULL;
IF COL_LENGTH('dbo.Acc_VoucherType', 'IsManual') IS NULL
    ALTER TABLE dbo.Acc_VoucherType ADD IsManual BIT NOT NULL CONSTRAINT DF_Acc_VoucherType_IsManual DEFAULT 0;

IF COL_LENGTH('dbo.Acc_LedgerTransaction', 'Status') IS NULL
    ALTER TABLE dbo.Acc_LedgerTransaction ADD Status CHAR(1) NOT NULL CONSTRAINT DF_Acc_LedgerTransaction_Status DEFAULT 'P';  -- P posted, C cancelled (reversed)
IF COL_LENGTH('dbo.Acc_LedgerTransaction', 'ReversalOfTransactionId') IS NULL
    ALTER TABLE dbo.Acc_LedgerTransaction ADD
        ReversalOfTransactionId BIGINT NULL,
        IsManual      BIT NOT NULL CONSTRAINT DF_Acc_LedgerTransaction_IsManual DEFAULT 0,
        FinancialYear VARCHAR(7) NULL,
        PayeeName     NVARCHAR(150) NULL,
        PaymentMode   NVARCHAR(50) NULL,
        InstrumentNo  NVARCHAR(100) NULL,
        InstrumentDate DATE NULL,
        CancelledBy   INT NULL,
        CancelledDate DATETIME NULL,
        CancelReason  NVARCHAR(300) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Acc_LedgerTransactionDetail_Ledger' AND object_id = OBJECT_ID('dbo.Acc_LedgerTransactionDetail'))
    CREATE INDEX IX_Acc_LedgerTransactionDetail_Ledger ON dbo.Acc_LedgerTransactionDetail(LedgerId, TransactionId) INCLUDE (DebitAmount, CreditAmount);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Acc_LedgerTransactionDetail_Tx' AND object_id = OBJECT_ID('dbo.Acc_LedgerTransactionDetail'))
    CREATE INDEX IX_Acc_LedgerTransactionDetail_Tx ON dbo.Acc_LedgerTransactionDetail(TransactionId) INCLUDE (LedgerId, DebitAmount, CreditAmount);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Acc_LedgerTransaction_Date' AND object_id = OBJECT_ID('dbo.Acc_LedgerTransaction'))
    CREATE INDEX IX_Acc_LedgerTransaction_Date ON dbo.Acc_LedgerTransaction(TransactionDate, BranchId) INCLUDE (VoucherTypeId, IsActive);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Acc_LedgerTransaction_Ref' AND object_id = OBJECT_ID('dbo.Acc_LedgerTransaction'))
    CREATE INDEX IX_Acc_LedgerTransaction_Ref ON dbo.Acc_LedgerTransaction(ReferenceType, ReferenceId);
GO

-- ── 2. New tables ───────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Acc_Settings', 'U') IS NULL
    CREATE TABLE dbo.Acc_Settings
    (
        CompanyId                INT NOT NULL CONSTRAINT PK_Acc_Settings PRIMARY KEY,
        PettyApprovalRequired    BIT NOT NULL CONSTRAINT DF_Acc_Settings_Appr DEFAULT 1,
        PettyAutoApproveLimit    DECIMAL(18,2) NOT NULL CONSTRAINT DF_Acc_Settings_Auto DEFAULT 500,   -- at or below: approved on save
        PettyMaxPerVoucher       DECIMAL(18,2) NOT NULL CONSTRAINT DF_Acc_Settings_Max DEFAULT 5000,
        AllowPettyOverdraw       BIT NOT NULL CONSTRAINT DF_Acc_Settings_Over DEFAULT 0,               -- expense above the counter balance
        AllowSelfApproval        BIT NOT NULL CONSTRAINT DF_Acc_Settings_Self DEFAULT 0,
        VoucherApprovalRequired  BIT NOT NULL CONSTRAINT DF_Acc_Settings_VAppr DEFAULT 0,              -- manual vouchers
        BackDateDays             INT NOT NULL CONSTRAINT DF_Acc_Settings_Back DEFAULT 2,
        FinancialYearStartMonth  TINYINT NOT NULL CONSTRAINT DF_Acc_Settings_Fy DEFAULT 4,
        PettyGstInputCredit      BIT NOT NULL CONSTRAINT DF_Acc_Settings_Gst DEFAULT 0,                -- split the GST of a petty bill to GST Input Credit
        ModifiedBy               INT NULL,
        ModifiedDate             DATETIME NULL
    );

-- Books locked branch by branch: no entry dated on or before LockedUpTo for that branch (NULL / no row = open).
IF OBJECT_ID('dbo.Acc_BranchLock', 'U') IS NULL
    CREATE TABLE dbo.Acc_BranchLock
    (
        CompanyId    INT NOT NULL,
        BranchId     INT NOT NULL,
        LockedUpTo   DATE NULL,
        ModifiedBy   INT NULL,
        ModifiedDate DATETIME NULL,
        CONSTRAINT PK_Acc_BranchLock PRIMARY KEY (CompanyId, BranchId)
    );

IF OBJECT_ID('dbo.Acc_VoucherSequence', 'U') IS NULL
    CREATE TABLE dbo.Acc_VoucherSequence
    (
        CompanyId     INT NOT NULL,
        BranchId      INT NOT NULL,
        VoucherTypeId INT NOT NULL,
        FinancialYear VARCHAR(7) NOT NULL,
        LastNo        INT NOT NULL,
        CONSTRAINT PK_Acc_VoucherSequence PRIMARY KEY (CompanyId, BranchId, VoucherTypeId, FinancialYear)
    );

IF OBJECT_ID('dbo.Acc_ExpenseHead', 'U') IS NULL
    CREATE TABLE dbo.Acc_ExpenseHead
    (
        ExpenseHeadId     INT IDENTITY(1,1) CONSTRAINT PK_Acc_ExpenseHead PRIMARY KEY,
        CompanyId         INT NOT NULL CONSTRAINT DF_Acc_ExpenseHead_Co DEFAULT 1,
        HeadName          NVARCHAR(100) NOT NULL,
        LedgerId          INT NOT NULL CONSTRAINT FK_Acc_ExpenseHead_Ledger REFERENCES dbo.Acc_LedgerMaster(LedgerId),
        MaxPerVoucher     DECIMAL(18,2) NULL,          -- NULL: the company limit applies
        BillRequiredAbove DECIMAL(18,2) NULL,          -- bill no. mandatory above this amount
        IsActive          BIT NOT NULL CONSTRAINT DF_Acc_ExpenseHead_Active DEFAULT 1,
        CreatedBy         INT NULL,
        CreatedDate       DATETIME NOT NULL CONSTRAINT DF_Acc_ExpenseHead_Created DEFAULT GETDATE(),
        ModifiedBy        INT NULL,
        ModifiedDate      DATETIME NULL
    );

-- Repeat payees (vendors, staff): offered on the petty expense and voucher screens; the name can still be typed freely.
IF OBJECT_ID('dbo.Acc_Payee', 'U') IS NULL
    CREATE TABLE dbo.Acc_Payee
    (
        PayeeId              INT IDENTITY(1,1) CONSTRAINT PK_Acc_Payee PRIMARY KEY,
        CompanyId            INT NOT NULL CONSTRAINT DF_Acc_Payee_Co DEFAULT 1,
        PayeeName            NVARCHAR(150) NOT NULL,
        Phone                NVARCHAR(20) NULL,
        GSTIN                NVARCHAR(15) NULL,
        PAN                  NVARCHAR(10) NULL,
        DefaultExpenseHeadId INT NULL,
        Remarks              NVARCHAR(300) NULL,
        IsActive             BIT NOT NULL CONSTRAINT DF_Acc_Payee_Active DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME NOT NULL CONSTRAINT DF_Acc_Payee_Created DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME NULL
    );

-- Bill photos / scans of a petty expense or a manual voucher. Files live in App_Data/accounts (not web-served).
IF OBJECT_ID('dbo.Acc_Attachment', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Acc_Attachment
    (
        AttachmentId INT IDENTITY(1,1) CONSTRAINT PK_Acc_Attachment PRIMARY KEY,
        CompanyId    INT NOT NULL,
        RefType      VARCHAR(20) NOT NULL CONSTRAINT CK_Acc_Attachment_Ref CHECK (RefType IN ('PETTY_EXP', 'VOUCHER')),
        RefId        INT NOT NULL,
        FileName     NVARCHAR(200) NOT NULL,       -- as uploaded
        StoredName   NVARCHAR(100) NOT NULL,       -- name on disk
        ContentType  NVARCHAR(100) NOT NULL,
        SizeBytes    INT NOT NULL,
        IsDeleted    BIT NOT NULL CONSTRAINT DF_Acc_Attachment_Deleted DEFAULT 0,
        CreatedBy    INT NULL,
        CreatedDate  DATETIME NOT NULL CONSTRAINT DF_Acc_Attachment_Created DEFAULT GETDATE(),
        DeletedBy    INT NULL,
        DeletedDate  DATETIME NULL
    );
    CREATE INDEX IX_Acc_Attachment_Ref ON dbo.Acc_Attachment(RefType, RefId) WHERE IsDeleted = 0;
END

IF OBJECT_ID('dbo.Acc_PettyCashCounter', 'U') IS NULL
    CREATE TABLE dbo.Acc_PettyCashCounter
    (
        CounterId        INT IDENTITY(1,1) CONSTRAINT PK_Acc_PettyCashCounter PRIMARY KEY,
        CompanyId        INT NOT NULL CONSTRAINT DF_Acc_PettyCashCounter_Co DEFAULT 1,
        BranchId         INT NOT NULL,
        CounterName      NVARCHAR(100) NOT NULL,
        CustodianUserId  INT NULL,
        FloatAmount      DECIMAL(18,2) NOT NULL,       -- the fixed imprest amount
        LedgerId         INT NOT NULL CONSTRAINT FK_Acc_PettyCashCounter_Ledger REFERENCES dbo.Acc_LedgerMaster(LedgerId),
        FundingLedgerId  INT NULL,                     -- default source of float / replenishment (cash or bank)
        LowBalanceAlert  DECIMAL(18,2) NULL,
        IsActive         BIT NOT NULL CONSTRAINT DF_Acc_PettyCashCounter_Active DEFAULT 1,
        CreatedBy        INT NULL,
        CreatedDate      DATETIME NOT NULL CONSTRAINT DF_Acc_PettyCashCounter_Created DEFAULT GETDATE(),
        ModifiedBy       INT NULL,
        ModifiedDate     DATETIME NULL
    );

IF OBJECT_ID('dbo.Acc_PettyCashFloat', 'U') IS NULL
    CREATE TABLE dbo.Acc_PettyCashFloat
    (
        FloatId         INT IDENTITY(1,1) CONSTRAINT PK_Acc_PettyCashFloat PRIMARY KEY,
        CounterId       INT NOT NULL CONSTRAINT FK_Acc_PettyCashFloat_Counter REFERENCES dbo.Acc_PettyCashCounter(CounterId),
        Kind            VARCHAR(10) NOT NULL CONSTRAINT CK_Acc_PettyCashFloat_Kind CHECK (Kind IN ('ISSUE', 'REPLENISH', 'RETURN')),
        TxnDate         DATE NOT NULL,
        Amount          DECIMAL(18,2) NOT NULL CONSTRAINT CK_Acc_PettyCashFloat_Amount CHECK (Amount > 0),
        SourceLedgerId  INT NOT NULL,
        ReferenceNo     NVARCHAR(100) NULL,
        Remarks         NVARCHAR(300) NULL,
        TransactionId   BIGINT NULL,
        VoucherNo       NVARCHAR(50) NULL,
        CreatedBy       INT NULL,
        CreatedDate     DATETIME NOT NULL CONSTRAINT DF_Acc_PettyCashFloat_Created DEFAULT GETDATE()
    );

IF OBJECT_ID('dbo.Acc_PettyExpense', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Acc_PettyExpense
    (
        ExpenseId      INT IDENTITY(1,1) CONSTRAINT PK_Acc_PettyExpense PRIMARY KEY,
        CompanyId      INT NOT NULL,
        BranchId       INT NOT NULL,
        CounterId      INT NOT NULL CONSTRAINT FK_Acc_PettyExpense_Counter REFERENCES dbo.Acc_PettyCashCounter(CounterId),
        ExpenseDate    DATE NOT NULL,
        PayeeName      NVARCHAR(150) NULL,
        BillNo         NVARCHAR(50) NULL,
        BillDate       DATE NULL,
        TotalAmount    DECIMAL(18,2) NOT NULL,
        Narration      NVARCHAR(500) NULL,
        Status         CHAR(1) NOT NULL CONSTRAINT CK_Acc_PettyExpense_Status CHECK (Status IN ('S', 'A', 'R', 'C')),  -- Submitted, Approved (posted), Rejected, Cancelled
        TransactionId  BIGINT NULL,
        VoucherNo      NVARCHAR(50) NULL,
        CreatedBy      INT NULL,
        CreatedDate    DATETIME NOT NULL CONSTRAINT DF_Acc_PettyExpense_Created DEFAULT GETDATE(),
        ModifiedBy     INT NULL,
        ModifiedDate   DATETIME NULL,
        ApprovedBy     INT NULL,
        ApprovedDate   DATETIME NULL,
        IsAutoApproved BIT NOT NULL CONSTRAINT DF_Acc_PettyExpense_Auto DEFAULT 0,
        RejectedBy     INT NULL,
        RejectedDate   DATETIME NULL,
        RejectReason   NVARCHAR(300) NULL,
        CancelledBy    INT NULL,
        CancelledDate  DATETIME NULL,
        CancelReason   NVARCHAR(300) NULL
    );
    CREATE INDEX IX_Acc_PettyExpense_Counter ON dbo.Acc_PettyExpense(CounterId, ExpenseDate, Status);
    CREATE INDEX IX_Acc_PettyExpense_Branch ON dbo.Acc_PettyExpense(CompanyId, BranchId, ExpenseDate);
END

IF OBJECT_ID('dbo.Acc_PettyExpenseLine', 'U') IS NULL
    CREATE TABLE dbo.Acc_PettyExpenseLine
    (
        LineId        INT IDENTITY(1,1) CONSTRAINT PK_Acc_PettyExpenseLine PRIMARY KEY,
        ExpenseId     INT NOT NULL CONSTRAINT FK_Acc_PettyExpenseLine_Expense REFERENCES dbo.Acc_PettyExpense(ExpenseId),
        ExpenseHeadId INT NOT NULL CONSTRAINT FK_Acc_PettyExpenseLine_Head REFERENCES dbo.Acc_ExpenseHead(ExpenseHeadId),
        Amount        DECIMAL(18,2) NOT NULL CONSTRAINT CK_Acc_PettyExpenseLine_Amount CHECK (Amount > 0),   -- paid, GST included
        GstAmount     DECIMAL(18,2) NOT NULL CONSTRAINT DF_Acc_PettyExpenseLine_Gst DEFAULT 0,               -- the GST inside Amount, claimed as input credit
        Remarks       NVARCHAR(200) NULL,
        CONSTRAINT CK_Acc_PettyExpenseLine_Gst CHECK (GstAmount >= 0 AND GstAmount < Amount)
    );

IF OBJECT_ID('dbo.Acc_PettyCashClosing', 'U') IS NULL
    CREATE TABLE dbo.Acc_PettyCashClosing
    (
        ClosingId        INT IDENTITY(1,1) CONSTRAINT PK_Acc_PettyCashClosing PRIMARY KEY,
        CounterId        INT NOT NULL CONSTRAINT FK_Acc_PettyCashClosing_Counter REFERENCES dbo.Acc_PettyCashCounter(CounterId),
        ClosingDate      DATE NOT NULL,
        BookBalance      DECIMAL(18,2) NOT NULL,
        CountedCash      DECIMAL(18,2) NOT NULL,
        Difference       DECIMAL(18,2) NOT NULL,       -- counted - book: negative = shortage, positive = excess
        DenominationJson NVARCHAR(1000) NULL,
        Remarks          NVARCHAR(300) NULL,
        TransactionId    BIGINT NULL,                  -- the shortage / excess journal, when there was a difference
        CreatedBy        INT NULL,
        CreatedDate      DATETIME NOT NULL CONSTRAINT DF_Acc_PettyCashClosing_Created DEFAULT GETDATE(),
        CONSTRAINT UX_Acc_PettyCashClosing UNIQUE (CounterId, ClosingDate)
    );

IF OBJECT_ID('dbo.Acc_Voucher', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Acc_Voucher
    (
        VoucherId      INT IDENTITY(1,1) CONSTRAINT PK_Acc_Voucher PRIMARY KEY,
        CompanyId      INT NOT NULL,
        BranchId       INT NOT NULL,
        VoucherTypeId  INT NOT NULL CONSTRAINT FK_Acc_Voucher_Type REFERENCES dbo.Acc_VoucherType(VoucherTypeId),
        VoucherDate    DATE NOT NULL,
        PayeeName      NVARCHAR(150) NULL,
        PaymentMode    NVARCHAR(50) NULL,
        InstrumentNo   NVARCHAR(100) NULL,
        InstrumentDate DATE NULL,
        Narration      NVARCHAR(500) NULL,
        TotalAmount    DECIMAL(18,2) NOT NULL,
        Status         CHAR(1) NOT NULL CONSTRAINT CK_Acc_Voucher_Status CHECK (Status IN ('S', 'A', 'R', 'C')),
        TransactionId  BIGINT NULL,
        VoucherNo      NVARCHAR(50) NULL,
        CreatedBy      INT NULL,
        CreatedDate    DATETIME NOT NULL CONSTRAINT DF_Acc_Voucher_Created DEFAULT GETDATE(),
        ApprovedBy     INT NULL,
        ApprovedDate   DATETIME NULL,
        RejectedBy     INT NULL,
        RejectedDate   DATETIME NULL,
        RejectReason   NVARCHAR(300) NULL,
        CancelledBy    INT NULL,
        CancelledDate  DATETIME NULL,
        CancelReason   NVARCHAR(300) NULL
    );
    CREATE INDEX IX_Acc_Voucher_Branch ON dbo.Acc_Voucher(CompanyId, BranchId, VoucherDate, Status);
END

IF OBJECT_ID('dbo.Acc_VoucherLine', 'U') IS NULL
    CREATE TABLE dbo.Acc_VoucherLine
    (
        LineId       INT IDENTITY(1,1) CONSTRAINT PK_Acc_VoucherLine PRIMARY KEY,
        VoucherId    INT NOT NULL CONSTRAINT FK_Acc_VoucherLine_Voucher REFERENCES dbo.Acc_Voucher(VoucherId),
        LedgerId     INT NOT NULL CONSTRAINT FK_Acc_VoucherLine_Ledger REFERENCES dbo.Acc_LedgerMaster(LedgerId),
        DebitAmount  DECIMAL(18,2) NOT NULL CONSTRAINT DF_Acc_VoucherLine_Dr DEFAULT 0,
        CreditAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_Acc_VoucherLine_Cr DEFAULT 0,
        Narration    NVARCHAR(300) NULL
    );
GO

-- ── 3. Starter kit: groups, ledgers, voucher types ──────────────────────────
DECLARE @g TABLE (GroupName NVARCHAR(100), GroupType NVARCHAR(50));
INSERT INTO @g VALUES ('Current Assets', 'Asset'), ('Cash In Hand', 'Asset'), ('Bank Accounts', 'Asset'), ('Loans and Advances', 'Asset'),
                      ('Current Liabilities', 'Liability'), ('Sundry Creditors', 'Liability'), ('Duties and Taxes', 'Liability'), ('Capital Account', 'Liability'),
                      ('Direct Income', 'Income'), ('Indirect Income', 'Income'), ('Direct Expenses', 'Expense'), ('Indirect Expenses', 'Expense');
INSERT INTO dbo.Acc_LedgerGroup (GroupName, GroupType)
SELECT g.GroupName, g.GroupType FROM @g g WHERE NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup x WHERE x.GroupName = g.GroupName);
UPDATE dbo.Acc_LedgerGroup SET IsSystem = 1 WHERE GroupName IN (SELECT GroupName FROM @g) AND IsSystem = 0;

-- the ledgers billing posts to: locked (found by name in the billing procedures)
UPDATE dbo.Acc_LedgerMaster SET IsSystem = 1
WHERE IsSystem = 0 AND LedgerName IN ('Patient Receivable', 'OPD Revenue', 'Cash Account', 'LAB Revenue', 'Franchise Receivable', 'Corporate Receivable',
      'Franchise Wallet (Advance)', 'Bank Account', 'Membership Revenue', 'Discount Allowed', 'Round Off', 'Membership Points Liability',
      'Membership Points Expense', 'GST Output Payable', 'Membership Discount');

UPDATE l SET LedgerType = CASE
        WHEN l.LedgerName = 'Cash Account' THEN 'CASH'
        WHEN l.LedgerName = 'Bank Account' THEN 'BANK'
        WHEN l.LedgerName LIKE '%Receivable' OR l.LedgerName LIKE 'Franchise Wallet%' THEN 'PARTY'
        WHEN l.LedgerName LIKE 'GST %' THEN 'TAX'
        WHEN g.GroupType = 'Income' THEN 'INCOME'
        WHEN g.GroupType = 'Expense' THEN 'EXPENSE'
        ELSE 'GENERAL' END
FROM dbo.Acc_LedgerMaster l JOIN dbo.Acc_LedgerGroup g ON g.LedgerGroupId = l.LedgerGroupId
WHERE l.IsSystem = 1 AND l.LedgerType = 'GENERAL';

DECLARE @l TABLE (LedgerName NVARCHAR(100), GroupName NVARCHAR(100), LedgerType VARCHAR(10), BalType NVARCHAR(2), Code NVARCHAR(30));
INSERT INTO @l VALUES
    ('Petty Cash Shortage', 'Indirect Expenses', 'EXPENSE', 'Dr', 'PETTY_SHORTAGE'),
    ('Petty Cash Excess',   'Indirect Income',   'INCOME',  'Cr', 'PETTY_EXCESS'),
    ('Staff Advance',       'Loans and Advances', 'PARTY',  'Dr', 'STAFF_ADVANCE'),
    ('GST Input Credit',    'Current Assets',    'TAX',     'Dr', 'GST_INPUT');
INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem)
SELECT l.LedgerName, g.LedgerGroupId, 0, l.BalType, 1, GETDATE(), l.Code, l.LedgerType, 1
FROM @l l JOIN dbo.Acc_LedgerGroup g ON g.GroupName = l.GroupName
WHERE NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster x WHERE x.LedgerCode = l.Code OR x.LedgerName = l.LedgerName);

UPDATE dbo.Acc_LedgerMaster SET LedgerCode = 'LGR' + RIGHT('0000' + CAST(LedgerId AS VARCHAR(10)), 4) WHERE LedgerCode IS NULL;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_Acc_LedgerMaster_Code' AND object_id = OBJECT_ID('dbo.Acc_LedgerMaster'))
    CREATE UNIQUE INDEX UX_Acc_LedgerMaster_Code ON dbo.Acc_LedgerMaster(LedgerCode) WHERE LedgerCode IS NOT NULL;

-- voucher types
UPDATE dbo.Acc_VoucherType SET VoucherTypeCode = CASE VoucherTypeName WHEN 'Sales' THEN 'SLS' WHEN 'Receipt' THEN 'RCT' WHEN 'Credit Note' THEN 'CN' ELSE VoucherTypeCode END
WHERE VoucherTypeCode IS NULL;
UPDATE dbo.Acc_VoucherType SET IsManual = 1 WHERE VoucherTypeCode = 'RCT' AND IsManual = 0;
DECLARE @v TABLE (Name NVARCHAR(50), Code VARCHAR(10), IsManual BIT);
INSERT INTO @v VALUES ('Payment', 'PMT', 1), ('Contra', 'CTR', 1), ('Journal', 'JRN', 1), ('Petty Cash', 'PCV', 0);
INSERT INTO dbo.Acc_VoucherType (VoucherTypeName, Prefix, IsActive, VoucherTypeCode, IsManual)
SELECT v.Name, v.Code, 1, v.Code, v.IsManual FROM @v v WHERE NOT EXISTS (SELECT 1 FROM dbo.Acc_VoucherType x WHERE x.VoucherTypeCode = v.Code OR x.VoucherTypeName = v.Name);

-- settings row per company
INSERT INTO dbo.Acc_Settings (CompanyId)
SELECT c.CompanyId FROM dbo.CompanyMaster c WHERE NOT EXISTS (SELECT 1 FROM dbo.Acc_Settings s WHERE s.CompanyId = c.CompanyId);
GO

-- starter expense heads, each with its own expense ledger (a client can rename, add or switch them off)
DECLARE @h TABLE (HeadName NVARCHAR(100), GroupName NVARCHAR(100));
INSERT INTO @h VALUES
    ('Courier and Sample Transport', 'Direct Expenses'), ('Minor Lab Consumables', 'Direct Expenses'), ('Biomedical Waste Disposal', 'Direct Expenses'),
    ('Conveyance and Fuel', 'Indirect Expenses'), ('Printing and Stationery', 'Indirect Expenses'), ('Tea and Refreshments', 'Indirect Expenses'),
    ('Housekeeping and Cleaning', 'Indirect Expenses'), ('Repairs and Maintenance', 'Indirect Expenses'), ('Electricity and Water', 'Indirect Expenses'),
    ('Telephone and Internet', 'Indirect Expenses'), ('Postage', 'Indirect Expenses'), ('Staff Welfare', 'Indirect Expenses'),
    ('Bank Charges', 'Indirect Expenses'), ('Miscellaneous Expenses', 'Indirect Expenses');

IF NOT EXISTS (SELECT 1 FROM dbo.Acc_ExpenseHead)
BEGIN
    INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerType, IsSystem)
    SELECT h.HeadName, g.LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'EXPENSE', 0
    FROM @h h JOIN dbo.Acc_LedgerGroup g ON g.GroupName = h.GroupName
    WHERE NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster x WHERE x.LedgerName = h.HeadName);
    UPDATE dbo.Acc_LedgerMaster SET LedgerCode = 'LGR' + RIGHT('0000' + CAST(LedgerId AS VARCHAR(10)), 4) WHERE LedgerCode IS NULL;

    INSERT INTO dbo.Acc_ExpenseHead (CompanyId, HeadName, LedgerId)
    SELECT c.CompanyId, h.HeadName, l.LedgerId
    FROM @h h JOIN dbo.Acc_LedgerMaster l ON l.LedgerName = h.HeadName CROSS JOIN dbo.CompanyMaster c
    WHERE c.IsActive = 1;

    INSERT INTO dbo.Acc_ExpenseHead (CompanyId, HeadName, LedgerId)
    SELECT c.CompanyId, 'Staff Advance', l.LedgerId
    FROM dbo.Acc_LedgerMaster l CROSS JOIN dbo.CompanyMaster c WHERE l.LedgerCode = 'STAFF_ADVANCE' AND c.IsActive = 1;
END
GO

-- ── 4. Helpers ──────────────────────────────────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Acc_FinancialYear (@Date DATE, @StartMonth TINYINT)
RETURNS VARCHAR(7)
AS
BEGIN
    DECLARE @y INT = YEAR(@Date) - CASE WHEN MONTH(@Date) < ISNULL(@StartMonth, 4) THEN 1 ELSE 0 END;
    IF ISNULL(@StartMonth, 4) = 1 RETURN CAST(@y AS VARCHAR(4));
    RETURN RIGHT(CAST(@y AS VARCHAR(4)), 2) + '-' + RIGHT(CAST(@y + 1 AS VARCHAR(4)), 2);
END
GO

-- Balance of a ledger, Dr positive: opening + every posted line up to the end of @UpTo (NULL = everything).
CREATE OR ALTER FUNCTION dbo.fn_Acc_LedgerBalance (@LedgerId INT, @UpTo DATE)
RETURNS DECIMAL(18,2)
AS
BEGIN
    DECLARE @bal DECIMAL(18,2);
    SELECT @bal = CASE WHEN OpeningBalanceType = 'Cr' THEN -OpeningBalance ELSE OpeningBalance END FROM dbo.Acc_LedgerMaster WHERE LedgerId = @LedgerId;
    SELECT @bal = ISNULL(@bal, 0) + ISNULL(SUM(d.DebitAmount - d.CreditAmount), 0)
    FROM dbo.Acc_LedgerTransactionDetail d
    JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId
    WHERE d.LedgerId = @LedgerId AND t.IsActive = 1 AND (@UpTo IS NULL OR t.TransactionDate < DATEADD(DAY, 1, CAST(@UpTo AS DATETIME)));
    RETURN ISNULL(@bal, 0);
END
GO

-- Entry-date rule shared by expenses, floats and vouchers: not in the future, not older than the company's
-- back-date days, not in a period locked for the branch.
CREATE OR ALTER PROCEDURE dbo.usp_Acc_CheckEntryDate
    @CompanyId INT,
    @BranchId  INT,
    @Date      DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @back INT = 2, @lock DATE, @today DATE = CAST(GETDATE() AS DATE), @msg NVARCHAR(200);
    SELECT @back = BackDateDays FROM dbo.Acc_Settings WHERE CompanyId = @CompanyId;
    SELECT @lock = LockedUpTo FROM dbo.Acc_BranchLock WHERE CompanyId = @CompanyId AND BranchId = @BranchId;
    IF @Date IS NULL THROW 53001, 'Enter the date.', 1;
    IF @Date > @today THROW 53002, 'The date cannot be in the future.', 1;
    IF @Date < DATEADD(DAY, -@back, @today)
    BEGIN
        SET @msg = CONCAT('Back-dated entry is allowed for ', @back, ' day(s) only.');
        THROW 53003, @msg, 1;
    END
    IF @lock IS NOT NULL AND @Date <= @lock
    BEGIN
        SET @msg = CONCAT('The books of this branch are locked up to ', FORMAT(@lock, 'dd-MMM-yyyy'), '.');
        THROW 53004, @msg, 1;
    END
END
GO

-- ── 5. Posting ──────────────────────────────────────────────────────────────
-- One voucher, any number of lines: @LinesJson = [{"LedgerId":1,"Dr":100,"Cr":0,"Narration":"..."}, ...].
-- Refuses an unbalanced voucher, an inactive ledger and a period locked for the branch. A reference (@ReferenceType + @ReferenceId)
-- is posted once: a second call returns the entry already there.
CREATE OR ALTER PROCEDURE dbo.usp_Acc_PostVoucher
    @VoucherTypeCode VARCHAR(10),
    @TransactionDate DATETIME,
    @CompanyId       INT,
    @BranchId        INT,
    @ReferenceType   NVARCHAR(50) = NULL,
    @ReferenceId     INT = NULL,
    @Narration       NVARCHAR(MAX) = NULL,
    @PayeeName       NVARCHAR(150) = NULL,
    @PaymentMode     NVARCHAR(50) = NULL,
    @InstrumentNo    NVARCHAR(100) = NULL,
    @InstrumentDate  DATE = NULL,
    @LinesJson       NVARCHAR(MAX),
    @IsManual        BIT = 0,
    @ReversalOf      BIGINT = NULL,
    @UserId          INT = NULL,
    @TransactionId   BIGINT OUTPUT,
    @VoucherNo       NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @typeId INT, @prefix NVARCHAR(10), @msg NVARCHAR(300);
    SELECT @typeId = VoucherTypeId, @prefix = ISNULL(NULLIF(Prefix, ''), VoucherTypeCode) FROM dbo.Acc_VoucherType WHERE VoucherTypeCode = @VoucherTypeCode AND IsActive = 1;
    IF @typeId IS NULL THROW 53010, 'Voucher type not found.', 1;
    IF @BranchId IS NULL OR @BranchId <= 0 THROW 53011, 'Branch is required to post a voucher.', 1;

    IF @ReversalOf IS NULL AND @ReferenceType IS NOT NULL AND @ReferenceId IS NOT NULL
    BEGIN
        SELECT TOP 1 @TransactionId = TransactionId, @VoucherNo = VoucherNo FROM dbo.Acc_LedgerTransaction
        WHERE ReferenceType = @ReferenceType AND ReferenceId = @ReferenceId AND IsActive = 1 AND Status = 'P' AND ReversalOfTransactionId IS NULL;
        IF @TransactionId IS NOT NULL RETURN;
    END

    DECLARE @lines TABLE (Seq INT IDENTITY(1,1), LedgerId INT, Dr DECIMAL(18,2), Cr DECIMAL(18,2), Narration NVARCHAR(300));
    INSERT INTO @lines (LedgerId, Dr, Cr, Narration)
    SELECT LedgerId, ISNULL(Dr, 0), ISNULL(Cr, 0), NULLIF(LTRIM(RTRIM(Narration)), '')
    FROM OPENJSON(@LinesJson) WITH (LedgerId INT '$.LedgerId', Dr DECIMAL(18,2) '$.Dr', Cr DECIMAL(18,2) '$.Cr', Narration NVARCHAR(300) '$.Narration');

    IF (SELECT COUNT(*) FROM @lines) < 2 THROW 53012, 'A voucher needs at least one debit and one credit line.', 1;
    IF EXISTS (SELECT 1 FROM @lines WHERE Dr < 0 OR Cr < 0 OR (Dr = 0 AND Cr = 0) OR (Dr > 0 AND Cr > 0))
        THROW 53013, 'Every line needs either a debit or a credit amount greater than zero.', 1;
    DECLARE @dr DECIMAL(18,2), @cr DECIMAL(18,2);
    SELECT @dr = SUM(Dr), @cr = SUM(Cr) FROM @lines;
    IF @dr <> @cr
    BEGIN
        SET @msg = CONCAT('The voucher does not balance: debit ', FORMAT(@dr, 'N2'), ', credit ', FORMAT(@cr, 'N2'), '.');
        THROW 53014, @msg, 1;
    END
    IF EXISTS (SELECT 1 FROM @lines x LEFT JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = x.LedgerId WHERE l.LedgerId IS NULL OR l.IsActive = 0)
        THROW 53015, 'A ledger on the voucher is missing or inactive.', 1;

    DECLARE @lock DATE, @fyStart TINYINT = 4;
    SELECT @fyStart = FinancialYearStartMonth FROM dbo.Acc_Settings WHERE CompanyId = @CompanyId;
    SELECT @lock = LockedUpTo FROM dbo.Acc_BranchLock WHERE CompanyId = @CompanyId AND BranchId = @BranchId;
    IF @lock IS NOT NULL AND CAST(@TransactionDate AS DATE) <= @lock
    BEGIN
        SET @msg = CONCAT('The books of this branch are locked up to ', FORMAT(@lock, 'dd-MMM-yyyy'), '.');
        THROW 53004, @msg, 1;
    END

    DECLARE @fy VARCHAR(7) = dbo.fn_Acc_FinancialYear(@TransactionDate, @fyStart), @no INT, @branchCode NVARCHAR(20);
    SELECT @branchCode = ISNULL(NULLIF(BranchCode, ''), CAST(BranchID AS NVARCHAR(10))) FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.Acc_VoucherSequence WITH (UPDLOCK, HOLDLOCK) SET @no = LastNo = LastNo + 1
        WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND VoucherTypeId = @typeId AND FinancialYear = @fy;
        IF @@ROWCOUNT = 0
        BEGIN
            SET @no = 1;
            INSERT INTO dbo.Acc_VoucherSequence (CompanyId, BranchId, VoucherTypeId, FinancialYear, LastNo) VALUES (@CompanyId, @BranchId, @typeId, @fy, 1);
        END
        SET @VoucherNo = CONCAT(@prefix, '/', ISNULL(@branchCode, CAST(@BranchId AS NVARCHAR(10))), '/', @fy, '/', RIGHT('00000' + CAST(@no AS VARCHAR(10)), 5));

        INSERT INTO dbo.Acc_LedgerTransaction (VoucherTypeId, VoucherNo, TransactionDate, ReferenceType, ReferenceId, BranchId, CompanyId, TotalAmount, Narration,
                                               CreatedBy, CreatedDate, Status, ReversalOfTransactionId, IsManual, FinancialYear, PayeeName, PaymentMode, InstrumentNo, InstrumentDate)
        VALUES (@typeId, @VoucherNo, @TransactionDate, @ReferenceType, @ReferenceId, @BranchId, @CompanyId, @dr, @Narration,
                @UserId, GETDATE(), 'P', @ReversalOf, @IsManual, @fy, @PayeeName, @PaymentMode, @InstrumentNo, @InstrumentDate);
        SET @TransactionId = SCOPE_IDENTITY();

        INSERT INTO dbo.Acc_LedgerTransactionDetail (TransactionId, LedgerId, DebitAmount, CreditAmount, Narration)
        SELECT @TransactionId, LedgerId, Dr, Cr, ISNULL(Narration, @Narration) FROM @lines ORDER BY Seq;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Cancels a posted voucher by posting its reversal (lines swapped, dated today). Nothing is deleted.
CREATE OR ALTER PROCEDURE dbo.usp_Acc_CancelVoucher
    @TransactionId BIGINT,
    @Reason        NVARCHAR(300),
    @UserId        INT = NULL,
    @ReversalId    BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @typeCode VARCHAR(10), @co INT, @br INT, @refType NVARCHAR(50), @refId INT, @no NVARCHAR(50), @status CHAR(1), @rev BIGINT, @narr NVARCHAR(MAX),
            @payee NVARCHAR(150), @lines NVARCHAR(MAX), @revNo NVARCHAR(50), @now DATETIME = GETDATE();
    SELECT @typeCode = v.VoucherTypeCode, @co = ISNULL(t.CompanyId, 1), @br = t.BranchId, @refType = t.ReferenceType, @refId = t.ReferenceId, @no = t.VoucherNo,
           @status = t.Status, @rev = t.ReversalOfTransactionId, @payee = t.PayeeName
    FROM dbo.Acc_LedgerTransaction t JOIN dbo.Acc_VoucherType v ON v.VoucherTypeId = t.VoucherTypeId
    WHERE t.TransactionId = @TransactionId AND t.IsActive = 1;

    IF @typeCode IS NULL THROW 53020, 'Voucher not found.', 1;
    IF @status = 'C' THROW 53021, 'This voucher is already cancelled.', 1;
    IF @rev IS NOT NULL THROW 53022, 'A reversal voucher cannot be cancelled.', 1;
    IF NULLIF(LTRIM(RTRIM(@Reason)), '') IS NULL THROW 53023, 'Enter the reason for cancellation.', 1;

    SELECT @lines = (SELECT LedgerId, CreditAmount AS Dr, DebitAmount AS Cr FROM dbo.Acc_LedgerTransactionDetail WHERE TransactionId = @TransactionId FOR JSON PATH);
    SET @narr = CONCAT('Reversal of ', @no, ': ', LTRIM(RTRIM(@Reason)));

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = @typeCode, @TransactionDate = @now, @CompanyId = @co, @BranchId = @br, @ReferenceType = @refType,
             @ReferenceId = @refId, @Narration = @narr, @PayeeName = @payee, @LinesJson = @lines, @IsManual = 0, @ReversalOf = @TransactionId, @UserId = @UserId,
             @TransactionId = @ReversalId OUTPUT, @VoucherNo = @revNo OUTPUT;
        UPDATE dbo.Acc_LedgerTransaction SET Status = 'C', CancelledBy = @UserId, CancelledDate = @now, CancelReason = LTRIM(RTRIM(@Reason)) WHERE TransactionId = @TransactionId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── 6. Masters ──────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Acc_LedgerGroup_Save
    @LedgerGroupId INT,
    @GroupName     NVARCHAR(100),
    @GroupType     NVARCHAR(50),
    @ParentGroupId INT = NULL,
    @IsActive      BIT = 1,
    @UserId        INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @GroupName = LTRIM(RTRIM(@GroupName));
    IF NULLIF(@GroupName, '') IS NULL THROW 53030, 'Enter the group name.', 1;
    IF @GroupType NOT IN ('Asset', 'Liability', 'Income', 'Expense') THROW 53031, 'Select the nature of the group.', 1;
    IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup WHERE GroupName = @GroupName AND LedgerGroupId <> ISNULL(@LedgerGroupId, 0))
        THROW 53032, 'A ledger group with this name already exists.', 1;
    IF @ParentGroupId IS NOT NULL
    BEGIN
        IF @ParentGroupId = @LedgerGroupId THROW 53033, 'A group cannot be its own parent.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup WHERE LedgerGroupId = @ParentGroupId AND GroupType = @GroupType)
            THROW 53034, 'The parent group must be of the same nature.', 1;
    END

    IF ISNULL(@LedgerGroupId, 0) = 0
    BEGIN
        INSERT INTO dbo.Acc_LedgerGroup (GroupName, ParentGroupId, GroupType, IsActive, CreatedBy) VALUES (@GroupName, @ParentGroupId, @GroupType, 1, @UserId);
        SELECT CAST(SCOPE_IDENTITY() AS INT) AS Id;
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup WHERE LedgerGroupId = @LedgerGroupId AND IsSystem = 1 AND (GroupName <> @GroupName OR GroupType <> @GroupType OR @IsActive = 0))
        THROW 53035, 'A system group cannot be renamed, changed in nature or switched off.', 1;
    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerGroupId = @LedgerGroupId AND IsActive = 1)
        THROW 53036, 'This group has active ledgers. Move or switch them off first.', 1;
    IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup WHERE LedgerGroupId = @LedgerGroupId AND GroupType <> @GroupType)
       AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerGroupId = @LedgerGroupId)
        THROW 53037, 'The nature of a group that has ledgers cannot be changed.', 1;

    UPDATE dbo.Acc_LedgerGroup SET GroupName = @GroupName, GroupType = @GroupType, ParentGroupId = @ParentGroupId, IsActive = @IsActive,
           ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE LedgerGroupId = @LedgerGroupId;
    SELECT @LedgerGroupId AS Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Acc_Ledger_Save
    @LedgerId           INT,
    @LedgerName         NVARCHAR(100),
    @LedgerGroupId      INT,
    @LedgerType         VARCHAR(10),
    @OpeningBalance     DECIMAL(18,2) = 0,
    @OpeningBalanceType NVARCHAR(2) = 'Dr',
    @Remarks            NVARCHAR(300) = NULL,
    @IsActive           BIT = 1,
    @UserId             INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @LedgerName = LTRIM(RTRIM(@LedgerName));
    IF NULLIF(@LedgerName, '') IS NULL THROW 53040, 'Enter the ledger name.', 1;
    IF @LedgerType NOT IN ('CASH', 'BANK', 'PARTY', 'EXPENSE', 'INCOME', 'TAX', 'GENERAL', 'PETTY') THROW 53041, 'Select the ledger type.', 1;
    IF @OpeningBalanceType NOT IN ('Dr', 'Cr') THROW 53042, 'Opening balance must be Dr or Cr.', 1;
    IF ISNULL(@OpeningBalance, 0) < 0 THROW 53043, 'Opening balance cannot be negative: choose Dr or Cr.', 1;
    DECLARE @groupType NVARCHAR(50);
    SELECT @groupType = GroupType FROM dbo.Acc_LedgerGroup WHERE LedgerGroupId = @LedgerGroupId AND IsActive = 1;
    IF @groupType IS NULL THROW 53044, 'Select an active ledger group.', 1;
    IF @LedgerType IN ('CASH', 'BANK', 'PETTY') AND @groupType <> 'Asset' THROW 53045, 'A cash or bank ledger must be under an Asset group.', 1;
    IF @LedgerType = 'EXPENSE' AND @groupType <> 'Expense' THROW 53046, 'An expense ledger must be under an Expense group.', 1;
    IF @LedgerType = 'INCOME' AND @groupType <> 'Income' THROW 53047, 'An income ledger must be under an Income group.', 1;
    IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = @LedgerName AND LedgerId <> ISNULL(@LedgerId, 0))
        THROW 53048, 'A ledger with this name already exists.', 1;

    IF ISNULL(@LedgerId, 0) = 0
    BEGIN
        IF @LedgerType = 'PETTY' THROW 53049, 'A petty cash ledger is created from the Petty Cash Counter screen.', 1;
        INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedBy, CreatedDate, LedgerType, IsSystem, Remarks)
        VALUES (@LedgerName, @LedgerGroupId, ISNULL(@OpeningBalance, 0), @OpeningBalanceType, 1, @UserId, GETDATE(), @LedgerType, 0, NULLIF(LTRIM(RTRIM(@Remarks)), ''));
        SET @LedgerId = SCOPE_IDENTITY();
        UPDATE dbo.Acc_LedgerMaster SET LedgerCode = 'LGR' + RIGHT('0000' + CAST(@LedgerId AS VARCHAR(10)), 4) WHERE LedgerId = @LedgerId;
        SELECT @LedgerId AS Id;
        RETURN;
    END

    DECLARE @isSystem BIT, @oldName NVARCHAR(100), @oldType VARCHAR(10), @oldGroup INT;
    SELECT @isSystem = IsSystem, @oldName = LedgerName, @oldType = LedgerType, @oldGroup = LedgerGroupId FROM dbo.Acc_LedgerMaster WHERE LedgerId = @LedgerId;
    IF @oldName IS NULL THROW 53050, 'Ledger not found.', 1;
    IF @isSystem = 1 AND (@oldName <> @LedgerName OR @oldType <> @LedgerType OR @oldGroup <> @LedgerGroupId OR @IsActive = 0)
        THROW 53051, 'A system ledger is used by billing: only its opening balance and remarks can be changed.', 1;
    IF @oldType = 'PETTY' AND (@LedgerType <> 'PETTY' OR ISNULL(@OpeningBalance, 0) <> 0)
        THROW 53052, 'A petty cash ledger belongs to its counter: its type cannot change and it has no opening balance.', 1;
    IF @oldType <> 'PETTY' AND @LedgerType = 'PETTY' THROW 53049, 'A petty cash ledger is created from the Petty Cash Counter screen.', 1;
    IF @IsActive = 0 AND dbo.fn_Acc_LedgerBalance(@LedgerId, NULL) <> 0 THROW 53053, 'This ledger has a balance and cannot be switched off.', 1;
    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM dbo.Acc_ExpenseHead WHERE LedgerId = @LedgerId AND IsActive = 1)
        THROW 53054, 'This ledger is mapped to an active expense head.', 1;

    UPDATE dbo.Acc_LedgerMaster SET LedgerName = @LedgerName, LedgerGroupId = @LedgerGroupId, LedgerType = @LedgerType, OpeningBalance = ISNULL(@OpeningBalance, 0),
           OpeningBalanceType = @OpeningBalanceType, Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''), IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE LedgerId = @LedgerId;
    SELECT @LedgerId AS Id;
END
GO

-- An expense head with no ledger chosen gets its own expense ledger under Indirect Expenses.
CREATE OR ALTER PROCEDURE dbo.usp_Acc_ExpenseHead_Save
    @ExpenseHeadId     INT,
    @CompanyId         INT,
    @HeadName          NVARCHAR(100),
    @LedgerId          INT = NULL,
    @MaxPerVoucher     DECIMAL(18,2) = NULL,
    @BillRequiredAbove DECIMAL(18,2) = NULL,
    @IsActive          BIT = 1,
    @UserId            INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @HeadName = LTRIM(RTRIM(@HeadName));
    IF NULLIF(@HeadName, '') IS NULL THROW 53060, 'Enter the expense head name.', 1;
    IF @MaxPerVoucher IS NOT NULL AND @MaxPerVoucher <= 0 THROW 53061, 'Limit per voucher must be greater than zero (or left blank).', 1;
    IF @BillRequiredAbove IS NOT NULL AND @BillRequiredAbove < 0 THROW 53062, 'Bill-required amount cannot be negative.', 1;
    IF EXISTS (SELECT 1 FROM dbo.Acc_ExpenseHead WHERE CompanyId = @CompanyId AND HeadName = @HeadName AND ExpenseHeadId <> ISNULL(@ExpenseHeadId, 0))
        THROW 53063, 'An expense head with this name already exists.', 1;

    BEGIN TRANSACTION;
    IF ISNULL(@LedgerId, 0) = 0
    BEGIN
        SELECT @LedgerId = LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = @HeadName AND LedgerType = 'EXPENSE' AND IsActive = 1;
        IF @LedgerId IS NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = @HeadName)
                THROW 53064, 'A ledger with this name exists but is not an active expense ledger. Choose the ledger to post to.', 1;
            INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedBy, CreatedDate, LedgerType, IsSystem)
            SELECT @HeadName, LedgerGroupId, 0, 'Dr', 1, @UserId, GETDATE(), 'EXPENSE', 0 FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Indirect Expenses';
            SET @LedgerId = SCOPE_IDENTITY();
            IF @LedgerId IS NULL THROW 53065, 'Ledger group "Indirect Expenses" is missing.', 1;
            UPDATE dbo.Acc_LedgerMaster SET LedgerCode = 'LGR' + RIGHT('0000' + CAST(@LedgerId AS VARCHAR(10)), 4) WHERE LedgerId = @LedgerId;
        END
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerId = @LedgerId AND IsActive = 1 AND LedgerType NOT IN ('CASH', 'BANK', 'PETTY'))
        THROW 53066, 'Choose an active ledger (not a cash, bank or petty cash ledger).', 1;

    IF ISNULL(@ExpenseHeadId, 0) = 0
    BEGIN
        INSERT INTO dbo.Acc_ExpenseHead (CompanyId, HeadName, LedgerId, MaxPerVoucher, BillRequiredAbove, IsActive, CreatedBy)
        VALUES (@CompanyId, @HeadName, @LedgerId, @MaxPerVoucher, @BillRequiredAbove, 1, @UserId);
        SET @ExpenseHeadId = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE dbo.Acc_ExpenseHead SET HeadName = @HeadName, LedgerId = @LedgerId, MaxPerVoucher = @MaxPerVoucher, BillRequiredAbove = @BillRequiredAbove,
               IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE ExpenseHeadId = @ExpenseHeadId AND CompanyId = @CompanyId;
    COMMIT TRANSACTION;
    SELECT @ExpenseHeadId AS Id;
END
GO

-- A counter owns one petty cash ledger ("Petty Cash - <branch> - <counter>"), created with it.
CREATE OR ALTER PROCEDURE dbo.usp_Acc_PettyCounter_Save
    @CounterId       INT,
    @CompanyId       INT,
    @BranchId        INT,
    @CounterName     NVARCHAR(100),
    @CustodianUserId INT = NULL,
    @FloatAmount     DECIMAL(18,2),
    @FundingLedgerId INT = NULL,
    @LowBalanceAlert DECIMAL(18,2) = NULL,
    @IsActive        BIT = 1,
    @UserId          INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @CounterName = LTRIM(RTRIM(@CounterName));
    IF NULLIF(@CounterName, '') IS NULL THROW 53070, 'Enter the counter name.', 1;
    IF ISNULL(@FloatAmount, 0) <= 0 THROW 53071, 'Float amount must be greater than zero.', 1;
    IF @LowBalanceAlert IS NOT NULL AND (@LowBalanceAlert < 0 OR @LowBalanceAlert > @FloatAmount) THROW 53072, 'Low-balance alert must be between zero and the float amount.', 1;
    DECLARE @branch NVARCHAR(100);
    SELECT @branch = ISNULL(NULLIF(BranchCode, ''), BranchName) FROM dbo.Branchmaster WHERE BranchID = @BranchId AND IsActive = 1;
    IF @branch IS NULL THROW 53073, 'Select an active branch.', 1;
    IF @FundingLedgerId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerId = @FundingLedgerId AND IsActive = 1 AND LedgerType IN ('CASH', 'BANK'))
        THROW 53074, 'The funding ledger must be an active cash or bank ledger.', 1;
    IF EXISTS (SELECT 1 FROM dbo.Acc_PettyCashCounter WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND CounterName = @CounterName AND CounterId <> ISNULL(@CounterId, 0))
        THROW 53075, 'This branch already has a counter with this name.', 1;

    DECLARE @ledgerName NVARCHAR(100) = LEFT(CONCAT('Petty Cash - ', @branch, ' - ', @CounterName), 100), @ledgerId INT;

    BEGIN TRANSACTION;
    IF ISNULL(@CounterId, 0) = 0
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = @ledgerName) THROW 53076, 'A ledger for this counter name already exists. Use another counter name.', 1;
        INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedBy, CreatedDate, LedgerType, IsSystem)
        SELECT @ledgerName, LedgerGroupId, 0, 'Dr', 1, @UserId, GETDATE(), 'PETTY', 0 FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Cash In Hand';
        SET @ledgerId = SCOPE_IDENTITY();
        IF @ledgerId IS NULL THROW 53077, 'Ledger group "Cash In Hand" is missing.', 1;
        UPDATE dbo.Acc_LedgerMaster SET LedgerCode = 'LGR' + RIGHT('0000' + CAST(@ledgerId AS VARCHAR(10)), 4) WHERE LedgerId = @ledgerId;

        INSERT INTO dbo.Acc_PettyCashCounter (CompanyId, BranchId, CounterName, CustodianUserId, FloatAmount, LedgerId, FundingLedgerId, LowBalanceAlert, IsActive, CreatedBy)
        VALUES (@CompanyId, @BranchId, @CounterName, @CustodianUserId, @FloatAmount, @ledgerId, @FundingLedgerId, @LowBalanceAlert, 1, @UserId);
        SET @CounterId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @oldBranch INT;
        SELECT @ledgerId = LedgerId, @oldBranch = BranchId FROM dbo.Acc_PettyCashCounter WHERE CounterId = @CounterId AND CompanyId = @CompanyId;
        IF @ledgerId IS NULL THROW 53078, 'Counter not found.', 1;
        IF @oldBranch <> @BranchId AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransactionDetail WHERE LedgerId = @ledgerId)
            THROW 53079, 'A counter that has transactions cannot move to another branch.', 1;
        DECLARE @bal DECIMAL(18,2) = dbo.fn_Acc_LedgerBalance(@ledgerId, NULL);
        IF @IsActive = 0 AND @bal <> 0 THROW 53080, 'Return the cash in this counter before switching it off.', 1;
        IF @FloatAmount < @bal THROW 53081, 'The float cannot be less than the cash now in the counter. Return the extra cash first.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = @ledgerName AND LedgerId <> @ledgerId) THROW 53076, 'A ledger for this counter name already exists. Use another counter name.', 1;

        UPDATE dbo.Acc_LedgerMaster SET LedgerName = @ledgerName, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE LedgerId = @ledgerId;
        UPDATE dbo.Acc_PettyCashCounter SET BranchId = @BranchId, CounterName = @CounterName, CustodianUserId = @CustodianUserId, FloatAmount = @FloatAmount,
               FundingLedgerId = @FundingLedgerId, LowBalanceAlert = @LowBalanceAlert, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE CounterId = @CounterId;
    END
    COMMIT TRANSACTION;
    SELECT @CounterId AS Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Acc_Settings_Save
    @CompanyId               INT,
    @PettyApprovalRequired   BIT,
    @PettyAutoApproveLimit   DECIMAL(18,2),
    @PettyMaxPerVoucher      DECIMAL(18,2),
    @AllowPettyOverdraw      BIT,
    @AllowSelfApproval       BIT,
    @VoucherApprovalRequired BIT,
    @BackDateDays            INT,
    @FinancialYearStartMonth TINYINT,
    @PettyGstInputCredit     BIT = 0,
    @UserId                  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @PettyAutoApproveLimit < 0 THROW 53090, 'Auto-approve limit cannot be negative.', 1;
    IF @PettyMaxPerVoucher <= 0 THROW 53091, 'Maximum per petty voucher must be greater than zero.', 1;
    IF @PettyAutoApproveLimit > @PettyMaxPerVoucher THROW 53092, 'Auto-approve limit cannot be more than the maximum per voucher.', 1;
    IF @BackDateDays < 0 OR @BackDateDays > 365 THROW 53093, 'Back-date days must be between 0 and 365.', 1;
    IF @FinancialYearStartMonth NOT BETWEEN 1 AND 12 THROW 53094, 'Financial year start month must be 1 to 12.', 1;

    UPDATE dbo.Acc_Settings SET PettyApprovalRequired = @PettyApprovalRequired, PettyAutoApproveLimit = @PettyAutoApproveLimit, PettyMaxPerVoucher = @PettyMaxPerVoucher,
           AllowPettyOverdraw = @AllowPettyOverdraw, AllowSelfApproval = @AllowSelfApproval, VoucherApprovalRequired = @VoucherApprovalRequired,
           BackDateDays = @BackDateDays, FinancialYearStartMonth = @FinancialYearStartMonth, PettyGstInputCredit = @PettyGstInputCredit,
           ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE CompanyId = @CompanyId;
    IF @@ROWCOUNT = 0
        INSERT INTO dbo.Acc_Settings (CompanyId, PettyApprovalRequired, PettyAutoApproveLimit, PettyMaxPerVoucher, AllowPettyOverdraw, AllowSelfApproval,
                                      VoucherApprovalRequired, BackDateDays, FinancialYearStartMonth, PettyGstInputCredit, ModifiedBy, ModifiedDate)
        VALUES (@CompanyId, @PettyApprovalRequired, @PettyAutoApproveLimit, @PettyMaxPerVoucher, @AllowPettyOverdraw, @AllowSelfApproval,
                @VoucherApprovalRequired, @BackDateDays, @FinancialYearStartMonth, @PettyGstInputCredit, @UserId, GETDATE());
END
GO

-- Lock (or, with NULL, unlock) the books of one branch up to a past date.
CREATE OR ALTER PROCEDURE dbo.usp_Acc_BranchLock_Save
    @CompanyId  INT,
    @BranchId   INT,
    @LockedUpTo DATE = NULL,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND ISNULL(CompanyId, 1) = @CompanyId) THROW 53073, 'Branch not found.', 1;
    IF @LockedUpTo IS NOT NULL AND @LockedUpTo >= CAST(GETDATE() AS DATE) THROW 53095, 'The books can be locked only up to a past date.', 1;
    IF @LockedUpTo IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Acc_PettyExpense WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND Status = 'S' AND ExpenseDate <= @LockedUpTo)
        THROW 53096, 'Petty expenses of this branch dated in that period are still waiting for approval. Approve or reject them first.', 1;
    IF @LockedUpTo IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Acc_Voucher WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND Status = 'S' AND VoucherDate <= @LockedUpTo)
        THROW 53097, 'Vouchers of this branch dated in that period are still waiting for approval. Approve or reject them first.', 1;

    UPDATE dbo.Acc_BranchLock SET LockedUpTo = @LockedUpTo, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE CompanyId = @CompanyId AND BranchId = @BranchId;
    IF @@ROWCOUNT = 0
        INSERT INTO dbo.Acc_BranchLock (CompanyId, BranchId, LockedUpTo, ModifiedBy, ModifiedDate) VALUES (@CompanyId, @BranchId, @LockedUpTo, @UserId, GETDATE());
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Acc_Payee_Save
    @PayeeId              INT,
    @CompanyId            INT,
    @PayeeName            NVARCHAR(150),
    @Phone                NVARCHAR(20) = NULL,
    @GSTIN                NVARCHAR(15) = NULL,
    @PAN                  NVARCHAR(10) = NULL,
    @DefaultExpenseHeadId INT = NULL,
    @Remarks              NVARCHAR(300) = NULL,
    @IsActive             BIT = 1,
    @UserId               INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @PayeeName = LTRIM(RTRIM(@PayeeName));
    SET @GSTIN = NULLIF(UPPER(LTRIM(RTRIM(@GSTIN))), '');
    SET @PAN = NULLIF(UPPER(LTRIM(RTRIM(@PAN))), '');
    IF NULLIF(@PayeeName, '') IS NULL THROW 53170, 'Enter the payee name.', 1;
    IF @GSTIN IS NOT NULL AND @GSTIN NOT LIKE '[0-9][0-9][A-Z][A-Z][A-Z][A-Z][A-Z][0-9][0-9][0-9][0-9][A-Z][0-9A-Z]Z[0-9A-Z]'
        THROW 53171, 'GSTIN is not valid (15 characters, e.g. 19ABCDE1234F1Z5).', 1;
    IF @PAN IS NOT NULL AND @PAN NOT LIKE '[A-Z][A-Z][A-Z][A-Z][A-Z][0-9][0-9][0-9][0-9][A-Z]' THROW 53172, 'PAN is not valid (e.g. ABCDE1234F).', 1;
    IF EXISTS (SELECT 1 FROM dbo.Acc_Payee WHERE CompanyId = @CompanyId AND PayeeName = @PayeeName AND PayeeId <> ISNULL(@PayeeId, 0))
        THROW 53173, 'A payee with this name already exists.', 1;
    IF @DefaultExpenseHeadId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Acc_ExpenseHead WHERE ExpenseHeadId = @DefaultExpenseHeadId AND CompanyId = @CompanyId)
        THROW 53174, 'Default expense head not found.', 1;

    IF ISNULL(@PayeeId, 0) = 0
    BEGIN
        INSERT INTO dbo.Acc_Payee (CompanyId, PayeeName, Phone, GSTIN, PAN, DefaultExpenseHeadId, Remarks, IsActive, CreatedBy)
        VALUES (@CompanyId, @PayeeName, NULLIF(LTRIM(RTRIM(@Phone)), ''), @GSTIN, @PAN, @DefaultExpenseHeadId, NULLIF(LTRIM(RTRIM(@Remarks)), ''), 1, @UserId);
        SELECT CAST(SCOPE_IDENTITY() AS INT) AS Id;
        RETURN;
    END
    UPDATE dbo.Acc_Payee SET PayeeName = @PayeeName, Phone = NULLIF(LTRIM(RTRIM(@Phone)), ''), GSTIN = @GSTIN, PAN = @PAN, DefaultExpenseHeadId = @DefaultExpenseHeadId,
           Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''), IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE PayeeId = @PayeeId AND CompanyId = @CompanyId;
    IF @@ROWCOUNT = 0 THROW 53175, 'Payee not found.', 1;
    SELECT @PayeeId AS Id;
END
GO

-- ── 7. Petty cash ───────────────────────────────────────────────────────────
-- Float issue / replenishment (Dr counter, Cr cash or bank) and return (the other way). The cash in a counter never
-- goes above its fixed float.
CREATE OR ALTER PROCEDURE dbo.usp_Acc_PettyCash_Float
    @CounterId      INT,
    @Kind           VARCHAR(10),
    @TxnDate        DATE,
    @Amount         DECIMAL(18,2),
    @SourceLedgerId INT,
    @ReferenceNo    NVARCHAR(100) = NULL,
    @Remarks        NVARCHAR(300) = NULL,
    @UserId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @co INT, @br INT, @ledger INT, @float DECIMAL(18,2), @name NVARCHAR(100), @active BIT, @msg NVARCHAR(300);
    SELECT @co = CompanyId, @br = BranchId, @ledger = LedgerId, @float = FloatAmount, @name = CounterName, @active = IsActive
    FROM dbo.Acc_PettyCashCounter WHERE CounterId = @CounterId;
    IF @ledger IS NULL THROW 53100, 'Petty cash counter not found.', 1;
    IF @active = 0 AND @Kind <> 'RETURN' THROW 53101, 'This counter is inactive.', 1;
    IF @Kind NOT IN ('ISSUE', 'REPLENISH', 'RETURN') THROW 53102, 'Select float issue, replenishment or return.', 1;
    IF ISNULL(@Amount, 0) <= 0 THROW 53103, 'Enter an amount greater than zero.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerId = @SourceLedgerId AND IsActive = 1 AND LedgerType IN ('CASH', 'BANK'))
        THROW 53104, 'Select the cash or bank ledger the money comes from / goes to.', 1;
    EXEC dbo.usp_Acc_CheckEntryDate @CompanyId = @co, @BranchId = @br, @Date = @TxnDate;
    IF EXISTS (SELECT 1 FROM dbo.Acc_PettyCashClosing WHERE CounterId = @CounterId AND ClosingDate >= @TxnDate)
        THROW 53105, 'This counter is already closed for that date.', 1;

    DECLARE @bal DECIMAL(18,2) = dbo.fn_Acc_LedgerBalance(@ledger, NULL);
    IF @Kind = 'RETURN' AND @Amount > @bal
    BEGIN
        SET @msg = CONCAT('Only ', FORMAT(@bal, 'N2'), ' is in the counter.');
        THROW 53106, @msg, 1;
    END
    IF @Kind <> 'RETURN' AND @bal + @Amount > @float
    BEGIN
        SET @msg = CONCAT('The counter holds ', FORMAT(@bal, 'N2'), ' against a float of ', FORMAT(@float, 'N2'), ': at most ', FORMAT(@float - @bal, 'N2'), ' can be added.');
        THROW 53107, @msg, 1;
    END

    DECLARE @floatId INT, @tx BIGINT, @no NVARCHAR(50), @lines NVARCHAR(MAX), @narr NVARCHAR(500), @when DATETIME;
    SET @when = CASE WHEN @TxnDate = CAST(GETDATE() AS DATE) THEN GETDATE() ELSE CAST(@TxnDate AS DATETIME) END;
    SET @narr = CONCAT(CASE @Kind WHEN 'ISSUE' THEN 'Float issued to ' WHEN 'REPLENISH' THEN 'Replenishment of ' ELSE 'Cash returned from ' END, @name,
                       CASE WHEN NULLIF(LTRIM(RTRIM(@Remarks)), '') IS NULL THEN '' ELSE ' - ' + LTRIM(RTRIM(@Remarks)) END);
    SET @lines = CASE WHEN @Kind = 'RETURN'
        THEN CONCAT('[{"LedgerId":', @SourceLedgerId, ',"Dr":', @Amount, ',"Cr":0},{"LedgerId":', @ledger, ',"Dr":0,"Cr":', @Amount, '}]')
        ELSE CONCAT('[{"LedgerId":', @ledger, ',"Dr":', @Amount, ',"Cr":0},{"LedgerId":', @SourceLedgerId, ',"Dr":0,"Cr":', @Amount, '}]') END;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO dbo.Acc_PettyCashFloat (CounterId, Kind, TxnDate, Amount, SourceLedgerId, ReferenceNo, Remarks, CreatedBy)
        VALUES (@CounterId, @Kind, @TxnDate, @Amount, @SourceLedgerId, NULLIF(LTRIM(RTRIM(@ReferenceNo)), ''), NULLIF(LTRIM(RTRIM(@Remarks)), ''), @UserId);
        SET @floatId = SCOPE_IDENTITY();

        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'CTR', @TransactionDate = @when, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'PETTY_FLOAT',
             @ReferenceId = @floatId, @Narration = @narr, @InstrumentNo = @ReferenceNo, @LinesJson = @lines, @UserId = @UserId,
             @TransactionId = @tx OUTPUT, @VoucherNo = @no OUTPUT;
        UPDATE dbo.Acc_PettyCashFloat SET TransactionId = @tx, VoucherNo = @no WHERE FloatId = @floatId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    SELECT @floatId AS FloatId, @no AS VoucherNo;
END
GO

-- Posts an expense: Dr the ledger of each head (net of the GST claimed), Dr GST Input Credit (the GST claimed),
-- Cr the counter (what was paid). Called on approval (and on save when auto-approved).
CREATE OR ALTER PROCEDURE dbo.usp_Acc_PettyExpense_Post
    @ExpenseId INT,
    @UserId    INT,
    @IsAuto    BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @co INT, @br INT, @counter INT, @ledger INT, @total DECIMAL(18,2), @date DATE, @payee NVARCHAR(150), @narr NVARCHAR(500), @bill NVARCHAR(50),
            @overdraw BIT = 0, @msg NVARCHAR(300), @lines NVARCHAR(MAX), @tx BIGINT, @no NVARCHAR(50), @when DATETIME;
    SELECT @co = e.CompanyId, @br = e.BranchId, @counter = e.CounterId, @ledger = c.LedgerId, @total = e.TotalAmount, @date = e.ExpenseDate, @payee = e.PayeeName,
           @narr = e.Narration, @bill = e.BillNo
    FROM dbo.Acc_PettyExpense e JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = e.CounterId WHERE e.ExpenseId = @ExpenseId;
    SELECT @overdraw = AllowPettyOverdraw FROM dbo.Acc_Settings WHERE CompanyId = @co;

    IF EXISTS (SELECT 1 FROM dbo.Acc_PettyCashClosing WHERE CounterId = @counter AND ClosingDate >= @date)
        THROW 53110, 'The counter is already closed for the expense date. Reject it and enter it on an open date.', 1;
    DECLARE @bal DECIMAL(18,2) = dbo.fn_Acc_LedgerBalance(@ledger, NULL);
    IF @overdraw = 0 AND @total > @bal
    BEGIN
        SET @msg = CONCAT('The counter has only ', FORMAT(@bal, 'N2'), '. Replenish it before this expense of ', FORMAT(@total, 'N2'), ' is approved.');
        THROW 53111, @msg, 1;
    END

    DECLARE @gst DECIMAL(18,2) = ISNULL((SELECT SUM(GstAmount) FROM dbo.Acc_PettyExpenseLine WHERE ExpenseId = @ExpenseId), 0), @gstLedger INT;
    IF @gst > 0
    BEGIN
        SELECT @gstLedger = LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'GST_INPUT' AND IsActive = 1;
        IF @gstLedger IS NULL THROW 53112, 'Ledger GST Input Credit is missing or inactive.', 1;
    END

    SELECT @lines = (SELECT x.LedgerId, x.Dr, x.Cr, x.Narration FROM (
                        SELECT h.LedgerId, SUM(l.Amount - l.GstAmount) AS Dr, CAST(0 AS DECIMAL(18,2)) AS Cr, MAX(h.HeadName) AS Narration, 0 AS Ord
                        FROM dbo.Acc_PettyExpenseLine l JOIN dbo.Acc_ExpenseHead h ON h.ExpenseHeadId = l.ExpenseHeadId
                        WHERE l.ExpenseId = @ExpenseId GROUP BY h.LedgerId
                        UNION ALL
                        SELECT @gstLedger, @gst, 0, N'GST input credit', 1 WHERE @gst > 0
                        UNION ALL
                        SELECT @ledger, 0, @total, NULL, 2) x ORDER BY x.Ord FOR JSON PATH);
    SET @when = CASE WHEN @date = CAST(GETDATE() AS DATE) THEN GETDATE() ELSE CAST(@date AS DATETIME) END;
    SET @narr = CONCAT('Petty expense', CASE WHEN @payee IS NULL THEN '' ELSE ' paid to ' + @payee END, CASE WHEN @bill IS NULL THEN '' ELSE ', bill ' + @bill END,
                       CASE WHEN @narr IS NULL THEN '' ELSE ' - ' + @narr END);

    EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'PCV', @TransactionDate = @when, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'PETTY_EXP',
         @ReferenceId = @ExpenseId, @Narration = @narr, @PayeeName = @payee, @PaymentMode = N'Cash', @LinesJson = @lines, @UserId = @UserId,
         @TransactionId = @tx OUTPUT, @VoucherNo = @no OUTPUT;

    UPDATE dbo.Acc_PettyExpense SET Status = 'A', TransactionId = @tx, VoucherNo = @no, ApprovedBy = @UserId, ApprovedDate = GETDATE(), IsAutoApproved = @IsAuto,
           RejectedBy = NULL, RejectedDate = NULL, RejectReason = NULL
    WHERE ExpenseId = @ExpenseId;
END
GO

-- Save (new, or a Submitted / Rejected one being corrected).
-- @LinesJson = [{"ExpenseHeadId":1,"Amount":118,"GstAmount":18,"Remarks":"..."}]: Amount is what was paid (GST included);
-- GstAmount, the GST inside it, counts only when the company claims GST input credit on petty bills and needs a bill number.
-- At or below the company's auto-approve limit (or when approval is not required) it is approved and posted at once.
CREATE OR ALTER PROCEDURE dbo.usp_Acc_PettyExpense_Save
    @ExpenseId   INT,
    @CompanyId   INT,
    @CounterId   INT,
    @ExpenseDate DATE,
    @PayeeName   NVARCHAR(150) = NULL,
    @BillNo      NVARCHAR(50) = NULL,
    @BillDate    DATE = NULL,
    @Narration   NVARCHAR(500) = NULL,
    @LinesJson   NVARCHAR(MAX),
    @UserId      INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @br INT, @ledger INT, @active BIT, @msg NVARCHAR(300);
    SELECT @br = BranchId, @ledger = LedgerId, @active = IsActive FROM dbo.Acc_PettyCashCounter WHERE CounterId = @CounterId AND CompanyId = @CompanyId;
    IF @ledger IS NULL THROW 53120, 'Select the petty cash counter.', 1;
    IF @active = 0 THROW 53101, 'This counter is inactive.', 1;
    EXEC dbo.usp_Acc_CheckEntryDate @CompanyId = @CompanyId, @BranchId = @br, @Date = @ExpenseDate;
    IF EXISTS (SELECT 1 FROM dbo.Acc_PettyCashClosing WHERE CounterId = @CounterId AND ClosingDate >= @ExpenseDate)
        THROW 53105, 'This counter is already closed for that date.', 1;
    IF @BillDate IS NOT NULL AND @BillDate > @ExpenseDate THROW 53121, 'Bill date cannot be after the expense date.', 1;

    DECLARE @gstOn BIT = 0;
    SELECT @gstOn = PettyGstInputCredit FROM dbo.Acc_Settings WHERE CompanyId = @CompanyId;
    DECLARE @lines TABLE (ExpenseHeadId INT, Amount DECIMAL(18,2), GstAmount DECIMAL(18,2), Remarks NVARCHAR(200));
    INSERT INTO @lines
    SELECT ExpenseHeadId, Amount, CASE WHEN @gstOn = 1 THEN ISNULL(GstAmount, 0) ELSE 0 END, NULLIF(LTRIM(RTRIM(Remarks)), '')
    FROM OPENJSON(@LinesJson) WITH (ExpenseHeadId INT '$.ExpenseHeadId', Amount DECIMAL(18,2) '$.Amount', GstAmount DECIMAL(18,2) '$.GstAmount', Remarks NVARCHAR(200) '$.Remarks');
    IF NOT EXISTS (SELECT 1 FROM @lines) THROW 53122, 'Add at least one expense head with an amount.', 1;
    IF EXISTS (SELECT 1 FROM @lines WHERE ISNULL(Amount, 0) <= 0) THROW 53123, 'Every expense line needs an amount greater than zero.', 1;
    IF EXISTS (SELECT 1 FROM @lines WHERE GstAmount < 0 OR GstAmount >= Amount) THROW 53118, 'GST on a line must be less than the amount paid (the amount includes the GST).', 1;
    IF EXISTS (SELECT 1 FROM @lines WHERE GstAmount > 0) AND NULLIF(LTRIM(RTRIM(@BillNo)), '') IS NULL
        THROW 53119, 'Bill number is required to claim GST input credit.', 1;
    IF EXISTS (SELECT 1 FROM @lines x LEFT JOIN dbo.Acc_ExpenseHead h ON h.ExpenseHeadId = x.ExpenseHeadId AND h.CompanyId = @CompanyId AND h.IsActive = 1 WHERE h.ExpenseHeadId IS NULL)
        THROW 53124, 'An expense head on the voucher is missing or inactive.', 1;

    DECLARE @total DECIMAL(18,2) = (SELECT SUM(Amount) FROM @lines);
    DECLARE @apprReq BIT = 1, @auto DECIMAL(18,2) = 0, @max DECIMAL(18,2) = 5000, @overdraw BIT = 0;
    SELECT @apprReq = PettyApprovalRequired, @auto = PettyAutoApproveLimit, @max = PettyMaxPerVoucher, @overdraw = AllowPettyOverdraw FROM dbo.Acc_Settings WHERE CompanyId = @CompanyId;
    IF @total > @max
    BEGIN
        SET @msg = CONCAT('A petty voucher can be at most ', FORMAT(@max, 'N2'), '. Use a Payment voucher for a larger amount.');
        THROW 53125, @msg, 1;
    END

    DECLARE @head NVARCHAR(100), @limit DECIMAL(18,2);
    SELECT TOP 1 @head = h.HeadName, @limit = h.MaxPerVoucher
    FROM (SELECT ExpenseHeadId, SUM(Amount) AS Amount FROM @lines GROUP BY ExpenseHeadId) x JOIN dbo.Acc_ExpenseHead h ON h.ExpenseHeadId = x.ExpenseHeadId
    WHERE h.MaxPerVoucher IS NOT NULL AND x.Amount > h.MaxPerVoucher;
    IF @head IS NOT NULL
    BEGIN
        SET @msg = CONCAT(@head, ' is limited to ', FORMAT(@limit, 'N2'), ' per voucher.');
        THROW 53126, @msg, 1;
    END
    SET @head = NULL;
    SELECT TOP 1 @head = h.HeadName, @limit = h.BillRequiredAbove
    FROM (SELECT ExpenseHeadId, SUM(Amount) AS Amount FROM @lines GROUP BY ExpenseHeadId) x JOIN dbo.Acc_ExpenseHead h ON h.ExpenseHeadId = x.ExpenseHeadId
    WHERE h.BillRequiredAbove IS NOT NULL AND x.Amount > h.BillRequiredAbove;
    IF @head IS NOT NULL AND NULLIF(LTRIM(RTRIM(@BillNo)), '') IS NULL
    BEGIN
        SET @msg = CONCAT('Bill number is required for ', @head, ' above ', FORMAT(@limit, 'N2'), '.');
        THROW 53127, @msg, 1;
    END

    -- money in the counter not yet promised to another waiting expense
    DECLARE @available DECIMAL(18,2) = dbo.fn_Acc_LedgerBalance(@ledger, NULL)
        - ISNULL((SELECT SUM(TotalAmount) FROM dbo.Acc_PettyExpense WHERE CounterId = @CounterId AND Status = 'S' AND ExpenseId <> ISNULL(@ExpenseId, 0)), 0);
    IF @overdraw = 0 AND @total > @available
    BEGIN
        SET @msg = CONCAT('Only ', FORMAT(@available, 'N2'), ' is available in this counter. Ask for a replenishment.');
        THROW 53128, @msg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;
        IF ISNULL(@ExpenseId, 0) = 0
        BEGIN
            INSERT INTO dbo.Acc_PettyExpense (CompanyId, BranchId, CounterId, ExpenseDate, PayeeName, BillNo, BillDate, TotalAmount, Narration, Status, CreatedBy)
            VALUES (@CompanyId, @br, @CounterId, @ExpenseDate, NULLIF(LTRIM(RTRIM(@PayeeName)), ''), NULLIF(LTRIM(RTRIM(@BillNo)), ''), @BillDate, @total,
                    NULLIF(LTRIM(RTRIM(@Narration)), ''), 'S', @UserId);
            SET @ExpenseId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.Acc_PettyExpense WHERE ExpenseId = @ExpenseId AND CompanyId = @CompanyId AND Status IN ('S', 'R'))
                THROW 53129, 'Only an expense waiting for approval or a rejected one can be changed.', 1;
            UPDATE dbo.Acc_PettyExpense SET BranchId = @br, CounterId = @CounterId, ExpenseDate = @ExpenseDate, PayeeName = NULLIF(LTRIM(RTRIM(@PayeeName)), ''),
                   BillNo = NULLIF(LTRIM(RTRIM(@BillNo)), ''), BillDate = @BillDate, TotalAmount = @total, Narration = NULLIF(LTRIM(RTRIM(@Narration)), ''),
                   Status = 'S', ModifiedBy = @UserId, ModifiedDate = GETDATE()
            WHERE ExpenseId = @ExpenseId;
            DELETE FROM dbo.Acc_PettyExpenseLine WHERE ExpenseId = @ExpenseId;
        END
        INSERT INTO dbo.Acc_PettyExpenseLine (ExpenseId, ExpenseHeadId, Amount, GstAmount, Remarks) SELECT @ExpenseId, ExpenseHeadId, Amount, GstAmount, Remarks FROM @lines;

        IF @apprReq = 0 OR @total <= @auto
            EXEC dbo.usp_Acc_PettyExpense_Post @ExpenseId = @ExpenseId, @UserId = @UserId, @IsAuto = 1;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT ExpenseId, Status, VoucherNo FROM dbo.Acc_PettyExpense WHERE ExpenseId = @ExpenseId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Acc_PettyExpense_Approve
    @ExpenseId INT,
    @CompanyId INT,
    @UserId    INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @status CHAR(1), @by INT, @self BIT = 0;
    SELECT @status = Status, @by = CreatedBy FROM dbo.Acc_PettyExpense WHERE ExpenseId = @ExpenseId AND CompanyId = @CompanyId;
    SELECT @self = AllowSelfApproval FROM dbo.Acc_Settings WHERE CompanyId = @CompanyId;
    IF @status IS NULL THROW 53130, 'Expense not found.', 1;
    IF @status <> 'S' THROW 53131, 'Only an expense waiting for approval can be approved.', 1;
    IF @self = 0 AND @by = @UserId THROW 53132, 'You cannot approve an expense you entered yourself.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC dbo.usp_Acc_PettyExpense_Post @ExpenseId = @ExpenseId, @UserId = @UserId, @IsAuto = 0;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    SELECT ExpenseId, Status, VoucherNo FROM dbo.Acc_PettyExpense WHERE ExpenseId = @ExpenseId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Acc_PettyExpense_Reject
    @ExpenseId INT,
    @CompanyId INT,
    @Reason    NVARCHAR(300),
    @UserId    INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(RTRIM(@Reason)), '') IS NULL THROW 53133, 'Enter the reason for rejection.', 1;
    UPDATE dbo.Acc_PettyExpense SET Status = 'R', RejectedBy = @UserId, RejectedDate = GETDATE(), RejectReason = LTRIM(RTRIM(@Reason))
    WHERE ExpenseId = @ExpenseId AND CompanyId = @CompanyId AND Status = 'S';
    IF @@ROWCOUNT = 0 THROW 53131, 'Only an expense waiting for approval can be rejected.', 1;
END
GO

-- Cancel: a waiting / rejected expense is simply closed; an approved one is reversed in the ledger.
CREATE OR ALTER PROCEDURE dbo.usp_Acc_PettyExpense_Cancel
    @ExpenseId INT,
    @CompanyId INT,
    @Reason    NVARCHAR(300),
    @UserId    INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @status CHAR(1), @tx BIGINT, @counter INT, @date DATE;
    SELECT @status = Status, @tx = TransactionId, @counter = CounterId, @date = ExpenseDate FROM dbo.Acc_PettyExpense WHERE ExpenseId = @ExpenseId AND CompanyId = @CompanyId;
    IF @status IS NULL THROW 53130, 'Expense not found.', 1;
    IF @status = 'C' THROW 53134, 'This expense is already cancelled.', 1;
    IF NULLIF(LTRIM(RTRIM(@Reason)), '') IS NULL THROW 53023, 'Enter the reason for cancellation.', 1;
    -- the reversal brings cash back into the counter today: not after today's closing
    IF @status = 'A' AND EXISTS (SELECT 1 FROM dbo.Acc_PettyCashClosing WHERE CounterId = @counter AND ClosingDate >= CAST(GETDATE() AS DATE))
        THROW 53135, 'The counter is already closed for today. Cancel this expense on the next working day.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        IF @status = 'A' AND @tx IS NOT NULL
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @tx, @Reason = @Reason, @UserId = @UserId;
        UPDATE dbo.Acc_PettyExpense SET Status = 'C', CancelledBy = @UserId, CancelledDate = GETDATE(), CancelReason = LTRIM(RTRIM(@Reason)) WHERE ExpenseId = @ExpenseId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Daily closing: the counted cash against the book balance at the end of the day. A difference is posted to
-- Petty Cash Shortage / Excess so the ledger equals the cash in the box. After it, the day takes no more entries.
CREATE OR ALTER PROCEDURE dbo.usp_Acc_PettyCash_Close
    @CounterId        INT,
    @ClosingDate      DATE,
    @CountedCash      DECIMAL(18,2),
    @DenominationJson NVARCHAR(1000) = NULL,
    @Remarks          NVARCHAR(300) = NULL,
    @UserId           INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @co INT, @br INT, @ledger INT, @name NVARCHAR(100), @lock DATE, @msg NVARCHAR(300);
    SELECT @co = CompanyId, @br = BranchId, @ledger = LedgerId, @name = CounterName FROM dbo.Acc_PettyCashCounter WHERE CounterId = @CounterId;
    IF @ledger IS NULL THROW 53100, 'Petty cash counter not found.', 1;
    IF @ClosingDate IS NULL OR @ClosingDate > CAST(GETDATE() AS DATE) THROW 53140, 'Closing date cannot be in the future.', 1;
    IF ISNULL(@CountedCash, -1) < 0 THROW 53141, 'Enter the cash counted.', 1;
    SELECT @lock = LockedUpTo FROM dbo.Acc_BranchLock WHERE CompanyId = @co AND BranchId = @br;
    IF @lock IS NOT NULL AND @ClosingDate <= @lock THROW 53142, 'The books of this branch are locked for that date.', 1;
    IF EXISTS (SELECT 1 FROM dbo.Acc_PettyCashClosing WHERE CounterId = @CounterId AND ClosingDate >= @ClosingDate)
        THROW 53143, 'This counter is already closed for that date (or a later one).', 1;
    IF EXISTS (SELECT 1 FROM dbo.Acc_PettyExpense WHERE CounterId = @CounterId AND Status = 'S' AND ExpenseDate <= @ClosingDate)
        THROW 53144, 'Expenses of this counter are still waiting for approval. Approve or reject them before closing.', 1;

    DECLARE @book DECIMAL(18,2) = dbo.fn_Acc_LedgerBalance(@ledger, @ClosingDate);
    DECLARE @diff DECIMAL(18,2) = @CountedCash - @book, @tx BIGINT, @no NVARCHAR(50), @lines NVARCHAR(MAX), @other INT, @narr NVARCHAR(500), @closingId INT, @abs DECIMAL(18,2);
    IF @diff <> 0 AND NULLIF(LTRIM(RTRIM(@Remarks)), '') IS NULL THROW 53145, 'Counted cash differs from the book balance: enter a remark explaining the difference.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO dbo.Acc_PettyCashClosing (CounterId, ClosingDate, BookBalance, CountedCash, Difference, DenominationJson, Remarks, CreatedBy)
        VALUES (@CounterId, @ClosingDate, @book, @CountedCash, @diff, @DenominationJson, NULLIF(LTRIM(RTRIM(@Remarks)), ''), @UserId);
        SET @closingId = SCOPE_IDENTITY();

        IF @diff <> 0
        BEGIN
            SET @abs = ABS(@diff);
            SELECT @other = LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = CASE WHEN @diff < 0 THEN 'PETTY_SHORTAGE' ELSE 'PETTY_EXCESS' END;
            IF @other IS NULL THROW 53146, 'Ledger Petty Cash Shortage / Excess is missing.', 1;
            SET @lines = CASE WHEN @diff < 0
                THEN CONCAT('[{"LedgerId":', @other, ',"Dr":', @abs, ',"Cr":0},{"LedgerId":', @ledger, ',"Dr":0,"Cr":', @abs, '}]')
                ELSE CONCAT('[{"LedgerId":', @ledger, ',"Dr":', @abs, ',"Cr":0},{"LedgerId":', @other, ',"Dr":0,"Cr":', @abs, '}]') END;
            SET @narr = CONCAT(CASE WHEN @diff < 0 THEN 'Cash shortage' ELSE 'Cash excess' END, ' at closing of ', @name, ' on ', FORMAT(@ClosingDate, 'dd-MMM-yyyy'), ' - ', LTRIM(RTRIM(@Remarks)));
            DECLARE @when DATETIME = DATEADD(SECOND, -1, DATEADD(DAY, 1, CAST(@ClosingDate AS DATETIME)));   -- last second of the closing day
            EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'JRN', @TransactionDate = @when, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'PETTY_CLOSE',
                 @ReferenceId = @closingId, @Narration = @narr, @LinesJson = @lines, @UserId = @UserId, @TransactionId = @tx OUTPUT, @VoucherNo = @no OUTPUT;
            UPDATE dbo.Acc_PettyCashClosing SET TransactionId = @tx WHERE ClosingId = @closingId;
        END
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    SELECT @closingId AS ClosingId, @book AS BookBalance, @diff AS Difference;
END
GO

-- ── 8. Manual vouchers (Payment / Receipt / Contra / Journal) ───────────────
CREATE OR ALTER PROCEDURE dbo.usp_Acc_Voucher_Post
    @VoucherId INT,
    @UserId    INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @code VARCHAR(10), @co INT, @br INT, @date DATE, @payee NVARCHAR(150), @mode NVARCHAR(50), @instNo NVARCHAR(100), @instDate DATE, @narr NVARCHAR(500),
            @lines NVARCHAR(MAX), @tx BIGINT, @no NVARCHAR(50), @when DATETIME;
    SELECT @code = t.VoucherTypeCode, @co = v.CompanyId, @br = v.BranchId, @date = v.VoucherDate, @payee = v.PayeeName, @mode = v.PaymentMode, @instNo = v.InstrumentNo,
           @instDate = v.InstrumentDate, @narr = v.Narration
    FROM dbo.Acc_Voucher v JOIN dbo.Acc_VoucherType t ON t.VoucherTypeId = v.VoucherTypeId WHERE v.VoucherId = @VoucherId;
    SELECT @lines = (SELECT LedgerId, DebitAmount AS Dr, CreditAmount AS Cr, Narration FROM dbo.Acc_VoucherLine WHERE VoucherId = @VoucherId ORDER BY LineId FOR JSON PATH);
    SET @when = CASE WHEN @date = CAST(GETDATE() AS DATE) THEN GETDATE() ELSE CAST(@date AS DATETIME) END;

    EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = @code, @TransactionDate = @when, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'MANUAL_VCH',
         @ReferenceId = @VoucherId, @Narration = @narr, @PayeeName = @payee, @PaymentMode = @mode, @InstrumentNo = @instNo, @InstrumentDate = @instDate,
         @LinesJson = @lines, @IsManual = 1, @UserId = @UserId, @TransactionId = @tx OUTPUT, @VoucherNo = @no OUTPUT;
    UPDATE dbo.Acc_Voucher SET Status = 'A', TransactionId = @tx, VoucherNo = @no, ApprovedBy = @UserId, ApprovedDate = GETDATE() WHERE VoucherId = @VoucherId;
END
GO

-- @LinesJson = [{"LedgerId":1,"Dr":100,"Cr":0,"Narration":"..."}]. Rules by type:
--   Payment: money leaves a cash / bank ledger (a credit line on one). Receipt: money comes into one (a debit line).
--   Contra: only cash / bank / petty cash ledgers. Journal: none of them. Petty cash ledgers move only by the
--   Petty Cash screens, except in a Contra.
CREATE OR ALTER PROCEDURE dbo.usp_Acc_Voucher_Save
    @CompanyId       INT,
    @BranchId        INT,
    @VoucherTypeCode VARCHAR(10),
    @VoucherDate     DATE,
    @PayeeName       NVARCHAR(150) = NULL,
    @PaymentMode     NVARCHAR(50) = NULL,
    @InstrumentNo    NVARCHAR(100) = NULL,
    @InstrumentDate  DATE = NULL,
    @Narration       NVARCHAR(500) = NULL,
    @LinesJson       NVARCHAR(MAX),
    @UserId          INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @typeId INT, @msg NVARCHAR(300);
    SELECT @typeId = VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeCode = @VoucherTypeCode AND IsManual = 1 AND IsActive = 1;
    IF @typeId IS NULL THROW 53150, 'Select Payment, Receipt, Contra or Journal.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND IsActive = 1) THROW 53073, 'Select an active branch.', 1;
    EXEC dbo.usp_Acc_CheckEntryDate @CompanyId = @CompanyId, @BranchId = @BranchId, @Date = @VoucherDate;
    IF NULLIF(LTRIM(RTRIM(@Narration)), '') IS NULL THROW 53151, 'Enter the narration.', 1;

    DECLARE @lines TABLE (LedgerId INT, Dr DECIMAL(18,2), Cr DECIMAL(18,2), Narration NVARCHAR(300), LedgerType VARCHAR(10));
    INSERT INTO @lines
    SELECT x.LedgerId, ISNULL(x.Dr, 0), ISNULL(x.Cr, 0), NULLIF(LTRIM(RTRIM(x.Narration)), ''), l.LedgerType
    FROM OPENJSON(@LinesJson) WITH (LedgerId INT '$.LedgerId', Dr DECIMAL(18,2) '$.Dr', Cr DECIMAL(18,2) '$.Cr', Narration NVARCHAR(300) '$.Narration') x
    LEFT JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = x.LedgerId AND l.IsActive = 1;

    IF (SELECT COUNT(*) FROM @lines) < 2 THROW 53012, 'A voucher needs at least one debit and one credit line.', 1;
    IF EXISTS (SELECT 1 FROM @lines WHERE LedgerType IS NULL) THROW 53015, 'A ledger on the voucher is missing or inactive.', 1;
    IF EXISTS (SELECT 1 FROM @lines WHERE Dr < 0 OR Cr < 0 OR (Dr = 0 AND Cr = 0) OR (Dr > 0 AND Cr > 0))
        THROW 53013, 'Every line needs either a debit or a credit amount greater than zero.', 1;
    DECLARE @dr DECIMAL(18,2), @cr DECIMAL(18,2);
    SELECT @dr = SUM(Dr), @cr = SUM(Cr) FROM @lines;
    IF @dr <> @cr
    BEGIN
        SET @msg = CONCAT('The voucher does not balance: debit ', FORMAT(@dr, 'N2'), ', credit ', FORMAT(@cr, 'N2'), '.');
        THROW 53014, @msg, 1;
    END

    IF @VoucherTypeCode = 'PMT' AND NOT EXISTS (SELECT 1 FROM @lines WHERE LedgerType IN ('CASH', 'BANK') AND Cr > 0)
        THROW 53152, 'A Payment voucher must credit a cash or bank ledger.', 1;
    IF @VoucherTypeCode = 'RCT' AND NOT EXISTS (SELECT 1 FROM @lines WHERE LedgerType IN ('CASH', 'BANK') AND Dr > 0)
        THROW 53153, 'A Receipt voucher must debit a cash or bank ledger.', 1;
    IF @VoucherTypeCode = 'CTR' AND EXISTS (SELECT 1 FROM @lines WHERE LedgerType NOT IN ('CASH', 'BANK', 'PETTY'))
        THROW 53154, 'A Contra voucher moves money only between cash, bank and petty cash ledgers.', 1;
    IF @VoucherTypeCode = 'JRN' AND EXISTS (SELECT 1 FROM @lines WHERE LedgerType IN ('CASH', 'BANK', 'PETTY'))
        THROW 53155, 'A Journal voucher cannot use a cash, bank or petty cash ledger. Use Payment, Receipt or Contra.', 1;
    IF @VoucherTypeCode IN ('PMT', 'RCT', 'CTR') AND EXISTS (SELECT 1 FROM @lines WHERE LedgerType = 'PETTY')
        THROW 53156, 'Petty cash moves through Petty Cash > Float and Petty Expense, where the counter limits are checked.', 1;

    DECLARE @apprReq BIT = 0, @voucherId INT;
    SELECT @apprReq = VoucherApprovalRequired FROM dbo.Acc_Settings WHERE CompanyId = @CompanyId;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO dbo.Acc_Voucher (CompanyId, BranchId, VoucherTypeId, VoucherDate, PayeeName, PaymentMode, InstrumentNo, InstrumentDate, Narration, TotalAmount, Status, CreatedBy)
        VALUES (@CompanyId, @BranchId, @typeId, @VoucherDate, NULLIF(LTRIM(RTRIM(@PayeeName)), ''), NULLIF(LTRIM(RTRIM(@PaymentMode)), ''),
                NULLIF(LTRIM(RTRIM(@InstrumentNo)), ''), @InstrumentDate, LTRIM(RTRIM(@Narration)), @dr, 'S', @UserId);
        SET @voucherId = SCOPE_IDENTITY();
        INSERT INTO dbo.Acc_VoucherLine (VoucherId, LedgerId, DebitAmount, CreditAmount, Narration) SELECT @voucherId, LedgerId, Dr, Cr, Narration FROM @lines;

        IF @apprReq = 0 EXEC dbo.usp_Acc_Voucher_Post @VoucherId = @voucherId, @UserId = @UserId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    SELECT VoucherId, Status, VoucherNo FROM dbo.Acc_Voucher WHERE VoucherId = @voucherId;
END
GO

-- @Action: APPROVE (posts), REJECT, CANCEL (a posted voucher is reversed).
CREATE OR ALTER PROCEDURE dbo.usp_Acc_Voucher_Action
    @VoucherId INT,
    @CompanyId INT,
    @Action    VARCHAR(10),
    @Reason    NVARCHAR(300) = NULL,
    @UserId    INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @status CHAR(1), @by INT, @tx BIGINT, @self BIT = 0;
    SELECT @status = Status, @by = CreatedBy, @tx = TransactionId FROM dbo.Acc_Voucher WHERE VoucherId = @VoucherId AND CompanyId = @CompanyId;
    SELECT @self = AllowSelfApproval FROM dbo.Acc_Settings WHERE CompanyId = @CompanyId;
    IF @status IS NULL THROW 53160, 'Voucher not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        IF @Action = 'APPROVE'
        BEGIN
            IF @status <> 'S' THROW 53161, 'Only a voucher waiting for approval can be approved.', 1;
            IF @self = 0 AND @by = @UserId THROW 53162, 'You cannot approve a voucher you entered yourself.', 1;
            EXEC dbo.usp_Acc_Voucher_Post @VoucherId = @VoucherId, @UserId = @UserId;
        END
        ELSE IF @Action = 'REJECT'
        BEGIN
            IF @status <> 'S' THROW 53161, 'Only a voucher waiting for approval can be rejected.', 1;
            IF NULLIF(LTRIM(RTRIM(@Reason)), '') IS NULL THROW 53133, 'Enter the reason for rejection.', 1;
            UPDATE dbo.Acc_Voucher SET Status = 'R', RejectedBy = @UserId, RejectedDate = GETDATE(), RejectReason = LTRIM(RTRIM(@Reason)) WHERE VoucherId = @VoucherId;
        END
        ELSE IF @Action = 'CANCEL'
        BEGIN
            IF @status IN ('C', 'R') THROW 53163, 'This voucher is already cancelled or rejected.', 1;
            IF NULLIF(LTRIM(RTRIM(@Reason)), '') IS NULL THROW 53023, 'Enter the reason for cancellation.', 1;
            IF @status = 'A' AND @tx IS NOT NULL EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @tx, @Reason = @Reason, @UserId = @UserId;
            UPDATE dbo.Acc_Voucher SET Status = 'C', CancelledBy = @UserId, CancelledDate = GETDATE(), CancelReason = LTRIM(RTRIM(@Reason)) WHERE VoucherId = @VoucherId;
        END
        ELSE THROW 53164, 'Unknown action.', 1;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

PRINT 'Script 2244 applied: Accounts foundation, petty cash and manual vouchers (tables, posting, masters, starter kit).';
GO
