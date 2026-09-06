USE [Dev_EMR]
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('LabOrder') AND name = 'IsUrgent')
BEGIN
    ALTER TABLE dbo.LabOrder ADD IsUrgent BIT NOT NULL DEFAULT 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('LabOrderItem') AND name = 'IsUrgent')
BEGIN
    ALTER TABLE dbo.LabOrderItem ADD IsUrgent BIT NOT NULL DEFAULT 0;
END
GO

-- We need to DROP the SP before dropping the type
IF OBJECT_ID('dbo.usp_CreateLabOrder', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE dbo.usp_CreateLabOrder;
END
GO

-- Re-create udt_LabOrderItem
IF TYPE_ID('dbo.udt_LabOrderItem') IS NOT NULL
BEGIN
    DROP TYPE dbo.udt_LabOrderItem;
END
GO

CREATE TYPE dbo.udt_LabOrderItem AS TABLE(
	[InvestigationId] [int] NOT NULL,
	[Type] [char](1) NULL,
	[Price] [decimal](18, 2) NOT NULL,
	[IsUrgent] [bit] NOT NULL DEFAULT 0
)
GO

-- Recreate usp_CreateLabOrder
CREATE PROCEDURE dbo.usp_CreateLabOrder
    @PatientId        INT,
    @BranchId         INT,
    @CreatedBy        INT,
    @TotalAmount      DECIMAL(10,2),
    @Items            dbo.udt_LabOrderItem READONLY,
    @CollectionType   NVARCHAR(50) = 'Lab',
    @PhlebotomistId   INT          = NULL,
    @BookingDate      DATETIME     = NULL,
    @LabOrderId       INT          OUTPUT,
    @BillNo           NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;
        
        DECLARE @IsUrgent BIT = 0;
        IF EXISTS (SELECT 1 FROM @Items WHERE IsUrgent = 1)
        BEGIN
            SET @IsUrgent = 1;
        END

        -- Insert Header
        INSERT INTO dbo.LabOrder 
            (PatientId, BranchId, OrderDate, BillNo, TotalAmount,
             CollectionType, PhlebotomistId, BookingDate, IsUrgent,
             CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@PatientId, @BranchId, GETDATE(), @BillNo, @TotalAmount,
             ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @BookingDate, @IsUrgent,
             @CreatedBy, GETDATE(), 1);
        
        SET @LabOrderId = SCOPE_IDENTITY();

        -- Insert Items
        INSERT INTO dbo.LabOrderItem (LabOrderId, InvestigationId, Type,
                                      Price, IsUrgent, CreatedBy, CreatedDate, IsActive)
        SELECT @LabOrderId, InvestigationId, ISNULL(Type, 'I'), Price, IsUrgent, @CreatedBy, GETDATE(), 1
        FROM @Items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ─────────────────────────────────────────────────────────────
-- Update usp_LabOrder_GetPagedList
-- ─────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetPagedList
    @BranchId INT,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @Search NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL SET @FromDate = CAST(GETDATE() AS DATE);
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize < 1 SET @PageSize = 10;

    -- Stats
    SELECT 
        COUNT(1) AS TotalOrders,
        ISNULL(SUM(o.TotalAmount), 0.00) AS TotalAmount,
        ISNULL(SUM(CASE WHEN ph.PaymentStatus = 'P' THEN 1 ELSE 0 END), 0) AS PaidCount,
        ISNULL(SUM(CASE WHEN ISNULL(ph.PaymentStatus, 'U') = 'U' THEN 1 ELSE 0 END), 0) AS UnpaidCount
    FROM dbo.LabOrder o
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
      AND (
          @Search IS NULL 
          OR o.BillNo LIKE '%' + @Search + '%' 
          OR o.TokenNo LIKE '%' + @Search + '%'
          OR EXISTS (
              SELECT 1 FROM dbo.PatientMaster p 
              WHERE p.PatientId = o.PatientId 
                AND (p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%' OR p.PatientCode LIKE '%' + @Search + '%')
          )
      );

    -- Paged Items
    WITH PagedOrders AS (
        SELECT 
            o.LabOrderId,
            o.PatientId,
            o.BranchId,
            o.OrderDate,
            o.BillNo,
            o.TokenNo,
            o.TotalAmount,
            o.CollectionType,
            o.PhlebotomistId,
            o.IsUrgent,
            phleb.FullName AS PhlebotomistName,
            o.BookingDate,
            o.IsActive,
            o.CreatedDate,
            o.CreatedBy,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.MiddleName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.DateOfBirth,
            CASE 
                WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                ELSE NULL 
            END AS Age,
            ph.PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
            ISNULL(ph.BalanceDue, o.TotalAmount) AS BalanceDue,
            u.FullName AS CreatedByName,
            (
                SELECT COUNT(1) 
                FROM dbo.LabOrderItem loi 
                WHERE loi.LabOrderId = o.LabOrderId
            ) AS ItemCount,
            (
                SELECT STRING_AGG(lim.Test_Name, ', ')
                FROM dbo.LabOrderItem loi
                INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId
                WHERE loi.LabOrderId = o.LabOrderId
            ) AS TestNamesSummary,
            ROW_NUMBER() OVER (ORDER BY o.LabOrderId DESC) AS RowNum,
            COUNT(1) OVER() AS TotalCount
        FROM dbo.LabOrder o
        INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
        LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
        LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
        WHERE o.BranchId = @BranchId
          AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
          AND (
              @Search IS NULL 
              OR o.BillNo LIKE '%' + @Search + '%' 
              OR o.TokenNo LIKE '%' + @Search + '%'
              OR p.FirstName LIKE '%' + @Search + '%'
              OR p.LastName LIKE '%' + @Search + '%'
              OR p.PhoneNumber LIKE '%' + @Search + '%'
              OR p.PatientCode LIKE '%' + @Search + '%'
          )
    )
    SELECT * FROM PagedOrders
    WHERE RowNum BETWEEN ((@PageNumber - 1) * @PageSize + 1) AND (@PageNumber * @PageSize)
    ORDER BY RowNum;
END;
GO

-- ─────────────────────────────────────────────────────────────
-- Update usp_LabOrder_GetDetail
-- ─────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetDetail
(
    @LabOrderId INT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    SELECT 
        o.LabOrderId,
        o.PatientId,
        o.BranchId,
        b.BranchName,
        o.OrderDate,
        o.BillNo,
        o.TokenNo,
        o.TotalAmount,
        o.CollectionType,
        o.PhlebotomistId,
        o.IsUrgent,
        phleb.FullName AS PhlebotomistName,
        o.BookingDate,
        o.IsActive,
        o.CreatedDate,
        u.FullName AS CreatedByName,
        p.PatientCode,
        (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
        p.PhoneNumber,
        p.EmailId,
        p.Gender,
        p.DateOfBirth,
        DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
            CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END AS Age,
        p.Address,
        ph.PaymentHeaderId,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0)       AS TotalPaid,
        ISNULL(ph.BalanceDue, o.TotalAmount) AS BalanceDue,
        ISNULL(ph.NetAmount, o.TotalAmount)  AS NetAmount,
        ISNULL(ph.HeaderDiscountAmount, 0)   AS DiscountAmount,
        ISNULL(ph.RoundOffAmount, 0)         AS RoundOffAmount
    FROM dbo.LabOrder o
    INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
    LEFT JOIN dbo.BranchMaster b ON b.BranchID = o.BranchId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
    LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
    WHERE o.LabOrderId = @LabOrderId;

    SELECT 
        loi.LabOrderItemId,
        loi.LabOrderId,
        loi.InvestigationId,
        ISNULL(lim.Test_Code, pkg.Profile_Code) AS TestCode,
        ISNULL(lim.Test_Name, pkg.Profile_Name) AS TestName,
        stm.Sample_Name AS SampleType,
        ISNULL(lim.TAT_Hours, pkg.Profile_TAT_Hours) AS TATHours,
        dm.DeptName AS DepartmentName,
        cm.Category_Name AS CategoryName,
        scm.SubCategory_Name AS SubCategoryName,
        loi.Price,
        loi.IsUrgent,
        ISNULL(pli.LineDiscountAmount, 0) AS DiscountAmount,
        ISNULL(pli.NetLineAmount, loi.Price) AS NetAmount,
        loi.IsActive
    FROM dbo.LabOrderItem loi
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND loi.InvestigationId > 0
    LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = ABS(loi.InvestigationId) AND loi.InvestigationId < 0
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    LEFT JOIN dbo.LabTestCategoryMaster cm ON cm.Category_ID = lim.Category_ID
    LEFT JOIN dbo.LabTestSubCategoryMaster scm ON scm.SubCategory_ID = lim.SubCategory_ID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = loi.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId 
        AND (pli.ModuleLineRefId = loi.LabOrderItemId OR pli.ModuleLineRefId = loi.InvestigationId)
        AND pli.IsActive = 1
    WHERE loi.LabOrderId = @LabOrderId
    ORDER BY loi.LabOrderItemId;

    SELECT 
        pd.PaymentDetailId,
        pm.MethodName,
        pm.MethodCode,
        pd.PaidAmount,
        pd.PaymentDate,
        pd.ReceiptNo,
        pd.TransactionRef,
        pd.ChequeNo,
        pd.BankName,
        pd.UPIRefNo,
        pd.CardLast4,
        pd.Notes
    FROM dbo.PaymentHeader ph
    INNER JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @LabOrderId AND ph.IsActive = 1;
END
GO

-- ─────────────────────────────────────────────────────────────
-- Update usp_SampleCollection_GetHeaderList
-- ─────────────────────────────────────────────────────────────
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
        lo.IsUrgent,
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
