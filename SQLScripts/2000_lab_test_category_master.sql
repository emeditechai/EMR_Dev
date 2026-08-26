-- ====================================================================================================
-- Script: 2000_lab_test_category_master.sql
-- Description: Creates dbo.LabTestCategoryMaster table and Stored Procedures for Lab Test Category Master
--              under Lab -> Test Category Master.
-- ====================================================================================================

-- Drop old table if exists for clean rename transition
IF EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabCategoryMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    DROP TABLE dbo.LabCategoryMaster;
END
GO

-- 1. Create dbo.LabTestCategoryMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabTestCategoryMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabTestCategoryMaster
    (
        Category_ID     INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId       INT NOT NULL DEFAULT 1,
        Department_ID   INT NOT NULL,
        Category_Name   NVARCHAR(150) NOT NULL,
        Category_Code   NVARCHAR(50) NOT NULL,
        Display_Order   INT NOT NULL DEFAULT 1,
        Status          BIT NOT NULL DEFAULT 1,
        IsDeleted       BIT NOT NULL DEFAULT 0,
        CreatedBy       INT NULL,
        CreatedDate     DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy      INT NULL,
        ModifiedDate    DATETIME2 NULL,
        CONSTRAINT FK_LabTestCategoryMaster_Department FOREIGN KEY (Department_ID) REFERENCES dbo.DepartmentMaster(DeptId)
    );
    CREATE INDEX IX_LabTestCategoryMaster_Department ON dbo.LabTestCategoryMaster(Department_ID);
    CREATE INDEX IX_LabTestCategoryMaster_Status ON dbo.LabTestCategoryMaster(Status);
    CREATE INDEX IX_LabTestCategoryMaster_Code ON dbo.LabTestCategoryMaster(Category_Code);
    PRINT 'Created table dbo.LabTestCategoryMaster';
END
ELSE
BEGIN
    -- Drop BranchId column if it exists (migration)
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabTestCategoryMaster') AND name = 'BranchId')
    BEGIN
        DROP INDEX IF EXISTS IX_LabTestCategoryMaster_Branch_Status ON dbo.LabTestCategoryMaster;
        DECLARE @ConstraintName NVARCHAR(200);
        SELECT @ConstraintName = d.name
        FROM sys.default_constraints d
        INNER JOIN sys.columns c ON d.parent_object_id = c.object_id AND d.parent_column_id = c.column_id
        WHERE d.parent_object_id = OBJECT_ID('dbo.LabTestCategoryMaster') AND c.name = 'BranchId';
        IF @ConstraintName IS NOT NULL
            EXEC('ALTER TABLE dbo.LabTestCategoryMaster DROP CONSTRAINT ' + @ConstraintName);

        ALTER TABLE dbo.LabTestCategoryMaster DROP COLUMN BranchId;
        PRINT 'Dropped BranchId column from dbo.LabTestCategoryMaster';
    END

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabTestCategoryMaster') AND name = 'IsDeleted')
    BEGIN
        ALTER TABLE dbo.LabTestCategoryMaster ADD IsDeleted BIT NOT NULL DEFAULT 0;
        PRINT 'Added IsDeleted column to dbo.LabTestCategoryMaster';
    END

    PRINT 'Table dbo.LabTestCategoryMaster already exists';
END
GO

-- 2. Stored Procedure: usp_Api_LabTestCategoryMaster_GetList
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

-- 3. Stored Procedure: usp_Api_LabTestCategoryMaster_GetById
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
        cat.CreatedBy,
        cat.CreatedDate,
        cat.ModifiedBy,
        cat.ModifiedDate
    FROM dbo.LabTestCategoryMaster cat
    LEFT JOIN dbo.DepartmentMaster dept ON cat.Department_ID = dept.DeptId
    WHERE cat.Category_ID = @Category_ID AND cat.IsDeleted = 0;
END
GO

-- 4. Stored Procedure: usp_Api_LabTestCategoryMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestCategoryMaster_Create
    @Department_ID INT,
    @Category_Name NVARCHAR(150),
    @Display_Order INT = 1,
    @CompanyId     INT = 1,
    @UserId        INT = NULL,
    @NewId         INT OUTPUT
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
        @UserId,
        GETDATE()
    );

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_Api_LabTestCategoryMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestCategoryMaster_Update
    @Category_ID   INT,
    @Department_ID INT,
    @Category_Name NVARCHAR(150),
    @Display_Order INT,
    @Status        BIT,
    @UserId        INT = NULL
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
    SET Department_ID = @Department_ID,
        Category_Name = @Category_Name,
        Display_Order = ISNULL(@Display_Order, 1),
        Status        = @Status,
        ModifiedBy    = @UserId,
        ModifiedDate  = GETDATE()
    WHERE Category_ID = @Category_ID;
END
GO

-- 6. Stored Procedure: usp_Api_LabTestCategoryMaster_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestCategoryMaster_ToggleStatus
    @Category_ID INT,
    @Status      BIT,
    @UserId      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestCategoryMaster WHERE Category_ID = @Category_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Lab Test Category record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabTestCategoryMaster
    SET Status       = @Status,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE Category_ID = @Category_ID;
END
GO

-- 7. Stored Procedure: usp_Api_LabTestCategoryMaster_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestCategoryMaster_Delete
    @Category_ID INT,
    @UserId      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestCategoryMaster WHERE Category_ID = @Category_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Lab Test Category record not found or already deleted.', 16, 1);
        RETURN;
    END

    -- Check if used in Sub Category
    IF EXISTS (SELECT 1 FROM dbo.LabTestSubCategoryMaster WHERE Category_ID = @Category_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Cannot delete Category because it is used in one or more Sub Categories.', 16, 1);
        RETURN;
    END

    -- Check if used in Investigation Master
    IF EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Category_ID = @Category_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Cannot delete Category because it is used in one or more Test Investigations.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabTestCategoryMaster
    SET IsDeleted = 1,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
    WHERE Category_ID = @Category_ID;
END
GO
