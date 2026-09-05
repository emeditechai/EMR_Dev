-- ==============================================================================
-- Script 2032: Standardized Profile-wise & Investigation-wise Barcode Generation
-- and Move Containers from Header part to Details based on Investigation
-- ==============================================================================

-- 1. Add ProfileId, ProfileName, PackageId, PackageName to dbo.SampleCollection
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'SampleCollection' AND COLUMN_NAME = 'ProfileId')
BEGIN
    ALTER TABLE dbo.SampleCollection ADD ProfileId INT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'SampleCollection' AND COLUMN_NAME = 'ProfileName')
BEGIN
    ALTER TABLE dbo.SampleCollection ADD ProfileName NVARCHAR(200) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'SampleCollection' AND COLUMN_NAME = 'PackageId')
BEGIN
    ALTER TABLE dbo.SampleCollection ADD PackageId INT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'SampleCollection' AND COLUMN_NAME = 'PackageName')
BEGIN
    ALTER TABLE dbo.SampleCollection ADD PackageName NVARCHAR(200) NULL;
END
GO

-- 2. Backfill ProfileId, ProfileName, PackageId, PackageName for existing records
-- A) Direct Packages (loi.Type = 'P' where h.Profile_Type = 2)
-- A1: Child profiles inside packages
UPDATE sc
SET 
    sc.PackageId   = pkg.Profile_ID,
    sc.PackageName = pkg.Profile_Name,
    sc.ProfileId   = ch.Profile_ID,
    sc.ProfileName = ch.Profile_Name
FROM dbo.SampleCollection sc
INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'P'
INNER JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId
INNER JOIN dbo.LabInvestigationProfileDetail pkg_d ON pkg_d.Profile_ID = pkg.Profile_ID
INNER JOIN dbo.LabInvestigationMaster pt ON pt.Test_ID = pkg_d.Test_ID AND pt.Is_Profile_Test = 1
INNER JOIN dbo.LabInvestigationProfileHeader ch ON (ch.Test_ID = pt.Test_ID OR ch.Profile_Name = pt.Test_Name)
INNER JOIN dbo.LabInvestigationProfileDetail ch_d ON ch_d.Profile_ID = ch.Profile_ID AND ch_d.Test_ID = sc.InvestigationID;
GO

-- A2: Direct standalone tests inside packages
UPDATE sc
SET 
    sc.PackageId   = pkg.Profile_ID,
    sc.PackageName = pkg.Profile_Name,
    sc.ProfileId   = NULL,
    sc.ProfileName = NULL
FROM dbo.SampleCollection sc
INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'P'
INNER JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId
INNER JOIN dbo.LabInvestigationProfileDetail pkg_d ON pkg_d.Profile_ID = pkg.Profile_ID AND pkg_d.Test_ID = sc.InvestigationID
INNER JOIN dbo.LabInvestigationMaster t ON t.Test_ID = pkg_d.Test_ID AND t.Is_Profile_Test = 0
WHERE sc.PackageId IS NULL;
GO

-- B) Direct Profiles (loi.Type = 'I' AND lim.Is_Profile_Test = 1)
UPDATE sc
SET 
    sc.ProfileId   = h.Profile_ID,
    sc.ProfileName = h.Profile_Name,
    sc.PackageId   = NULL,
    sc.PackageName = NULL
FROM dbo.SampleCollection sc
INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'I'
INNER JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = loi.InvestigationId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = loi.InvestigationId))
INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.Test_ID = sc.InvestigationID
WHERE sc.ProfileId IS NULL;
GO

-- C) Also sync sc.ProfilePackageName for backward compatibility
UPDATE sc
SET sc.ProfilePackageName = COALESCE(sc.ProfileName, sc.PackageName, '—')
FROM dbo.SampleCollection sc
WHERE sc.ProfilePackageName IS NULL OR sc.ProfilePackageName = '';
GO

-- 3. Update Barcodes for all collected samples based on new standard:
-- - Profile-wise: If ProfileId IS NOT NULL -> same barcode for same LabOrderId + SampleTypeId + ProfileId
-- - Investigation-wise: If ProfileId IS NULL -> separate barcode for same LabOrderId + SampleTypeId + InvestigationId
UPDATE sc
SET sc.BarcodeNo = CASE 
    WHEN sc.ProfileId IS NOT NULL THEN
        'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) 
             + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2) 
             + '-P' + RIGHT('000' + CAST(sc.ProfileId AS NVARCHAR(10)), 3)
    ELSE
        'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) 
             + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2) 
             + '-' + RIGHT('0000' + CAST(sc.InvestigationID AS NVARCHAR(10)), 4)
END
FROM dbo.SampleCollection sc
INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
WHERE sc.CollectionstatusID = 2;
GO

-- ── 4. Stored Procedure: usp_CreateSampleCollectionFromLabOrder ───────────────
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

    SELECT @InsertedCount AS RowsCount;
END
GO

-- ── 5. Stored Procedure: usp_SampleCollection_GetDetail ───────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Auto-backfill ProfileId / PackageId if missing
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND ProfileId IS NULL AND PackageId IS NULL AND ProfilePackageName IS NOT NULL AND ProfilePackageName <> '—')
    BEGIN
        -- Profiles
        UPDATE sc
        SET 
            sc.ProfileId   = h.Profile_ID,
            sc.ProfileName = h.Profile_Name
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'I'
        INNER JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = loi.InvestigationId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = loi.InvestigationId))
        INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.Test_ID = sc.InvestigationID
        WHERE sc.Laborderid = @LabOrderId AND sc.ProfileId IS NULL;

        -- Packages
        UPDATE sc
        SET 
            sc.PackageId   = h.Profile_ID,
            sc.PackageName = h.Profile_Name
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'P'
        INNER JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = loi.InvestigationId
        WHERE sc.Laborderid = @LabOrderId AND sc.PackageId IS NULL;
    END

    -- If any COLLECTED sample is missing BarcodeNo, generate it based on Profile-wise or Investigation-wise standard
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND CollectionstatusID = 2 AND BarcodeNo IS NULL)
    BEGIN
        UPDATE sc
        SET sc.BarcodeNo = CASE 
            WHEN sc.ProfileId IS NOT NULL THEN
                'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) 
                     + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2) 
                     + '-P' + RIGHT('000' + CAST(sc.ProfileId AS NVARCHAR(10)), 3)
            ELSE
                'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) 
                     + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2) 
                     + '-' + RIGHT('0000' + CAST(sc.InvestigationID AS NVARCHAR(10)), 4)
        END
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        WHERE sc.Laborderid = @LabOrderId AND sc.CollectionstatusID = 2 AND sc.BarcodeNo IS NULL;
    END

    -- RS1: Order Header Summary
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
        p.Address,
        lo.OrderDate,
        lo.BookingDate AS BookingDateTime,
        lo.BillNo,
        lo.TokenNo,
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

    -- RS2: Investigation Line Items with Barcode, Container, and Collection Status
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

-- ── 6. Stored Procedure: usp_SampleCollection_UpdateStatus ────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateStatus
    @SampleCollectionId BIGINT,
    @CollectionstatusID INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LabOrderId INT;
    DECLARE @ProfileId INT;
    DECLARE @SampleTypeId INT;
    DECLARE @GeneratedBarcode NVARCHAR(50);

    SELECT 
        @LabOrderId    = sc.Laborderid,
        @ProfileId     = sc.ProfileId,
        @SampleTypeId  = lim.Sample_Type_ID
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    WHERE sc.samplecollectionID = @SampleCollectionId;

    IF @LabOrderId IS NULL
    BEGIN
        RAISERROR('SampleCollection record with ID %I64d does not exist.', 16, 1, @SampleCollectionId);
        RETURN;
    END

    -- If Collected (StatusID = 2): generate barcode based on Profile-wise or Investigation-wise standard
    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        IF @ProfileId IS NOT NULL
        BEGIN
            -- Profile-wise: Check if any sibling test in the same profile + sample type already has a barcode
            SELECT TOP 1 @GeneratedBarcode = BarcodeNo 
            FROM dbo.SampleCollection 
            WHERE Laborderid = @LabOrderId 
              AND ProfileId = @ProfileId 
              AND BarcodeNo IS NOT NULL;

            IF @GeneratedBarcode IS NULL
            BEGIN
                SET @GeneratedBarcode = 'BC' + RIGHT('00000' + CAST(@LabOrderId AS NVARCHAR(10)), 5) 
                                      + '-' + RIGHT('00' + CAST(ISNULL(@SampleTypeId, 0) AS NVARCHAR(10)), 2) 
                                      + '-P' + RIGHT('000' + CAST(@ProfileId AS NVARCHAR(10)), 3);
            END

            -- Update current test
            UPDATE sc
            SET 
                CollectionstatusID   = 2,
                Samplecollectiondate = @SampleCollectionDate,
                Samplecollectiontime = @SampleCollectionTime,
                BarcodeNo            = @GeneratedBarcode,
                ModifiedBy           = @UserId,
                ModifiedDate         = GETDATE()
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @SampleCollectionId;
        END
        ELSE
        BEGIN
            -- Standalone investigation-wise
            SET @GeneratedBarcode = 'BC' + RIGHT('00000' + CAST(@LabOrderId AS NVARCHAR(10)), 5) 
                                  + '-' + RIGHT('00' + CAST(ISNULL(@SampleTypeId, 0) AS NVARCHAR(10)), 2) 
                                  + '-' + RIGHT('0000' + CAST((SELECT InvestigationID FROM dbo.SampleCollection WHERE samplecollectionID = @SampleCollectionId) AS NVARCHAR(10)), 4);

            UPDATE sc
            SET 
                CollectionstatusID   = 2,
                Samplecollectiondate = @SampleCollectionDate,
                Samplecollectiontime = @SampleCollectionTime,
                BarcodeNo            = @GeneratedBarcode,
                ModifiedBy           = @UserId,
                ModifiedDate         = GETDATE()
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @SampleCollectionId;
        END
    END
    ELSE IF @CollectionstatusID = 1 -- Revert to Pending: clear collection date, time, and BarcodeNo
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = 1,
            Samplecollectiondate = NULL,
            Samplecollectiontime = NULL,
            BarcodeNo            = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @SampleCollectionId;
    END
    ELSE -- Other statuses (Re Collect = 3, Rejected = 4)
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

    SELECT @@ROWCOUNT AS RowsUpdated;
END
GO

-- ── 7. Stored Procedure: usp_SampleCollection_CollectAll ──────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_CollectAll
    @LabOrderId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentDate DATE    = CAST(GETDATE() AS DATE);
    DECLARE @CurrentTime TIME(0) = CAST(GETDATE() AS TIME(0));

    -- Mark pending / re-collect as Collected and generate Barcodes adhering to Profile/Investigation standards
    UPDATE sc
    SET 
        CollectionstatusID   = 2, -- Collected
        Samplecollectiondate = ISNULL(sc.Samplecollectiondate, @CurrentDate),
        Samplecollectiontime = ISNULL(sc.Samplecollectiontime, @CurrentTime),
        BarcodeNo            = ISNULL(sc.BarcodeNo, 
                                CASE 
                                    WHEN sc.ProfileId IS NOT NULL THEN
                                        'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) 
                                             + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2) 
                                             + '-P' + RIGHT('000' + CAST(sc.ProfileId AS NVARCHAR(10)), 3)
                                    ELSE
                                        'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) 
                                             + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2) 
                                             + '-' + RIGHT('0000' + CAST(sc.InvestigationID AS NVARCHAR(10)), 4)
                                END),
        ModifiedBy           = @UserId,
        ModifiedDate         = GETDATE()
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND sc.Iscancelled = 0
      AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID = 1 OR sc.CollectionstatusID = 3);

    SELECT @@ROWCOUNT AS RowsUpdated;
END
GO
