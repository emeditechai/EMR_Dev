-- ====================================================================================================
-- Script: 100_lab_investigation_master.sql
-- Description: Creates dbo.LabInvestigationMaster table and Stored Procedures for Investigation Master
--              under Lab -> Investigation Master.
-- ====================================================================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabInvestigationMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabInvestigationMaster
    (
        Test_ID          INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId        INT NOT NULL DEFAULT 1,
        BranchId         INT NOT NULL DEFAULT 1,
        Test_Code        NVARCHAR(50) NOT NULL,
        Test_Name        NVARCHAR(200) NOT NULL,
        Department_ID    INT NOT NULL,
        Category_ID      INT NOT NULL,
        SubCategory_ID   INT NULL,
        Sample_Type_ID   INT NULL,
        Method_ID        INT NULL,
        Unit_ID          INT NULL,
        Reporting_Type   NVARCHAR(50) NOT NULL DEFAULT 'Numeric', -- Numeric / Text / Descriptive / Image / Template
        TAT_Hours        INT NULL DEFAULT 24,
        NABL_Accredited  BIT NOT NULL DEFAULT 0,
        NABL_Scope_No    NVARCHAR(100) NULL,
        Is_Outsourced    BIT NOT NULL DEFAULT 0,
        MRP              DECIMAL(18,2) NOT NULL DEFAULT 0.00,
        Status           BIT NOT NULL DEFAULT 1,
        CreatedBy        INT NULL,
        CreatedDate      DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy       INT NULL,
        ModifiedDate     DATETIME2 NULL,
        CONSTRAINT FK_LabInvestigationMaster_Department FOREIGN KEY (Department_ID) REFERENCES dbo.DepartmentMaster(DeptId),
        CONSTRAINT FK_LabInvestigationMaster_Category FOREIGN KEY (Category_ID) REFERENCES dbo.LabTestCategoryMaster(Category_ID),
        CONSTRAINT FK_LabInvestigationMaster_SubCategory FOREIGN KEY (SubCategory_ID) REFERENCES dbo.LabTestSubCategoryMaster(SubCategory_ID),
        CONSTRAINT FK_LabInvestigationMaster_SampleType FOREIGN KEY (Sample_Type_ID) REFERENCES dbo.LabSampleTypeMaster(Sample_Type_ID),
        CONSTRAINT FK_LabInvestigationMaster_Method FOREIGN KEY (Method_ID) REFERENCES dbo.LabTestMethodMaster(Method_ID),
        CONSTRAINT FK_LabInvestigationMaster_Unit FOREIGN KEY (Unit_ID) REFERENCES dbo.LabUnitMaster(Unit_ID)
    );

    CREATE INDEX IX_LabInvestigationMaster_Department ON dbo.LabInvestigationMaster(Department_ID);
    CREATE INDEX IX_LabInvestigationMaster_Category ON dbo.LabInvestigationMaster(Category_ID);
    CREATE INDEX IX_LabInvestigationMaster_Branch_Status ON dbo.LabInvestigationMaster(BranchId, Status);
    CREATE INDEX IX_LabInvestigationMaster_Code ON dbo.LabInvestigationMaster(Test_Code);
    PRINT 'Created table dbo.LabInvestigationMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.LabInvestigationMaster already exists';
END
GO

-- 2. Stored Procedure: usp_Api_LabInvestigationMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_GetList
    @BranchId        INT = NULL,
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
        inv.BranchId,
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
    WHERE (@BranchId IS NULL OR inv.BranchId = @BranchId)
      AND (@DepartmentId IS NULL OR inv.Department_ID = @DepartmentId)
      AND (@CategoryId IS NULL OR inv.Category_ID = @CategoryId)
      AND (@Status IS NULL OR inv.Status = @Status)
      AND (@CompanyId IS NULL OR inv.CompanyId = @CompanyId)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR 
           inv.Test_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR 
           inv.Test_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           cat.Category_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY inv.Test_Name ASC;
END
GO

-- 3. Stored Procedure: usp_Api_LabInvestigationMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_GetById
    @Test_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        inv.Test_ID,
        inv.CompanyId,
        inv.BranchId,
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
    WHERE inv.Test_ID = @Test_ID;
END
GO

-- 4. Stored Procedure: usp_Api_LabInvestigationMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_Create
    @CompanyId       INT = 1,
    @BranchId        INT = 1,
    @Department_ID   INT,
    @Category_ID     INT,
    @SubCategory_ID  INT = NULL,
    @Sample_Type_ID  INT = NULL,
    @Method_ID       INT = NULL,
    @Unit_ID         INT = NULL,
    @Test_Name       NVARCHAR(200),
    @Reporting_Type  NVARCHAR(50) = 'Numeric',
    @TAT_Hours       INT = 24,
    @NABL_Accredited BIT = 0,
    @NABL_Scope_No   NVARCHAR(100) = NULL,
    @Is_Outsourced   BIT = 0,
    @MRP             DECIMAL(18,2) = 0.00,
    @Status          BIT = 1,
    @UserId          INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Validations
    IF @Department_ID IS NULL OR @Department_ID <= 0
    BEGIN
        RAISERROR('Department is required.', 16, 1);
        RETURN;
    END

    IF @Category_ID IS NULL OR @Category_ID <= 0
    BEGIN
        RAISERROR('Category is required.', 16, 1);
        RETURN;
    END

    IF @Test_Name IS NULL OR LTRIM(RTRIM(@Test_Name)) = ''
    BEGIN
        RAISERROR('Test Name is required.', 16, 1);
        RETURN;
    END

    SET @Test_Name = LTRIM(RTRIM(@Test_Name));

    -- Duplicate check per Branch & Department
    IF EXISTS (
        SELECT 1 FROM dbo.LabInvestigationMaster 
        WHERE BranchId = @BranchId AND LOWER(Test_Name) = LOWER(@Test_Name)
    )
    BEGIN
        RAISERROR('A Test with the same name already exists.', 16, 1);
        RETURN;
    END

    -- Auto-generate Test_Code
    DECLARE @NextId INT;
    DECLARE @GeneratedCode NVARCHAR(50);

    SELECT @NextId = ISNULL(MAX(Test_ID), 0) + 1 FROM dbo.LabInvestigationMaster;
    SET @GeneratedCode = 'TST' + RIGHT('0000' + CAST(@NextId AS NVARCHAR(10)), 4);

    INSERT INTO dbo.LabInvestigationMaster
    (
        CompanyId, BranchId, Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID,
        Sample_Type_ID, Method_ID, Unit_ID, Reporting_Type, TAT_Hours, NABL_Accredited,
        NABL_Scope_No, Is_Outsourced, MRP, Status, CreatedBy, CreatedDate
    )
    VALUES
    (
        @CompanyId, @BranchId, @GeneratedCode, @Test_Name, @Department_ID, @Category_ID, @SubCategory_ID,
        @Sample_Type_ID, @Method_ID, @Unit_ID, ISNULL(@Reporting_Type, 'Numeric'), ISNULL(@TAT_Hours, 24), ISNULL(@NABL_Accredited, 0),
        @NABL_Scope_No, ISNULL(@Is_Outsourced, 0), ISNULL(@MRP, 0.00), ISNULL(@Status, 1), @UserId, GETDATE()
    );

    SELECT SCOPE_IDENTITY() AS NewId;
END
GO

-- 5. Stored Procedure: usp_Api_LabInvestigationMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_Update
    @Test_ID         INT,
    @Department_ID   INT,
    @Category_ID     INT,
    @SubCategory_ID  INT = NULL,
    @Sample_Type_ID  INT = NULL,
    @Method_ID       INT = NULL,
    @Unit_ID         INT = NULL,
    @Test_Name       NVARCHAR(200),
    @Reporting_Type  NVARCHAR(50) = 'Numeric',
    @TAT_Hours       INT = 24,
    @NABL_Accredited BIT = 0,
    @NABL_Scope_No   NVARCHAR(100) = NULL,
    @Is_Outsourced   BIT = 0,
    @MRP             DECIMAL(18,2) = 0.00,
    @Status          BIT = 1,
    @UserId          INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID)
    BEGIN
        RAISERROR('Investigation Master record not found.', 16, 1);
        RETURN;
    END

    IF @Department_ID IS NULL OR @Department_ID <= 0
    BEGIN
        RAISERROR('Department is required.', 16, 1);
        RETURN;
    END

    IF @Category_ID IS NULL OR @Category_ID <= 0
    BEGIN
        RAISERROR('Category is required.', 16, 1);
        RETURN;
    END

    IF @Test_Name IS NULL OR LTRIM(RTRIM(@Test_Name)) = ''
    BEGIN
        RAISERROR('Test Name is required.', 16, 1);
        RETURN;
    END

    SET @Test_Name = LTRIM(RTRIM(@Test_Name));

    DECLARE @CurrentBranchId INT;
    SELECT @CurrentBranchId = BranchId FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID;

    IF EXISTS (
        SELECT 1 FROM dbo.LabInvestigationMaster 
        WHERE BranchId = @CurrentBranchId 
          AND LOWER(Test_Name) = LOWER(@Test_Name) 
          AND Test_ID <> @Test_ID
    )
    BEGIN
        RAISERROR('A Test with the same name already exists.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabInvestigationMaster
    SET Department_ID   = @Department_ID,
        Category_ID     = @Category_ID,
        SubCategory_ID  = @SubCategory_ID,
        Sample_Type_ID  = @Sample_Type_ID,
        Method_ID       = @Method_ID,
        Unit_ID         = @Unit_ID,
        Test_Name       = @Test_Name,
        Reporting_Type  = ISNULL(@Reporting_Type, 'Numeric'),
        TAT_Hours       = ISNULL(@TAT_Hours, 24),
        NABL_Accredited = ISNULL(@NABL_Accredited, 0),
        NABL_Scope_No   = @NABL_Scope_No,
        Is_Outsourced   = ISNULL(@Is_Outsourced, 0),
        MRP             = ISNULL(@MRP, 0.00),
        Status          = @Status,
        ModifiedBy      = @UserId,
        ModifiedDate    = GETDATE()
    WHERE Test_ID = @Test_ID;
END
GO

-- 6. Stored Procedure: usp_Api_LabInvestigationMaster_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_ToggleStatus
    @Test_ID INT,
    @Status  BIT,
    @UserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID)
    BEGIN
        RAISERROR('Investigation Master record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabInvestigationMaster
    SET Status       = @Status,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE Test_ID = @Test_ID;
END
GO

-- 7. Stored Procedure: usp_Api_LabInvestigationMaster_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_Delete
    @Test_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID)
    BEGIN
        RAISERROR('Investigation Master record not found.', 16, 1);
        RETURN;
    END

    DELETE FROM dbo.LabInvestigationMaster
    WHERE Test_ID = @Test_ID;
END
GO
