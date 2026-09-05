-- ── Barcode Generation At Billing Logic ────────────────────────────────
-- Modifies usp_CreateSampleCollectionFromLabOrder to generate barcodes
-- immediately if HospitalSettings.BarcodeGenerateAtBilling = 1

CREATE OR ALTER PROCEDURE dbo.usp_CreateSampleCollectionFromLabOrder
    @LabOrderId INT,
    @BranchId   INT = NULL,
    @CompanyId  INT = NULL,
    @CreatedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PatientId       INT;
    DECLARE @OrderDate       DATETIME;
    DECLARE @BookingDateTime DATETIME;
    DECLARE @TokenNo         NVARCHAR(50);
    DECLARE @OrderBranch     INT;

    SELECT 
        @PatientId       = PatientId,
        @OrderDate       = OrderDate,
        @BookingDateTime = BookingDate,
        @TokenNo         = TokenNo,
        @OrderBranch     = BranchId
    FROM dbo.LabOrder
    WHERE LabOrderId = @LabOrderId;

    IF @PatientId IS NULL
    BEGIN
        RAISERROR('LabOrder with ID %d was not found.', 16, 1, @LabOrderId);
        RETURN;
    END

    IF @BranchId IS NULL OR @BranchId <= 0
        SET @BranchId = @OrderBranch;

    IF @CompanyId IS NULL OR @CompanyId <= 0
        SET @CompanyId = 1;

    -- If records already exist for this order, update TokenNo / Bookingdatetime if needed and return
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId)
    BEGIN
        UPDATE dbo.SampleCollection
        SET 
            TokenNo = ISNULL(@TokenNo, TokenNo),
            Bookingdatetime = ISNULL(@BookingDateTime, Bookingdatetime)
        WHERE Laborderid = @LabOrderId 
          AND (
              (@TokenNo IS NOT NULL AND (TokenNo IS NULL OR TokenNo <> @TokenNo))
              OR (@BookingDateTime IS NOT NULL AND (Bookingdatetime IS NULL OR Bookingdatetime <> @BookingDateTime))
          );

        SELECT COUNT(1) AS RowsCount FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId;
        RETURN;
    END

    -- Temporary table to hold resolved individual investigation tests
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
        ProfilePackageName NVARCHAR(200)
    );

    -- 1A. Packages (Type = 'P'): Direct standalone tests under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName)
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
        h.Profile_Name
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
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.IsActive = 1;

    -- 1B. Packages (Type = 'P'): Tests under profiles that are under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
        t.Sample_Type_ID,
        pheader.Profile_ID,
        pheader.Profile_Name,
        h.Profile_ID,
        h.Profile_Name,
        pheader.Profile_Name
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
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.IsActive = 1;

    -- 2. Profiles (Type = 'I' AND Is_Profile_Test = 1): Tests under regular profiles
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
        t.Sample_Type_ID,
        h.Profile_ID,
        h.Profile_Name,
        NULL,
        NULL,
        h.Profile_Name
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
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.Type = 'I'
      AND loi.IsActive = 1;

    -- 3. Non-profile regular individual tests (Type = 'I' AND Is_Profile_Test = 0)
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName)
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
        '—'
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = loi.InvestigationId 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.Type = 'I'
      AND loi.IsActive = 1
      AND NOT EXISTS (
          SELECT 1 
          FROM dbo.LabInvestigationProfileHeader h 
          WHERE (h.Test_ID = loi.InvestigationId OR h.Profile_Name = t.Test_Name) 
            AND h.IsDeleted = 0
      );

    -- Insert into SampleCollection table
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
        BarcodeNo
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
        NULL,
        NULL,
        0,
        @CreatedBy,
        GETDATE(),
        ti.ProfilePackageName,
        ti.ProfileId,
        ti.ProfileName,
        ti.PackageId,
        ti.PackageName,
        1,   -- 1 = Pending
        NULL -- Barcode only generated AFTER collection!
    FROM #TestsToInsert ti;

    DECLARE @InsertedCount INT = @@ROWCOUNT;

    DROP TABLE #TestsToInsert;

    -- ── CHECK FOR BARCODE GEN AT BILLING ────────────────────────────
    DECLARE @BarcodeGenAtBilling BIT = 0;
    SELECT @BarcodeGenAtBilling = ISNULL(BarcodeGenerateAtBilling, 0)
    FROM dbo.HospitalSettings
    WHERE BranchId = @BranchId AND IsActive = 1;

    IF @BarcodeGenAtBilling = 1
    BEGIN
        DECLARE @v_ProfileId INT, @v_ProfileName NVARCHAR(200), @v_SampleCollectionId BIGINT;
        DECLARE @GenBarcode NVARCHAR(50);

        -- Cursor to group by ProfileId/ProfileName or SampleCollectionId for standalones
        DECLARE barcode_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT ProfileId, ProfileName, MAX(samplecollectionID)
        FROM dbo.SampleCollection
        WHERE Laborderid = @LabOrderId AND BarcodeNo IS NULL
        GROUP BY ProfileId, ProfileName, 
                 CASE WHEN ProfileId IS NULL AND ProfileName IS NULL THEN samplecollectionID ELSE 0 END;

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
                WHERE sc.Laborderid = @LabOrderId
                  AND (
                      (@v_ProfileId IS NOT NULL AND sc.ProfileId = @v_ProfileId)
                      OR (@v_ProfileId IS NULL AND @v_ProfileName IS NOT NULL AND sc.ProfileName = @v_ProfileName)
                  )
                  AND sc.BarcodeNo IS NULL;
            END
            ELSE
            BEGIN
                UPDATE sc
                SET sc.BarcodeNo = @GenBarcode
                FROM dbo.SampleCollection sc
                WHERE sc.samplecollectionID = @v_SampleCollectionId
                  AND sc.BarcodeNo IS NULL;
            END

            FETCH NEXT FROM barcode_cursor INTO @v_ProfileId, @v_ProfileName, @v_SampleCollectionId;
        END

        CLOSE barcode_cursor;
        DEALLOCATE barcode_cursor;
    END
    -- ─────────────────────────────────────────────────────────────

    SELECT @InsertedCount AS RowsCount;
END
GO
