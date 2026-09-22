-- ============================================================================
-- Migration: 2115_laborder_list_approved_test_count.sql
-- Description:
--   B2C Order List / B2B Registration & Order List screens: adds ApprovedTestCount to
--   usp_LabOrder_GetPagedList so the Web layer can show a "Print Report" action only when at
--   least one test on the order has been approved (partial approval is enough - the report can
--   already be printed with whatever is signed off so far).
--   Driven by HospitalSettings.ShowLabReportPrintOnList (Settings > LAB tab) - purely additive,
--   no existing column removed/renamed.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetPagedList
    @BranchId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @Search NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10,
    @IsB2B BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    IF @FromDate IS NULL SET @FromDate = CAST(GETDATE() AS DATE);
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize < 1 SET @PageSize = 10;

    -- Stats
    SELECT
        COUNT(1) AS TotalOrders,
        ISNULL(SUM(o.TotalAmount), 0.00) AS TotalAmount,
        ISNULL(SUM(CASE
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 1
            WHEN ISNULL(o.IsB2B, 0) = 0 AND ph.PaymentStatus = 'P' THEN 1
            ELSE 0
        END), 0) AS PaidCount,
        ISNULL(SUM(CASE
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) < ISNULL(o.B2BTotal, o.TotalAmount) THEN 1
            WHEN ISNULL(o.IsB2B, 0) = 0 AND ISNULL(ph.PaymentStatus, 'U') <> 'P' THEN 1
            ELSE 0
        END), 0) AS UnpaidCount,
        ISNULL(SUM(CASE WHEN o.IsB2B = 1 THEN ISNULL(o.B2BTotal, 0.00) ELSE 0.00 END), 0.00) AS B2BTotalAmount
    FROM dbo.LabOrder o
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE (@BranchId IS NULL OR @BranchId = 0 OR o.BranchId = @BranchId)
      AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
      AND (@IsB2B IS NULL OR (@IsB2B = 1 AND o.IsB2B = 1) OR (@IsB2B = 0 AND ISNULL(o.IsB2B, 0) = 0))
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
            o.IsB2B,
            o.B2BAgentID,
            o.AgentType,
            o.B2BTotal,
            CASE
                WHEN o.AgentType = 'F' THEN f.Franchise_Name
                WHEN o.AgentType = 'C' THEN corp.Corporate_Name
                ELSE NULL
            END AS AgentName,
            CASE
                WHEN o.AgentType = 'F' THEN f.Franchise_Code
                WHEN o.AgentType = 'C' THEN corp.Corporate_Code
                ELSE NULL
            END AS AgentCode,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.MiddleName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            CASE
                WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                ELSE NULL
            END AS Age,
            ph.PaymentHeaderId,
            CASE
                WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 'P'
                WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'R'
                WHEN o.IsB2B = 1 THEN 'U'
                ELSE ISNULL(ph.PaymentStatus, 'U')
            END AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
            CASE
                WHEN o.IsB2B = 1 THEN
                    CASE WHEN ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) < 0 THEN 0.00
                         ELSE ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) END
                ELSE ISNULL(ph.BalanceDue, o.TotalAmount)
            END AS BalanceDue,
            ISNULL(NULLIF(u.FullName, ''), u.Username) AS CreatedByName,
            u.Username AS CreatedByUsername,
            (
                SELECT COUNT(1)
                FROM dbo.LabOrderItem loi
                WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
            ) AS ItemCount,
            (
                SELECT STRING_AGG(
                    CASE
                        WHEN loi.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Package #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                        ELSE ISNULL(lim.Test_Name, 'Test #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                    END, ', ')
                FROM dbo.LabOrderItem loi
                LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND (loi.Type = 'I' OR loi.Type IS NULL)
                LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
            ) AS TestNamesSummary,
            -- Tests already signed off (ReportStatusId = 5 "Report Approve"); >0 means the report can be
            -- printed even if not every test on the order is approved yet (partial approval allowed).
            (
                SELECT COUNT(1)
                FROM dbo.SampleCollection sc
                INNER JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
                WHERE sc.Laborderid = o.LabOrderId AND led.ReportStatusId = 5
            ) AS ApprovedTestCount,
            ROW_NUMBER() OVER (ORDER BY o.LabOrderId DESC) AS RowNum,
            COUNT(1) OVER() AS TotalCount
        FROM dbo.LabOrder o
        INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
        LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
        LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = o.B2BAgentID AND o.AgentType = 'F'
        LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
        WHERE (@BranchId IS NULL OR @BranchId = 0 OR o.BranchId = @BranchId)
          AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
          AND (@IsB2B IS NULL OR (@IsB2B = 1 AND o.IsB2B = 1) OR (@IsB2B = 0 AND ISNULL(o.IsB2B, 0) = 0))
          AND (
              @Search IS NULL
              OR o.BillNo LIKE '%' + @Search + '%'
              OR o.TokenNo LIKE '%' + @Search + '%'
              OR EXISTS (
              SELECT 1 FROM dbo.PatientMaster p
              WHERE p.PatientId = o.PatientId
                AND (p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%' OR p.PatientCode LIKE '%' + @Search + '%')
          )
      )
    )
    SELECT
        LabOrderId,
        PatientId,
        BranchId,
        OrderDate,
        BillNo,
        TokenNo,
        TotalAmount,
        CollectionType,
        PhlebotomistId,
        IsUrgent,
        PhlebotomistName,
        BookingDate,
        IsActive,
        CreatedDate,
        CreatedBy,
        IsB2B,
        B2BAgentID,
        AgentType,
        B2BTotal,
        AgentName,
        AgentCode,
        PatientCode,
        PatientName,
        PhoneNumber,
        Gender,
        Age,
        PaymentHeaderId,
        PaymentStatus,
        TotalPaid,
        BalanceDue,
        CreatedByName,
        CreatedByUsername,
        ItemCount,
        TestNamesSummary,
        ApprovedTestCount,
        TotalCount
    FROM PagedOrders
    WHERE RowNum BETWEEN ((@PageNumber - 1) * @PageSize + 1) AND (@PageNumber * @PageSize)
    ORDER BY LabOrderId DESC;
END;
GO

PRINT 'Updated dbo.usp_LabOrder_GetPagedList (added ApprovedTestCount).';
GO
