-- ============================================================
-- Script: 2076_fix_duplicate_ranges_and_enforce_test_superseding.sql
-- Description: Ensures saving a reference range (Create/Update/BulkSave) supersedes older records for the test
-- ============================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Clean up duplicate/stale records for tests that have multiple sets of active ranges
;WITH RankedRanges AS (
    SELECT 
        RefRange_ID,
        Test_ID,
        CompanyId,
        Is_Common_For_All,
        CreatedDate,
        ROW_NUMBER() OVER (
            PARTITION BY Test_ID, CompanyId, Gender, Age_From, Age_To 
            ORDER BY RefRange_ID DESC
        ) AS RowNum
    FROM dbo.LabReferenceRangeMaster
    WHERE IsDeleted = 0
)
UPDATE dbo.LabReferenceRangeMaster
SET IsDeleted = 1,
    ModifiedDate = GETDATE()
WHERE RefRange_ID IN (
    SELECT RefRange_ID FROM RankedRanges WHERE RowNum > 1
);
GO

-- If a test has non-common ranges (Is_Common_For_All = 0), soft-delete any old common range (Is_Common_For_All = 1) for that test
UPDATE oldCommon
SET oldCommon.IsDeleted = 1,
    oldCommon.ModifiedDate = GETDATE()
FROM dbo.LabReferenceRangeMaster oldCommon
WHERE oldCommon.IsDeleted = 0
  AND oldCommon.Is_Common_For_All = 1
  AND EXISTS (
      SELECT 1 
      FROM dbo.LabReferenceRangeMaster multi
      WHERE multi.Test_ID = oldCommon.Test_ID
        AND multi.CompanyId = oldCommon.CompanyId
        AND multi.Is_Common_For_All = 0
        AND multi.IsDeleted = 0
  );
GO

-- 2. Update usp_Api_LabReferenceRange_Create to supersede prior active records for the test
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

    -- If saving a common range, supersede all existing ranges for this test
    IF @Is_Common_For_All = 1
    BEGIN
        UPDATE dbo.LabReferenceRangeMaster
        SET IsDeleted = 1,
            ModifiedBy = @CreatedBy,
            ModifiedDate = GETDATE()
        WHERE Test_ID = @Test_ID
          AND CompanyId = @CompanyId
          AND IsDeleted = 0;
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

-- 3. Update usp_Api_LabReferenceRange_Update
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

    -- If updating to a common range, deactivate any other records for this test
    IF @Is_Common_For_All = 1
    BEGIN
        UPDATE dbo.LabReferenceRangeMaster
        SET IsDeleted = 1,
            ModifiedBy = @ModifiedBy,
            ModifiedDate = GETDATE()
        WHERE Test_ID = @Test_ID
          AND CompanyId = @CompanyId
          AND RefRange_ID <> @RefRange_ID
          AND IsDeleted = 0;
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

-- 4. Update usp_Api_LabReferenceRange_BulkSave to guarantee soft-deletion of existing records for the test
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

        -- Soft delete all existing reference range records for this test & company
        UPDATE dbo.LabReferenceRangeMaster
        SET IsDeleted = 1,
            ModifiedBy = @CreatedBy,
            ModifiedDate = GETDATE()
        WHERE Test_ID = @Test_ID
          AND CompanyId = @CompanyId
          AND IsDeleted = 0;

        -- Insert new reference range brackets
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
