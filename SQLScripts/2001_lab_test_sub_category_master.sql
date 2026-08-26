-- ====================================================================================================
-- Script: 2001_lab_test_sub_category_master.sql
-- Description: Creates dbo.LabTestSubCategoryMaster table and Stored Procedures for Lab Test Sub Category Master
--              under Lab -> Test Sub Category Master.
-- ====================================================================================================

-- 1. Create dbo.LabTestSubCategoryMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabTestSubCategoryMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabTestSubCategoryMaster
    (
        SubCategory_ID     INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId          INT NOT NULL DEFAULT 1,
        Category_ID        INT NOT NULL,
        SubCategory_Name   NVARCHAR(150) NOT NULL,
        SubCategory_Code   NVARCHAR(50) NOT NULL,
        Display_Order      INT NOT NULL DEFAULT 1,
        Status             BIT NOT NULL DEFAULT 1,
        IsDeleted          BIT NOT NULL DEFAULT 0,
        CreatedBy          INT NULL,
        CreatedDate        DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy         INT NULL,
        ModifiedDate       DATETIME2 NULL,
        CONSTRAINT FK_LabTestSubCategoryMaster_Category FOREIGN KEY (Category_ID) REFERENCES dbo.LabTestCategoryMaster(Category_ID)
    );
    CREATE INDEX IX_LabTestSubCategoryMaster_Category ON dbo.LabTestSubCategoryMaster(Category_ID);
    CREATE INDEX IX_LabTestSubCategoryMaster_Status ON dbo.LabTestSubCategoryMaster(Status);
    CREATE INDEX IX_LabTestSubCategoryMaster_Code ON dbo.LabTestSubCategoryMaster(SubCategory_Code);
    PRINT 'Created table dbo.LabTestSubCategoryMaster';
END
ELSE
BEGIN
    -- Drop BranchId column if it exists (migration)
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabTestSubCategoryMaster') AND name = 'BranchId')
    BEGIN
        DROP INDEX IF EXISTS IX_LabTestSubCategoryMaster_Branch_Status ON dbo.LabTestSubCategoryMaster;
        DECLARE @ConstraintName NVARCHAR(200);
        SELECT @ConstraintName = d.name
        FROM sys.default_constraints d
        INNER JOIN sys.columns c ON d.parent_object_id = c.object_id AND d.parent_column_id = c.column_id
        WHERE d.parent_object_id = OBJECT_ID('dbo.LabTestSubCategoryMaster') AND c.name = 'BranchId';
        IF @ConstraintName IS NOT NULL
            EXEC('ALTER TABLE dbo.LabTestSubCategoryMaster DROP CONSTRAINT ' + @ConstraintName);

        ALTER TABLE dbo.LabTestSubCategoryMaster DROP COLUMN BranchId;
        PRINT 'Dropped BranchId column from dbo.LabTestSubCategoryMaster';
    END

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabTestSubCategoryMaster') AND name = 'IsDeleted')
    BEGIN
        ALTER TABLE dbo.LabTestSubCategoryMaster ADD IsDeleted BIT NOT NULL DEFAULT 0;
        PRINT 'Added IsDeleted column to dbo.LabTestSubCategoryMaster';
    END

    PRINT 'Table dbo.LabTestSubCategoryMaster already exists';
END
GO

-- 2. Stored Procedure: usp_Api_LabTestSubCategoryMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestSubCategoryMaster_GetList
    @CategoryId      INT = NULL,
    @Status          BIT = NULL,
    @Search          NVARCHAR(100) = NULL,
    @CompanyId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        sub.SubCategory_ID,
        sub.CompanyId,
        sub.Category_ID,
        cat.Category_Name,
        cat.Category_Code,
        cat.Department_ID,
        dept.DeptName AS Department_Name,
        dept.DeptCode AS Department_Code,
        sub.SubCategory_Name,
        sub.SubCategory_Code,
        sub.Display_Order,
        sub.Status,
        sub.CreatedBy,
        sub.CreatedDate,
        sub.ModifiedBy,
        sub.ModifiedDate
    FROM dbo.LabTestSubCategoryMaster sub
    INNER JOIN dbo.LabTestCategoryMaster cat ON sub.Category_ID = cat.Category_ID
    LEFT JOIN dbo.DepartmentMaster dept ON cat.Department_ID = dept.DeptId
    WHERE sub.IsDeleted = 0
      AND (@CategoryId IS NULL OR sub.Category_ID = @CategoryId)
      AND (@Status IS NULL OR sub.Status = @Status)
      AND (@CompanyId IS NULL OR sub.CompanyId = @CompanyId)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR 
           sub.SubCategory_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR 
           sub.SubCategory_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           cat.Category_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY cat.Category_Name ASC, sub.Display_Order ASC, sub.SubCategory_Name ASC;
END
GO

-- 3. Stored Procedure: usp_Api_LabTestSubCategoryMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestSubCategoryMaster_GetById
    @SubCategory_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        sub.SubCategory_ID,
        sub.CompanyId,
        sub.Category_ID,
        cat.Category_Name,
        cat.Category_Code,
        cat.Department_ID,
        dept.DeptName AS Department_Name,
        dept.DeptCode AS Department_Code,
        sub.SubCategory_Name,
        sub.SubCategory_Code,
        sub.Display_Order,
        sub.Status,
        sub.CreatedBy,
        sub.CreatedDate,
        sub.ModifiedBy,
        sub.ModifiedDate
    FROM dbo.LabTestSubCategoryMaster sub
    INNER JOIN dbo.LabTestCategoryMaster cat ON sub.Category_ID = cat.Category_ID
    LEFT JOIN dbo.DepartmentMaster dept ON cat.Department_ID = dept.DeptId
    WHERE sub.SubCategory_ID = @SubCategory_ID AND sub.IsDeleted = 0;
END
GO

-- 4. Stored Procedure: usp_Api_LabTestSubCategoryMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestSubCategoryMaster_Create
    @Category_ID        INT,
    @SubCategory_Name   NVARCHAR(150),
    @Display_Order      INT = 1,
    @CompanyId          INT = 1,
    @UserId             INT = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @Category_ID IS NULL OR @Category_ID <= 0
    BEGIN
        RAISERROR('Test Category is required.', 16, 1);
        RETURN;
    END

    IF @SubCategory_Name IS NULL OR LTRIM(RTRIM(@SubCategory_Name)) = ''
    BEGIN
        RAISERROR('Sub Category Name is required.', 16, 1);
        RETURN;
    END

    SET @SubCategory_Name = LTRIM(RTRIM(@SubCategory_Name));

    IF EXISTS (
        SELECT 1 FROM dbo.LabTestSubCategoryMaster 
        WHERE Category_ID = @Category_ID 
          AND LOWER(SubCategory_Name) = LOWER(@SubCategory_Name)
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A sub-category with the same name already exists in this category.', 16, 1);
        RETURN;
    END

    DECLARE @NextNum INT;
    DECLARE @GeneratedCode NVARCHAR(50);

    SELECT @NextNum = ISNULL(MAX(SubCategory_ID), 0) + 1 FROM dbo.LabTestSubCategoryMaster;
    SET @GeneratedCode = 'LSUBCAT' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);

    WHILE EXISTS (SELECT 1 FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Code = @GeneratedCode)
    BEGIN
        SET @NextNum = @NextNum + 1;
        SET @GeneratedCode = 'LSUBCAT' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
    END

    INSERT INTO dbo.LabTestSubCategoryMaster
    (
        CompanyId,
        Category_ID,
        SubCategory_Name,
        SubCategory_Code,
        Display_Order,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Category_ID,
        @SubCategory_Name,
        @GeneratedCode,
        ISNULL(@Display_Order, 1),
        1,
        @UserId,
        GETDATE()
    );

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_Api_LabTestSubCategoryMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestSubCategoryMaster_Update
    @SubCategory_ID   INT,
    @Category_ID      INT,
    @SubCategory_Name NVARCHAR(150),
    @Display_Order    INT,
    @Status           BIT,
    @UserId           INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_ID = @SubCategory_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Lab Test Sub Category record not found.', 16, 1);
        RETURN;
    END

    IF @Category_ID IS NULL OR @Category_ID <= 0
    BEGIN
        RAISERROR('Test Category is required.', 16, 1);
        RETURN;
    END

    IF @SubCategory_Name IS NULL OR LTRIM(RTRIM(@SubCategory_Name)) = ''
    BEGIN
        RAISERROR('Sub Category Name is required.', 16, 1);
        RETURN;
    END

    SET @SubCategory_Name = LTRIM(RTRIM(@SubCategory_Name));

    IF EXISTS (
        SELECT 1 FROM dbo.LabTestSubCategoryMaster 
        WHERE Category_ID = @Category_ID 
          AND LOWER(SubCategory_Name) = LOWER(@SubCategory_Name) 
          AND SubCategory_ID <> @SubCategory_ID
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A sub-category with the same name already exists in this category.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabTestSubCategoryMaster
    SET Category_ID      = @Category_ID,
        SubCategory_Name = @SubCategory_Name,
        Display_Order    = ISNULL(@Display_Order, 1),
        Status           = @Status,
        ModifiedBy       = @UserId,
        ModifiedDate     = GETDATE()
    WHERE SubCategory_ID = @SubCategory_ID;
END
GO

-- 6. Stored Procedure: usp_Api_LabTestSubCategoryMaster_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestSubCategoryMaster_ToggleStatus
    @SubCategory_ID INT,
    @Status         BIT,
    @UserId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_ID = @SubCategory_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Lab Test Sub Category record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabTestSubCategoryMaster
    SET Status       = @Status,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE SubCategory_ID = @SubCategory_ID;
END
GO

-- 7. Stored Procedure: usp_Api_LabTestSubCategoryMaster_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestSubCategoryMaster_Delete
    @SubCategory_ID INT,
    @UserId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_ID = @SubCategory_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Lab Test Sub Category record not found or already deleted.', 16, 1);
        RETURN;
    END

    -- Check if used in Investigation Master
    IF EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE SubCategory_ID = @SubCategory_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Cannot delete Sub Category because it is used in one or more Test Investigations.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabTestSubCategoryMaster
    SET IsDeleted = 1,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
    WHERE SubCategory_ID = @SubCategory_ID;
END
GO
