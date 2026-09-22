-- =============================================
-- Lab Descriptive Test Template
-- Table + CRUD stored procedures
-- =============================================

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'LabDescriptiveTestTemplate')
BEGIN
    CREATE TABLE LabDescriptiveTestTemplate
    (
        Template_ID          INT IDENTITY(1,1) PRIMARY KEY,
        Test_ID              INT NOT NULL,
        Section_Name         NVARCHAR(200) NOT NULL,
        Section_Sequence     INT NOT NULL DEFAULT 1,
        Is_Mandatory         BIT NOT NULL DEFAULT 0,
        Default_Content_Html NVARCHAR(MAX) NULL,
        Placeholder_Tags     NVARCHAR(500) NULL,
        IsActive             BIT NOT NULL DEFAULT 1,
        CompanyId            INT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME NULL
    );
END
GO

-- =============================================
-- GetList
-- =============================================
IF OBJECT_ID('usp_Api_LabDescriptiveTestTemplate_GetList', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabDescriptiveTestTemplate_GetList;
GO

CREATE PROCEDURE usp_Api_LabDescriptiveTestTemplate_GetList
    @Status     BIT = NULL,
    @Search     NVARCHAR(200) = NULL,
    @TestId     INT = NULL,
    @CompanyId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.Template_ID,
        t.Test_ID,
        inv.Test_Name,
        inv.Test_Code,
        t.Section_Name,
        t.Section_Sequence,
        t.Is_Mandatory,
        t.Default_Content_Html,
        t.Placeholder_Tags,
        t.IsActive,
        t.CompanyId,
        t.CreatedBy,
        t.CreatedDate,
        t.ModifiedBy,
        t.ModifiedDate
    FROM LabDescriptiveTestTemplate t
    INNER JOIN LabInvestigationMaster inv ON inv.Test_ID = t.Test_ID
    WHERE (@CompanyId IS NULL OR t.CompanyId = @CompanyId)
      AND (@Status IS NULL OR t.IsActive = @Status)
      AND (@TestId IS NULL OR t.Test_ID = @TestId)
      AND (@Search IS NULL OR inv.Test_Name LIKE '%' + @Search + '%' OR inv.Test_Code LIKE '%' + @Search + '%' OR t.Section_Name LIKE '%' + @Search + '%')
    ORDER BY inv.Test_Name, t.Section_Sequence;
END
GO

-- =============================================
-- GetById
-- =============================================
IF OBJECT_ID('usp_Api_LabDescriptiveTestTemplate_GetById', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabDescriptiveTestTemplate_GetById;
GO

CREATE PROCEDURE usp_Api_LabDescriptiveTestTemplate_GetById
    @Template_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.Template_ID,
        t.Test_ID,
        inv.Test_Name,
        inv.Test_Code,
        t.Section_Name,
        t.Section_Sequence,
        t.Is_Mandatory,
        t.Default_Content_Html,
        t.Placeholder_Tags,
        t.IsActive,
        t.CompanyId,
        t.CreatedBy,
        t.CreatedDate,
        t.ModifiedBy,
        t.ModifiedDate
    FROM LabDescriptiveTestTemplate t
    INNER JOIN LabInvestigationMaster inv ON inv.Test_ID = t.Test_ID
    WHERE t.Template_ID = @Template_ID;
END
GO

-- =============================================
-- Create
-- =============================================
IF OBJECT_ID('usp_Api_LabDescriptiveTestTemplate_Create', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabDescriptiveTestTemplate_Create;
GO

CREATE PROCEDURE usp_Api_LabDescriptiveTestTemplate_Create
    @Test_ID              INT,
    @Section_Name         NVARCHAR(200),
    @Section_Sequence     INT = 1,
    @Is_Mandatory         BIT = 0,
    @Default_Content_Html NVARCHAR(MAX) = NULL,
    @Placeholder_Tags     NVARCHAR(500) = NULL,
    @CompanyId            INT = 1,
    @UserId               INT = NULL,
    @NewId                INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @Test_ID AND Section_Name = @Section_Name AND IsActive = 1)
    BEGIN
        RAISERROR('A template section with the same name already exists for this test.', 16, 1);
        RETURN;
    END

    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, CreatedBy, CreatedDate)
    VALUES (@Test_ID, @Section_Name, @Section_Sequence, @Is_Mandatory, @Default_Content_Html, @Placeholder_Tags, 1, @CompanyId, @UserId, GETDATE());

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- =============================================
-- Update
-- =============================================
IF OBJECT_ID('usp_Api_LabDescriptiveTestTemplate_Update', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabDescriptiveTestTemplate_Update;
GO

CREATE PROCEDURE usp_Api_LabDescriptiveTestTemplate_Update
    @Template_ID          INT,
    @Test_ID              INT,
    @Section_Name         NVARCHAR(200),
    @Section_Sequence     INT = 1,
    @Is_Mandatory         BIT = 0,
    @Default_Content_Html NVARCHAR(MAX) = NULL,
    @Placeholder_Tags     NVARCHAR(500) = NULL,
    @IsActive             BIT = 1,
    @UserId               INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @Test_ID AND Section_Name = @Section_Name AND IsActive = 1 AND Template_ID <> @Template_ID)
    BEGIN
        RAISERROR('A template section with the same name already exists for this test.', 16, 1);
        RETURN;
    END

    UPDATE LabDescriptiveTestTemplate
    SET Test_ID              = @Test_ID,
        Section_Name         = @Section_Name,
        Section_Sequence     = @Section_Sequence,
        Is_Mandatory         = @Is_Mandatory,
        Default_Content_Html = @Default_Content_Html,
        Placeholder_Tags     = @Placeholder_Tags,
        IsActive             = @IsActive,
        ModifiedBy           = @UserId,
        ModifiedDate         = GETDATE()
    WHERE Template_ID = @Template_ID;
END
GO

-- =============================================
-- ToggleStatus
-- =============================================
IF OBJECT_ID('usp_Api_LabDescriptiveTestTemplate_ToggleStatus', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabDescriptiveTestTemplate_ToggleStatus;
GO

CREATE PROCEDURE usp_Api_LabDescriptiveTestTemplate_ToggleStatus
    @Template_ID INT,
    @IsActive    BIT,
    @UserId      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE LabDescriptiveTestTemplate
    SET IsActive     = @IsActive,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE Template_ID = @Template_ID;
END
GO

-- =============================================
-- Delete
-- =============================================
IF OBJECT_ID('usp_Api_LabDescriptiveTestTemplate_Delete', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabDescriptiveTestTemplate_Delete;
GO

CREATE PROCEDURE usp_Api_LabDescriptiveTestTemplate_Delete
    @Template_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM LabDescriptiveTestTemplate WHERE Template_ID = @Template_ID;
END
GO

-- =============================================
-- GetRadiologyTests (for dropdown - tests under Radiology department)
-- =============================================
IF OBJECT_ID('usp_Api_LabDescriptiveTestTemplate_GetRadiologyTests', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabDescriptiveTestTemplate_GetRadiologyTests;
GO

CREATE PROCEDURE usp_Api_LabDescriptiveTestTemplate_GetRadiologyTests
    @CompanyId INT = NULL,
    @Search    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        inv.Test_ID,
        inv.Test_Code,
        inv.Test_Name
    FROM LabInvestigationMaster inv
    INNER JOIN DepartmentMaster dept ON dept.DeptId = inv.Department_ID
    WHERE dept.DeptName LIKE '%Radiology%'
      AND inv.IsActive = 1
      AND (@CompanyId IS NULL OR inv.CompanyId = @CompanyId)
      AND (@Search IS NULL OR inv.Test_Name LIKE '%' + @Search + '%' OR inv.Test_Code LIKE '%' + @Search + '%')
    ORDER BY inv.Test_Name;
END
GO
