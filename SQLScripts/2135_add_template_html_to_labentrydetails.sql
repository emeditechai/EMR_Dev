-- ============================================================================
-- Script: 2135_add_template_html_to_labentrydetails.sql
-- Description:
--   1. Adds Template_Html NVARCHAR(MAX) column to dbo.labentrydetails to store
--      the entire patient report template in HTML format for Image reporting.
--   2. Updates dbo.usp_LabReporting_SaveEntry to accept and persist Template_Html
--      and preserve/assign Reporting_Type.
--   3. Updates dbo.usp_LabReporting_GetDetail to return Template_Html AS TemplateHtml
--      and recognize Template_Html in filled-item status calculations.
-- ============================================================================

USE Dev_EMR;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Add Template_Html to dbo.labentrydetails
-- ─────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (
    SELECT 1 
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'labentrydetails' 
      AND COLUMN_NAME = 'Template_Html'
)
BEGIN
    PRINT 'Adding column Template_Html NVARCHAR(MAX) to dbo.labentrydetails...';
    ALTER TABLE dbo.labentrydetails ADD Template_Html NVARCHAR(MAX) NULL;
    PRINT 'Column Template_Html added successfully.';
END
ELSE
BEGIN
    PRINT 'Column Template_Html already exists in dbo.labentrydetails.';
END
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Update dbo.usp_LabReporting_SaveEntry
-- ─────────────────────────────────────────────────────────────────────────────
PRINT 'Updating dbo.usp_LabReporting_SaveEntry with Template_Html support...';
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

    -- Return 1 on success
    SELECT 1 AS Result;
END;
GO

PRINT 'Updated dbo.usp_LabReporting_SaveEntry.';
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Update dbo.usp_LabReporting_GetDetail to return Template_Html
-- ─────────────────────────────────────────────────────────────────────────────
PRINT 'Updating dbo.usp_LabReporting_GetDetail to return Template_Html...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetDetail
    @LabOrderId    INT,
    @BranchId      INT = NULL,     -- NULL = every sample of the order; otherwise only this branch's samples
    @ReportingType NVARCHAR(50) = 'Numeric' -- NULL = all; 'Numeric' = only Numeric; 'Image' = only Image
AS
BEGIN
    SET NOCOUNT ON;

    -- Check if any sample was transferred for this order
    DECLARE @IsTransferred BIT = 0;
    DECLARE @SourceBranchId INT = NULL;
    DECLARE @SourceBranchName NVARCHAR(150) = NULL;
    DECLARE @TransferredDate DATETIME = NULL;
    DECLARE @TransferRemarks NVARCHAR(500) = NULL;
    DECLARE @IsReceived BIT = 0;
    DECLARE @ReceivedDate DATETIME = NULL;

    SELECT TOP 1
        @IsTransferred = 1,
        @SourceBranchId = sc.SourceBranchID,
        @SourceBranchName = bm.BranchName,
        @TransferredDate = sc.TransferredDate,
        @TransferRemarks = sc.TransferRemarks,
        @IsReceived = ISNULL(sc.IsReceived, 0),
        @ReceivedDate = sc.ReceivedDate
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = sc.SourceBranchID
    WHERE sc.Laborderid = @LabOrderId 
      AND sc.IsTransferred = 1
      AND (@BranchId IS NULL
           OR (sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1));

    -- Patient Demographic variables for reference range and delta check matching
    DECLARE @PatientId INT = NULL;
    DECLARE @PatientGender VARCHAR(20) = NULL;
    DECLARE @PatientAge DECIMAL(6,2) = NULL;
    DECLARE @CompanyId INT = 1;

    SELECT 
        @PatientId = lo.PatientId,
        @PatientGender = p.Gender,
        @CompanyId = ISNULL(bm.CompanyId, 1),
        @PatientAge = CASE 
            WHEN p.DateOfBirth IS NOT NULL THEN 
                DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
                CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
            ELSE NULL 
        END
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    WHERE lo.LabOrderId = @LabOrderId;

    -- Compute Overall Order Status based on entered test results / template html
    DECLARE @OverallStatusId INT = 0;
    DECLARE @OverallStatusCode VARCHAR(30) = 'PENDING';
    DECLARE @OverallStatusName NVARCHAR(100) = 'Pending Entry';
    DECLARE @OverallBadgeClass NVARCHAR(200) = 'bg-secondary-subtle text-secondary border border-secondary-subtle';
    DECLARE @DraftedDate DATETIME = NULL;
    DECLARE @SubmittedDate DATETIME = NULL;
    DECLARE @ValidatedDate DATETIME = NULL;
    DECLARE @ApprovedDate DATETIME = NULL;

    DECLARE @TotalItems INT = 0;
    DECLARE @FilledItems INT = 0;
    DECLARE @MinStatusId INT = 0;
    DECLARE @MaxStatusId INT = 0;

    SELECT 
        @TotalItems = COUNT(*),
        @FilledItems = COUNT(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN 1 ELSE NULL END),
        @MinStatusId = ISNULL(MIN(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @MaxStatusId = ISNULL(MAX(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @DraftedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Drafted_Date ELSE NULL END),
        @SubmittedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Submitted_Date ELSE NULL END),
        @ValidatedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Validated_date ELSE NULL END),
        @ApprovedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Approved_Date ELSE NULL END)
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
      AND sc.CollectionstatusID IN (2, 3, 4)
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND (@ReportingType IS NULL OR LOWER(LTRIM(RTRIM(ISNULL(lim.Reporting_Type, 'Numeric')))) = LOWER(LTRIM(RTRIM(@ReportingType))))
      AND (@BranchId IS NULL
           OR (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1)
           OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
               AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap
                           WHERE l_ap.SamplecollectionID = sc.samplecollectionID
                             AND l_ap.IsActive = 1 AND l_ap.ReportStatusId = 5)));

    IF @FilledItems > 0
    BEGIN
        SET @OverallStatusId = @MaxStatusId;
    END
    ELSE
    BEGIN
        SET @OverallStatusId = 0; -- Pending Entry
    END

    IF @OverallStatusId > 0
    BEGIN
        SELECT 
            @OverallStatusCode = StatusCode,
            @OverallStatusName = StatusName,
            @OverallBadgeClass = BadgeClass
        FROM dbo.Reportentrystatus
        WHERE ReportStatusId = @OverallStatusId;
    END

    -- RS 1: Order and Patient Header Details
    SELECT 
        lo.LabOrderId,
        lo.BranchId,
        ISNULL(bm.BranchName, 'Main Branch') AS BranchName,
        lo.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        @PatientAge AS Age,
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
        ISNULL(lo.RefDoctorId, lo.ReferralDoctorId) AS ReferralDoctorId,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''), NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS ReferralDoctorName,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount,
        -- Transfer information
        ISNULL(@IsTransferred, 0) AS IsTransferred,
        @SourceBranchId AS SourceBranchId,
        @SourceBranchName AS SourceBranchName,
        @TransferredDate AS TransferredDate,
        @TransferRemarks AS TransferRemarks,
        ISNULL(@IsReceived, 0) AS IsReceived,
        @ReceivedDate AS ReceivedDate,
        -- Overall Report Status Information
        @OverallStatusId AS ReportStatusId,
        @OverallStatusCode AS StatusCode,
        @OverallStatusName AS ReportStatusName,
        @OverallBadgeClass AS ReportBadgeClass,
        @DraftedDate AS DraftedDate,
        @SubmittedDate AS SubmittedDate,
        @ValidatedDate AS ValidatedDate,
        @ApprovedDate AS ApprovedDate
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    LEFT JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = lo.RefDoctorId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS 2: Eligible Investigation Items for this Order
    SELECT 
        sc.samplecollectionID,
        sc.Laborderid,
        sc.InvestigationID,
        lim.Test_Code AS TestCode,
        lim.Test_Name AS TestName,
        sc.DepartmentID,
        ISNULL(ldm.DeptName, '') AS DepartmentName,
        COALESCE(NULLIF(m_ref.Method_Name, ''), NULLIF(m_inv.Method_Name, ''), '') AS MethodName,
        lim.Sample_Type_ID AS SampleTypeId,
        ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
        ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS ContainerType,
        COALESCE(NULLIF(ref.UnitSymbol, ''), NULLIF(u_inv.Unit_Symbol, ''), u_inv.Unit_Name, '') AS UnitName,
        ISNULL(lim.Reporting_Type, 'Numeric') AS ReportingType,
        sc.BarcodeNo,
        sc.Samplecollectiondate,
        sc.Samplecollectiontime,
        sc.ProfileId,
        sc.ProfileName,
        sc.PackageId,
        sc.PackageName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName, '—') AS ProfilePackageName,
        ISNULL(sc.CollectionstatusID, 2) AS CollectionstatusID,
        ISNULL(scs.StatusName, 'Collected') AS SampleCollectionStatus,
        ISNULL(scs.StatusCode, 'COLLECTED') AS SampleCollectionStatusCode,
        sc.RejectionReasonId,
        sc.RejectionReason,
        led.LabEntryDetailId,
        CASE WHEN sc.CollectionstatusID IN (3, 4) THEN NULL ELSE led.TestValue END AS TestValue,
        led.Template_Html AS TemplateHtml,
        COALESCE(NULLIF(led.Remarks, ''), ref.Special_Remarks, '') AS Remarks,
        ref.Special_Remarks AS SpecialRemarks,
        COALESCE(rem_prof.LabRemarks, rem_inv.LabRemarks, led.LabRemarks, '') AS GroupLabRemarks,

        -- Reference Range Values
        ref.RefRange_ID AS RefRangeId,
        ref.Low_Value AS LowValue,
        ref.High_Value AS HighValue,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.Tier END AS RangeTier,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.Low_Threshold END AS LowThreshold,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.High_Threshold END AS HighThreshold,
        CASE 
            WHEN ref.Low_Value IS NOT NULL AND ref.High_Value IS NOT NULL AND ref.Low_Value > 0 THEN
                CONCAT(
                    CAST(CAST(ref.Low_Value AS FLOAT) AS VARCHAR(30)), 
                    ' — ', 
                    CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30))
                )
            WHEN ref.Low_Value = 0 AND ref.High_Value IS NOT NULL THEN
                CONCAT('< ', CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30)))
            WHEN ref.Low_Value IS NULL AND ref.High_Value IS NOT NULL THEN
                CONCAT('< ', CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30)))
            WHEN ref.Low_Value IS NOT NULL AND ref.High_Value IS NULL THEN
                CONCAT('> ', CAST(CAST(ref.Low_Value AS FLOAT) AS VARCHAR(30)))
            ELSE '—'
        END AS ReferenceRange,
        -- AbnormalFlag
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN NULL
            ELSE COALESCE(led.AbnormalFlag, 
                CASE 
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.Tier IN ('Critical Value', 'Panic Value')
                         AND ((ref.Low_Threshold IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) < ref.Low_Threshold)
                           OR (ref.High_Threshold IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) > ref.High_Threshold))
                         THEN CASE ref.Tier WHEN 'Panic Value' THEN 'Panic' ELSE 'Critical' END
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.Low_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) < ref.Low_Value THEN 'L'
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.High_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) > ref.High_Value THEN 'H'
                    WHEN ISNUMERIC(led.TestValue) = 1 AND (ref.Low_Value IS NOT NULL OR ref.High_Value IS NOT NULL) THEN 'Normal'
                    ELSE NULL
                END
            )
        END AS AbnormalFlag,
        ISNULL(lim.TAT_Hours, 24) AS TATHours,
        prev.PreviousTestValue,
        prev.PreviousOrderDate,
        prev.PreviousUnitSymbol,
        -- Status Details: Strictly guard empty results
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 0
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' AND LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) = '' THEN 0
            ELSE ISNULL(led.ReportStatusId, 0)
        END AS ReportStatusId,
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 'Pending Entry'
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' AND LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) = '' THEN 'Pending Entry'
            ELSE ISNULL(res.StatusName, 'Pending Entry')
        END AS ReportStatusName,
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' AND LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) = '' THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            ELSE ISNULL(res.BadgeClass, 'bg-secondary-subtle text-secondary border border-secondary-subtle')
        END AS ReportBadgeClass,
        CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Drafted_Date ELSE NULL END AS DraftedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Submitted_Date ELSE NULL END AS SubmittedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Validated_date ELSE NULL END AS ValidatedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Approved_Date ELSE NULL END AS ApprovedDate,
        led.ModifiedDate AS LastSavedDate,
        -- Sample transfer fields
        ISNULL(sc.IsTransferred, 0) AS IsTransferred,
        sc.SourceBranchID           AS SourceBranchId,
        srcB.BranchName             AS SourceBranchName,
        sc.TargetBranchID           AS TargetBranchId,
        CAST(CASE WHEN @BranchId IS NOT NULL
                   AND sc.IsTransferred = 1
                   AND sc.SourceBranchID = @BranchId
                   AND ISNULL(sc.TargetBranchID, 0) <> @BranchId
                  THEN 1 ELSE 0 END AS BIT) AS IsReadOnlyForBranch,
        tgtB.BranchName             AS TargetBranchName,
        sc.TransferredDate,
        sc.TransferRemarks,
        ISNULL(sc.IsReceived, 0)    AS IsReceived,
        sc.ReceivedDate,
        sc.ReceiveRemarks
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabTestMethodMaster m_inv ON m_inv.Method_ID = lim.Method_ID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.LabUnitMaster u_inv ON u_inv.Unit_ID = lim.Unit_ID
    LEFT JOIN dbo.Branchmaster srcB ON srcB.BranchID = sc.SourceBranchID
    LEFT JOIN dbo.Branchmaster tgtB ON tgtB.BranchID = sc.TargetBranchID
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT JOIN dbo.Reportentrystatus res ON res.ReportStatusId = led.ReportStatusId
    LEFT JOIN dbo.SampleCollectionStatus scs ON scs.StatusID = sc.CollectionstatusID

    -- Join Group-level remarks if saved
    LEFT JOIN dbo.LabReportTestRemarks rem_prof ON rem_prof.LabOrderId = sc.Laborderid 
                                                AND rem_prof.GroupKey = 'PRF_' + CAST(sc.ProfileId AS VARCHAR(20))
                                                AND sc.ProfileId IS NOT NULL
                                                AND rem_prof.IsActive = 1
    LEFT JOIN dbo.LabReportTestRemarks rem_inv ON rem_inv.LabOrderId = sc.Laborderid 
                                              AND rem_inv.GroupKey = 'INV_' + CAST(sc.InvestigationID AS VARCHAR(20))
                                              AND rem_inv.IsActive = 1

    -- Match best Reference Range for patient's Gender & Age
    OUTER APPLY (
        SELECT TOP 1 
            r.RefRange_ID,
            r.Method_ID AS RefMethodId,
            r.Unit_ID,
            r.Low_Value,
            r.High_Value,
            r.Special_Remarks,
            r.Tier,
            r.Low_Threshold,
            r.High_Threshold,
            r.Age_From,
            r.Age_To,
            r.Gender AS RangeGender,
            u.Unit_Name,
            COALESCE(NULLIF(u.Unit_Symbol, ''), u.Unit_Name, '') AS UnitSymbol
        FROM dbo.LabReferenceRangeMaster r
        LEFT JOIN dbo.LabUnitMaster u ON u.Unit_ID = r.Unit_ID
        WHERE r.Test_ID = sc.InvestigationID
          AND r.IsDeleted = 0
          AND r.Status = 1
          AND (r.CompanyId = @CompanyId OR r.CompanyId = 1)
          AND r.Effective_From <= CAST(GETDATE() AS DATE)
          AND (r.Effective_To IS NULL OR r.Effective_To >= CAST(GETDATE() AS DATE))
          AND (
              (@PatientAge IS NULL)
              OR (r.Age_Unit = 'Years' AND @PatientAge >= r.Age_From AND @PatientAge <= r.Age_To)
              OR (r.Age_Unit = 'Months' AND (@PatientAge * 12.0) >= r.Age_From AND (@PatientAge * 12.0) <= r.Age_To)
              OR (r.Age_Unit = 'Days' AND (@PatientAge * 365.25) >= r.Age_From AND (@PatientAge * 365.25) <= r.Age_To)
              OR r.Is_Common_For_All = 1
          )
          AND (
              r.Is_Common_For_All = 1
              OR r.Gender = 'All'
              OR LOWER(r.Gender) = LOWER(ISNULL(@PatientGender, ''))
          )
        ORDER BY 
          CASE WHEN LOWER(r.Gender) = LOWER(ISNULL(@PatientGender, '')) THEN 1 ELSE 2 END ASC,
          CASE WHEN r.Is_Common_For_All = 0 THEN 1 ELSE 2 END ASC,
          r.RefRange_ID DESC
    ) ref

    LEFT JOIN dbo.LabTestMethodMaster m_ref ON m_ref.Method_ID = ref.RefMethodId

    -- Previous Historical Result for Delta Check
    OUTER APPLY (
        SELECT TOP 1 
            prev_led.TestValue AS PreviousTestValue,
            prev_lo.OrderDate AS PreviousOrderDate,
            COALESCE(NULLIF(prev_u.Unit_Symbol, ''), prev_u.Unit_Name, '') AS PreviousUnitSymbol
        FROM dbo.labentrydetails prev_led
        INNER JOIN dbo.LabOrder prev_lo ON prev_lo.LabOrderId = prev_led.LabOrderId
        LEFT JOIN dbo.LabInvestigationMaster prev_lim ON prev_lim.Test_ID = prev_led.InvestigationID
        LEFT JOIN dbo.LabUnitMaster prev_u ON prev_u.Unit_ID = prev_lim.Unit_ID
        WHERE prev_led.PatientId = @PatientId
          AND prev_led.InvestigationID = sc.InvestigationID
          AND prev_led.LabOrderId != @LabOrderId
          AND prev_led.IsActive = 1
          AND prev_led.TestValue IS NOT NULL
          AND LTRIM(RTRIM(prev_led.TestValue)) <> ''
        ORDER BY prev_lo.OrderDate DESC, prev_led.LabEntryDetailId DESC
    ) prev

    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
      AND sc.CollectionstatusID IN (2, 3, 4)
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND (@ReportingType IS NULL OR LOWER(LTRIM(RTRIM(ISNULL(lim.Reporting_Type, 'Numeric')))) = LOWER(LTRIM(RTRIM(@ReportingType))))
      AND (@BranchId IS NULL
           OR (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1)
           OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
               AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap
                           WHERE l_ap.SamplecollectionID = sc.samplecollectionID
                             AND l_ap.IsActive = 1 AND l_ap.ReportStatusId = 5)))
    ORDER BY sc.samplecollectionID ASC;

    -- RS 3: Header-Level Lab Remarks
    SELECT 
        GroupKey,
        HeaderName,
        ProfileId,
        InvestigationId,
        LabRemarks
    FROM dbo.LabReportTestRemarks
    WHERE LabOrderId = @LabOrderId AND IsActive = 1;
END;
GO

PRINT 'Updated dbo.usp_LabReporting_GetDetail.';
GO
