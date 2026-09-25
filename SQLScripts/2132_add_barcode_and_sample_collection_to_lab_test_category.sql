-- ====================================================================================================
-- Script: 2132_add_barcode_and_sample_collection_to_lab_test_category.sql
-- Description: Adds Is_Barcode_Required and Is_Sample_Collection_Required to dbo.LabTestCategoryMaster
--              and updates related stored procedures.
-- ====================================================================================================

-- 1. Add columns to dbo.LabTestCategoryMaster if not exists
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabTestCategoryMaster') AND name = 'Is_Barcode_Required')
BEGIN
    ALTER TABLE dbo.LabTestCategoryMaster 
    ADD Is_Barcode_Required BIT NOT NULL CONSTRAINT DF_LabTestCategoryMaster_Is_Barcode_Required DEFAULT 1;
    PRINT 'Added Is_Barcode_Required column to dbo.LabTestCategoryMaster';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabTestCategoryMaster') AND name = 'Is_Sample_Collection_Required')
BEGIN
    ALTER TABLE dbo.LabTestCategoryMaster 
    ADD Is_Sample_Collection_Required BIT NOT NULL CONSTRAINT DF_LabTestCategoryMaster_Is_Sample_Collection_Required DEFAULT 1;
    PRINT 'Added Is_Sample_Collection_Required column to dbo.LabTestCategoryMaster';
END
GO

-- 2. Update dbo.usp_Api_LabTestCategoryMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestCategoryMaster_GetList
    @DepartmentId    INT = NULL,
    @Status          BIT = NULL,
    @Search          NVARCHAR(100) = NULL,
    @CompanyId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        cat.Category_ID,
        cat.CompanyId,
        cat.Department_ID,
        dept.DeptName AS Department_Name,
        dept.DeptCode AS Department_Code,
        cat.Category_Name,
        cat.Category_Code,
        cat.Display_Order,
        cat.Status,
        cat.Is_Barcode_Required,
        cat.Is_Sample_Collection_Required,
        cat.CreatedBy,
        cat.CreatedDate,
        cat.ModifiedBy,
        cat.ModifiedDate
    FROM dbo.LabTestCategoryMaster cat
    LEFT JOIN dbo.DepartmentMaster dept ON cat.Department_ID = dept.DeptId
    WHERE cat.IsDeleted = 0
      AND (@DepartmentId IS NULL OR cat.Department_ID = @DepartmentId)
      AND (@Status IS NULL OR cat.Status = @Status)
      AND (@CompanyId IS NULL OR cat.CompanyId = @CompanyId)
      AND (dept.DeptType IS NULL OR dept.DeptType = 'Lab' OR dept.DeptType LIKE '%Lab%')
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR 
           cat.Category_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR 
           cat.Category_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           dept.DeptName LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY cat.Display_Order ASC, cat.Category_Name ASC;
END
GO

-- 3. Update dbo.usp_Api_LabTestCategoryMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestCategoryMaster_GetById
    @Category_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        cat.Category_ID,
        cat.CompanyId,
        cat.Department_ID,
        dept.DeptName AS Department_Name,
        dept.DeptCode AS Department_Code,
        cat.Category_Name,
        cat.Category_Code,
        cat.Display_Order,
        cat.Status,
        cat.Is_Barcode_Required,
        cat.Is_Sample_Collection_Required,
        cat.CreatedBy,
        cat.CreatedDate,
        cat.ModifiedBy,
        cat.ModifiedDate
    FROM dbo.LabTestCategoryMaster cat
    LEFT JOIN dbo.DepartmentMaster dept ON cat.Department_ID = dept.DeptId
    WHERE cat.Category_ID = @Category_ID AND cat.IsDeleted = 0;
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
        WHERE Department_ID = @Department_ID 
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
        WHERE Department_ID = @Department_ID 
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
