-- ====================================================================================================
-- Script: 2004_lab_unit_master.sql
-- Description: Creates dbo.LabUnitMaster table and Stored Procedures for Unit Master
--              under Master -> General Master & Master -> Lab Master -> Unit Master.
-- ====================================================================================================

-- 1. Create dbo.LabUnitMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabUnitMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabUnitMaster
    (
        Unit_ID             INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId           INT NOT NULL DEFAULT 1,
        Unit_Name           NVARCHAR(150) NOT NULL,
        Unit_Code           NVARCHAR(50) NOT NULL,
        Unit_Symbol         NVARCHAR(50) NULL,
        Conversion_Factor   DECIMAL(18, 6) NULL DEFAULT 1.0,
        Display_Order       INT NOT NULL DEFAULT 1,
        Status              BIT NOT NULL DEFAULT 1,
        IsDeleted           BIT NOT NULL DEFAULT 0,
        CreatedBy           INT NULL,
        CreatedDate         DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy          INT NULL,
        ModifiedDate        DATETIME2 NULL
    );
    CREATE INDEX IX_LabUnitMaster_Status ON dbo.LabUnitMaster(Status);
    CREATE INDEX IX_LabUnitMaster_Code ON dbo.LabUnitMaster(Unit_Code);
    PRINT 'Created table dbo.LabUnitMaster';
END
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabUnitMaster') AND name = 'BranchId')
    BEGIN
        DROP INDEX IF EXISTS IX_LabUnitMaster_Branch_Status ON dbo.LabUnitMaster;
        DECLARE @ConstraintName NVARCHAR(200);
        SELECT @ConstraintName = d.name
        FROM sys.default_constraints d
        INNER JOIN sys.columns c ON d.parent_object_id = c.object_id AND d.parent_column_id = c.column_id
        WHERE d.parent_object_id = OBJECT_ID('dbo.LabUnitMaster') AND c.name = 'BranchId';
        IF @ConstraintName IS NOT NULL
            EXEC('ALTER TABLE dbo.LabUnitMaster DROP CONSTRAINT ' + @ConstraintName);

        ALTER TABLE dbo.LabUnitMaster DROP COLUMN BranchId;
        PRINT 'Dropped BranchId column from dbo.LabUnitMaster';
    END

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabUnitMaster') AND name = 'IsDeleted')
    BEGIN
        ALTER TABLE dbo.LabUnitMaster ADD IsDeleted BIT NOT NULL DEFAULT 0;
        PRINT 'Added IsDeleted column to dbo.LabUnitMaster';
    END

    PRINT 'Table dbo.LabUnitMaster already exists';
END
GO

-- 2. Stored Procedure: usp_Api_LabUnitMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabUnitMaster_GetList
    @Status          BIT = NULL,
    @Search          NVARCHAR(100) = NULL,
    @CompanyId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        u.Unit_ID,
        u.CompanyId,
        u.Unit_Name,
        u.Unit_Code,
        u.Unit_Symbol,
        u.Conversion_Factor,
        u.Display_Order,
        u.Status,
        u.CreatedBy,
        u.CreatedDate,
        u.ModifiedBy,
        u.ModifiedDate
    FROM dbo.LabUnitMaster u
    WHERE u.IsDeleted = 0
      AND (@Status IS NULL OR u.Status = @Status)
      AND (@CompanyId IS NULL OR u.CompanyId = @CompanyId)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR 
           u.Unit_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR 
           u.Unit_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           u.Unit_Symbol LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY u.Display_Order ASC, u.Unit_Name ASC;
END
GO

-- 3. Stored Procedure: usp_Api_LabUnitMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabUnitMaster_GetById
    @Unit_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        u.Unit_ID,
        u.CompanyId,
        u.Unit_Name,
        u.Unit_Code,
        u.Unit_Symbol,
        u.Conversion_Factor,
        u.Display_Order,
        u.Status,
        u.CreatedBy,
        u.CreatedDate,
        u.ModifiedBy,
        u.ModifiedDate
    FROM dbo.LabUnitMaster u
    WHERE u.Unit_ID = @Unit_ID AND u.IsDeleted = 0;
END
GO

-- 4. Stored Procedure: usp_Api_LabUnitMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabUnitMaster_Create
    @Unit_Name          NVARCHAR(150),
    @Unit_Symbol        NVARCHAR(50) = NULL,
    @Conversion_Factor  DECIMAL(18, 6) = 1.0,
    @Display_Order      INT = 1,
    @CompanyId          INT = 1,
    @UserId             INT = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @Unit_Name IS NULL OR LTRIM(RTRIM(@Unit_Name)) = ''
    BEGIN
        RAISERROR('Unit Name is required.', 16, 1);
        RETURN;
    END

    SET @Unit_Name = LTRIM(RTRIM(@Unit_Name));
    SET @Unit_Symbol = LTRIM(RTRIM(@Unit_Symbol));

    IF EXISTS (
        SELECT 1 FROM dbo.LabUnitMaster 
        WHERE LOWER(Unit_Name) = LOWER(@Unit_Name)
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A Unit with the same name already exists.', 16, 1);
        RETURN;
    END

    DECLARE @NextNum INT;
    DECLARE @GeneratedCode NVARCHAR(50);

    SELECT @NextNum = ISNULL(MAX(Unit_ID), 0) + 1 FROM dbo.LabUnitMaster;
    SET @GeneratedCode = 'UNT' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);

    WHILE EXISTS (SELECT 1 FROM dbo.LabUnitMaster WHERE Unit_Code = @GeneratedCode)
    BEGIN
        SET @NextNum = @NextNum + 1;
        SET @GeneratedCode = 'UNT' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
    END

    INSERT INTO dbo.LabUnitMaster
    (
        CompanyId,
        Unit_Name,
        Unit_Code,
        Unit_Symbol,
        Conversion_Factor,
        Display_Order,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Unit_Name,
        @GeneratedCode,
        @Unit_Symbol,
        ISNULL(@Conversion_Factor, 1.0),
        ISNULL(@Display_Order, 1),
        1,
        @UserId,
        GETDATE()
    );

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_Api_LabUnitMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabUnitMaster_Update
    @Unit_ID            INT,
    @Unit_Name          NVARCHAR(150),
    @Unit_Symbol        NVARCHAR(50) = NULL,
    @Conversion_Factor  DECIMAL(18, 6) = 1.0,
    @Display_Order      INT = 1,
    @Status             BIT = 1,
    @UserId             INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabUnitMaster WHERE Unit_ID = @Unit_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Unit record not found.', 16, 1);
        RETURN;
    END

    IF @Unit_Name IS NULL OR LTRIM(RTRIM(@Unit_Name)) = ''
    BEGIN
        RAISERROR('Unit Name is required.', 16, 1);
        RETURN;
    END

    SET @Unit_Name = LTRIM(RTRIM(@Unit_Name));
    SET @Unit_Symbol = LTRIM(RTRIM(@Unit_Symbol));

    IF EXISTS (
        SELECT 1 FROM dbo.LabUnitMaster 
        WHERE LOWER(Unit_Name) = LOWER(@Unit_Name)
          AND Unit_ID <> @Unit_ID
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A Unit with the same name already exists.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabUnitMaster
    SET Unit_Name         = @Unit_Name,
        Unit_Symbol       = @Unit_Symbol,
        Conversion_Factor = ISNULL(@Conversion_Factor, 1.0),
        Display_Order     = ISNULL(@Display_Order, 1),
        Status            = @Status,
        ModifiedBy        = @UserId,
        ModifiedDate      = GETDATE()
    WHERE Unit_ID = @Unit_ID;
END
GO

-- 6. Stored Procedure: usp_Api_LabUnitMaster_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabUnitMaster_ToggleStatus
    @Unit_ID INT,
    @Status  BIT,
    @UserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabUnitMaster WHERE Unit_ID = @Unit_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Unit record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabUnitMaster
    SET Status       = @Status,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE Unit_ID = @Unit_ID;
END
GO

-- 7. Stored Procedure: usp_Api_LabUnitMaster_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabUnitMaster_Delete
    @Unit_ID INT,
    @UserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabUnitMaster WHERE Unit_ID = @Unit_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Unit record not found or already deleted.', 16, 1);
        RETURN;
    END

    -- Check if used in Investigation Master
    IF EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Unit_ID = @Unit_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Cannot delete Unit because it is used in one or more Test Investigations.', 16, 1);
        RETURN;
    END

    -- Check if used in Sample Type Master
    IF EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Unit_ID = @Unit_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Cannot delete Unit because it is used in one or more Sample Types.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabUnitMaster
    SET IsDeleted = 1,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
    WHERE Unit_ID = @Unit_ID;
END
GO
