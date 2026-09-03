-- ====================================================================================================
-- Script: 2013_lab_investigation_master_new_fields.sql
-- Description: Adds Applicable_Gender, Is_Billable, Age_Operator, and Applicable_Age columns to 
--              dbo.LabInvestigationMaster and updates stored procedures.
-- Database:    Dev_EMR (SQL Server)
-- ====================================================================================================

USE [Dev_EMR];
GO

SET NOCOUNT ON;

PRINT 'Adding new columns to dbo.LabInvestigationMaster...';

-- 1. Applicable_Gender
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabInvestigationMaster') AND name = 'Applicable_Gender')
BEGIN
    ALTER TABLE dbo.LabInvestigationMaster ADD Applicable_Gender VARCHAR(20) NOT NULL DEFAULT('All');
    PRINT 'Added Applicable_Gender column to dbo.LabInvestigationMaster';
END

-- 2. Is_Billable
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabInvestigationMaster') AND name = 'Is_Billable')
BEGIN
    ALTER TABLE dbo.LabInvestigationMaster ADD Is_Billable BIT NOT NULL DEFAULT(1);
    PRINT 'Added Is_Billable column to dbo.LabInvestigationMaster';
END

-- 3. Age_Operator
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabInvestigationMaster') AND name = 'Age_Operator')
BEGIN
    ALTER TABLE dbo.LabInvestigationMaster ADD Age_Operator VARCHAR(20) NULL;
    PRINT 'Added Age_Operator column to dbo.LabInvestigationMaster';
END

-- 4. Applicable_Age
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabInvestigationMaster') AND name = 'Applicable_Age')
BEGIN
    ALTER TABLE dbo.LabInvestigationMaster ADD Applicable_Age INT NULL;
    PRINT 'Added Applicable_Age column to dbo.LabInvestigationMaster';
END

GO

-- ====================================================================================================
-- Update Stored Procedures
-- ====================================================================================================

-- 1. GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_GetList
    @DepartmentId    INT = NULL,
    @CategoryId      INT = NULL,
    @Status          BIT = NULL,
    @Search          NVARCHAR(100) = NULL,
    @CompanyId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        inv.Test_ID,
        inv.CompanyId,
        inv.Test_Code,
        inv.Test_Name,
        inv.Department_ID,
        dept.DeptName AS Department_Name,
        dept.DeptCode AS Department_Code,
        inv.Category_ID,
        cat.Category_Name,
        cat.Category_Code,
        inv.SubCategory_ID,
        sub.SubCategory_Name,
        sub.SubCategory_Code,
        inv.Sample_Type_ID,
        st.Sample_Name AS Sample_Type_Name,
        inv.Method_ID,
        tm.Method_Name,
        inv.Unit_ID,
        u.Unit_Name,
        u.Unit_Symbol,
        inv.Reporting_Type,
        inv.TAT_Hours,
        inv.NABL_Accredited,
        inv.NABL_Scope_No,
        inv.Is_Outsourced,
        inv.Is_Profile_Test,
        inv.Applicable_Gender,
        inv.Is_Billable,
        inv.Age_Operator,
        inv.Applicable_Age,
        inv.MRP,
        inv.Status,
        inv.CreatedBy,
        inv.CreatedDate,
        inv.ModifiedBy,
        inv.ModifiedDate
    FROM dbo.LabInvestigationMaster inv
    LEFT JOIN dbo.DepartmentMaster dept ON inv.Department_ID = dept.DeptId
    LEFT JOIN dbo.LabTestCategoryMaster cat ON inv.Category_ID = cat.Category_ID
    LEFT JOIN dbo.LabTestSubCategoryMaster sub ON inv.SubCategory_ID = sub.SubCategory_ID
    LEFT JOIN dbo.LabSampleTypeMaster st ON inv.Sample_Type_ID = st.Sample_Type_ID
    LEFT JOIN dbo.LabTestMethodMaster tm ON inv.Method_ID = tm.Method_ID
    LEFT JOIN dbo.LabUnitMaster u ON inv.Unit_ID = u.Unit_ID
    WHERE inv.IsDeleted = 0
      AND (@DepartmentId IS NULL OR inv.Department_ID = @DepartmentId)
      AND (@CategoryId   IS NULL OR inv.Category_ID   = @CategoryId)
      AND (@Status       IS NULL OR inv.Status         = @Status)
      AND (@CompanyId    IS NULL OR inv.CompanyId      = @CompanyId)
      AND (dept.DeptType IS NULL OR UPPER(dept.DeptType) = 'LAB' OR dept.DeptType LIKE '%Lab%')
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = ''
           OR inv.Test_Name  LIKE '%' + LTRIM(RTRIM(@Search)) + '%'
           OR inv.Test_Code  LIKE '%' + LTRIM(RTRIM(@Search)) + '%'
           OR cat.Category_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY inv.Test_Name ASC;
END
GO

-- 2. GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_GetById
    @Test_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        inv.Test_ID,
        inv.CompanyId,
        inv.Test_Code,
        inv.Test_Name,
        inv.Department_ID,
        dept.DeptName AS Department_Name,
        dept.DeptCode AS Department_Code,
        inv.Category_ID,
        cat.Category_Name,
        cat.Category_Code,
        inv.SubCategory_ID,
        sub.SubCategory_Name,
        sub.SubCategory_Code,
        inv.Sample_Type_ID,
        st.Sample_Name AS Sample_Type_Name,
        inv.Method_ID,
        tm.Method_Name,
        inv.Unit_ID,
        u.Unit_Name,
        u.Unit_Symbol,
        inv.Reporting_Type,
        inv.TAT_Hours,
        inv.NABL_Accredited,
        inv.NABL_Scope_No,
        inv.Is_Outsourced,
        inv.Is_Profile_Test,
        inv.Applicable_Gender,
        inv.Is_Billable,
        inv.Age_Operator,
        inv.Applicable_Age,
        inv.MRP,
        inv.Status,
        inv.CreatedBy,
        inv.CreatedDate,
        inv.ModifiedBy,
        inv.ModifiedDate
    FROM dbo.LabInvestigationMaster inv
    LEFT JOIN dbo.DepartmentMaster dept ON inv.Department_ID = dept.DeptId
    LEFT JOIN dbo.LabTestCategoryMaster cat ON inv.Category_ID = cat.Category_ID
    LEFT JOIN dbo.LabTestSubCategoryMaster sub ON inv.SubCategory_ID = sub.SubCategory_ID
    LEFT JOIN dbo.LabSampleTypeMaster st ON inv.Sample_Type_ID = st.Sample_Type_ID
    LEFT JOIN dbo.LabTestMethodMaster tm ON inv.Method_ID = tm.Method_ID
    LEFT JOIN dbo.LabUnitMaster u ON inv.Unit_ID = u.Unit_ID
    WHERE inv.Test_ID = @Test_ID AND inv.IsDeleted = 0;
END
GO

-- 3. Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_Create
    @CompanyId          INT = 1,
    @Department_ID      INT,
    @Category_ID        INT,
    @SubCategory_ID     INT = NULL,
    @Sample_Type_ID     INT = NULL,
    @Method_ID          INT = NULL,
    @Unit_ID            INT = NULL,
    @Test_Name          NVARCHAR(200),
    @Reporting_Type     NVARCHAR(50) = 'Numeric',
    @TAT_Hours          INT = 24,
    @NABL_Accredited    BIT = 0,
    @NABL_Scope_No      NVARCHAR(100) = NULL,
    @Is_Outsourced      BIT = 0,
    @Is_Profile_Test    BIT = 0,
    @Applicable_Gender  VARCHAR(20) = 'All',
    @Is_Billable        BIT = 1,
    @Age_Operator       VARCHAR(20) = NULL,
    @Applicable_Age     INT = NULL,
    @MRP                DECIMAL(18,2) = 0.00,
    @Status             BIT = 1,
    @UserId             INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Department_ID IS NULL OR @Department_ID <= 0
    BEGIN RAISERROR('Department is required.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE DeptId = @Department_ID AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%'))
    BEGIN RAISERROR('Selected department must be a Lab department (Type=LAB).', 16, 1); RETURN; END

    IF @Category_ID IS NULL OR @Category_ID <= 0
    BEGIN RAISERROR('Category is required.', 16, 1); RETURN; END

    IF @Test_Name IS NULL OR LTRIM(RTRIM(@Test_Name)) = ''
    BEGIN RAISERROR('Test Name is required.', 16, 1); RETURN; END

    SET @Test_Name = LTRIM(RTRIM(@Test_Name));

    -- Duplicate check
    IF EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE LOWER(Test_Name) = LOWER(@Test_Name) AND IsDeleted = 0)
    BEGIN RAISERROR('A Test with the same name already exists.', 16, 1); RETURN; END

    DECLARE @NextId INT;
    DECLARE @GeneratedCode NVARCHAR(50);
    SELECT @NextId = ISNULL(MAX(Test_ID), 0) + 1 FROM dbo.LabInvestigationMaster;
    SET @GeneratedCode = 'TST' + RIGHT('0000' + CAST(@NextId AS NVARCHAR(10)), 4);

    INSERT INTO dbo.LabInvestigationMaster
    (
        CompanyId, Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID,
        Sample_Type_ID, Method_ID, Unit_ID, Reporting_Type, TAT_Hours, NABL_Accredited,
        NABL_Scope_No, Is_Outsourced, Is_Profile_Test, Applicable_Gender, Is_Billable,
        Age_Operator, Applicable_Age, MRP, Status, CreatedBy, CreatedDate
    )
    VALUES
    (
        @CompanyId, @GeneratedCode, @Test_Name, @Department_ID, @Category_ID, @SubCategory_ID,
        @Sample_Type_ID, @Method_ID, @Unit_ID, ISNULL(@Reporting_Type,'Numeric'), ISNULL(@TAT_Hours,24),
        ISNULL(@NABL_Accredited,0), @NABL_Scope_No, ISNULL(@Is_Outsourced,0), ISNULL(@Is_Profile_Test,0),
        ISNULL(@Applicable_Gender,'All'), ISNULL(@Is_Billable,1), @Age_Operator, @Applicable_Age,
        ISNULL(@MRP,0.00), ISNULL(@Status,1), @UserId, GETDATE()
    );

    SELECT SCOPE_IDENTITY() AS NewId;
END
GO

-- 4. Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_Update
    @Test_ID            INT,
    @Department_ID      INT,
    @Category_ID        INT,
    @SubCategory_ID     INT = NULL,
    @Sample_Type_ID     INT = NULL,
    @Method_ID          INT = NULL,
    @Unit_ID            INT = NULL,
    @Test_Name          NVARCHAR(200),
    @Reporting_Type     NVARCHAR(50) = 'Numeric',
    @TAT_Hours          INT = 24,
    @NABL_Accredited    BIT = 0,
    @NABL_Scope_No      NVARCHAR(100) = NULL,
    @Is_Outsourced      BIT = 0,
    @Is_Profile_Test    BIT = 0,
    @Applicable_Gender  VARCHAR(20) = 'All',
    @Is_Billable        BIT = 1,
    @Age_Operator       VARCHAR(20) = NULL,
    @Applicable_Age     INT = NULL,
    @MRP                DECIMAL(18,2) = 0.00,
    @Status             BIT = 1,
    @UserId             INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID AND IsDeleted = 0)
    BEGIN RAISERROR('Investigation Master record not found.', 16, 1); RETURN; END

    IF @Department_ID IS NULL OR @Department_ID <= 0
    BEGIN RAISERROR('Department is required.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE DeptId = @Department_ID AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%'))
    BEGIN RAISERROR('Selected department must be a Lab department (Type=LAB).', 16, 1); RETURN; END

    IF @Category_ID IS NULL OR @Category_ID <= 0
    BEGIN RAISERROR('Category is required.', 16, 1); RETURN; END

    IF @Test_Name IS NULL OR LTRIM(RTRIM(@Test_Name)) = ''
    BEGIN RAISERROR('Test Name is required.', 16, 1); RETURN; END

    SET @Test_Name = LTRIM(RTRIM(@Test_Name));

    -- Duplicate check
    IF EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE LOWER(Test_Name) = LOWER(@Test_Name) AND Test_ID <> @Test_ID AND IsDeleted = 0)
    BEGIN RAISERROR('A Test with the same name already exists.', 16, 1); RETURN; END

    UPDATE dbo.LabInvestigationMaster
    SET Department_ID      = @Department_ID,
        Category_ID        = @Category_ID,
        SubCategory_ID     = @SubCategory_ID,
        Sample_Type_ID     = @Sample_Type_ID,
        Method_ID          = @Method_ID,
        Unit_ID            = @Unit_ID,
        Test_Name          = @Test_Name,
        Reporting_Type     = ISNULL(@Reporting_Type, 'Numeric'),
        TAT_Hours          = ISNULL(@TAT_Hours, 24),
        NABL_Accredited    = ISNULL(@NABL_Accredited, 0),
        NABL_Scope_No      = @NABL_Scope_No,
        Is_Outsourced      = ISNULL(@Is_Outsourced, 0),
        Is_Profile_Test    = ISNULL(@Is_Profile_Test, 0),
        Applicable_Gender  = ISNULL(@Applicable_Gender, 'All'),
        Is_Billable        = ISNULL(@Is_Billable, 1),
        Age_Operator       = @Age_Operator,
        Applicable_Age     = @Applicable_Age,
        MRP                = ISNULL(@MRP, 0.00),
        Status             = @Status,
        ModifiedBy         = @UserId,
        ModifiedDate       = GETDATE()
    WHERE Test_ID = @Test_ID;
END
GO

PRINT 'Script 2013_lab_investigation_master_new_fields.sql executed successfully.';
GO
