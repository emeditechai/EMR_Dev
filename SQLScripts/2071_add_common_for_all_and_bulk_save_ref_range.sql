-- ============================================================
-- Script: 2071_add_common_for_all_and_bulk_save_ref_range.sql
-- Description: Adds Is_Common_For_All column to dbo.LabReferenceRangeMaster and creates Bulk Save SP
-- ============================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Add Is_Common_For_All column if not exists
IF NOT EXISTS (
    SELECT 1 
    FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.LabReferenceRangeMaster') 
      AND name = 'Is_Common_For_All'
)
BEGIN
    ALTER TABLE dbo.LabReferenceRangeMaster
    ADD Is_Common_For_All BIT NOT NULL CONSTRAINT DF_LabRefRange_CommonForAll DEFAULT 0;
END
GO

-- 2. Update usp_Api_LabReferenceRange_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReferenceRange_GetList
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
        r.Is_Common_For_All,
        r.Age_From,
        r.Age_To,
        r.Age_Unit,
        r.Gender,
        r.Pregnancy_Trimester,
        r.Low_Value,
        r.High_Value,
        r.Special_Remarks,
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
            ISNULL(r.Special_Remarks, '') LIKE '%' + @Search + '%' OR
            ISNULL(r.Range_Source, '') LIKE '%' + @Search + '%'
      ))
    ORDER BY t.Test_Name ASC, r.Gender ASC, r.Age_From ASC, r.RefRange_ID DESC;
END
GO

-- 3. Update usp_Api_LabReferenceRange_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReferenceRange_GetById
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
        r.Is_Common_For_All,
        r.Age_From,
        r.Age_To,
        r.Age_Unit,
        r.Gender,
        r.Pregnancy_Trimester,
        r.Low_Value,
        r.High_Value,
        r.Special_Remarks,
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

-- 4. Update usp_Api_LabReferenceRange_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReferenceRange_Create
    @CompanyId            INT,
    @Test_ID              INT,
    @Method_ID            INT = NULL,
    @Unit_ID              INT,
    @Is_Common_For_All    BIT = 0,
    @Age_From             DECIMAL(6,2),
    @Age_To               DECIMAL(6,2),
    @Age_Unit             VARCHAR(20) = 'Years',
    @Gender               VARCHAR(20) = 'All',
    @Pregnancy_Trimester  VARCHAR(50) = 'Not Applicable',
    @Low_Value            DECIMAL(18,4) = NULL,
    @High_Value           DECIMAL(18,4) = NULL,
    @Special_Remarks      NVARCHAR(1000) = NULL,
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
        Is_Common_For_All,
        Age_From,
        Age_To,
        Age_Unit,
        Gender,
        Pregnancy_Trimester,
        Low_Value,
        High_Value,
        Special_Remarks,
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
        ISNULL(@Is_Common_For_All, 0),
        @Age_From,
        @Age_To,
        ISNULL(@Age_Unit, 'Years'),
        ISNULL(@Gender, 'All'),
        ISNULL(@Pregnancy_Trimester, 'Not Applicable'),
        @Low_Value,
        @High_Value,
        @Special_Remarks,
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

-- 5. Update usp_Api_LabReferenceRange_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReferenceRange_Update
    @RefRange_ID          INT,
    @CompanyId            INT,
    @Test_ID              INT,
    @Method_ID            INT = NULL,
    @Unit_ID              INT,
    @Is_Common_For_All    BIT = 0,
    @Age_From             DECIMAL(6,2),
    @Age_To               DECIMAL(6,2),
    @Age_Unit             VARCHAR(20) = 'Years',
    @Gender               VARCHAR(20) = 'All',
    @Pregnancy_Trimester  VARCHAR(50) = 'Not Applicable',
    @Low_Value            DECIMAL(18,4) = NULL,
    @High_Value           DECIMAL(18,4) = NULL,
    @Special_Remarks      NVARCHAR(1000) = NULL,
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
        Is_Common_For_All   = ISNULL(@Is_Common_For_All, 0),
        Age_From            = @Age_From,
        Age_To              = @Age_To,
        Age_Unit            = ISNULL(@Age_Unit, 'Years'),
        Gender              = ISNULL(@Gender, 'All'),
        Pregnancy_Trimester = ISNULL(@Pregnancy_Trimester, 'Not Applicable'),
        Low_Value           = @Low_Value,
        High_Value          = @High_Value,
        Special_Remarks     = @Special_Remarks,
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

-- 6. Stored Procedure: usp_Api_LabReferenceRange_BulkSave
-- Inserts a collection of reference ranges for a test in bulk
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReferenceRange_BulkSave
    @CompanyId            INT,
    @Test_ID              INT,
    @Method_ID            INT = NULL,
    @Unit_ID              INT,
    @Is_Common_For_All    BIT = 0,
    @Range_Source         NVARCHAR(500) = NULL,
    @Effective_From       DATE,
    @Effective_To         DATE = NULL,
    @RangeItemsJson       NVARCHAR(MAX), -- JSON Array of range items
    @CreatedBy            INT = NULL,
    @InsertedCount        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID AND IsDeleted = 0)
        BEGIN
            RAISERROR('Selected Test is invalid or does not exist.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.LabUnitMaster WHERE Unit_ID = @Unit_ID AND IsDeleted = 0)
        BEGIN
            RAISERROR('Selected Unit is invalid or does not exist.', 16, 1);
            ROLLBACK TRANSACTION;
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
            Is_Common_For_All,
            Age_From,
            Age_To,
            Age_Unit,
            Gender,
            Pregnancy_Trimester,
            Low_Value,
            High_Value,
            Special_Remarks,
            Range_Source,
            Effective_From,
            Effective_To,
            Status,
            IsDeleted,
            CreatedBy,
            CreatedDate
        )
        SELECT 
            @CompanyId,
            @Test_ID,
            @Method_ID,
            @Unit_ID,
            @Is_Common_For_All,
            j.Age_From,
            j.Age_To,
            ISNULL(j.Age_Unit, 'Years'),
            ISNULL(j.Gender, 'All'),
            ISNULL(j.Pregnancy_Trimester, 'Not Applicable'),
            j.Low_Value,
            j.High_Value,
            j.Special_Remarks,
            @Range_Source,
            @Effective_From,
            @Effective_To,
            1, -- Active by default
            0,
            @CreatedBy,
            GETDATE()
        FROM OPENJSON(@RangeItemsJson)
        WITH (
            Age_From            DECIMAL(6,2)    '$.Age_From',
            Age_To              DECIMAL(6,2)    '$.Age_To',
            Age_Unit            VARCHAR(20)     '$.Age_Unit',
            Gender              VARCHAR(20)     '$.Gender',
            Pregnancy_Trimester VARCHAR(50)     '$.Pregnancy_Trimester',
            Low_Value           DECIMAL(18,4)   '$.Low_Value',
            High_Value          DECIMAL(18,4)   '$.High_Value',
            Special_Remarks     NVARCHAR(1000)  '$.Special_Remarks'
        ) AS j;

        SET @InsertedCount = @@ROWCOUNT;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO
