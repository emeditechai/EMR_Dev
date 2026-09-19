-- ============================================================
-- Script: 2069_lab_reference_range_master.sql
-- Description: Creates dbo.LabReferenceRangeMaster table and CRUD SPs
-- ============================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Create Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabReferenceRangeMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabReferenceRangeMaster (
        RefRange_ID          INT IDENTITY(1,1) NOT NULL,
        CompanyId            INT NOT NULL CONSTRAINT DF_LabRefRange_CompanyId DEFAULT 1,
        Test_ID              INT NOT NULL,
        Method_ID            INT NULL,
        Unit_ID              INT NOT NULL,
        Age_From             DECIMAL(6,2) NOT NULL,
        Age_To               DECIMAL(6,2) NOT NULL,
        Age_Unit             VARCHAR(20) NOT NULL CONSTRAINT DF_LabRefRange_AgeUnit DEFAULT 'Years', -- Years, Months, Days
        Gender               VARCHAR(20) NOT NULL CONSTRAINT DF_LabRefRange_Gender DEFAULT 'All',   -- All, Male, Female, Transgender
        Pregnancy_Trimester  VARCHAR(50) NULL CONSTRAINT DF_LabRefRange_Trimester DEFAULT 'Not Applicable', -- Not Applicable, 1st Trimester, 2nd Trimester, 3rd Trimester
        Low_Value            DECIMAL(18,4) NULL,
        High_Value           DECIMAL(18,4) NULL,
        Special_Remarks      NVARCHAR(1000) NULL,
        Range_Source         NVARCHAR(500) NULL,
        Effective_From       DATE NOT NULL,
        Effective_To         DATE NULL,
        Status               BIT NOT NULL CONSTRAINT DF_LabRefRange_Status DEFAULT 1,
        IsDeleted            BIT NOT NULL CONSTRAINT DF_LabRefRange_IsDeleted DEFAULT 0,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL CONSTRAINT DF_LabRefRange_CreatedDate DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT PK_LabReferenceRangeMaster PRIMARY KEY CLUSTERED (RefRange_ID ASC),
        CONSTRAINT FK_LabRefRange_Test FOREIGN KEY (Test_ID) REFERENCES dbo.LabInvestigationMaster(Test_ID),
        CONSTRAINT FK_LabRefRange_Method FOREIGN KEY (Method_ID) REFERENCES dbo.LabTestMethodMaster(Method_ID),
        CONSTRAINT FK_LabRefRange_Unit FOREIGN KEY (Unit_ID) REFERENCES dbo.LabUnitMaster(Unit_ID)
    );

    CREATE NONCLUSTERED INDEX IX_LabRefRange_Test_ID ON dbo.LabReferenceRangeMaster (Test_ID, CompanyId, IsDeleted, Status);
    CREATE NONCLUSTERED INDEX IX_LabRefRange_CompanyId ON dbo.LabReferenceRangeMaster (CompanyId, IsDeleted, Status);
END
GO

-- 2. Drop existing SPs if exist
IF OBJECT_ID('dbo.usp_Api_LabReferenceRange_GetList', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_Api_LabReferenceRange_GetList;
GO
IF OBJECT_ID('dbo.usp_Api_LabReferenceRange_GetById', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_Api_LabReferenceRange_GetById;
GO
IF OBJECT_ID('dbo.usp_Api_LabReferenceRange_Create', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_Api_LabReferenceRange_Create;
GO
IF OBJECT_ID('dbo.usp_Api_LabReferenceRange_Update', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_Api_LabReferenceRange_Update;
GO
IF OBJECT_ID('dbo.usp_Api_LabReferenceRange_Delete', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_Api_LabReferenceRange_Delete;
GO
IF OBJECT_ID('dbo.usp_Api_LabReferenceRange_ToggleStatus', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_Api_LabReferenceRange_ToggleStatus;
GO
IF OBJECT_ID('dbo.usp_Api_LabReferenceRange_GetNumericTests', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_Api_LabReferenceRange_GetNumericTests;
GO

-- 3. Stored Procedure: usp_Api_LabReferenceRange_GetNumericTests
-- Fetches only active numeric individual tests (excluding parent profiles/packages) with their default method & unit
CREATE PROCEDURE dbo.usp_Api_LabReferenceRange_GetNumericTests
    @CompanyId INT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        t.Test_ID,
        t.Test_Code,
        t.Test_Name,
        t.Reporting_Type,
        t.Method_ID,
        m.Method_Name,
        t.Unit_ID,
        u.Unit_Name,
        u.Unit_Symbol,
        t.Applicable_Gender
    FROM dbo.LabInvestigationMaster t
    LEFT JOIN dbo.LabTestMethodMaster m ON t.Method_ID = m.Method_ID AND m.IsDeleted = 0
    LEFT JOIN dbo.LabUnitMaster u ON t.Unit_ID = u.Unit_ID AND u.IsDeleted = 0
    WHERE t.CompanyId = @CompanyId
      AND t.IsDeleted = 0
      AND t.Status = 1
      AND LOWER(LTRIM(RTRIM(ISNULL(t.Reporting_Type, '')))) = 'numeric'
      AND ISNULL(t.Is_Profile_Test, 0) = 0
      AND NOT EXISTS (
          SELECT 1 
          FROM dbo.LabInvestigationProfileHeader h 
          WHERE h.Test_ID = t.Test_ID 
            AND h.IsDeleted = 0
      )
    ORDER BY t.Test_Name ASC;
END
GO

-- 4. Stored Procedure: usp_Api_LabReferenceRange_GetList
CREATE PROCEDURE dbo.usp_Api_LabReferenceRange_GetList
    @Test_ID     INT = NULL,
    @Gender      VARCHAR(20) = NULL,
    @Status      BIT = NULL,
    @Search      NVARCHAR(100) = NULL,
    @CompanyId   INT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        r.RefRange_ID,
        r.CompanyId,
        r.Test_ID,
        t.Test_Code,
        t.Test_Name,
        r.Method_ID,
        m.Method_Name,
        r.Unit_ID,
        u.Unit_Name,
        u.Unit_Symbol,
        r.Age_From,
        r.Age_To,
        r.Age_Unit,
        r.Gender,
        r.Pregnancy_Trimester,
        r.Low_Value,
        r.High_Value,
        r.Range_Source,
        r.Effective_From,
        r.Effective_To,
        r.Status,
        r.CreatedDate,
        r.ModifiedDate
    FROM dbo.LabReferenceRangeMaster r
    INNER JOIN dbo.LabInvestigationMaster t ON r.Test_ID = t.Test_ID
    LEFT JOIN dbo.LabTestMethodMaster m ON r.Method_ID = m.Method_ID
    LEFT JOIN dbo.LabUnitMaster u ON r.Unit_ID = u.Unit_ID
    WHERE r.CompanyId = @CompanyId
      AND r.IsDeleted = 0
      AND (@Test_ID IS NULL OR r.Test_ID = @Test_ID)
      AND (@Gender IS NULL OR @Gender = '' OR r.Gender = @Gender)
      AND (@Status IS NULL OR r.Status = @Status)
      AND (@Search IS NULL OR @Search = '' OR (
            t.Test_Name LIKE '%' + @Search + '%' OR
            t.Test_Code LIKE '%' + @Search + '%' OR
            ISNULL(m.Method_Name, '') LIKE '%' + @Search + '%' OR
            ISNULL(r.Range_Source, '') LIKE '%' + @Search + '%'
      ))
    ORDER BY t.Test_Name ASC, r.Gender ASC, r.Age_From ASC, r.RefRange_ID DESC;
END
GO

-- 5. Stored Procedure: usp_Api_LabReferenceRange_GetById
CREATE PROCEDURE dbo.usp_Api_LabReferenceRange_GetById
    @RefRange_ID INT,
    @CompanyId   INT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        r.RefRange_ID,
        r.CompanyId,
        r.Test_ID,
        t.Test_Code,
        t.Test_Name,
        r.Method_ID,
        m.Method_Name,
        r.Unit_ID,
        u.Unit_Name,
        u.Unit_Symbol,
        r.Age_From,
        r.Age_To,
        r.Age_Unit,
        r.Gender,
        r.Pregnancy_Trimester,
        r.Low_Value,
        r.High_Value,
        r.Range_Source,
        r.Effective_From,
        r.Effective_To,
        r.Status,
        r.CreatedBy,
        r.CreatedDate,
        r.ModifiedBy,
        r.ModifiedDate
    FROM dbo.LabReferenceRangeMaster r
    INNER JOIN dbo.LabInvestigationMaster t ON r.Test_ID = t.Test_ID
    LEFT JOIN dbo.LabTestMethodMaster m ON r.Method_ID = m.Method_ID
    LEFT JOIN dbo.LabUnitMaster u ON r.Unit_ID = u.Unit_ID
    WHERE r.RefRange_ID = @RefRange_ID
      AND r.CompanyId = @CompanyId
      AND r.IsDeleted = 0;
END
GO

-- 6. Stored Procedure: usp_Api_LabReferenceRange_Create
CREATE PROCEDURE dbo.usp_Api_LabReferenceRange_Create
    @CompanyId            INT,
    @Test_ID              INT,
    @Method_ID            INT = NULL,
    @Unit_ID              INT,
    @Age_From             DECIMAL(6,2),
    @Age_To               DECIMAL(6,2),
    @Age_Unit             VARCHAR(20) = 'Years',
    @Gender               VARCHAR(20) = 'All',
    @Pregnancy_Trimester  VARCHAR(50) = 'Not Applicable',
    @Low_Value            DECIMAL(18,4) = NULL,
    @High_Value           DECIMAL(18,4) = NULL,
    @Range_Source         NVARCHAR(500) = NULL,
    @Effective_From       DATE,
    @Effective_To         DATE = NULL,
    @Status               BIT = 1,
    @CreatedBy            INT = NULL,
    @NewRefRange_ID       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Validation
    IF NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Selected Test is invalid or does not exist.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.LabUnitMaster WHERE Unit_ID = @Unit_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Selected Unit is invalid or does not exist.', 16, 1);
        RETURN;
    END

    IF @Age_From < 0 OR @Age_To < 0 OR @Age_From > @Age_To
    BEGIN
        RAISERROR('Age From must be less than or equal to Age To and non-negative.', 16, 1);
        RETURN;
    END

    IF @Low_Value IS NOT NULL AND @High_Value IS NOT NULL AND @Low_Value > @High_Value
    BEGIN
        RAISERROR('Low Value must be less than or equal to High Value.', 16, 1);
        RETURN;
    END

    IF @Effective_To IS NOT NULL AND @Effective_From > @Effective_To
    BEGIN
        RAISERROR('Effective From must be before or equal to Effective To.', 16, 1);
        RETURN;
    END

    -- If Method_ID is null, try to inherit from test
    IF @Method_ID IS NULL OR @Method_ID = 0
    BEGIN
        SELECT @Method_ID = Method_ID FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID;
    END

    INSERT INTO dbo.LabReferenceRangeMaster (
        CompanyId,
        Test_ID,
        Method_ID,
        Unit_ID,
        Age_From,
        Age_To,
        Age_Unit,
        Gender,
        Pregnancy_Trimester,
        Low_Value,
        High_Value,
        Range_Source,
        Effective_From,
        Effective_To,
        Status,
        IsDeleted,
        CreatedBy,
        CreatedDate
    )
    VALUES (
        @CompanyId,
        @Test_ID,
        @Method_ID,
        @Unit_ID,
        @Age_From,
        @Age_To,
        ISNULL(@Age_Unit, 'Years'),
        ISNULL(@Gender, 'All'),
        ISNULL(@Pregnancy_Trimester, 'Not Applicable'),
        @Low_Value,
        @High_Value,
        @Range_Source,
        @Effective_From,
        @Effective_To,
        ISNULL(@Status, 1),
        0,
        @CreatedBy,
        GETDATE()
    );

    SET @NewRefRange_ID = SCOPE_IDENTITY();
END
GO

-- 7. Stored Procedure: usp_Api_LabReferenceRange_Update
CREATE PROCEDURE dbo.usp_Api_LabReferenceRange_Update
    @RefRange_ID          INT,
    @CompanyId            INT,
    @Test_ID              INT,
    @Method_ID            INT = NULL,
    @Unit_ID              INT,
    @Age_From             DECIMAL(6,2),
    @Age_To               DECIMAL(6,2),
    @Age_Unit             VARCHAR(20) = 'Years',
    @Gender               VARCHAR(20) = 'All',
    @Pregnancy_Trimester  VARCHAR(50) = 'Not Applicable',
    @Low_Value            DECIMAL(18,4) = NULL,
    @High_Value           DECIMAL(18,4) = NULL,
    @Range_Source         NVARCHAR(500) = NULL,
    @Effective_From       DATE,
    @Effective_To         DATE = NULL,
    @Status               BIT,
    @ModifiedBy           INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabReferenceRangeMaster WHERE RefRange_ID = @RefRange_ID AND CompanyId = @CompanyId AND IsDeleted = 0)
    BEGIN
        RAISERROR('Reference range record not found.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Selected Test is invalid or does not exist.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.LabUnitMaster WHERE Unit_ID = @Unit_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Selected Unit is invalid or does not exist.', 16, 1);
        RETURN;
    END

    IF @Age_From < 0 OR @Age_To < 0 OR @Age_From > @Age_To
    BEGIN
        RAISERROR('Age From must be less than or equal to Age To and non-negative.', 16, 1);
        RETURN;
    END

    IF @Low_Value IS NOT NULL AND @High_Value IS NOT NULL AND @Low_Value > @High_Value
    BEGIN
        RAISERROR('Low Value must be less than or equal to High Value.', 16, 1);
        RETURN;
    END

    IF @Effective_To IS NOT NULL AND @Effective_From > @Effective_To
    BEGIN
        RAISERROR('Effective From must be before or equal to Effective To.', 16, 1);
        RETURN;
    END

    -- If Method_ID is null, try to inherit from test
    IF @Method_ID IS NULL OR @Method_ID = 0
    BEGIN
        SELECT @Method_ID = Method_ID FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID;
    END

    UPDATE dbo.LabReferenceRangeMaster
    SET 
        Test_ID             = @Test_ID,
        Method_ID           = @Method_ID,
        Unit_ID             = @Unit_ID,
        Age_From            = @Age_From,
        Age_To              = @Age_To,
        Age_Unit            = ISNULL(@Age_Unit, 'Years'),
        Gender              = ISNULL(@Gender, 'All'),
        Pregnancy_Trimester = ISNULL(@Pregnancy_Trimester, 'Not Applicable'),
        Low_Value           = @Low_Value,
        High_Value          = @High_Value,
        Range_Source        = @Range_Source,
        Effective_From      = @Effective_From,
        Effective_To        = @Effective_To,
        Status              = @Status,
        ModifiedBy          = @ModifiedBy,
        ModifiedDate        = GETDATE()
    WHERE RefRange_ID = @RefRange_ID
      AND CompanyId = @CompanyId
      AND IsDeleted = 0;
END
GO

-- 8. Stored Procedure: usp_Api_LabReferenceRange_Delete
CREATE PROCEDURE dbo.usp_Api_LabReferenceRange_Delete
    @RefRange_ID INT,
    @CompanyId   INT,
    @ModifiedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabReferenceRangeMaster WHERE RefRange_ID = @RefRange_ID AND CompanyId = @CompanyId AND IsDeleted = 0)
    BEGIN
        RAISERROR('Reference range record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabReferenceRangeMaster
    SET 
        IsDeleted    = 1,
        ModifiedBy   = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE RefRange_ID = @RefRange_ID
      AND CompanyId = @CompanyId;
END
GO

-- 9. Stored Procedure: usp_Api_LabReferenceRange_ToggleStatus
CREATE PROCEDURE dbo.usp_Api_LabReferenceRange_ToggleStatus
    @RefRange_ID INT,
    @CompanyId   INT,
    @ModifiedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabReferenceRangeMaster WHERE RefRange_ID = @RefRange_ID AND CompanyId = @CompanyId AND IsDeleted = 0)
    BEGIN
        RAISERROR('Reference range record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabReferenceRangeMaster
    SET 
        Status       = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedBy   = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE RefRange_ID = @RefRange_ID
      AND CompanyId = @CompanyId;

    SELECT Status FROM dbo.LabReferenceRangeMaster WHERE RefRange_ID = @RefRange_ID;
END
GO
