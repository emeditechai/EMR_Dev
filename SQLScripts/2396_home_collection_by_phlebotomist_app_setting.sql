-- ============================================================================================================
-- Migration: 2396_home_collection_by_phlebotomist_app_setting.sql
-- Hospital Settings > LAB > "Is Phlebotomist App Required" (2395) now decides how a Home Collection order is collected:
--   Yes: as 2390 - collected through the Phlebotomist App; the Sample Collection screen only after the hand-over, and
--        never auto-collected.
--   No : like a Lab order - collected on the Sample Collection screen at once, and auto-collected when "Is Sample
--        Collection Mandatory" is No.
--   fn_LabPhlebotomistAppRequired: the setting of the order's billing branch (its active Hospital Settings).
--   fn_LabHomeCollectionHold (2390) and usp_SampleCollection_AutoCollectIfNoMandatory (live + the check) use it.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION dbo.fn_LabPhlebotomistAppRequired (@LabOrderId INT)
RETURNS BIT
AS
BEGIN
    RETURN ISNULL((SELECT TOP 1 hs.IsPhlebotomistAppRequired
                     FROM dbo.LabOrder lo
                     JOIN dbo.HospitalSettings hs ON hs.BranchId = lo.BranchId
                    WHERE lo.LabOrderId = @LabOrderId
                    ORDER BY hs.IsActive DESC, hs.Id DESC), 0);
END
GO

-- why a Home Collection order cannot be collected at the lab desk yet (NULL = it can; Lab orders always can, and a
-- Home Collection order too when its branch does not use the Phlebotomist App)
CREATE OR ALTER FUNCTION dbo.fn_LabHomeCollectionHold (@LabOrderId INT)
RETURNS NVARCHAR(400)
AS
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId AND ISNULL(CollectionType, '') = 'Home Collection')
        RETURN NULL;
    IF dbo.fn_LabPhlebotomistAppRequired(@LabOrderId) = 0 RETURN NULL;   -- 2396
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
    -- 2396: only while the branch uses the Phlebotomist App; without it a Home Collection order follows the Lab rule
    IF EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId AND ISNULL(CollectionType, '') = 'Home Collection')
       AND dbo.fn_LabPhlebotomistAppRequired(@LabOrderId) = 1
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

PRINT 'Script 2396 applied: Home Collection follows Is Phlebotomist App Required.';
GO
