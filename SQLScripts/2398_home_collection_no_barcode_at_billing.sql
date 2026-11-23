-- ============================================================================================================
-- Migration: 2398_home_collection_no_barcode_at_billing.sql
-- Home Collection orders never get barcodes at billing, whatever Hospital Settings > "Barcode Gen at Billing" says:
-- the barcode is made at sample collection (Sample Collection screen) or saved from the phlebotomist app's pre-printed
-- tube barcode. Lab / B2B orders are unchanged (they follow the setting as before).
--   usp_CreateSampleCollectionFromLabOrder (billing) and usp_Lab_BillChange_Decide (tests added to a bill) - live
--   definitions + the "2398" check.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
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
        SET @CompanyId = ISNULL((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), 1);   -- 2332

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

    -- 2398: a Home Collection order never gets its barcodes at billing, whatever the setting says - they come at sample
    -- collection (or the phlebotomist app's pre-printed tube barcode)
    IF EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId AND ISNULL(CollectionType, '') = 'Home Collection')
        SET @BarcodeGenAtBilling = 0;

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

CREATE OR ALTER PROCEDURE dbo.usp_Lab_BillChange_Decide
    @BillChangeId   INT,
    @BranchId       INT,
    @UserId         INT,
    @Action         VARCHAR(10),   -- APPROVE / REFUSE
    @Remarks        NVARCHAR(300) = NULL,
    @DiscountAmount DECIMAL(12, 2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status VARCHAR(10), @Type VARCHAR(20), @Order INT, @Visit INT, @Company INT;
    SELECT @Status = Status, @Type = RequestType, @Order = LabOrderId, @Visit = VisitId, @Company = CompanyId
      FROM dbo.LabBillChangeRequest WITH (UPDLOCK) WHERE BillChangeId = @BillChangeId AND BranchId = @BranchId;

    IF @Status IS NULL BEGIN RAISERROR('This request is not of your branch.', 16, 1); RETURN; END
    IF @Status <> 'PENDING' BEGIN RAISERROR('This request has already been decided.', 16, 1); RETURN; END
    IF @Action NOT IN ('APPROVE', 'REFUSE') BEGIN RAISERROR('Choose approve or refuse.', 16, 1); RETURN; END
    IF @Action = 'REFUSE' AND NULLIF(LTRIM(RTRIM(@Remarks)), N'') IS NULL BEGIN RAISERROR('Give a reason.', 16, 1); RETURN; END

    DECLARE @EventId NVARCHAR(64) = CONCAT('WEB-', NEWID()), @NewStatus VARCHAR(10), @Header INT;

    IF @Action = 'REFUSE'
    BEGIN
        BEGIN TRANSACTION;
            UPDATE dbo.LabBillChangeRequest
               SET Status = 'REFUSED', NewTotal = OldTotal, ActionedBy = @UserId, ActionedDate = GETDATE(), ActionRemarks = @Remarks
             WHERE BillChangeId = @BillChangeId;
            IF @Visit IS NOT NULL
                INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, Reason, CreatedBy) VALUES (@Visit, 'BILL_REFUSED', @EventId, @Remarks, @UserId);
        COMMIT;
    END
    ELSE
    BEGIN
        DECLARE @IsTests BIT = CASE WHEN @Type IN ('ADD_TEST', 'REMOVE_TEST', 'REPLACE_TEST') THEN 1 ELSE 0 END;
        DECLARE @VisitStatus VARCHAR(15) = (SELECT Status FROM dbo.LabHomeVisit WHERE VisitId = @Visit);
        IF @IsTests = 1 AND ISNULL(@VisitStatus, '') NOT IN ('REACHED', 'IN_PROGRESS')
        BEGIN RAISERROR('The phlebotomist has left this stage of the visit. Refuse this request.', 16, 1); RETURN; END

        SELECT @Header = PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = 'LAB' AND ModuleRefId = @Order AND ISNULL(IsActive, 0) = 1;
        IF @Header IS NULL AND @Type IN ('ADD_TEST', 'REMOVE_TEST', 'REPLACE_TEST', 'DISCOUNT')
        BEGIN RAISERROR('This bill has no payment record yet. Open it on the bill page first.', 16, 1); RETURN; END

        IF @Type = 'DISCOUNT' AND (@DiscountAmount IS NULL OR @DiscountAmount <= 0)
        BEGIN RAISERROR('Enter the discount amount.', 16, 1); RETURN; END
        IF @Type = 'DISCOUNT' AND @DiscountAmount > (SELECT BalanceDue FROM dbo.PaymentHeader WHERE PaymentHeaderId = @Header)
        BEGIN RAISERROR('The discount cannot be more than the balance due.', 16, 1); RETURN; END

        DECLARE @Remove TABLE (ItemId INT PRIMARY KEY, Price DECIMAL(12, 2));
        INSERT @Remove
        SELECT DISTINCT i.LabOrderItemId, i.Price
          FROM dbo.LabBillChangeLine l
          JOIN dbo.LabOrderItem i ON i.LabOrderId = @Order AND i.InvestigationId = l.InvestigationId AND i.IsActive = 1
         WHERE l.BillChangeId = @BillChangeId AND l.LineAction = 'REMOVE';
        IF EXISTS (SELECT 1 FROM dbo.LabBillChangeLine WHERE BillChangeId = @BillChangeId AND LineAction = 'REMOVE')
           AND NOT EXISTS (SELECT 1 FROM @Remove)
        BEGIN RAISERROR('The test is no longer on this bill. Refuse this request.', 16, 1); RETURN; END
        IF EXISTS (SELECT 1 FROM @Remove)
           AND NOT EXISTS (SELECT 1 FROM dbo.LabBillChangeLine WHERE BillChangeId = @BillChangeId AND LineAction = 'ADD')
           AND NOT EXISTS (SELECT 1 FROM dbo.LabOrderItem i WHERE i.LabOrderId = @Order AND i.IsActive = 1
                            AND NOT EXISTS (SELECT 1 FROM @Remove x WHERE x.ItemId = i.LabOrderItemId))
        BEGIN RAISERROR('This removes every test. Use Bill Cancellation for the whole bill.', 16, 1); RETURN; END
        IF EXISTS (SELECT 1 FROM dbo.LabBillChangeLine l JOIN dbo.LabOrderItem i ON i.LabOrderId = @Order AND i.InvestigationId = l.InvestigationId AND i.IsActive = 1
                    WHERE l.BillChangeId = @BillChangeId AND l.LineAction = 'ADD')
        BEGIN RAISERROR('A test in this request is already on the bill. Refuse this request.', 16, 1); RETURN; END

        BEGIN TRY
            BEGIN TRANSACTION;

            DECLARE @Rev INT = ISNULL((SELECT MAX(RevisionNo) FROM dbo.LabBillRevision WHERE LabOrderId = @Order), 0) + 1;
            IF @IsTests = 1 OR @Type = 'DISCOUNT'
                INSERT dbo.LabBillRevision (LabOrderId, RevisionNo, BillChangeId, Snapshot, AppliedBy)
                SELECT @Order, @Rev, @BillChangeId,
                       (SELECT ph.SubTotal, ph.HeaderDiscountAmount, ph.NetAmount, ph.TotalPaid, ph.BalanceDue, o.TotalAmount,
                               (SELECT i.LabOrderItemId, i.InvestigationId, i.Type, i.Price FROM dbo.LabOrderItem i
                                 WHERE i.LabOrderId = @Order AND i.IsActive = 1 FOR JSON PATH) AS Items
                          FROM dbo.PaymentHeader ph JOIN dbo.LabOrder o ON o.LabOrderId = ph.ModuleRefId
                         WHERE ph.PaymentHeaderId = @Header FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                       @UserId;

            -- removed tests: an ordinary partial cancellation, with the same discount share as the Bill Cancellation page
            IF EXISTS (SELECT 1 FROM @Remove)
            BEGIN
                DECLARE @Sub DECIMAL(18, 2) = (SELECT SUM(Price) FROM @Remove), @Disc DECIMAL(18, 2), @BillDisc DECIMAL(18, 2), @BillSub DECIMAL(18, 2);
                SELECT @BillDisc = ISNULL(LineDiscountTotal, 0) + ISNULL(HeaderDiscountAmount, 0), @BillSub = ISNULL(SubTotal, 0)
                  FROM dbo.PaymentHeader WHERE PaymentHeaderId = @Header;
                SET @Disc = ISNULL((SELECT SUM(pli.LineDiscountAmount) FROM dbo.PaymentLineItem pli JOIN @Remove x ON x.ItemId = pli.ModuleLineRefId
                                     WHERE pli.PaymentHeaderId = @Header AND pli.IsActive = 1), 0);
                IF @Disc = 0 AND @BillSub > 0 SET @Disc = ROUND(@Sub / @BillSub * @BillDisc, 2);
                IF @Disc > @BillDisc SET @Disc = @BillDisc;

                DECLARE @Json NVARCHAR(MAX) = (SELECT ItemId AS lineRefId, Price AS amount FROM @Remove FOR JSON PATH),
                        @Why NVARCHAR(500) = CONCAT(N'Home collection bill change #', @BillChangeId), @CancelId INT, @CancelNo NVARCHAR(50);
                EXEC dbo.usp_Bill_Cancel @ModuleCode = 'LAB', @ModuleRefId = @Order, @BranchId = @BranchId, @LineItemsJson = @Json, @Reason = @Why,
                     @DiscountAdjusted = @Disc, @UserId = @UserId, @CancellationId = @CancelId OUTPUT, @CancellationNo = @CancelNo OUTPUT;
            END

            -- added tests
            DECLARE @Added DECIMAL(12, 2) = 0, @Test INT, @Price DECIMAL(12, 2), @Item INT;
            DECLARE @Patient INT, @Token NVARCHAR(50), @OrderDate DATE, @Booking DATETIME, @Urgent BIT;
            SELECT @Patient = PatientId, @Token = TokenNo, @OrderDate = CAST(OrderDate AS DATE), @Booking = ISNULL(BookingDate, OrderDate), @Urgent = ISNULL(IsUrgent, 0)
              FROM dbo.LabOrder WHERE LabOrderId = @Order;
            DECLARE @New TABLE (Id BIGINT PRIMARY KEY);

            DECLARE ac CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT InvestigationId, Price FROM dbo.LabBillChangeLine WHERE BillChangeId = @BillChangeId AND LineAction = 'ADD';
            OPEN ac; FETCH NEXT FROM ac INTO @Test, @Price;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                INSERT dbo.LabOrderItem (LabOrderId, InvestigationId, Price, IsActive, CreatedBy, CreatedDate, Type, IsUrgent)
                VALUES (@Order, @Test, @Price, 1, @UserId, GETDATE(), 'I', @Urgent);
                SET @Item = SCOPE_IDENTITY();

                INSERT dbo.PaymentLineItem (PaymentHeaderId, ModuleLineRefId, ItemDescription, ServiceType, OriginalAmount, LineDiscountType, LineDiscountValue,
                       LineDiscountAmount, NetLineAmount, CreatedDate, CreatedBy, IsActive, IsGstApplicable, GstPercentage, CgstAmount, SgstAmount, IgstAmount, CompanyId, MembershipDiscountAmount)
                SELECT @Header, @Item, t.Test_Name, 'Test', @Price, 'P', 0, 0, @Price, GETDATE(), @UserId, 1, 0, 0, 0, 0, 0, @Company, 0
                  FROM dbo.LabInvestigationMaster t WHERE t.Test_ID = @Test;

                -- a profile test brings its member tests; a single test brings itself (as usp_CreateSampleCollectionFromLabOrder)
                INSERT dbo.SampleCollection (Laborderid, BranchID, CompanyID, PatientID, TokenNo, InvestigationID, DepartmentID, DepartmentD, TestcategoryID,
                       TestsubcategoryID, TestsubcategotyID, Orderdate, Bookingdatetime, Is_Active, Samplecollectiondate, Samplecollectiontime, Iscancelled, CreatedBy,
                       CreatedDate, ProfilePackageName, ProfileId, ProfileName, CollectionstatusID, BarcodeNo, IsoutSource)
                OUTPUT inserted.samplecollectionID INTO @New (Id)
                SELECT @Order, @BranchId, @Company, @Patient, @Token, x.TestId, x.Dept, x.Dept, x.Cat, x.SubCat, x.SubCat, @OrderDate, @Booking, 1,
                       CASE WHEN x.NeedsSample = 0 THEN @OrderDate END, CASE WHEN x.NeedsSample = 0 THEN CAST(@Booking AS TIME(0)) END, 0, @UserId,
                       GETDATE(), x.Label, x.ProfileId, x.ProfileName, CASE WHEN x.NeedsSample = 0 THEN 2 ELSE 1 END, NULL, x.Outsourced
                  FROM (
                        SELECT t.Test_ID AS TestId, COALESCE(pm.Department_ID, t.Department_ID) AS Dept, COALESCE(pm.Category_ID, t.Category_ID) AS Cat,
                               COALESCE(pm.SubCategory_ID, t.SubCategory_ID) AS SubCat, h.Profile_ID AS ProfileId, h.Profile_Name AS ProfileName, h.Profile_Name AS Label,
                               CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT) AS NeedsSample, CAST(ISNULL(t.Is_Outsourced, 0) AS BIT) AS Outsourced
                          FROM dbo.LabInvestigationMaster pm
                          JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = pm.Test_ID OR h.Profile_Name = pm.Test_Name) AND h.IsDeleted = 0
                          JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.IsDeleted = 0
                          JOIN dbo.LabInvestigationMaster t ON t.Test_ID = d.Test_ID AND t.Status = 1 AND t.IsDeleted = 0
                          LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = t.Category_ID
                         WHERE pm.Test_ID = @Test
                        UNION ALL
                        SELECT t.Test_ID, t.Department_ID, t.Category_ID, t.SubCategory_ID, NULL, NULL, N'—',
                               CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT), CAST(ISNULL(t.Is_Outsourced, 0) AS BIT)
                          FROM dbo.LabInvestigationMaster t
                          LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = t.Category_ID
                         WHERE t.Test_ID = @Test
                           AND NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationProfileHeader h WHERE (h.Test_ID = t.Test_ID OR h.Profile_Name = t.Test_Name) AND h.IsDeleted = 0)
                       ) x;

                SET @Added += @Price;
                FETCH NEXT FROM ac INTO @Test, @Price;
            END
            CLOSE ac; DEALLOCATE ac;

            -- 2398: not for a Home Collection order (its barcodes come at collection / from the phlebotomist app)
            IF EXISTS (SELECT 1 FROM dbo.HospitalSettings WHERE BranchId = @BranchId AND IsActive = 1 AND ISNULL(BarcodeGenerateAtBilling, 0) = 1)
               AND NOT EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @Order AND ISNULL(CollectionType, '') = 'Home Collection')
            BEGIN
                DECLARE @Sc BIGINT, @Barcode NVARCHAR(50);
                DECLARE bc CURSOR LOCAL FAST_FORWARD FOR
                    SELECT sc.samplecollectionID FROM dbo.SampleCollection sc JOIN @New n ON n.Id = sc.samplecollectionID
                      LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = sc.TestcategoryID
                     WHERE ISNULL(cat.Is_Barcode_Required, 1) = 1 ORDER BY sc.samplecollectionID;
                OPEN bc; FETCH NEXT FROM bc INTO @Sc;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    SET @Barcode = NULL;
                    EXEC dbo.usp_Lab_AssignTubeBarcode @SampleCollectionId = @Sc, @BranchId = @BranchId, @Barcode = @Barcode OUTPUT;
                    UPDATE dbo.SampleCollection SET BarcodeNo = @Barcode WHERE samplecollectionID = @Sc AND BarcodeNo IS NULL;
                    FETCH NEXT FROM bc INTO @Sc;
                END
                CLOSE bc; DEALLOCATE bc;
            END

            IF @Added > 0
            BEGIN
                UPDATE dbo.LabOrder SET TotalAmount = TotalAmount + @Added, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE LabOrderId = @Order;
                UPDATE dbo.PaymentHeader
                   SET SubTotal = SubTotal + @Added, NetAmount = NetAmount + @Added,
                       BalanceDue = CASE WHEN NetAmount + @Added - TotalPaid > 0 THEN NetAmount + @Added - TotalPaid ELSE 0 END,
                       PaymentStatus = CASE WHEN TotalPaid >= NetAmount + @Added THEN 'P' WHEN TotalPaid > 0 THEN 'R' ELSE 'U' END,
                       LastModifiedDate = GETDATE(), LastModifiedBy = @UserId
                 WHERE PaymentHeaderId = @Header;

                -- the added revenue, as another LAB_BILL entry: usp_Ledger_PostBillMoney adds them up
                DECLARE @Sales INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Sales'),
                        @Dr INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable'),
                        @Cr INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'LAB Revenue'),
                        @BillNo NVARCHAR(60) = (SELECT BillNo FROM dbo.LabOrder WHERE LabOrderId = @Order), @Now DATETIME = GETDATE(), @Tx BIGINT;
                DECLARE @Narr NVARCHAR(300) = CONCAT(N'Tests added in the field, LAB Bill ', @BillNo);
                IF @Sales IS NOT NULL AND @Dr IS NOT NULL AND @Cr IS NOT NULL
                    EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Sales, @TransactionDate = @Now, @ReferenceType = 'LAB_BILL', @ReferenceId = @Order,
                         @BranchId = @BranchId, @CompanyId = @Company, @TotalAmount = @Added, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Cr,
                         @CreatedBy = @UserId, @NewTransactionId = @Tx OUTPUT;
            END

            IF @Type = 'DISCOUNT'
                UPDATE dbo.PaymentHeader
                   SET HeaderDiscountType = 'D', HeaderDiscountValue = ISNULL(HeaderDiscountAmount, 0) + @DiscountAmount,
                       HeaderDiscountAmount = ISNULL(HeaderDiscountAmount, 0) + @DiscountAmount, NetAmount = NetAmount - @DiscountAmount,
                       BalanceDue = BalanceDue - @DiscountAmount, PaymentStatus = CASE WHEN TotalPaid >= NetAmount - @DiscountAmount THEN 'P' WHEN TotalPaid > 0 THEN 'R' ELSE 'U' END,
                       DiscountReason = LEFT((SELECT Reason FROM dbo.LabBillChangeRequest WHERE BillChangeId = @BillChangeId), 200), DiscountApprovedBy = @UserId, DiscountApprovedDate = GETDATE(),
                       LastModifiedDate = GETDATE(), LastModifiedBy = @UserId
                 WHERE PaymentHeaderId = @Header;

            IF @Added > 0 OR @Type = 'DISCOUNT'
            BEGIN
                EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'ADJUST', @RefId = @Header, @UserId = @UserId;
                EXEC dbo.usp_Membership_SyncBill @PaymentHeaderId = @Header, @UserId = @UserId;
            END

            SET @NewStatus = CASE WHEN @IsTests = 1 OR @Type = 'DISCOUNT' THEN 'APPLIED' ELSE 'APPROVED' END;
            UPDATE dbo.LabBillChangeRequest
               SET Status = @NewStatus, NewTotal = dbo.ufn_Phlebo_BillAmount(@Order), ActionedBy = @UserId, ActionedDate = GETDATE(), ActionRemarks = @Remarks
             WHERE BillChangeId = @BillChangeId;
            IF @Visit IS NOT NULL
                INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, Reason, CreatedBy) VALUES (@Visit, 'BILL_APPROVED', @EventId, @Remarks, @UserId);

            COMMIT;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            THROW;
        END CATCH
    END

    SELECT r.Status, r.NewTotal, ph.BalanceDue,
           CASE WHEN ph.TotalPaid > ph.NetAmount THEN ph.TotalPaid - ph.NetAmount ELSE 0 END AS Refundable
      FROM dbo.LabBillChangeRequest r
      LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = r.LabOrderId AND ph.IsActive = 1
     WHERE r.BillChangeId = @BillChangeId;
END
GO

PRINT 'Script 2398 applied: no barcode at billing for Home Collection orders.';
GO
