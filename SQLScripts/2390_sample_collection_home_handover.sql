-- ============================================================================================================
-- Migration: 2390_sample_collection_home_handover.sql
-- LAB > Sample Collection, Home Collection orders:
--   a) never auto-collected: usp_SampleCollection_AutoCollectIfNoMandatory skips them whatever Hospital Settings >
--      "Is Sample Collection Mandatory" says (Lab orders unchanged);
--   b) Collection Type filter: usp_SampleCollection_GetHeaderList @CollectionType ('Lab' / 'Home Collection' / All);
--   c) collected at the lab desk only once the latest home visit (LabHomeVisit) is HANDED_OVER (or RECEIVED after it):
--      fn_LabHomeCollectionHold gives the reason when not; usp_SampleCollection_UpdateStatus / UpdateProfileStatus /
--      CollectAll refuse status Collected with it when called with @EnforceHomeHandover = 1 (the Sample Collection
--      screen). The phlebotomist app's own calls (usp_Phlebo_Visit_Samples) leave it 0 and are unchanged.
--   List / detail also return HomeVisitStatus, CanCollect / CollectionHoldReason. Live definitions + the 2390 parts.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- why a Home Collection order cannot be collected at the lab desk yet (NULL = it can; Lab orders always can)
CREATE OR ALTER FUNCTION dbo.fn_LabHomeCollectionHold (@LabOrderId INT)
RETURNS NVARCHAR(400)
AS
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId AND ISNULL(CollectionType, '') = 'Home Collection')
        RETURN NULL;
    DECLARE @s VARCHAR(30) = (SELECT TOP 1 v.Status FROM dbo.LabHomeVisit v WHERE v.LabOrderId = @LabOrderId ORDER BY v.VisitId DESC);
    IF @s IN ('HANDED_OVER', 'RECEIVED') RETURN NULL;
    RETURN N'Home Collection: the sample can be collected only after the phlebotomist has handed it over to the lab'
         + CASE WHEN @s IS NULL THEN N' (no home visit has been dispatched yet).'
                ELSE N' (home visit status now: ' + REPLACE(@s, '_', ' ') + N').' END;
END
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

    -- 2390: a Home Collection order is never auto-collected - its samples are always collected (after the handover),
    -- whatever "Is Sample Collection Mandatory" says
    IF EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId AND ISNULL(CollectionType, '') = 'Home Collection')
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

    -- One barcode per tube (SQLScripts/2312): every pending row keeps its barcode, else takes the barcode of this bill's
    -- test with the same Sample Name + Container Type (old profile / own rule when the test has no sample type).
    DECLARE @CurSampleCollectionId BIGINT, @RowBarcode NVARCHAR(50);
    DECLARE row_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT sc.samplecollectionID
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID = 1)
        ORDER BY CASE WHEN sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL THEN 0 ELSE 1 END, sc.samplecollectionID;

    OPEN row_cur;
    FETCH NEXT FROM row_cur INTO @CurSampleCollectionId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @RowBarcode = NULL;
        EXEC dbo.usp_Lab_AssignTubeBarcode @SampleCollectionId = @CurSampleCollectionId, @BranchId = @BranchId, @Barcode = @RowBarcode OUTPUT;

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @BookingDate,
            Samplecollectiontime = @BookingTime,
            BarcodeNo            = ISNULL(sc.BarcodeNo, @RowBarcode),
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @CurSampleCollectionId;

        FETCH NEXT FROM row_cur INTO @CurSampleCollectionId;
    END
    CLOSE row_cur;
    DEALLOCATE row_cur;

    -- Return number of collected items
    SELECT COUNT(*) AS RowsUpdated
    FROM dbo.SampleCollection
    WHERE Laborderid = @LabOrderId AND CollectionstatusID = 2;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateStatus
    @SampleCollectionId   BIGINT,
    @CollectionstatusID   INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId               INT = NULL,
    @EnforceHomeHandover  BIT = 0     -- 2390: 1 from the Sample Collection screen; the phlebotomist app leaves it 0
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

    -- 2390: Home Collection - collected at the lab desk only after the phlebotomist has handed the samples over
    IF ISNULL(@EnforceHomeHandover, 0) = 1 AND @CollectionstatusID = 2
    BEGIN
        DECLARE @HoldMsg NVARCHAR(400) = dbo.fn_LabHomeCollectionHold(@LabOrderId);
        IF @HoldMsg IS NOT NULL BEGIN RAISERROR(@HoldMsg, 16, 1); RETURN; END
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
            -- One barcode per tube (SQLScripts/2312): the row's own barcode, else the barcode of this bill's test with the
            -- same Sample Name + Container Type (old profile rule when the test has no sample type), else a new one
            EXEC dbo.usp_Lab_AssignTubeBarcode @SampleCollectionId = @SampleCollectionId, @BranchId = @BranchId, @Barcode = @GeneratedBarcode OUTPUT;
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
    @UserId              INT = NULL,
    @EnforceHomeHandover BIT = 0      -- 2390: 1 from the Sample Collection screen
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

    -- 2390: Home Collection - collected at the lab desk only after the phlebotomist has handed the samples over
    IF ISNULL(@EnforceHomeHandover, 0) = 1 AND @CollectionstatusID = 2
    BEGIN
        DECLARE @HoldMsg NVARCHAR(400) = dbo.fn_LabHomeCollectionHold(@LabOrderId);
        IF @HoldMsg IS NOT NULL BEGIN RAISERROR(@HoldMsg, 16, 1); RETURN; END
    END

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

        -- One barcode per tube (SQLScripts/2312): each test of the profile keeps its barcode, else takes the barcode of
        -- this bill's test with the same Sample Name + Container Type (old profile rule when it has no sample type)
        DECLARE @PSampleId BIGINT, @PBarcode NVARCHAR(50);
        DECLARE prow_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT sc.samplecollectionID
            FROM dbo.SampleCollection sc
            WHERE sc.Laborderid = @LabOrderId
              AND sc.Is_Active = 1
              AND sc.Iscancelled = 0
              AND (
                  (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
                  OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
              )
            ORDER BY sc.samplecollectionID;
        OPEN prow_cur;
        FETCH NEXT FROM prow_cur INTO @PSampleId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @PBarcode = NULL;
            EXEC dbo.usp_Lab_AssignTubeBarcode @SampleCollectionId = @PSampleId, @BranchId = @BranchId, @Barcode = @PBarcode OUTPUT;
            UPDATE sc
            SET 
                CollectionstatusID   = 2,
                Samplecollectiondate = @SampleCollectionDate,
                Samplecollectiontime = @SampleCollectionTime,
                BarcodeNo            = ISNULL(sc.BarcodeNo, @PBarcode),
                RejectionReasonId    = NULL,
                RejectionReason      = NULL,
                ModifiedBy           = @UserId,
                ModifiedDate         = GETDATE()
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @PSampleId;
            FETCH NEXT FROM prow_cur INTO @PSampleId;
        END
        CLOSE prow_cur;
        DEALLOCATE prow_cur;

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
    @UserId     INT = NULL,
    @EnforceHomeHandover BIT = 0      -- 2390: 1 from the Sample Collection screen
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    -- 2390: Home Collection - collected at the lab desk only after the phlebotomist has handed the samples over
    IF ISNULL(@EnforceHomeHandover, 0) = 1 AND 1 = 1
    BEGIN
        DECLARE @HoldMsg NVARCHAR(400) = dbo.fn_LabHomeCollectionHold(@LabOrderId);
        IF @HoldMsg IS NOT NULL BEGIN RAISERROR(@HoldMsg, 16, 1); RETURN; END
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

    -- One barcode per tube (SQLScripts/2312): every pending row keeps its barcode, else takes the barcode of this bill's
    -- test with the same Sample Name + Container Type (old profile / own rule when the test has no sample type).
    DECLARE @CurSampleCollectionId BIGINT, @RowBarcode NVARCHAR(50);
    DECLARE row_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT sc.samplecollectionID
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID IN (1, 3))
        ORDER BY CASE WHEN sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL THEN 0 ELSE 1 END, sc.samplecollectionID;

    OPEN row_cur;
    FETCH NEXT FROM row_cur INTO @CurSampleCollectionId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @RowBarcode = NULL;
        EXEC dbo.usp_Lab_AssignTubeBarcode @SampleCollectionId = @CurSampleCollectionId, @BranchId = @BranchId, @Barcode = @RowBarcode OUTPUT;

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = ISNULL(sc.Samplecollectiondate, @CurrentDate),
            Samplecollectiontime = ISNULL(sc.Samplecollectiontime, @CurrentTime),
            BarcodeNo            = ISNULL(sc.BarcodeNo, @RowBarcode),
            RejectionReasonId    = NULL,
            RejectionReason      = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @CurSampleCollectionId;

        FETCH NEXT FROM row_cur INTO @CurSampleCollectionId;
    END
    CLOSE row_cur;
    DEALLOCATE row_cur;

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

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetHeaderList
    @BranchId        INT,
    @FromDate        DATETIME      = NULL,
    @ToDate          DATETIME      = NULL,
    @DateFilterType  VARCHAR(20)   = 'BookingDate',
    @StatusFilter    VARCHAR(50)   = 'All',
    @Search          NVARCHAR(100) = NULL,
    -- 2266: a franchise login (its user id): only the orders it created or that are for its franchise; NULL = all
    @CreatedBy       INT           = NULL,
    -- 2390: 'Lab' / 'Home Collection'; NULL or 'All' = every order
    @CollectionType  VARCHAR(30)   = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL
        SET @FromDate = CAST(CAST(GETDATE() AS DATE) AS DATETIME);
    
    IF @ToDate IS NULL
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));
    ELSE IF CAST(@ToDate AS TIME) = '00:00:00'
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(@ToDate AS DATE) AS DATETIME));

    -- Only count tests where Is_Sample_Collection_Required = 1 (YES)
    WITH OrderAggregates AS (
        SELECT 
            sc.Laborderid,
            COUNT(1) AS TotalTests,
            SUM(CASE WHEN ISNULL(sc.CollectionstatusID, 1) = 2 THEN 1 ELSE 0 END) AS CollectedCount,
            SUM(CASE WHEN ISNULL(sc.CollectionstatusID, 1) = 1 THEN 1 ELSE 0 END) AS PendingCount,
            SUM(CASE WHEN ISNULL(sc.CollectionstatusID, 1) = 3 THEN 1 ELSE 0 END) AS ReCollectCount,
            SUM(CASE WHEN ISNULL(sc.CollectionstatusID, 1) = 4 THEN 1 ELSE 0 END) AS RejectedCount,
            MIN(sc.Bookingdatetime) AS MinBookingDateTime,
            MIN(sc.Orderdate) AS MinOrderDate
        FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
        WHERE sc.BranchID = @BranchId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND ISNULL(cat.Is_Sample_Collection_Required, 1) = 1
        GROUP BY sc.Laborderid
    ),
    DistinctContainers AS (
        SELECT DISTINCT
            sc.Laborderid,
            ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS Container_Type
        FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
        LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
        WHERE sc.BranchID = @BranchId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND ISNULL(cat.Is_Sample_Collection_Required, 1) = 1
    ),
    AggregatedContainers AS (
        SELECT 
            dc.Laborderid,
            STRING_AGG(dc.Container_Type, ', ') AS ContainerTypes
        FROM DistinctContainers dc
        GROUP BY dc.Laborderid
    )
    SELECT 
        lo.LabOrderId,
        lo.BranchId,
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
        lo.OrderDate,
        ISNULL(lo.BookingDate, agg.MinBookingDateTime) AS BookingDateTime,
        lo.BillNo,
        lo.TokenNo,
        -- urgent when the order or any of its tests is marked urgent
        CAST(CASE WHEN ISNULL(lo.IsUrgent, 0) = 1
                    OR EXISTS (SELECT 1 FROM dbo.LabOrderItem uli WHERE uli.LabOrderId = lo.LabOrderId AND uli.IsUrgent = 1)
                  THEN 1 ELSE 0 END AS BIT) AS IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        hv.Status AS HomeVisitStatus,                                   -- 2390: latest home visit
        CAST(CASE WHEN dbo.fn_LabHomeCollectionHold(lo.LabOrderId) IS NULL THEN 1 ELSE 0 END AS BIT) AS CanCollect,
        CASE 
            WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B'
            ELSE ISNULL(ph.PaymentStatus, 'U')
        END AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount,
        ISNULL(ac.ContainerTypes, '—') AS ContainerTypes,
        agg.TotalTests,
        agg.CollectedCount,
        agg.PendingCount,
        agg.ReCollectCount,
        agg.RejectedCount,
        CASE 
            WHEN agg.CollectedCount = agg.TotalTests AND agg.TotalTests > 0 THEN 'Collected'
            WHEN agg.CollectedCount > 0 AND agg.CollectedCount < agg.TotalTests THEN 'Partially Collected'
            WHEN agg.ReCollectCount > 0 THEN 'Re Collect'
            WHEN agg.RejectedCount = agg.TotalTests AND agg.TotalTests > 0 THEN 'Rejected'
            ELSE 'Pending'
        END AS OverallStatus,
        ISNULL(lo.IsB2B, 0) AS IsB2B,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Franchise_Name
            WHEN lo.AgentType = 'C' THEN corp.Corporate_Name
            ELSE NULL
        END AS PartnerName
    INTO #FilteredOrders
    FROM OrderAggregates agg
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = agg.Laborderid AND lo.IsActive = 1 AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy OR (lo.AgentType = 'F' AND lo.B2BAgentID = (SELECT fu.ReferenceUserID FROM dbo.Users fu WHERE fu.Id = @CreatedBy AND fu.User_Type = 'F')))
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT JOIN AggregatedContainers ac ON ac.Laborderid = lo.LabOrderId
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    OUTER APPLY (SELECT TOP 1 v.Status FROM dbo.LabHomeVisit v WHERE v.LabOrderId = lo.LabOrderId ORDER BY v.VisitId DESC) hv
    WHERE lo.BranchId = @BranchId
      AND (NULLIF(NULLIF(@CollectionType, ''), 'All') IS NULL
           OR (@CollectionType = 'Home Collection' AND ISNULL(lo.CollectionType, '') = 'Home Collection')
           OR (@CollectionType <> 'Home Collection' AND ISNULL(lo.CollectionType, '') <> 'Home Collection'))
      AND (
          (@DateFilterType = 'OrderDate' AND lo.OrderDate BETWEEN @FromDate AND @ToDate)
          OR (@DateFilterType <> 'OrderDate' AND ISNULL(lo.BookingDate, agg.MinBookingDateTime) BETWEEN @FromDate AND @ToDate)
      )
      AND (
          @Search IS NULL OR LTRIM(RTRIM(@Search)) = ''
          OR lo.BillNo LIKE '%' + @Search + '%'
          OR lo.TokenNo LIKE '%' + @Search + '%'
          OR p.PatientCode LIKE '%' + @Search + '%'
          OR p.FirstName LIKE '%' + @Search + '%'
          OR p.LastName LIKE '%' + @Search + '%'
          OR p.PhoneNumber LIKE '%' + @Search + '%'
      );

    -- RS1: Summary Counters
    SELECT 
        COUNT(1) AS TotalOrders,
        SUM(CASE WHEN OverallStatus = 'Pending' THEN 1 ELSE 0 END) AS PendingOrders,
        SUM(CASE WHEN OverallStatus = 'Partially Collected' THEN 1 ELSE 0 END) AS PartialOrders,
        SUM(CASE WHEN OverallStatus = 'Collected' THEN 1 ELSE 0 END) AS CollectedOrders
    FROM #FilteredOrders;

    -- RS2: Header Rows (filtered by status)
    DECLARE @NormalizedStatus VARCHAR(50) = UPPER(LTRIM(RTRIM(ISNULL(@StatusFilter, 'ALL'))));

    SELECT *
    FROM #FilteredOrders
    WHERE (
        @NormalizedStatus = 'ALL' OR @NormalizedStatus = ''
        OR (@NormalizedStatus = 'PENDING' AND OverallStatus = 'Pending')
        OR (@NormalizedStatus = 'COLLECTED' AND OverallStatus = 'Collected')
        OR (@NormalizedStatus IN ('PARTIAL', 'PARTIALLY COLLECTED', 'PARTIALLY') AND OverallStatus = 'Partially Collected')
        OR (@NormalizedStatus IN ('RE COLLECT', 'RECOLLECT', 'RE-COLLECT') AND OverallStatus = 'Re Collect')
        OR (@NormalizedStatus = 'REJECTED' AND OverallStatus = 'Rejected')
    )
    ORDER BY IsUrgent DESC, BookingDateTime DESC, LabOrderId DESC;   -- urgent orders always on top

    DROP TABLE #FilteredOrders;
END
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
        (SELECT TOP 1 v.Status FROM dbo.LabHomeVisit v WHERE v.LabOrderId = lo.LabOrderId ORDER BY v.VisitId DESC) AS HomeVisitStatus,   -- 2390
        dbo.fn_LabHomeCollectionHold(lo.LabOrderId) AS CollectionHoldReason,
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

PRINT 'Script 2390 applied: Home Collection - handover before collection, no auto-collect, Collection Type filter.';
GO
