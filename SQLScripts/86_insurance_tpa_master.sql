-- ====================================================================================================
-- Script: 86_insurance_tpa_master.sql
-- Description: Creates dbo.InsuranceTPAMaster table and Stored Procedures for API operations & CRUD.
-- ====================================================================================================

-- 1. Create dbo.InsuranceTPAMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'InsuranceTPAMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.InsuranceTPAMaster
    (
        InsuranceTPA_ID         INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId              INT NOT NULL DEFAULT 1,
        Branch_ID              INT NOT NULL,
        Type                   NVARCHAR(50) NOT NULL, -- 'Insurance Company', 'TPA'
        Name                   NVARCHAR(200) NOT NULL,
        Code                   NVARCHAR(50) NOT NULL,
        SchemeName             NVARCHAR(200) NULL,
        PolicyPrefix           NVARCHAR(50) NOT NULL,
        NetworkCategory        NVARCHAR(50) NOT NULL, -- 'Cashless', 'Reimbursement', 'Both'
        AuthorizationRequired  BIT NOT NULL DEFAULT 1,
        ContactPerson          NVARCHAR(150) NULL,
        ContactNumber          NVARCHAR(20) NULL,
        Email                  NVARCHAR(150) NULL,
        Status                 BIT NOT NULL DEFAULT 1, -- 1: Active, 0: Inactive
        CreatedBy              INT NULL,
        CreatedDate            DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy             INT NULL,
        ModifiedDate           DATETIME2 NULL,
        CONSTRAINT FK_InsuranceTPAMaster_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID)
    );
    CREATE INDEX IX_InsuranceTPAMaster_Branch ON dbo.InsuranceTPAMaster(Branch_ID, Status);
    CREATE INDEX IX_InsuranceTPAMaster_Type ON dbo.InsuranceTPAMaster(Type);
    CREATE INDEX IX_InsuranceTPAMaster_NetworkCategory ON dbo.InsuranceTPAMaster(NetworkCategory);
    CREATE INDEX IX_InsuranceTPAMaster_Code ON dbo.InsuranceTPAMaster(Code);
    PRINT 'Created table dbo.InsuranceTPAMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.InsuranceTPAMaster already exists';
END
GO

-- 2. Stored Procedure: usp_Api_InsuranceTPA_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_InsuranceTPA_GetList
    @BranchId          INT = NULL,
    @Type              NVARCHAR(50) = NULL,
    @NetworkCategory   NVARCHAR(50) = NULL,
    @Status            BIT = NULL,
    @Search            NVARCHAR(100) = NULL,
    @CompanyId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        i.InsuranceTPA_ID,
        i.CompanyId,
        i.Branch_ID,
        b.BranchName,
        b.BranchCode,
        i.Type,
        i.Name,
        i.Code,
        i.SchemeName,
        i.PolicyPrefix,
        i.NetworkCategory,
        i.AuthorizationRequired,
        i.ContactPerson,
        i.ContactNumber,
        i.Email,
        i.Status,
        i.CreatedBy,
        i.CreatedDate,
        i.ModifiedBy,
        i.ModifiedDate
    FROM dbo.InsuranceTPAMaster i
    INNER JOIN dbo.Branchmaster b ON i.Branch_ID = b.BranchID
    WHERE (@BranchId IS NULL OR i.Branch_ID = @BranchId)
      AND (@Type IS NULL OR @Type = '' OR i.Type = @Type)
      AND (@NetworkCategory IS NULL OR @NetworkCategory = '' OR i.NetworkCategory = @NetworkCategory)
      AND (@Status IS NULL OR i.Status = @Status)
      AND (@CompanyId IS NULL OR i.CompanyId = @CompanyId)
      AND (@Search IS NULL OR @Search = '' OR 
           i.Name LIKE '%' + @Search + '%' OR 
           i.Code LIKE '%' + @Search + '%' OR 
           i.SchemeName LIKE '%' + @Search + '%' OR
           i.PolicyPrefix LIKE '%' + @Search + '%' OR
           i.ContactPerson LIKE '%' + @Search + '%' OR
           i.ContactNumber LIKE '%' + @Search + '%' OR
           i.Email LIKE '%' + @Search + '%')
    ORDER BY i.CreatedDate DESC;
END
GO

-- 3. Stored Procedure: usp_InsuranceTPA_GetById
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTPA_GetById
    @InsuranceTPA_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        i.InsuranceTPA_ID,
        i.CompanyId,
        i.Branch_ID,
        b.BranchName,
        b.BranchCode,
        i.Type,
        i.Name,
        i.Code,
        i.SchemeName,
        i.PolicyPrefix,
        i.NetworkCategory,
        i.AuthorizationRequired,
        i.ContactPerson,
        i.ContactNumber,
        i.Email,
        i.Status,
        i.CreatedBy,
        i.CreatedDate,
        i.ModifiedBy,
        i.ModifiedDate
    FROM dbo.InsuranceTPAMaster i
    INNER JOIN dbo.Branchmaster b ON i.Branch_ID = b.BranchID
    WHERE i.InsuranceTPA_ID = @InsuranceTPA_ID;
END
GO

-- 4. Stored Procedure: usp_InsuranceTPA_Create
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTPA_Create
    @CompanyId              INT = 1,
    @Branch_ID              INT,
    @Type                   NVARCHAR(50),
    @Name                   NVARCHAR(200),
    @Code                   NVARCHAR(50),
    @SchemeName             NVARCHAR(200) = NULL,
    @PolicyPrefix           NVARCHAR(50) = NULL,
    @NetworkCategory        NVARCHAR(50),
    @AuthorizationRequired  BIT = 1,
    @ContactPerson          NVARCHAR(150) = NULL,
    @ContactNumber          NVARCHAR(20) = NULL,
    @Email                  NVARCHAR(150) = NULL,
    @Status                 BIT = 1,
    @CreatedBy              INT = NULL,
    @NewInsuranceTPA_ID     INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Generate PolicyPrefix if not provided
    IF @PolicyPrefix IS NULL OR LTRIM(RTRIM(@PolicyPrefix)) = ''
    BEGIN
        DECLARE @NextNum INT;
        SELECT @NextNum = ISNULL(MAX(InsuranceTPA_ID), 0) + 1 FROM dbo.InsuranceTPAMaster;
        
        DECLARE @TypeShort NVARCHAR(10);
        SET @TypeShort = CASE WHEN @Type LIKE '%TPA%' THEN 'TPA' ELSE 'INS' END;
        
        SET @PolicyPrefix = 'POL-' + @TypeShort + '-' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
    END

    -- Ensure Code uppercase
    SET @Code = UPPER(LTRIM(RTRIM(@Code)));

    INSERT INTO dbo.InsuranceTPAMaster
    (
        CompanyId,
        Branch_ID,
        Type,
        Name,
        Code,
        SchemeName,
        PolicyPrefix,
        NetworkCategory,
        AuthorizationRequired,
        ContactPerson,
        ContactNumber,
        Email,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Branch_ID,
        @Type,
        @Name,
        @Code,
        @SchemeName,
        @PolicyPrefix,
        @NetworkCategory,
        @AuthorizationRequired,
        @ContactPerson,
        @ContactNumber,
        @Email,
        @Status,
        @CreatedBy,
        GETDATE()
    );

    SET @NewInsuranceTPA_ID = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_InsuranceTPA_Update
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTPA_Update
    @InsuranceTPA_ID        INT,
    @Branch_ID              INT,
    @Type                   NVARCHAR(50),
    @Name                   NVARCHAR(200),
    @Code                   NVARCHAR(50),
    @SchemeName             NVARCHAR(200) = NULL,
    @PolicyPrefix           NVARCHAR(50),
    @NetworkCategory        NVARCHAR(50),
    @AuthorizationRequired  BIT = 1,
    @ContactPerson          NVARCHAR(150) = NULL,
    @ContactNumber          NVARCHAR(20) = NULL,
    @Email                  NVARCHAR(150) = NULL,
    @Status                 BIT = 1,
    @ModifiedBy             INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Ensure Code uppercase
    SET @Code = UPPER(LTRIM(RTRIM(@Code)));

    UPDATE dbo.InsuranceTPAMaster
    SET
        Branch_ID              = @Branch_ID,
        Type                   = @Type,
        Name                   = @Name,
        Code                   = @Code,
        SchemeName             = @SchemeName,
        PolicyPrefix           = @PolicyPrefix,
        NetworkCategory        = @NetworkCategory,
        AuthorizationRequired  = @AuthorizationRequired,
        ContactPerson          = @ContactPerson,
        ContactNumber          = @ContactNumber,
        Email                  = @Email,
        Status                 = @Status,
        ModifiedBy             = @ModifiedBy,
        ModifiedDate           = GETDATE()
    WHERE InsuranceTPA_ID      = @InsuranceTPA_ID;
END
GO

-- 6. Stored Procedure: usp_InsuranceTPA_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTPA_ToggleStatus
    @InsuranceTPA_ID INT,
    @ModifiedBy      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.InsuranceTPAMaster
    SET 
        Status = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedBy = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE InsuranceTPA_ID = @InsuranceTPA_ID;

    SELECT Status FROM dbo.InsuranceTPAMaster WHERE InsuranceTPA_ID = @InsuranceTPA_ID;
END
GO

-- 7. Stored Procedure: usp_InsuranceTPA_Delete
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTPA_Delete
    @InsuranceTPA_ID INT,
    @ModifiedBy      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.InsuranceTPAMaster
    WHERE InsuranceTPA_ID = @InsuranceTPA_ID;
END
GO

-- 8. Seed Sample Insurance Company & TPA Records for Primary Branches
IF NOT EXISTS (SELECT 1 FROM dbo.InsuranceTPAMaster)
BEGIN
    DECLARE @DefaultBranch INT;
    SELECT TOP 1 @DefaultBranch = BranchID FROM dbo.Branchmaster ORDER BY BranchID;

    IF @DefaultBranch IS NOT NULL
    BEGIN
        INSERT INTO dbo.InsuranceTPAMaster
        (
            CompanyId, Branch_ID, Type, Name, Code, SchemeName, PolicyPrefix,
            NetworkCategory, AuthorizationRequired, ContactPerson, ContactNumber, Email, Status, CreatedDate
        )
        VALUES
        (
            1, @DefaultBranch, 'Insurance Company', 'Star Health and Allied Insurance Co Ltd', 'INS-STAR01',
            'Family Health Optima Insurance Plan', 'POL-STAR-0001', 'Both', 1,
            'Sanjay Mukherjee (Claims Desk)', '9830112233', 'hospitaldesk@starhealth.in', 1, GETDATE()
        ),
        (
            1, @DefaultBranch, 'TPA', 'Medi Assist Healthcare Services TPA Pvt Ltd', 'TPA-MEDI01',
            'Medi Assist Corporate & Retail Network', 'POL-MEDI-0002', 'Cashless', 1,
            'Ananya Roy (Pre-Auth Lead)', '9831223344', 'preauth@mediassist.in', 1, GETDATE()
        ),
        (
            1, @DefaultBranch, 'Insurance Company', 'HDFC ERGO General Insurance Co Ltd', 'INS-HDFC01',
            'Optima Secure Health Policy', 'POL-HDFC-0003', 'Both', 1,
            'Vikram Sen (Institutional Head)', '9832334455', 'claims.support@hdfcergo.com', 1, GETDATE()
        ),
        (
            1, @DefaultBranch, 'TPA', 'Paramount Health Services & Insurance TPA Pvt Ltd', 'TPA-PARA01',
            'Paramount Institutional Cashless Scheme', 'POL-PARA-0004', 'Both', 1,
            'Debasish Roy (TPA Desk)', '9833445566', 'desk@paramounttpa.com', 1, GETDATE()
        ),
        (
            1, @DefaultBranch, 'Insurance Company', 'Care Health Insurance Ltd', 'INS-CARE01',
            'Care Supreme Comprehensive Coverage', 'POL-CARE-0005', 'Reimbursement', 0,
            'Pooja Sen (Customer Relations)', '9834556677', 'claims@careinsurance.com', 1, GETDATE()
        );
        PRINT 'Sample Insurance / TPA Master records seeded successfully.';
    END
END
GO
