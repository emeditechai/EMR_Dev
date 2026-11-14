-- ============================================================================
-- Migration: 2456_lab_masters_duplicate_check_per_company.sql
-- Lab masters: the "already exists" checks now look only at the record's own company (as Investigation, 2455).
-- usp_Company_CopyLabMasters copies these masters to a new company with the same names (and departments), so a
-- company-wide check made the source company's records fail to save, and blocked a second company from using a name.
--   Sample Type, Test Category, Test Method : Create (scoped to @CompanyId) and Update
--   Sample Rejection, Sample Rejection Reason, Franchise : Update (their Create was already per company)
--   Update checks are scoped to the edited record's CompanyId.
-- Procedures are the live definitions with only that condition added. Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 4. Stored Procedure: usp_Api_LabSampleTypeMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleTypeMaster_Create
    @Sample_Name         NVARCHAR(150),
    @Container_Type      NVARCHAR(100),
    @Volume_Value        DECIMAL(10, 2),
    @Unit_ID             INT = NULL,
    @Volume_Unit         NVARCHAR(50) = NULL,
    @Storage_Temperature NVARCHAR(50) = NULL,
    @Rejection_Criteria  NVARCHAR(500) = NULL,
    @Display_Order       INT = 1,
    @CompanyId           INT = 1,
    @UserId              INT = NULL,
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @Sample_Name IS NULL OR LTRIM(RTRIM(@Sample_Name)) = ''
    BEGIN
        RAISERROR('Sample Name is required.', 16, 1);
        RETURN;
    END

    IF @Container_Type IS NULL OR LTRIM(RTRIM(@Container_Type)) = ''
    BEGIN
        RAISERROR('Container Type is required.', 16, 1);
        RETURN;
    END

    IF @Volume_Value IS NULL OR @Volume_Value <= 0
    BEGIN
        RAISERROR('Volume Value must be greater than zero.', 16, 1);
        RETURN;
    END

    IF @Unit_ID IS NOT NULL AND @Unit_ID > 0
    BEGIN
        SELECT @Volume_Unit = ISNULL(NULLIF(LTRIM(RTRIM(Unit_Symbol)), ''), Unit_Name)
        FROM dbo.LabUnitMaster
        WHERE Unit_ID = @Unit_ID;
    END

    IF @Volume_Unit IS NULL OR LTRIM(RTRIM(@Volume_Unit)) = ''
    BEGIN
        SET @Volume_Unit = 'mL';
    END

    SET @Sample_Name = LTRIM(RTRIM(@Sample_Name));
    SET @Container_Type = LTRIM(RTRIM(@Container_Type));
    SET @Volume_Unit = LTRIM(RTRIM(@Volume_Unit));
    SET @Storage_Temperature = LTRIM(RTRIM(@Storage_Temperature));
    SET @Rejection_Criteria = LTRIM(RTRIM(@Rejection_Criteria));

    DECLARE @Volume_Required NVARCHAR(50) = CAST(CAST(@Volume_Value AS FLOAT) AS NVARCHAR(20)) + ' ' + @Volume_Unit;

    IF EXISTS (
        SELECT 1 FROM dbo.LabSampleTypeMaster 
        WHERE CompanyId = @CompanyId AND LOWER(Sample_Name) = LOWER(@Sample_Name)
          AND LOWER(Container_Type) = LOWER(@Container_Type)
          AND Volume_Value = @Volume_Value
          AND LOWER(Volume_Unit) = LOWER(@Volume_Unit)
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A Sample Type with the same Name, Container Type, and Volume already exists.', 16, 1);
        RETURN;
    END

    DECLARE @NextNum INT;
    DECLARE @GeneratedCode NVARCHAR(50);

    SELECT @NextNum = ISNULL(MAX(Sample_Type_ID), 0) + 1 FROM dbo.LabSampleTypeMaster;
    SET @GeneratedCode = 'SMP' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);

    WHILE EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Code = @GeneratedCode)
    BEGIN
        SET @NextNum = @NextNum + 1;
        SET @GeneratedCode = 'SMP' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
    END

    INSERT INTO dbo.LabSampleTypeMaster
    (
        CompanyId,
        Sample_Name,
        Sample_Code,
        Container_Type,
        Volume_Value,
        Unit_ID,
        Volume_Unit,
        Volume_Required,
        Storage_Temperature,
        Rejection_Criteria,
        Display_Order,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Sample_Name,
        @GeneratedCode,
        @Container_Type,
        @Volume_Value,
        @Unit_ID,
        @Volume_Unit,
        @Volume_Required,
        @Storage_Temperature,
        @Rejection_Criteria,
        ISNULL(@Display_Order, 1),
        1,
        @UserId,
        GETDATE()
    );

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_Api_LabSampleTypeMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleTypeMaster_Update
    @Sample_Type_ID      INT,
    @Sample_Name         NVARCHAR(150),
    @Container_Type      NVARCHAR(100),
    @Volume_Value        DECIMAL(10, 2),
    @Unit_ID             INT = NULL,
    @Volume_Unit         NVARCHAR(50) = NULL,
    @Storage_Temperature NVARCHAR(50) = NULL,
    @Rejection_Criteria  NVARCHAR(500) = NULL,
    @Display_Order       INT = 1,
    @Status              BIT = 1,
    @UserId              INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @Sample_Type_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Lab Sample Type record not found.', 16, 1);
        RETURN;
    END

    IF @Sample_Name IS NULL OR LTRIM(RTRIM(@Sample_Name)) = ''
    BEGIN
        RAISERROR('Sample Name is required.', 16, 1);
        RETURN;
    END

    IF @Container_Type IS NULL OR LTRIM(RTRIM(@Container_Type)) = ''
    BEGIN
        RAISERROR('Container Type is required.', 16, 1);
        RETURN;
    END

    IF @Volume_Value IS NULL OR @Volume_Value <= 0
    BEGIN
        RAISERROR('Volume Value must be greater than zero.', 16, 1);
        RETURN;
    END

    IF @Unit_ID IS NOT NULL AND @Unit_ID > 0
    BEGIN
        SELECT @Volume_Unit = ISNULL(NULLIF(LTRIM(RTRIM(Unit_Symbol)), ''), Unit_Name)
        FROM dbo.LabUnitMaster
        WHERE Unit_ID = @Unit_ID;
    END

    IF @Volume_Unit IS NULL OR LTRIM(RTRIM(@Volume_Unit)) = ''
    BEGIN
        SET @Volume_Unit = 'mL';
    END

    SET @Sample_Name = LTRIM(RTRIM(@Sample_Name));
    SET @Container_Type = LTRIM(RTRIM(@Container_Type));
    SET @Volume_Unit = LTRIM(RTRIM(@Volume_Unit));
    SET @Storage_Temperature = LTRIM(RTRIM(@Storage_Temperature));
    SET @Rejection_Criteria = LTRIM(RTRIM(@Rejection_Criteria));

    DECLARE @Volume_Required NVARCHAR(50) = CAST(CAST(@Volume_Value AS FLOAT) AS NVARCHAR(20)) + ' ' + @Volume_Unit;

    IF EXISTS (
        SELECT 1 FROM dbo.LabSampleTypeMaster 
        WHERE CompanyId = (SELECT CompanyId FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @Sample_Type_ID) AND LOWER(Sample_Name) = LOWER(@Sample_Name)
          AND LOWER(Container_Type) = LOWER(@Container_Type)
          AND Volume_Value = @Volume_Value
          AND LOWER(Volume_Unit) = LOWER(@Volume_Unit)
          AND Sample_Type_ID <> @Sample_Type_ID
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A Sample Type with the same Name, Container Type, and Volume already exists.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabSampleTypeMaster
    SET Sample_Name         = @Sample_Name,
        Container_Type      = @Container_Type,
        Volume_Value        = @Volume_Value,
        Unit_ID             = @Unit_ID,
        Volume_Unit         = @Volume_Unit,
        Volume_Required     = @Volume_Required,
        Storage_Temperature = @Storage_Temperature,
        Rejection_Criteria  = @Rejection_Criteria,
        Display_Order       = ISNULL(@Display_Order, 1),
        Status              = @Status,
        ModifiedBy          = @UserId,
        ModifiedDate        = GETDATE()
    WHERE Sample_Type_ID = @Sample_Type_ID;
END
GO

-- 4. Update dbo.usp_Api_LabTestCategoryMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestCategoryMaster_Create
    @Department_ID                INT,
    @Category_Name                NVARCHAR(150),
    @Display_Order                INT = 1,
    @CompanyId                    INT = 1,
    @UserId                       INT = NULL,
    @Is_Barcode_Required          BIT = 1,
    @Is_Sample_Collection_Required BIT = 1,
    @NewId                        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Mandatory Validations
    IF @Department_ID IS NULL OR @Department_ID <= 0
    BEGIN
        RAISERROR('Department is required.', 16, 1);
        RETURN;
    END

    -- Ensure selected Department is of Type LAB
    IF NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE DeptId = @Department_ID AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%'))
    BEGIN
        RAISERROR('Selected department must be a Lab department (Type=LAB).', 16, 1);
        RETURN;
    END

    IF @Category_Name IS NULL OR LTRIM(RTRIM(@Category_Name)) = ''
    BEGIN
        RAISERROR('Category Name is required.', 16, 1);
        RETURN;
    END

    SET @Category_Name = LTRIM(RTRIM(@Category_Name));

    -- Check duplicate category name within same department
    IF EXISTS (
        SELECT 1 FROM dbo.LabTestCategoryMaster 
        WHERE CompanyId = @CompanyId AND Department_ID = @Department_ID 
          AND LOWER(Category_Name) = LOWER(@Category_Name)
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A category with the same name already exists in this department.', 16, 1);
        RETURN;
    END

    -- Auto-generate Category_Code
    DECLARE @NextId INT;
    DECLARE @GeneratedCode NVARCHAR(50);

    SELECT @NextId = ISNULL(MAX(Category_ID), 0) + 1 FROM dbo.LabTestCategoryMaster;
    SET @GeneratedCode = 'LCAT' + RIGHT('0000' + CAST(@NextId AS NVARCHAR(10)), 4);

    INSERT INTO dbo.LabTestCategoryMaster
    (
        CompanyId,
        Department_ID,
        Category_Name,
        Category_Code,
        Display_Order,
        Status,
        Is_Barcode_Required,
        Is_Sample_Collection_Required,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Department_ID,
        @Category_Name,
        @GeneratedCode,
        ISNULL(@Display_Order, 1),
        1,
        ISNULL(@Is_Barcode_Required, 1),
        ISNULL(@Is_Sample_Collection_Required, 1),
        @UserId,
        GETDATE()
    );

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- 5. Update dbo.usp_Api_LabTestCategoryMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestCategoryMaster_Update
    @Category_ID                  INT,
    @Department_ID                INT,
    @Category_Name                NVARCHAR(150),
    @Display_Order                INT,
    @Status                       BIT,
    @UserId                       INT = NULL,
    @Is_Barcode_Required          BIT = 1,
    @Is_Sample_Collection_Required BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestCategoryMaster WHERE Category_ID = @Category_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Lab Test Category record not found.', 16, 1);
        RETURN;
    END

    -- Mandatory Validations
    IF @Department_ID IS NULL OR @Department_ID <= 0
    BEGIN
        RAISERROR('Department is required.', 16, 1);
        RETURN;
    END

    -- Ensure selected Department is of Type LAB
    IF NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE DeptId = @Department_ID AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%'))
    BEGIN
        RAISERROR('Selected department must be a Lab department (Type=LAB).', 16, 1);
        RETURN;
    END

    IF @Category_Name IS NULL OR LTRIM(RTRIM(@Category_Name)) = ''
    BEGIN
        RAISERROR('Category Name is required.', 16, 1);
        RETURN;
    END

    SET @Category_Name = LTRIM(RTRIM(@Category_Name));

    -- Duplicate check ignoring self
    IF EXISTS (
        SELECT 1 FROM dbo.LabTestCategoryMaster 
        WHERE CompanyId = (SELECT CompanyId FROM dbo.LabTestCategoryMaster WHERE Category_ID = @Category_ID) AND Department_ID = @Department_ID 
          AND LOWER(Category_Name) = LOWER(@Category_Name) 
          AND Category_ID <> @Category_ID
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A category with the same name already exists in this department.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabTestCategoryMaster
    SET Department_ID                = @Department_ID,
        Category_Name                = @Category_Name,
        Display_Order                = ISNULL(@Display_Order, 1),
        Status                       = @Status,
        Is_Barcode_Required          = ISNULL(@Is_Barcode_Required, 1),
        Is_Sample_Collection_Required = ISNULL(@Is_Sample_Collection_Required, 1),
        ModifiedBy                   = @UserId,
        ModifiedDate                 = GETDATE()
    WHERE Category_ID = @Category_ID;
END
GO

-- 4. Stored Procedure: usp_Api_LabTestMethodMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestMethodMaster_Create
    @Department_ID      INT,
    @Method_Name        NVARCHAR(150),
    @Display_Order      INT = 1,
    @CompanyId          INT = 1,
    @UserId             INT = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @Department_ID IS NULL OR @Department_ID <= 0
    BEGIN
        RAISERROR('Department is required.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE DeptId = @Department_ID AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%'))
    BEGIN
        RAISERROR('Selected department must be a Lab department (Type=LAB).', 16, 1);
        RETURN;
    END

    IF @Method_Name IS NULL OR LTRIM(RTRIM(@Method_Name)) = ''
    BEGIN
        RAISERROR('Method Name is required.', 16, 1);
        RETURN;
    END

    SET @Method_Name = LTRIM(RTRIM(@Method_Name));

    IF EXISTS (
        SELECT 1 FROM dbo.LabTestMethodMaster 
        WHERE CompanyId = @CompanyId AND Department_ID = @Department_ID 
          AND LOWER(Method_Name) = LOWER(@Method_Name)
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A Test Method with the same name already exists in this Department.', 16, 1);
        RETURN;
    END

    DECLARE @NextNum INT;
    DECLARE @GeneratedCode NVARCHAR(50);

    SELECT @NextNum = ISNULL(MAX(Method_ID), 0) + 1 FROM dbo.LabTestMethodMaster;
    SET @GeneratedCode = 'MTH' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);

    WHILE EXISTS (SELECT 1 FROM dbo.LabTestMethodMaster WHERE Method_Code = @GeneratedCode)
    BEGIN
        SET @NextNum = @NextNum + 1;
        SET @GeneratedCode = 'MTH' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
    END

    INSERT INTO dbo.LabTestMethodMaster
    (
        CompanyId,
        Department_ID,
        Method_Name,
        Method_Code,
        Display_Order,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Department_ID,
        @Method_Name,
        @GeneratedCode,
        ISNULL(@Display_Order, 1),
        1,
        @UserId,
        GETDATE()
    );

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_Api_LabTestMethodMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestMethodMaster_Update
    @Method_ID        INT,
    @Department_ID    INT,
    @Method_Name      NVARCHAR(150),
    @Display_Order    INT = 1,
    @Status           BIT = 1,
    @UserId           INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestMethodMaster WHERE Method_ID = @Method_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Lab Test Method record not found.', 16, 1);
        RETURN;
    END

    IF @Department_ID IS NULL OR @Department_ID <= 0
    BEGIN
        RAISERROR('Department is required.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE DeptId = @Department_ID AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%'))
    BEGIN
        RAISERROR('Selected department must be a Lab department (Type=LAB).', 16, 1);
        RETURN;
    END

    IF @Method_Name IS NULL OR LTRIM(RTRIM(@Method_Name)) = ''
    BEGIN
        RAISERROR('Method Name is required.', 16, 1);
        RETURN;
    END

    SET @Method_Name = LTRIM(RTRIM(@Method_Name));

    IF EXISTS (
        SELECT 1 FROM dbo.LabTestMethodMaster 
        WHERE CompanyId = (SELECT CompanyId FROM dbo.LabTestMethodMaster WHERE Method_ID = @Method_ID) AND Department_ID = @Department_ID 
          AND LOWER(Method_Name) = LOWER(@Method_Name)
          AND Method_ID <> @Method_ID
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A Test Method with the same name already exists in this Department.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabTestMethodMaster
    SET Department_ID = @Department_ID,
        Method_Name   = @Method_Name,
        Display_Order = ISNULL(@Display_Order, 1),
        Status        = @Status,
        ModifiedBy    = @UserId,
        ModifiedDate  = GETDATE()
    WHERE Method_ID = @Method_ID;
END
GO

-- 5. Stored Procedure: usp_Api_LabSampleRejectionMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionMaster_Update
    @Rejection_ID      INT,
    @Rejection_Reason  NVARCHAR(255),
    @Description       NVARCHAR(500) = NULL,
    @Display_Order     INT = 1,
    @Status            BIT = 1,
    @UserId            INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleRejectionMaster WHERE Rejection_ID = @Rejection_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Sample Rejection record not found.', 16, 1);
        RETURN;
    END

    IF @Rejection_Reason IS NULL OR LTRIM(RTRIM(@Rejection_Reason)) = ''
    BEGIN
        RAISERROR('Rejection Reason is required.', 16, 1);
        RETURN;
    END

    SET @Rejection_Reason = LTRIM(RTRIM(@Rejection_Reason));
    SET @Description = LTRIM(RTRIM(@Description));

    IF EXISTS (
        SELECT 1 FROM dbo.LabSampleRejectionMaster 
        WHERE CompanyId = (SELECT CompanyId FROM dbo.LabSampleRejectionMaster WHERE Rejection_ID = @Rejection_ID) AND LOWER(Rejection_Reason) = LOWER(@Rejection_Reason)
          AND Rejection_ID <> @Rejection_ID
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A Sample Rejection Reason with the same name already exists.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabSampleRejectionMaster
    SET Rejection_Reason = @Rejection_Reason,
        Description      = @Description,
        Display_Order    = ISNULL(@Display_Order, 1),
        Status           = @Status,
        ModifiedBy       = @UserId,
        ModifiedDate     = GETDATE()
    WHERE Rejection_ID = @Rejection_ID;
END
GO

-- 5. Stored Procedure: usp_Api_LabSampleRejectionReasonMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionReasonMaster_Update
    @Reason_ID                 INT,
    @Reason_Text               NVARCHAR(1000),
    @Applicable_Sample_Type_ID INT = NULL,
    @Display_Order             INT = 1,
    @Status                    BIT = 1,
    @UserId                    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleRejectionReasonMaster WHERE Reason_ID = @Reason_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Sample Rejection Reason record not found.', 16, 1);
        RETURN;
    END

    IF @Reason_Text IS NULL OR LTRIM(RTRIM(@Reason_Text)) = ''
    BEGIN
        RAISERROR('Reason Text is required.', 16, 1);
        RETURN;
    END

    SET @Reason_Text = LTRIM(RTRIM(@Reason_Text));

    IF LEN(@Reason_Text) > 1000
    BEGIN
        RAISERROR('Reason Text cannot exceed 1000 characters.', 16, 1);
        RETURN;
    END

    IF @Applicable_Sample_Type_ID IS NOT NULL AND @Applicable_Sample_Type_ID > 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @Applicable_Sample_Type_ID AND IsDeleted = 0 AND Status = 1)
        BEGIN
            RAISERROR('Selected Sample Type is inactive or invalid.', 16, 1);
            RETURN;
        END
    END
    ELSE
    BEGIN
        SET @Applicable_Sample_Type_ID = NULL;
    END

    IF EXISTS (
        SELECT 1 FROM dbo.LabSampleRejectionReasonMaster 
        WHERE CompanyId = (SELECT CompanyId FROM dbo.LabSampleRejectionReasonMaster WHERE Reason_ID = @Reason_ID) AND LOWER(Reason_Text) = LOWER(@Reason_Text)
          AND ISNULL(Applicable_Sample_Type_ID, 0) = ISNULL(@Applicable_Sample_Type_ID, 0)
          AND Reason_ID <> @Reason_ID
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('An identical Sample Rejection Reason already exists.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabSampleRejectionReasonMaster
    SET Reason_Text               = @Reason_Text,
        Applicable_Sample_Type_ID = @Applicable_Sample_Type_ID,
        Display_Order             = ISNULL(@Display_Order, 1),
        Status                    = @Status,
        ModifiedBy                = @UserId,
        ModifiedDate              = GETDATE()
    WHERE Reason_ID = @Reason_ID;
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
            WHERE CompanyId = (SELECT CompanyId FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @Franchise_ID) AND LOWER(Franchise_Name) = LOWER(@Franchise_Name)
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
