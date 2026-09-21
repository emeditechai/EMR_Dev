-- =============================================
-- Lab Formula Parameter Master
-- Table + CRUD stored procedures
-- =============================================

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'LabFormulaParameterMaster')
BEGIN
    CREATE TABLE LabFormulaParameterMaster
    (
        Parameter_ID        INT IDENTITY(1,1) PRIMARY KEY,
        Test_ID             INT NOT NULL,
        Formula_Expression  NVARCHAR(1000) NOT NULL,
        Rounding_Precision  INT NOT NULL DEFAULT 2,
        Validity_Condition  NVARCHAR(500) NULL,
        IsActive            BIT NOT NULL DEFAULT 1,
        CompanyId           INT NOT NULL DEFAULT 1,
        CreatedBy           INT NULL,
        CreatedDate         DATETIME NOT NULL DEFAULT GETDATE(),
        ModifiedBy          INT NULL,
        ModifiedDate        DATETIME NULL
    );
END
GO

-- =============================================
-- GetList
-- =============================================
IF OBJECT_ID('usp_Api_LabFormulaParameterMaster_GetList', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabFormulaParameterMaster_GetList;
GO

CREATE PROCEDURE usp_Api_LabFormulaParameterMaster_GetList
    @Status     BIT = NULL,
    @Search     NVARCHAR(200) = NULL,
    @CompanyId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        fp.Parameter_ID,
        fp.Test_ID,
        inv.Test_Name,
        inv.Test_Code,
        fp.Formula_Expression,
        fp.Rounding_Precision,
        fp.Validity_Condition,
        fp.IsActive,
        fp.CompanyId,
        fp.CreatedBy,
        fp.CreatedDate,
        fp.ModifiedBy,
        fp.ModifiedDate
    FROM LabFormulaParameterMaster fp
    INNER JOIN LabInvestigationMaster inv ON inv.Test_ID = fp.Test_ID
    WHERE (@CompanyId IS NULL OR fp.CompanyId = @CompanyId)
      AND (@Status IS NULL OR fp.IsActive = @Status)
      AND (@Search IS NULL OR inv.Test_Name LIKE '%' + @Search + '%' OR inv.Test_Code LIKE '%' + @Search + '%' OR fp.Formula_Expression LIKE '%' + @Search + '%')
    ORDER BY fp.Parameter_ID DESC;
END
GO

-- =============================================
-- GetById
-- =============================================
IF OBJECT_ID('usp_Api_LabFormulaParameterMaster_GetById', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabFormulaParameterMaster_GetById;
GO

CREATE PROCEDURE usp_Api_LabFormulaParameterMaster_GetById
    @Parameter_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        fp.Parameter_ID,
        fp.Test_ID,
        inv.Test_Name,
        inv.Test_Code,
        fp.Formula_Expression,
        fp.Rounding_Precision,
        fp.Validity_Condition,
        fp.IsActive,
        fp.CompanyId,
        fp.CreatedBy,
        fp.CreatedDate,
        fp.ModifiedBy,
        fp.ModifiedDate
    FROM LabFormulaParameterMaster fp
    INNER JOIN LabInvestigationMaster inv ON inv.Test_ID = fp.Test_ID
    WHERE fp.Parameter_ID = @Parameter_ID;
END
GO

-- =============================================
-- Create
-- =============================================
IF OBJECT_ID('usp_Api_LabFormulaParameterMaster_Create', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabFormulaParameterMaster_Create;
GO

CREATE PROCEDURE usp_Api_LabFormulaParameterMaster_Create
    @Test_ID            INT,
    @Formula_Expression NVARCHAR(1000),
    @Rounding_Precision INT = 2,
    @Validity_Condition NVARCHAR(500) = NULL,
    @CompanyId          INT = 1,
    @UserId             INT = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM LabFormulaParameterMaster WHERE Test_ID = @Test_ID AND IsActive = 1)
    BEGIN
        RAISERROR('An active formula already exists for this test.', 16, 1);
        RETURN;
    END

    INSERT INTO LabFormulaParameterMaster (Test_ID, Formula_Expression, Rounding_Precision, Validity_Condition, IsActive, CompanyId, CreatedBy, CreatedDate)
    VALUES (@Test_ID, @Formula_Expression, @Rounding_Precision, @Validity_Condition, 1, @CompanyId, @UserId, GETDATE());

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- =============================================
-- Update
-- =============================================
IF OBJECT_ID('usp_Api_LabFormulaParameterMaster_Update', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabFormulaParameterMaster_Update;
GO

CREATE PROCEDURE usp_Api_LabFormulaParameterMaster_Update
    @Parameter_ID       INT,
    @Test_ID            INT,
    @Formula_Expression NVARCHAR(1000),
    @Rounding_Precision INT = 2,
    @Validity_Condition NVARCHAR(500) = NULL,
    @IsActive           BIT = 1,
    @UserId             INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM LabFormulaParameterMaster WHERE Test_ID = @Test_ID AND IsActive = 1 AND Parameter_ID <> @Parameter_ID)
    BEGIN
        RAISERROR('An active formula already exists for this test.', 16, 1);
        RETURN;
    END

    UPDATE LabFormulaParameterMaster
    SET Test_ID            = @Test_ID,
        Formula_Expression = @Formula_Expression,
        Rounding_Precision = @Rounding_Precision,
        Validity_Condition = @Validity_Condition,
        IsActive           = @IsActive,
        ModifiedBy         = @UserId,
        ModifiedDate       = GETDATE()
    WHERE Parameter_ID = @Parameter_ID;
END
GO

-- =============================================
-- ToggleStatus
-- =============================================
IF OBJECT_ID('usp_Api_LabFormulaParameterMaster_ToggleStatus', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabFormulaParameterMaster_ToggleStatus;
GO

CREATE PROCEDURE usp_Api_LabFormulaParameterMaster_ToggleStatus
    @Parameter_ID INT,
    @IsActive     BIT,
    @UserId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE LabFormulaParameterMaster
    SET IsActive     = @IsActive,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE Parameter_ID = @Parameter_ID;
END
GO

-- =============================================
-- Delete
-- =============================================
IF OBJECT_ID('usp_Api_LabFormulaParameterMaster_Delete', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabFormulaParameterMaster_Delete;
GO

CREATE PROCEDURE usp_Api_LabFormulaParameterMaster_Delete
    @Parameter_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM LabFormulaParameterMaster WHERE Parameter_ID = @Parameter_ID;
END
GO

-- =============================================
-- GetNumericTests (for formula builder dropdown)
-- Returns only tests with Reporting_Type = 'Numeric' and IsActive = 1
-- =============================================
IF OBJECT_ID('usp_Api_LabFormulaParameterMaster_GetNumericTests', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabFormulaParameterMaster_GetNumericTests;
GO

CREATE PROCEDURE usp_Api_LabFormulaParameterMaster_GetNumericTests
    @CompanyId INT = NULL,
    @Search    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Test_ID,
        Test_Code,
        Test_Name
    FROM LabInvestigationMaster
    WHERE Reporting_Type = 'Numeric'
      AND IsActive = 1
      AND (@CompanyId IS NULL OR CompanyId = @CompanyId)
      AND (@Search IS NULL OR Test_Name LIKE '%' + @Search + '%' OR Test_Code LIKE '%' + @Search + '%')
    ORDER BY Test_Name;
END
GO
