-- ============================================================
-- Script: 2075_update_bulk_save_sp_soft_delete_existing.sql
-- Description: Update usp_Api_LabReferenceRange_BulkSave to soft-delete existing ranges before inserting new brackets
-- ============================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

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

        -- Soft delete existing reference range records for this test & company
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
