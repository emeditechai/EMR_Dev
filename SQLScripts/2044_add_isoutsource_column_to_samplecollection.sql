-- Migration 2044: Add IsoutSource column to SampleCollection and store value based on Investigation

-- ── 1. Add IsoutSource column to dbo.SampleCollection table ───────────────
IF NOT EXISTS (
    SELECT 1 
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'SampleCollection' AND COLUMN_NAME = 'IsoutSource'
)
BEGIN
    ALTER TABLE dbo.SampleCollection ADD IsoutSource BIT NOT NULL CONSTRAINT DF_SampleCollection_IsoutSource DEFAULT 0;
    PRINT 'Added IsoutSource column to dbo.SampleCollection table.';
END
ELSE
BEGIN
    PRINT 'IsoutSource column already exists in dbo.SampleCollection table.';
END
GO

-- ── 2. Backfill existing records in SampleCollection ──────────────────────
UPDATE sc
SET sc.IsoutSource = ISNULL(lim.Is_Outsourced, 0)
FROM dbo.SampleCollection sc
INNER JOIN dbo.LabInvestigationMaster lim ON sc.InvestigationID = lim.Test_ID;
PRINT 'Backfilled IsoutSource in dbo.SampleCollection based on LabInvestigationMaster.Is_Outsourced.';
GO

-- ── 3. Update dbo.usp_CreateSampleCollectionFromLabOrder to store IsoutSource ─
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
        ProfilePackageName NVARCHAR(200),
        IsoutSource        BIT
    );

    -- 1A. Packages (Type = 'P'): Direct standalone tests under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource)
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
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT)
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
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource)
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
        pheader.Profile_Name,
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT)
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
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource)
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
        h.Profile_Name,
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT)
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
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource)
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
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT)
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
        NULL, -- Barcode only generated AFTER collection!
        ti.IsoutSource
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

-- ── 4. Update dbo.usp_SampleCollection_GetDetail to read IsoutSource ────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND ProfileId IS NULL AND PackageId IS NULL AND ProfilePackageName IS NOT NULL AND ProfilePackageName <> '—')
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

    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND CollectionstatusID = 2 AND BarcodeNo IS NULL)
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
            WHERE sc.Laborderid = @LabOrderId AND sc.CollectionstatusID = 2 AND sc.BarcodeNo IS NULL
              AND (sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL);

        OPEN missing_prof;
        FETCH NEXT FROM missing_prof INTO @MissingProfId, @MissingProfName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @MBarcode NVARCHAR(50) = NULL;
            SELECT TOP 1 @MBarcode = BarcodeNo
            FROM dbo.SampleCollection
            WHERE Laborderid = @LabOrderId
              AND (
                  (@MissingProfId IS NOT NULL AND ProfileId = @MissingProfId)
                  OR (@MissingProfId IS NULL AND @MissingProfName IS NOT NULL AND ProfileName = @MissingProfName)
              )
              AND BarcodeNo IS NOT NULL;

            IF @MBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @MBarcode OUTPUT;
            END

            UPDATE sc
            SET BarcodeNo = @MBarcode
            FROM dbo.SampleCollection sc
            WHERE sc.Laborderid = @LabOrderId AND sc.CollectionstatusID = 2 AND sc.BarcodeNo IS NULL
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
            WHERE sc.Laborderid = @LabOrderId AND sc.CollectionstatusID = 2 AND sc.BarcodeNo IS NULL
              AND sc.ProfileId IS NULL AND sc.ProfileName IS NULL;

        OPEN missing_item;
        FETCH NEXT FROM missing_item INTO @MissingItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @MItemBarcode NVARCHAR(50) = NULL;
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @MItemBarcode OUTPUT;

            UPDATE sc
            SET BarcodeNo = @MItemBarcode
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @MissingItemId;

            FETCH NEXT FROM missing_item INTO @MissingItemId;
        END
        CLOSE missing_item;
        DEALLOCATE missing_item;
    END

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
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.LabOrderId = @LabOrderId;

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
        u.FullName AS CollectedByName
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.SampleCollectionStatus cs ON cs.StatusID = sc.CollectionstatusID
    LEFT JOIN dbo.Users u ON u.Id = sc.ModifiedBy
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND sc.Iscancelled = 0
    ORDER BY 
        COALESCE(sc.ProfileName, sc.PackageName, 'ZZZ'),
        ISNULL(stm.Sample_Name, ''),
        lim.Test_Name;
END
GO
