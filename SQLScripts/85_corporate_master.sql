-- ====================================================================================================
-- Script: 85_corporate_master.sql
-- Description: Creates dbo.CorporateMaster table and Stored Procedures for API operations & CRUD.
-- ====================================================================================================

-- 1. Create dbo.CorporateMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CorporateMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.CorporateMaster
    (
        Corporate_ID    INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId       INT NOT NULL DEFAULT 1,
        Branch_ID       INT NOT NULL,
        Corporate_Code  NVARCHAR(50) NULL,
        Corporate_Name  NVARCHAR(200) NOT NULL,
        Corporate_Type  NVARCHAR(50) NOT NULL, -- IPD, OPD, LAB, MED, GENERAL, ALL
        Effective_From  DATETIME2 NOT NULL,
        Effective_To    DATETIME2 NOT NULL,
        Credit_Limit    DECIMAL(18,2) NULL,
        Credit_Days     INT NULL,
        BillingCycle    NVARCHAR(50) NOT NULL, -- Monthly, Daily, Yearly, Bi-Monthly, Half-Yearly
        Contact_No      NVARCHAR(20) NOT NULL,
        Email           NVARCHAR(150) NULL,
        Address         NVARCHAR(500) NULL,
        Pincode         NVARCHAR(20) NULL,
        Status          BIT NOT NULL DEFAULT 1, -- 1: Active, 0: Inactive
        CreatedBy       INT NULL,
        CreatedDate     DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy      INT NULL,
        ModifiedDate    DATETIME2 NULL,
        CONSTRAINT FK_CorporateMaster_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID)
    );
    CREATE INDEX IX_CorporateMaster_Branch ON dbo.CorporateMaster(Branch_ID, Status);
    CREATE INDEX IX_CorporateMaster_Type ON dbo.CorporateMaster(Corporate_Type);
    PRINT 'Created table dbo.CorporateMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.CorporateMaster already exists';
END
GO

-- 2. Stored Procedure: usp_Api_Corporate_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_Corporate_GetList
    @BranchId      INT = NULL,
    @CorporateType NVARCHAR(50) = NULL,
    @Status        BIT = NULL,
    @Search        NVARCHAR(100) = NULL,
    @CompanyId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        c.Corporate_ID,
        c.CompanyId,
        c.Branch_ID,
        b.BranchName,
        b.BranchCode,
        c.Corporate_Code,
        c.Corporate_Name,
        c.Corporate_Type,
        c.Effective_From,
        c.Effective_To,
        c.Credit_Limit,
        c.Credit_Days,
        c.BillingCycle,
        c.Contact_No,
        c.Email,
        c.Address,
        c.Pincode,
        c.Status,
        c.CreatedBy,
        c.CreatedDate,
        c.ModifiedBy,
        c.ModifiedDate
    FROM dbo.CorporateMaster c
    INNER JOIN dbo.Branchmaster b ON c.Branch_ID = b.BranchID
    WHERE (@BranchId IS NULL OR c.Branch_ID = @BranchId)
      AND (@CorporateType IS NULL OR @CorporateType = '' OR c.Corporate_Type = @CorporateType)
      AND (@Status IS NULL OR c.Status = @Status)
      AND (@CompanyId IS NULL OR c.CompanyId = @CompanyId)
      AND (@Search IS NULL OR @Search = '' OR 
           c.Corporate_Name LIKE '%' + @Search + '%' OR 
           c.Corporate_Code LIKE '%' + @Search + '%' OR 
           c.Contact_No LIKE '%' + @Search + '%' OR
           c.BillingCycle LIKE '%' + @Search + '%')
    ORDER BY c.CreatedDate DESC;
END
GO

-- 3. Stored Procedure: usp_Corporate_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Corporate_GetById
    @Corporate_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        c.Corporate_ID,
        c.CompanyId,
        c.Branch_ID,
        b.BranchName,
        b.BranchCode,
        c.Corporate_Code,
        c.Corporate_Name,
        c.Corporate_Type,
        c.Effective_From,
        c.Effective_To,
        c.Credit_Limit,
        c.Credit_Days,
        c.BillingCycle,
        c.Contact_No,
        c.Email,
        c.Address,
        c.Pincode,
        c.Status,
        c.CreatedBy,
        c.CreatedDate,
        c.ModifiedBy,
        c.ModifiedDate
    FROM dbo.CorporateMaster c
    INNER JOIN dbo.Branchmaster b ON c.Branch_ID = b.BranchID
    WHERE c.Corporate_ID = @Corporate_ID;
END
GO

-- 4. Stored Procedure: usp_Corporate_Create
CREATE OR ALTER PROCEDURE dbo.usp_Corporate_Create
    @CompanyId          INT = 1,
    @Branch_ID          INT,
    @Corporate_Code     NVARCHAR(50) = NULL,
    @Corporate_Name     NVARCHAR(200),
    @Corporate_Type     NVARCHAR(50),
    @Effective_From     DATETIME2,
    @Effective_To       DATETIME2,
    @Credit_Limit       DECIMAL(18,2) = NULL,
    @Credit_Days        INT = NULL,
    @BillingCycle       NVARCHAR(50),
    @Contact_No         NVARCHAR(20),
    @Email              NVARCHAR(150) = NULL,
    @Address            NVARCHAR(500) = NULL,
    @Pincode            NVARCHAR(20) = NULL,
    @Status             BIT = 1,
    @CreatedBy          INT = NULL,
    @NewCorporate_ID    INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Generate Corporate Code if not provided
    IF @Corporate_Code IS NULL OR LTRIM(RTRIM(@Corporate_Code)) = ''
    BEGIN
        DECLARE @NextNum INT;
        SELECT @NextNum = ISNULL(MAX(Corporate_ID), 0) + 1 FROM dbo.CorporateMaster;
        SET @Corporate_Code = 'CORP-' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
    END

    INSERT INTO dbo.CorporateMaster
    (
        CompanyId,
        Branch_ID,
        Corporate_Code,
        Corporate_Name,
        Corporate_Type,
        Effective_From,
        Effective_To,
        Credit_Limit,
        Credit_Days,
        BillingCycle,
        Contact_No,
        Email,
        Address,
        Pincode,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Branch_ID,
        @Corporate_Code,
        @Corporate_Name,
        @Corporate_Type,
        @Effective_From,
        @Effective_To,
        @Credit_Limit,
        @Credit_Days,
        @BillingCycle,
        @Contact_No,
        @Email,
        @Address,
        @Pincode,
        @Status,
        @CreatedBy,
        GETDATE()
    );

    SET @NewCorporate_ID = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_Corporate_Update
CREATE OR ALTER PROCEDURE dbo.usp_Corporate_Update
    @Corporate_ID       INT,
    @Branch_ID          INT,
    @Corporate_Code     NVARCHAR(50) = NULL,
    @Corporate_Name     NVARCHAR(200),
    @Corporate_Type     NVARCHAR(50),
    @Effective_From     DATETIME2,
    @Effective_To       DATETIME2,
    @Credit_Limit       DECIMAL(18,2) = NULL,
    @Credit_Days        INT = NULL,
    @BillingCycle       NVARCHAR(50),
    @Contact_No         NVARCHAR(20),
    @Email              NVARCHAR(150) = NULL,
    @Address            NVARCHAR(500) = NULL,
    @Pincode            NVARCHAR(20) = NULL,
    @Status             BIT = 1,
    @ModifiedBy         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.CorporateMaster
    SET
        Branch_ID       = @Branch_ID,
        Corporate_Code  = ISNULL(@Corporate_Code, Corporate_Code),
        Corporate_Name  = @Corporate_Name,
        Corporate_Type  = @Corporate_Type,
        Effective_From  = @Effective_From,
        Effective_To    = @Effective_To,
        Credit_Limit    = @Credit_Limit,
        Credit_Days     = @Credit_Days,
        BillingCycle    = @BillingCycle,
        Contact_No      = @Contact_No,
        Email           = @Email,
        Address         = @Address,
        Pincode         = @Pincode,
        Status          = @Status,
        ModifiedBy      = @ModifiedBy,
        ModifiedDate    = GETDATE()
    WHERE Corporate_ID  = @Corporate_ID;
END
GO

-- 6. Stored Procedure: usp_Corporate_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Corporate_ToggleStatus
    @Corporate_ID INT,
    @ModifiedBy   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.CorporateMaster
    SET 
        Status = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedBy = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE Corporate_ID = @Corporate_ID;

    SELECT Status FROM dbo.CorporateMaster WHERE Corporate_ID = @Corporate_ID;
END
GO

-- 7. Stored Procedure: usp_Corporate_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Corporate_Delete
    @Corporate_ID INT,
    @ModifiedBy   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.CorporateMaster
    WHERE Corporate_ID = @Corporate_ID;
END
GO

-- 8. Seed Sample Corporate Data for Primary Branches
IF NOT EXISTS (SELECT 1 FROM dbo.CorporateMaster)
BEGIN
    DECLARE @DefaultBranch INT;
    SELECT TOP 1 @DefaultBranch = BranchID FROM dbo.Branchmaster ORDER BY BranchID;

    IF @DefaultBranch IS NOT NULL
    BEGIN
        INSERT INTO dbo.CorporateMaster 
        (
            CompanyId, Branch_ID, Corporate_Code, Corporate_Name, Corporate_Type, 
            Effective_From, Effective_To, Credit_Limit, Credit_Days, BillingCycle, 
            Contact_No, Email, Address, Pincode, Status, CreatedDate
        )
        VALUES
        (
            1, @DefaultBranch, 'CORP-0001', 'Tata Consultancy Services (TCS Healthcare)', 'IPD',
            GETDATE(), DATEADD(YEAR, 1, GETDATE()), 500000.00, 30, 'Monthly',
            '9876543210', 'tcs.health@tata.com', 'Plot 54, Sector V, Salt Lake', '700091', 1, GETDATE()
        ),
        (
            1, @DefaultBranch, 'CORP-0002', 'Wipro Health & Wellness Tie-up', 'OPD',
            GETDATE(), DATEADD(YEAR, 1, GETDATE()), 250000.00, 45, 'Bi-Monthly',
            '9830123456', 'wipro.tpa@wipro.com', 'Block DM, Sector V, Bidhannagar', '700091', 1, GETDATE()
        ),
        (
            1, @DefaultBranch, 'CORP-0003', 'Indian Oil Corporation Ltd (IOCL)', 'ALL',
            GETDATE(), DATEADD(YEAR, 2, GETDATE()), 1000000.00, 60, 'Monthly',
            '9123456780', 'medical@iocl.co.in', 'Indian Oil Bhavan, Gariahat Road', '700068', 1, GETDATE()
        ),
        (
            1, @DefaultBranch, 'CORP-0004', 'Apollo Munich / HDFC ERGO Corporate', 'MED',
            GETDATE(), DATEADD(MONTH, 6, GETDATE()), 150000.00, 15, 'Daily',
            '9748123456', 'claims@hdfcergo.com', 'Camac Street, 4th Floor', '700016', 1, GETDATE()
        );
        PRINT 'Sample Corporate Master records seeded successfully.';
    END
END
GO
