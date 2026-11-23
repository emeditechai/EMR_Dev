-- ============================================================================================================
-- 2415  Phlebotomist app > Collect Samples: a collected tube is saved only with the barcode scanned from its label.
--   usp_Phlebo_Visit_Samples (live definition + the 2415 check): a collected tube whose test category needs a
--   barcode (LabTestCategoryMaster.Is_Barcode_Required) and arrives without one is refused, so no barcode is made up
--   at saving. The scanned barcode is saved to SampleCollection.BarcodeNo as before. The app hides Save until every
--   collected tube is scanned.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- Samples stay open while a bill change on the visit is waiting. Otherwise as in 2374.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Visit_Samples
    @UserId        INT,
    @VisitId       INT,
    @ClientEventId NVARCHAR(64),
    @TubesJson     NVARCHAR(MAX),
    @DeviceTime    DATETIME = NULL,
    @Latitude      DECIMAL(10, 8) = NULL,
    @Longitude     DECIMAL(11, 8) = NULL,
    @AccuracyM     DECIMAL(8, 2) = NULL,
    @IsMock        BIT = 0,
    @DueReason     NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@ClientEventId)), N'') IS NULL BEGIN RAISERROR('ClientEventId is required.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.LabHomeVisitEvent WHERE ClientEventId = @ClientEventId)
    BEGIN
        SELECT VisitId, Status, NeedsReview FROM dbo.LabHomeVisit WHERE VisitId = @VisitId;
        RETURN;
    END

    DECLARE @Cur VARCHAR(15), @OrderId INT, @Lat DECIMAL(10, 8), @Lng DECIMAL(11, 8), @Company INT, @OtpOk DATETIME;
    SELECT @Cur = Status, @OrderId = LabOrderId, @Lat = Latitude, @Lng = Longitude, @Company = CompanyId, @OtpOk = OtpVerifiedOn
      FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId;
    IF @Cur IS NULL BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END
    IF @Cur <> 'IN_PROGRESS' BEGIN RAISERROR('Begin the visit first.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.LabBillChangeRequest WHERE VisitId = @VisitId AND Status = 'PENDING')
    BEGIN RAISERROR('A bill change is waiting for approval. Ask the office to decide it first.', 16, 1); RETURN; END

    DECLARE @OtpReq BIT, @ArrRadius INT, @Outside VARCHAR(5);
    SELECT @OtpReq = OtpRequired, @ArrRadius = ArrivalRadiusM, @Outside = OutsideRadiusAction FROM dbo.PhleboSettings WHERE CompanyId = @Company;
    IF @OtpReq = 1 AND @OtpOk IS NULL BEGIN RAISERROR('Verify the patient first.', 16, 1); RETURN; END

    DECLARE @Dist FLOAT = dbo.ufn_Phlebo_DistanceM(@Latitude, @Longitude, @Lat, @Lng);
    IF @Outside = 'BLOCK' AND @Dist > @ArrRadius BEGIN RAISERROR('You are too far from the patient address.', 16, 1); RETURN; END

    DECLARE @Tubes TABLE (Id BIGINT PRIMARY KEY, Collected BIT, Barcode NVARCHAR(50), ReasonId INT, Remarks NVARCHAR(300));
    INSERT @Tubes
    SELECT j.id, ISNULL(j.collected, 0), NULLIF(LTRIM(RTRIM(j.barcode)), N''), j.reasonId, j.remarks
      FROM OPENJSON(@TubesJson) WITH (id BIGINT '$.sampleCollectionId', collected BIT '$.collected', barcode NVARCHAR(50) '$.barcode',
                                      reasonId INT '$.reasonId', remarks NVARCHAR(300) '$.remarks') j;

    -- every open tube of this booking must be answered, and only its own tubes
    IF EXISTS (SELECT 1 FROM @Tubes t WHERE NOT EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.samplecollectionID = t.Id AND sc.Laborderid = @OrderId))
    BEGIN RAISERROR('A tube does not belong to this booking.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection sc
                 LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
                 LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
                WHERE sc.Laborderid = @OrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0 AND ISNULL(sc.CollectionstatusID, 1) IN (1, 3)
                  AND ISNULL(cat.Is_Sample_Collection_Required, 1) = 1
                  AND NOT EXISTS (SELECT 1 FROM @Tubes t WHERE t.Id = sc.samplecollectionID))
    BEGIN RAISERROR('Scan every tube, or mark it as not collected.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @Tubes t WHERE t.Collected = 0 AND t.ReasonId IS NULL)
    BEGIN RAISERROR('Choose a reason for every tube not collected.', 16, 1); RETURN; END
    -- 2415: a collected tube that needs a barcode is saved only with the barcode scanned from its label
    IF EXISTS (SELECT 1 FROM @Tubes t
                 JOIN dbo.SampleCollection sc ON sc.samplecollectionID = t.Id
                 LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
                 LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
                WHERE t.Collected = 1 AND t.Barcode IS NULL AND ISNULL(cat.Is_Barcode_Required, 1) = 1)
    BEGIN RAISERROR('Scan the barcode of every collected tube.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @Tubes t JOIN dbo.SampleCollection sc ON sc.BarcodeNo = t.Barcode AND sc.Laborderid <> @OrderId AND ISNULL(sc.Iscancelled, 0) = 0)
    BEGIN RAISERROR('A barcode is already used on another booking.', 16, 1); RETURN; END

    DECLARE @Due DECIMAL(12, 2) = (SELECT CASE WHEN ISNULL(o.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(ph.BalanceDue, dbo.ufn_Phlebo_BillAmount(o.LabOrderId)) END
                                     FROM dbo.LabOrder o
                                     LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
                                    WHERE o.LabOrderId = @OrderId);
    IF @Due > 0 AND NULLIF(LTRIM(RTRIM(@DueReason)), N'') IS NULL
    BEGIN RAISERROR('Record the payment, or give a reason for leaving the amount due.', 16, 1); RETURN; END

    DECLARE @At DATETIME = CASE WHEN @DeviceTime IS NOT NULL AND @DeviceTime <= GETDATE() AND @DeviceTime >= DATEADD(DAY, -1, GETDATE()) THEN @DeviceTime ELSE GETDATE() END;
    DECLARE @ColDate DATE = CAST(@At AS DATE), @ColTime TIME(0) = CAST(@At AS TIME(0));
    DECLARE @Failed INT = (SELECT COUNT(*) FROM @Tubes WHERE Collected = 0);
    DECLARE @Sink TABLE (R INT);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE sc SET BarcodeNo = t.Barcode FROM dbo.SampleCollection sc JOIN @Tubes t ON t.Id = sc.samplecollectionID WHERE t.Collected = 1 AND t.Barcode IS NOT NULL;

        DECLARE @Id BIGINT, @Col BIT, @RId INT, @Rem NVARCHAR(300), @RText NVARCHAR(300);
        DECLARE tc CURSOR LOCAL FAST_FORWARD FOR SELECT Id, Collected, ReasonId, Remarks FROM @Tubes;
        OPEN tc; FETCH NEXT FROM tc INTO @Id, @Col, @RId, @Rem;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @Col = 1
                INSERT @Sink EXEC dbo.usp_SampleCollection_UpdateStatus @SampleCollectionId = @Id, @CollectionstatusID = 2,
                     @SampleCollectionDate = @ColDate, @SampleCollectionTime = @ColTime, @UserId = @UserId;
            ELSE
            BEGIN
                INSERT @Sink EXEC dbo.usp_SampleCollection_UpdateStatus @SampleCollectionId = @Id, @CollectionstatusID = 3, @UserId = @UserId;
                SELECT @RText = Reason_Text FROM dbo.LabSampleRejectionReasonMaster WHERE Reason_ID = @RId;
                UPDATE dbo.SampleCollection SET RejectionReasonId = @RId, RejectionReason = LEFT(CONCAT(@RText, N' ', @Rem), 500) WHERE samplecollectionID = @Id;
            END
            FETCH NEXT FROM tc INTO @Id, @Col, @RId, @Rem;
        END
        CLOSE tc; DEALLOCATE tc;

        INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, DeviceTime, Latitude, Longitude, AccuracyM, IsMock, DistanceM, Reason, CreatedBy)
        VALUES (@VisitId, 'COLLECTED', @ClientEventId, @DeviceTime, @Latitude, @Longitude, @AccuracyM, @IsMock, @Dist, @DueReason, @UserId);

        UPDATE dbo.LabHomeVisit
           SET Status = 'COLLECTED', ModifiedDate = GETDATE(),
               NeedsReview = CASE WHEN @IsMock = 1 OR @Dist > @ArrRadius THEN 1 ELSE NeedsReview END
         WHERE VisitId = @VisitId;

        -- failed tubes go back out as a child visit, for the dispatcher to re-time
        IF @Failed > 0
            INSERT dbo.LabHomeVisit (CompanyId, BranchId, LabOrderId, PatientId, PhlebotomistId, SlotAt, AddressSnapshot, Latitude, Longitude, ParentVisitId)
            SELECT CompanyId, BranchId, LabOrderId, PatientId, PhlebotomistId, DATEADD(DAY, 1, GETDATE()), AddressSnapshot, Latitude, Longitude, VisitId
              FROM dbo.LabHomeVisit WHERE VisitId = @VisitId;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT VisitId, Status, NeedsReview FROM dbo.LabHomeVisit WHERE VisitId = @VisitId;
END
GO
PRINT 'Script 2415 applied: phlebotomist app saves a collected tube only with its scanned barcode.';
GO
