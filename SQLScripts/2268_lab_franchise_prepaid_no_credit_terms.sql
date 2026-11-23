-- ============================================================================
-- Migration: 2268_lab_franchise_prepaid_no_credit_terms.sql
-- Franchise Setup: the credit facility is Prepaid (Wallet) or Postpaid (Credit) - Hybrid is removed.
-- For a prepaid franchise the Create / Update procedures drop the credit terms (limit, credit days, grace days,
-- security deposit, interest, temporary limit), so the save never fails on an empty field and the screens,
-- the API and the Excel bulk upload all store the same thing.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
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
    @IsNotificationRequired         BIT = 0,
    @PreprintedBarcode              BIT = 1,
    @IsReportHeaderRequired         BIT = 0,
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
    -- Credit facility is Prepaid (Wallet) or Postpaid (Credit) only. A prepaid franchise has no credit terms: whatever
    -- was sent for them is dropped, so the row always saves (the NOT NULL columns get 0, the rest stay empty).
    SET @Credit_Facility_Type = ISNULL(@Credit_Facility_Type, 1);
    IF @Credit_Facility_Type NOT IN (1, 2)
        THROW 50020, 'Credit Facility Type must be Prepaid (Wallet) or Postpaid (Credit).', 1;
    IF @Credit_Facility_Type = 1
    BEGIN
        SET @Credit_Limit = 0; SET @Credit_Days = NULL; SET @Grace_Days = 0;
        SET @Security_Deposit_Amount = NULL; SET @Security_Deposit_Received_On = NULL; SET @Interest_On_Overdue_Percent = NULL;
        SET @Temporary_Limit_Increase = 0; SET @Temp_Limit_Valid_Till = NULL;
    END

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
            IsNotificationRequired,
            PreprintedBarcode,
            IsReportHeaderRequired,
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
            ISNULL(@IsNotificationRequired, 0),
            ISNULL(@PreprintedBarcode, 1),
            ISNULL(@IsReportHeaderRequired, 0),
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
    @IsNotificationRequired         BIT = 0,
    @PreprintedBarcode              BIT = 1,
    @IsReportHeaderRequired         BIT = 0,
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
    -- Credit facility is Prepaid (Wallet) or Postpaid (Credit) only. A prepaid franchise has no credit terms: whatever
    -- was sent for them is dropped, so the row always saves (the NOT NULL columns get 0, the rest stay empty).
    SET @Credit_Facility_Type = ISNULL(@Credit_Facility_Type, 1);
    IF @Credit_Facility_Type NOT IN (1, 2)
        THROW 50020, 'Credit Facility Type must be Prepaid (Wallet) or Postpaid (Credit).', 1;
    IF @Credit_Facility_Type = 1
    BEGIN
        SET @Credit_Limit = 0; SET @Credit_Days = NULL; SET @Grace_Days = 0;
        SET @Security_Deposit_Amount = NULL; SET @Security_Deposit_Received_On = NULL; SET @Interest_On_Overdue_Percent = NULL;
        SET @Temporary_Limit_Increase = 0; SET @Temp_Limit_Valid_Till = NULL;
    END

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
            IsNotificationRequired = ISNULL(@IsNotificationRequired, 0),
            PreprintedBarcode     = ISNULL(@PreprintedBarcode, 1),
            IsReportHeaderRequired = ISNULL(@IsReportHeaderRequired, 0),
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
