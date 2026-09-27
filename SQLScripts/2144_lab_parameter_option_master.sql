-- =============================================
-- Script : 2144_lab_parameter_option_master.sql
-- Purpose: Parameter Option Master — table and stored procedures.
-- CAP/NABL: Audit trail (Created/Modified By/Date), soft delete, company scope.
-- =============================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabParameterOptionMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabParameterOptionMaster
    (
        Option_ID INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId                INT NOT NULL DEFAULT 1,
        Option_Code NVARCHAR(50) NOT NULL,
        Test_ID                  INT NOT NULL,
        Option_Text              NVARCHAR(100) NOT NULL,
        Display_Order            INT NOT NULL DEFAULT 1,
        Is_Abnormal              BIT NOT NULL DEFAULT 0,
        Is_Default               BIT NOT NULL DEFAULT 0,
        Status                   BIT NOT NULL DEFAULT 1,
        IsDeleted                BIT NOT NULL DEFAULT 0,
        CreatedBy                INT NULL,
        CreatedDate              DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy               INT NULL,
        ModifiedDate             DATETIME2 NULL
    );
    CREATE INDEX IX_LabParameterOptionMaster_Status ON dbo.LabParameterOptionMaster(Status);
    CREATE UNIQUE INDEX UX_LabParameterOptionMaster_Code ON dbo.LabParameterOptionMaster(Option_Code);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabParameterOptionMaster_GetList
    @Status    BIT = NULL,
    @Search    NVARCHAR(100) = NULL,
    @CompanyId INT = NULL,
    @Test_ID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Option_ID,
        m.CompanyId,
        m.Option_Code,
        m.Test_ID,
        j0.Test_Name AS Test_Name,
        m.Option_Text,
        m.Display_Order,
        m.Is_Abnormal,
        m.Is_Default,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabParameterOptionMaster m
    LEFT JOIN dbo.LabInvestigationMaster j0 ON j0.Test_ID = m.Test_ID
    WHERE m.IsDeleted = 0
      AND (@Status IS NULL OR m.Status = @Status)
      AND (@CompanyId IS NULL OR m.CompanyId = @CompanyId)
      AND (@Test_ID IS NULL OR m.Test_ID = @Test_ID)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR
           m.Option_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Option_Text LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY j0.Test_Name, m.Display_Order, m.Option_Text;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabParameterOptionMaster_GetById
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Option_ID,
        m.CompanyId,
        m.Option_Code,
        m.Test_ID,
        j0.Test_Name AS Test_Name,
        m.Option_Text,
        m.Display_Order,
        m.Is_Abnormal,
        m.Is_Default,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabParameterOptionMaster m
    LEFT JOIN dbo.LabInvestigationMaster j0 ON j0.Test_ID = m.Test_ID
    WHERE m.Option_ID = @Id AND m.IsDeleted = 0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabParameterOptionMaster_Create
    @Test_ID                INT,
    @Option_Text            NVARCHAR(100),
    @Display_Order          INT = 1,
    @Is_Abnormal            BIT = 0,
    @Is_Default             BIT = 0,
    @CompanyId              INT = 1,
    @UserId                 INT = NULL,
    @NewId                  INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Option_Text = NULLIF(LTRIM(RTRIM(@Option_Text)), '');
    IF @Option_Text IS NULL
    BEGIN
        RAISERROR('Option Text is required.', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID)
    BEGIN
        RAISERROR('Test (Parameter) is invalid.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.LabParameterOptionMaster WHERE Test_ID = @Test_ID AND LOWER(Option_Text) = LOWER(@Option_Text) AND CompanyId = @CompanyId AND IsDeleted = 0)
    BEGIN
        RAISERROR('This option already exists for the selected test.', 16, 1);
        RETURN;
    END

    DECLARE @Next INT, @GeneratedCode NVARCHAR(50), @RowId INT;
    SELECT @Next = ISNULL(MAX(Option_ID), 0) + 1 FROM dbo.LabParameterOptionMaster;
    SET @GeneratedCode = 'OPT' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    WHILE EXISTS (SELECT 1 FROM dbo.LabParameterOptionMaster WHERE Option_Code = @GeneratedCode)
    BEGIN
        SET @Next += 1;
        SET @GeneratedCode = 'OPT' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    END

    BEGIN TRY
        INSERT INTO dbo.LabParameterOptionMaster
        (
        CompanyId,
        Option_Code,
        Test_ID,
        Option_Text,
        Display_Order,
        Is_Abnormal,
        Is_Default,
        Status,
        CreatedBy,
        CreatedDate
        )
        VALUES
        (
        @CompanyId,
        @GeneratedCode,
        @Test_ID,
        @Option_Text,
        @Display_Order,
        @Is_Abnormal,
        @Is_Default,
        1,
        @UserId,
        GETDATE()
        );
        SET @RowId = SCOPE_IDENTITY();
        SET @NewId = @RowId;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabParameterOptionMaster_Update
    @Id INT,
    @Test_ID                INT,
    @Option_Text            NVARCHAR(100),
    @Display_Order          INT = 1,
    @Is_Abnormal            BIT = 0,
    @Is_Default             BIT = 0,
    @Status                 BIT = 1,
    @UserId                 INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabParameterOptionMaster WHERE Option_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Parameter Option record not found.', 16, 1);
        RETURN;
    END
    SET @Option_Text = NULLIF(LTRIM(RTRIM(@Option_Text)), '');
    IF @Option_Text IS NULL
    BEGIN
        RAISERROR('Option Text is required.', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID)
    BEGIN
        RAISERROR('Test (Parameter) is invalid.', 16, 1);
        RETURN;
    END

    DECLARE @CompanyId INT = (SELECT CompanyId FROM dbo.LabParameterOptionMaster WHERE Option_ID = @Id), @RowId INT = @Id;
    IF EXISTS (SELECT 1 FROM dbo.LabParameterOptionMaster WHERE Test_ID = @Test_ID AND LOWER(Option_Text) = LOWER(@Option_Text) AND CompanyId = @CompanyId AND Option_ID <> @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('This option already exists for the selected test.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        UPDATE dbo.LabParameterOptionMaster
        SET Test_ID = @Test_ID,
        Option_Text = @Option_Text,
        Display_Order = @Display_Order,
        Is_Abnormal = @Is_Abnormal,
        Is_Default = @Is_Default,
        Status = @Status,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
        WHERE Option_ID = @Id;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabParameterOptionMaster_ToggleStatus
    @Id     INT,
    @Status BIT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabParameterOptionMaster WHERE Option_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Parameter Option record not found.', 16, 1);
        RETURN;
    END
    UPDATE dbo.LabParameterOptionMaster SET Status = @Status, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Option_ID = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabParameterOptionMaster_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabParameterOptionMaster WHERE Option_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Parameter Option record not found or already deleted.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabParameterOptionMaster SET IsDeleted = 1, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Option_ID = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabParameterOptionMaster_LookupTests
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Test_ID AS Id, Test_Name + ' (' + Test_Code + ')' AS Text FROM dbo.LabInvestigationMaster WHERE IsDeleted = 0 AND Status = 1 AND Reporting_Type = 'Select' AND (@CompanyId IS NULL OR CompanyId = @CompanyId) ORDER BY Test_Name;
END
GO

PRINT 'Parameter Option Master ready.';
