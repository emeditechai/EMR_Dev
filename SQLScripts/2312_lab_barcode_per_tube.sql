-- ============================================================================================================
-- Migration: 2312_lab_barcode_per_tube.sql
-- One barcode per tube: within a bill, every test whose sample type has the same Sample Name and Container Type
-- (LabSampleTypeMaster, via the test's Sample_Type_ID) gets the same barcode - e.g. all Serum / Yellow Top (SST) tests
-- of a bill, across profiles and single tests. A test without a sample type keeps the old rule (one barcode per
-- profile / package, else its own). Applies to every place a barcode is given: at billing, single / profile collection,
-- Collect All and auto-collection. Existing barcodes are never changed, and Is_Barcode_Required = 0 still skips.
-- B2B franchise pre-printed stickers: a sticker is applied to all tests of the bill with the same Sample Name +
-- Container Type, and a sticker already used on the SAME bill for the same Sample Name + Container Type is accepted for
-- another test of that tube (a sticker of another bill, or of another tube, is still refused). Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- The tube of a test: Sample Name + Container Type of its sample type (NULL when the test has no sample type)
CREATE OR ALTER FUNCTION dbo.ufn_Lab_SampleTubeKey (@InvestigationId INT)
RETURNS NVARCHAR(400)
AS
BEGIN
    RETURN (SELECT TOP 1 LOWER(LTRIM(RTRIM(ISNULL(st.Sample_Name, N'')))) + N'|' + LOWER(LTRIM(RTRIM(ISNULL(st.Container_Type, N''))))
              FROM dbo.LabInvestigationMaster lim
              INNER JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = lim.Sample_Type_ID
             WHERE lim.Test_ID = @InvestigationId
               AND (NULLIF(LTRIM(RTRIM(st.Sample_Name)), N'') IS NOT NULL OR NULLIF(LTRIM(RTRIM(st.Container_Type)), N'') IS NOT NULL));
END
GO

-- The barcode for one sample row: its own; else the barcode of a test of the same bill in the same tube (Sample Name +
-- Container Type); else - only when the test has no sample type - the old rule (its profile's barcode); else a new one.
CREATE OR ALTER PROCEDURE dbo.usp_Lab_AssignTubeBarcode
    @SampleCollectionId BIGINT,
    @BranchId           INT,
    @Barcode            NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Barcode = NULL;

    DECLARE @LabOrderId INT, @ProfileId INT, @ProfileName NVARCHAR(200), @Own NVARCHAR(50), @Key NVARCHAR(400);
    SELECT @LabOrderId = sc.Laborderid, @ProfileId = sc.ProfileId, @ProfileName = sc.ProfileName, @Own = sc.BarcodeNo,
           @Key = dbo.ufn_Lab_SampleTubeKey(sc.InvestigationID)
      FROM dbo.SampleCollection sc
     WHERE sc.samplecollectionID = @SampleCollectionId;

    IF @LabOrderId IS NULL RETURN;
    IF NULLIF(LTRIM(RTRIM(@Own)), N'') IS NOT NULL BEGIN SET @Barcode = @Own; RETURN; END

    IF @Key IS NOT NULL
        SELECT TOP 1 @Barcode = o.BarcodeNo
          FROM dbo.SampleCollection o
         WHERE o.Laborderid = @LabOrderId
           AND o.samplecollectionID <> @SampleCollectionId
           AND NULLIF(LTRIM(RTRIM(o.BarcodeNo)), N'') IS NOT NULL
           AND ISNULL(o.Iscancelled, 0) = 0 AND ISNULL(o.Is_Active, 1) = 1
           AND dbo.ufn_Lab_SampleTubeKey(o.InvestigationID) = @Key
         ORDER BY o.samplecollectionID;
    ELSE IF @ProfileId IS NOT NULL OR @ProfileName IS NOT NULL
        SELECT TOP 1 @Barcode = o.BarcodeNo
          FROM dbo.SampleCollection o
         WHERE o.Laborderid = @LabOrderId
           AND o.samplecollectionID <> @SampleCollectionId
           AND o.BarcodeNo IS NOT NULL
           AND ((@ProfileId IS NOT NULL AND o.ProfileId = @ProfileId)
             OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND o.ProfileName = @ProfileName))
         ORDER BY o.samplecollectionID;

    IF @Barcode IS NULL
        EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @Barcode OUTPUT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_CreateSampleCollectionFromLabOrder
    @LabOrderId INT,
    @BranchId   INT = NULL,
    @CompanyId  INT = NULL,
    @CreatedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
        RETURN;

    -- Avoid duplicate sample collection creation for this order
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId)
    BEGIN
        SELECT COUNT(1) AS RowsCount FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId;
        RETURN;
    END

    DECLARE @PatientId       INT;
    DECLARE @TokenNo         NVARCHAR(50);
    DECLARE @OrderDate       DATE;
    DECLARE @BookingDateTime DATETIME;
    DECLARE @OrderBranch     INT;
    DECLARE @OrderCreatedBy  INT;
    DECLARE @OrderIsB2B      BIT;
    DECLARE @OrderAgentType  VARCHAR(10);
    DECLARE @OrderB2BAgentID INT;

    SELECT 
        @OrderBranch     = BranchId,
        @PatientId       = PatientId,
        @TokenNo         = TokenNo,
        @OrderDate       = CAST(OrderDate AS DATE),
        @BookingDateTime = ISNULL(BookingDate, OrderDate),
        @OrderCreatedBy  = CreatedBy,
        @OrderIsB2B      = IsB2B,
        @OrderAgentType  = AgentType,
        @OrderB2BAgentID = B2BAgentID
    FROM dbo.LabOrder
    WHERE LabOrderId = @LabOrderId;

    IF @PatientId IS NULL
        RETURN;

    -- Pre-Printed Barcode (Franchise): when this B2B order's Franchise has PreprintedBarcode = 1,
    -- no system barcode is ever auto-generated for it - the franchise's own sticker, entered on the
    -- Sample Collection page, is validated against its pool and becomes the row's BarcodeNo instead
    -- (see dbo.usp_Lab_ValidateAndConsumeFranchiseBarcode). @SkipAutoBarcode only gates the
    -- barcode-AT-BILLING cursor below; it changes nothing for a B2C order or a Corporate order,
    -- and nothing for a Franchise whose own PreprintedBarcode flag is 0 (the default).
    DECLARE @SkipAutoBarcode BIT = 0;
    IF @OrderIsB2B = 1 AND @OrderAgentType = 'F' AND EXISTS (
        SELECT 1 FROM dbo.LabFranchiseMaster f
        WHERE f.Franchise_ID = @OrderB2BAgentID AND f.PreprintedBarcode = 1
    )
        SET @SkipAutoBarcode = 1;

    IF @BranchId IS NULL OR @BranchId <= 0
        SET @BranchId = @OrderBranch;

    IF @CompanyId IS NULL OR @CompanyId <= 0
        SET @CompanyId = 1;

    IF @CreatedBy IS NULL OR @CreatedBy <= 0
        SET @CreatedBy = @OrderCreatedBy;

    -- Temporary table to hold expanded tests
    CREATE TABLE #TestsToInsert (
        InvestigationId    INT,
        DepartmentId       INT,
        CategoryId         INT,
        SubCategoryId      INT,
        SampleTypeId       INT,
        ProfileId          INT,
        ProfileName        NVARCHAR(200),
        PackageId          INT,
        PackageName        NVARCHAR(200),
        ProfilePackageName NVARCHAR(200),
        IsoutSource        BIT,
        IsSampleRequired   BIT,
        IsBarcodeRequired  BIT
    );

    -- 1A. Packages (Type = 'P'): Standalone tests directly under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource, IsSampleRequired, IsBarcodeRequired)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
        t.Sample_Type_ID,
        NULL,
        NULL,
        h.Profile_ID,
        h.Profile_Name,
        h.Profile_Name,
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT),
        CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT),
        CAST(ISNULL(cat.Is_Barcode_Required, 1) AS BIT)
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON h.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
       AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail d 
        ON d.Profile_ID = h.Profile_ID 
       AND d.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = d.Test_ID 
       AND t.Status = 1 
       AND t.IsDeleted = 0
       AND t.Is_Profile_Test = 0
    LEFT JOIN dbo.LabTestCategoryMaster cat 
        ON cat.Category_ID = t.Category_ID
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.IsActive = 1;

    -- 1B. Packages (Type = 'P'): Tests under profiles that are under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource, IsSampleRequired, IsBarcodeRequired)
    SELECT DISTINCT
        t.Test_ID,
        COALESCE(pt.Department_ID, t.Department_ID),   -- a profile's tests belong to the profile's department / category
        COALESCE(pt.Category_ID, t.Category_ID),
        COALESCE(pt.SubCategory_ID, t.SubCategory_ID),
        t.Sample_Type_ID,
        pheader.Profile_ID,
        pheader.Profile_Name,
        h.Profile_ID,
        h.Profile_Name,
        pheader.Profile_Name,
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT),
        CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT),
        CAST(ISNULL(cat.Is_Barcode_Required, 1) AS BIT)
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON h.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
       AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail pd 
        ON pd.Profile_ID = h.Profile_ID 
       AND pd.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster pt 
        ON pt.Test_ID = pd.Test_ID AND pt.Is_Profile_Test = 1
    INNER JOIN dbo.LabInvestigationProfileHeader pheader 
        ON (pheader.Test_ID = pt.Test_ID OR pheader.Profile_Name = pt.Test_Name) AND pheader.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail child_d 
        ON child_d.Profile_ID = pheader.Profile_ID AND child_d.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = child_d.Test_ID 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    LEFT JOIN dbo.LabTestCategoryMaster cat 
        ON cat.Category_ID = t.Category_ID
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.IsActive = 1;

    -- 2. Profiles (Type = 'I' AND Is_Profile_Test = 1): Tests under regular profiles
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource, IsSampleRequired, IsBarcodeRequired)
    SELECT DISTINCT
        t.Test_ID,
        COALESCE(pm.Department_ID, t.Department_ID),   -- a profile's tests belong to the profile's department / category
        COALESCE(pm.Category_ID, t.Category_ID),
        COALESCE(pm.SubCategory_ID, t.SubCategory_ID),
        t.Sample_Type_ID,
        h.Profile_ID,
        h.Profile_Name,
        NULL,
        NULL,
        h.Profile_Name,
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT),
        CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT),
        CAST(ISNULL(cat.Is_Barcode_Required, 1) AS BIT)
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON (h.Test_ID = loi.InvestigationId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = loi.InvestigationId))
       AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail d 
        ON d.Profile_ID = h.Profile_ID 
       AND d.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = d.Test_ID 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    LEFT JOIN dbo.LabInvestigationMaster pm 
        ON pm.Test_ID = h.Test_ID
    LEFT JOIN dbo.LabTestCategoryMaster cat 
        ON cat.Category_ID = t.Category_ID
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.Type = 'I'
      AND loi.IsActive = 1;

    -- 3. Non-profile regular individual tests (Type = 'I' AND Is_Profile_Test = 0)
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource, IsSampleRequired, IsBarcodeRequired)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
        t.Sample_Type_ID,
        NULL,
        NULL,
        NULL,
        NULL,
        '—',
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT),
        CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT),
        CAST(ISNULL(cat.Is_Barcode_Required, 1) AS BIT)
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = loi.InvestigationId 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    LEFT JOIN dbo.LabTestCategoryMaster cat 
        ON cat.Category_ID = t.Category_ID
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.Type = 'I'
      AND loi.IsActive = 1
      AND NOT EXISTS (
          SELECT 1 
          FROM dbo.LabInvestigationProfileHeader h 
          WHERE (h.Test_ID = loi.InvestigationId OR h.Profile_Name = t.Test_Name) 
            AND h.IsDeleted = 0
      );

    -- Insert into SampleCollection table:
    -- If IsSampleRequired = 0: auto-mark CollectionstatusID = 2 (ready for report entry immediately)
    -- If IsSampleRequired = 1: CollectionstatusID = 1 (Pending sample collection)
    INSERT INTO dbo.SampleCollection (
        Laborderid,
        BranchID,
        CompanyID,
        PatientID,
        TokenNo,
        InvestigationID,
        DepartmentID,
        DepartmentD,
        TestcategoryID,
        TestsubcategoryID,
        TestsubcategotyID,
        Orderdate,
        Bookingdatetime,
        Is_Active,
        Samplecollectiondate,
        Samplecollectiontime,
        Iscancelled,
        CreatedBy,
        CreatedDate,
        ProfilePackageName,
        ProfileId,
        ProfileName,
        PackageId,
        PackageName,
        CollectionstatusID,
        BarcodeNo,
        IsoutSource
    )
    SELECT 
        @LabOrderId,
        @BranchId,
        @CompanyId,
        @PatientId,
        @TokenNo,
        ti.InvestigationId,
        ti.DepartmentId,
        ti.DepartmentId,
        ti.CategoryId,
        ti.SubCategoryId,
        ti.SubCategoryId,
        @OrderDate,
        @BookingDateTime,
        1,
        CASE WHEN ti.IsSampleRequired = 0 THEN @OrderDate ELSE NULL END,
        CASE WHEN ti.IsSampleRequired = 0 THEN CAST(@BookingDateTime AS TIME(0)) ELSE NULL END,
        0,
        @CreatedBy,
        GETDATE(),
        ti.ProfilePackageName,
        ti.ProfileId,
        ti.ProfileName,
        ti.PackageId,
        ti.PackageName,
        CASE WHEN ti.IsSampleRequired = 0 THEN 2 ELSE 1 END,
        NULL,
        ti.IsoutSource
    FROM #TestsToInsert ti;

    DECLARE @InsertedCount INT = @@ROWCOUNT;

    -- Flags these rows for the Sample Collection page: show a manual/scan barcode entry
    -- instead of the usual read-only system-generated badge.
    IF @SkipAutoBarcode = 1
    BEGIN
        UPDATE dbo.SampleCollection
        SET RequiresManualBarcode = 1
        WHERE Laborderid = @LabOrderId;
    END

    -- ── CHECK FOR BARCODE GEN AT BILLING ────────────────────────────
    -- ONLY generate barcodes if HospitalSettings.BarcodeGenerateAtBilling = 1
    -- AND the test's category has Is_Barcode_Required = 1!
    DECLARE @BarcodeGenAtBilling BIT = 0;
    SELECT @BarcodeGenAtBilling = ISNULL(BarcodeGenerateAtBilling, 0)
    FROM dbo.HospitalSettings
    WHERE BranchId = @BranchId AND IsActive = 1;

    IF @BarcodeGenAtBilling = 1 AND @SkipAutoBarcode = 0
    BEGIN
        -- One barcode per tube (SQLScripts/2312): tests of this bill with the same Sample Name + Container Type share a
        -- barcode; a test without a sample type keeps the old rule (shared within its profile, else its own).
        -- SKIPS any tests where category has Is_Barcode_Required = 0!
        DECLARE @v_SampleCollectionId BIGINT, @GenBarcode NVARCHAR(50);
        DECLARE barcode_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT sc.samplecollectionID
        FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
        WHERE sc.Laborderid = @LabOrderId
          AND sc.BarcodeNo IS NULL
          AND ISNULL(cat.Is_Barcode_Required, 1) = 1
        ORDER BY sc.samplecollectionID;

        OPEN barcode_cursor;
        FETCH NEXT FROM barcode_cursor INTO @v_SampleCollectionId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @GenBarcode = NULL;
            EXEC dbo.usp_Lab_AssignTubeBarcode @SampleCollectionId = @v_SampleCollectionId, @BranchId = @BranchId, @Barcode = @GenBarcode OUTPUT;
            UPDATE dbo.SampleCollection SET BarcodeNo = @GenBarcode
             WHERE samplecollectionID = @v_SampleCollectionId AND BarcodeNo IS NULL;
            FETCH NEXT FROM barcode_cursor INTO @v_SampleCollectionId;
        END

        CLOSE barcode_cursor;
        DEALLOCATE barcode_cursor;
    END
    -- ─────────────────────────────────────────────────────────────

    DROP TABLE #TestsToInsert;

    SELECT @InsertedCount AS RowsCount;
END
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

CREATE OR ALTER PROCEDURE dbo.usp_Lab_ValidateAndConsumeFranchiseBarcode
    @BarcodeNo          NVARCHAR(50),
    @Franchise_ID        INT,
    @LabOrderId          INT,
    @SamplecollectionID  BIGINT,
    @InvestigationId     INT = NULL,
    @UserId              INT = NULL,
    @Success             BIT OUTPUT,
    @ErrorMessage        NVARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Success = 0;
    SET @ErrorMessage = NULL;
    SET @BarcodeNo = LTRIM(RTRIM(ISNULL(@BarcodeNo, '')));

    IF @BarcodeNo = ''
    BEGIN
        SET @ErrorMessage = 'Please enter or scan a barcode.';
        RETURN;
    END

    IF @SamplecollectionID IS NULL OR @SamplecollectionID <= 0
    BEGIN
        SET @ErrorMessage = 'A valid sample is required.';
        RETURN;
    END

    BEGIN TRANSACTION;

    BEGIN TRY
        DECLARE @PoolFranchiseId INT, @PoolStatus TINYINT, @SeriesStatus NVARCHAR(20);
        DECLARE @UsedBillNo NVARCHAR(100), @UsedDate DATETIME2;

        SELECT
            @PoolFranchiseId = bp.Franchise_ID,
            @PoolStatus      = bp.Status,
            @SeriesStatus    = s.Status,
            @UsedDate        = bp.UsedDate
        FROM dbo.LabFranchiseBarcodePool bp WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
        INNER JOIN dbo.LabFranchiseBarcodeSeries s ON s.SeriesId = bp.SeriesId
        WHERE bp.BarcodeNo = @BarcodeNo;

        IF @PoolFranchiseId IS NULL
        BEGIN
            SET @ErrorMessage = 'Barcode not found.';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @PoolFranchiseId <> @Franchise_ID
        BEGIN
            SET @ErrorMessage = 'This barcode belongs to a different franchise.';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @SeriesStatus = 'Cancelled' OR @PoolStatus = 3
        BEGIN
            SET @ErrorMessage = 'This barcode''s series was cancelled.';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- One barcode per tube (SQLScripts/2312): a sticker already used on THIS bill for a test of the same
        -- Sample Name + Container Type is the same tube - it is applied to this test too instead of being refused.
        DECLARE @ScanKey NVARCHAR(400) = (SELECT dbo.ufn_Lab_SampleTubeKey(sc.InvestigationID) FROM dbo.SampleCollection sc
                                           WHERE sc.samplecollectionID = @SamplecollectionID AND sc.Laborderid = @LabOrderId);
        IF @PoolStatus = 2 AND @ScanKey IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.LabFranchiseBarcodePool bp WHERE bp.BarcodeNo = @BarcodeNo AND bp.LabOrderId = @LabOrderId)
           AND EXISTS (SELECT 1 FROM dbo.SampleCollection o
                        WHERE o.Laborderid = @LabOrderId AND o.BarcodeNo = @BarcodeNo AND ISNULL(o.Iscancelled, 0) = 0
                          AND dbo.ufn_Lab_SampleTubeKey(o.InvestigationID) = @ScanKey)
        BEGIN
            UPDATE sc SET BarcodeNo = @BarcodeNo
            FROM dbo.SampleCollection sc
            WHERE sc.Laborderid = @LabOrderId AND sc.BarcodeNo IS NULL AND ISNULL(sc.Iscancelled, 0) = 0
              AND (sc.samplecollectionID = @SamplecollectionID OR dbo.ufn_Lab_SampleTubeKey(sc.InvestigationID) = @ScanKey);
            COMMIT TRANSACTION;
            SET @Success = 1;
            RETURN;
        END

        IF @PoolStatus = 2
        BEGIN
            SELECT @UsedBillNo = lo.BillNo FROM dbo.LabOrder lo
            INNER JOIN dbo.LabFranchiseBarcodePool bp ON bp.LabOrderId = lo.LabOrderId
            WHERE bp.BarcodeNo = @BarcodeNo;

            SET @ErrorMessage = 'Already used on Bill ' + ISNULL(@UsedBillNo, '(unknown)')
                + ', ' + CONVERT(NVARCHAR(20), @UsedDate, 106)
                + CASE WHEN EXISTS (SELECT 1 FROM dbo.LabFranchiseBarcodePool bp WHERE bp.BarcodeNo = @BarcodeNo AND bp.LabOrderId = @LabOrderId)
                       THEN ' for a different sample / container type - use a separate sticker for this tube.' ELSE '.' END;
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- All checks passed: mark Used and stamp what consumed it.
        UPDATE dbo.LabFranchiseBarcodePool
        SET Status = 2,
            LabOrderId = @LabOrderId,
            SamplecollectionID = @SamplecollectionID,
            InvestigationId = @InvestigationId,
            UsedDate = GETDATE(),
            UsedBy = @UserId
        WHERE BarcodeNo = @BarcodeNo;

        -- Write it onto SampleCollection.BarcodeNo - the row scanned, plus every sibling row of the
        -- same order sharing the same tube (Profile/Package), exactly like the system's own
        -- shared-tube barcodes already work. usp_SampleCollection_UpdateStatus needs no change: it
        -- already keeps a pre-existing BarcodeNo instead of generating a new one.
        DECLARE @ProfileId INT, @ProfileName NVARCHAR(200);
        SELECT @ProfileId = ProfileId, @ProfileName = ProfileName
        FROM dbo.SampleCollection WHERE samplecollectionID = @SamplecollectionID;

        -- One barcode per tube (SQLScripts/2312): every test of this bill with the same Sample Name + Container Type;
        -- a test without a sample type keeps the old rule (its profile / package)
        UPDATE sc
        SET BarcodeNo = @BarcodeNo
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.BarcodeNo IS NULL
          AND ISNULL(sc.Iscancelled, 0) = 0
          AND (
                sc.samplecollectionID = @SamplecollectionID
             OR (@ScanKey IS NOT NULL AND dbo.ufn_Lab_SampleTubeKey(sc.InvestigationID) = @ScanKey)
             OR (@ScanKey IS NULL AND @ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
             OR (@ScanKey IS NULL AND @ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );

        COMMIT TRANSACTION;
        SET @Success = 1;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Success = 0;
        SET @ErrorMessage = 'Server error while validating the barcode. Please try again.';
    END CATCH
END
GO

PRINT 'Script 2312 applied: one barcode per tube (Sample Name + Container Type) per bill.';
GO
