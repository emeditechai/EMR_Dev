USE [Dev_EMR];
GO

-- 1. Acc_LedgerGroup
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[Acc_LedgerGroup]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[Acc_LedgerGroup](
        [LedgerGroupId] INT IDENTITY(1,1) NOT NULL,
        [GroupName] NVARCHAR(100) NOT NULL,
        [ParentGroupId] INT NULL,
        [GroupType] NVARCHAR(50) NOT NULL, -- Asset, Liability, Income, Expense
        [IsActive] BIT NOT NULL DEFAULT 1,
        [CreatedBy] INT NULL,
        [CreatedDate] DATETIME NOT NULL DEFAULT GETDATE(),
        CONSTRAINT [PK_Acc_LedgerGroup] PRIMARY KEY CLUSTERED ([LedgerGroupId] ASC)
    );
END
GO

-- 2. Acc_LedgerMaster
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[Acc_LedgerMaster]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[Acc_LedgerMaster](
        [LedgerId] INT IDENTITY(1,1) NOT NULL,
        [LedgerName] NVARCHAR(100) NOT NULL,
        [LedgerGroupId] INT NOT NULL,
        [OpeningBalance] DECIMAL(18,2) NOT NULL DEFAULT 0,
        [OpeningBalanceType] NVARCHAR(2) NOT NULL DEFAULT 'Dr', -- Dr or Cr
        [IsActive] BIT NOT NULL DEFAULT 1,
        [CreatedBy] INT NULL,
        [CreatedDate] DATETIME NOT NULL DEFAULT GETDATE(),
        CONSTRAINT [PK_Acc_LedgerMaster] PRIMARY KEY CLUSTERED ([LedgerId] ASC),
        CONSTRAINT [FK_Acc_LedgerMaster_Group] FOREIGN KEY([LedgerGroupId]) REFERENCES [dbo].[Acc_LedgerGroup] ([LedgerGroupId])
    );
END
GO

-- 3. Acc_VoucherType
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[Acc_VoucherType]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[Acc_VoucherType](
        [VoucherTypeId] INT IDENTITY(1,1) NOT NULL,
        [VoucherTypeName] NVARCHAR(50) NOT NULL,
        [Prefix] NVARCHAR(10) NULL,
        [IsActive] BIT NOT NULL DEFAULT 1,
        CONSTRAINT [PK_Acc_VoucherType] PRIMARY KEY CLUSTERED ([VoucherTypeId] ASC)
    );
END
GO

-- 4. Acc_LedgerTransaction
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[Acc_LedgerTransaction]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[Acc_LedgerTransaction](
        [TransactionId] BIGINT IDENTITY(1,1) NOT NULL,
        [VoucherTypeId] INT NOT NULL,
        [VoucherNo] NVARCHAR(50) NULL,
        [TransactionDate] DATETIME NOT NULL,
        [ReferenceType] NVARCHAR(50) NULL, -- e.g., 'OPD_BILL'
        [ReferenceId] INT NULL,            -- e.g., OPDServiceId
        [BranchId] INT NULL,
        [CompanyId] INT NULL,
        [TotalAmount] DECIMAL(18,2) NOT NULL,
        [Narration] NVARCHAR(MAX) NULL,
        [IsActive] BIT NOT NULL DEFAULT 1,
        [CreatedBy] INT NULL,
        [CreatedDate] DATETIME NOT NULL DEFAULT GETDATE(),
        CONSTRAINT [PK_Acc_LedgerTransaction] PRIMARY KEY CLUSTERED ([TransactionId] ASC),
        CONSTRAINT [FK_Acc_LedgerTransaction_Voucher] FOREIGN KEY([VoucherTypeId]) REFERENCES [dbo].[Acc_VoucherType] ([VoucherTypeId])
    );
END
GO

-- 5. Acc_LedgerTransactionDetail
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[Acc_LedgerTransactionDetail]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[Acc_LedgerTransactionDetail](
        [TransactionDetailId] BIGINT IDENTITY(1,1) NOT NULL,
        [TransactionId] BIGINT NOT NULL,
        [LedgerId] INT NOT NULL,
        [DebitAmount] DECIMAL(18,2) NOT NULL DEFAULT 0,
        [CreditAmount] DECIMAL(18,2) NOT NULL DEFAULT 0,
        [Narration] NVARCHAR(MAX) NULL,
        CONSTRAINT [PK_Acc_LedgerTransactionDetail] PRIMARY KEY CLUSTERED ([TransactionDetailId] ASC),
        CONSTRAINT [FK_Acc_LedgerTransactionDetail_Trans] FOREIGN KEY([TransactionId]) REFERENCES [dbo].[Acc_LedgerTransaction] ([TransactionId]),
        CONSTRAINT [FK_Acc_LedgerTransactionDetail_Ledger] FOREIGN KEY([LedgerId]) REFERENCES [dbo].[Acc_LedgerMaster] ([LedgerId])
    );
END
GO

-- 6. SP for Posting Entry
CREATE OR ALTER PROCEDURE [dbo].[usp_Ledger_PostEntry]
    @VoucherTypeId INT,
    @TransactionDate DATETIME,
    @ReferenceType NVARCHAR(50),
    @ReferenceId INT,
    @BranchId INT,
    @CompanyId INT,
    @TotalAmount DECIMAL(18,2),
    @Narration NVARCHAR(MAX),
    @DebitLedgerId INT,
    @CreditLedgerId INT,
    @CreatedBy INT,
    @NewTransactionId BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate Voucher No (Simplified version)
        DECLARE @VoucherNo NVARCHAR(50) = 'VCH-' + FORMAT(GETDATE(), 'yyyyMMddHHmmss');

        -- Insert Header
        INSERT INTO [dbo].[Acc_LedgerTransaction] 
            (VoucherTypeId, VoucherNo, TransactionDate, ReferenceType, ReferenceId, BranchId, CompanyId, TotalAmount, Narration, CreatedBy, CreatedDate)
        VALUES 
            (@VoucherTypeId, @VoucherNo, @TransactionDate, @ReferenceType, @ReferenceId, @BranchId, @CompanyId, @TotalAmount, @Narration, @CreatedBy, GETDATE());
        
        SET @NewTransactionId = SCOPE_IDENTITY();

        -- Insert Debit Line
        INSERT INTO [dbo].[Acc_LedgerTransactionDetail] (TransactionId, LedgerId, DebitAmount, CreditAmount, Narration)
        VALUES (@NewTransactionId, @DebitLedgerId, @TotalAmount, 0, @Narration);

        -- Insert Credit Line
        INSERT INTO [dbo].[Acc_LedgerTransactionDetail] (TransactionId, LedgerId, DebitAmount, CreditAmount, Narration)
        VALUES (@NewTransactionId, @CreditLedgerId, 0, @TotalAmount, @Narration);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- 7. Seed Data
-- Groups
IF NOT EXISTS (SELECT 1 FROM [dbo].[Acc_LedgerGroup] WHERE GroupName = 'Current Assets')
    INSERT INTO [dbo].[Acc_LedgerGroup] (GroupName, GroupType) VALUES ('Current Assets', 'Asset');
IF NOT EXISTS (SELECT 1 FROM [dbo].[Acc_LedgerGroup] WHERE GroupName = 'Direct Income')
    INSERT INTO [dbo].[Acc_LedgerGroup] (GroupName, GroupType) VALUES ('Direct Income', 'Income');
IF NOT EXISTS (SELECT 1 FROM [dbo].[Acc_LedgerGroup] WHERE GroupName = 'Cash In Hand')
    INSERT INTO [dbo].[Acc_LedgerGroup] (GroupName, GroupType) VALUES ('Cash In Hand', 'Asset');

-- Ledgers
DECLARE @AssetGroupId INT = (SELECT LedgerGroupId FROM [dbo].[Acc_LedgerGroup] WHERE GroupName = 'Current Assets');
DECLARE @IncomeGroupId INT = (SELECT LedgerGroupId FROM [dbo].[Acc_LedgerGroup] WHERE GroupName = 'Direct Income');
DECLARE @CashGroupId INT = (SELECT LedgerGroupId FROM [dbo].[Acc_LedgerGroup] WHERE GroupName = 'Cash In Hand');

IF NOT EXISTS (SELECT 1 FROM [dbo].[Acc_LedgerMaster] WHERE LedgerName = 'Patient Receivable')
    INSERT INTO [dbo].[Acc_LedgerMaster] (LedgerName, LedgerGroupId) VALUES ('Patient Receivable', @AssetGroupId);
IF NOT EXISTS (SELECT 1 FROM [dbo].[Acc_LedgerMaster] WHERE LedgerName = 'OPD Revenue')
    INSERT INTO [dbo].[Acc_LedgerMaster] (LedgerName, LedgerGroupId) VALUES ('OPD Revenue', @IncomeGroupId);
IF NOT EXISTS (SELECT 1 FROM [dbo].[Acc_LedgerMaster] WHERE LedgerName = 'Cash Account')
    INSERT INTO [dbo].[Acc_LedgerMaster] (LedgerName, LedgerGroupId) VALUES ('Cash Account', @CashGroupId);

-- Voucher Types
IF NOT EXISTS (SELECT 1 FROM [dbo].[Acc_VoucherType] WHERE VoucherTypeName = 'Sales')
    INSERT INTO [dbo].[Acc_VoucherType] (VoucherTypeName, Prefix) VALUES ('Sales', 'SLS');
IF NOT EXISTS (SELECT 1 FROM [dbo].[Acc_VoucherType] WHERE VoucherTypeName = 'Receipt')
    INSERT INTO [dbo].[Acc_VoucherType] (VoucherTypeName, Prefix) VALUES ('Receipt', 'RCT');
GO
