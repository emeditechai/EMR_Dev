-- ============================================================================
-- Migration: 2108_lab_dashboard_client_filter_and_analytics.sql
-- Description:
--   LAB Dashboard: a B2C / B2B client filter that drives EVERY figure on the page, plus new analysis sets.
--
--     @ClientType = ALL | B2C | B2B is applied to every existing result set (summary, collection status,
--     top investigations, category split and the order queue), and adds:
--       RS6  reporting pipeline  - pending entry / entered / validated / approved, abnormal & critical, average TAT
--       RS7  billing             - gross, collected, outstanding, B2B vs B2C split, average bill value
--       RS8  bookings by hour    - workload through the day
--       RS9  department workload - tests, collected and approved per department
--       RS10 top B2B clients     - franchise / company leaderboard (empty when the filter is B2C)
--
--   Nothing else is altered; the existing five result sets keep their shape and order.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LAB_Dashboard_GetStats
    @BranchId INT,
    @Date     DATE = NULL,
    @ClientType VARCHAR(10) = 'ALL'    -- ALL | B2C | B2B : drives every result set
AS
BEGIN
    SET @ClientType = UPPER(LTRIM(RTRIM(ISNULL(@ClientType, 'ALL'))));
    IF @ClientType NOT IN ('ALL', 'B2C', 'B2B') SET @ClientType = 'ALL';

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
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0)) 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 1
              AND sc.Is_Active = 1
        ), 0) AS PendingCollectionsToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
            WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0)) 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 2
              AND sc.Is_Active = 1
        ), 0) AS CompletedCollectionsToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
            WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0)) 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 3
              AND sc.Is_Active = 1
        ), 0) AS RecollectSamplesToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
            WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0)) 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 4
              AND sc.Is_Active = 1
        ), 0) AS RejectedSamplesToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.LabOrderItem loi
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId
            WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0)) 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND loi.IsActive = 1
        ), 0) AS TotalTestsBookedToday
    FROM dbo.LabOrder o
    WHERE o.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
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
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
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
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
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
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
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
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
      AND (CAST(o.OrderDate AS DATE) = @Date OR CAST(o.BookingDate AS DATE) = @Date)
      AND o.IsActive = 1
    ORDER BY 
        o.IsUrgent DESC,
        ISNULL(o.BookingDate, o.OrderDate) DESC,
        o.LabOrderId DESC;

    -- ─────────────────────────────────────────────────────────────
    -- 6. Reporting pipeline (entry -> validation -> approval)
    -- ─────────────────────────────────────────────────────────────
    SELECT
        SUM(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 1 ELSE 0 END) AS PendingEntry,
        SUM(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' AND led.ReportStatusId IN (1, 2) THEN 1 ELSE 0 END) AS Entered,
        SUM(CASE WHEN led.ReportStatusId = 3 THEN 1 ELSE 0 END)                     AS Validated,
        SUM(CASE WHEN led.ReportStatusId = 5 THEN 1 ELSE 0 END)                     AS Approved,
        SUM(CASE WHEN ISNULL(led.AbnormalFlag, '') IN ('H', 'L') THEN 1 ELSE 0 END) AS AbnormalResults,
        SUM(CASE WHEN ISNULL(led.AbnormalFlag, '') = 'Critical' THEN 1 ELSE 0 END)  AS CriticalResults,
        CAST(AVG(CASE WHEN led.ReportStatusId = 5 AND led.Approved_Date IS NOT NULL
                      THEN DATEDIFF(MINUTE, ISNULL(o.BookingDate, o.OrderDate), led.Approved_Date) * 1.0 END) AS DECIMAL(12,1)) AS AvgTatMinutes
    FROM dbo.LabOrder o
    INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0
    LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
      AND CAST(ISNULL(o.BookingDate, o.OrderDate) AS DATE) = @Date
      AND o.IsActive = 1;

    -- ─────────────────────────────────────────────────────────────
    -- 7. Billing and money collected
    -- ─────────────────────────────────────────────────────────────
    SELECT
        ISNULL(SUM(o.TotalAmount), 0)                                                  AS GrossAmount,
        ISNULL(SUM(ISNULL(ph.TotalPaid, 0)), 0)                                        AS CollectedAmount,
        ISNULL(SUM(ISNULL(ph.BalanceDue, o.TotalAmount)), 0)                           AS OutstandingAmount,
        SUM(CASE WHEN ISNULL(ph.BalanceDue, o.TotalAmount) > 0 THEN 1 ELSE 0 END)      AS BillsWithDue,
        SUM(CASE WHEN ISNULL(o.IsB2B, 0) = 1 THEN 1 ELSE 0 END)                        AS B2BOrders,
        SUM(CASE WHEN ISNULL(o.IsB2B, 0) = 0 THEN 1 ELSE 0 END)                        AS B2COrders,
        ISNULL(SUM(CASE WHEN ISNULL(o.IsB2B, 0) = 1 THEN o.TotalAmount ELSE 0 END), 0) AS B2BAmount,
        ISNULL(SUM(CASE WHEN ISNULL(o.IsB2B, 0) = 0 THEN o.TotalAmount ELSE 0 END), 0) AS B2CAmount,
        CAST(ISNULL(AVG(NULLIF(o.TotalAmount, 0)), 0) AS DECIMAL(12,2))                AS AvgBillValue
    FROM dbo.LabOrder o
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
      AND CAST(ISNULL(o.BookingDate, o.OrderDate) AS DATE) = @Date
      AND o.IsActive = 1;

    -- ─────────────────────────────────────────────────────────────
    -- 8. Bookings by hour
    -- ─────────────────────────────────────────────────────────────
    SELECT
        DATEPART(HOUR, ISNULL(o.BookingDate, o.OrderDate)) AS HourOfDay,
        COUNT(1)                                           AS OrderCount,
        ISNULL(SUM(o.TotalAmount), 0)                      AS Amount
    FROM dbo.LabOrder o
    WHERE o.BranchId = @BranchId
      AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
      AND CAST(ISNULL(o.BookingDate, o.OrderDate) AS DATE) = @Date
      AND o.IsActive = 1
    GROUP BY DATEPART(HOUR, ISNULL(o.BookingDate, o.OrderDate))
    ORDER BY HourOfDay;

    -- ─────────────────────────────────────────────────────────────
    -- 9. Department workload
    -- ─────────────────────────────────────────────────────────────
    SELECT TOP 8
        ISNULL(d.DeptName, 'Unassigned')                           AS DepartmentName,
        COUNT(1)                                                   AS TestCount,
        SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) AS CollectedCount,
        SUM(CASE WHEN led.ReportStatusId = 5 THEN 1 ELSE 0 END)    AS ApprovedCount
    FROM dbo.LabOrder o
    INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.DepartmentMaster d ON d.DeptId = COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID)
    LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
      AND CAST(ISNULL(o.BookingDate, o.OrderDate) AS DATE) = @Date
      AND o.IsActive = 1
    GROUP BY ISNULL(d.DeptName, 'Unassigned')
    ORDER BY TestCount DESC;

    -- ─────────────────────────────────────────────────────────────
    -- 10. Top B2B clients (franchise / company)
    -- ─────────────────────────────────────────────────────────────
    SELECT TOP 6
        CASE o.AgentType WHEN 'F' THEN 'FRANCHISE' ELSE 'COMPANY' END                  AS ClientType,
        CASE WHEN o.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END AS ClientName,
        CASE WHEN o.AgentType = 'F' THEN f.Franchise_Code ELSE corp.Corporate_Code END AS ClientCode,
        COUNT(1)                                                                       AS OrderCount,
        ISNULL(SUM(o.TotalAmount), 0)                                                  AS Amount
    FROM dbo.LabOrder o
    LEFT JOIN dbo.LabFranchiseMaster f    ON f.Franchise_ID    = o.B2BAgentID AND o.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster    corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
    WHERE o.BranchId = @BranchId
      AND ISNULL(o.IsB2B, 0) = 1
      AND @ClientType <> 'B2C'
      AND CAST(ISNULL(o.BookingDate, o.OrderDate) AS DATE) = @Date
      AND o.IsActive = 1
    GROUP BY o.AgentType,
             CASE WHEN o.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END,
             CASE WHEN o.AgentType = 'F' THEN f.Franchise_Code ELSE corp.Corporate_Code END
    ORDER BY OrderCount DESC, Amount DESC;
END;

GO

PRINT 'Updated dbo.usp_Api_LAB_Dashboard_GetStats (client filter + analytics)';
GO
