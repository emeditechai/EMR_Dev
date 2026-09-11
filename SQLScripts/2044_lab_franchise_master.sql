-- ====================================================================================================
-- Script: 2044_lab_franchise_master.sql
-- Description: Creates dbo.LabFranchiseMaster and dbo.LabFranchiseCreditLimitMaster tables 
--              and Stored Procedures for Franchise Master CRUD operations under Masters > Lab (Franchise Setup).
-- Database:    Dev_EMR (SQL Server)
-- ====================================================================================================

USE Dev_EMR;
GO

-- 1. Create dbo.LabFranchiseMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabFranchiseMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabFranchiseMaster
    (
        Franchise_ID          INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId             INT NOT NULL DEFAULT 1,
        Franchise_Code        NVARCHAR(50) NOT NULL UNIQUE,
        Franchise_Name        NVARCHAR(100) NOT NULL,
        Mobile_No             NVARCHAR(20) NOT NULL,
        Email                 NVARCHAR(200) NULL,
        Franchise_Type        INT NOT NULL, -- 1: Collection Center, 2: Franchise Lab, 3: Pickup Point, 4: Marketing
        Parent_Branch_ID      INT NOT NULL,
        Onboarding_Date       DATE NULL,
        Go_Live_Date          DATE NULL,
        Agreement_Doc_Path    NVARCHAR(500) NULL,
        Agreement_Valid_From  DATE NULL,
        Agreement_Valid_To    DATE NULL,
        Status                BIT NOT NULL DEFAULT 0, -- Is Suspended bit: 0 = Active/No, 1 = Suspended
        Suspension_Reason     NVARCHAR(500) NULL,
        IsActive              BIT NOT NULL DEFAULT 1,
        IsDeleted             BIT NOT NULL DEFAULT 0,
        CreatedBy             INT NULL,
        CreatedDate           DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy            INT NULL,
        ModifiedDate          DATETIME2 NULL
    );
    CREATE INDEX IX_LabFranchiseMaster_CompanyId ON dbo.LabFranchiseMaster(CompanyId);
    CREATE INDEX IX_LabFranchiseMaster_ParentBranch ON dbo.LabFranchiseMaster(Parent_Branch_ID);
    CREATE INDEX IX_LabFranchiseMaster_IsActive ON dbo.LabFranchiseMaster(IsActive);
    PRINT 'Created table dbo.LabFranchiseMaster';
END
ELSE
BEGIN
    -- Ensure columns exist if table was created earlier
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabFranchiseMaster') AND name = 'Mobile_No')
        ALTER TABLE dbo.LabFranchiseMaster ADD Mobile_No NVARCHAR(20) NOT NULL DEFAULT '';

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabFranchiseMaster') AND name = 'Email')
        ALTER TABLE dbo.LabFranchiseMaster ADD Email NVARCHAR(200) NULL;

    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabFranchiseMaster') AND name = 'Servicing_Lab_ID')
        ALTER TABLE dbo.LabFranchiseMaster DROP COLUMN Servicing_Lab_ID;

    PRINT 'Updated table dbo.LabFranchiseMaster structure';
END
GO

-- 2. Create dbo.LabFranchiseCreditLimitMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabFranchiseCreditLimitMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabFranchiseCreditLimitMaster
    (
        Credit_ID                      INT IDENTITY(1,1) PRIMARY KEY,
        Franchise_ID                   INT NOT NULL,
        Credit_Facility_Type           INT NOT NULL, -- 1: Prepaid (Wallet), 2: Postpaid (Credit), 3: Hybrid
        Credit_Limit                   DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        Credit_Days                    INT NULL,
        Grace_Days                     INT NOT NULL DEFAULT 0,
        Security_Deposit_Amount        DECIMAL(18,2) NULL,
        Security_Deposit_Received_On   DATE NULL,
        Interest_On_Overdue_Percent    DECIMAL(5,2) NULL,
        Temporary_Limit_Increase       DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        Temp_Limit_Valid_Till          DATE NULL,
        CreatedBy                      INT NULL,
        CreatedDate                    DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy                     INT NULL,
        ModifiedDate                   DATETIME2 NULL,
        CONSTRAINT FK_LabFranchiseCreditLimit_Franchise FOREIGN KEY (Franchise_ID) REFERENCES dbo.LabFranchiseMaster(Franchise_ID) ON DELETE CASCADE
    );
    CREATE INDEX IX_LabFranchiseCreditLimit_FranchiseID ON dbo.LabFranchiseCreditLimitMaster(Franchise_ID);
    PRINT 'Created table dbo.LabFranchiseCreditLimitMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.LabFranchiseCreditLimitMaster already exists';
END
GO

-- Seed sample data if empty
IF NOT EXISTS (SELECT 1 FROM dbo.LabFranchiseMaster WHERE IsDeleted = 0)
BEGIN
    DECLARE @DefaultBranch INT;
    SELECT TOP 1 @DefaultBranch = BranchID FROM dbo.Branchmaster WHERE IsActive = 1 ORDER BY BranchID ASC;
    IF @DefaultBranch IS NULL SET @DefaultBranch = 1;

    INSERT INTO dbo.LabFranchiseMaster
    (CompanyId, Franchise_Code, Franchise_Name, Mobile_No, Email, Franchise_Type, Parent_Branch_ID, Onboarding_Date, Go_Live_Date, Agreement_Valid_From, Agreement_Valid_To, Status, IsActive, CreatedDate)
    VALUES
    (1, 'FRN0001', 'Metro Healthcare Collection Center', '9876543210', 'contact@metrohealthcare.com', 1, @DefaultBranch, '2025-01-15', '2025-02-01', '2025-01-15', '2027-01-14', 0, 1, GETDATE()),
    (1, 'FRN0002', 'CityCare Diagnostic Franchise Lab', '9123456789', 'info@citycarelab.com', 2, @DefaultBranch, '2025-03-10', '2025-04-01', '2025-03-10', '2028-03-09', 0, 1, GETDATE());

    DECLARE @Frn1 INT = (SELECT Franchise_ID FROM dbo.LabFranchiseMaster WHERE Franchise_Code = 'FRN0001');
    DECLARE @Frn2 INT = (SELECT Franchise_ID FROM dbo.LabFranchiseMaster WHERE Franchise_Code = 'FRN0002');

    IF @Frn1 IS NOT NULL
    BEGIN
        INSERT INTO dbo.LabFranchiseCreditLimitMaster
        (Franchise_ID, Credit_Facility_Type, Credit_Limit, Credit_Days, Grace_Days, Security_Deposit_Amount, Security_Deposit_Received_On, Interest_On_Overdue_Percent, Temporary_Limit_Increase, CreatedDate)
        VALUES
        (@Frn1, 2, 50000.00, 30, 7, 10000.00, '2025-01-10', 2.50, 0.00, GETDATE());
    END

    IF @Frn2 IS NOT NULL
    BEGIN
        INSERT INTO dbo.LabFranchiseCreditLimitMaster
        (Franchise_ID, Credit_Facility_Type, Credit_Limit, Credit_Days, Grace_Days, Security_Deposit_Amount, Security_Deposit_Received_On, Interest_On_Overdue_Percent, Temporary_Limit_Increase, CreatedDate)
        VALUES
        (@Frn2, 1, 100000.00, 0, 0, 25000.00, '2025-03-05', 0.00, 10000.00, GETDATE());
    END

    PRINT 'Seeded initial sample data into dbo.LabFranchiseMaster and dbo.LabFranchiseCreditLimitMaster';
END
GO

-- 3. Stored Procedure: usp_Api_LabFranchiseMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseMaster_GetList
    @Status           BIT = NULL, -- Is Suspended filter
    @IsActive         BIT = NULL, -- IsActive filter
    @Search           NVARCHAR(100) = NULL,
    @CompanyId        INT = NULL,
    @FranchiseType    INT = NULL,
    @ParentBranchId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        f.Franchise_ID,
        f.CompanyId,
        f.Franchise_Code,
        f.Franchise_Name,
        ISNULL(f.Mobile_No, '') AS Mobile_No,
        f.Email,
        f.Franchise_Type,
        CASE f.Franchise_Type
            WHEN 1 THEN 'Collection Center'
            WHEN 2 THEN 'Franchise Lab'
            WHEN 3 THEN 'Pickup Point'
            WHEN 4 THEN 'Marketing'
            ELSE 'Unknown'
        END AS Franchise_Type_Name,
        f.Parent_Branch_ID,
        pb.BranchName AS Parent_Branch_Name,
        f.Onboarding_Date,
        f.Go_Live_Date,
        f.Agreement_Doc_Path,
        f.Agreement_Valid_From,
        f.Agreement_Valid_To,
        f.Status,
        f.Suspension_Reason,
        f.IsActive,
        f.CreatedBy,
        f.CreatedDate,
        f.ModifiedBy,
        f.ModifiedDate,

        -- Credit Limit Details
        c.Credit_ID,
        ISNULL(c.Credit_Facility_Type, 1) AS Credit_Facility_Type,
        CASE c.Credit_Facility_Type
            WHEN 1 THEN 'Prepaid (Wallet)'
            WHEN 2 THEN 'Postpaid (Credit)'
            WHEN 3 THEN 'Hybrid'
            ELSE 'Prepaid (Wallet)'
        END AS Credit_Facility_Type_Name,
        ISNULL(c.Credit_Limit, 0.00) AS Credit_Limit,
        c.Credit_Days,
        ISNULL(c.Grace_Days, 0) AS Grace_Days,
        c.Security_Deposit_Amount,
        c.Security_Deposit_Received_On,
        c.Interest_On_Overdue_Percent,
        ISNULL(c.Temporary_Limit_Increase, 0.00) AS Temporary_Limit_Increase,
        c.Temp_Limit_Valid_Till
    FROM dbo.LabFranchiseMaster f
    LEFT JOIN dbo.Branchmaster pb ON f.Parent_Branch_ID = pb.BranchID
    LEFT JOIN dbo.LabFranchiseCreditLimitMaster c ON f.Franchise_ID = c.Franchise_ID
    WHERE f.IsDeleted = 0
      AND (@Status IS NULL OR f.Status = @Status)
      AND (@IsActive IS NULL OR f.IsActive = @IsActive)
      AND (@CompanyId IS NULL OR f.CompanyId = @CompanyId)
      AND (@FranchiseType IS NULL OR f.Franchise_Type = @FranchiseType)
      AND (@ParentBranchId IS NULL OR f.Parent_Branch_ID = @ParentBranchId)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR 
           f.Franchise_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR 
           f.Franchise_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           f.Mobile_No LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           f.Email LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY f.Franchise_ID DESC;
END
GO

-- 4. Stored Procedure: usp_Api_LabFranchiseMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseMaster_GetById
    @Franchise_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        f.Franchise_ID,
        f.CompanyId,
        f.Franchise_Code,
        f.Franchise_Name,
        ISNULL(f.Mobile_No, '') AS Mobile_No,
        f.Email,
        f.Franchise_Type,
        CASE f.Franchise_Type
            WHEN 1 THEN 'Collection Center'
            WHEN 2 THEN 'Franchise Lab'
            WHEN 3 THEN 'Pickup Point'
            WHEN 4 THEN 'Marketing'
            ELSE 'Unknown'
        END AS Franchise_Type_Name,
        f.Parent_Branch_ID,
        pb.BranchName AS Parent_Branch_Name,
        f.Onboarding_Date,
        f.Go_Live_Date,
        f.Agreement_Doc_Path,
        f.Agreement_Valid_From,
        f.Agreement_Valid_To,
        f.Status,
        f.Suspension_Reason,
        f.IsActive,
        f.CreatedBy,
        f.CreatedDate,
        f.ModifiedBy,
        f.ModifiedDate,

        -- Credit Limit Details
        c.Credit_ID,
        ISNULL(c.Credit_Facility_Type, 1) AS Credit_Facility_Type,
        CASE c.Credit_Facility_Type
            WHEN 1 THEN 'Prepaid (Wallet)'
            WHEN 2 THEN 'Postpaid (Credit)'
            WHEN 3 THEN 'Hybrid'
            ELSE 'Prepaid (Wallet)'
        END AS Credit_Facility_Type_Name,
        ISNULL(c.Credit_Limit, 0.00) AS Credit_Limit,
        c.Credit_Days,
        ISNULL(c.Grace_Days, 0) AS Grace_Days,
        c.Security_Deposit_Amount,
        c.Security_Deposit_Received_On,
        c.Interest_On_Overdue_Percent,
        ISNULL(c.Temporary_Limit_Increase, 0.00) AS Temporary_Limit_Increase,
        c.Temp_Limit_Valid_Till
    FROM dbo.LabFranchiseMaster f
    LEFT JOIN dbo.Branchmaster pb ON f.Parent_Branch_ID = pb.BranchID
    LEFT JOIN dbo.LabFranchiseCreditLimitMaster c ON f.Franchise_ID = c.Franchise_ID
    WHERE f.Franchise_ID = @Franchise_ID AND f.IsDeleted = 0;
END
GO

-- 5. Stored Procedure: usp_Api_LabFranchiseMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseMaster_Create
    @CompanyId                      INT = 1,
    @Franchise_Name                 NVARCHAR(100),
    @Mobile_No                      NVARCHAR(20),
    @Email                          NVARCHAR(200) = NULL,
    @Franchise_Type                 INT,
    @Parent_Branch_ID               INT,
    @Onboarding_Date                DATE = NULL,
    @Go_Live_Date                   DATE = NULL,
    @Agreement_Doc_Path             NVARCHAR(500) = NULL,
    @Agreement_Valid_From           DATE = NULL,
    @Agreement_Valid_To             DATE = NULL,
    @Status                         BIT = 0, -- Is Suspended
    @IsActive                       BIT = 1,
    -- Credit Limit fields
    @Credit_Facility_Type           INT = 1,
    @Credit_Limit                   DECIMAL(18,2) = 0.00,
    @Credit_Days                    INT = NULL,
    @Grace_Days                     INT = 0,
    @Security_Deposit_Amount        DECIMAL(18,2) = NULL,
    @Security_Deposit_Received_On   DATE = NULL,
    @Interest_On_Overdue_Percent    DECIMAL(5,2) = NULL,
    @Temporary_Limit_Increase       DECIMAL(18,2) = 0.00,
    @Temp_Limit_Valid_Till          DATE = NULL,
    @UserId                         INT = NULL,
    @NewId                          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRANSACTION;

    BEGIN TRY
        IF @Franchise_Name IS NULL OR LTRIM(RTRIM(@Franchise_Name)) = ''
        BEGIN
            RAISERROR('Franchise Name is required.', 16, 1);
        END

        IF @Mobile_No IS NULL OR LTRIM(RTRIM(@Mobile_No)) = ''
        BEGIN
            RAISERROR('Mobile Number is required.', 16, 1);
        END

        SET @Franchise_Name = LTRIM(RTRIM(@Franchise_Name));
        SET @Mobile_No = LTRIM(RTRIM(@Mobile_No));
        SET @Email = LTRIM(RTRIM(@Email));

        IF EXISTS (
            SELECT 1 FROM dbo.LabFranchiseMaster 
            WHERE LOWER(Franchise_Name) = LOWER(@Franchise_Name)
              AND CompanyId = @CompanyId
              AND IsDeleted = 0
        )
        BEGIN
            RAISERROR('A Franchise with the same name already exists.', 16, 1);
        END

        -- Generate Unique Franchise Code
        DECLARE @NextNum INT;
        DECLARE @GeneratedCode NVARCHAR(50);

        SELECT @NextNum = ISNULL(MAX(Franchise_ID), 0) + 1 FROM dbo.LabFranchiseMaster;
        SET @GeneratedCode = 'FRN' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);

        WHILE EXISTS (SELECT 1 FROM dbo.LabFranchiseMaster WHERE Franchise_Code = @GeneratedCode)
        BEGIN
            SET @NextNum = @NextNum + 1;
            SET @GeneratedCode = 'FRN' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
        END

        INSERT INTO dbo.LabFranchiseMaster
        (
            CompanyId,
            Franchise_Code,
            Franchise_Name,
            Mobile_No,
            Email,
            Franchise_Type,
            Parent_Branch_ID,
            Onboarding_Date,
            Go_Live_Date,
            Agreement_Doc_Path,
            Agreement_Valid_From,
            Agreement_Valid_To,
            Status,
            IsActive,
            IsDeleted,
            CreatedBy,
            CreatedDate
        )
        VALUES
        (
            @CompanyId,
            @GeneratedCode,
            @Franchise_Name,
            @Mobile_No,
            @Email,
            @Franchise_Type,
            @Parent_Branch_ID,
            @Onboarding_Date,
            @Go_Live_Date,
            @Agreement_Doc_Path,
            @Agreement_Valid_From,
            @Agreement_Valid_To,
            ISNULL(@Status, 0),
            ISNULL(@IsActive, 1),
            0,
            @UserId,
            GETDATE()
        );

        SET @NewId = SCOPE_IDENTITY();

        -- Insert Credit Limit
        INSERT INTO dbo.LabFranchiseCreditLimitMaster
        (
            Franchise_ID,
            Credit_Facility_Type,
            Credit_Limit,
            Credit_Days,
            Grace_Days,
            Security_Deposit_Amount,
            Security_Deposit_Received_On,
            Interest_On_Overdue_Percent,
            Temporary_Limit_Increase,
            Temp_Limit_Valid_Till,
            CreatedBy,
            CreatedDate
        )
        VALUES
        (
            @NewId,
            ISNULL(@Credit_Facility_Type, 1),
            ISNULL(@Credit_Limit, 0.00),
            @Credit_Days,
            ISNULL(@Grace_Days, 0),
            @Security_Deposit_Amount,
            @Security_Deposit_Received_On,
            @Interest_On_Overdue_Percent,
            ISNULL(@Temporary_Limit_Increase, 0.00),
            @Temp_Limit_Valid_Till,
            @UserId,
            GETDATE()
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- 6. Stored Procedure: usp_Api_LabFranchiseMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseMaster_Update
    @Franchise_ID                   INT,
    @Franchise_Name                 NVARCHAR(100),
    @Mobile_No                      NVARCHAR(20),
    @Email                          NVARCHAR(200) = NULL,
    @Franchise_Type                 INT,
    @Parent_Branch_ID               INT,
    @Onboarding_Date                DATE = NULL,
    @Go_Live_Date                   DATE = NULL,
    @Agreement_Doc_Path             NVARCHAR(500) = NULL,
    @Agreement_Valid_From           DATE = NULL,
    @Agreement_Valid_To             DATE = NULL,
    @Status                         BIT = 0,
    @IsActive                       BIT = 1,
    -- Credit Limit fields
    @Credit_Facility_Type           INT = 1,
    @Credit_Limit                   DECIMAL(18,2) = 0.00,
    @Credit_Days                    INT = NULL,
    @Grace_Days                     INT = 0,
    @Security_Deposit_Amount        DECIMAL(18,2) = NULL,
    @Security_Deposit_Received_On   DATE = NULL,
    @Interest_On_Overdue_Percent    DECIMAL(5,2) = NULL,
    @Temporary_Limit_Increase       DECIMAL(18,2) = 0.00,
    @Temp_Limit_Valid_Till          DATE = NULL,
    @UserId                         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRANSACTION;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @Franchise_ID AND IsDeleted = 0)
        BEGIN
            RAISERROR('Franchise record not found.', 16, 1);
        END

        IF @Franchise_Name IS NULL OR LTRIM(RTRIM(@Franchise_Name)) = ''
        BEGIN
            RAISERROR('Franchise Name is required.', 16, 1);
        END

        IF @Mobile_No IS NULL OR LTRIM(RTRIM(@Mobile_No)) = ''
        BEGIN
            RAISERROR('Mobile Number is required.', 16, 1);
        END

        SET @Franchise_Name = LTRIM(RTRIM(@Franchise_Name));
        SET @Mobile_No = LTRIM(RTRIM(@Mobile_No));
        SET @Email = LTRIM(RTRIM(@Email));

        IF EXISTS (
            SELECT 1 FROM dbo.LabFranchiseMaster 
            WHERE LOWER(Franchise_Name) = LOWER(@Franchise_Name)
              AND Franchise_ID <> @Franchise_ID
              AND IsDeleted = 0
        )
        BEGIN
            RAISERROR('A Franchise with the same name already exists.', 16, 1);
        END

        UPDATE dbo.LabFranchiseMaster
        SET Franchise_Name        = @Franchise_Name,
            Mobile_No             = @Mobile_No,
            Email                 = @Email,
            Franchise_Type        = @Franchise_Type,
            Parent_Branch_ID      = @Parent_Branch_ID,
            Onboarding_Date       = @Onboarding_Date,
            Go_Live_Date          = @Go_Live_Date,
            Agreement_Doc_Path    = ISNULL(@Agreement_Doc_Path, Agreement_Doc_Path),
            Agreement_Valid_From  = @Agreement_Valid_From,
            Agreement_Valid_To    = @Agreement_Valid_To,
            Status                = ISNULL(@Status, 0),
            IsActive              = ISNULL(@IsActive, 1),
            ModifiedBy            = @UserId,
            ModifiedDate          = GETDATE()
        WHERE Franchise_ID = @Franchise_ID;

        -- Update or Insert Credit Limit
        IF EXISTS (SELECT 1 FROM dbo.LabFranchiseCreditLimitMaster WHERE Franchise_ID = @Franchise_ID)
        BEGIN
            UPDATE dbo.LabFranchiseCreditLimitMaster
            SET Credit_Facility_Type          = ISNULL(@Credit_Facility_Type, 1),
                Credit_Limit                  = ISNULL(@Credit_Limit, 0.00),
                Credit_Days                   = @Credit_Days,
                Grace_Days                    = ISNULL(@Grace_Days, 0),
                Security_Deposit_Amount       = @Security_Deposit_Amount,
                Security_Deposit_Received_On  = @Security_Deposit_Received_On,
                Interest_On_Overdue_Percent   = @Interest_On_Overdue_Percent,
                Temporary_Limit_Increase      = ISNULL(@Temporary_Limit_Increase, 0.00),
                Temp_Limit_Valid_Till         = @Temp_Limit_Valid_Till,
                ModifiedBy                    = @UserId,
                ModifiedDate                  = GETDATE()
            WHERE Franchise_ID = @Franchise_ID;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.LabFranchiseCreditLimitMaster
            (
                Franchise_ID,
                Credit_Facility_Type,
                Credit_Limit,
                Credit_Days,
                Grace_Days,
                Security_Deposit_Amount,
                Security_Deposit_Received_On,
                Interest_On_Overdue_Percent,
                Temporary_Limit_Increase,
                Temp_Limit_Valid_Till,
                CreatedBy,
                CreatedDate
            )
            VALUES
            (
                @Franchise_ID,
                ISNULL(@Credit_Facility_Type, 1),
                ISNULL(@Credit_Limit, 0.00),
                @Credit_Days,
                ISNULL(@Grace_Days, 0),
                @Security_Deposit_Amount,
                @Security_Deposit_Received_On,
                @Interest_On_Overdue_Percent,
                ISNULL(@Temporary_Limit_Increase, 0.00),
                @Temp_Limit_Valid_Till,
                @UserId,
                GETDATE()
            );
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- 7. Stored Procedure: usp_Api_LabFranchiseMaster_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseMaster_ToggleStatus
    @Franchise_ID INT,
    @IsActive     BIT,
    @UserId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @Franchise_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Franchise record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabFranchiseMaster
    SET IsActive     = @IsActive,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE Franchise_ID = @Franchise_ID;
END
GO

-- 8. Stored Procedure: usp_Api_LabFranchiseMaster_ToggleSuspension
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseMaster_ToggleSuspension
    @Franchise_ID      INT,
    @Status            BIT, -- 1 = Suspended, 0 = Active
    @Suspension_Reason NVARCHAR(500) = NULL,
    @UserId            INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @Franchise_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Franchise record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabFranchiseMaster
    SET Status            = @Status,
        Suspension_Reason = CASE WHEN @Status = 1 THEN @Suspension_Reason ELSE NULL END,
        ModifiedBy        = @UserId,
        ModifiedDate      = GETDATE()
    WHERE Franchise_ID = @Franchise_ID;
END
GO

-- 9. Stored Procedure: usp_Api_LabFranchiseMaster_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseMaster_Delete
    @Franchise_ID INT,
    @UserId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @Franchise_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Franchise record not found or already deleted.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabFranchiseMaster
    SET IsDeleted = 1,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
    WHERE Franchise_ID = @Franchise_ID;
END
GO

PRINT 'Updated SQL objects for Lab Franchise Master (Mobile_No, Email added, Servicing_Lab_ID removed).';
