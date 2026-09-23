-- =============================================
-- Add radiology-specific fields to LabDescriptiveTestTemplate
-- Modality, Body Part, Laterality, Contrast, Views, Preparation
-- =============================================

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabDescriptiveTestTemplate' AND COLUMN_NAME = 'Modality')
BEGIN
    ALTER TABLE LabDescriptiveTestTemplate ADD Modality NVARCHAR(50) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabDescriptiveTestTemplate' AND COLUMN_NAME = 'Body_Part')
BEGIN
    ALTER TABLE LabDescriptiveTestTemplate ADD Body_Part NVARCHAR(100) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabDescriptiveTestTemplate' AND COLUMN_NAME = 'Laterality')
BEGIN
    ALTER TABLE LabDescriptiveTestTemplate ADD Laterality NVARCHAR(20) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabDescriptiveTestTemplate' AND COLUMN_NAME = 'Contrast_Required')
BEGIN
    ALTER TABLE LabDescriptiveTestTemplate ADD Contrast_Required BIT NOT NULL DEFAULT 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabDescriptiveTestTemplate' AND COLUMN_NAME = 'Contrast_Agent')
BEGIN
    ALTER TABLE LabDescriptiveTestTemplate ADD Contrast_Agent NVARCHAR(100) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabDescriptiveTestTemplate' AND COLUMN_NAME = 'Views_Projections')
BEGIN
    ALTER TABLE LabDescriptiveTestTemplate ADD Views_Projections NVARCHAR(200) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabDescriptiveTestTemplate' AND COLUMN_NAME = 'Preparation_Instructions')
BEGIN
    ALTER TABLE LabDescriptiveTestTemplate ADD Preparation_Instructions NVARCHAR(1000) NULL;
END
GO

-- =============================================
-- Recreate GetList with new columns
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
        t.Modality,
        t.Body_Part,
        t.Laterality,
        t.Contrast_Required,
        t.Contrast_Agent,
        t.Views_Projections,
        t.Preparation_Instructions,
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
-- Recreate GetById with new columns
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
        t.Modality,
        t.Body_Part,
        t.Laterality,
        t.Contrast_Required,
        t.Contrast_Agent,
        t.Views_Projections,
        t.Preparation_Instructions,
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
-- Recreate Create with new columns
-- =============================================
IF OBJECT_ID('usp_Api_LabDescriptiveTestTemplate_Create', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabDescriptiveTestTemplate_Create;
GO

CREATE PROCEDURE usp_Api_LabDescriptiveTestTemplate_Create
    @Test_ID                   INT,
    @Section_Name              NVARCHAR(200),
    @Section_Sequence          INT = 1,
    @Is_Mandatory              BIT = 0,
    @Default_Content_Html      NVARCHAR(MAX) = NULL,
    @Placeholder_Tags          NVARCHAR(500) = NULL,
    @Modality                  NVARCHAR(50) = NULL,
    @Body_Part                 NVARCHAR(100) = NULL,
    @Laterality                NVARCHAR(20) = NULL,
    @Contrast_Required         BIT = 0,
    @Contrast_Agent            NVARCHAR(100) = NULL,
    @Views_Projections         NVARCHAR(200) = NULL,
    @Preparation_Instructions  NVARCHAR(1000) = NULL,
    @CompanyId                 INT = 1,
    @UserId                    INT = NULL,
    @NewId                     INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @Test_ID AND Section_Name = @Section_Name AND IsActive = 1)
    BEGIN
        RAISERROR('A template section with the same name already exists for this test.', 16, 1);
        RETURN;
    END

    INSERT INTO LabDescriptiveTestTemplate
        (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags,
         Modality, Body_Part, Laterality, Contrast_Required, Contrast_Agent, Views_Projections, Preparation_Instructions,
         IsActive, CompanyId, CreatedBy, CreatedDate)
    VALUES
        (@Test_ID, @Section_Name, @Section_Sequence, @Is_Mandatory, @Default_Content_Html, @Placeholder_Tags,
         @Modality, @Body_Part, @Laterality, @Contrast_Required, @Contrast_Agent, @Views_Projections, @Preparation_Instructions,
         1, @CompanyId, @UserId, GETDATE());

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- =============================================
-- Recreate Update with new columns
-- =============================================
IF OBJECT_ID('usp_Api_LabDescriptiveTestTemplate_Update', 'P') IS NOT NULL
    DROP PROCEDURE usp_Api_LabDescriptiveTestTemplate_Update;
GO

CREATE PROCEDURE usp_Api_LabDescriptiveTestTemplate_Update
    @Template_ID               INT,
    @Test_ID                   INT,
    @Section_Name              NVARCHAR(200),
    @Section_Sequence          INT = 1,
    @Is_Mandatory              BIT = 0,
    @Default_Content_Html      NVARCHAR(MAX) = NULL,
    @Placeholder_Tags          NVARCHAR(500) = NULL,
    @Modality                  NVARCHAR(50) = NULL,
    @Body_Part                 NVARCHAR(100) = NULL,
    @Laterality                NVARCHAR(20) = NULL,
    @Contrast_Required         BIT = 0,
    @Contrast_Agent            NVARCHAR(100) = NULL,
    @Views_Projections         NVARCHAR(200) = NULL,
    @Preparation_Instructions  NVARCHAR(1000) = NULL,
    @IsActive                  BIT = 1,
    @UserId                    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @Test_ID AND Section_Name = @Section_Name AND IsActive = 1 AND Template_ID <> @Template_ID)
    BEGIN
        RAISERROR('A template section with the same name already exists for this test.', 16, 1);
        RETURN;
    END

    UPDATE LabDescriptiveTestTemplate
    SET Test_ID                   = @Test_ID,
        Section_Name              = @Section_Name,
        Section_Sequence          = @Section_Sequence,
        Is_Mandatory              = @Is_Mandatory,
        Default_Content_Html      = @Default_Content_Html,
        Placeholder_Tags          = @Placeholder_Tags,
        Modality                  = @Modality,
        Body_Part                 = @Body_Part,
        Laterality                = @Laterality,
        Contrast_Required         = @Contrast_Required,
        Contrast_Agent            = @Contrast_Agent,
        Views_Projections         = @Views_Projections,
        Preparation_Instructions  = @Preparation_Instructions,
        IsActive                  = @IsActive,
        ModifiedBy                = @UserId,
        ModifiedDate              = GETDATE()
    WHERE Template_ID = @Template_ID;
END
GO
