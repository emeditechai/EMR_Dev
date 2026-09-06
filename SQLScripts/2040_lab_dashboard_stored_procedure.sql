USE [Dev_EMR]
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LAB_Dashboard_GetStats
    @BranchId INT,
    @Date     DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Date IS NULL
        SET @Date = CAST(GETDATE() AS DATE);

    -- ─────────────────────────────────────────────────────────────
    -- 1. Summary KPI Statistics
    -- ─────────────────────────────────────────────────────────────
    SELECT 
        COUNT(DISTINCT o.LabOrderId) AS TotalOrdersToday,
        ISNULL(SUM(o.TotalAmount), 0) AS TotalRevenueToday,
        ISNULL(SUM(CASE WHEN o.IsUrgent = 1 THEN 1 ELSE 0 END), 0) AS UrgentOrdersToday,
        ISNULL(SUM(CASE WHEN o.CollectionType = 'Home' OR o.CollectionType = 'Home Collection' THEN 1 ELSE 0 END), 0) AS HomeCollectionOrders,
        ISNULL(SUM(CASE WHEN o.CollectionType = 'Lab' OR o.CollectionType IS NULL THEN 1 ELSE 0 END), 0) AS InLabOrders,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
            WHERE lo.BranchId = @BranchId 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 1
              AND sc.Is_Active = 1
        ), 0) AS PendingCollectionsToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
            WHERE lo.BranchId = @BranchId 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 2
              AND sc.Is_Active = 1
        ), 0) AS CompletedCollectionsToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
            WHERE lo.BranchId = @BranchId 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 3
              AND sc.Is_Active = 1
        ), 0) AS RecollectSamplesToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
            WHERE lo.BranchId = @BranchId 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 4
              AND sc.Is_Active = 1
        ), 0) AS RejectedSamplesToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.LabOrderItem loi
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId
            WHERE lo.BranchId = @BranchId 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND loi.IsActive = 1
        ), 0) AS TotalTestsBookedToday
    FROM dbo.LabOrder o
    WHERE o.BranchId = @BranchId
      AND (CAST(o.OrderDate AS DATE) = @Date OR CAST(o.BookingDate AS DATE) = @Date)
      AND o.IsActive = 1;

    -- ─────────────────────────────────────────────────────────────
    -- 2. Collection Status Breakdown
    -- ─────────────────────────────────────────────────────────────
    SELECT 
        scs.StatusID,
        scs.StatusCode,
        scs.StatusName,
        scs.BadgeClass,
        ISNULL(cnt.TotalCount, 0) AS TotalCount
    FROM dbo.SampleCollectionStatus scs
    LEFT JOIN (
        SELECT sc.CollectionstatusID, COUNT(1) AS TotalCount
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
        WHERE lo.BranchId = @BranchId
          AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
          AND sc.Is_Active = 1
        GROUP BY sc.CollectionstatusID
    ) cnt ON cnt.CollectionstatusID = scs.StatusID
    WHERE scs.IsActive = 1
    ORDER BY scs.DisplayOrder;

    -- ─────────────────────────────────────────────────────────────
    -- 3. Top Investigations / Profiles Booked
    -- ─────────────────────────────────────────────────────────────
    SELECT TOP 6
        CASE 
            WHEN loi.Type = 'P' THEN ISNULL(p.Profile_Name, 'Profile #' + CAST(loi.InvestigationId AS VARCHAR(10)))
            ELSE ISNULL(lim.Test_Name, 'Test #' + CAST(loi.InvestigationId AS VARCHAR(10)))
        END AS ItemName,
        ISNULL(loi.Type, 'I') AS ItemType,
        ISNULL(cat.Category_Name, 'General Investigation') AS CategoryName,
        COUNT(1) AS OrderCount,
        SUM(ISNULL(loi.Price, 0)) AS TotalRevenue
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND (loi.Type = 'I' OR loi.Type IS NULL)
    LEFT JOIN dbo.LabInvestigationProfileHeader p ON p.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
    LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = lim.Category_ID
    WHERE lo.BranchId = @BranchId
      AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
      AND loi.IsActive = 1
    GROUP BY 
        loi.Type,
        CASE 
            WHEN loi.Type = 'P' THEN ISNULL(p.Profile_Name, 'Profile #' + CAST(loi.InvestigationId AS VARCHAR(10)))
            ELSE ISNULL(lim.Test_Name, 'Test #' + CAST(loi.InvestigationId AS VARCHAR(10)))
        END,
        cat.Category_Name
    ORDER BY OrderCount DESC, TotalRevenue DESC;

    -- ─────────────────────────────────────────────────────────────
    -- 4. Category Distribution
    -- ─────────────────────────────────────────────────────────────
    SELECT TOP 6
        ISNULL(cat.Category_Name, 'Profile / Package') AS CategoryName,
        COUNT(1) AS TestCount
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = sc.TestcategoryID
    WHERE lo.BranchId = @BranchId
      AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
      AND sc.Is_Active = 1
    GROUP BY cat.Category_Name
    ORDER BY TestCount DESC;

    -- ─────────────────────────────────────────────────────────────
    -- 5. Today's Patient / Lab Order Queue
    -- ─────────────────────────────────────────────────────────────
    SELECT 
        o.LabOrderId,
        o.BillNo,
        o.TokenNo,
        o.OrderDate,
        ISNULL(o.BookingDate, o.OrderDate) AS BookingDate,
        o.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        p.Gender,
        CASE 
            WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
            ELSE NULL 
        END AS Age,
        o.TotalAmount,
        ISNULL(o.IsUrgent, 0) AS IsUrgent,
        ISNULL(o.CollectionType, 'Lab') AS CollectionType,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, o.TotalAmount) AS BalanceDue,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.LabOrderItem loi 
            WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
        ), 0) AS TotalItems,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc 
            WHERE sc.Laborderid = o.LabOrderId AND sc.CollectionstatusID = 1 AND sc.Is_Active = 1
        ), 0) AS PendingCount,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc 
            WHERE sc.Laborderid = o.LabOrderId AND sc.CollectionstatusID = 2 AND sc.Is_Active = 1
        ), 0) AS CollectedCount,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc 
            WHERE sc.Laborderid = o.LabOrderId AND (sc.CollectionstatusID = 3 OR sc.CollectionstatusID = 4) AND sc.Is_Active = 1
        ), 0) AS AlertCount,
        CASE 
            WHEN NOT EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1) THEN 'Unassigned'
            WHEN NOT EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.Laborderid = o.LabOrderId AND sc.CollectionstatusID != 2 AND sc.Is_Active = 1) THEN 'Collected'
            WHEN NOT EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.Laborderid = o.LabOrderId AND sc.CollectionstatusID != 1 AND sc.Is_Active = 1) THEN 'Pending'
            ELSE 'Partially Collected'
        END AS OverallSampleStatus,
        (
            SELECT STRING_AGG(
                CASE 
                    WHEN loi.Type = 'P' THEN ISNULL(pr.Profile_Name, 'Profile #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                    ELSE ISNULL(lim.Test_Name, 'Test #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                END, ', ')
            FROM dbo.LabOrderItem loi
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND (loi.Type = 'I' OR loi.Type IS NULL)
            LEFT JOIN dbo.LabInvestigationProfileHeader pr ON pr.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
            WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
        ) AS TestSummary
    FROM dbo.LabOrder o
    INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND (CAST(o.OrderDate AS DATE) = @Date OR CAST(o.BookingDate AS DATE) = @Date)
      AND o.IsActive = 1
    ORDER BY 
        o.IsUrgent DESC,
        ISNULL(o.BookingDate, o.OrderDate) DESC,
        o.LabOrderId DESC;

END;
GO
