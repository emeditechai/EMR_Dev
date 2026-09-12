-- ====================================================================================================
-- Script: 2045_lab_reporting_entry_tables_and_sps.sql
-- Description: Creates dbo.Reportentrystatus and dbo.labentrydetails tables,
--              along with Stored Procedures for the Lab Reporting Entry screen.
-- ====================================================================================================

-- ── 1. Create dbo.Reportentrystatus Table ──────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Reportentrystatus' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.Reportentrystatus (
        ReportStatusId INT IDENTITY(1,1) PRIMARY KEY,
        StatusCode     VARCHAR(30)   NOT NULL UNIQUE,
        StatusName     NVARCHAR(50)  NOT NULL,
        BadgeClass     VARCHAR(100)  NOT NULL DEFAULT 'bg-secondary text-white',
        DisplayOrder   INT           NOT NULL DEFAULT 0,
        IsActive       BIT           NOT NULL DEFAULT 1,
        CreatedDate    DATETIME      NOT NULL DEFAULT GETDATE()
    );

    PRINT 'Created table dbo.Reportentrystatus.';
END
GO

-- Seed Statuses
IF NOT EXISTS (SELECT 1 FROM dbo.Reportentrystatus WHERE StatusCode = 'DRAFT')
    INSERT INTO dbo.Reportentrystatus (StatusCode, StatusName, BadgeClass, DisplayOrder, IsActive)
    VALUES ('DRAFT', 'Draft', 'bg-warning-subtle text-warning border border-warning-subtle', 1, 1);

IF NOT EXISTS (SELECT 1 FROM dbo.Reportentrystatus WHERE StatusCode = 'REPORT_ENTRY')
    INSERT INTO dbo.Reportentrystatus (StatusCode, StatusName, BadgeClass, DisplayOrder, IsActive)
    VALUES ('REPORT_ENTRY', 'Report Entry', 'bg-primary-subtle text-primary border border-primary-subtle', 2, 1);

IF NOT EXISTS (SELECT 1 FROM dbo.Reportentrystatus WHERE StatusCode = 'REPORT_VALIDATED')
    INSERT INTO dbo.Reportentrystatus (StatusCode, StatusName, BadgeClass, DisplayOrder, IsActive)
    VALUES ('REPORT_VALIDATED', 'Report Validated', 'bg-success-subtle text-success border border-success-subtle', 3, 1);

IF NOT EXISTS (SELECT 1 FROM dbo.Reportentrystatus WHERE StatusCode = 'RE_COLLECTED')
    INSERT INTO dbo.Reportentrystatus (StatusCode, StatusName, BadgeClass, DisplayOrder, IsActive)
    VALUES ('RE_COLLECTED', 'Re Collected', 'bg-danger-subtle text-danger border border-danger-subtle', 4, 1);
GO

-- ── 2. Create dbo.labentrydetails Table ─────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'labentrydetails' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.labentrydetails (
        LabEntryDetailId   BIGINT IDENTITY(1,1) PRIMARY KEY,
        SamplecollectionID BIGINT        NOT NULL,
        LabOrderId         INT           NOT NULL,
        PatientId          INT           NOT NULL,
        InvestigationID    INT           NOT NULL,
        TestValue          NVARCHAR(MAX) NULL,
        Remarks            NVARCHAR(500) NULL,
        ReportStatusId     INT           NOT NULL,
        CreatedBy          INT           NULL,
        CreatedDate        DATETIME      NOT NULL DEFAULT GETDATE(),
        ModifiedBy         INT           NULL,
        ModifiedDate       DATETIME      NULL,
        IsActive           BIT           NOT NULL DEFAULT 1,
        CONSTRAINT FK_LabEntryDetails_SampleCollection FOREIGN KEY (SamplecollectionID) REFERENCES dbo.SampleCollection(samplecollectionID),
        CONSTRAINT FK_LabEntryDetails_LabOrder FOREIGN KEY (LabOrderId) REFERENCES dbo.LabOrder(LabOrderId),
        CONSTRAINT FK_LabEntryDetails_Status FOREIGN KEY (ReportStatusId) REFERENCES dbo.Reportentrystatus(ReportStatusId)
    );

    CREATE INDEX IX_LabEntryDetails_Order ON dbo.labentrydetails(LabOrderId);
    CREATE INDEX IX_LabEntryDetails_SampleCollection ON dbo.labentrydetails(SamplecollectionID);
    CREATE INDEX IX_LabEntryDetails_Status ON dbo.labentrydetails(ReportStatusId);

    PRINT 'Created table dbo.labentrydetails.';
END
GO

-- ── 3. Stored Procedure: dbo.usp_LabReporting_GetStatuses ──────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetStatuses
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        ReportStatusId,
        StatusCode,
        StatusName,
        BadgeClass,
        DisplayOrder,
        IsActive
    FROM dbo.Reportentrystatus
    WHERE IsActive = 1
    ORDER BY DisplayOrder, ReportStatusId;
END
GO

-- ── 4. Stored Procedure: dbo.usp_LabReporting_GetHeaderList ────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetHeaderList
    @BranchId        INT,
    @FromDate        DATETIME      = NULL,
    @ToDate          DATETIME      = NULL,
    @DateFilterType  VARCHAR(20)   = 'BookingDate', -- 'BookingDate' or 'OrderDate'
    @StatusFilter    VARCHAR(50)   = 'All',         -- 'All', 'Pending Entry', 'Draft', 'Report Entry', 'Report Validated'
    @Search          NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Default Date Range: Today 00:00:00 to 23:59:59
    IF @FromDate IS NULL
        SET @FromDate = CAST(CAST(GETDATE() AS DATE) AS DATETIME);
    
    IF @ToDate IS NULL
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));
    ELSE IF CAST(@ToDate AS TIME) = '00:00:00'
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(@ToDate AS DATE) AS DATETIME));

    -- Aggregate eligible collected in-house tests from SampleCollection
    WITH EligibleOrders AS (
        SELECT 
            sc.Laborderid,
            -- Counts across in-house tests for this order
            COUNT(1) AS TotalInHouseTests,
            SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) AS CollectedInHouseTests,
            MIN(sc.Bookingdatetime) AS MinBookingDateTime,
            MIN(sc.Orderdate) AS MinOrderDate
        FROM dbo.SampleCollection sc
        WHERE sc.BranchID = @BranchId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND ISNULL(sc.IsoutSource, 0) = 0
        GROUP BY sc.Laborderid
        -- Order MUST have at least one collected in-house sample
        HAVING SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) > 0
    ),
    ReportAggregates AS (
        SELECT 
            eo.Laborderid,
            COUNT(led.LabEntryDetailId) AS TotalEnteredCount,
            SUM(CASE WHEN led.ReportStatusId = 1 THEN 1 ELSE 0 END) AS DraftCount,
            SUM(CASE WHEN led.ReportStatusId = 2 THEN 1 ELSE 0 END) AS EntryCount,
            SUM(CASE WHEN led.ReportStatusId = 3 THEN 1 ELSE 0 END) AS ValidatedCount
        FROM EligibleOrders eo
        INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = eo.Laborderid 
            AND sc.CollectionstatusID = 2 
            AND ISNULL(sc.IsoutSource, 0) = 0
            AND sc.Is_Active = 1 
            AND sc.Iscancelled = 0
        LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
        GROUP BY eo.Laborderid
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
        p.EmailId,
        lo.OrderDate,
        ISNULL(lo.BookingDate, eo.MinBookingDateTime) AS BookingDateTime,
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        eo.TotalInHouseTests,
        eo.CollectedInHouseTests,
        -- Dynamic Sample Collection Status:
        CASE 
            WHEN eo.CollectedInHouseTests >= eo.TotalInHouseTests THEN 'Collected'
            ELSE 'Partially Collected'
        END AS SampleCollectionStatus,
        -- Reporting Status:
        CASE 
            WHEN ra.TotalEnteredCount = 0 THEN 0
            WHEN ra.ValidatedCount = eo.CollectedInHouseTests AND eo.CollectedInHouseTests > 0 THEN 3
            WHEN ra.EntryCount > 0 AND (ra.EntryCount + ra.ValidatedCount) = eo.CollectedInHouseTests THEN 2
            WHEN ra.DraftCount > 0 OR ra.TotalEnteredCount > 0 THEN 1
            ELSE 0
        END AS ReportStatusId,
        CASE 
            WHEN ra.TotalEnteredCount = 0 THEN 'Pending Entry'
            WHEN ra.ValidatedCount = eo.CollectedInHouseTests AND eo.CollectedInHouseTests > 0 THEN 'Report Validated'
            WHEN ra.EntryCount > 0 AND (ra.EntryCount + ra.ValidatedCount) = eo.CollectedInHouseTests THEN 'Report Entry'
            WHEN ra.DraftCount > 0 OR ra.TotalEnteredCount > 0 THEN 'Draft'
            ELSE 'Pending Entry'
        END AS ReportStatusName,
        CASE 
            WHEN ra.TotalEnteredCount = 0 THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            WHEN ra.ValidatedCount = eo.CollectedInHouseTests AND eo.CollectedInHouseTests > 0 THEN 'bg-success-subtle text-success border border-success-subtle'
            WHEN ra.EntryCount > 0 AND (ra.EntryCount + ra.ValidatedCount) = eo.CollectedInHouseTests THEN 'bg-primary-subtle text-primary border border-primary-subtle'
            WHEN ra.DraftCount > 0 OR ra.TotalEnteredCount > 0 THEN 'bg-warning-subtle text-warning border border-warning-subtle'
            ELSE 'bg-secondary-subtle text-secondary border border-secondary-subtle'
        END AS ReportBadgeClass
    INTO #FilteredReportOrders
    FROM EligibleOrders eo
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = eo.Laborderid AND lo.IsActive = 1
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN ReportAggregates ra ON ra.Laborderid = eo.Laborderid
    WHERE lo.BranchId = @BranchId
      AND (
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

    -- Result Set 1: Summary Stats
    SELECT 
        COUNT(1) AS TotalOrders,
        SUM(CASE WHEN ReportStatusName = 'Pending Entry' THEN 1 ELSE 0 END) AS PendingOrders,
        SUM(CASE WHEN ReportStatusName = 'Draft' THEN 1 ELSE 0 END) AS DraftOrders,
        SUM(CASE WHEN ReportStatusName = 'Report Entry' THEN 1 ELSE 0 END) AS EnteredOrders,
        SUM(CASE WHEN ReportStatusName = 'Report Validated' THEN 1 ELSE 0 END) AS ValidatedOrders
    FROM #FilteredReportOrders;

    -- Result Set 2: Header Rows (filtered by status if requested)
    DECLARE @NormalizedStatus VARCHAR(50) = UPPER(LTRIM(RTRIM(ISNULL(@StatusFilter, 'ALL'))));

    SELECT *
    FROM #FilteredReportOrders
    WHERE (
        @NormalizedStatus = 'ALL'
        OR (@NormalizedStatus IN ('PENDING', 'PENDING ENTRY') AND ReportStatusName = 'Pending Entry')
        OR (@NormalizedStatus = 'DRAFT' AND ReportStatusName = 'Draft')
        OR (@NormalizedStatus IN ('REPORT ENTRY', 'ENTRY', 'ENTERED') AND ReportStatusName = 'Report Entry')
        OR (@NormalizedStatus IN ('REPORT VALIDATED', 'VALIDATED') AND ReportStatusName = 'Report Validated')
    )
    ORDER BY 
        IsUrgent DESC,
        BookingDateTime DESC,
        LabOrderId DESC;

    DROP TABLE #FilteredReportOrders;
END
GO

-- ── 5. Stored Procedure: dbo.usp_LabReporting_GetDetail ────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    -- RS 1: Patient and Lab Order Information
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
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS 2: Eligible Collected In-House Investigation Items for this Order
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
        ISNULL(u.Unit_Name, '') AS UnitName,
        ISNULL(lim.Reporting_Type, 'Numeric') AS ReportingType,
        sc.BarcodeNo,
        sc.Samplecollectiondate,
        sc.Samplecollectiontime,
        sc.ProfileId,
        sc.ProfileName,
        sc.PackageId,
        sc.PackageName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName, '—') AS ProfilePackageName,
        led.LabEntryDetailId,
        led.TestValue,
        led.Remarks,
        ISNULL(led.ReportStatusId, 0) AS ReportStatusId,
        ISNULL(res.StatusName, 'Pending Entry') AS ReportStatusName,
        ISNULL(res.BadgeClass, 'bg-secondary-subtle text-secondary border border-secondary-subtle') AS ReportBadgeClass,
        led.ModifiedDate AS LastSavedDate
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.LabUnitMaster u ON u.Unit_ID = lim.Unit_ID
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT JOIN dbo.Reportentrystatus res ON res.ReportStatusId = led.ReportStatusId
    WHERE sc.Laborderid = @LabOrderId
      AND sc.CollectionstatusID = 2
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND sc.Is_Active = 1
      AND sc.Iscancelled = 0
    ORDER BY 
        COALESCE(sc.ProfileName, sc.PackageName, 'ZZZ'),
        ISNULL(stm.Sample_Name, ''),
        lim.Test_Name;
END
GO

-- ── 6. Stored Procedure: dbo.usp_LabReporting_SaveEntry ───────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_SaveEntry
    @LabOrderId     INT,
    @ReportStatusId INT,
    @UserId         INT,
    @EntriesJson    NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Reportentrystatus WHERE ReportStatusId = @ReportStatusId)
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

    -- Temporary table for parsed entries
    CREATE TABLE #ParsedEntries (
        SamplecollectionID BIGINT,
        InvestigationID    INT,
        TestValue          NVARCHAR(MAX),
        Remarks            NVARCHAR(500)
    );

    INSERT INTO #ParsedEntries (SamplecollectionID, InvestigationID, TestValue, Remarks)
    SELECT 
        COALESCE(j.samplecollectionID, j.SamplecollectionID, j.samplecollectionId, j.SampleCollectionId, 0),
        COALESCE(j.investigationID, j.InvestigationID, j.investigationId, 0),
        COALESCE(j.testValue, j.TestValue, ''),
        COALESCE(j.remarks, j.Remarks, '')
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
        Remarks            NVARCHAR(500) '$.Remarks'
    ) j
    WHERE COALESCE(j.samplecollectionID, j.SamplecollectionID, j.samplecollectionId, j.SampleCollectionId, 0) > 0;

    -- Update existing records
    UPDATE led
    SET 
        led.TestValue      = pe.TestValue,
        led.Remarks        = pe.Remarks,
        led.ReportStatusId = @ReportStatusId,
        led.ModifiedBy     = @UserId,
        led.ModifiedDate   = GETDATE(),
        led.IsActive       = 1
    FROM dbo.labentrydetails led
    INNER JOIN #ParsedEntries pe ON pe.SamplecollectionID = led.SamplecollectionID;

    -- Insert new records that don't exist yet
    INSERT INTO dbo.labentrydetails (
        SamplecollectionID,
        LabOrderId,
        PatientId,
        InvestigationID,
        TestValue,
        Remarks,
        ReportStatusId,
        CreatedBy,
        CreatedDate,
        IsActive
    )
    SELECT 
        pe.SamplecollectionID,
        @LabOrderId,
        @PatientId,
        pe.InvestigationID,
        pe.TestValue,
        pe.Remarks,
        @ReportStatusId,
        @UserId,
        GETDATE(),
        1
    FROM #ParsedEntries pe
    WHERE NOT EXISTS (
        SELECT 1 
        FROM dbo.labentrydetails led 
        WHERE led.SamplecollectionID = pe.SamplecollectionID
    );

    DECLARE @SavedCount INT = (SELECT COUNT(1) FROM #ParsedEntries);
    DROP TABLE #ParsedEntries;

    SELECT @SavedCount AS SavedCount;
END
GO
