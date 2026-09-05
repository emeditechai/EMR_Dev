-- ==============================================================================
-- Script 2031: Fix Barcode Generation Logic and Status Wise Filtering
-- 1. Barcode only generates after sample is collected (CollectionstatusID = 2)
-- 2. Barcode generation based on Sample Type + Investigation:
--    BC[OrderID 5-digits]-[SampleTypeID 2-digits]-[InvestigationID 4-digits]
-- 3. Fix status-wise filtering in usp_SampleCollection_GetHeaderList
-- ==============================================================================

-- Clean up barcodes from pending / uncollected samples
UPDATE sc
SET sc.BarcodeNo = NULL
FROM dbo.SampleCollection sc
WHERE sc.CollectionstatusID = 1 OR sc.CollectionstatusID IS NULL;

-- Update barcodes for collected samples to the new SampleType + Investigation format
UPDATE sc
SET sc.BarcodeNo = 'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) 
                 + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2)
                 + '-' + RIGHT('0000' + CAST(sc.InvestigationID AS NVARCHAR(10)), 4)
FROM dbo.SampleCollection sc
INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
WHERE sc.CollectionstatusID = 2;
GO

-- ── 1. Stored Procedure: usp_SampleCollection_GetHeaderList ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetHeaderList
    @BranchId        INT,
    @FromDate        DATETIME      = NULL,
    @ToDate          DATETIME      = NULL,
    @DateFilterType  VARCHAR(20)   = 'BookingDate', -- 'BookingDate' or 'OrderDate'
    @StatusFilter    VARCHAR(50)   = 'All',         -- 'All', 'Pending', 'Collected', 'Partial', 'Partially Collected', 'Re Collect', 'Rejected'
    @Search          NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Defaults: Today from 00:00:00 to 23:59:59
    IF @FromDate IS NULL
        SET @FromDate = CAST(CAST(GETDATE() AS DATE) AS DATETIME);
    
    IF @ToDate IS NULL
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));
    ELSE IF CAST(@ToDate AS TIME) = '00:00:00'
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(@ToDate AS DATE) AS DATETIME));

    -- CTE to compute order-level aggregates from SampleCollection
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
        WHERE sc.BranchID = @BranchId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
        GROUP BY sc.Laborderid
    ),
    DistinctContainers AS (
        SELECT DISTINCT
            sc.Laborderid,
            ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS Container_Type
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
        WHERE sc.BranchID = @BranchId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
    ),
    AggregatedContainers AS (
        SELECT 
            dc.Laborderid,
            STRING_AGG(dc.Container_Type, ', ') AS ContainerTypes
        FROM DistinctContainers dc
        GROUP BY dc.Laborderid
    )
    -- Store FilteredOrders in temporary table
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
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
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
        END AS OverallStatus
    INTO #FilteredOrders
    FROM OrderAggregates agg
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = agg.Laborderid AND lo.IsActive = 1
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT JOIN AggregatedContainers ac ON ac.Laborderid = lo.LabOrderId
    WHERE lo.BranchId = @BranchId
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

    -- RS1: Summary Counters (always computed across all orders matching the date/search filter)
    SELECT 
        COUNT(1) AS TotalOrders,
        SUM(CASE WHEN OverallStatus = 'Pending' THEN 1 ELSE 0 END) AS PendingOrders,
        SUM(CASE WHEN OverallStatus = 'Partially Collected' THEN 1 ELSE 0 END) AS PartialOrders,
        SUM(CASE WHEN OverallStatus = 'Collected' THEN 1 ELSE 0 END) AS CollectedOrders
    FROM #FilteredOrders;

    -- RS2: Header Rows (filtered by status if requested)
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
    ORDER BY BookingDateTime DESC, LabOrderId DESC;

    DROP TABLE #FilteredOrders;
END
GO

-- ── 2. Stored Procedure: usp_SampleCollection_GetDetail ───────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Auto-backfill ProfilePackageName if missing
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND ProfilePackageName IS NULL)
    BEGIN
        -- 1. Direct Packages
        UPDATE sc
        SET sc.ProfilePackageName = h.Profile_Name
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'P'
        INNER JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = loi.InvestigationId
        INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.Test_ID = sc.InvestigationID
        WHERE sc.Laborderid = @LabOrderId AND sc.ProfilePackageName IS NULL;

        -- 2. Profiles
        UPDATE sc
        SET sc.ProfilePackageName = h.Profile_Name
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'I'
        INNER JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = loi.InvestigationId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = loi.InvestigationId))
        INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.Test_ID = sc.InvestigationID
        WHERE sc.Laborderid = @LabOrderId AND sc.ProfilePackageName IS NULL;
    END

    -- If any COLLECTED sample is missing BarcodeNo, generate it based on Sample Type + Investigation
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND CollectionstatusID = 2 AND BarcodeNo IS NULL)
    BEGIN
        UPDATE sc
        SET sc.BarcodeNo = 'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) 
                         + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2)
                         + '-' + RIGHT('0000' + CAST(sc.InvestigationID AS NVARCHAR(10)), 4)
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
        sc.ProfilePackageName,
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
        ISNULL(stm.Sample_Name, ''),
        lim.Test_Name;
END
GO

-- ── 3. Stored Procedure: usp_SampleCollection_UpdateStatus ────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateStatus
    @SampleCollectionId BIGINT,
    @CollectionstatusID INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE samplecollectionID = @SampleCollectionId)
    BEGIN
        RAISERROR('SampleCollection record with ID %I64d does not exist.', 16, 1, @SampleCollectionId);
        RETURN;
    END

    -- If Collected (StatusID = 2): generate barcode based on Sample Type + Investigation
    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            BarcodeNo            = ISNULL(sc.BarcodeNo, 'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) 
                                                      + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2) 
                                                      + '-' + RIGHT('0000' + CAST(sc.InvestigationID AS NVARCHAR(10)), 4)),
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        WHERE sc.samplecollectionID = @SampleCollectionId;
    END
    ELSE IF @CollectionstatusID = 1 -- Revert to Pending: clear collection date, time, and BarcodeNo
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = 1,
            Samplecollectiondate = NULL,
            Samplecollectiontime = NULL,
            BarcodeNo            = NULL, -- Barcode removed when pending!
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

-- ── 4. Stored Procedure: usp_SampleCollection_CollectAll ──────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_CollectAll
    @LabOrderId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentDate DATE    = CAST(GETDATE() AS DATE);
    DECLARE @CurrentTime TIME(0) = CAST(GETDATE() AS TIME(0));

    -- Mark pending / re-collect as Collected and generate Barcode based on Sample Type + Investigation
    UPDATE sc
    SET 
        CollectionstatusID   = 2, -- Collected
        Samplecollectiondate = ISNULL(sc.Samplecollectiondate, @CurrentDate),
        Samplecollectiontime = ISNULL(sc.Samplecollectiontime, @CurrentTime),
        BarcodeNo            = ISNULL(sc.BarcodeNo, 'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) 
                                                  + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2) 
                                                  + '-' + RIGHT('0000' + CAST(sc.InvestigationID AS NVARCHAR(10)), 4)),
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

-- ── 5. Stored Procedure: usp_CreateSampleCollectionFromLabOrder ───────────────
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
        ProfilePackageName NVARCHAR(200)
    );

    -- 1A. Packages (Type = 'P'): Direct tests under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfilePackageName)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
        t.Sample_Type_ID,
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
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfilePackageName)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
        t.Sample_Type_ID,
        h.Profile_Name
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
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfilePackageName)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
        t.Sample_Type_ID,
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
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfilePackageName)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
        t.Sample_Type_ID,
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

    -- Insert into SampleCollection table with Bookingdatetime, CollectionstatusID = 1 (Pending), BarcodeNo = NULL
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
        1,   -- 1 = Pending
        NULL -- Barcode only generated AFTER collection!
    FROM #TestsToInsert ti;

    DECLARE @InsertedCount INT = @@ROWCOUNT;

    DROP TABLE #TestsToInsert;

    SELECT @InsertedCount AS RowsCount;
END
GO
