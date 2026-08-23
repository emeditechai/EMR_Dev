-- ====================================================================================================
-- Script: 94_lab_test_category_master.sql
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
        BranchId        INT NOT NULL DEFAULT 1,
        Department_ID   INT NOT NULL,
        Category_Name   NVARCHAR(150) NOT NULL,
        Category_Code   NVARCHAR(50) NOT NULL,
        Display_Order   INT NOT NULL DEFAULT 1,
        Status          BIT NOT NULL DEFAULT 1,
        CreatedBy       INT NULL,
        CreatedDate     DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy      INT NULL,
        ModifiedDate    DATETIME2 NULL,
        CONSTRAINT FK_LabTestCategoryMaster_Department FOREIGN KEY (Department_ID) REFERENCES dbo.DepartmentMaster(DeptId)
    );
    CREATE INDEX IX_LabTestCategoryMaster_Department ON dbo.LabTestCategoryMaster(Department_ID);
    CREATE INDEX IX_LabTestCategoryMaster_Branch_Status ON dbo.LabTestCategoryMaster(BranchId, Status);
    CREATE INDEX IX_LabTestCategoryMaster_Code ON dbo.LabTestCategoryMaster(Category_Code);
    PRINT 'Created table dbo.LabTestCategoryMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.LabTestCategoryMaster already exists';
END
GO

-- 2. Stored Procedure: usp_Api_LabTestCategoryMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestCategoryMaster_GetList
    @BranchId        INT = NULL,
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
        cat.BranchId,
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
    WHERE (@BranchId IS NULL OR cat.BranchId = @BranchId)
      AND (@DepartmentId IS NULL OR cat.Department_ID = @DepartmentId)
      AND (@Status IS NULL OR cat.Status = @Status)
      AND (@CompanyId IS NULL OR cat.CompanyId = @CompanyId)
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
        cat.BranchId,
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
    WHERE cat.Category_ID = @Category_ID;
END
GO

-- 4. Stored Procedure: usp_Api_LabTestCategoryMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestCategoryMaster_Create
    @Department_ID INT,
    @Category_Name NVARCHAR(150),
    @Display_Order INT = 1,
    @CompanyId     INT = 1,
    @BranchId      INT = 1,
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

    IF @Category_Name IS NULL OR LTRIM(RTRIM(@Category_Name)) = ''
    BEGIN
        RAISERROR('Category Name is required.', 16, 1);
        RETURN;
    END

    SET @Category_Name = LTRIM(RTRIM(@Category_Name));

    -- Check duplicate category name within same branch & department
    IF EXISTS (
        SELECT 1 FROM dbo.LabTestCategoryMaster 
        WHERE BranchId = @BranchId 
          AND Department_ID = @Department_ID 
          AND LOWER(Category_Name) = LOWER(@Category_Name)
    )
    BEGIN
        RAISERROR('A category with the same name already exists in this department.', 16, 1);
        RETURN;
    END

    -- Generate Category Code (e.g. LCAT0001)
    DECLARE @NextNum INT;
    DECLARE @GeneratedCode NVARCHAR(50);

    SELECT @NextNum = ISNULL(MAX(Category_ID), 0) + 1 FROM dbo.LabTestCategoryMaster;
    SET @GeneratedCode = 'LCAT' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);

    -- Ensure unique generated code
    WHILE EXISTS (SELECT 1 FROM dbo.LabTestCategoryMaster WHERE Category_Code = @GeneratedCode)
    BEGIN
        SET @NextNum = @NextNum + 1;
        SET @GeneratedCode = 'LCAT' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
    END

    INSERT INTO dbo.LabTestCategoryMaster
    (
        CompanyId,
        BranchId,
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
        @BranchId,
        @Department_ID,
        @Category_Name,
        @GeneratedCode,
        ISNULL(@Display_Order, 1),
        1, -- New categories start as Active (Status = 1)
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

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestCategoryMaster WHERE Category_ID = @Category_ID)
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

    IF @Category_Name IS NULL OR LTRIM(RTRIM(@Category_Name)) = ''
    BEGIN
        RAISERROR('Category Name is required.', 16, 1);
        RETURN;
    END

    SET @Category_Name = LTRIM(RTRIM(@Category_Name));

    DECLARE @CurrentBranchId INT;
    SELECT @CurrentBranchId = BranchId FROM dbo.LabTestCategoryMaster WHERE Category_ID = @Category_ID;

    -- Duplicate check ignoring self
    IF EXISTS (
        SELECT 1 FROM dbo.LabTestCategoryMaster 
        WHERE BranchId = @CurrentBranchId 
          AND Department_ID = @Department_ID 
          AND LOWER(Category_Name) = LOWER(@Category_Name) 
          AND Category_ID <> @Category_ID
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

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestCategoryMaster WHERE Category_ID = @Category_ID)
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
    @Category_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestCategoryMaster WHERE Category_ID = @Category_ID)
    BEGIN
        RAISERROR('Lab Test Category record not found.', 16, 1);
        RETURN;
    END

    DELETE FROM dbo.LabTestCategoryMaster
    WHERE Category_ID = @Category_ID;
END
GO
