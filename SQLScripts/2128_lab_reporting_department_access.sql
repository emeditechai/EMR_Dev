-- ============================================================================
-- Migration: 2128_lab_reporting_department_access.sql
-- Description:
--   Lab Reporting Entry list (LabReporting/Index) is limited to the Department Access of the logged-in
--   user (User Master > Access & Roles > Department Access, dbo.Users.DepartmentIds).
--   dbo.usp_LabReporting_GetHeaderList  + @AllowedDepartmentIds (NULL = unrestricted, '' = none).
--   Orders, their test counts, report status and the KPI counts cover only tests of those departments.
--   Other callers do not pass the parameter and are unchanged.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetHeaderList
    @BranchId        INT,
    @FromDate        DATETIME      = NULL,
    @ToDate          DATETIME      = NULL,
    @DateFilterType  VARCHAR(20)   = 'BookingDate',
    @StatusFilter    VARCHAR(50)   = 'All',
    @Search          NVARCHAR(100) = NULL,
    @DepartmentId    INT           = NULL,
    @CategoryId      INT           = NULL,
    @SubCategoryId   INT           = NULL,
    -- Department Access of the logged-in user (User Master), comma separated DeptIds.
    -- NULL = not restricted (super admin / other callers); '' = no department -> nothing is listed.
    @AllowedDepartmentIds NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RestrictDept BIT = CASE WHEN @AllowedDepartmentIds IS NULL THEN 0 ELSE 1 END;
    DECLARE @AllowedDept TABLE (DeptId INT PRIMARY KEY);
    IF @RestrictDept = 1
        INSERT INTO @AllowedDept (DeptId)
        SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
        FROM STRING_SPLIT(@AllowedDepartmentIds, ',')
        WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;

    IF @FromDate IS NULL
        SET @FromDate = CAST(CAST(GETDATE() AS DATE) AS DATETIME);
    
    IF @ToDate IS NULL
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));
    ELSE IF CAST(@ToDate AS TIME) = '00:00:00'
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(@ToDate AS DATE) AS DATETIME));

    WITH EligibleOrders AS (
        SELECT 
            sc.Laborderid,
            COUNT(1) AS TotalInHouseTests,
            SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) AS CollectedInHouseTests,
            MIN(sc.Bookingdatetime) AS MinBookingDateTime,
            MIN(sc.Orderdate) AS MinOrderDate,
            MAX(CASE WHEN sc.IsTransferred = 1 THEN 1 ELSE 0 END) AS HasTransferredSamples,
            MAX(CASE WHEN sc.IsTransferred = 1 THEN sc.SourceBranchID ELSE NULL END) AS TransferredSourceBranchId,
            MAX(CASE WHEN sc.IsTransferred = 1 THEN sc.TransferredDate ELSE NULL END) AS TransferredDate
        FROM dbo.SampleCollection sc
        WHERE (
            -- Native non-transferred sample at this branch
            (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
            -- OR sample transferred TO this branch AND received
            OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND sc.IsReceived = 1)
            -- transferred out of this branch but APPROVED at the target: the bill belongs to the source branch again
            OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
                AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap
                            WHERE l_ap.SamplecollectionID = sc.samplecollectionID
                              AND l_ap.IsActive = 1 AND l_ap.ReportStatusId = 5))
        )
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND ISNULL(sc.IsoutSource, 0) = 0
          AND (@RestrictDept = 0 OR sc.DepartmentID IN (SELECT DeptId FROM @AllowedDept))
        GROUP BY sc.Laborderid
        HAVING SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) > 0
           AND (
               (@DepartmentId IS NULL AND @CategoryId IS NULL AND @SubCategoryId IS NULL)
               OR EXISTS (
                   SELECT 1
                   FROM dbo.SampleCollection sc_f
                   LEFT JOIN dbo.LabInvestigationMaster lim_f ON lim_f.Test_ID = sc_f.InvestigationID
                   WHERE sc_f.Laborderid = sc.Laborderid
                     AND (
                         (ISNULL(sc_f.IsTransferred, 0) = 0 AND sc_f.BranchID = @BranchId)
                         OR (sc_f.IsTransferred = 1 AND sc_f.TargetBranchID = @BranchId AND sc_f.IsReceived = 1)
                         -- transferred out of this branch but APPROVED at the target: the bill belongs to the source branch again
                         OR (sc_f.IsTransferred = 1 AND sc_f.SourceBranchID = @BranchId
                             AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap2
                                         WHERE l_ap2.SamplecollectionID = sc_f.samplecollectionID
                                           AND l_ap2.IsActive = 1 AND l_ap2.ReportStatusId = 5))
                     )
                     AND sc_f.Is_Active = 1
                     AND sc_f.Iscancelled = 0
                     AND ISNULL(sc_f.IsoutSource, 0) = 0
                     AND (@RestrictDept = 0 OR sc_f.DepartmentID IN (SELECT DeptId FROM @AllowedDept))
                     AND (@DepartmentId IS NULL OR sc_f.DepartmentID = @DepartmentId OR lim_f.Department_ID = @DepartmentId)
                     AND (@CategoryId IS NULL OR sc_f.TestcategoryID = @CategoryId OR lim_f.Category_ID = @CategoryId)
                     AND (@SubCategoryId IS NULL OR sc_f.TestsubcategoryID = @SubCategoryId OR lim_f.SubCategory_ID = @SubCategoryId)
               )
           )
    ),
    ReportAggregates AS (
        SELECT 
            eo.Laborderid,
            COUNT(led.LabEntryDetailId) AS TotalEnteredCount,
            SUM(CASE WHEN led.ReportStatusId = 1 THEN 1 ELSE 0 END) AS DraftCount,
            SUM(CASE WHEN led.ReportStatusId = 2 THEN 1 ELSE 0 END) AS EntryCount,
            SUM(CASE WHEN led.ReportStatusId = 3 THEN 1 ELSE 0 END) AS ValidatedCount,
            SUM(CASE WHEN led.ReportStatusId = 5 OR res.StatusCode IN ('REPORT_APPROVE', 'REPORT_APPROVED') THEN 1 ELSE 0 END) AS ApprovedCount
        FROM EligibleOrders eo
        INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = eo.Laborderid 
            AND sc.CollectionstatusID = 2 
            AND ISNULL(sc.IsoutSource, 0) = 0
            AND sc.Is_Active = 1 
            AND sc.Iscancelled = 0
            AND (@RestrictDept = 0 OR sc.DepartmentID IN (SELECT DeptId FROM @AllowedDept))
            AND (
                (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
                OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND sc.IsReceived = 1)
                -- transferred out of this branch but APPROVED at the target: the bill belongs to the source branch again
                OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
                    AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap3
                                WHERE l_ap3.SamplecollectionID = sc.samplecollectionID
                                  AND l_ap3.IsActive = 1 AND l_ap3.ReportStatusId = 5))
            )
        LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
        LEFT JOIN dbo.Reportentrystatus res ON res.ReportStatusId = led.ReportStatusId
        GROUP BY eo.Laborderid
    )
    SELECT 
        lo.LabOrderId,
        lo.BranchId,
        p.PatientId,
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
        lo.OrderDate,
        ISNULL(lo.BookingDate, eo.MinBookingDateTime) AS BookingDateTime,
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        eo.TotalInHouseTests,
        eo.CollectedInHouseTests,
        CASE 
            WHEN eo.CollectedInHouseTests >= eo.TotalInHouseTests THEN 'Collected'
            ELSE 'Partially Collected'
        END AS SampleCollectionStatus,
        CASE 
            WHEN ra.TotalEnteredCount = 0 THEN 0
            WHEN ra.ApprovedCount = eo.CollectedInHouseTests AND eo.CollectedInHouseTests > 0 THEN 5
            WHEN ra.ValidatedCount = eo.CollectedInHouseTests AND eo.CollectedInHouseTests > 0 THEN 3
            WHEN ra.EntryCount > 0 AND (ra.EntryCount + ra.ValidatedCount + ra.ApprovedCount) = eo.CollectedInHouseTests THEN 2
            WHEN ra.DraftCount > 0 OR ra.TotalEnteredCount > 0 THEN 1
            ELSE 0
        END AS ReportStatusId,
        CASE 
            WHEN ra.TotalEnteredCount = 0 THEN 'Pending Entry'
            WHEN ra.ApprovedCount = eo.CollectedInHouseTests AND eo.CollectedInHouseTests > 0 THEN 'Report Approve'
            WHEN ra.ValidatedCount = eo.CollectedInHouseTests AND eo.CollectedInHouseTests > 0 THEN 'Report Validated'
            WHEN ra.EntryCount > 0 AND (ra.EntryCount + ra.ValidatedCount + ra.ApprovedCount) = eo.CollectedInHouseTests THEN 'Report Entry'
            WHEN ra.DraftCount > 0 OR ra.TotalEnteredCount > 0 THEN 'Draft'
            ELSE 'Pending Entry'
        END AS ReportStatusName,
        CASE 
            WHEN ra.TotalEnteredCount = 0 THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            WHEN ra.ApprovedCount = eo.CollectedInHouseTests AND eo.CollectedInHouseTests > 0 THEN 'bg-info-subtle text-info border border-info-subtle'
            WHEN ra.ValidatedCount = eo.CollectedInHouseTests AND eo.CollectedInHouseTests > 0 THEN 'bg-success-subtle text-success border border-success-subtle'
            WHEN ra.EntryCount > 0 AND (ra.EntryCount + ra.ValidatedCount + ra.ApprovedCount) = eo.CollectedInHouseTests THEN 'bg-primary-subtle text-primary border border-primary-subtle'
            WHEN ra.DraftCount > 0 OR ra.TotalEnteredCount > 0 THEN 'bg-warning-subtle text-warning border border-warning-subtle'
            ELSE 'bg-secondary-subtle text-secondary border border-secondary-subtle'
        END AS ReportBadgeClass,
        CAST(ISNULL(eo.HasTransferredSamples, 0) AS BIT) AS IsTransferred,
        eo.TransferredSourceBranchId AS SourceBranchId,
        srcB.BranchName AS SourceBranchName,
        eo.TransferredDate
    INTO #FilteredReportOrders
    FROM EligibleOrders eo
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = eo.Laborderid AND lo.IsActive = 1
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster srcB ON srcB.BranchID = eo.TransferredSourceBranchId
    LEFT JOIN ReportAggregates ra ON ra.Laborderid = eo.Laborderid
    WHERE (
          (@DateFilterType = 'OrderDate' AND lo.OrderDate BETWEEN @FromDate AND @ToDate)
          OR (@DateFilterType <> 'OrderDate' AND ISNULL(lo.BookingDate, eo.MinBookingDateTime) BETWEEN @FromDate AND @ToDate)
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

    SELECT 
        COUNT(1) AS TotalOrders,
        SUM(CASE WHEN ReportStatusName = 'Pending Entry' THEN 1 ELSE 0 END) AS PendingOrders,
        SUM(CASE WHEN ReportStatusName = 'Draft' THEN 1 ELSE 0 END) AS DraftOrders,
        SUM(CASE WHEN ReportStatusName = 'Report Entry' THEN 1 ELSE 0 END) AS EnteredOrders,
        SUM(CASE WHEN ReportStatusName = 'Report Validated' THEN 1 ELSE 0 END) AS ValidatedOrders
    FROM #FilteredReportOrders;

    DECLARE @NormalizedStatus VARCHAR(50) = UPPER(LTRIM(RTRIM(ISNULL(@StatusFilter, 'ALL'))));

    SELECT *
    FROM #FilteredReportOrders
    WHERE (
        @NormalizedStatus = 'ALL'
        OR (@NormalizedStatus IN ('PENDING', 'PENDING ENTRY') AND ReportStatusName = 'Pending Entry')
        OR (@NormalizedStatus = 'DRAFT' AND ReportStatusName = 'Draft')
        OR (@NormalizedStatus IN ('REPORT ENTRY', 'ENTRY', 'ENTERED') AND ReportStatusName = 'Report Entry')
        OR (@NormalizedStatus IN ('REPORT VALIDATED', 'VALIDATED') AND ReportStatusName = 'Report Validated')
        OR (@NormalizedStatus IN ('REPORT APPROVE', 'REPORT APPROVED', 'APPROVE', 'APPROVED') AND ReportStatusName IN ('Report Approve', 'Report Approved'))
    )
    ORDER BY 
        IsUrgent DESC,
        BookingDateTime DESC,
        LabOrderId DESC;

    DROP TABLE #FilteredReportOrders;
END;
GO

PRINT 'Script 2128 applied: Lab Reporting list limited by user Department Access.';
GO
