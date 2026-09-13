-- ═══════════════════════════════════════════════════════════════════════════════
-- Script  : 2060_sample_collection_b2b_display_fixes.sql
-- Purpose : Fix B2B display issues in the Sample Collection page:
--           1. Return actual CollectionType from LabOrder (so "B2BCollector" is
--              surfaced to the UI for correct badge rendering).
--           2. Return PartnerName (from LabFranchiseMaster / CorporateMaster)
--              so the detail panel can display the B2B partner.
--           3. Return PaymentStatus = 'B' (Credit) for B2B orders instead of
--              'U' (Unpaid), since B2B bills are settled via Invoice/Settlement
--              workflow and never have a PaymentHeader row.
-- Affects : dbo.usp_SampleCollection_GetHeaderList
--           dbo.usp_SampleCollection_GetDetail
-- Note    : All logic for B2C / non-B2B orders is completely unchanged.
-- ===============================================================================

-- ── 1. usp_SampleCollection_GetHeaderList ───────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetHeaderList
    @BranchId        INT,
    @FromDate        DATETIME      = NULL,
    @ToDate          DATETIME      = NULL,
    @DateFilterType  VARCHAR(20)   = 'BookingDate',
    @StatusFilter    VARCHAR(50)   = 'All',
    @Search          NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL
        SET @FromDate = CAST(CAST(GETDATE() AS DATE) AS DATETIME);
    
    IF @ToDate IS NULL
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));
    ELSE IF CAST(@ToDate AS TIME) = '00:00:00'
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(@ToDate AS DATE) AS DATETIME));

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
        lo.IsUrgent,
        -- FIX 1: Return exact CollectionType from LabOrder for correct badge rendering
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        -- FIX 3: For B2B orders return 'B' (Credit) as payment is via Invoice/Settlement
        CASE 
            WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B'
            ELSE ISNULL(ph.PaymentStatus, 'U')
        END AS PaymentStatus,
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
        END AS OverallStatus,
        -- FIX 2: B2B partner details
        ISNULL(lo.IsB2B, 0) AS IsB2B,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Franchise_Name
            WHEN lo.AgentType = 'C' THEN corp.Corporate_Name
            ELSE NULL
        END AS PartnerName
    INTO #FilteredOrders
    FROM OrderAggregates agg
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = agg.Laborderid AND lo.IsActive = 1
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT JOIN AggregatedContainers ac ON ac.Laborderid = lo.LabOrderId
    -- B2B partner name JOINs (LEFT JOIN - safe for non-B2B rows, returns NULL)
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
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

    -- RS2: Header Rows (filtered by status)
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

-- ── 2. usp_SampleCollection_GetDetail ───────────────────────────────────────
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

    -- Backfill ProfileId/PackageId if missing (existing logic unchanged)
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

    -- Backfill BarcodeNo if missing (existing logic unchanged)
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

    -- RS1: Order-level header (with B2B fixes for FIX 1, 2, 3)
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
        -- FIX 1: Return exact CollectionType from LabOrder for correct badge rendering
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        -- FIX 3: For B2B orders return 'B' (Credit) as payment is via Invoice/Settlement
        CASE 
            WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B'
            ELSE ISNULL(ph.PaymentStatus, 'U')
        END AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount,
        -- FIX 2: B2B partner details
        ISNULL(lo.IsB2B, 0) AS IsB2B,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Franchise_Name
            WHEN lo.AgentType = 'C' THEN corp.Corporate_Name
            ELSE NULL
        END AS PartnerName
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    -- B2B partner name JOINs (LEFT JOIN - safe for non-B2B rows, returns NULL)
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS2: Individual test/sample items (completely unchanged)
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
