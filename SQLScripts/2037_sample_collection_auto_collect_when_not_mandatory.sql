-- ==============================================================================
-- Migration Script: 2037_sample_collection_auto_collect_when_not_mandatory.sql
-- Description: Automatic Sample Collection upon Lab Billing and Payment completion
-- when HospitalSettings.IsSampleCollectionMandatory = 0 (NO).
-- Sample collection date and time will be set to Booking date and time.
-- Barcodes generated as per existing profile & standalone logic.
-- ==============================================================================

SET NOCOUNT ON;
PRINT 'Starting 2037_sample_collection_auto_collect_when_not_mandatory migration...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_AutoCollectIfNoMandatory
    @LabOrderId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        SELECT 0 AS RowsUpdated;
        RETURN;
    END

    DECLARE @BranchId INT;
    DECLARE @BookingDate DATE;
    DECLARE @BookingTime TIME(0);

    SELECT TOP 1 
        @BranchId    = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDate = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS DATE),
        @BookingTime = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS TIME(0))
    FROM dbo.LabOrder lo
    LEFT JOIN dbo.SampleCollection sc ON sc.Laborderid = lo.LabOrderId
    WHERE lo.LabOrderId = @LabOrderId;

    IF @BranchId IS NULL
    BEGIN
        SELECT 0 AS RowsUpdated;
        RETURN;
    END

    -- Check HospitalSettings for this branch
    DECLARE @IsMandatory BIT = 1;
    SELECT TOP 1 @IsMandatory = ISNULL(IsSampleCollectionMandatory, 1)
    FROM dbo.HospitalSettings
    WHERE BranchID = @BranchId AND IsActive = 1;

    -- If Sample Collection IS Mandatory (1 / YES), do nothing!
    IF @IsMandatory = 1
    BEGIN
        SELECT 0 AS RowsUpdated;
        RETURN;
    END

    -- If NOT Mandatory (0 / NO), auto-collect all samples!
    -- Collection date & time MUST be same as Booking date & time
    IF @BookingDate IS NULL
        SET @BookingDate = CAST(GETDATE() AS DATE);
    IF @BookingTime IS NULL
        SET @BookingTime = CAST(GETDATE() AS TIME(0));

    -- 1. Process Profiles: Each profile shares a single barcode
    DECLARE @CurProfileId INT, @CurProfileName NVARCHAR(200);
    DECLARE prof_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT sc.ProfileId, sc.ProfileName
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL)
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID = 1);

    OPEN prof_cur;
    FETCH NEXT FROM prof_cur INTO @CurProfileId, @CurProfileName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @ProfBarcode NVARCHAR(50) = NULL;
        SELECT TOP 1 @ProfBarcode = sc.BarcodeNo
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@CurProfileId IS NOT NULL AND sc.ProfileId = @CurProfileId)
              OR (@CurProfileId IS NULL AND @CurProfileName IS NOT NULL AND sc.ProfileName = @CurProfileName)
          )
          AND sc.BarcodeNo IS NOT NULL;

        IF @ProfBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ProfBarcode OUTPUT;
        END

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @BookingDate,
            Samplecollectiontime = @BookingTime,
            BarcodeNo            = ISNULL(sc.BarcodeNo, @ProfBarcode),
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (
              (@CurProfileId IS NOT NULL AND sc.ProfileId = @CurProfileId)
              OR (@CurProfileId IS NULL AND @CurProfileName IS NOT NULL AND sc.ProfileName = @CurProfileName)
          )
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID = 1);

        FETCH NEXT FROM prof_cur INTO @CurProfileId, @CurProfileName;
    END
    CLOSE prof_cur;
    DEALLOCATE prof_cur;

    -- 2. Process Standalone Investigations: Each gets its own unique sequential barcode
    DECLARE @CurSampleCollectionId BIGINT;
    DECLARE item_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT sc.samplecollectionID
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND sc.ProfileId IS NULL AND sc.ProfileName IS NULL
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID = 1);

    OPEN item_cur;
    FETCH NEXT FROM item_cur INTO @CurSampleCollectionId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @ItemBarcode NVARCHAR(50) = NULL;
        SELECT @ItemBarcode = BarcodeNo FROM dbo.SampleCollection WHERE samplecollectionID = @CurSampleCollectionId;

        IF @ItemBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ItemBarcode OUTPUT;
        END

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @BookingDate,
            Samplecollectiontime = @BookingTime,
            BarcodeNo            = @ItemBarcode,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @CurSampleCollectionId;

        FETCH NEXT FROM item_cur INTO @CurSampleCollectionId;
    END
    CLOSE item_cur;
    DEALLOCATE item_cur;

    -- Return number of collected items
    SELECT COUNT(*) AS RowsUpdated
    FROM dbo.SampleCollection
    WHERE Laborderid = @LabOrderId AND CollectionstatusID = 2;
END
GO

PRINT 'Migration 2037 completed successfully.';
