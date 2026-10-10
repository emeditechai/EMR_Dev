-- ============================================================================
-- Migration: 2182_lab_profile_tests_follow_profile_department.sql
-- Description: The tests of a profile belong to the profile's own Department / Category / Sub-Category
--   (Investigation Master of the profile), e.g. Urine Routine & Microscopy is a Microbiology profile, so its
--   parameters are reported, filtered, scoped (User Master > Department Access) and printed - each Department
--   starting a new page - under Microbiology, not under the parameters' own Pathology department.
--   * usp_CreateSampleCollectionFromLabOrder - the live definition; the profile branches (a profile booked on its own,
--     and a profile inside a package) take the profile's Department / Category / Sub-Category, falling back to the
--     parameter's own when the profile has none. Nothing else changed. Every other profile already has the same
--     values as its parameters, so their sample rows come out exactly as before.
--   * Existing sample rows of a profile are aligned the same way (only rows whose values differ are touched).
--   Run after 2181.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ============================================================================
-- usp_CreateSampleCollectionFromLabOrder (altered)
--   Adds the @SkipAutoBarcode gate for a Franchise order with
--   PreprintedBarcode = 1 (see the comment inline below). Every other line is
--   identical to the version in script 2133 - nothing else about how this
--   order's SampleCollection rows are built changes.
-- ============================================================================
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
        DECLARE @v_ProfileId INT, @v_ProfileName NVARCHAR(200), @v_SampleCollectionId BIGINT;
        DECLARE @GenBarcode NVARCHAR(50);

        -- Cursor to group by ProfileId/ProfileName or SampleCollectionId for standalones
        -- SKIPS any tests where category has Is_Barcode_Required = 0!
        DECLARE barcode_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT sc.ProfileId, sc.ProfileName, MAX(sc.samplecollectionID)
        FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
        WHERE sc.Laborderid = @LabOrderId 
          AND sc.BarcodeNo IS NULL
          AND ISNULL(cat.Is_Barcode_Required, 1) = 1
        GROUP BY sc.ProfileId, sc.ProfileName, 
                 CASE WHEN sc.ProfileId IS NULL AND sc.ProfileName IS NULL THEN sc.samplecollectionID ELSE 0 END;

        OPEN barcode_cursor;
        FETCH NEXT FROM barcode_cursor INTO @v_ProfileId, @v_ProfileName, @v_SampleCollectionId;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GenBarcode OUTPUT;

            IF @v_ProfileId IS NOT NULL OR @v_ProfileName IS NOT NULL
            BEGIN
                UPDATE sc
                SET sc.BarcodeNo = @GenBarcode
                FROM dbo.SampleCollection sc
                LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
                LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
                WHERE sc.Laborderid = @LabOrderId
                  AND (
                      (@v_ProfileId IS NOT NULL AND sc.ProfileId = @v_ProfileId)
                      OR (@v_ProfileId IS NULL AND @v_ProfileName IS NOT NULL AND sc.ProfileName = @v_ProfileName)
                  )
                  AND sc.BarcodeNo IS NULL
                  AND ISNULL(cat.Is_Barcode_Required, 1) = 1;
            END
            ELSE
            BEGIN
                UPDATE sc
                SET sc.BarcodeNo = @GenBarcode
                FROM dbo.SampleCollection sc
                LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
                LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
                WHERE sc.samplecollectionID = @v_SampleCollectionId
                  AND sc.BarcodeNo IS NULL
                  AND ISNULL(cat.Is_Barcode_Required, 1) = 1;
            END

            FETCH NEXT FROM barcode_cursor INTO @v_ProfileId, @v_ProfileName, @v_SampleCollectionId;
        END

        CLOSE barcode_cursor;
        DEALLOCATE barcode_cursor;
    END
    -- ─────────────────────────────────────────────────────────────

    DROP TABLE #TestsToInsert;

    SELECT @InsertedCount AS RowsCount;
END
GO

-- Existing sample rows of a profile: the profile's Department / Category / Sub-Category.
UPDATE sc
SET sc.DepartmentID       = COALESCE(pm.Department_ID, sc.DepartmentID),
    sc.DepartmentD        = COALESCE(pm.Department_ID, sc.DepartmentD),
    sc.TestcategoryID     = COALESCE(pm.Category_ID, sc.TestcategoryID),
    sc.TestsubcategoryID  = COALESCE(pm.SubCategory_ID, sc.TestsubcategoryID),
    sc.TestsubcategotyID  = COALESCE(pm.SubCategory_ID, sc.TestsubcategotyID)
FROM dbo.SampleCollection sc
INNER JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = sc.ProfileId
INNER JOIN dbo.LabInvestigationMaster pm ON pm.Test_ID = h.Test_ID
WHERE (pm.Department_ID IS NOT NULL AND ISNULL(sc.DepartmentID, 0) <> pm.Department_ID)
   OR (pm.Category_ID IS NOT NULL AND ISNULL(sc.TestcategoryID, 0) <> pm.Category_ID)
   OR (pm.SubCategory_ID IS NOT NULL AND ISNULL(sc.TestsubcategoryID, 0) <> pm.SubCategory_ID);
PRINT CONCAT('Script 2182 applied: ', @@ROWCOUNT, ' existing profile sample row(s) aligned to the profile''s department / category.');
GO
