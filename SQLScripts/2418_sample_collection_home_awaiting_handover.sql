-- ============================================================================================================
-- 2418  Sample Collection screen, Home Collection with Hospital Settings > "Is Phlebotomist App Required" = Yes
--       (after 2417): until the app marks the visit HANDED OVER, the tubes the phlebotomist collected are NOT shown as
--       collected here - the order counts as Pending ("N with phlebotomist") and each tube shows "With phlebotomist".
--       Display only: SampleCollection is not changed; Lab orders, B2B and branches without the app are as before.
--       Collecting at this desk stays blocked by fn_LabHomeCollectionHold (2390). Re-runnable.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetHeaderList
    @BranchId        INT,
    @FromDate        DATETIME      = NULL,
    @ToDate          DATETIME      = NULL,
    @DateFilterType  VARCHAR(20)   = 'BookingDate',
    @StatusFilter    VARCHAR(50)   = 'All',
    @Search          NVARCHAR(100) = NULL,
    -- 2266: a franchise login (its user id): only the orders it created or that are for its franchise; NULL = all
    @CreatedBy       INT           = NULL,
    -- 2390: 'Lab' / 'Home Collection'; NULL or 'All' = every order
    @CollectionType  VARCHAR(30)   = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL
        SET @FromDate = CAST(CAST(GETDATE() AS DATE) AS DATETIME);
    
    IF @ToDate IS NULL
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));
    ELSE IF CAST(@ToDate AS TIME) = '00:00:00'
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(@ToDate AS DATE) AS DATETIME));

    -- Only count tests where Is_Sample_Collection_Required = 1 (YES)
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
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
        WHERE sc.BranchID = @BranchId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND ISNULL(cat.Is_Sample_Collection_Required, 1) = 1
        GROUP BY sc.Laborderid
    ),
    DistinctContainers AS (
        SELECT DISTINCT
            sc.Laborderid,
            ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS Container_Type
        FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
        LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
        WHERE sc.BranchID = @BranchId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND ISNULL(cat.Is_Sample_Collection_Required, 1) = 1
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
        -- urgent when the order or any of its tests is marked urgent
        CAST(CASE WHEN ISNULL(lo.IsUrgent, 0) = 1
                    OR EXISTS (SELECT 1 FROM dbo.LabOrderItem uli WHERE uli.LabOrderId = lo.LabOrderId AND uli.IsUrgent = 1)
                  THEN 1 ELSE 0 END AS BIT) AS IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        hv.Status AS HomeVisitStatus,                                   -- 2390: latest home visit
        CAST(CASE WHEN hold.Msg IS NULL THEN 1 ELSE 0 END AS BIT) AS CanCollect,
        -- 2418: Home Collection with the Phlebotomist App - tubes the app collected are not collected here until handed over
        CASE WHEN hold.Msg IS NOT NULL THEN agg.CollectedCount ELSE 0 END AS WithPhlebotomistCount,
        CASE 
            WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B'
            ELSE ISNULL(ph.PaymentStatus, 'U')
        END AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount,
        ISNULL(ac.ContainerTypes, '—') AS ContainerTypes,
        agg.TotalTests,
        CASE WHEN hold.Msg IS NOT NULL THEN 0 ELSE agg.CollectedCount END AS CollectedCount,
        CASE WHEN hold.Msg IS NOT NULL THEN agg.PendingCount + agg.CollectedCount ELSE agg.PendingCount END AS PendingCount,
        agg.ReCollectCount,
        agg.RejectedCount,
        CASE 
            WHEN hold.Msg IS NOT NULL AND agg.CollectedCount > 0 THEN 'Pending'
            WHEN agg.CollectedCount = agg.TotalTests AND agg.TotalTests > 0 THEN 'Collected'
            WHEN agg.CollectedCount > 0 AND agg.CollectedCount < agg.TotalTests THEN 'Partially Collected'
            WHEN agg.ReCollectCount > 0 THEN 'Re Collect'
            WHEN agg.RejectedCount = agg.TotalTests AND agg.TotalTests > 0 THEN 'Rejected'
            ELSE 'Pending'
        END AS OverallStatus,
        ISNULL(lo.IsB2B, 0) AS IsB2B,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Franchise_Name
            WHEN lo.AgentType = 'C' THEN corp.Corporate_Name
            ELSE NULL
        END AS PartnerName
    INTO #FilteredOrders
    FROM OrderAggregates agg
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = agg.Laborderid AND lo.IsActive = 1 AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy OR (lo.AgentType = 'F' AND lo.B2BAgentID = (SELECT fu.ReferenceUserID FROM dbo.Users fu WHERE fu.Id = @CreatedBy AND fu.User_Type = 'F')))
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT JOIN AggregatedContainers ac ON ac.Laborderid = lo.LabOrderId
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    OUTER APPLY (SELECT TOP 1 v.Status FROM dbo.LabHomeVisit v WHERE v.LabOrderId = lo.LabOrderId ORDER BY v.VisitId DESC) hv
    OUTER APPLY (SELECT dbo.fn_LabHomeCollectionHold(lo.LabOrderId) AS Msg) hold
    WHERE lo.BranchId = @BranchId
      AND (NULLIF(NULLIF(@CollectionType, ''), 'All') IS NULL
           OR (@CollectionType = 'Home Collection' AND ISNULL(lo.CollectionType, '') = 'Home Collection')
           OR (@CollectionType <> 'Home Collection' AND ISNULL(lo.CollectionType, '') <> 'Home Collection'))
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
    ORDER BY IsUrgent DESC, BookingDateTime DESC, LabOrderId DESC;   -- urgent orders always on top

    DROP TABLE #FilteredOrders;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
        RETURN;

    -- Heal missing ProfileId / PackageId for legacy rows
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND (ProfileId IS NULL OR PackageId IS NULL))
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

    -- Backfill BarcodeNo if missing (ONLY for tests requiring barcodes!)
    IF EXISTS (
        SELECT 1 FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
        WHERE sc.Laborderid = @LabOrderId 
          AND sc.CollectionstatusID = 2 
          AND sc.BarcodeNo IS NULL
          AND ISNULL(cat.Is_Barcode_Required, 1) = 1
    )
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
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId 
              AND sc.CollectionstatusID = 2 
              AND sc.BarcodeNo IS NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1
              AND (sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL);

        OPEN missing_prof;
        FETCH NEXT FROM missing_prof INTO @MissingProfId, @MissingProfName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @MBarcode NVARCHAR(50) = NULL;
            SELECT TOP 1 @MBarcode = sc.BarcodeNo
            FROM dbo.SampleCollection sc
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId
              AND (
                  (@MissingProfId IS NOT NULL AND sc.ProfileId = @MissingProfId)
                  OR (@MissingProfId IS NULL AND @MissingProfName IS NOT NULL AND sc.ProfileName = @MissingProfName)
              )
              AND sc.BarcodeNo IS NOT NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1;

            IF @MBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @MBarcode OUTPUT;
            END

            UPDATE sc
            SET sc.BarcodeNo = @MBarcode
            FROM dbo.SampleCollection sc
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId 
              AND sc.CollectionstatusID = 2 
              AND sc.BarcodeNo IS NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1
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
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId 
              AND sc.CollectionstatusID = 2 
              AND sc.BarcodeNo IS NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1;

        OPEN missing_item;
        FETCH NEXT FROM missing_item INTO @MissingItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @MItemBarcode NVARCHAR(50) = NULL;
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @MItemBarcode OUTPUT;

            UPDATE sc
            SET sc.BarcodeNo = @MItemBarcode
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @MissingItemId;

            FETCH NEXT FROM missing_item INTO @MissingItemId;
        END
        CLOSE missing_item;
        DEALLOCATE missing_item;
    END

    -- RS1: Order-level header
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
        CASE WHEN lo.CreatedDate < ISNULL(lo.BookingDate, lo.OrderDate) THEN lo.CreatedDate ELSE ISNULL(lo.BookingDate, lo.OrderDate) END AS EarliestCollectionOn,   -- 2203: the earliest collection time allowed
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        (SELECT TOP 1 v.Status FROM dbo.LabHomeVisit v WHERE v.LabOrderId = lo.LabOrderId ORDER BY v.VisitId DESC) AS HomeVisitStatus,   -- 2390
        dbo.fn_LabHomeCollectionHold(lo.LabOrderId) AS CollectionHoldReason,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        CASE 
            WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B'
            ELSE ISNULL(ph.PaymentStatus, 'U')
        END AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount,
        ISNULL(lo.IsB2B, 0) AS IsB2B,
        lo.AgentType,
        lo.B2BAgentID AS B2BAgentId,
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
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE lo.LabOrderId = @LabOrderId;

    -- 2418: Home Collection with the Phlebotomist App, not handed over yet - a tube the app collected shows as with the
    -- phlebotomist (not collected) on this screen; the data itself is not changed
    DECLARE @HeldByPhlebo BIT = CASE WHEN dbo.fn_LabHomeCollectionHold(@LabOrderId) IS NULL THEN 0 ELSE 1 END;

    -- RS2: Individual test/sample items
    -- EXCLUDES tests where Is_Sample_Collection_Required = 0 (e.g. Radiology)!
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
        ISNULL(sc.RequiresManualBarcode, 0) AS RequiresManualBarcode,
        CASE WHEN @HeldByPhlebo = 1 AND sc.CollectionstatusID = 2 THEN 1 ELSE ISNULL(sc.CollectionstatusID, 1) END AS CollectionstatusID,
        CASE WHEN @HeldByPhlebo = 1 AND sc.CollectionstatusID = 2 THEN N'With phlebotomist' ELSE ISNULL(cs.StatusName, 'Pending') END AS StatusName,
        CAST(CASE WHEN @HeldByPhlebo = 1 AND sc.CollectionstatusID = 2 THEN 1 ELSE 0 END AS BIT) AS AwaitingHandover,
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
        u.FullName AS CollectedByName,
        sc.RejectionReasonId,
        sc.RejectionReason
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.SampleCollectionStatus cs ON cs.StatusID = sc.CollectionstatusID
    LEFT JOIN dbo.Users u ON u.Id = sc.ModifiedBy
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND sc.Iscancelled = 0
      AND ISNULL(cat.Is_Sample_Collection_Required, 1) = 1
    ORDER BY 
        COALESCE(sc.ProfileName, sc.PackageName, 'ZZZ'),
        ISNULL(stm.Sample_Name, ''),
        lim.Test_Name;
END
GO
PRINT 'Script 2418 applied: Sample Collection shows home-collection tubes with the phlebotomist until handed over.';
GO
