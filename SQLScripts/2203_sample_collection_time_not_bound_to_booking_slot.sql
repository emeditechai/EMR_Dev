-- ============================================================================
-- Migration: 2203_sample_collection_time_not_bound_to_booking_slot.sql
-- Description: Sample Collection - the collection date & time is no longer held back by the BOOKING time.
--   A home collection booked for a later slot (e.g. booked yesterday for 7 PM today) can be collected whenever the
--   phlebotomist reaches the patient. The rule (2098, 2133) "collection cannot be earlier than the booking date and
--   time" becomes:
--       earliest = when the bill was made (LabOrder.CreatedDate), or its booking time when that is earlier
--                  (a back-dated bill, entered after the sample was taken)
--       latest   = now (5 minutes of clock difference allowed) - a collection time cannot be in the future
--   Applies to usp_SampleCollection_UpdateStatus, _UpdateProfileStatus and _CollectAll (live definitions, only the
--   time rule changed). usp_SampleCollection_GetDetail also returns EarliestCollectionOn so the screen shows and
--   checks the same limit. Barcodes, re-collection, rejection and return values are unchanged.
--   Run after 2202.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateStatus
    @SampleCollectionId   BIGINT,
    @CollectionstatusID   INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId               INT = NULL
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

    DECLARE @LabOrderId          INT;
    DECLARE @ProfileId           INT;
    DECLARE @ProfileName         NVARCHAR(200);
    DECLARE @BranchId            INT;
    DECLARE @GeneratedBarcode    NVARCHAR(50);
    DECLARE @BookingDateTime     DATETIME;
    DECLARE @CurrentStatus       INT;
    DECLARE @IsBarcodeReq        BIT = 1;

    SELECT 
        @LabOrderId       = sc.Laborderid,
        @ProfileId        = sc.ProfileId,
        @ProfileName      = sc.ProfileName,
        @BranchId         = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        -- earliest allowed collection: when the bill was made, or its booking time when that is earlier (back-dated bill).
        -- A booking slot in the future (home collection) does not hold the collection back.
        @BookingDateTime  = CASE WHEN lo.CreatedDate < ISNULL(lo.BookingDate, lo.OrderDate) THEN lo.CreatedDate ELSE ISNULL(lo.BookingDate, lo.OrderDate) END,
        @CurrentStatus    = sc.CollectionstatusID,
        @IsBarcodeReq     = ISNULL(cat.Is_Barcode_Required, 1)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
    WHERE sc.samplecollectionID = @SampleCollectionId;

    IF @LabOrderId IS NULL
    BEGIN
        RAISERROR('Sample record not found.', 16, 1);
        RETURN;
    END

    IF @CollectionstatusID = 2 AND @BookingDateTime IS NOT NULL
    BEGIN
        DECLARE @CollectAt DATETIME =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST('00:00:00' AS TIME(0)), ISNULL(@SampleCollectionTime, CAST(GETDATE() AS TIME(0)))),
                    CAST(ISNULL(@SampleCollectionDate, CAST(GETDATE() AS DATE)) AS DATETIME));

        IF DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @CollectAt), 0) < DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @BookingDateTime), 0)
        BEGIN
            DECLARE @CollectStr VARCHAR(16) = CONVERT(VARCHAR(16), @CollectAt, 120);
            DECLARE @BookStr    VARCHAR(16) = CONVERT(VARCHAR(16), @BookingDateTime, 120);
            RAISERROR('Sample collection date and time (%s) cannot be earlier than the bill date and time (%s).', 16, 1, @CollectStr, @BookStr);
            RETURN;
        END
        -- ...and not in the future (5 minutes of clock difference allowed)
        IF @CollectAt > DATEADD(MINUTE, 5, GETDATE())
        BEGIN
            DECLARE @FutureStr VARCHAR(16) = CONVERT(VARCHAR(16), @CollectAt, 120);
            RAISERROR('Sample collection date and time (%s) cannot be in the future.', 16, 1, @FutureStr);
            RETURN;
        END
    END

    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        IF @IsBarcodeReq = 1
        BEGIN
            IF @ProfileId IS NOT NULL OR @ProfileName IS NOT NULL
            BEGIN
                SELECT TOP 1 @GeneratedBarcode = sc.BarcodeNo 
                FROM dbo.SampleCollection sc
                LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
                LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
                WHERE sc.Laborderid = @LabOrderId 
                  AND (
                      (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
                      OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
                  )
                  AND sc.BarcodeNo IS NOT NULL
                  AND ISNULL(cat.Is_Barcode_Required, 1) = 1;

                IF @GeneratedBarcode IS NULL
                BEGIN
                    EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GeneratedBarcode OUTPUT;
                END
            END
            ELSE
            BEGIN
                SELECT @GeneratedBarcode = BarcodeNo FROM dbo.SampleCollection WHERE samplecollectionID = @SampleCollectionId;

                IF @GeneratedBarcode IS NULL
                BEGIN
                    EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GeneratedBarcode OUTPUT;
                END
            END
        END
        ELSE
        BEGIN
            SET @GeneratedBarcode = NULL;
        END

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            BarcodeNo            = CASE WHEN @IsBarcodeReq = 1 THEN ISNULL(sc.BarcodeNo, @GeneratedBarcode) ELSE NULL END,
            RejectionReasonId    = NULL,
            RejectionReason      = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @SampleCollectionId;

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

    SELECT 1 AS RowsUpdated;
END
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
    DECLARE @BookingDateTime DATETIME;

    SELECT TOP 1 
        @BranchId    = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDateTime = CASE WHEN lo.CreatedDate < ISNULL(lo.BookingDate, lo.OrderDate) THEN lo.CreatedDate ELSE ISNULL(lo.BookingDate, lo.OrderDate) END   -- earliest allowed collection (see UpdateStatus)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.Laborderid = @LabOrderId;

    -- Collection date & time: not earlier than the bill (when it was made, or its booking time when earlier), not in the future.
    IF @CollectionstatusID = 2 AND @BookingDateTime IS NOT NULL
    BEGIN
        DECLARE @CollectAt DATETIME =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST('00:00:00' AS TIME(0)), ISNULL(@SampleCollectionTime, CAST(GETDATE() AS TIME(0)))),
                    CAST(ISNULL(@SampleCollectionDate, CAST(GETDATE() AS DATE)) AS DATETIME));

        IF DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @CollectAt), 0) < DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @BookingDateTime), 0)
        BEGIN
            DECLARE @CollectStr VARCHAR(16) = CONVERT(VARCHAR(16), @CollectAt, 120);
            DECLARE @BookStr    VARCHAR(16) = CONVERT(VARCHAR(16), @BookingDateTime, 120);
            RAISERROR('Sample collection date and time (%s) cannot be earlier than the bill date and time (%s).', 16, 1, @CollectStr, @BookStr);
            RETURN;
        END
        -- ...and not in the future (5 minutes of clock difference allowed)
        IF @CollectAt > DATEADD(MINUTE, 5, GETDATE())
        BEGIN
            DECLARE @FutureStr VARCHAR(16) = CONVERT(VARCHAR(16), @CollectAt, 120);
            RAISERROR('Sample collection date and time (%s) cannot be in the future.', 16, 1, @FutureStr);
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
    DECLARE @BookingDateTime DATETIME;

    SELECT TOP 1 
        @BranchId    = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDateTime = CASE WHEN lo.CreatedDate < ISNULL(lo.BookingDate, lo.OrderDate) THEN lo.CreatedDate ELSE ISNULL(lo.BookingDate, lo.OrderDate) END   -- earliest allowed collection (see UpdateStatus)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.Laborderid = @LabOrderId;

    -- Collect All stamps "now": refused only when now is earlier than the bill itself (never for a future booking slot).
    IF @BookingDateTime IS NOT NULL
       AND DATEADD(MINUTE, DATEDIFF(MINUTE, 0, GETDATE()), 0) < DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @BookingDateTime), 0)
    BEGIN
        IF EXISTS (
            SELECT 1 FROM dbo.SampleCollection sc
            WHERE sc.Laborderid = @LabOrderId
              AND sc.Is_Active = 1 AND sc.Iscancelled = 0
              AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID IN (1, 3))
        )
        BEGIN
            DECLARE @NowStr3  VARCHAR(16) = CONVERT(VARCHAR(16), GETDATE(), 120);
            DECLARE @BookStr3 VARCHAR(16) = CONVERT(VARCHAR(16), @BookingDateTime, 120);
            RAISERROR('Sample collection date and time (%s) cannot be earlier than the bill date and time (%s).', 16, 1, @NowStr3, @BookStr3);
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

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
        RETURN;

    -- Heal missing ProfileId / PackageId for legacy rows
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND (ProfileId IS NULL OR PackageId IS NULL))
    BEGIN
        UPDATE sc
        SET 
            sc.ProfileId   = h.Profile_ID,
            sc.ProfileName = h.Profile_Name
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'I'
        INNER JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = loi.InvestigationId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = loi.InvestigationId))
        INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.Test_ID = sc.InvestigationID
        WHERE sc.Laborderid = @LabOrderId AND sc.ProfileId IS NULL;

        UPDATE sc
        SET 
            sc.PackageId   = h.Profile_ID,
            sc.PackageName = h.Profile_Name
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'P'
        INNER JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = loi.InvestigationId
        WHERE sc.Laborderid = @LabOrderId AND sc.PackageId IS NULL;
    END

    -- Backfill BarcodeNo if missing (ONLY for tests requiring barcodes!)
    IF EXISTS (
        SELECT 1 FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
        WHERE sc.Laborderid = @LabOrderId 
          AND sc.CollectionstatusID = 2 
          AND sc.BarcodeNo IS NULL
          AND ISNULL(cat.Is_Barcode_Required, 1) = 1
    )
    BEGIN
        DECLARE @BranchId INT = 1;
        SELECT TOP 1 @BranchId = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1))
        FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
        WHERE sc.Laborderid = @LabOrderId;

        DECLARE @MissingProfId INT, @MissingProfName NVARCHAR(200);
        DECLARE missing_prof CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT sc.ProfileId, sc.ProfileName
            FROM dbo.SampleCollection sc
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId 
              AND sc.CollectionstatusID = 2 
              AND sc.BarcodeNo IS NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1
              AND (sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL);

        OPEN missing_prof;
        FETCH NEXT FROM missing_prof INTO @MissingProfId, @MissingProfName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @MBarcode NVARCHAR(50) = NULL;
            SELECT TOP 1 @MBarcode = sc.BarcodeNo
            FROM dbo.SampleCollection sc
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId
              AND (
                  (@MissingProfId IS NOT NULL AND sc.ProfileId = @MissingProfId)
                  OR (@MissingProfId IS NULL AND @MissingProfName IS NOT NULL AND sc.ProfileName = @MissingProfName)
              )
              AND sc.BarcodeNo IS NOT NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1;

            IF @MBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @MBarcode OUTPUT;
            END

            UPDATE sc
            SET sc.BarcodeNo = @MBarcode
            FROM dbo.SampleCollection sc
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId 
              AND sc.CollectionstatusID = 2 
              AND sc.BarcodeNo IS NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1
              AND (
                  (@MissingProfId IS NOT NULL AND sc.ProfileId = @MissingProfId)
                  OR (@MissingProfId IS NULL AND @MissingProfName IS NOT NULL AND sc.ProfileName = @MissingProfName)
              );

            FETCH NEXT FROM missing_prof INTO @MissingProfId, @MissingProfName;
        END
        CLOSE missing_prof;
        DEALLOCATE missing_prof;

        DECLARE @MissingItemId BIGINT;
        DECLARE missing_item CURSOR LOCAL FAST_FORWARD FOR
            SELECT sc.samplecollectionID
            FROM dbo.SampleCollection sc
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId 
              AND sc.CollectionstatusID = 2 
              AND sc.BarcodeNo IS NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1;

        OPEN missing_item;
        FETCH NEXT FROM missing_item INTO @MissingItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @MItemBarcode NVARCHAR(50) = NULL;
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @MItemBarcode OUTPUT;

            UPDATE sc
            SET sc.BarcodeNo = @MItemBarcode
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @MissingItemId;

            FETCH NEXT FROM missing_item INTO @MissingItemId;
        END
        CLOSE missing_item;
        DEALLOCATE missing_item;
    END

    -- RS1: Order-level header
    SELECT 
        lo.LabOrderId,
        lo.BranchId,
        bm.BranchName,
        lo.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        CASE 
            WHEN p.DateOfBirth IS NOT NULL THEN 
                DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
                CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
            ELSE NULL 
        END AS Age,
        p.Gender,
        p.PhoneNumber,
        p.EmailId,
        p.Address,
        lo.OrderDate,
        lo.BookingDate AS BookingDateTime,
        CASE WHEN lo.CreatedDate < ISNULL(lo.BookingDate, lo.OrderDate) THEN lo.CreatedDate ELSE ISNULL(lo.BookingDate, lo.OrderDate) END AS EarliestCollectionOn,   -- 2203: the earliest collection time allowed
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        CASE 
            WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B'
            ELSE ISNULL(ph.PaymentStatus, 'U')
        END AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount,
        ISNULL(lo.IsB2B, 0) AS IsB2B,
        lo.AgentType,
        lo.B2BAgentID AS B2BAgentId,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Franchise_Name
            WHEN lo.AgentType = 'C' THEN corp.Corporate_Name
            ELSE NULL
        END AS PartnerName
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS2: Individual test/sample items
    -- EXCLUDES tests where Is_Sample_Collection_Required = 0 (e.g. Radiology)!
    SELECT 
        sc.samplecollectionID,
        sc.Laborderid,
        sc.InvestigationID,
        lim.Test_Code AS TestCode,
        lim.Test_Name AS TestName,
        sc.DepartmentID,
        ISNULL(ldm.DeptName, '') AS DepartmentName,
        lim.Sample_Type_ID AS SampleTypeId,
        ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
        ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS ContainerType,
        ISNULL(lim.Is_Fasting_Required, 0) AS IsFastingRequired,
        CAST(ISNULL(sc.IsoutSource, ISNULL(lim.Is_Outsourced, 0)) AS BIT) AS IsOutsourced,
        CAST(ISNULL(sc.IsoutSource, ISNULL(lim.Is_Outsourced, 0)) AS BIT) AS IsoutSource,
        sc.BarcodeNo,
        ISNULL(sc.RequiresManualBarcode, 0) AS RequiresManualBarcode,
        ISNULL(sc.CollectionstatusID, 1) AS CollectionstatusID,
        ISNULL(cs.StatusName, 'Pending') AS StatusName,
        sc.Samplecollectiondate,
        sc.Samplecollectiontime,
        sc.Orderdate,
        sc.Bookingdatetime,
        sc.TokenNo,
        sc.ProfileId,
        sc.ProfileName,
        sc.PackageId,
        sc.PackageName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName, '—') AS ProfilePackageName,
        u.FullName AS CollectedByName,
        sc.RejectionReasonId,
        sc.RejectionReason
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.SampleCollectionStatus cs ON cs.StatusID = sc.CollectionstatusID
    LEFT JOIN dbo.Users u ON u.Id = sc.ModifiedBy
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND sc.Iscancelled = 0
      AND ISNULL(cat.Is_Sample_Collection_Required, 1) = 1
    ORDER BY 
        COALESCE(sc.ProfileName, sc.PackageName, 'ZZZ'),
        ISNULL(stm.Sample_Name, ''),
        lim.Test_Name;
END
GO

PRINT 'Script 2203 applied: sample collection time no longer bound to the booking slot.';
GO
