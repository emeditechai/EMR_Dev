-- ============================================================================================================
-- 2417  Phlebotomist pre-printed barcodes are consumed when the sample is collected (after 2416).
--   usp_LabPhleboBarcode_SyncSample: a tube saved as COLLECTED with a barcode of dbo.LabPhleboBarcodePool marks that
--   barcode Used (lab order, first sample, who, when); the same barcode on more tests of the same tube stays one use.
--   Undoing the collection (back to pending) gives the barcode back (Available) when no other collected tube of the
--   order still carries it. Called from usp_SampleCollection_UpdateStatus, which every collection path uses
--   (phlebotomist app and the Sample Collection screen).
--   usp_Phlebo_Visit_Samples (app): a pre-printed barcode must be issued to this phlebotomist, not voided, and not used
--   on another booking. Barcodes not from the pool behave as before.
--   Existing collected samples with pool barcodes are marked Used once (backfill). Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_LabPhleboBarcode_SyncSample @SampleCollectionId BIGINT, @UserId INT = NULL, @Release BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bc NVARCHAR(50), @order INT, @status INT;
    SELECT @bc = NULLIF(LTRIM(RTRIM(BarcodeNo)), N''), @order = Laborderid, @status = CollectionstatusID FROM dbo.SampleCollection WHERE samplecollectionID = @SampleCollectionId;
    IF @bc IS NULL RETURN;
    IF @Release = 0
    BEGIN
        IF ISNULL(@status, 0) <> 2 RETURN;
        UPDATE dbo.LabPhleboBarcodePool SET Status = 2, LabOrderId = @order, SamplecollectionID = @SampleCollectionId, UsedBy = @UserId, UsedDate = GETDATE()
         WHERE BarcodeNo = @bc AND Status = 1;
    END
    ELSE
    BEGIN
        -- the tube goes back to pending: free the barcode unless another collected tube of the order still has it
        IF NOT EXISTS (SELECT 1 FROM dbo.SampleCollection x WHERE x.Laborderid = @order AND x.BarcodeNo = @bc AND x.CollectionstatusID = 2
                          AND x.samplecollectionID <> @SampleCollectionId AND ISNULL(x.Iscancelled, 0) = 0)
            UPDATE dbo.LabPhleboBarcodePool SET Status = 1, LabOrderId = NULL, SamplecollectionID = NULL, UsedBy = NULL, UsedDate = NULL
             WHERE BarcodeNo = @bc AND Status = 2 AND LabOrderId = @order;
        ELSE
            UPDATE p SET SamplecollectionID = (SELECT MIN(x.samplecollectionID) FROM dbo.SampleCollection x WHERE x.Laborderid = @order AND x.BarcodeNo = @bc
                                                  AND x.CollectionstatusID = 2 AND x.samplecollectionID <> @SampleCollectionId AND ISNULL(x.Iscancelled, 0) = 0)
              FROM dbo.LabPhleboBarcodePool p WHERE p.BarcodeNo = @bc AND p.Status = 2 AND p.SamplecollectionID = @SampleCollectionId;
    END
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

        -- SQLScripts/2417: a pre-printed phlebotomist barcode on this tube is now used
        EXEC dbo.usp_LabPhleboBarcode_SyncSample @SampleCollectionId = @SampleCollectionId, @UserId = @UserId;

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
        -- SQLScripts/2417: the barcode is cleared below - give a pre-printed one back first
        EXEC dbo.usp_LabPhleboBarcode_SyncSample @SampleCollectionId = @SampleCollectionId, @UserId = @UserId, @Release = 1;
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
    -- SQLScripts/2417: a pre-printed barcode is the phlebotomist's own, not voided, and not used on another booking
    DECLARE @pbMsg NVARCHAR(300) = (SELECT TOP 1
            CASE WHEN p.PhlebotomistId <> @UserId THEN N'Barcode ' + t.Barcode + N' is issued to another phlebotomist.'
                 WHEN p.Status = 3 THEN N'Barcode ' + t.Barcode + N' was voided; use another label.'
                 WHEN p.Status = 2 AND ISNULL(p.LabOrderId, 0) <> @OrderId THEN N'Barcode ' + t.Barcode + N' is already used on another booking.' END
          FROM @Tubes t JOIN dbo.LabPhleboBarcodePool p ON p.BarcodeNo = t.Barcode
         WHERE t.Collected = 1 AND (p.PhlebotomistId <> @UserId OR p.Status = 3 OR (p.Status = 2 AND ISNULL(p.LabOrderId, 0) <> @OrderId)));
    IF @pbMsg IS NOT NULL BEGIN RAISERROR(@pbMsg, 16, 1); RETURN; END
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

-- backfill: collected tubes already carrying a pool barcode
UPDATE p SET Status = 2, LabOrderId = x.Laborderid, SamplecollectionID = x.Sid, UsedBy = x.ModifiedBy, UsedDate = ISNULL(x.ModifiedDate, GETDATE())
  FROM dbo.LabPhleboBarcodePool p
 CROSS APPLY (SELECT TOP 1 sc.Laborderid, MIN(sc.samplecollectionID) OVER (PARTITION BY sc.Laborderid) AS Sid, sc.ModifiedBy, sc.ModifiedDate
                FROM dbo.SampleCollection sc WHERE sc.BarcodeNo = p.BarcodeNo AND sc.CollectionstatusID = 2 AND ISNULL(sc.Iscancelled, 0) = 0
               ORDER BY sc.samplecollectionID) x
 WHERE p.Status = 1;
GO
PRINT 'Script 2417 applied: phlebotomist pre-printed barcodes consumed on collection.';
GO
