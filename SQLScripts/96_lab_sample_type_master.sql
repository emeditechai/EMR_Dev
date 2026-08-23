-- ====================================================================================================
-- Script: 96_lab_sample_type_master.sql
-- Description: Creates dbo.LabSampleTypeMaster table and Stored Procedures for Sample Type Master
--              under Master -> Lab Master -> Sample Type. Updated to reference Unit_ID FK.
-- ====================================================================================================

-- 1. Create / Alter dbo.LabSampleTypeMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabSampleTypeMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabSampleTypeMaster
    (
        Sample_Type_ID       INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        BranchId             INT NOT NULL DEFAULT 1,
        Sample_Name          NVARCHAR(150) NOT NULL,
        Sample_Code          NVARCHAR(50) NOT NULL,
        Container_Type       NVARCHAR(100) NOT NULL,
        Volume_Value         DECIMAL(10, 2) NOT NULL,
        Unit_ID              INT NULL,
        Volume_Unit          NVARCHAR(50) NOT NULL,
        Volume_Required      NVARCHAR(50) NOT NULL, -- e.g. "5.00 mL"
        Storage_Temperature NVARCHAR(50) NULL,      -- e.g. "2 to 8 °C" or numerical string "4"
        Rejection_Criteria   NVARCHAR(500) NULL,
        Display_Order        INT NOT NULL DEFAULT 1,
        Status               BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL
    );
    CREATE INDEX IX_LabSampleTypeMaster_Branch_Status ON dbo.LabSampleTypeMaster(BranchId, Status);
    CREATE INDEX IX_LabSampleTypeMaster_Code ON dbo.LabSampleTypeMaster(Sample_Code);
    PRINT 'Created table dbo.LabSampleTypeMaster';
END
ELSE
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabSampleTypeMaster') AND name = 'Unit_ID')
    BEGIN
        ALTER TABLE dbo.LabSampleTypeMaster ADD Unit_ID INT NULL;
        PRINT 'Added Unit_ID column to dbo.LabSampleTypeMaster';
    END
END
GO

-- Add foreign key constraint if missing
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_LabSampleTypeMaster_Unit')
BEGIN
    ALTER TABLE dbo.LabSampleTypeMaster
    ADD CONSTRAINT FK_LabSampleTypeMaster_Unit FOREIGN KEY (Unit_ID) REFERENCES dbo.LabUnitMaster(Unit_ID);
    PRINT 'Added FK_LabSampleTypeMaster_Unit constraint';
END
GO

-- 2. Stored Procedure: usp_Api_LabSampleTypeMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleTypeMaster_GetList
    @BranchId        INT = NULL,
    @ContainerType   NVARCHAR(100) = NULL,
    @Status          BIT = NULL,
    @Search          NVARCHAR(100) = NULL,
    @CompanyId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        st.Sample_Type_ID,
        st.CompanyId,
        st.BranchId,
        st.Sample_Name,
        st.Sample_Code,
        st.Container_Type,
        st.Volume_Value,
        st.Unit_ID,
        st.Volume_Unit,
        u.Unit_Name,
        u.Unit_Symbol,
        st.Volume_Required,
        st.Storage_Temperature,
        st.Rejection_Criteria,
        st.Display_Order,
        st.Status,
        st.CreatedBy,
        st.CreatedDate,
        st.ModifiedBy,
        st.ModifiedDate
    FROM dbo.LabSampleTypeMaster st
    LEFT JOIN dbo.LabUnitMaster u ON st.Unit_ID = u.Unit_ID
    WHERE (@BranchId IS NULL OR st.BranchId = @BranchId)
      AND (@ContainerType IS NULL OR LTRIM(RTRIM(@ContainerType)) = '' OR st.Container_Type = @ContainerType)
      AND (@Status IS NULL OR st.Status = @Status)
      AND (@CompanyId IS NULL OR st.CompanyId = @CompanyId)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR 
           st.Sample_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR 
           st.Sample_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           st.Container_Type LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           st.Volume_Unit LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY st.Display_Order ASC, st.Sample_Name ASC;
END
GO

-- 3. Stored Procedure: usp_Api_LabSampleTypeMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleTypeMaster_GetById
    @Sample_Type_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        st.Sample_Type_ID,
        st.CompanyId,
        st.BranchId,
        st.Sample_Name,
        st.Sample_Code,
        st.Container_Type,
        st.Volume_Value,
        st.Unit_ID,
        st.Volume_Unit,
        u.Unit_Name,
        u.Unit_Symbol,
        st.Volume_Required,
        st.Storage_Temperature,
        st.Rejection_Criteria,
        st.Display_Order,
        st.Status,
        st.CreatedBy,
        st.CreatedDate,
        st.ModifiedBy,
        st.ModifiedDate
    FROM dbo.LabSampleTypeMaster st
    LEFT JOIN dbo.LabUnitMaster u ON st.Unit_ID = u.Unit_ID
    WHERE st.Sample_Type_ID = @Sample_Type_ID;
END
GO

-- 4. Stored Procedure: usp_Api_LabSampleTypeMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleTypeMaster_Create
    @Sample_Name          NVARCHAR(150),
    @Container_Type       NVARCHAR(100),
    @Volume_Value         DECIMAL(10, 2),
    @Unit_ID              INT = NULL,
    @Volume_Unit          NVARCHAR(50) = NULL,
    @Storage_Temperature NVARCHAR(50) = NULL,
    @Rejection_Criteria   NVARCHAR(500) = NULL,
    @Display_Order        INT = 1,
    @CompanyId            INT = 1,
    @BranchId             INT = 1,
    @UserId               INT = NULL,
    @NewId                INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Mandatory Validations
    IF @Sample_Name IS NULL OR LTRIM(RTRIM(@Sample_Name)) = ''
    BEGIN
        RAISERROR('Sample Name is required.', 16, 1);
        RETURN;
    END

    IF @Container_Type IS NULL OR LTRIM(RTRIM(@Container_Type)) = ''
    BEGIN
        RAISERROR('Container Type is required.', 16, 1);
        RETURN;
    END

    IF @Volume_Value IS NULL OR @Volume_Value <= 0
    BEGIN
        RAISERROR('Volume Value must be greater than zero.', 16, 1);
        RETURN;
    END

    -- If Unit_ID is provided, resolve Unit_Symbol or Unit_Name for display Volume_Unit
    IF @Unit_ID IS NOT NULL AND @Unit_ID > 0
    BEGIN
        SELECT @Volume_Unit = ISNULL(NULLIF(LTRIM(RTRIM(Unit_Symbol)), ''), Unit_Name)
        FROM dbo.LabUnitMaster
        WHERE Unit_ID = @Unit_ID;
    END

    IF @Volume_Unit IS NULL OR LTRIM(RTRIM(@Volume_Unit)) = ''
    BEGIN
        SET @Volume_Unit = 'mL';
    END

    SET @Sample_Name = LTRIM(RTRIM(@Sample_Name));
    SET @Container_Type = LTRIM(RTRIM(@Container_Type));
    SET @Volume_Unit = LTRIM(RTRIM(@Volume_Unit));
    SET @Storage_Temperature = LTRIM(RTRIM(@Storage_Temperature));
    SET @Rejection_Criteria = LTRIM(RTRIM(@Rejection_Criteria));

    DECLARE @Volume_Required NVARCHAR(50) = CAST(CAST(@Volume_Value AS FLOAT) AS NVARCHAR(20)) + ' ' + @Volume_Unit;

    -- Duplication check: Sample Name + Container Type + Volume within same Branch
    IF EXISTS (
        SELECT 1 FROM dbo.LabSampleTypeMaster 
        WHERE BranchId = @BranchId 
          AND LOWER(Sample_Name) = LOWER(@Sample_Name)
          AND LOWER(Container_Type) = LOWER(@Container_Type)
          AND Volume_Value = @Volume_Value
          AND LOWER(Volume_Unit) = LOWER(@Volume_Unit)
    )
    BEGIN
        RAISERROR('A Sample Type with the same Name, Container Type, and Volume already exists.', 16, 1);
        RETURN;
    END

    -- Auto Generation Code (e.g. SMP0001)
    DECLARE @NextNum INT;
    DECLARE @GeneratedCode NVARCHAR(50);

    SELECT @NextNum = ISNULL(MAX(Sample_Type_ID), 0) + 1 FROM dbo.LabSampleTypeMaster;
    SET @GeneratedCode = 'SMP' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);

    WHILE EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Code = @GeneratedCode)
    BEGIN
        SET @NextNum = @NextNum + 1;
        SET @GeneratedCode = 'SMP' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
    END

    INSERT INTO dbo.LabSampleTypeMaster
    (
        CompanyId,
        BranchId,
        Sample_Name,
        Sample_Code,
        Container_Type,
        Volume_Value,
        Unit_ID,
        Volume_Unit,
        Volume_Required,
        Storage_Temperature,
        Rejection_Criteria,
        Display_Order,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @BranchId,
        @Sample_Name,
        @GeneratedCode,
        @Container_Type,
        @Volume_Value,
        @Unit_ID,
        @Volume_Unit,
        @Volume_Required,
        @Storage_Temperature,
        @Rejection_Criteria,
        ISNULL(@Display_Order, 1),
        1, -- Starts as Active (Status = 1)
        @UserId,
        GETDATE()
    );

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_Api_LabSampleTypeMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleTypeMaster_Update
    @Sample_Type_ID       INT,
    @Sample_Name          NVARCHAR(150),
    @Container_Type       NVARCHAR(100),
    @Volume_Value         DECIMAL(10, 2),
    @Unit_ID              INT = NULL,
    @Volume_Unit          NVARCHAR(50) = NULL,
    @Storage_Temperature NVARCHAR(50) = NULL,
    @Rejection_Criteria   NVARCHAR(500) = NULL,
    @Display_Order        INT = 1,
    @Status               BIT = 1,
    @UserId               INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @Sample_Type_ID)
    BEGIN
        RAISERROR('Lab Sample Type record not found.', 16, 1);
        RETURN;
    END

    -- Mandatory Validations
    IF @Sample_Name IS NULL OR LTRIM(RTRIM(@Sample_Name)) = ''
    BEGIN
        RAISERROR('Sample Name is required.', 16, 1);
        RETURN;
    END

    IF @Container_Type IS NULL OR LTRIM(RTRIM(@Container_Type)) = ''
    BEGIN
        RAISERROR('Container Type is required.', 16, 1);
        RETURN;
    END

    IF @Volume_Value IS NULL OR @Volume_Value <= 0
    BEGIN
        RAISERROR('Volume Value must be greater than zero.', 16, 1);
        RETURN;
    END

    -- If Unit_ID is provided, resolve Unit_Symbol or Unit_Name for display Volume_Unit
    IF @Unit_ID IS NOT NULL AND @Unit_ID > 0
    BEGIN
        SELECT @Volume_Unit = ISNULL(NULLIF(LTRIM(RTRIM(Unit_Symbol)), ''), Unit_Name)
        FROM dbo.LabUnitMaster
        WHERE Unit_ID = @Unit_ID;
    END

    IF @Volume_Unit IS NULL OR LTRIM(RTRIM(@Volume_Unit)) = ''
    BEGIN
        SET @Volume_Unit = 'mL';
    END

    SET @Sample_Name = LTRIM(RTRIM(@Sample_Name));
    SET @Container_Type = LTRIM(RTRIM(@Container_Type));
    SET @Volume_Unit = LTRIM(RTRIM(@Volume_Unit));
    SET @Storage_Temperature = LTRIM(RTRIM(@Storage_Temperature));
    SET @Rejection_Criteria = LTRIM(RTRIM(@Rejection_Criteria));

    DECLARE @CurrentBranchId INT;
    SELECT @CurrentBranchId = BranchId FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @Sample_Type_ID;

    DECLARE @Volume_Required NVARCHAR(50) = CAST(CAST(@Volume_Value AS FLOAT) AS NVARCHAR(20)) + ' ' + @Volume_Unit;

    -- Duplication check: Sample Name + Container Type + Volume (ignoring self)
    IF EXISTS (
        SELECT 1 FROM dbo.LabSampleTypeMaster 
        WHERE BranchId = @CurrentBranchId 
          AND LOWER(Sample_Name) = LOWER(@Sample_Name)
          AND LOWER(Container_Type) = LOWER(@Container_Type)
          AND Volume_Value = @Volume_Value
          AND LOWER(Volume_Unit) = LOWER(@Volume_Unit)
          AND Sample_Type_ID <> @Sample_Type_ID
    )
    BEGIN
        RAISERROR('A Sample Type with the same Name, Container Type, and Volume already exists.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabSampleTypeMaster
    SET Sample_Name          = @Sample_Name,
        Container_Type       = @Container_Type,
        Volume_Value         = @Volume_Value,
        Unit_ID              = @Unit_ID,
        Volume_Unit          = @Volume_Unit,
        Volume_Required      = @Volume_Required,
        Storage_Temperature = @Storage_Temperature,
        Rejection_Criteria   = @Rejection_Criteria,
        Display_Order        = ISNULL(@Display_Order, 1),
        Status               = @Status,
        ModifiedBy           = @UserId,
        ModifiedDate         = GETDATE()
    WHERE Sample_Type_ID = @Sample_Type_ID;
END
GO

-- 6. Stored Procedure: usp_Api_LabSampleTypeMaster_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleTypeMaster_ToggleStatus
    @Sample_Type_ID INT,
    @Status         BIT,
    @UserId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @Sample_Type_ID)
    BEGIN
        RAISERROR('Lab Sample Type record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabSampleTypeMaster
    SET Status       = @Status,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE Sample_Type_ID = @Sample_Type_ID;
END
GO

-- 7. Stored Procedure: usp_Api_LabSampleTypeMaster_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleTypeMaster_Delete
    @Sample_Type_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @Sample_Type_ID)
    BEGIN
        RAISERROR('Lab Sample Type record not found.', 16, 1);
        RETURN;
    END

    DELETE FROM dbo.LabSampleTypeMaster
    WHERE Sample_Type_ID = @Sample_Type_ID;
END
GO
