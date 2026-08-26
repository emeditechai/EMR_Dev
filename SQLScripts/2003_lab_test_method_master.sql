-- ====================================================================================================
-- Script: 2003_lab_test_method_master.sql
-- Description: Creates dbo.LabTestMethodMaster table and Stored Procedures for Test Method Master
--              under Lab -> Test Method Master.
-- ====================================================================================================

-- 1. Create dbo.LabTestMethodMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabTestMethodMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabTestMethodMaster
    (
        Method_ID          INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId          INT NOT NULL DEFAULT 1,
        Department_ID      INT NOT NULL,
        Method_Name        NVARCHAR(150) NOT NULL,
        Method_Code        NVARCHAR(50) NOT NULL,
        Display_Order      INT NOT NULL DEFAULT 1,
        Status             BIT NOT NULL DEFAULT 1,
        IsDeleted          BIT NOT NULL DEFAULT 0,
        CreatedBy          INT NULL,
        CreatedDate        DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy         INT NULL,
        ModifiedDate       DATETIME2 NULL,
        CONSTRAINT FK_LabTestMethodMaster_Department FOREIGN KEY (Department_ID) REFERENCES dbo.DepartmentMaster(DeptId)
    );
    CREATE INDEX IX_LabTestMethodMaster_Dept ON dbo.LabTestMethodMaster(Department_ID);
    CREATE INDEX IX_LabTestMethodMaster_Status ON dbo.LabTestMethodMaster(Status);
    CREATE INDEX IX_LabTestMethodMaster_Code ON dbo.LabTestMethodMaster(Method_Code);
    PRINT 'Created table dbo.LabTestMethodMaster';
END
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabTestMethodMaster') AND name = 'BranchId')
    BEGIN
        DROP INDEX IF EXISTS IX_LabTestMethodMaster_Branch_Status ON dbo.LabTestMethodMaster;
        DECLARE @ConstraintName NVARCHAR(200);
        SELECT @ConstraintName = d.name
        FROM sys.default_constraints d
        INNER JOIN sys.columns c ON d.parent_object_id = c.object_id AND d.parent_column_id = c.column_id
        WHERE d.parent_object_id = OBJECT_ID('dbo.LabTestMethodMaster') AND c.name = 'BranchId';
        IF @ConstraintName IS NOT NULL
            EXEC('ALTER TABLE dbo.LabTestMethodMaster DROP CONSTRAINT ' + @ConstraintName);

        ALTER TABLE dbo.LabTestMethodMaster DROP COLUMN BranchId;
        PRINT 'Dropped BranchId column from dbo.LabTestMethodMaster';
    END

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabTestMethodMaster') AND name = 'IsDeleted')
    BEGIN
        ALTER TABLE dbo.LabTestMethodMaster ADD IsDeleted BIT NOT NULL DEFAULT 0;
        PRINT 'Added IsDeleted column to dbo.LabTestMethodMaster';
    END

    PRINT 'Table dbo.LabTestMethodMaster already exists';
END
GO

-- 2. Stored Procedure: usp_Api_LabTestMethodMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestMethodMaster_GetList
    @DepartmentId    INT = NULL,
    @Status          BIT = NULL,
    @Search          NVARCHAR(100) = NULL,
    @CompanyId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        tm.Method_ID,
        tm.CompanyId,
        tm.Department_ID,
        dept.DeptName AS Department_Name,
        dept.DeptCode AS Department_Code,
        tm.Method_Name,
        tm.Method_Code,
        tm.Display_Order,
        tm.Status,
        tm.CreatedBy,
        tm.CreatedDate,
        tm.ModifiedBy,
        tm.ModifiedDate
    FROM dbo.LabTestMethodMaster tm
    LEFT JOIN dbo.DepartmentMaster dept ON tm.Department_ID = dept.DeptId
    WHERE tm.IsDeleted = 0
      AND (@DepartmentId IS NULL OR tm.Department_ID = @DepartmentId)
      AND (@Status IS NULL OR tm.Status = @Status)
      AND (@CompanyId IS NULL OR tm.CompanyId = @CompanyId)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR 
           tm.Method_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR 
           tm.Method_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           dept.DeptName LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY dept.DeptName ASC, tm.Display_Order ASC, tm.Method_Name ASC;
END
GO

-- 3. Stored Procedure: usp_Api_LabTestMethodMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestMethodMaster_GetById
    @Method_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        tm.Method_ID,
        tm.CompanyId,
        tm.Department_ID,
        dept.DeptName AS Department_Name,
        dept.DeptCode AS Department_Code,
        tm.Method_Name,
        tm.Method_Code,
        tm.Display_Order,
        tm.Status,
        tm.CreatedBy,
        tm.CreatedDate,
        tm.ModifiedBy,
        tm.ModifiedDate
    FROM dbo.LabTestMethodMaster tm
    LEFT JOIN dbo.DepartmentMaster dept ON tm.Department_ID = dept.DeptId
    WHERE tm.Method_ID = @Method_ID AND tm.IsDeleted = 0;
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
        WHERE Department_ID = @Department_ID 
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
        WHERE Department_ID = @Department_ID 
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

-- 6. Stored Procedure: usp_Api_LabTestMethodMaster_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestMethodMaster_ToggleStatus
    @Method_ID INT,
    @Status    BIT,
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestMethodMaster WHERE Method_ID = @Method_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Lab Test Method record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabTestMethodMaster
    SET Status       = @Status,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE Method_ID = @Method_ID;
END
GO

-- 7. Stored Procedure: usp_Api_LabTestMethodMaster_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestMethodMaster_Delete
    @Method_ID INT,
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestMethodMaster WHERE Method_ID = @Method_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Lab Test Method record not found or already deleted.', 16, 1);
        RETURN;
    END

    -- Check if used in Investigation Master
    IF EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Method_ID = @Method_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Cannot delete Test Method because it is used in one or more Test Investigations.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabTestMethodMaster
    SET IsDeleted = 1,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
    WHERE Method_ID = @Method_ID;
END
GO
