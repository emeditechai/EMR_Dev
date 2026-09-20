-- ============================================================
-- Script: 2082_fix_lab_reporting_submission.sql
-- Description:
--   1. Fix dbo.usp_LabReporting_SaveEntry to freeze approved rows
--   2. Prevent status regression when submitting partial results
-- ============================================================

USE Dev_EMR;
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
        AbnormalFlag       VARCHAR(20)
    );

    INSERT INTO #ParsedEntries (SamplecollectionID, InvestigationID, TestValue, Remarks, Reporting_Type, AbnormalFlag)
    SELECT 
        COALESCE(j.samplecollectionID, j.SamplecollectionID, j.samplecollectionId, j.SampleCollectionId, 0),
        COALESCE(j.investigationID, j.InvestigationID, j.investigationId, 0),
        COALESCE(j.testValue, j.TestValue, ''),
        COALESCE(j.remarks, j.Remarks, ''),
        COALESCE(j.reportingType, j.ReportingType, j.reporting_type, j.Reporting_Type, ''),
        COALESCE(j.abnormalFlag, j.AbnormalFlag, j.flag, j.Flag, NULL)
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
        Flag               VARCHAR(20)   '$.Flag'
    ) j
    WHERE COALESCE(j.samplecollectionID, j.SamplecollectionID, j.samplecollectionId, j.SampleCollectionId, 0) > 0;

    DECLARE @Now DATETIME = GETDATE();

    -- Update existing records in labentrydetails
    -- FREEZE LOGIC: 
    -- 1. If led.ReportStatusId = 5, do NOT update.
    -- 2. If TestValue is unchanged and led.ReportStatusId >= @ReportStatusId, do NOT regress the status.
    UPDATE led
    SET 
        led.TestValue      = pe.TestValue,
        led.Remarks        = pe.Remarks,
        led.Reporting_Type = COALESCE(NULLIF(pe.Reporting_Type, ''), led.Reporting_Type, lim.Reporting_Type, 'Numeric'),
        led.AbnormalFlag   = pe.AbnormalFlag,
        led.ReportStatusId = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' THEN NULL
                                -- If test value has changed, apply the new status
                                WHEN ISNULL(led.TestValue, '') <> pe.TestValue THEN @ReportStatusId
                                -- If test value is the same, but the new status is higher, progress it
                                WHEN @ReportStatusId > ISNULL(led.ReportStatusId, 0) THEN @ReportStatusId
                                -- Otherwise keep existing status
                                ELSE led.ReportStatusId
                             END,
        led.ModifiedBy     = @UserId,
        led.ModifiedDate   = @Now,
        led.Drafted_Date   = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' THEN NULL
                                WHEN ISNULL(led.TestValue, '') <> pe.TestValue AND (@ReportStatusId = 1 OR @StatusCode = 'DRAFT') THEN @Now
                                WHEN @ReportStatusId > ISNULL(led.ReportStatusId, 0) AND (@ReportStatusId = 1 OR @StatusCode = 'DRAFT') THEN @Now
                                ELSE led.Drafted_Date 
                             END,
        led.Submitted_Date = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' THEN NULL
                                WHEN ISNULL(led.TestValue, '') <> pe.TestValue AND (@ReportStatusId = 2 OR @StatusCode = 'REPORT_ENTRY') THEN @Now
                                WHEN @ReportStatusId > ISNULL(led.ReportStatusId, 0) AND (@ReportStatusId = 2 OR @StatusCode = 'REPORT_ENTRY') THEN @Now
                                ELSE led.Submitted_Date 
                             END,
        led.Validated_date = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' THEN NULL
                                WHEN ISNULL(led.TestValue, '') <> pe.TestValue AND (@ReportStatusId = 3 OR @StatusCode = 'REPORT_VALIDATED') THEN @Now
                                WHEN @ReportStatusId > ISNULL(led.ReportStatusId, 0) AND (@ReportStatusId = 3 OR @StatusCode = 'REPORT_VALIDATED') THEN @Now
                                ELSE led.Validated_date 
                             END,
        led.Approved_Date  = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' THEN NULL
                                WHEN ISNULL(led.TestValue, '') <> pe.TestValue AND (@ReportStatusId = 5 OR @StatusCode IN ('REPORT_APPROVE', 'REPORT_APPROVED')) THEN @Now
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
        pe.TestValue,
        pe.Remarks,
        pe.AbnormalFlag,
        CASE 
            WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' THEN @ReportStatusId 
            ELSE NULL 
        END,
        COALESCE(NULLIF(pe.Reporting_Type, ''), lim.Reporting_Type, 'Numeric'),
        CASE WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 1 OR @StatusCode = 'DRAFT') THEN @Now ELSE NULL END,
        CASE WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 2 OR @StatusCode = 'REPORT_ENTRY') THEN @Now ELSE NULL END,
        CASE WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 3 OR @StatusCode = 'REPORT_VALIDATED') THEN @Now ELSE NULL END,
        CASE WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 5 OR @StatusCode IN ('REPORT_APPROVE', 'REPORT_APPROVED')) THEN @Now ELSE NULL END,
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

PRINT 'Updated dbo.usp_LabReporting_SaveEntry to freeze approved rows and prevent status regression.';
GO
