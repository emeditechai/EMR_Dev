-- ==============================================================================
-- Migration Script: 2033_sample_collection_update_profile_status.sql
-- Description: Stored procedure to update collection status for all tests in a Profile at once
-- ==============================================================================

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateProfileStatus
    @LabOrderId          INT,
    @ProfileId           INT = NULL,
    @ProfileName         NVARCHAR(200) = NULL,
    @CollectionstatusID  INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId              INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    IF @CollectionstatusID IS NULL OR @CollectionstatusID <= 0
    BEGIN
        RAISERROR('Valid CollectionstatusID is required.', 16, 1);
        RETURN;
    END

    -- If Collected (2)
    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        -- 1. Check if any test in this profile already has a barcode generated
        DECLARE @ExistingBarcode NVARCHAR(50);
        SELECT TOP 1 @ExistingBarcode = sc.BarcodeNo
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          )
          AND sc.BarcodeNo IS NOT NULL;

        -- 2. Update all tests in this profile
        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            BarcodeNo            = ISNULL(sc.BarcodeNo, 
                                    ISNULL(@ExistingBarcode,
                                        'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) 
                                             + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2) 
                                             + '-P' + RIGHT('000' + CAST(ISNULL(sc.ProfileId, 0) AS NVARCHAR(10)), 3)
                                    )),
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END
    ELSE IF @CollectionstatusID = 1 -- Revert to Pending: clear collection date, time, and BarcodeNo
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = 1,
            Samplecollectiondate = NULL,
            Samplecollectiontime = NULL,
            BarcodeNo            = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END
    ELSE -- Other statuses (Re Collect = 3, Rejected = 4)
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = @CollectionstatusID,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END

    SELECT @@ROWCOUNT AS RowsUpdated;
END
GO
