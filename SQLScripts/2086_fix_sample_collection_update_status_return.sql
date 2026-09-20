-- ============================================================================
-- Script: 2086_fix_sample_collection_update_status_return.sql
-- Description: 
-- 1. Ensure dbo.usp_SampleCollection_UpdateStatus returns 'SELECT 1 AS RowsUpdated'
--    so ExecuteScalarAsync<int> evaluates > 0 properly.
-- 2. Allow re-collection (from Status 3) even if booking date is not today.
-- 3. Clear rejection reason in both SampleCollection and labentrydetails.
-- 4. Update dbo.usp_SampleCollection_UpdateProfileStatus to return RowsUpdated count.
-- 5. Update dbo.usp_SampleCollection_CollectAll to clear rejection reasons.
-- ============================================================================

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateStatus
    @SampleCollectionId  BIGINT,
    @CollectionstatusID  INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId              INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @SampleCollectionId IS NULL OR @SampleCollectionId <= 0
    BEGIN
        RAISERROR('Valid SampleCollectionId is required.', 16, 1);
        RETURN;
    END

    IF @CollectionstatusID IS NULL OR @CollectionstatusID <= 0
    BEGIN
        RAISERROR('Valid CollectionstatusID is required.', 16, 1);
        RETURN;
    END

    DECLARE @LabOrderId       INT;
    DECLARE @ProfileId        INT;
    DECLARE @ProfileName      NVARCHAR(200);
    DECLARE @BranchId         INT;
    DECLARE @GeneratedBarcode NVARCHAR(50);
    DECLARE @BookingDate      DATE;
    DECLARE @CurrentStatus    INT;

    SELECT 
        @LabOrderId    = sc.Laborderid,
        @ProfileId     = sc.ProfileId,
        @ProfileName   = sc.ProfileName,
        @BranchId      = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDate   = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS DATE),
        @CurrentStatus = sc.CollectionstatusID
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.samplecollectionID = @SampleCollectionId;

    IF @LabOrderId IS NULL
    BEGIN
        RAISERROR('Sample record not found.', 16, 1);
        RETURN;
    END

    -- If collecting (Status 2), enforce booking date ONLY IF not a re-collection (Status 3)
    IF @CollectionstatusID = 2 AND ISNULL(@CurrentStatus, 1) <> 3 AND @BookingDate IS NOT NULL AND @BookingDate <> CAST(GETDATE() AS DATE)
    BEGIN
        DECLARE @BDateStr VARCHAR(10) = CONVERT(VARCHAR(10), @BookingDate, 120);
        RAISERROR('Sample collection is only permitted on the booking date (%s).', 16, 1, @BDateStr);
        RETURN;
    END

    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        IF @ProfileId IS NOT NULL OR @ProfileName IS NOT NULL
        BEGIN
            SELECT TOP 1 @GeneratedBarcode = BarcodeNo 
            FROM dbo.SampleCollection 
            WHERE Laborderid = @LabOrderId 
              AND (
                  (@ProfileId IS NOT NULL AND ProfileId = @ProfileId)
                  OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND ProfileName = @ProfileName)
              )
              AND BarcodeNo IS NOT NULL;

            IF @GeneratedBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GeneratedBarcode OUTPUT;
            END

            UPDATE sc
            SET 
                CollectionstatusID   = 2,
                Samplecollectiondate = @SampleCollectionDate,
                Samplecollectiontime = @SampleCollectionTime,
                BarcodeNo            = ISNULL(sc.BarcodeNo, @GeneratedBarcode),
                RejectionReasonId    = NULL,
                RejectionReason      = NULL,
                ModifiedBy           = @UserId,
                ModifiedDate         = GETDATE()
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @SampleCollectionId;
        END
        ELSE
        BEGIN
            SELECT @GeneratedBarcode = BarcodeNo FROM dbo.SampleCollection WHERE samplecollectionID = @SampleCollectionId;

            IF @GeneratedBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GeneratedBarcode OUTPUT;
            END

            UPDATE sc
            SET 
                CollectionstatusID   = 2,
                Samplecollectiondate = @SampleCollectionDate,
                Samplecollectiontime = @SampleCollectionTime,
                BarcodeNo            = ISNULL(sc.BarcodeNo, @GeneratedBarcode),
                RejectionReasonId    = NULL,
                RejectionReason      = NULL,
                ModifiedBy           = @UserId,
                ModifiedDate         = GETDATE()
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @SampleCollectionId;
        END

        -- Clear rejection in labentrydetails as well
        UPDATE led
        SET led.RejectionReasonId = NULL,
            led.RejectionReason = NULL
        FROM dbo.labentrydetails led
        WHERE led.SamplecollectionID = @SampleCollectionId
           OR (led.laborderid = @LabOrderId AND led.investigationid = (SELECT sc.InvestigationID FROM dbo.SampleCollection sc WHERE sc.samplecollectionID = @SampleCollectionId));
    END
    ELSE IF @CollectionstatusID = 1
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = 1,
            Samplecollectiondate = NULL,
            Samplecollectiontime = NULL,
            BarcodeNo            = NULL,
            RejectionReasonId    = NULL,
            RejectionReason      = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @SampleCollectionId;

        UPDATE led
        SET led.RejectionReasonId = NULL,
            led.RejectionReason = NULL
        FROM dbo.labentrydetails led
        WHERE led.SamplecollectionID = @SampleCollectionId
           OR (led.laborderid = @LabOrderId AND led.investigationid = (SELECT sc.InvestigationID FROM dbo.SampleCollection sc WHERE sc.samplecollectionID = @SampleCollectionId));
    END
    ELSE
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = @CollectionstatusID,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @SampleCollectionId;
    END

    -- Return 1 to indicate success for ExecuteScalarAsync
    SELECT 1 AS RowsUpdated;
END;
GO

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

    DECLARE @BranchId    INT = 1;
    DECLARE @BookingDate DATE;

    SELECT TOP 1 
        @BranchId    = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDate = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS DATE)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.Laborderid = @LabOrderId;

    -- If collecting (Status 2), enforce booking date ONLY IF not all items in profile are Re-Collect (Status 3)
    IF @CollectionstatusID = 2 AND @BookingDate IS NOT NULL AND @BookingDate <> CAST(GETDATE() AS DATE)
    BEGIN
        IF EXISTS (
            SELECT 1 FROM dbo.SampleCollection sc
            WHERE sc.Laborderid = @LabOrderId
              AND (
                  (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
                  OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
              )
              AND ISNULL(sc.CollectionstatusID, 1) <> 3
        )
        BEGIN
            DECLARE @BDateStr2 VARCHAR(10) = CONVERT(VARCHAR(10), @BookingDate, 120);
            RAISERROR('Sample collection is only permitted on the booking date (%s).', 16, 1, @BDateStr2);
            RETURN;
        END
    END

    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        DECLARE @ExistingBarcode NVARCHAR(50);
        SELECT TOP 1 @ExistingBarcode = sc.BarcodeNo
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          )
          AND sc.BarcodeNo IS NOT NULL;

        IF @ExistingBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ExistingBarcode OUTPUT;
        END

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            BarcodeNo            = ISNULL(sc.BarcodeNo, @ExistingBarcode),
            RejectionReasonId    = NULL,
            RejectionReason      = NULL,
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

        -- Clear rejection in labentrydetails as well
        UPDATE led
        SET led.RejectionReasonId = NULL,
            led.RejectionReason = NULL
        FROM dbo.labentrydetails led
        INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = led.laborderid AND sc.InvestigationID = led.investigationid
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END
    ELSE IF @CollectionstatusID = 1
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = 1,
            Samplecollectiondate = NULL,
            Samplecollectiontime = NULL,
            BarcodeNo            = NULL,
            RejectionReasonId    = NULL,
            RejectionReason      = NULL,
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

        UPDATE led
        SET led.RejectionReasonId = NULL,
            led.RejectionReason = NULL
        FROM dbo.labentrydetails led
        INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = led.laborderid AND sc.InvestigationID = led.investigationid
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END
    ELSE
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

    -- Return count of updated rows
    SELECT COUNT(*) AS RowsUpdated
    FROM dbo.SampleCollection sc
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND sc.Iscancelled = 0
      AND (
          (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
          OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
      );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_CollectAll
    @LabOrderId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    DECLARE @CurrentDate DATE    = CAST(GETDATE() AS DATE);
    DECLARE @CurrentTime TIME(0) = CAST(GETDATE() AS TIME(0));

    DECLARE @BranchId    INT = 1;
    DECLARE @BookingDate DATE;

    SELECT TOP 1 
        @BranchId    = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDate = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS DATE)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.Laborderid = @LabOrderId;

    -- If booking date check applies, allow if all remaining uncollected items are Re-Collect (Status 3)
    IF @BookingDate IS NOT NULL AND @BookingDate <> @CurrentDate
    BEGIN
        IF EXISTS (
            SELECT 1 FROM dbo.SampleCollection sc
            WHERE sc.Laborderid = @LabOrderId
              AND sc.Is_Active = 1 AND sc.Iscancelled = 0
              AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID = 1)
        )
        BEGIN
            DECLARE @BDateStr3 VARCHAR(10) = CONVERT(VARCHAR(10), @BookingDate, 120);
            RAISERROR('Sample collection is only permitted on the booking date (%s).', 16, 1, @BDateStr3);
            RETURN;
        END
    END

    -- 1. Process Profiles: Each profile shares a single barcode
    DECLARE @CurProfileId INT, @CurProfileName NVARCHAR(200);
    DECLARE prof_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT sc.ProfileId, sc.ProfileName
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL)
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID IN (1, 3));

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
            Samplecollectiondate = ISNULL(sc.Samplecollectiondate, @CurrentDate),
            Samplecollectiontime = ISNULL(sc.Samplecollectiontime, @CurrentTime),
            BarcodeNo            = ISNULL(sc.BarcodeNo, @ProfBarcode),
            RejectionReasonId    = NULL,
            RejectionReason      = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (
              (@CurProfileId IS NOT NULL AND sc.ProfileId = @CurProfileId)
              OR (@CurProfileId IS NULL AND @CurProfileName IS NOT NULL AND sc.ProfileName = @CurProfileName)
          )
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID IN (1, 3));

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
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID IN (1, 3));

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
            Samplecollectiondate = ISNULL(sc.Samplecollectiondate, @CurrentDate),
            Samplecollectiontime = ISNULL(sc.Samplecollectiontime, @CurrentTime),
            BarcodeNo            = ISNULL(sc.BarcodeNo, @ItemBarcode),
            RejectionReasonId    = NULL,
            RejectionReason      = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @CurSampleCollectionId;

        FETCH NEXT FROM item_cur INTO @CurSampleCollectionId;
    END
    CLOSE item_cur;
    DEALLOCATE item_cur;

    -- Clear rejection reasons in labentrydetails for this lab order
    UPDATE led
    SET led.RejectionReasonId = NULL,
        led.RejectionReason = NULL
    FROM dbo.labentrydetails led
    INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = led.laborderid AND sc.InvestigationID = led.investigationid
    WHERE sc.Laborderid = @LabOrderId AND sc.CollectionstatusID = 2;

    -- Return count of collected items for this order
    SELECT COUNT(*) AS RowsUpdated
    FROM dbo.SampleCollection
    WHERE Laborderid = @LabOrderId AND CollectionstatusID = 2;
END;
GO
