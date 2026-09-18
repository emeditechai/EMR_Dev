SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ========================================================================
-- Description: Update usp_SampleTransfer_GetEligibleSamples to support
-- cascading filters by Department, Category, and SubCategory
-- ========================================================================
CREATE OR ALTER PROCEDURE dbo.usp_SampleTransfer_GetEligibleSamples
    @SourceBranchId        INT,
    @FromDate              DATETIME      = NULL,
    @ToDate                DATETIME      = NULL,
    @DateFilterType        VARCHAR(20)   = 'CollectionDate', -- 'CollectionDate', 'BookingDate', 'OrderDate'
    @TransferStatusFilter  VARCHAR(20)   = 'Ready',          -- 'Ready', 'Transferred', 'All'
    @Search                NVARCHAR(100) = NULL,
    @DepartmentId          INT           = NULL,
    @CategoryId            INT           = NULL,
    @SubCategoryId         INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Default Date Range: Today
    IF @FromDate IS NULL
        SET @FromDate = CAST(CAST(GETDATE() AS DATE) AS DATETIME);
    
    IF @ToDate IS NULL
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));
    ELSE IF CAST(@ToDate AS TIME) = '00:00:00'
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(@ToDate AS DATE) AS DATETIME));

    DECLARE @NormFilter VARCHAR(20) = UPPER(LTRIM(RTRIM(ISNULL(@TransferStatusFilter, 'READY'))));

    -- Summary Stats
    SELECT 
        SUM(CASE WHEN ISNULL(sc.IsTransferred, 0) = 0 AND sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) AS ReadyCount,
        SUM(CASE WHEN sc.IsTransferred = 1 AND sc.SourceBranchID = @SourceBranchId AND CAST(sc.TransferredDate AS DATE) = CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END) AS TransferredTodayCount,
        COUNT(DISTINCT CASE WHEN sc.IsTransferred = 1 AND sc.SourceBranchID = @SourceBranchId THEN sc.TargetBranchID END) AS TargetBranchesCount
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    WHERE (
        (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @SourceBranchId)
        OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @SourceBranchId)
    )
    AND sc.Is_Active = 1
    AND sc.Iscancelled = 0
    AND sc.CollectionstatusID = 2
    AND ISNULL(sc.IsoutSource, 0) = 0
    AND (@DepartmentId IS NULL OR sc.DepartmentID = @DepartmentId OR lim.Department_ID = @DepartmentId)
    AND (@CategoryId IS NULL OR sc.TestcategoryID = @CategoryId OR lim.Category_ID = @CategoryId)
    AND (@SubCategoryId IS NULL OR sc.TestsubcategoryID = @SubCategoryId OR lim.SubCategory_ID = @SubCategoryId);

    -- Detail Sample Items
    SELECT 
        sc.samplecollectionID       AS SampleCollectionId,
        sc.Laborderid               AS LabOrderId,
        sc.BranchID                 AS CurrentBranchId,
        sc.PatientID                AS PatientId,
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
        lo.BillNo,
        lo.TokenNo,
        lo.OrderDate,
        ISNULL(lo.BookingDate, sc.Bookingdatetime) AS BookingDateTime,
        sc.Samplecollectiondate     AS CollectionDate,
        sc.Samplecollectiontime     AS CollectionTime,
        sc.BarcodeNo,
        sc.InvestigationID          AS InvestigationId,
        lim.Test_Code               AS TestCode,
        lim.Test_Name               AS TestName,
        sc.DepartmentID             AS DepartmentId,
        ISNULL(ldm.DeptName, 'General') AS DepartmentName,
        ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
        ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS ContainerType,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName, '—') AS ProfilePackageName,
        sc.CollectionstatusID       AS CollectionStatusId,
        scs.StatusName              AS CollectionStatusName,
        ISNULL(sc.IsTransferred, 0) AS IsTransferred,
        ISNULL(sc.SourceBranchID, sc.BranchID) AS SourceBranchId,
        ISNULL(srcB.BranchName, 'Main Branch') AS SourceBranchName,
        sc.TargetBranchID           AS TargetBranchId,
        tgtB.BranchName             AS TargetBranchName,
        sc.TransferredDate,
        sc.TransferredBy,
        u.FullName                  AS TransferredByName,
        sc.TransferRemarks,
        -- Check if report entry already initiated/completed at target branch
        CASE 
            WHEN led.LabEntryDetailId IS NOT NULL THEN 1 
            ELSE 0 
        END AS HasReportEntry,
        ISNULL(res.StatusName, 'Pending Entry') AS ReportStatusName
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid AND lo.IsActive = 1
    INNER JOIN dbo.PatientMaster p ON p.PatientId = sc.PatientID
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.SampleCollectionStatus scs ON scs.StatusID = sc.CollectionstatusID
    LEFT JOIN dbo.Branchmaster srcB ON srcB.BranchID = ISNULL(sc.SourceBranchID, sc.BranchID)
    LEFT JOIN dbo.Branchmaster tgtB ON tgtB.BranchID = sc.TargetBranchID
    LEFT JOIN dbo.Users u ON u.Id = sc.TransferredBy
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT JOIN dbo.Reportentrystatus res ON res.ReportStatusId = led.ReportStatusId
    WHERE sc.Is_Active = 1
      AND sc.Iscancelled = 0
      AND sc.CollectionstatusID = 2 -- Only collected samples can be transferred!
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND (
          (@NormFilter = 'READY' AND ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @SourceBranchId)
          OR (@NormFilter = 'TRANSFERRED' AND sc.IsTransferred = 1 AND sc.SourceBranchID = @SourceBranchId)
          OR (@NormFilter = 'ALL' AND (
              (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @SourceBranchId)
              OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @SourceBranchId)
          ))
      )
      AND (
          (@DateFilterType = 'CollectionDate' AND sc.Samplecollectiondate BETWEEN CAST(@FromDate AS DATE) AND CAST(@ToDate AS DATE))
          OR (@DateFilterType = 'BookingDate' AND ISNULL(lo.BookingDate, sc.Bookingdatetime) BETWEEN @FromDate AND @ToDate)
          OR (@DateFilterType = 'OrderDate' AND lo.OrderDate BETWEEN @FromDate AND @ToDate)
      )
      AND (
          @DepartmentId IS NULL OR sc.DepartmentID = @DepartmentId OR lim.Department_ID = @DepartmentId
      )
      AND (
          @CategoryId IS NULL OR sc.TestcategoryID = @CategoryId OR lim.Category_ID = @CategoryId
      )
      AND (
          @SubCategoryId IS NULL OR sc.TestsubcategoryID = @SubCategoryId OR lim.SubCategory_ID = @SubCategoryId
      )
      AND (
          @Search IS NULL OR LTRIM(RTRIM(@Search)) = ''
          OR lo.BillNo LIKE '%' + @Search + '%'
          OR lo.TokenNo LIKE '%' + @Search + '%'
          OR sc.BarcodeNo LIKE '%' + @Search + '%'
          OR p.PatientCode LIKE '%' + @Search + '%'
          OR p.FirstName LIKE '%' + @Search + '%'
          OR p.LastName LIKE '%' + @Search + '%'
          OR p.PhoneNumber LIKE '%' + @Search + '%'
          OR lim.Test_Name LIKE '%' + @Search + '%'
          OR lim.Test_Code LIKE '%' + @Search + '%'
      )
    ORDER BY 
        sc.IsTransferred ASC,
        sc.Samplecollectiondate DESC,
        sc.Samplecollectiontime DESC,
        sc.samplecollectionID DESC;
END;
GO
