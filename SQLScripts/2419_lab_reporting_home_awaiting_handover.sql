-- ============================================================================================================
-- 2419  Lab Report Entry, Home Collection with Hospital Settings > "Is Phlebotomist App Required" = Yes (after 2418):
--       an order comes for result entry only once the phlebotomist app marks it HANDED OVER (as on the Sample
--       Collection screen, 2418): usp_LabReporting_GetHeaderList leaves it out, usp_LabReporting_SaveEntry refuses it.
--       Lab orders, B2B and branches without the app are as before. Re-runnable.
-- ============================================================================================================
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
    @AllowedDepartmentIds NVARCHAR(MAX) = NULL,
    @ReportingType   NVARCHAR(50)  = 'Numeric'
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
            MIN(CASE WHEN sc.CollectionstatusID = 2 AND sc.Samplecollectiondate IS NOT NULL
                     THEN CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME) END) AS MinCollectionDateTime,
            MAX(CASE WHEN sc.IsTransferred = 1 THEN 1 ELSE 0 END) AS HasTransferredSamples,
            MAX(CASE WHEN sc.IsTransferred = 1 THEN sc.SourceBranchID ELSE NULL END) AS TransferredSourceBranchId,
            MAX(CASE WHEN sc.IsTransferred = 1 THEN sc.TransferredDate ELSE NULL END) AS TransferredDate
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
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
          AND (@ReportingType IS NULL OR dbo.ufn_Lab_ReportingTypeKey(lim.Reporting_Type, sc.ProfileId) = LOWER(LTRIM(RTRIM(@ReportingType))))
          AND (@RestrictDept = 0 OR sc.DepartmentID IN (SELECT DeptId FROM @AllowedDept))
        GROUP BY sc.Laborderid
        HAVING SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) > 0
           -- 2419: a Home Collection (Phlebotomist App branch) comes for reporting only once it is handed over to the lab
           AND dbo.fn_LabHomeCollectionHold(sc.Laborderid) IS NULL
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
                     AND (@ReportingType IS NULL OR dbo.ufn_Lab_ReportingTypeKey(lim_f.Reporting_Type, sc_f.ProfileId) = LOWER(LTRIM(RTRIM(@ReportingType))))
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
        INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
        LEFT JOIN dbo.Reportentrystatus res ON res.ReportStatusId = led.ReportStatusId
        WHERE (@ReportingType IS NULL OR dbo.ufn_Lab_ReportingTypeKey(lim.Reporting_Type, sc.ProfileId) = LOWER(LTRIM(RTRIM(@ReportingType))))
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
        ra.TotalEnteredCount,
        ra.DraftCount,
        ra.EntryCount,
        ra.ValidatedCount,
        ra.ApprovedCount,
        eo.HasTransferredSamples,
        eo.TransferredSourceBranchId,
        eo.TransferredDate
    INTO #FinalOrders
    FROM EligibleOrders eo
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = eo.Laborderid
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN ReportAggregates ra ON ra.Laborderid = eo.Laborderid
    WHERE (
        (@DateFilterType = 'BookingDate' AND ISNULL(lo.BookingDate, eo.MinBookingDateTime) BETWEEN @FromDate AND @ToDate)
        OR (@DateFilterType = 'OrderDate' AND lo.OrderDate BETWEEN @FromDate AND @ToDate)
        OR (@DateFilterType = 'CollectionDate' AND eo.MinCollectionDateTime BETWEEN @FromDate AND @ToDate)
    )
    AND (
        @Search IS NULL 
        OR lo.BillNo LIKE '%' + @Search + '%'
        OR lo.TokenNo LIKE '%' + @Search + '%'
        OR p.PatientCode LIKE '%' + @Search + '%'
        OR p.FirstName LIKE '%' + @Search + '%'
        OR p.LastName LIKE '%' + @Search + '%'
        OR p.PhoneNumber LIKE '%' + @Search + '%'
    );

    -- RS 1: Summary Statistics (names read by both screens: TotalOrders, PendingOrders, DraftOrders, EnteredOrders, ValidatedOrders)
    SELECT
        COUNT(1) AS TotalOrders,
        SUM(CASE WHEN ReportStatusName = 'Pending Entry' THEN 1 ELSE 0 END) AS PendingOrders,
        SUM(CASE WHEN ReportStatusName = 'Draft' THEN 1 ELSE 0 END) AS DraftOrders,
        SUM(CASE WHEN ReportStatusName = 'Report Entry' THEN 1 ELSE 0 END) AS EnteredOrders,
        SUM(CASE WHEN ReportStatusName = 'Report Validated' THEN 1 ELSE 0 END) AS ValidatedOrders,
        SUM(CASE WHEN ReportStatusName = 'Report Approve' THEN 1 ELSE 0 END) AS ApprovedOrders
    FROM #FinalOrders;

    -- RS 2: Orders of the clicked card - its status name as the screens send it ("Pending Entry", "Report Entry", ...)
    --        or the short code (Pending, Entered, Validated, Approved)
    DECLARE @NormalizedStatus VARCHAR(50) = UPPER(LTRIM(RTRIM(ISNULL(@StatusFilter, 'ALL'))));

    SELECT *
    FROM #FinalOrders
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

    DROP TABLE #FinalOrders;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_SaveEntry
    @LabOrderId         INT,
    @ReportStatusId     INT,
    @UserId             INT,
    @EntriesJson        NVARCHAR(MAX),
    @GroupRemarksJson   NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    DECLARE @StatusCode VARCHAR(30);
    SELECT @StatusCode = StatusCode FROM dbo.Reportentrystatus WHERE ReportStatusId = @ReportStatusId;

    IF @StatusCode IS NULL
    BEGIN
        RAISERROR('Invalid ReportStatusId.', 16, 1);
        RETURN;
    END

    DECLARE @PatientId INT;
    SELECT @PatientId = PatientId FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId;

    IF @PatientId IS NULL
    BEGIN
        RAISERROR('LabOrder not found.', 16, 1);
        RETURN;
    END


    -- 2419: results only once a Home Collection (Phlebotomist App branch) is handed over to the lab
    DECLARE @HoldMsg NVARCHAR(400) = dbo.fn_LabHomeCollectionHold(@LabOrderId);
    IF @HoldMsg IS NOT NULL BEGIN RAISERROR(@HoldMsg, 16, 1); RETURN; END
    -- Temporary table for parsed entries
    CREATE TABLE #ParsedEntries (
        SamplecollectionID BIGINT,
        InvestigationID    INT,
        TestValue          NVARCHAR(MAX),
        Remarks            NVARCHAR(500),
        Reporting_Type     NVARCHAR(100),
        AbnormalFlag       VARCHAR(20),
        Template_Html      NVARCHAR(MAX)
    );

    INSERT INTO #ParsedEntries (SamplecollectionID, InvestigationID, TestValue, Remarks, Reporting_Type, AbnormalFlag, Template_Html)
    SELECT 
        COALESCE(j.samplecollectionID, j.SamplecollectionID, j.samplecollectionId, j.SampleCollectionId, 0),
        COALESCE(j.investigationID, j.InvestigationID, j.investigationId, 0),
        COALESCE(j.testValue, j.TestValue, ''),
        COALESCE(j.remarks, j.Remarks, ''),
        COALESCE(j.reportingType, j.ReportingType, j.reporting_type, j.Reporting_Type, ''),
        COALESCE(j.abnormalFlag, j.AbnormalFlag, j.flag, j.Flag, NULL),
        COALESCE(j.templateHtml, j.TemplateHtml, j.template_html, j.Template_Html, NULL)
    FROM OPENJSON(@EntriesJson)
    WITH (
        samplecollectionID BIGINT        '$.samplecollectionID',
        SamplecollectionID BIGINT        '$.SamplecollectionID',
        samplecollectionId BIGINT        '$.samplecollectionId',
        SampleCollectionId BIGINT        '$.SampleCollectionId',
        investigationID    INT           '$.investigationID',
        InvestigationID    INT           '$.InvestigationID',
        investigationId    INT           '$.investigationId',
        testValue          NVARCHAR(MAX) '$.testValue',
        TestValue          NVARCHAR(MAX) '$.TestValue',
        remarks            NVARCHAR(500) '$.remarks',
        Remarks            NVARCHAR(500) '$.Remarks',
        reportingType      NVARCHAR(100) '$.reportingType',
        ReportingType      NVARCHAR(100) '$.ReportingType',
        reporting_type     NVARCHAR(100) '$.reporting_type',
        Reporting_Type     NVARCHAR(100) '$.Reporting_Type',
        abnormalFlag       VARCHAR(20)   '$.abnormalFlag',
        AbnormalFlag       VARCHAR(20)   '$.AbnormalFlag',
        flag               VARCHAR(20)   '$.flag',
        Flag               VARCHAR(20)   '$.Flag',
        templateHtml       NVARCHAR(MAX) '$.templateHtml',
        TemplateHtml       NVARCHAR(MAX) '$.TemplateHtml',
        template_html      NVARCHAR(MAX) '$.template_html',
        Template_Html      NVARCHAR(MAX) '$.Template_Html'
    ) j
    WHERE COALESCE(j.samplecollectionID, j.SamplecollectionID, j.samplecollectionId, j.SampleCollectionId, 0) > 0;

    -- 2252: a parameter whose internal QC is rejected (no corrective action yet) cannot be validated or approved
    IF @ReportStatusId IN (3, 5) OR @StatusCode IN ('REPORT_VALIDATED', 'REPORT_APPROVE', 'REPORT_APPROVED')
    BEGIN
        DECLARE @IqcIds NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(SamplecollectionID AS VARCHAR(20)), ',') FROM #ParsedEntries
                                         WHERE LTRIM(RTRIM(ISNULL(TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(Template_Html, ''))) <> '');
        DECLARE @IqcMsg NVARCHAR(1000);
        IF @IqcIds IS NOT NULL EXEC dbo.usp_Iqc_BlockMessage @LabOrderId, @IqcIds, @IqcMsg OUTPUT;
        IF @IqcMsg IS NOT NULL THROW 55050, @IqcMsg, 1;
    END

    DECLARE @Now DATETIME = GETDATE();

    -- Update existing records in labentrydetails
    -- FREEZE LOGIC: 
    -- 1. If led.ReportStatusId = 5, do NOT update.
    -- 2. If content is unchanged and led.ReportStatusId >= @ReportStatusId, do NOT regress the status.
    UPDATE led
    SET 
        led.TestValue      = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' THEN pe.TestValue
                                WHEN LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) <> '' AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'Report Entered'
                                ELSE led.TestValue
                             END,
        led.Remarks        = pe.Remarks,
        led.Reporting_Type = COALESCE(NULLIF(pe.Reporting_Type, ''), led.Reporting_Type, lim.Reporting_Type, 'Numeric'),
        led.AbnormalFlag   = pe.AbnormalFlag,
        led.Template_Html  = COALESCE(pe.Template_Html, led.Template_Html),
        led.ReportStatusId = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' AND LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) = '' AND LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) = '' THEN NULL
                                -- If test value or template html has changed, apply the new status
                                WHEN ISNULL(led.TestValue, '') <> pe.TestValue OR (pe.Template_Html IS NOT NULL AND ISNULL(led.Template_Html, '') <> pe.Template_Html) THEN @ReportStatusId
                                -- If test value/template is the same, but the new status is higher, progress it
                                WHEN @ReportStatusId > ISNULL(led.ReportStatusId, 0) THEN @ReportStatusId
                                -- Otherwise keep existing status
                                ELSE led.ReportStatusId
                             END,
        led.ModifiedBy     = @UserId,
        led.ModifiedDate   = @Now,
        led.Drafted_Date   = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' AND LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) = '' AND LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) = '' THEN NULL
                                WHEN (ISNULL(led.TestValue, '') <> pe.TestValue OR (pe.Template_Html IS NOT NULL AND ISNULL(led.Template_Html, '') <> pe.Template_Html)) AND (@ReportStatusId = 1 OR @StatusCode = 'DRAFT') THEN @Now
                                WHEN @ReportStatusId > ISNULL(led.ReportStatusId, 0) AND (@ReportStatusId = 1 OR @StatusCode = 'DRAFT') THEN @Now
                                ELSE led.Drafted_Date 
                             END,
        led.Submitted_Date = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' AND LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) = '' AND LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) = '' THEN NULL
                                WHEN (ISNULL(led.TestValue, '') <> pe.TestValue OR (pe.Template_Html IS NOT NULL AND ISNULL(led.Template_Html, '') <> pe.Template_Html)) AND (@ReportStatusId = 2 OR @StatusCode = 'REPORT_ENTRY') THEN @Now
                                WHEN @ReportStatusId > ISNULL(led.ReportStatusId, 0) AND (@ReportStatusId = 2 OR @StatusCode = 'REPORT_ENTRY') THEN @Now
                                ELSE led.Submitted_Date 
                             END,
        led.Validated_date = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' AND LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) = '' AND LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) = '' THEN NULL
                                WHEN (ISNULL(led.TestValue, '') <> pe.TestValue OR (pe.Template_Html IS NOT NULL AND ISNULL(led.Template_Html, '') <> pe.Template_Html)) AND (@ReportStatusId = 3 OR @StatusCode = 'REPORT_VALIDATED') THEN @Now
                                WHEN @ReportStatusId > ISNULL(led.ReportStatusId, 0) AND (@ReportStatusId = 3 OR @StatusCode = 'REPORT_VALIDATED') THEN @Now
                                ELSE led.Validated_date 
                             END,
        led.Approved_Date  = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' AND LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) = '' AND LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) = '' THEN NULL
                                WHEN (ISNULL(led.TestValue, '') <> pe.TestValue OR (pe.Template_Html IS NOT NULL AND ISNULL(led.Template_Html, '') <> pe.Template_Html)) AND (@ReportStatusId = 5 OR @StatusCode IN ('REPORT_APPROVE', 'REPORT_APPROVED')) THEN @Now
                                WHEN @ReportStatusId > ISNULL(led.ReportStatusId, 0) AND (@ReportStatusId = 5 OR @StatusCode IN ('REPORT_APPROVE', 'REPORT_APPROVED')) THEN @Now
                                ELSE led.Approved_Date 
                             END,
        led.IsActive       = 1
    FROM dbo.labentrydetails led
    INNER JOIN #ParsedEntries pe ON pe.SamplecollectionID = led.SamplecollectionID
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = pe.InvestigationID
    WHERE ISNULL(led.ReportStatusId, 0) < 5; -- FREEZE APPROVED ROWS completely

    -- Insert new records that don't exist yet
    INSERT INTO dbo.labentrydetails (
        SamplecollectionID,
        LabOrderId,
        PatientId,
        InvestigationID,
        TestValue,
        Remarks,
        AbnormalFlag,
        ReportStatusId,
        Reporting_Type,
        Template_Html,
        Drafted_Date,
        Submitted_Date,
        Validated_date,
        Approved_Date,
        CreatedBy,
        CreatedDate,
        IsActive
    )
    SELECT 
        pe.SamplecollectionID,
        @LabOrderId,
        @PatientId,
        pe.InvestigationID,
        CASE 
            WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' THEN pe.TestValue
            WHEN LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) <> '' THEN 'Report Entered'
            ELSE ''
        END,
        pe.Remarks,
        pe.AbnormalFlag,
        CASE 
            WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) <> '' THEN @ReportStatusId 
            ELSE NULL 
        END,
        COALESCE(NULLIF(pe.Reporting_Type, ''), lim.Reporting_Type, 'Numeric'),
        pe.Template_Html,
        CASE WHEN (LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) <> '') AND (@ReportStatusId = 1 OR @StatusCode = 'DRAFT') THEN @Now ELSE NULL END,
        CASE WHEN (LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) <> '') AND (@ReportStatusId = 2 OR @StatusCode = 'REPORT_ENTRY') THEN @Now ELSE NULL END,
        CASE WHEN (LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) <> '') AND (@ReportStatusId = 3 OR @StatusCode = 'REPORT_VALIDATED') THEN @Now ELSE NULL END,
        CASE WHEN (LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(pe.Template_Html, ''))) <> '') AND (@ReportStatusId = 5 OR @StatusCode IN ('REPORT_APPROVE', 'REPORT_APPROVED')) THEN @Now ELSE NULL END,
        @UserId,
        @Now,
        1
    FROM #ParsedEntries pe
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = pe.SamplecollectionID
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = pe.InvestigationID
    WHERE led.SamplecollectionID IS NULL;

    -- Process Group Remarks
    IF @GroupRemarksJson IS NOT NULL AND LTRIM(RTRIM(@GroupRemarksJson)) <> ''
    BEGIN
        CREATE TABLE #ParsedRemarks (
            GroupKey        VARCHAR(50),
            HeaderName      VARCHAR(255),
            ProfileId       INT,
            InvestigationId INT,
            LabRemarks      NVARCHAR(MAX)
        );

        INSERT INTO #ParsedRemarks (GroupKey, HeaderName, ProfileId, InvestigationId, LabRemarks)
        SELECT 
            COALESCE(r.GroupKey, r.groupKey, ''),
            COALESCE(r.HeaderName, r.headerName, ''),
            COALESCE(r.ProfileId, r.profileId, 0),
            COALESCE(r.InvestigationId, r.investigationId, 0),
            COALESCE(r.LabRemarks, r.labRemarks, '')
        FROM OPENJSON(@GroupRemarksJson)
        WITH (
            GroupKey        VARCHAR(50)   '$.GroupKey',
            groupKey        VARCHAR(50)   '$.groupKey',
            HeaderName      VARCHAR(255)  '$.HeaderName',
            headerName      VARCHAR(255)  '$.headerName',
            ProfileId       INT           '$.ProfileId',
            profileId       INT           '$.profileId',
            InvestigationId INT           '$.InvestigationId',
            investigationId INT           '$.investigationId',
            LabRemarks      NVARCHAR(MAX) '$.LabRemarks',
            labRemarks      NVARCHAR(MAX) '$.labRemarks'
        ) r;

        UPDATE rm
        SET 
            rm.LabRemarks = pr.LabRemarks,
            rm.ModifiedBy = @UserId,
            rm.ModifiedDate = @Now,
            rm.IsActive = CASE WHEN LTRIM(RTRIM(ISNULL(pr.LabRemarks, ''))) = '' THEN 0 ELSE 1 END
        FROM dbo.LabReportTestRemarks rm
        INNER JOIN #ParsedRemarks pr ON pr.GroupKey = rm.GroupKey
        WHERE rm.LabOrderId = @LabOrderId;

        INSERT INTO dbo.LabReportTestRemarks (
            LabOrderId, GroupKey, HeaderName, ProfileId, InvestigationId, LabRemarks, CreatedBy, CreatedDate, IsActive
        )
        SELECT 
            @LabOrderId, pr.GroupKey, pr.HeaderName, pr.ProfileId, pr.InvestigationId, pr.LabRemarks, @UserId, @Now, 1
        FROM #ParsedRemarks pr
        LEFT JOIN dbo.LabReportTestRemarks rm ON rm.GroupKey = pr.GroupKey AND rm.LabOrderId = @LabOrderId
        WHERE rm.RemarkId IS NULL
          AND LTRIM(RTRIM(ISNULL(pr.LabRemarks, ''))) <> '';

        -- Also sync to labentrydetails for convenient direct querying
        UPDATE led
        SET 
            led.LabRemarks = rem.LabRemarks,
            led.ModifiedBy = @UserId,
            led.ModifiedDate = @Now
        FROM dbo.labentrydetails led
        INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = led.SamplecollectionID
        INNER JOIN dbo.LabReportTestRemarks rem ON rem.LabOrderId = sc.Laborderid
        WHERE rem.LabOrderId = @LabOrderId
          AND rem.IsActive = 1
          AND (
              (sc.ProfileId IS NOT NULL AND rem.GroupKey = 'PRF_' + CAST(sc.ProfileId AS VARCHAR(20)))
              OR
              (sc.ProfileId IS NULL AND rem.GroupKey = 'INV_' + CAST(sc.InvestigationID AS VARCHAR(20)))
          );
    END;

    -- 2246: BOM consumption of the tests submitted now (Quality & Compliance); it never stops the result from being saved
    BEGIN TRY
        EXEC dbo.usp_Qc_Consume_Sync @LabOrderId = @LabOrderId, @UserId = @UserId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        BEGIN TRY
            INSERT INTO dbo.QcConsumptionLog (LabOrderId, ErrorNumber, ErrorMessage) VALUES (@LabOrderId, ERROR_NUMBER(), LEFT(ERROR_MESSAGE(), 2000));
        END TRY
        BEGIN CATCH
        END CATCH
    END CATCH

    -- Return 1 on success
    SELECT 1 AS Result;
END;
GO
PRINT 'Script 2419 applied: Lab Report Entry waits for home-collection hand-over.';
GO
