-- ====================================================================================================
-- Script: 2016_lab_investigation_consent_required.sql
-- Description: Adds Is_Consent_Required column to dbo.LabInvestigationMaster and updates SPs.
-- Database:    Dev_EMR (SQL Server)
-- ====================================================================================================

USE [Dev_EMR];
GO

SET NOCOUNT ON;

PRINT 'Adding Is_Consent_Required column to dbo.LabInvestigationMaster...';

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabInvestigationMaster') AND name = 'Is_Consent_Required')
BEGIN
    ALTER TABLE dbo.LabInvestigationMaster ADD Is_Consent_Required BIT NOT NULL DEFAULT 0;
    PRINT 'Added Is_Consent_Required column to dbo.LabInvestigationMaster';
END
GO

-- 1. Update GetList
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
        inv.Is_Fasting_Required,
        inv.Sample_Quantity,
        inv.Sample_Quantity_Unit_ID,
        squ.Unit_Name AS Sample_Quantity_Unit_Name,
        squ.Unit_Symbol AS Sample_Quantity_Unit_Symbol,
        inv.Reported_Duration_Value,
        inv.Reported_Duration_Unit,
        inv.Is_Consent_Required,
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
    LEFT JOIN dbo.LabUnitMaster squ ON inv.Sample_Quantity_Unit_ID = squ.Unit_ID
    WHERE inv.IsDeleted = 0
      AND (@CompanyId IS NULL OR inv.CompanyId = @CompanyId)
      AND (@DepartmentId IS NULL OR inv.Department_ID = @DepartmentId)
      AND (@CategoryId IS NULL OR inv.Category_ID = @CategoryId)
      AND (@Status IS NULL OR inv.Status = @Status)
      AND (@Search IS NULL OR inv.Test_Name LIKE '%' + @Search + '%' OR inv.Test_Code LIKE '%' + @Search + '%')
    ORDER BY inv.Test_Name ASC;
END
GO

-- 2. Update GetById
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
        inv.Is_Fasting_Required,
        inv.Sample_Quantity,
        inv.Sample_Quantity_Unit_ID,
        squ.Unit_Name AS Sample_Quantity_Unit_Name,
        squ.Unit_Symbol AS Sample_Quantity_Unit_Symbol,
        inv.Reported_Duration_Value,
        inv.Reported_Duration_Unit,
        inv.Is_Consent_Required,
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
    LEFT JOIN dbo.LabUnitMaster squ ON inv.Sample_Quantity_Unit_ID = squ.Unit_ID
    WHERE inv.Test_ID = @Test_ID AND inv.IsDeleted = 0;
END
GO

-- 3. Update Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_Create
    @CompanyId                 INT = 1,
    @Department_ID             INT,
    @Category_ID               INT,
    @SubCategory_ID            INT = NULL,
    @Sample_Type_ID            INT = NULL,
    @Method_ID                 INT = NULL,
    @Unit_ID                   INT = NULL,
    @Test_Name                 NVARCHAR(200),
    @Reporting_Type            NVARCHAR(50),
    @TAT_Hours                 INT = 24,
    @NABL_Accredited           BIT = 0,
    @NABL_Scope_No             NVARCHAR(100) = NULL,
    @Is_Outsourced             BIT = 0,
    @Is_Profile_Test           BIT = 0,
    @Applicable_Gender         VARCHAR(20) = 'All',
    @Is_Billable               BIT = 1,
    @Age_Operator              VARCHAR(20) = NULL,
    @Applicable_Age            INT = NULL,
    @Is_Fasting_Required       BIT = 0,
    @Sample_Quantity           DECIMAL(18,2) = NULL,
    @Sample_Quantity_Unit_ID   INT = NULL,
    @Reported_Duration_Value   INT = NULL,
    @Reported_Duration_Unit    VARCHAR(20) = 'Days',
    @Is_Consent_Required       BIT = 0,
    @MRP                       DECIMAL(18,2) = 0.00,
    @Status                    BIT = 1,
    @UserId                    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_Name = @Test_Name AND Department_ID = @Department_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Investigation Master with the same Test Name already exists in this Department.', 16, 1);
        RETURN;
    END

    -- Generate Test_Code (e.g. LAB-10001)
    DECLARE @NextNum INT;
    SELECT @NextNum = ISNULL(MAX(Test_ID), 0) + 1 FROM dbo.LabInvestigationMaster;
    DECLARE @Test_Code NVARCHAR(50) = 'LAB-' + RIGHT('00000' + CAST(@NextNum AS NVARCHAR(10)), 5);

    INSERT INTO dbo.LabInvestigationMaster
    (
        CompanyId, Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID,
        Sample_Type_ID, Method_ID, Unit_ID, Reporting_Type, TAT_Hours, NABL_Accredited,
        NABL_Scope_No, Is_Outsourced, Is_Profile_Test, Applicable_Gender, Is_Billable,
        Age_Operator, Applicable_Age, Is_Fasting_Required, Sample_Quantity, Sample_Quantity_Unit_ID,
        Reported_Duration_Value, Reported_Duration_Unit, Is_Consent_Required, MRP, Status, IsDeleted, CreatedBy, CreatedDate
    )
    VALUES
    (
        @CompanyId, @Test_Code, @Test_Name, @Department_ID, @Category_ID, @SubCategory_ID,
        @Sample_Type_ID, @Method_ID, @Unit_ID, @Reporting_Type, @TAT_Hours, @NABL_Accredited,
        @NABL_Scope_No, @Is_Outsourced, @Is_Profile_Test, ISNULL(@Applicable_Gender, 'All'), ISNULL(@Is_Billable, 1),
        @Age_Operator, @Applicable_Age, ISNULL(@Is_Fasting_Required, 0), @Sample_Quantity, @Sample_Quantity_Unit_ID,
        @Reported_Duration_Value, ISNULL(@Reported_Duration_Unit, 'Days'), ISNULL(@Is_Consent_Required, 0), @MRP, @Status, 0, @UserId, GETDATE()
    );

    SELECT SCOPE_IDENTITY() AS Test_ID;
END
GO

-- 4. Update Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_Update
    @Test_ID                   INT,
    @Department_ID             INT,
    @Category_ID               INT,
    @SubCategory_ID            INT = NULL,
    @Sample_Type_ID            INT = NULL,
    @Method_ID                 INT = NULL,
    @Unit_ID                   INT = NULL,
    @Test_Name                 NVARCHAR(200),
    @Reporting_Type            NVARCHAR(50),
    @TAT_Hours                 INT = 24,
    @NABL_Accredited           BIT = 0,
    @NABL_Scope_No             NVARCHAR(100) = NULL,
    @Is_Outsourced             BIT = 0,
    @Is_Profile_Test           BIT = 0,
    @Applicable_Gender         VARCHAR(20) = 'All',
    @Is_Billable               BIT = 1,
    @Age_Operator              VARCHAR(20) = NULL,
    @Applicable_Age            INT = NULL,
    @Is_Fasting_Required       BIT = 0,
    @Sample_Quantity           DECIMAL(18,2) = NULL,
    @Sample_Quantity_Unit_ID   INT = NULL,
    @Reported_Duration_Value   INT = NULL,
    @Reported_Duration_Unit    VARCHAR(20) = 'Days',
    @Is_Consent_Required       BIT = 0,
    @MRP                       DECIMAL(18,2) = 0.00,
    @Status                    BIT = 1,
    @UserId                    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_Name = @Test_Name AND Department_ID = @Department_ID AND Test_ID <> @Test_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Another Investigation Master with the same Test Name already exists in this Department.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabInvestigationMaster
    SET Department_ID             = @Department_ID,
        Category_ID               = @Category_ID,
        SubCategory_ID            = @SubCategory_ID,
        Sample_Type_ID            = @Sample_Type_ID,
        Method_ID                 = @Method_ID,
        Unit_ID                   = @Unit_ID,
        Test_Name                 = @Test_Name,
        Reporting_Type            = @Reporting_Type,
        TAT_Hours                 = @TAT_Hours,
        NABL_Accredited           = @NABL_Accredited,
        NABL_Scope_No             = @NABL_Scope_No,
        Is_Outsourced             = @Is_Outsourced,
        Is_Profile_Test           = @Is_Profile_Test,
        Applicable_Gender         = ISNULL(@Applicable_Gender, 'All'),
        Is_Billable               = ISNULL(@Is_Billable, 1),
        Age_Operator              = @Age_Operator,
        Applicable_Age            = @Applicable_Age,
        Is_Fasting_Required       = ISNULL(@Is_Fasting_Required, 0),
        Sample_Quantity           = @Sample_Quantity,
        Sample_Quantity_Unit_ID   = @Sample_Quantity_Unit_ID,
        Reported_Duration_Value   = @Reported_Duration_Value,
        Reported_Duration_Unit    = ISNULL(@Reported_Duration_Unit, 'Days'),
        Is_Consent_Required       = ISNULL(@Is_Consent_Required, 0),
        MRP                       = @MRP,
        Status                    = @Status,
        ModifiedBy                = @UserId,
        ModifiedDate              = GETDATE()
    WHERE Test_ID = @Test_ID AND IsDeleted = 0;
END
GO

PRINT 'Investigation Master Is_Consent_Required migration completed successfully.';
GO
