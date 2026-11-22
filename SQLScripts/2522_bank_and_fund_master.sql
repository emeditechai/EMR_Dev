-- ============================================================================================================
-- Migration: 2522_bank_and_fund_master.sql   (application database)
-- 1. Master > General > Bank Master: the company's own bank accounts (add, edit, view, activate / deactivate).
-- dbo.BankMaster already exists (read by the B2B invoice letterhead: the primary active account); its columns are kept
-- and the standard ones are added. Web -> EMR.Api api/banks -> these procedures. Funds (2523) pick their account here.
--   Rules (server side): bank name, account holder, account number (6-20 digits, unique per company with the IFSC),
--   account type (SAVINGS / CURRENT / OD / CC), IFSC (AAAA0XXXXXX), optional MICR (9 digits), SWIFT (8 / 11), UPI
--   (name@bank), e-mail and 10-digit phone; one primary account per company (marking one clears the others); an account
--   used by an active fund cannot be deactivated.
--   usp_Api_Bank_List / _Get / _Save / _SetStatus / _Options
--   Page MASTER.BANKS (Master > General): VIEW, ADD, EDIT, STATUS. No role is granted.
-- 2. Utility > Accounts > Fund Master: the funds the hospital pays from (the payout mechanism uses them later) - type
--   WALLET or BANK (a bank fund is one Bank Master account, one fund per account), opening balance, top-ups and the full
--   history with the running balance (dbo.Fund, dbo.FundTransaction: OPENING / TOPUP; later PAYOUT ...).
--   Rules: unique fund code per company; opening balance >= 0, changeable only while the fund has no other movement;
--   top-up > 0, not in the future, mode CASH / BANK TRANSFER / NEFT / RTGS / IMPS / CHEQUE / UPI; balance kept under lock.
--   usp_Api_Fund_List / _Get / _Save / _TopUp / _SetStatus / _History
--   Page UTILITY.ACCOUNTS.FUNDS (Utility > Accounts): VIEW, ADD, EDIT, TOPUP, STATUS. No role is granted.
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF OBJECT_ID(N'dbo.BankMaster', N'U') IS NULL
    CREATE TABLE dbo.BankMaster
    (
        Id            INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_BankMaster PRIMARY KEY,
        BankName      NVARCHAR(150) NOT NULL,
        AccountNumber NVARCHAR(30)  NOT NULL,
        BranchName    NVARCHAR(150) NOT NULL,
        IFSCCode      NVARCHAR(11)  NOT NULL,
        UpiId         NVARCHAR(50)  NULL,
        UpiHolderName NVARCHAR(150) NULL,
        IsPrimary     BIT NOT NULL CONSTRAINT DF_BankMaster_IsPrimary DEFAULT (0),
        IsActive      BIT NOT NULL CONSTRAINT DF_BankMaster_IsActive DEFAULT (1),
        CreatedAt     DATETIME NOT NULL CONSTRAINT DF_BankMaster_CreatedAt DEFAULT (GETDATE())
    );
GO
IF COL_LENGTH('dbo.BankMaster', 'CompanyId') IS NULL         ALTER TABLE dbo.BankMaster ADD CompanyId INT NOT NULL CONSTRAINT DF_BankMaster_CompanyId DEFAULT (1);
IF COL_LENGTH('dbo.BankMaster', 'AccountHolderName') IS NULL ALTER TABLE dbo.BankMaster ADD AccountHolderName NVARCHAR(150) NULL;
IF COL_LENGTH('dbo.BankMaster', 'AccountType') IS NULL       ALTER TABLE dbo.BankMaster ADD AccountType VARCHAR(10) NOT NULL CONSTRAINT DF_BankMaster_AccountType DEFAULT ('CURRENT');
IF COL_LENGTH('dbo.BankMaster', 'MICRCode') IS NULL          ALTER TABLE dbo.BankMaster ADD MICRCode VARCHAR(9) NULL;
IF COL_LENGTH('dbo.BankMaster', 'SwiftCode') IS NULL         ALTER TABLE dbo.BankMaster ADD SwiftCode VARCHAR(11) NULL;
IF COL_LENGTH('dbo.BankMaster', 'BranchAddress') IS NULL     ALTER TABLE dbo.BankMaster ADD BranchAddress NVARCHAR(400) NULL;
IF COL_LENGTH('dbo.BankMaster', 'City') IS NULL              ALTER TABLE dbo.BankMaster ADD City NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.BankMaster', 'ContactPerson') IS NULL     ALTER TABLE dbo.BankMaster ADD ContactPerson NVARCHAR(150) NULL;
IF COL_LENGTH('dbo.BankMaster', 'ContactPhone') IS NULL      ALTER TABLE dbo.BankMaster ADD ContactPhone VARCHAR(15) NULL;
IF COL_LENGTH('dbo.BankMaster', 'ContactEmail') IS NULL      ALTER TABLE dbo.BankMaster ADD ContactEmail NVARCHAR(150) NULL;
IF COL_LENGTH('dbo.BankMaster', 'Remarks') IS NULL           ALTER TABLE dbo.BankMaster ADD Remarks NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.BankMaster', 'CreatedBy') IS NULL         ALTER TABLE dbo.BankMaster ADD CreatedBy INT NULL;
IF COL_LENGTH('dbo.BankMaster', 'ModifiedBy') IS NULL        ALTER TABLE dbo.BankMaster ADD ModifiedBy INT NULL;
IF COL_LENGTH('dbo.BankMaster', 'ModifiedAt') IS NULL        ALTER TABLE dbo.BankMaster ADD ModifiedAt DATETIME NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_BankMaster_AccountType')
    ALTER TABLE dbo.BankMaster ADD CONSTRAINT CK_BankMaster_AccountType CHECK (AccountType IN ('SAVINGS', 'CURRENT', 'OD', 'CC'));
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_BankMaster_Account' AND object_id = OBJECT_ID(N'dbo.BankMaster'))
    CREATE UNIQUE INDEX UX_BankMaster_Account ON dbo.BankMaster (CompanyId, AccountNumber, IFSCCode);
GO

-- ── Fund tables ──────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID(N'dbo.Fund', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Fund
    (
        FundId         INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Fund PRIMARY KEY,
        CompanyId      INT           NOT NULL,
        BranchId       INT           NULL,                       -- the branch it was set up at (a fund serves the company)
        FundCode       VARCHAR(20)   NOT NULL,
        FundName       NVARCHAR(150) NOT NULL,
        FundType       VARCHAR(10)   NOT NULL CONSTRAINT CK_Fund_Type CHECK (FundType IN ('WALLET', 'BANK')),
        BankId         INT           NULL CONSTRAINT FK_Fund_Bank REFERENCES dbo.BankMaster (Id),
        OpeningBalance DECIMAL(18, 2) NOT NULL CONSTRAINT DF_Fund_Opening DEFAULT (0),
        OpeningDate    DATE          NOT NULL,
        CurrentBalance DECIMAL(18, 2) NOT NULL CONSTRAINT DF_Fund_Current DEFAULT (0),
        Remarks        NVARCHAR(500) NULL,
        IsActive       BIT           NOT NULL CONSTRAINT DF_Fund_IsActive DEFAULT (1),
        IsDeleted      BIT           NOT NULL CONSTRAINT DF_Fund_IsDeleted DEFAULT (0),
        CreatedBy      INT           NULL,
        CreatedDate    DATETIME      NOT NULL CONSTRAINT DF_Fund_Created DEFAULT (GETDATE()),
        ModifiedBy     INT           NULL,
        ModifiedDate   DATETIME      NULL,
        CONSTRAINT CK_Fund_BankForBank CHECK ((FundType = 'BANK' AND BankId IS NOT NULL) OR (FundType = 'WALLET' AND BankId IS NULL))
    );
    CREATE UNIQUE INDEX UX_Fund_Code ON dbo.Fund (CompanyId, FundCode) WHERE IsDeleted = 0;
    CREATE UNIQUE INDEX UX_Fund_Bank ON dbo.Fund (BankId) WHERE BankId IS NOT NULL AND IsDeleted = 0;
END
GO
IF OBJECT_ID(N'dbo.FundTransaction', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.FundTransaction
    (
        FundTxnId    BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_FundTransaction PRIMARY KEY,
        FundId       INT           NOT NULL CONSTRAINT FK_FundTransaction_Fund REFERENCES dbo.Fund (FundId),
        CompanyId    INT           NOT NULL,
        BranchId     INT           NULL,
        TxnType      VARCHAR(12)   NOT NULL,                       -- OPENING | TOPUP (PAYOUT ... later)
        TxnDate      DATE          NOT NULL,
        Amount       DECIMAL(18, 2) NOT NULL,                      -- + in, - out
        BalanceAfter DECIMAL(18, 2) NOT NULL,
        PaymentMode  VARCHAR(20)   NULL,
        ReferenceNo  NVARCHAR(100) NULL,
        Remarks      NVARCHAR(500) NULL,
        CreatedBy    INT           NULL,
        CreatedDate  DATETIME      NOT NULL CONSTRAINT DF_FundTransaction_Created DEFAULT (GETDATE())
    );
    CREATE INDEX IX_FundTransaction_Fund ON dbo.FundTransaction (FundId, FundTxnId);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Bank_List @CompanyId INT, @Search NVARCHAR(100) = NULL, @Status VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SELECT b.Id AS BankId, b.BankName, b.AccountHolderName, b.AccountNumber, b.AccountType, b.IFSCCode, b.MICRCode, b.SwiftCode,
           b.BranchName, b.BranchAddress, b.City, b.UpiId, b.UpiHolderName, b.ContactPerson, b.ContactPhone, b.ContactEmail, b.Remarks,
           b.IsPrimary, b.IsActive, b.CreatedAt, b.ModifiedAt,
           ISNULL(NULLIF(cu.FullName, N''), cu.Username) AS CreatedByName, ISNULL(NULLIF(mu.FullName, N''), mu.Username) AS ModifiedByName,
           (SELECT COUNT(*) FROM dbo.Fund f WHERE f.BankId = b.Id AND f.IsDeleted = 0) AS FundCount
      FROM dbo.BankMaster b
      LEFT JOIN dbo.Users cu ON cu.Id = b.CreatedBy
      LEFT JOIN dbo.Users mu ON mu.Id = b.ModifiedBy
     WHERE b.CompanyId = @CompanyId
       AND (@Status IS NULL OR (@Status = 'ACTIVE' AND b.IsActive = 1) OR (@Status = 'INACTIVE' AND b.IsActive = 0))
       AND (@Search IS NULL OR b.BankName LIKE N'%' + @Search + N'%' OR b.AccountNumber LIKE N'%' + @Search + N'%' OR b.IFSCCode LIKE N'%' + @Search + N'%'
            OR b.BranchName LIKE N'%' + @Search + N'%' OR b.AccountHolderName LIKE N'%' + @Search + N'%')
     ORDER BY b.IsActive DESC, b.IsPrimary DESC, b.BankName, b.Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Bank_Get @CompanyId INT, @BankId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.Id AS BankId, b.BankName, b.AccountHolderName, b.AccountNumber, b.AccountType, b.IFSCCode, b.MICRCode, b.SwiftCode,
           b.BranchName, b.BranchAddress, b.City, b.UpiId, b.UpiHolderName, b.ContactPerson, b.ContactPhone, b.ContactEmail, b.Remarks,
           b.IsPrimary, b.IsActive, b.CreatedAt, b.ModifiedAt,
           ISNULL(NULLIF(cu.FullName, N''), cu.Username) AS CreatedByName, ISNULL(NULLIF(mu.FullName, N''), mu.Username) AS ModifiedByName,
           (SELECT COUNT(*) FROM dbo.Fund f WHERE f.BankId = b.Id AND f.IsDeleted = 0) AS FundCount
      FROM dbo.BankMaster b
      LEFT JOIN dbo.Users cu ON cu.Id = b.CreatedBy
      LEFT JOIN dbo.Users mu ON mu.Id = b.ModifiedBy
     WHERE b.Id = @BankId AND b.CompanyId = @CompanyId;
END
GO

-- Success, Error, BankId
CREATE OR ALTER PROCEDURE dbo.usp_Api_Bank_Save
    @CompanyId INT, @UserId INT, @BankId INT = NULL,
    @BankName NVARCHAR(150), @AccountHolderName NVARCHAR(150), @AccountNumber NVARCHAR(30), @AccountType VARCHAR(10),
    @IFSCCode NVARCHAR(11), @MICRCode VARCHAR(9) = NULL, @SwiftCode VARCHAR(11) = NULL,
    @BranchName NVARCHAR(150), @BranchAddress NVARCHAR(400) = NULL, @City NVARCHAR(100) = NULL,
    @UpiId NVARCHAR(50) = NULL, @UpiHolderName NVARCHAR(150) = NULL,
    @ContactPerson NVARCHAR(150) = NULL, @ContactPhone VARCHAR(15) = NULL, @ContactEmail NVARCHAR(150) = NULL,
    @Remarks NVARCHAR(500) = NULL, @IsPrimary BIT = 0, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @BankId = NULLIF(@BankId, 0),
           @BankName = LTRIM(RTRIM(@BankName)), @AccountHolderName = LTRIM(RTRIM(@AccountHolderName)),
           @AccountNumber = REPLACE(LTRIM(RTRIM(@AccountNumber)), N' ', N''), @AccountType = UPPER(LTRIM(RTRIM(@AccountType))),
           @IFSCCode = UPPER(LTRIM(RTRIM(@IFSCCode))), @MICRCode = NULLIF(LTRIM(RTRIM(@MICRCode)), ''), @SwiftCode = NULLIF(UPPER(LTRIM(RTRIM(@SwiftCode))), ''),
           @BranchName = LTRIM(RTRIM(@BranchName)), @BranchAddress = NULLIF(LTRIM(RTRIM(@BranchAddress)), N''), @City = NULLIF(LTRIM(RTRIM(@City)), N''),
           @UpiId = NULLIF(LOWER(LTRIM(RTRIM(@UpiId))), N''), @UpiHolderName = NULLIF(LTRIM(RTRIM(@UpiHolderName)), N''),
           @ContactPerson = NULLIF(LTRIM(RTRIM(@ContactPerson)), N''), @ContactPhone = NULLIF(LTRIM(RTRIM(@ContactPhone)), ''),
           @ContactEmail = NULLIF(LOWER(LTRIM(RTRIM(@ContactEmail))), N''), @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');
    DECLARE @e NVARCHAR(400) =
        CASE WHEN ISNULL(@BankName, N'') = N'' OR LEN(@BankName) < 2 THEN N'Enter the bank name.'
             WHEN ISNULL(@AccountHolderName, N'') = N'' OR LEN(@AccountHolderName) < 2 THEN N'Enter the account holder name.'
             WHEN ISNULL(@AccountNumber, N'') = N'' OR @AccountNumber LIKE N'%[^0-9]%' OR LEN(@AccountNumber) NOT BETWEEN 6 AND 20 THEN N'Enter the account number (6 to 20 digits).'
             WHEN ISNULL(@AccountType, '') NOT IN ('SAVINGS', 'CURRENT', 'OD', 'CC') THEN N'Choose the account type.'
             WHEN ISNULL(@IFSCCode, N'') NOT LIKE N'[A-Z][A-Z][A-Z][A-Z]0[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]' OR LEN(@IFSCCode) <> 11 THEN N'Enter a valid IFSC (e.g. SBIN0001234).'
             WHEN @MICRCode IS NOT NULL AND (@MICRCode LIKE '%[^0-9]%' OR LEN(@MICRCode) <> 9) THEN N'MICR code is 9 digits.'
             WHEN @SwiftCode IS NOT NULL AND (@SwiftCode LIKE '%[^A-Z0-9]%' OR LEN(@SwiftCode) NOT IN (8, 11)) THEN N'SWIFT code is 8 or 11 letters / digits.'
             WHEN ISNULL(@BranchName, N'') = N'' THEN N'Enter the bank branch name.'
             WHEN @UpiId IS NOT NULL AND @UpiId NOT LIKE N'_%@_%' THEN N'Enter a valid UPI ID (e.g. name@bank).'
             WHEN @ContactPhone IS NOT NULL AND (@ContactPhone LIKE '%[^0-9]%' OR LEN(@ContactPhone) NOT BETWEEN 10 AND 12) THEN N'Enter a valid contact phone (10 digits).'
             WHEN @ContactEmail IS NOT NULL AND @ContactEmail NOT LIKE N'_%@_%._%' THEN N'Enter a valid contact e-mail.'
             WHEN @BankId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.BankMaster WHERE Id = @BankId AND CompanyId = @CompanyId) THEN N'The bank account was not found.'
             WHEN EXISTS (SELECT 1 FROM dbo.BankMaster WHERE CompanyId = @CompanyId AND AccountNumber = @AccountNumber AND IFSCCode = @IFSCCode AND Id <> ISNULL(@BankId, -1))
                  THEN N'This account number and IFSC are already in the Bank Master.'
             WHEN @BankId IS NOT NULL AND @IsActive = 0 AND EXISTS (SELECT 1 FROM dbo.Fund WHERE BankId = @BankId AND IsDeleted = 0 AND IsActive = 1)
                  THEN N'An active fund uses this bank account - deactivate the fund first.' END;
    IF @e IS NOT NULL BEGIN SELECT CAST(0 AS BIT) AS Success, @e AS Error, CAST(NULL AS INT) AS BankId; RETURN; END
    IF @IsActive = 0 SET @IsPrimary = 0;                                   -- an inactive account is never the primary one

    BEGIN TRANSACTION;
    IF @IsPrimary = 1
        UPDATE dbo.BankMaster SET IsPrimary = 0, ModifiedBy = @UserId, ModifiedAt = GETDATE()
         WHERE CompanyId = @CompanyId AND IsPrimary = 1 AND Id <> ISNULL(@BankId, -1);
    IF @BankId IS NULL
    BEGIN
        INSERT dbo.BankMaster (CompanyId, BankName, AccountHolderName, AccountNumber, AccountType, IFSCCode, MICRCode, SwiftCode, BranchName, BranchAddress,
                               City, UpiId, UpiHolderName, ContactPerson, ContactPhone, ContactEmail, Remarks, IsPrimary, IsActive, CreatedAt, CreatedBy)
        VALUES (@CompanyId, @BankName, @AccountHolderName, @AccountNumber, @AccountType, @IFSCCode, @MICRCode, @SwiftCode, @BranchName, @BranchAddress,
                @City, @UpiId, @UpiHolderName, @ContactPerson, @ContactPhone, @ContactEmail, @Remarks, @IsPrimary, @IsActive, GETDATE(), @UserId);
        SET @BankId = CAST(SCOPE_IDENTITY() AS INT);
    END
    ELSE
        UPDATE dbo.BankMaster SET BankName = @BankName, AccountHolderName = @AccountHolderName, AccountNumber = @AccountNumber, AccountType = @AccountType,
               IFSCCode = @IFSCCode, MICRCode = @MICRCode, SwiftCode = @SwiftCode, BranchName = @BranchName, BranchAddress = @BranchAddress, City = @City,
               UpiId = @UpiId, UpiHolderName = @UpiHolderName, ContactPerson = @ContactPerson, ContactPhone = @ContactPhone, ContactEmail = @ContactEmail,
               Remarks = @Remarks, IsPrimary = @IsPrimary, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedAt = GETDATE()
         WHERE Id = @BankId AND CompanyId = @CompanyId;
    COMMIT;
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @BankId AS BankId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Bank_SetStatus @CompanyId INT, @UserId INT, @BankId INT, @IsActive BIT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.BankMaster WHERE Id = @BankId AND CompanyId = @CompanyId)
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The bank account was not found.' AS Error, CAST(NULL AS INT) AS BankId; RETURN; END
    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM dbo.Fund WHERE BankId = @BankId AND IsDeleted = 0 AND IsActive = 1)
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'An active fund uses this bank account - deactivate the fund first.' AS Error, CAST(NULL AS INT) AS BankId; RETURN; END
    UPDATE dbo.BankMaster SET IsActive = @IsActive, IsPrimary = CASE WHEN @IsActive = 0 THEN 0 ELSE IsPrimary END, ModifiedBy = @UserId, ModifiedAt = GETDATE()
     WHERE Id = @BankId AND CompanyId = @CompanyId;
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @BankId AS BankId;
END
GO

-- the active bank accounts a BANK fund can use (with the one a fund already has, even if it is inactive now)
CREATE OR ALTER PROCEDURE dbo.usp_Api_Bank_Options @CompanyId INT, @FundId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.Id AS BankId, b.BankName, b.AccountNumber, b.IFSCCode, b.BranchName, b.AccountType, b.IsActive,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.Fund f WHERE f.BankId = b.Id AND f.IsDeleted = 0 AND f.FundId <> ISNULL(@FundId, -1)) THEN 1 ELSE 0 END AS BIT) AS UsedByOtherFund
      FROM dbo.BankMaster b
     WHERE b.CompanyId = @CompanyId
       AND (b.IsActive = 1 OR EXISTS (SELECT 1 FROM dbo.Fund f WHERE f.FundId = @FundId AND f.BankId = b.Id))
     ORDER BY b.IsPrimary DESC, b.BankName;
END
GO

-- ── 2. Fund Master ─────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_Fund_List @CompanyId INT, @Search NVARCHAR(100) = NULL, @Type VARCHAR(10) = NULL, @Status VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N''); SET @Type = NULLIF(@Type, '');
    SELECT f.FundId, f.FundCode, f.FundName, f.FundType, f.BankId, b.BankName, b.AccountNumber, b.IFSCCode, f.OpeningBalance, f.OpeningDate,
           f.CurrentBalance, f.Remarks, f.IsActive, f.CreatedDate, f.ModifiedDate,
           ISNULL(NULLIF(cu.FullName, N''), cu.Username) AS CreatedByName, ISNULL(NULLIF(mu.FullName, N''), mu.Username) AS ModifiedByName,
           (SELECT COUNT(*) FROM dbo.FundTransaction t WHERE t.FundId = f.FundId AND t.TxnType <> 'OPENING') AS MovementCount,
           (SELECT MAX(t.TxnDate) FROM dbo.FundTransaction t WHERE t.FundId = f.FundId AND t.TxnType = 'TOPUP') AS LastTopUpDate
      FROM dbo.Fund f
      LEFT JOIN dbo.BankMaster b ON b.Id = f.BankId
      LEFT JOIN dbo.Users cu ON cu.Id = f.CreatedBy
      LEFT JOIN dbo.Users mu ON mu.Id = f.ModifiedBy
     WHERE f.CompanyId = @CompanyId AND f.IsDeleted = 0
       AND (@Type IS NULL OR f.FundType = @Type)
       AND (@Status IS NULL OR (@Status = 'ACTIVE' AND f.IsActive = 1) OR (@Status = 'INACTIVE' AND f.IsActive = 0))
       AND (@Search IS NULL OR f.FundName LIKE N'%' + @Search + N'%' OR f.FundCode LIKE N'%' + @Search + N'%' OR b.BankName LIKE N'%' + @Search + N'%'
            OR b.AccountNumber LIKE N'%' + @Search + N'%')
     ORDER BY f.IsActive DESC, f.FundName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Fund_Get @CompanyId INT, @FundId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.FundId, f.FundCode, f.FundName, f.FundType, f.BankId, b.BankName, b.AccountNumber, b.IFSCCode, b.BranchName AS BankBranch,
           f.OpeningBalance, f.OpeningDate, f.CurrentBalance, f.Remarks, f.IsActive, f.CreatedDate, f.ModifiedDate,
           ISNULL(NULLIF(cu.FullName, N''), cu.Username) AS CreatedByName, ISNULL(NULLIF(mu.FullName, N''), mu.Username) AS ModifiedByName,
           (SELECT COUNT(*) FROM dbo.FundTransaction t WHERE t.FundId = f.FundId AND t.TxnType <> 'OPENING') AS MovementCount
      FROM dbo.Fund f
      LEFT JOIN dbo.BankMaster b ON b.Id = f.BankId
      LEFT JOIN dbo.Users cu ON cu.Id = f.CreatedBy
      LEFT JOIN dbo.Users mu ON mu.Id = f.ModifiedBy
     WHERE f.FundId = @FundId AND f.CompanyId = @CompanyId AND f.IsDeleted = 0;
END
GO

-- Success, Error, FundId. A new fund books its opening balance; an edit may change it only while nothing else moved.
CREATE OR ALTER PROCEDURE dbo.usp_Api_Fund_Save
    @CompanyId INT, @UserId INT, @BranchId INT = NULL, @FundId INT = NULL,
    @FundCode VARCHAR(20), @FundName NVARCHAR(150), @FundType VARCHAR(10), @BankId INT = NULL,
    @OpeningBalance DECIMAL(18, 2) = 0, @OpeningDate DATE = NULL, @Remarks NVARCHAR(500) = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @FundId = NULLIF(@FundId, 0), @FundCode = UPPER(LTRIM(RTRIM(@FundCode))), @FundName = LTRIM(RTRIM(@FundName)),
           @FundType = UPPER(LTRIM(RTRIM(@FundType))), @BankId = NULLIF(@BankId, 0), @OpeningBalance = ISNULL(@OpeningBalance, 0),
           @OpeningDate = ISNULL(@OpeningDate, CAST(GETDATE() AS DATE)), @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');
    IF @FundType = 'WALLET' SET @BankId = NULL;
    DECLARE @moved INT = CASE WHEN @FundId IS NULL THEN 0 ELSE (SELECT COUNT(*) FROM dbo.FundTransaction WHERE FundId = @FundId AND TxnType <> 'OPENING') END;
    DECLARE @oldOpening DECIMAL(18, 2), @oldDate DATE;
    SELECT @oldOpening = OpeningBalance, @oldDate = OpeningDate FROM dbo.Fund WHERE FundId = @FundId AND CompanyId = @CompanyId AND IsDeleted = 0;
    DECLARE @e NVARCHAR(400) =
        CASE WHEN ISNULL(@FundCode, '') = '' OR @FundCode LIKE '%[^A-Z0-9_-]%' OR LEN(@FundCode) > 20 THEN N'Enter the fund code (up to 20 letters, digits, - or _).'
             WHEN ISNULL(@FundName, N'') = N'' OR LEN(@FundName) < 2 THEN N'Enter the fund name.'
             WHEN ISNULL(@FundType, '') NOT IN ('WALLET', 'BANK') THEN N'Choose the fund type: Wallet or Bank.'
             WHEN @FundType = 'BANK' AND @BankId IS NULL THEN N'Choose the bank account of the fund.'
             WHEN @FundType = 'BANK' AND NOT EXISTS (SELECT 1 FROM dbo.BankMaster WHERE Id = @BankId AND CompanyId = @CompanyId
                                                     AND (IsActive = 1 OR EXISTS (SELECT 1 FROM dbo.Fund WHERE FundId = @FundId AND BankId = @BankId)))
                  THEN N'Choose an active bank account from the Bank Master.'
             WHEN @FundType = 'BANK' AND EXISTS (SELECT 1 FROM dbo.Fund WHERE BankId = @BankId AND IsDeleted = 0 AND FundId <> ISNULL(@FundId, -1))
                  THEN N'This bank account already has a fund.'
             WHEN @OpeningBalance < 0 THEN N'The opening balance cannot be negative.'
             WHEN @OpeningBalance > 9999999999.99 THEN N'The opening balance is too large.'
             WHEN @OpeningDate > CAST(GETDATE() AS DATE) THEN N'The opening date cannot be in the future.'
             WHEN @FundId IS NOT NULL AND @oldOpening IS NULL THEN N'The fund was not found.'
             WHEN @FundId IS NOT NULL AND @moved > 0 AND (@OpeningBalance <> @oldOpening OR @OpeningDate <> @oldDate)
                  THEN N'The opening balance and date cannot change after the fund has top-ups or other movements.'
             WHEN EXISTS (SELECT 1 FROM dbo.Fund WHERE CompanyId = @CompanyId AND FundCode = @FundCode AND IsDeleted = 0 AND FundId <> ISNULL(@FundId, -1))
                  THEN N'This fund code is already used.' END;
    IF @e IS NOT NULL BEGIN SELECT CAST(0 AS BIT) AS Success, @e AS Error, CAST(NULL AS INT) AS FundId; RETURN; END

    BEGIN TRANSACTION;
    IF @FundId IS NULL
    BEGIN
        INSERT dbo.Fund (CompanyId, BranchId, FundCode, FundName, FundType, BankId, OpeningBalance, OpeningDate, CurrentBalance, Remarks, IsActive, CreatedBy)
        VALUES (@CompanyId, @BranchId, @FundCode, @FundName, @FundType, @BankId, @OpeningBalance, @OpeningDate, @OpeningBalance, @Remarks, @IsActive, @UserId);
        SET @FundId = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.FundTransaction (FundId, CompanyId, BranchId, TxnType, TxnDate, Amount, BalanceAfter, Remarks, CreatedBy)
        VALUES (@FundId, @CompanyId, @BranchId, 'OPENING', @OpeningDate, @OpeningBalance, @OpeningBalance, N'Opening balance', @UserId);
    END
    ELSE
    BEGIN
        UPDATE dbo.Fund SET FundCode = @FundCode, FundName = @FundName, FundType = @FundType, BankId = @BankId, OpeningBalance = @OpeningBalance,
               OpeningDate = @OpeningDate, CurrentBalance = CASE WHEN @moved = 0 THEN @OpeningBalance ELSE CurrentBalance END,
               Remarks = @Remarks, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE FundId = @FundId AND CompanyId = @CompanyId;
        -- nothing moved yet: the opening entry follows the new opening balance / date
        IF @moved = 0
            UPDATE dbo.FundTransaction SET TxnDate = @OpeningDate, Amount = @OpeningBalance, BalanceAfter = @OpeningBalance
             WHERE FundId = @FundId AND TxnType = 'OPENING';
    END
    COMMIT;
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @FundId AS FundId;
END
GO

-- Success, Error, FundId, FundTxnId, Balance
CREATE OR ALTER PROCEDURE dbo.usp_Api_Fund_TopUp
    @CompanyId INT, @UserId INT, @BranchId INT = NULL, @FundId INT, @Amount DECIMAL(18, 2), @TxnDate DATE = NULL,
    @PaymentMode VARCHAR(20), @ReferenceNo NVARCHAR(100) = NULL, @Remarks NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @TxnDate = ISNULL(@TxnDate, CAST(GETDATE() AS DATE)), @PaymentMode = UPPER(LTRIM(RTRIM(@PaymentMode))),
           @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N''), @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');
    DECLARE @e NVARCHAR(400) =
        CASE WHEN ISNULL(@Amount, 0) <= 0 THEN N'Enter the top-up amount (more than 0).'
             WHEN @Amount > 9999999999.99 THEN N'The amount is too large.'
             WHEN @TxnDate > CAST(GETDATE() AS DATE) THEN N'The top-up date cannot be in the future.'
             WHEN ISNULL(@PaymentMode, '') NOT IN ('CASH', 'BANK TRANSFER', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE', 'UPI') THEN N'Choose the mode of the top-up.'
             WHEN @PaymentMode IN ('NEFT', 'RTGS', 'IMPS', 'CHEQUE', 'UPI', 'BANK TRANSFER') AND @ReferenceNo IS NULL THEN N'Enter the reference (UTR / cheque no.) of the top-up.'
             WHEN NOT EXISTS (SELECT 1 FROM dbo.Fund WHERE FundId = @FundId AND CompanyId = @CompanyId AND IsDeleted = 0) THEN N'The fund was not found.'
             WHEN NOT EXISTS (SELECT 1 FROM dbo.Fund WHERE FundId = @FundId AND IsActive = 1) THEN N'The fund is inactive - activate it to top it up.'
             WHEN @TxnDate < (SELECT OpeningDate FROM dbo.Fund WHERE FundId = @FundId) THEN N'The top-up date cannot be before the fund''s opening date.' END;
    IF @e IS NOT NULL BEGIN SELECT CAST(0 AS BIT) AS Success, @e AS Error, CAST(NULL AS INT) AS FundId, CAST(NULL AS BIGINT) AS FundTxnId, CAST(NULL AS DECIMAL(18, 2)) AS Balance; RETURN; END

    BEGIN TRANSACTION;
    DECLARE @bal DECIMAL(18, 2);
    -- the balance is moved under the fund's row lock (two top-ups at once both count)
    UPDATE dbo.Fund WITH (UPDLOCK, ROWLOCK) SET @bal = CurrentBalance = CurrentBalance + @Amount, ModifiedBy = @UserId, ModifiedDate = GETDATE()
     WHERE FundId = @FundId;
    INSERT dbo.FundTransaction (FundId, CompanyId, BranchId, TxnType, TxnDate, Amount, BalanceAfter, PaymentMode, ReferenceNo, Remarks, CreatedBy)
    VALUES (@FundId, @CompanyId, @BranchId, 'TOPUP', @TxnDate, @Amount, @bal, @PaymentMode, @ReferenceNo, @Remarks, @UserId);
    DECLARE @tx BIGINT = SCOPE_IDENTITY();
    COMMIT;
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @FundId AS FundId, @tx AS FundTxnId, @bal AS Balance;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Fund_SetStatus @CompanyId INT, @UserId INT, @FundId INT, @IsActive BIT
AS
BEGIN
    SET NOCOUNT ON;
    IF @IsActive = 1 AND EXISTS (SELECT 1 FROM dbo.Fund f JOIN dbo.BankMaster b ON b.Id = f.BankId WHERE f.FundId = @FundId AND b.IsActive = 0)
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'Its bank account is inactive in the Bank Master - activate the account first.' AS Error, CAST(NULL AS INT) AS FundId; RETURN; END
    UPDATE dbo.Fund SET IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE FundId = @FundId AND CompanyId = @CompanyId AND IsDeleted = 0;
    IF @@ROWCOUNT = 0 SELECT CAST(0 AS BIT) AS Success, N'The fund was not found.' AS Error, CAST(NULL AS INT) AS FundId;
    ELSE SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @FundId AS FundId;
END
GO

-- the fund's movements, newest first, with the running balance (optional date range)
CREATE OR ALTER PROCEDURE dbo.usp_Api_Fund_History @CompanyId INT, @FundId INT, @FromDate DATE = NULL, @ToDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT t.FundTxnId, t.TxnType, t.TxnDate, t.Amount, t.BalanceAfter, t.PaymentMode, t.ReferenceNo, t.Remarks, t.CreatedDate,
           ISNULL(NULLIF(u.FullName, N''), u.Username) AS CreatedByName, br.BranchName
      FROM dbo.FundTransaction t
      JOIN dbo.Fund f ON f.FundId = t.FundId AND f.CompanyId = @CompanyId
      LEFT JOIN dbo.Users u ON u.Id = t.CreatedBy
      LEFT JOIN dbo.Branchmaster br ON br.BranchID = t.BranchId
     WHERE t.FundId = @FundId AND (@FromDate IS NULL OR t.TxnDate >= @FromDate) AND (@ToDate IS NULL OR t.TxnDate <= @ToDate)
     ORDER BY t.FundTxnId DESC;
END
GO

-- ── pages, controls and endpoints ──────────────────────────────────────────────────────────────────────────
DECLARE @co INT = 1, @menu INT, @page INT, @view INT, @ctl INT;
DECLARE @pg TABLE (Seq INT IDENTITY, MenuCode NVARCHAR(60), PageCode NVARCHAR(60), Title NVARCHAR(100), Ctl NVARCHAR(60), Sort INT, Icon NVARCHAR(60), ViewActs NVARCHAR(200));
INSERT @pg (MenuCode, PageCode, Title, Ctl, Sort, Icon, ViewActs) VALUES
 (N'MASTER.GENERAL',   N'MASTER.BANKS',            N'Bank Master', N'Banks', 240, N'bi bi-bank me-2',   N'Index,ListData,Get'),
 (N'UTILITY.ACCOUNTS', N'UTILITY.ACCOUNTS.FUNDS',  N'Fund Master', N'Funds', 77,  N'bi bi-safe2 me-2', N'Index,ListData,Get,History,BankOptions');
DECLARE @ctls TABLE (PageCode NVARCHAR(60), Code VARCHAR(30), Title NVARCHAR(150), Sort INT, Act NVARCHAR(60));
INSERT @ctls VALUES
 (N'MASTER.BANKS', 'ADD', N'Add a bank account', 20, N'Save'), (N'MASTER.BANKS', 'EDIT', N'Edit a bank account', 30, N'Save'),
 (N'MASTER.BANKS', 'STATUS', N'Activate / deactivate', 40, N'SetStatus'),
 (N'UTILITY.ACCOUNTS.FUNDS', 'ADD', N'Add a fund', 20, N'Save'), (N'UTILITY.ACCOUNTS.FUNDS', 'EDIT', N'Edit a fund', 30, N'Save'),
 (N'UTILITY.ACCOUNTS.FUNDS', 'TOPUP', N'Top up a fund', 40, N'TopUp'), (N'UTILITY.ACCOUNTS.FUNDS', 'STATUS', N'Activate / deactivate', 50, N'SetStatus');
DECLARE @s INT = 1, @n INT = (SELECT COUNT(*) FROM @pg), @mc NVARCHAR(60), @pc NVARCHAR(60), @ti NVARCHAR(100), @cn NVARCHAR(60), @so INT, @ic NVARCHAR(60), @va NVARCHAR(200);
WHILE @s <= @n
BEGIN
    SELECT @mc = MenuCode, @pc = PageCode, @ti = Title, @cn = Ctl, @so = Sort, @ic = Icon, @va = ViewActs FROM @pg WHERE Seq = @s;
    SET @menu = (SELECT Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = @mc);
    IF @menu IS NULL THROW 51400, 'A menu of 2522 is missing (MASTER.GENERAL / UTILITY.ACCOUNTS).', 1;
    SELECT @page = NULL, @view = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @pc, @Title = @ti, @Controller = @cn, @Action = N'Index',
         @Show_In_Menu = 1, @Sort_Order = @so, @Icon = @ic, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
    DECLARE @a NVARCHAR(60);
    DECLARE va CURSOR LOCAL FAST_FORWARD FOR SELECT LTRIM(value) FROM STRING_SPLIT(@va, ',');
    OPEN va; FETCH NEXT FROM va INTO @a;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = @cn, @Action = @a, @Source = 'SEED';
        FETCH NEXT FROM va INTO @a;
    END
    CLOSE va; DEALLOCATE va;
    DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @ca NVARCHAR(60);
    DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort, Act FROM @ctls WHERE PageCode = @pc;
    OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = @cn, @Action = @ca, @Source = 'SEED';
        FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
    END
    CLOSE k; DEALLOCATE k;
    SET @s += 1;
END
GO
-- Save serves both Add and Edit: it is mapped to page access (VIEW) and the controller checks ADD (new) or EDIT (existing)
-- itself - a user allowed to add but not to edit can still add.
DECLARE @p INT, @v INT, @pc2 NVARCHAR(60), @cn2 NVARCHAR(60);
DECLARE sv CURSOR LOCAL FAST_FORWARD FOR SELECT N'MASTER.BANKS', N'Banks' UNION ALL SELECT N'UTILITY.ACCOUNTS.FUNDS', N'Funds';
OPEN sv; FETCH NEXT FROM sv INTO @pc2, @cn2;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @p = Page_ID FROM dbo.PageMaster WHERE Page_Code = @pc2;
    SELECT @v = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @p AND Control_Code = 'VIEW';
    UPDATE dbo.PageEndpointMap SET Control_ID = @v WHERE Page_ID = @p AND App = 'WEB' AND Http_Method = 'POST' AND Controller = @cn2 AND Action = N'Save';
    FETCH NEXT FROM sv INTO @pc2, @cn2;
END
CLOSE sv; DEALLOCATE sv;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2522 applied: Bank Master and Fund Master.';
GO
