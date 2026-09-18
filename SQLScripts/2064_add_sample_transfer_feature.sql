-- ============================================================================
-- Migration: 2064_add_sample_transfer_feature.sql
-- Description:
--   1. Adds transfer columns to dbo.SampleCollection (SourceBranchID, TargetBranchID,
--      IsTransferred, TransferredDate, TransferredBy, TransferRemarks).
--   2. Creates dbo.SampleTransferAudit table for complete audit history.
--   3. Creates dbo.usp_SampleTransfer_GetEligibleSamples.
--   4. Creates dbo.usp_SampleTransfer_ExecuteTransfer.
--   5. Creates dbo.usp_SampleTransfer_GetHistory.
--   6. Updates dbo.usp_LabReporting_GetHeaderList to route transferred samples to
--      target branch and hide them from source branch, with transfer metadata.
--   7. Updates dbo.usp_LabReporting_GetDetail to return transfer metadata.
-- ============================================================================

USE [Dev_EMR];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Add Transfer Columns to dbo.SampleCollection ─────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.SampleCollection') AND name = 'SourceBranchID')
BEGIN
    ALTER TABLE dbo.SampleCollection ADD SourceBranchID INT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.SampleCollection') AND name = 'TargetBranchID')
BEGIN
    ALTER TABLE dbo.SampleCollection ADD TargetBranchID INT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.SampleCollection') AND name = 'IsTransferred')
BEGIN
    ALTER TABLE dbo.SampleCollection ADD IsTransferred BIT NOT NULL CONSTRAINT DF_SampleCollection_IsTransferred DEFAULT 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.SampleCollection') AND name = 'TransferredDate')
BEGIN
    ALTER TABLE dbo.SampleCollection ADD TransferredDate DATETIME NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.SampleCollection') AND name = 'TransferredBy')
BEGIN
    ALTER TABLE dbo.SampleCollection ADD TransferredBy INT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.SampleCollection') AND name = 'TransferRemarks')
BEGIN
    ALTER TABLE dbo.SampleCollection ADD TransferRemarks NVARCHAR(500) NULL;
END
GO

-- Index for efficient routing in Lab Reporting and Transfer Worklist
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.SampleCollection') AND name = 'IX_SampleCollection_Transfer_Routing')
BEGIN
    CREATE NONCLUSTERED INDEX IX_SampleCollection_Transfer_Routing 
    ON dbo.SampleCollection (BranchID, TargetBranchID, IsTransferred, CollectionstatusID)
    INCLUDE (Laborderid, samplecollectionID, InvestigationID, BarcodeNo);
END
GO

-- ── 2. Create Audit Table: dbo.SampleTransferAudit ───────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'SampleTransferAudit')
BEGIN
    CREATE TABLE dbo.SampleTransferAudit (
        TransferAuditId     BIGINT IDENTITY(1,1) PRIMARY KEY,
        SampleCollectionId  BIGINT NOT NULL,
        LabOrderId          INT NOT NULL,
        SourceBranchId      INT NOT NULL,
        TargetBranchId      INT NOT NULL,
        BarcodeNo           NVARCHAR(50) NULL,
        InvestigationId     INT NOT NULL,
        TransferredBy       INT NOT NULL,
        TransferredDate     DATETIME NOT NULL CONSTRAINT DF_SampleTransferAudit_Date DEFAULT GETDATE(),
        TransferRemarks     NVARCHAR(500) NULL,
        CreatedDate         DATETIME NOT NULL CONSTRAINT DF_SampleTransferAudit_Created DEFAULT GETDATE()
    );

    CREATE NONCLUSTERED INDEX IX_SampleTransferAudit_SampleCollectionId ON dbo.SampleTransferAudit(SampleCollectionId);
    CREATE NONCLUSTERED INDEX IX_SampleTransferAudit_LabOrderId ON dbo.SampleTransferAudit(LabOrderId);
    CREATE NONCLUSTERED INDEX IX_SampleTransferAudit_Branches ON dbo.SampleTransferAudit(SourceBranchId, TargetBranchId, TransferredDate);
END
GO

-- ── 3. Stored Procedure: dbo.usp_SampleTransfer_GetEligibleSamples ────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleTransfer_GetEligibleSamples
    @SourceBranchId        INT,
    @FromDate              DATETIME      = NULL,
    @ToDate                DATETIME      = NULL,
    @DateFilterType        VARCHAR(20)   = 'CollectionDate', -- 'CollectionDate', 'BookingDate', 'OrderDate'
    @TransferStatusFilter  VARCHAR(20)   = 'Ready',          -- 'Ready', 'Transferred', 'All'
    @Search                NVARCHAR(100) = NULL
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
    WHERE (
        (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @SourceBranchId)
        OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @SourceBranchId)
    )
    AND sc.Is_Active = 1
    AND sc.Iscancelled = 0
    AND sc.CollectionstatusID = 2
    AND ISNULL(sc.IsoutSource, 0) = 0;

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

-- ── 4. Stored Procedure: dbo.usp_SampleTransfer_ExecuteTransfer ───────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleTransfer_ExecuteTransfer
    @SampleCollectionIds   NVARCHAR(MAX), -- Comma-separated samplecollectionIDs
    @SourceBranchId        INT,
    @TargetBranchId        INT,
    @TransferredBy         INT,
    @TransferRemarks       NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @SourceBranchId IS NULL OR @SourceBranchId <= 0
    BEGIN
        RAISERROR('Source branch is required.', 16, 1);
        RETURN;
    END

    IF @TargetBranchId IS NULL OR @TargetBranchId <= 0
    BEGIN
        RAISERROR('Target branch is required.', 16, 1);
        RETURN;
    END

    IF @SourceBranchId = @TargetBranchId
    BEGIN
        RAISERROR('Source branch and Target branch cannot be the same.', 16, 1);
        RETURN;
    END

    IF @SampleCollectionIds IS NULL OR LTRIM(RTRIM(@SampleCollectionIds)) = ''
    BEGIN
        RAISERROR('No samples selected for transfer.', 16, 1);
        RETURN;
    END

    -- Split incoming IDs into a temp table
    CREATE TABLE #SelectedSamples (SampleCollectionId BIGINT PRIMARY KEY);

    INSERT INTO #SelectedSamples (SampleCollectionId)
    SELECT DISTINCT CAST(LTRIM(RTRIM(value)) AS BIGINT)
    FROM STRING_SPLIT(@SampleCollectionIds, ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    DECLARE @TotalRequested INT = (SELECT COUNT(1) FROM #SelectedSamples);
    IF @TotalRequested = 0
    BEGIN
        RAISERROR('No valid sample IDs provided.', 16, 1);
        RETURN;
    END

    -- Validate that all selected samples are in Collected status (2) and currently at the SourceBranch
    DECLARE @EligibleCount INT;
    SELECT @EligibleCount = COUNT(1)
    FROM dbo.SampleCollection sc
    INNER JOIN #SelectedSamples ss ON ss.SampleCollectionId = sc.samplecollectionID
    WHERE sc.Is_Active = 1
      AND sc.Iscancelled = 0
      AND sc.CollectionstatusID = 2 -- Must be Collected!
      AND (sc.BranchID = @SourceBranchId OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @SourceBranchId));

    IF @EligibleCount <> @TotalRequested
    BEGIN
        RAISERROR('One or more selected samples are not in Collected status or do not belong to the source branch.', 16, 1);
        RETURN;
    END

    DECLARE @TransferredDate DATETIME = GETDATE();

    BEGIN TRANSACTION;
    BEGIN TRY
        -- 1. Insert into Audit History
        INSERT INTO dbo.SampleTransferAudit (
            SampleCollectionId,
            LabOrderId,
            SourceBranchId,
            TargetBranchId,
            BarcodeNo,
            InvestigationId,
            TransferredBy,
            TransferredDate,
            TransferRemarks,
            CreatedDate
        )
        SELECT 
            sc.samplecollectionID,
            sc.Laborderid,
            @SourceBranchId,
            @TargetBranchId,
            sc.BarcodeNo,
            sc.InvestigationID,
            @TransferredBy,
            @TransferredDate,
            @TransferRemarks,
            @TransferredDate
        FROM dbo.SampleCollection sc
        INNER JOIN #SelectedSamples ss ON ss.SampleCollectionId = sc.samplecollectionID;

        -- 2. Update SampleCollection records
        UPDATE sc
        SET 
            sc.IsTransferred    = 1,
            sc.SourceBranchID   = @SourceBranchId,
            sc.TargetBranchID   = @TargetBranchId,
            sc.TransferredDate  = @TransferredDate,
            sc.TransferredBy    = @TransferredBy,
            sc.TransferRemarks  = @TransferRemarks,
            sc.ModifiedBy       = @TransferredBy,
            sc.ModifiedDate     = @TransferredDate
        FROM dbo.SampleCollection sc
        INNER JOIN #SelectedSamples ss ON ss.SampleCollectionId = sc.samplecollectionID;

        COMMIT TRANSACTION;

        SELECT 
            1 AS IsSuccess,
            @EligibleCount AS TransferredCount,
            'Successfully transferred ' + CAST(@EligibleCount AS VARCHAR(10)) + ' sample(s) to target branch.' AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@ErrMsg, 16, 1);
    END CATCH;

    DROP TABLE #SelectedSamples;
END;
GO

-- ── 5. Stored Procedure: dbo.usp_SampleTransfer_GetHistory ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleTransfer_GetHistory
    @BranchId     INT,
    @Mode         VARCHAR(20) = 'Outgoing', -- 'Outgoing', 'Incoming', 'All'
    @FromDate     DATETIME    = NULL,
    @ToDate       DATETIME    = NULL,
    @Search       NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL
        SET @FromDate = DATEADD(DAY, -7, CAST(CAST(GETDATE() AS DATE) AS DATETIME));

    IF @ToDate IS NULL
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));
    ELSE IF CAST(@ToDate AS TIME) = '00:00:00'
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(@ToDate AS DATE) AS DATETIME));

    DECLARE @NormMode VARCHAR(20) = UPPER(LTRIM(RTRIM(ISNULL(@Mode, 'OUTGOING'))));

    SELECT 
        sta.TransferAuditId,
        sta.SampleCollectionId,
        sta.LabOrderId,
        sta.BarcodeNo,
        sta.InvestigationId,
        lim.Test_Code           AS TestCode,
        lim.Test_Name           AS TestName,
        ISNULL(ldm.DeptName, 'General') AS DepartmentName,
        ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        lo.BillNo,
        lo.TokenNo,
        sta.SourceBranchId,
        srcB.BranchName         AS SourceBranchName,
        sta.TargetBranchId,
        tgtB.BranchName         AS TargetBranchName,
        sta.TransferredDate,
        sta.TransferredBy,
        u.FullName              AS TransferredByName,
        sta.TransferRemarks,
        -- Status of reporting at target branch
        ISNULL(res.StatusName, 'Pending Entry') AS ReportStatusName
    FROM dbo.SampleTransferAudit sta
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = sta.SampleCollectionId
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sta.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sta.InvestigationId
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = lim.Department_ID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.Branchmaster srcB ON srcB.BranchID = sta.SourceBranchId
    LEFT JOIN dbo.Branchmaster tgtB ON tgtB.BranchID = sta.TargetBranchId
    LEFT JOIN dbo.Users u ON u.Id = sta.TransferredBy
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sta.SampleCollectionId AND led.IsActive = 1
    LEFT JOIN dbo.Reportentrystatus res ON res.ReportStatusId = led.ReportStatusId
    WHERE (
        (@NormMode = 'OUTGOING' AND sta.SourceBranchId = @BranchId)
        OR (@NormMode = 'INCOMING' AND sta.TargetBranchId = @BranchId)
        OR (@NormMode = 'ALL' AND (sta.SourceBranchId = @BranchId OR sta.TargetBranchId = @BranchId))
    )
    AND sta.TransferredDate BETWEEN @FromDate AND @ToDate
    AND (
        @Search IS NULL OR LTRIM(RTRIM(@Search)) = ''
        OR sta.BarcodeNo LIKE '%' + @Search + '%'
        OR lo.BillNo LIKE '%' + @Search + '%'
        OR p.PatientCode LIKE '%' + @Search + '%'
        OR p.FirstName LIKE '%' + @Search + '%'
        OR p.LastName LIKE '%' + @Search + '%'
        OR lim.Test_Name LIKE '%' + @Search + '%'
    )
    ORDER BY sta.TransferredDate DESC;
END;
GO

-- ── 6. Update Stored Procedure: dbo.usp_LabReporting_GetHeaderList ────────────
-- Routes transferred samples to target branch and hides them from source branch.
-- Returns transfer metadata (IsTransferred, SourceBranchId, SourceBranchName, TransferredDate).
CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetHeaderList
    @BranchId        INT,
    @FromDate        DATETIME      = NULL,
    @ToDate          DATETIME      = NULL,
    @DateFilterType  VARCHAR(20)   = 'BookingDate', -- 'BookingDate' or 'OrderDate'
    @StatusFilter    VARCHAR(50)   = 'All',         -- 'All', 'Pending Entry', 'Draft', 'Report Entry', 'Report Validated', 'Report Approve'
    @Search          NVARCHAR(100) = NULL,
    @DepartmentId    INT           = NULL,
    @CategoryId      INT           = NULL,
    @SubCategoryId   INT           = NULL
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
    -- CRITICAL LOGIC FOR TRANSFERRED SAMPLES:
    -- If sample is NOT transferred: reports at sc.BranchID
    -- If sample IS transferred: reports at sc.TargetBranchID (hidden from sc.SourceBranchID)
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
            -- OR sample transferred TO this branch from another branch
            OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId)
        )
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND ISNULL(sc.IsoutSource, 0) = 0
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
                         OR (sc_f.IsTransferred = 1 AND sc_f.TargetBranchID = @BranchId)
                     )
                     AND sc_f.Is_Active = 1
                     AND sc_f.Iscancelled = 0
                     AND ISNULL(sc_f.IsoutSource, 0) = 0
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
            AND (
                (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
                OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId)
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
        -- Transfer metadata for UI display
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
        OR (@NormalizedStatus IN ('REPORT APPROVE', 'REPORT APPROVED', 'APPROVE', 'APPROVED') AND ReportStatusName IN ('Report Approve', 'Report Approved'))
    )
    ORDER BY 
        IsUrgent DESC,
        BookingDateTime DESC,
        LabOrderId DESC;

    DROP TABLE #FilteredReportOrders;
END;
GO

-- ── 7. Update Stored Procedure: dbo.usp_LabReporting_GetDetail ────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Check if any sample was transferred for this order
    DECLARE @IsTransferred BIT = 0;
    DECLARE @SourceBranchId INT = NULL;
    DECLARE @SourceBranchName NVARCHAR(150) = NULL;
    DECLARE @TransferredDate DATETIME = NULL;
    DECLARE @TransferRemarks NVARCHAR(500) = NULL;

    SELECT TOP 1
        @IsTransferred = 1,
        @SourceBranchId = sc.SourceBranchID,
        @SourceBranchName = bm.BranchName,
        @TransferredDate = sc.TransferredDate,
        @TransferRemarks = sc.TransferRemarks
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = sc.SourceBranchID
    WHERE sc.Laborderid = @LabOrderId 
      AND sc.IsTransferred = 1;

    -- RS 1: Order and Patient Header Details
    SELECT 
        lo.LabOrderId,
        lo.BranchId,
        ISNULL(bm.BranchName, 'Main Branch') AS BranchName,
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
        lo.TotalAmount,
        -- Transfer information
        ISNULL(@IsTransferred, 0) AS IsTransferred,
        @SourceBranchId AS SourceBranchId,
        @SourceBranchName AS SourceBranchName,
        @TransferredDate AS TransferredDate,
        @TransferRemarks AS TransferRemarks
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
        COALESCE(led.Reporting_Type, lim.Reporting_Type, 'Numeric') AS ReportingType,
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
        led.Drafted_Date AS DraftedDate,
        led.Submitted_Date AS SubmittedDate,
        led.Validated_date AS ValidatedDate,
        led.Approved_Date AS ApprovedDate,
        led.ModifiedDate AS LastSavedDate,
        -- Sample transfer fields
        ISNULL(sc.IsTransferred, 0) AS IsTransferred,
        sc.SourceBranchID           AS SourceBranchId,
        srcB.BranchName             AS SourceBranchName,
        sc.TargetBranchID           AS TargetBranchId,
        tgtB.BranchName             AS TargetBranchName,
        sc.TransferredDate,
        sc.TransferRemarks
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.LabUnitMaster u ON u.Unit_ID = lim.Unit_ID
    LEFT JOIN dbo.Branchmaster srcB ON srcB.BranchID = sc.SourceBranchID
    LEFT JOIN dbo.Branchmaster tgtB ON tgtB.BranchID = sc.TargetBranchID
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT JOIN dbo.Reportentrystatus res ON res.ReportStatusId = led.ReportStatusId
    WHERE sc.Laborderid = @LabOrderId
      AND sc.CollectionstatusID = 2
      AND ISNULL(sc.IsoutSource, 0) = 0
    ORDER BY sc.samplecollectionID ASC;
END;
GO
