-- ====================================================================================================
-- Script: 2030_sample_collection_management.sql
-- Description: End-to-end Sample Collection Management schema, statuses, and stored procedures.
-- ====================================================================================================

-- ── 1. Create SampleCollectionStatus Master Table ─────────────────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'SampleCollectionStatus')
BEGIN
    CREATE TABLE dbo.SampleCollectionStatus (
        StatusID     INT IDENTITY(1,1) PRIMARY KEY,
        StatusCode   VARCHAR(30)   NOT NULL UNIQUE,
        StatusName   NVARCHAR(50)  NOT NULL,
        BadgeClass   VARCHAR(30)   NOT NULL DEFAULT 'badge-secondary',
        DisplayOrder INT           NOT NULL DEFAULT 1,
        IsActive     BIT           NOT NULL DEFAULT 1,
        CreatedDate  DATETIME      NOT NULL DEFAULT GETDATE()
    );

    PRINT 'Created dbo.SampleCollectionStatus table.';
END
GO

-- Seed Status Values
IF NOT EXISTS (SELECT 1 FROM dbo.SampleCollectionStatus WHERE StatusCode = 'PENDING')
    INSERT INTO dbo.SampleCollectionStatus (StatusCode, StatusName, BadgeClass, DisplayOrder, IsActive)
    VALUES ('PENDING', 'Pending', 'bg-warning text-dark', 1, 1);

IF NOT EXISTS (SELECT 1 FROM dbo.SampleCollectionStatus WHERE StatusCode = 'COLLECTED')
    INSERT INTO dbo.SampleCollectionStatus (StatusCode, StatusName, BadgeClass, DisplayOrder, IsActive)
    VALUES ('COLLECTED', 'Collected', 'bg-success text-white', 2, 1);

IF NOT EXISTS (SELECT 1 FROM dbo.SampleCollectionStatus WHERE StatusCode = 'RE_COLLECT')
    INSERT INTO dbo.SampleCollectionStatus (StatusCode, StatusName, BadgeClass, DisplayOrder, IsActive)
    VALUES ('RE_COLLECT', 'Re Collect', 'bg-info text-dark', 3, 1);

IF NOT EXISTS (SELECT 1 FROM dbo.SampleCollectionStatus WHERE StatusCode = 'REJECTED')
    INSERT INTO dbo.SampleCollectionStatus (StatusCode, StatusName, BadgeClass, DisplayOrder, IsActive)
    VALUES ('REJECTED', 'Rejected', 'bg-danger text-white', 4, 1);

PRINT 'Seeded dbo.SampleCollectionStatus table.';
GO

-- ── 2. Alter dbo.SampleCollection Table ───────────────────────────────────────
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'SampleCollection' AND COLUMN_NAME = 'CollectionstatusID'
)
BEGIN
    ALTER TABLE dbo.SampleCollection 
    ADD CollectionstatusID INT NULL CONSTRAINT FK_SampleCollection_Status REFERENCES dbo.SampleCollectionStatus(StatusID);
    PRINT 'Added CollectionstatusID to dbo.SampleCollection.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'SampleCollection' AND COLUMN_NAME = 'BarcodeNo'
)
BEGIN
    ALTER TABLE dbo.SampleCollection ADD BarcodeNo NVARCHAR(50) NULL;
    PRINT 'Added BarcodeNo to dbo.SampleCollection.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'SampleCollection' AND COLUMN_NAME = 'ProfilePackageName'
)
BEGIN
    ALTER TABLE dbo.SampleCollection ADD ProfilePackageName NVARCHAR(200) NULL;
    PRINT 'Added ProfilePackageName to dbo.SampleCollection.';
END
GO

-- Set default CollectionstatusID = 1 (Pending) for existing rows where null
UPDATE dbo.SampleCollection
SET CollectionstatusID = 1
WHERE CollectionstatusID IS NULL;
GO

-- Backfill BarcodeNo for existing rows (Investigations sharing same sample type get the same barcode)
UPDATE sc
SET sc.BarcodeNo = 'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2)
FROM dbo.SampleCollection sc
INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
WHERE sc.BarcodeNo IS NULL;
GO

-- Backfill ProfilePackageName for existing rows
-- 1. Direct Packages
UPDATE sc
SET sc.ProfilePackageName = h.Profile_Name
FROM dbo.SampleCollection sc
INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'P'
INNER JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = loi.InvestigationId
INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.Test_ID = sc.InvestigationID
WHERE sc.ProfilePackageName IS NULL;

-- 2. Profiles
UPDATE sc
SET sc.ProfilePackageName = h.Profile_Name
FROM dbo.SampleCollection sc
INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'I'
INNER JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = loi.InvestigationId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = loi.InvestigationId))
INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.Test_ID = sc.InvestigationID
WHERE sc.ProfilePackageName IS NULL;
GO

-- Create index on SampleCollection for fast querying
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SampleCollection_Status_Booking' AND object_id = OBJECT_ID('dbo.SampleCollection'))
BEGIN
    CREATE INDEX IX_SampleCollection_Status_Booking 
    ON dbo.SampleCollection (BranchID, Bookingdatetime, CollectionstatusID);
END
GO

-- ── 3. Stored Procedure: usp_SampleCollection_GetHeaderList ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetHeaderList
    @BranchId        INT,
    @FromDate        DATETIME      = NULL,
    @ToDate          DATETIME      = NULL,
    @DateFilterType  VARCHAR(20)   = 'BookingDate', -- 'BookingDate' or 'OrderDate'
    @StatusFilter    VARCHAR(30)   = 'All',         -- 'All', 'Pending', 'Collected', 'Partial', 'Re Collect', 'Rejected'
    @Search          NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Defaults: Today
    IF @FromDate IS NULL
        SET @FromDate = CAST(CAST(GETDATE() AS DATE) AS DATETIME);
    
    IF @ToDate IS NULL
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));

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

    -- RS1: Summary Counters
    SELECT 
        COUNT(1) AS TotalOrders,
        SUM(CASE WHEN OverallStatus = 'Pending' THEN 1 ELSE 0 END) AS PendingOrders,
        SUM(CASE WHEN OverallStatus = 'Partially Collected' THEN 1 ELSE 0 END) AS PartialOrders,
        SUM(CASE WHEN OverallStatus = 'Collected' THEN 1 ELSE 0 END) AS CollectedOrders
    FROM #FilteredOrders;

    -- RS2: Header Rows
    SELECT *
    FROM #FilteredOrders
    WHERE (
        @StatusFilter IS NULL OR @StatusFilter = '' OR @StatusFilter = 'All'
        OR (@StatusFilter = 'Pending' AND OverallStatus = 'Pending')
        OR (@StatusFilter = 'Collected' AND OverallStatus = 'Collected')
        OR (@StatusFilter = 'Partial' AND OverallStatus = 'Partially Collected')
        OR (@StatusFilter = 'Re Collect' AND OverallStatus = 'Re Collect')
        OR (@StatusFilter = 'Rejected' AND OverallStatus = 'Rejected')
    )
    ORDER BY BookingDateTime DESC, LabOrderId DESC;

    DROP TABLE #FilteredOrders;
END
GO

-- ── 4. Stored Procedure: usp_SampleCollection_GetDetail ───────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Auto-backfill BarcodeNo if missing for this order
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND BarcodeNo IS NULL)
    BEGIN
        UPDATE sc
        SET sc.BarcodeNo = 'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2)
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        WHERE sc.Laborderid = @LabOrderId AND sc.BarcodeNo IS NULL;
    END

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

    -- RS1: Order Header Info
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
        p.EmailId,
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
        ISNULL(sc.ProfilePackageName, '—') AS ProfileOrPackageName,
        lim.Sample_Type_ID AS SampleTypeId,
        ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
        ISNULL(stm.Container_Type, 'Standard Container') AS ContainerType,
        CAST(ISNULL(lim.Is_Fasting_Required, 0) AS BIT) AS IsFastingRequired,
        sc.BarcodeNo,
        ISNULL(sc.CollectionstatusID, 1) AS CollectionstatusID,
        ISNULL(st.StatusName, 'Pending') AS StatusName,
        ISNULL(st.StatusCode, 'PENDING') AS StatusCode,
        ISNULL(st.BadgeClass, 'bg-warning text-dark') AS BadgeClass,
        sc.Samplecollectiondate,
        sc.Samplecollectiontime,
        CASE 
            WHEN sc.Samplecollectiondate IS NOT NULL THEN 
                CONVERT(VARCHAR(10), sc.Samplecollectiondate, 120) + 
                CASE WHEN sc.Samplecollectiontime IS NOT NULL THEN ' ' + CONVERT(VARCHAR(5), sc.Samplecollectiontime, 108) ELSE '' END
            ELSE NULL 
        END AS FormattedCollectionDateTime,
        sc.Iscancelled
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.SampleCollectionStatus st ON st.StatusID = sc.CollectionstatusID
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND sc.Iscancelled = 0
    ORDER BY stm.Sample_Name ASC, lim.Test_Name ASC;
END
GO

-- ── 5. Stored Procedure: usp_SampleCollection_UpdateStatus ────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateStatus
    @SampleCollectionId   BIGINT,
    @CollectionstatusID   INT,
    @SampleCollectionDate DATE          = NULL,
    @SampleCollectionTime TIME(0)       = NULL,
    @UserId               INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE samplecollectionID = @SampleCollectionId)
    BEGIN
        RAISERROR('SampleCollection record with ID %I64d does not exist.', 16, 1, @SampleCollectionId);
        RETURN;
    END

    -- If Collected (StatusID = 2) and date/time not provided, default to current timestamp
    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));
    END

    -- If reverting to Pending (StatusID = 1), clear collection date/time
    IF @CollectionstatusID = 1
    BEGIN
        SET @SampleCollectionDate = NULL;
        SET @SampleCollectionTime = NULL;
    END

    UPDATE dbo.SampleCollection
    SET 
        CollectionstatusID   = @CollectionstatusID,
        Samplecollectiondate = @SampleCollectionDate,
        Samplecollectiontime = @SampleCollectionTime,
        ModifiedBy           = @UserId,
        ModifiedDate         = GETDATE()
    WHERE samplecollectionID = @SampleCollectionId;

    SELECT @@ROWCOUNT AS RowsUpdated;
END
GO

-- ── 6. Stored Procedure: usp_SampleCollection_CollectAll ──────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_CollectAll
    @LabOrderId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentDate DATE    = CAST(GETDATE() AS DATE);
    DECLARE @CurrentTime TIME(0) = CAST(GETDATE() AS TIME(0));

    UPDATE dbo.SampleCollection
    SET 
        CollectionstatusID   = 2, -- Collected
        Samplecollectiondate = ISNULL(Samplecollectiondate, @CurrentDate),
        Samplecollectiontime = ISNULL(Samplecollectiontime, @CurrentTime),
        ModifiedBy           = @UserId,
        ModifiedDate         = GETDATE()
    WHERE Laborderid = @LabOrderId
      AND Is_Active = 1
      AND Iscancelled = 0
      AND (CollectionstatusID IS NULL OR CollectionstatusID = 1 OR CollectionstatusID = 3);

    SELECT @@ROWCOUNT AS RowsUpdated;
END
GO

-- ── 7. Update usp_CreateSampleCollectionFromLabOrder ──────────────────────────
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

        -- Ensure Barcodes are populated
        UPDATE sc
        SET sc.BarcodeNo = 'BC' + RIGHT('00000' + CAST(sc.Laborderid AS NVARCHAR(10)), 5) + '-' + RIGHT('00' + CAST(ISNULL(lim.Sample_Type_ID, 0) AS NVARCHAR(10)), 2)
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        WHERE sc.Laborderid = @LabOrderId AND sc.BarcodeNo IS NULL;

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
        h.Profile_Name + ' > ' + pheader.Profile_Name
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
        NULL
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

    -- Insert into SampleCollection table with Bookingdatetime, BarcodeNo, and CollectionstatusID
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
        CollectionstatusID,
        BarcodeNo,
        ProfilePackageName,
        Iscancelled,
        CreatedBy,
        CreatedDate
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
        1, -- Pending
        'BC' + RIGHT('00000' + CAST(@LabOrderId AS NVARCHAR(10)), 5) + '-' + RIGHT('00' + CAST(ISNULL(ti.SampleTypeId, 0) AS NVARCHAR(10)), 2),
        ti.ProfilePackageName,
        0,
        @CreatedBy,
        GETDATE()
    FROM #TestsToInsert ti;

    DECLARE @InsertedCount INT = @@ROWCOUNT;

    DROP TABLE #TestsToInsert;

    SELECT @InsertedCount AS RowsCount;
END
GO

PRINT '2030_sample_collection_management.sql executed successfully.';
GO
