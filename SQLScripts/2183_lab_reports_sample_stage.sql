-- ============================================================================
-- Migration: 2183_lab_reports_sample_stage.sql
-- Description:
--   Reports > LAB (LAB Reports Roadmap), Sample stage:
--     LR-10  Samples Pending Collection            dbo.usp_Api_LabReport_SamplesPendingCollection
--     LR-11  Sample Rejection & Re-collection (QI) dbo.usp_Api_LabReport_SampleRejection
--     LR-12  Sample Transfer Register              dbo.usp_Api_LabReport_SampleTransfer
--
--   Same four result sets as every register (SQLScripts/2124): RS1 summary, RS2 groups, RS3 rows, RS4 filter options.
--   Data visibility (roadmap rule): branch check by dbo.usp_LabReport_CheckAccess; Administrator / super admin see every
--   user's data of the branch; anyone else only their own records (defined per report below).
--
--   Sample status history - dbo.LabSampleStatusLog:
--     SampleCollection keeps only a sample's current status, so a rejection disappears once the sample is re-collected.
--     A trigger on SampleCollection now records every change of collection status (Pending / Collected / Re-collect /
--     Rejected) with who, when and the rejection reason - whatever screen made it. LR-11 is built on it.
--     History before this script is reconstructed once: rejections from the audit trail (LAB.SampleStatusChanged),
--     and each sample's current collection (date / time and the user who last updated it).
--   Run after 2182.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Sample status history ────────────────────────────────────────────────
IF OBJECT_ID('dbo.LabSampleStatusLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabSampleStatusLog (
        LogId              BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_LabSampleStatusLog PRIMARY KEY,
        SampleCollectionId BIGINT        NOT NULL,
        LabOrderId         INT           NOT NULL,
        BranchId           INT           NULL,      -- the branch that holds the sample (the target branch once a transfer is received)
        InvestigationId    INT           NULL,
        ProfileId          INT           NULL,
        BarcodeNo          NVARCHAR(50)  NULL,      -- the specimen's barcode at the time of the change
        FromStatusId       INT           NULL,
        ToStatusId         INT           NOT NULL,  -- 1 Pending, 2 Collected, 3 Re-collect, 4 Rejected
        RejectionReasonId  INT           NULL,
        RejectionReason    NVARCHAR(500) NULL,
        ChangedBy          INT           NULL,
        ChangedOn          DATETIME      NOT NULL CONSTRAINT DF_LabSampleStatusLog_ChangedOn DEFAULT (GETDATE()),
        Source             VARCHAR(20)   NOT NULL CONSTRAINT DF_LabSampleStatusLog_Source DEFAULT ('TRIGGER')
    );
    CREATE INDEX IX_LabSampleStatusLog_Status_Date ON dbo.LabSampleStatusLog (ToStatusId, ChangedOn) INCLUDE (BranchId, SampleCollectionId, LabOrderId, ChangedBy);
    CREATE INDEX IX_LabSampleStatusLog_Sample ON dbo.LabSampleStatusLog (SampleCollectionId, ChangedOn);
END
GO

CREATE OR ALTER TRIGGER dbo.trg_SampleCollection_StatusLog
ON dbo.SampleCollection
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(CollectionstatusID) RETURN;

    INSERT INTO dbo.LabSampleStatusLog (SampleCollectionId, LabOrderId, BranchId, InvestigationId, ProfileId, BarcodeNo,
                                        FromStatusId, ToStatusId, RejectionReasonId, RejectionReason, ChangedBy, ChangedOn, Source)
    SELECT i.samplecollectionID, i.Laborderid,
           CASE WHEN ISNULL(i.IsTransferred, 0) = 1 AND ISNULL(i.IsReceived, 0) = 1 THEN i.TargetBranchID ELSE i.BranchID END,
           i.InvestigationID, i.ProfileId,
           LEFT(COALESCE(NULLIF(d.BarcodeNo, ''), NULLIF(i.BarcodeNo, '')), 50),
           d.CollectionstatusID, i.CollectionstatusID,
           CASE WHEN i.CollectionstatusID IN (3, 4) THEN i.RejectionReasonId END,
           CASE WHEN i.CollectionstatusID IN (3, 4) THEN LEFT(i.RejectionReason, 500) END,
           i.ModifiedBy, GETDATE(), 'TRIGGER'
    FROM inserted i
    INNER JOIN deleted d ON d.samplecollectionID = i.samplecollectionID
    WHERE ISNULL(i.CollectionstatusID, 0) <> ISNULL(d.CollectionstatusID, 0)
      AND i.CollectionstatusID IS NOT NULL;
END;
GO

-- One-time reconstruction of the history that existed before the log (skipped once anything was backfilled).
IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleStatusLog WHERE Source LIKE 'BACKFILL%')
BEGIN
    -- a) each sample's current collection
    INSERT INTO dbo.LabSampleStatusLog (SampleCollectionId, LabOrderId, BranchId, InvestigationId, ProfileId, BarcodeNo,
                                        FromStatusId, ToStatusId, ChangedBy, ChangedOn, Source)
    SELECT sc.samplecollectionID, sc.Laborderid,
           CASE WHEN ISNULL(sc.IsTransferred, 0) = 1 AND ISNULL(sc.IsReceived, 0) = 1 THEN sc.TargetBranchID ELSE sc.BranchID END,
           sc.InvestigationID, sc.ProfileId, LEFT(NULLIF(sc.BarcodeNo, ''), 50),
           1, 2, sc.ModifiedBy,
           -- the stored collection time keeps only the minute: the last update of that minute is the exact moment
           CASE WHEN sc.ModifiedDate >= CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME)
                 AND sc.ModifiedDate <  DATEADD(MINUTE, 1, CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME))
                THEN sc.ModifiedDate
                ELSE CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME) END,
           'BACKFILL'
    FROM dbo.SampleCollection sc
    WHERE sc.CollectionstatusID = 2 AND sc.Samplecollectiondate IS NOT NULL;

    -- b) rejections / re-collect requests recorded in the audit trail (Lab Report Entry > sample status)
    INSERT INTO dbo.LabSampleStatusLog (SampleCollectionId, LabOrderId, BranchId, InvestigationId, ProfileId, BarcodeNo,
                                        FromStatusId, ToStatusId, RejectionReasonId, RejectionReason, ChangedBy, ChangedOn, Source)
    SELECT sc.samplecollectionID, sc.Laborderid,
           CASE WHEN ISNULL(sc.IsTransferred, 0) = 1 AND ISNULL(sc.IsReceived, 0) = 1 THEN sc.TargetBranchID ELSE sc.BranchID END,
           sc.InvestigationID, sc.ProfileId, LEFT(NULLIF(sc.BarcodeNo, ''), 50),
           2, a.StatusId, a.ReasonId, LEFT(a.Reason, 500), a.UserId, a.CreatedDate, 'BACKFILL-AUDIT'
    FROM (SELECT al.UserId, CAST(al.CreatedDate AS DATETIME) AS CreatedDate,
                 TRY_CAST(JSON_VALUE(al.MetadataJson, '$.LabOrderId') AS INT)           AS LabOrderId,
                 TRY_CAST(JSON_VALUE(al.MetadataJson, '$.ProfileId') AS INT)            AS ProfileId,
                 TRY_CAST(JSON_VALUE(al.MetadataJson, '$.InvestigationId') AS INT)      AS InvestigationId,
                 TRY_CAST(JSON_VALUE(al.MetadataJson, '$.SampleCollectionId') AS BIGINT) AS SampleCollectionId,
                 TRY_CAST(JSON_VALUE(al.MetadataJson, '$.CollectionStatusId') AS INT)   AS StatusId,
                 TRY_CAST(JSON_VALUE(al.MetadataJson, '$.RejectionReasonId') AS INT)    AS ReasonId,
                 JSON_VALUE(al.MetadataJson, '$.RejectionReason')                       AS Reason
          FROM dbo.AuditLogs al
          WHERE al.ActionName = 'LAB.SampleStatusChanged' AND ISJSON(al.MetadataJson) = 1) a
    INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = a.LabOrderId
         AND ((a.SampleCollectionId IS NOT NULL AND sc.samplecollectionID = a.SampleCollectionId)
           OR (a.SampleCollectionId IS NULL AND a.ProfileId IS NOT NULL AND sc.ProfileId = a.ProfileId)
           OR (a.SampleCollectionId IS NULL AND a.ProfileId IS NULL AND a.InvestigationId IS NOT NULL AND sc.InvestigationID = a.InvestigationId))
    WHERE a.StatusId IN (3, 4);

    -- c) samples waiting for re-collection / rejected whose request is not in the audit trail
    INSERT INTO dbo.LabSampleStatusLog (SampleCollectionId, LabOrderId, BranchId, InvestigationId, ProfileId, BarcodeNo,
                                        FromStatusId, ToStatusId, RejectionReasonId, RejectionReason, ChangedBy, ChangedOn, Source)
    SELECT sc.samplecollectionID, sc.Laborderid,
           CASE WHEN ISNULL(sc.IsTransferred, 0) = 1 AND ISNULL(sc.IsReceived, 0) = 1 THEN sc.TargetBranchID ELSE sc.BranchID END,
           sc.InvestigationID, sc.ProfileId, LEFT(NULLIF(sc.BarcodeNo, ''), 50),
           2, sc.CollectionstatusID, sc.RejectionReasonId, LEFT(sc.RejectionReason, 500), sc.ModifiedBy,
           ISNULL(sc.ModifiedDate, sc.CreatedDate), 'BACKFILL'
    FROM dbo.SampleCollection sc
    WHERE sc.CollectionstatusID IN (3, 4)
      AND NOT EXISTS (SELECT 1 FROM dbo.LabSampleStatusLog l WHERE l.SampleCollectionId = sc.samplecollectionID AND l.ToStatusId IN (3, 4));
END
GO

-- Collections reconstructed before the exact-time rule above: same correction (idempotent).
UPDATE l SET l.ChangedOn = sc.ModifiedDate
FROM dbo.LabSampleStatusLog l
INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = l.SampleCollectionId
WHERE l.Source = 'BACKFILL' AND l.ToStatusId = 2 AND sc.CollectionstatusID = 2
  AND l.ChangedOn = CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME)
  AND sc.ModifiedDate > l.ChangedOn AND sc.ModifiedDate < DATEADD(MINUTE, 1, l.ChangedOn);
GO

-- ============================================================================
-- LR-10 Samples Pending Collection - billed tests whose sample is not collected yet (Pending), or was sent back
-- for re-collection, by bill date. One line per billed test (a profile is one line). Urgent first, longest wait first.
-- Own data: bills the user created, and home collections assigned to the user as phlebotomist.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_SamplesPendingCollection
    @BranchId       INT,
    @FromDate       DATE,
    @ToDate         DATE,
    @CollectionType VARCHAR(10)   = NULL,   -- LAB / HOME / B2B
    @WaitBand       VARCHAR(10)   = NULL,   -- 0-2 / 2-6 / 6-24 / 24+ (hours)
    @PendingStatus  VARCHAR(10)   = NULL,   -- PENDING / RECOLLECT
    @CreatedBy      INT           = NULL,
    @PhlebotomistId INT           = NULL,
    @Search         NVARCHAR(100) = NULL,
    @UserId         INT           = NULL,
    @IsAdmin        BIT           = 0,
    @IsSuperAdmin   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @OwnOnly = 1 SET @CreatedBy = NULL;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)), @Now DATETIME = GETDATE();
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @CollectionType = NULLIF(UPPER(LTRIM(RTRIM(@CollectionType))), '');
    SET @WaitBand = NULLIF(LTRIM(RTRIM(@WaitBand)), '');
    SET @PendingStatus = NULLIF(UPPER(LTRIM(RTRIM(@PendingStatus))), '');

    -- one line per billed test: a profile's parameters share one sample, so they are one line
    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        p.PatientId, p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        COALESCE(NULLIF(sc.ProfileName, ''), lim.Test_Name) AS TestName,
        NULLIF(sc.PackageName, '') AS PackageName,
        COUNT(1) AS ParameterCount,
        MAX(NULLIF(sc.BarcodeNo, '')) AS BarcodeNo,
        MIN(ISNULL(st.Sample_Name, 'Not set')) AS SampleType,
        MIN(NULLIF(st.Container_Type, '')) AS ContainerType,
        CASE WHEN MAX(sc.CollectionstatusID) = 3 THEN 'RECOLLECT' ELSE 'PENDING' END AS PendingStatus,
        MAX(CASE WHEN sc.CollectionstatusID = 3 THEN sc.RejectionReason END) AS RejectionReason,
        -- waiting since the booking; for a re-collection, since it was sent back
        CASE WHEN MAX(sc.CollectionstatusID) = 3 THEN MAX(ISNULL(sc.ModifiedDate, lo.OrderDate))
             ELSE COALESCE(MIN(lo.BookingDate), MIN(lo.OrderDate)) END AS WaitingSince,
        CASE WHEN UPPER(ISNULL(lo.CollectionType, '')) LIKE '%HOME%' THEN 'HOME'
             WHEN UPPER(ISNULL(lo.CollectionType, '')) LIKE '%B2B%' THEN 'B2B'
             ELSE 'LAB' END AS CollectionType,
        lo.PhlebotomistId,
        NULLIF(LTRIM(RTRIM(ph.FullName)), '') AS PhlebotomistName,
        CAST(CASE WHEN ISNULL(lo.IsUrgent, 0) = 1
                    OR EXISTS (SELECT 1 FROM dbo.LabOrderItem uli WHERE uli.LabOrderId = lo.LabOrderId AND uli.IsUrgent = 1)
                  THEN 1 ELSE 0 END AS BIT) AS IsUrgent,
        lo.CreatedBy AS CreatedById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CreatedBy
    INTO #T
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = lim.Sample_Type_ID
    LEFT  JOIN dbo.Users u ON u.Id = lo.CreatedBy
    LEFT  JOIN dbo.Users ph ON ph.Id = lo.PhlebotomistId
    WHERE sc.BranchID = @BranchId
      AND sc.CollectionstatusID IN (1, 3)
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
      AND lo.IsActive = 1
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@OwnOnly = 0 OR lo.CreatedBy = @UserId OR lo.PhlebotomistId = @UserId)
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)
      AND (@PhlebotomistId IS NULL OR lo.PhlebotomistId = @PhlebotomistId)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR sc.BarcodeNo LIKE '%' + @Search + '%' OR lim.Test_Name LIKE '%' + @Search + '%' OR sc.ProfileName LIKE '%' + @Search + '%')
    GROUP BY lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate, p.PatientId, p.PatientCode, p.Salutation, p.FirstName, p.LastName, p.PhoneNumber,
             CASE WHEN sc.ProfileId IS NOT NULL THEN -sc.ProfileId ELSE sc.samplecollectionID END,
             COALESCE(NULLIF(sc.ProfileName, ''), lim.Test_Name), NULLIF(sc.PackageName, ''),
             lo.CollectionType, lo.PhlebotomistId, ph.FullName, lo.IsUrgent, lo.CreatedBy, u.FullName, u.Username;

    SELECT t.*, CAST(DATEDIFF(MINUTE, t.WaitingSince, @Now) / 60.0 AS DECIMAL(10, 1)) AS HoursWaiting,
           CASE WHEN DATEDIFF(MINUTE, t.WaitingSince, @Now) < 120 THEN '0-2'
                WHEN DATEDIFF(MINUTE, t.WaitingSince, @Now) < 360 THEN '2-6'
                WHEN DATEDIFF(MINUTE, t.WaitingSince, @Now) < 1440 THEN '6-24'
                ELSE '24+' END AS WaitBand
    INTO #R FROM #T t;

    IF @CollectionType IS NOT NULL DELETE FROM #R WHERE CollectionType <> @CollectionType;
    IF @WaitBand IS NOT NULL DELETE FROM #R WHERE WaitBand <> @WaitBand;
    IF @PendingStatus IS NOT NULL DELETE FROM #R WHERE PendingStatus <> @PendingStatus;

    -- RS1 summary
    SELECT COUNT(1) AS PendingTests, COUNT(DISTINCT LabOrderId) AS BillCount, COUNT(DISTINCT PatientId) AS PatientCount,
           SUM(CASE WHEN IsUrgent = 1 THEN 1 ELSE 0 END) AS UrgentTests,
           SUM(CASE WHEN CollectionType = 'HOME' THEN 1 ELSE 0 END) AS HomeTests,
           SUM(CASE WHEN PendingStatus = 'RECOLLECT' THEN 1 ELSE 0 END) AS RecollectTests,
           SUM(CASE WHEN WaitBand = '24+' THEN 1 ELSE 0 END) AS Over24Tests,
           ISNULL(MAX(HoursWaiting), 0) AS LongestHours
    FROM #R;

    -- RS2 groups
    SELECT 'bySampleType' AS GroupKey, NULL AS GroupId, SampleType AS GroupName, 0 AS SortOrder,
           COUNT(1) AS PendingTests, COUNT(DISTINCT LabOrderId) AS BillCount, SUM(CASE WHEN IsUrgent = 1 THEN 1 ELSE 0 END) AS UrgentTests,
           SUM(CASE WHEN PendingStatus = 'RECOLLECT' THEN 1 ELSE 0 END) AS RecollectTests, MAX(HoursWaiting) AS LongestHours
    FROM #R GROUP BY SampleType
    UNION ALL
    SELECT 'byCollectionType', NULL, CollectionType, CASE CollectionType WHEN 'LAB' THEN 1 WHEN 'HOME' THEN 2 ELSE 3 END,
           COUNT(1), COUNT(DISTINCT LabOrderId), SUM(CASE WHEN IsUrgent = 1 THEN 1 ELSE 0 END),
           SUM(CASE WHEN PendingStatus = 'RECOLLECT' THEN 1 ELSE 0 END), MAX(HoursWaiting)
    FROM #R GROUP BY CollectionType
    UNION ALL
    SELECT 'byWaitBand', NULL, WaitBand, CASE WaitBand WHEN '0-2' THEN 1 WHEN '2-6' THEN 2 WHEN '6-24' THEN 3 ELSE 4 END,
           COUNT(1), COUNT(DISTINCT LabOrderId), SUM(CASE WHEN IsUrgent = 1 THEN 1 ELSE 0 END),
           SUM(CASE WHEN PendingStatus = 'RECOLLECT' THEN 1 ELSE 0 END), MAX(HoursWaiting)
    FROM #R GROUP BY WaitBand
    UNION ALL
    SELECT 'byPhlebotomist', PhlebotomistId, ISNULL(PhlebotomistName, 'Not assigned'), CASE WHEN PhlebotomistId IS NULL THEN 1 ELSE 0 END,
           COUNT(1), COUNT(DISTINCT LabOrderId), SUM(CASE WHEN IsUrgent = 1 THEN 1 ELSE 0 END),
           SUM(CASE WHEN PendingStatus = 'RECOLLECT' THEN 1 ELSE 0 END), MAX(HoursWaiting)
    FROM #R GROUP BY PhlebotomistId, PhlebotomistName
    UNION ALL
    SELECT 'byDate', NULL, BillDay, 0, COUNT(1), COUNT(DISTINCT LabOrderId), SUM(CASE WHEN IsUrgent = 1 THEN 1 ELSE 0 END),
           SUM(CASE WHEN PendingStatus = 'RECOLLECT' THEN 1 ELSE 0 END), MAX(HoursWaiting)
    FROM #R GROUP BY BillDay
    UNION ALL
    SELECT 'byCreatedBy', CreatedById, CreatedBy, 0, COUNT(1), COUNT(DISTINCT LabOrderId), SUM(CASE WHEN IsUrgent = 1 THEN 1 ELSE 0 END),
           SUM(CASE WHEN PendingStatus = 'RECOLLECT' THEN 1 ELSE 0 END), MAX(HoursWaiting)
    FROM #R GROUP BY CreatedById, CreatedBy
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows: urgent first, then the longest wait
    SELECT * FROM #R ORDER BY IsUrgent DESC, HoursWaiting DESC, LabOrderId;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(CreatedById AS VARCHAR(20)) AS Value, CreatedBy AS Text FROM #R WHERE CreatedById IS NOT NULL
    UNION
    SELECT DISTINCT 'phlebotomistId', CAST(PhlebotomistId AS VARCHAR(20)), PhlebotomistName FROM #R WHERE PhlebotomistId IS NOT NULL AND PhlebotomistName IS NOT NULL;

    DROP TABLE #R; DROP TABLE #T;
END;
GO

-- ============================================================================
-- LR-11 Sample Rejection & Re-collection (NABL / NABH quality indicator) - by rejection date.
-- One line per rejected specimen (the samples of one barcode rejected together count once; a profile is one specimen).
-- Rejection rate = rejected specimens / specimens collected in the period. Re-collect turnaround = rejection to the
-- next collection of that sample. "Collected by" = who last collected the specimen before it was rejected.
-- Own data: specimens the user collected or rejected.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_SampleRejection
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @Outcome       VARCHAR(10)   = NULL,   -- RECOLLECT / REJECTED
    @ReasonId      INT           = NULL,
    @CollectedBy   INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @OwnOnly = 1 SET @CollectedBy = NULL;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Outcome = NULLIF(UPPER(LTRIM(RTRIM(@Outcome))), '');

    -- rejection events of the period, one row per specimen (same sample rows, same moment)
    SELECT l.LabOrderId,
           COALESCE(l.BarcodeNo, CASE WHEN l.ProfileId IS NOT NULL THEN CONCAT('P', l.LabOrderId, '-', l.ProfileId) ELSE CONCAT('S', l.SampleCollectionId) END) AS SpecimenKey,
           CAST(l.ChangedOn AS DATETIME2(0)) AS RejectedOn,
           MAX(l.ToStatusId) AS ToStatusId,
           MAX(l.RejectionReasonId) AS ReasonId, MAX(l.RejectionReason) AS Reason,
           MAX(l.ChangedBy) AS RejectedById, MAX(l.BarcodeNo) AS BarcodeNo,
           MIN(l.SampleCollectionId) AS FirstSampleId, COUNT(1) AS TestRows
    INTO #E
    FROM dbo.LabSampleStatusLog l
    WHERE l.ToStatusId IN (3, 4) AND l.BranchId = @BranchId
      AND l.ChangedOn >= @From AND l.ChangedOn < @To
    GROUP BY l.LabOrderId,
             COALESCE(l.BarcodeNo, CASE WHEN l.ProfileId IS NOT NULL THEN CONCAT('P', l.LabOrderId, '-', l.ProfileId) ELSE CONCAT('S', l.SampleCollectionId) END),
             CAST(l.ChangedOn AS DATETIME2(0));

    SELECT e.LabOrderId, lo.BillNo, lo.TokenNo, e.SpecimenKey, e.BarcodeNo, e.RejectedOn,
           CONVERT(VARCHAR(10), CAST(e.RejectedOn AS DATE), 23) AS RejectedDay,
           CASE WHEN e.ToStatusId = 4 THEN 'REJECTED' ELSE 'RECOLLECT' END AS Outcome,
           e.ReasonId, ISNULL(NULLIF(LTRIM(RTRIM(COALESCE(rr.Reason_Text, e.Reason))), ''), 'Not recorded') AS Reason,
           e.Reason AS ReasonDetail,
           COALESCE(NULLIF(sc.ProfileName, ''), lim.Test_Name) AS TestName, e.TestRows,
           ISNULL(st.Sample_Name, 'Not set') AS SampleType, NULLIF(st.Container_Type, '') AS ContainerType,
           p.PatientId, p.PatientCode,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           col.ChangedBy AS CollectedById,
           NULLIF(LTRIM(RTRIM(cu.FullName)), '') AS CollectedBy,
           col.ChangedOn AS CollectedOn,
           e.RejectedById,
           ISNULL(NULLIF(LTRIM(RTRIM(ru.FullName)), ''), ru.Username) AS RejectedBy,
           re.ChangedOn AS RecollectedOn,
           CAST(CASE WHEN re.ChangedOn IS NULL THEN NULL ELSE DATEDIFF(MINUTE, e.RejectedOn, re.ChangedOn) / 60.0 END AS DECIMAL(10, 1)) AS RecollectHours,
           -- a sample that is collected now was re-collected, even when that moment was not recorded
           CASE WHEN re.ChangedOn IS NOT NULL OR sc.CollectionstatusID = 2 THEN 'DONE' WHEN e.ToStatusId = 4 THEN 'CLOSED' ELSE 'WAITING' END AS RecollectStatus
    INTO #R
    FROM #E e
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = e.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = e.FirstSampleId
    LEFT  JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = lim.Sample_Type_ID
    LEFT  JOIN dbo.LabSampleRejectionReasonMaster rr ON rr.Reason_ID = e.ReasonId
    LEFT  JOIN dbo.Users ru ON ru.Id = e.RejectedById
    -- who collected it before the rejection
    OUTER APPLY (SELECT TOP 1 c.ChangedBy, c.ChangedOn FROM dbo.LabSampleStatusLog c
                  WHERE c.SampleCollectionId = e.FirstSampleId AND c.ToStatusId = 2 AND c.ChangedOn <= e.RejectedOn
                  ORDER BY c.ChangedOn DESC, c.LogId DESC) col
    LEFT  JOIN dbo.Users cu ON cu.Id = col.ChangedBy
    -- the next collection of the sample after the rejection
    OUTER APPLY (SELECT TOP 1 c.ChangedOn FROM dbo.LabSampleStatusLog c
                  WHERE c.SampleCollectionId = e.FirstSampleId AND c.ToStatusId = 2 AND c.ChangedOn > e.RejectedOn
                  ORDER BY c.ChangedOn, c.LogId) re
    WHERE (@OwnOnly = 0 OR e.RejectedById = @UserId OR col.ChangedBy = @UserId)
      AND (@CollectedBy IS NULL OR col.ChangedBy = @CollectedBy)
      AND (@ReasonId IS NULL OR e.ReasonId = @ReasonId)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR e.BarcodeNo LIKE '%' + @Search + '%' OR lim.Test_Name LIKE '%' + @Search + '%' OR sc.ProfileName LIKE '%' + @Search + '%');

    IF @Outcome IS NOT NULL DELETE FROM #R WHERE Outcome <> @Outcome;

    -- specimens collected in the period (the base of the rejection rate), per test / sample type / collector
    SELECT COALESCE(l.BarcodeNo, CASE WHEN l.ProfileId IS NOT NULL THEN CONCAT('P', l.LabOrderId, '-', l.ProfileId) ELSE CONCAT('S', l.SampleCollectionId) END) AS SpecimenKey,
           MIN(l.SampleCollectionId) AS FirstSampleId, MAX(l.ChangedBy) AS CollectedById
    INTO #C0
    FROM dbo.LabSampleStatusLog l
    WHERE l.ToStatusId = 2 AND l.BranchId = @BranchId AND l.ChangedOn >= @From AND l.ChangedOn < @To
      AND (@OwnOnly = 0 OR l.ChangedBy = @UserId)
      AND (@CollectedBy IS NULL OR l.ChangedBy = @CollectedBy)
    GROUP BY COALESCE(l.BarcodeNo, CASE WHEN l.ProfileId IS NOT NULL THEN CONCAT('P', l.LabOrderId, '-', l.ProfileId) ELSE CONCAT('S', l.SampleCollectionId) END),
             CAST(l.ChangedOn AS DATETIME2(0));

    SELECT c.SpecimenKey, c.CollectedById,
           COALESCE(NULLIF(sc.ProfileName, ''), lim.Test_Name) AS TestName,
           ISNULL(st.Sample_Name, 'Not set') AS SampleType
    INTO #C
    FROM #C0 c
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = c.FirstSampleId
    LEFT  JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = lim.Sample_Type_ID;

    DECLARE @Collected INT = (SELECT COUNT(1) FROM #C);
    DECLARE @Rejected INT = (SELECT COUNT(1) FROM #R);

    -- RS1 summary
    SELECT @Rejected AS RejectedSpecimens, ISNULL(SUM(TestRows), 0) AS RejectedTests, @Collected AS CollectedSpecimens,
           -- no rate when nothing was collected in the period (a rejection of an older sample has no base here)
           CAST(100.0 * @Rejected / NULLIF(@Collected, 0) AS DECIMAL(6, 2)) AS RejectionRate,
           SUM(CASE WHEN Outcome = 'RECOLLECT' THEN 1 ELSE 0 END) AS RecollectRequests,
           SUM(CASE WHEN Outcome = 'REJECTED' THEN 1 ELSE 0 END) AS RejectedOutright,
           SUM(CASE WHEN RecollectStatus = 'DONE' THEN 1 ELSE 0 END) AS Recollected,
           SUM(CASE WHEN RecollectStatus = 'WAITING' THEN 1 ELSE 0 END) AS WaitingRecollect,
           CAST(AVG(RecollectHours) AS DECIMAL(10, 1)) AS AvgRecollectHours,
           (SELECT TOP 1 Reason FROM #R GROUP BY Reason ORDER BY COUNT(1) DESC, Reason) AS TopReason
    FROM #R;

    -- RS2 groups: rejected / collected specimens and the rate of each group
    SELECT 'byReason' AS GroupKey, ReasonId AS GroupId, Reason AS GroupName, 0 AS SortOrder,
           COUNT(1) AS RejectedSpecimens, CAST(NULL AS INT) AS CollectedSpecimens,
           CAST(100.0 * COUNT(1) / NULLIF(@Rejected, 0) AS DECIMAL(6, 2)) AS RejectionRate,
           CAST(AVG(RecollectHours) AS DECIMAL(10, 1)) AS AvgRecollectHours
    FROM #R GROUP BY ReasonId, Reason
    UNION ALL
    SELECT 'byTest', NULL, g.TestName, 0, g.Rejected, ISNULL(c.Collected, 0),
           CAST(100.0 * g.Rejected / NULLIF(c.Collected, 0) AS DECIMAL(6, 2)), g.AvgH
    FROM (SELECT TestName, COUNT(1) AS Rejected, CAST(AVG(RecollectHours) AS DECIMAL(10, 1)) AS AvgH FROM #R GROUP BY TestName) g
    LEFT JOIN (SELECT TestName, COUNT(1) AS Collected FROM #C GROUP BY TestName) c ON c.TestName = g.TestName
    UNION ALL
    SELECT 'bySampleType', NULL, g.SampleType, 0, g.Rejected, ISNULL(c.Collected, 0),
           CAST(100.0 * g.Rejected / NULLIF(c.Collected, 0) AS DECIMAL(6, 2)), g.AvgH
    FROM (SELECT SampleType, COUNT(1) AS Rejected, CAST(AVG(RecollectHours) AS DECIMAL(10, 1)) AS AvgH FROM #R GROUP BY SampleType) g
    LEFT JOIN (SELECT SampleType, COUNT(1) AS Collected FROM #C GROUP BY SampleType) c ON c.SampleType = g.SampleType
    UNION ALL
    SELECT 'byCollector', g.CollectedById, ISNULL(g.CollectedBy, 'Not recorded'), CASE WHEN g.CollectedById IS NULL THEN 1 ELSE 0 END,
           -- collector not recorded (history before the status log): no base to compare with
           g.Rejected, CASE WHEN g.CollectedById IS NULL THEN NULL ELSE ISNULL(c.Collected, 0) END,
           CAST(100.0 * g.Rejected / NULLIF(c.Collected, 0) AS DECIMAL(6, 2)), g.AvgH
    FROM (SELECT CollectedById, CollectedBy, COUNT(1) AS Rejected, CAST(AVG(RecollectHours) AS DECIMAL(10, 1)) AS AvgH FROM #R GROUP BY CollectedById, CollectedBy) g
    LEFT JOIN (SELECT CollectedById, COUNT(1) AS Collected FROM #C GROUP BY CollectedById) c ON c.CollectedById = g.CollectedById
    UNION ALL
    SELECT 'byDate', NULL, RejectedDay, 0, COUNT(1), CAST(NULL AS INT), CAST(100.0 * COUNT(1) / NULLIF(@Rejected, 0) AS DECIMAL(6, 2)),
           CAST(AVG(RecollectHours) AS DECIMAL(10, 1))
    FROM #R GROUP BY RejectedDay
    ORDER BY GroupKey, SortOrder, RejectedSpecimens DESC, GroupName;

    -- RS3 rows: newest first
    SELECT * FROM #R ORDER BY RejectedOn DESC, LabOrderId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'reasonId' AS FilterKey, CAST(ReasonId AS VARCHAR(20)) AS Value, Reason AS Text FROM #R WHERE ReasonId IS NOT NULL
    UNION
    SELECT DISTINCT 'collectedBy', CAST(CollectedById AS VARCHAR(20)), CollectedBy FROM #R WHERE CollectedById IS NOT NULL AND CollectedBy IS NOT NULL;

    DROP TABLE #R; DROP TABLE #E; DROP TABLE #C; DROP TABLE #C0;
END;
GO

-- ============================================================================
-- LR-12 Sample Transfer Register - samples sent from this branch to another, or sent here from another branch,
-- by transfer date. One line per transferred specimen (its tests listed). Hours in transit = sent to received
-- (or to now while still in transit).
-- Own data: transfers the user sent or received.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_SampleTransfer
    @BranchId       INT,
    @FromDate       DATE,
    @ToDate         DATE,
    @Direction      VARCHAR(10)   = NULL,   -- SENT / RECEIVED (seen from this branch)
    @TransferStatus VARCHAR(10)   = NULL,   -- TRANSIT / RECEIVED
    @OtherBranchId  INT           = NULL,
    @Search         NVARCHAR(100) = NULL,
    @UserId         INT           = NULL,
    @IsAdmin        BIT           = 0,
    @IsSuperAdmin   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)), @Now DATETIME = GETDATE();
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Direction = NULLIF(UPPER(LTRIM(RTRIM(@Direction))), '');
    SET @TransferStatus = NULLIF(UPPER(LTRIM(RTRIM(@TransferStatus))), '');

    SELECT lo.LabOrderId, lo.BillNo, lo.TokenNo,
           NULLIF(sc.BarcodeNo, '') AS BarcodeNo,
           MIN(sc.TransferredDate) AS SentOn,
           CONVERT(VARCHAR(10), CAST(MIN(sc.TransferredDate) AS DATE), 23) AS SentDay,
           sc.SourceBranchID AS FromBranchId, fb.BranchName AS FromBranch,
           sc.TargetBranchID AS ToBranchId, tb.BranchName AS ToBranch,
           CASE WHEN sc.SourceBranchID = @BranchId THEN 'SENT' ELSE 'RECEIVED' END AS Direction,
           CASE WHEN sc.SourceBranchID = @BranchId THEN sc.TargetBranchID ELSE sc.SourceBranchID END AS OtherBranchId,
           CASE WHEN MIN(CAST(ISNULL(sc.IsReceived, 0) AS INT)) = 1 THEN 'RECEIVED' ELSE 'TRANSIT' END AS TransferStatus,
           MAX(sc.ReceivedDate) AS ReceivedOn,
           STRING_AGG(CAST(COALESCE(NULLIF(sc.ProfileName, ''), lim.Test_Name) AS NVARCHAR(MAX)), '|') AS TestNamesRaw,
           COUNT(1) AS TestRows,
           MIN(ISNULL(st.Sample_Name, 'Not set')) AS SampleType,
           p.PatientId, p.PatientCode,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           MAX(sc.TransferredBy) AS SentById, MAX(sc.ReceivedBy) AS ReceivedById,
           MAX(sc.TransferRemarks) AS TransferRemarks, MAX(sc.ReceiveRemarks) AS ReceiveRemarks
    INTO #T
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.BranchMaster fb ON fb.BranchID = sc.SourceBranchID
    LEFT  JOIN dbo.BranchMaster tb ON tb.BranchID = sc.TargetBranchID
    LEFT  JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = lim.Sample_Type_ID
    WHERE ISNULL(sc.IsTransferred, 0) = 1
      AND (sc.SourceBranchID = @BranchId OR sc.TargetBranchID = @BranchId)
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
      AND sc.TransferredDate >= @From AND sc.TransferredDate < @To
      AND (@OwnOnly = 0 OR sc.TransferredBy = @UserId OR sc.ReceivedBy = @UserId)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR sc.BarcodeNo LIKE '%' + @Search + '%' OR lim.Test_Name LIKE '%' + @Search + '%' OR sc.ProfileName LIKE '%' + @Search + '%')
    GROUP BY lo.LabOrderId, lo.BillNo, lo.TokenNo, NULLIF(sc.BarcodeNo, ''), sc.SourceBranchID, fb.BranchName, sc.TargetBranchID, tb.BranchName,
             CASE WHEN NULLIF(sc.BarcodeNo, '') IS NULL THEN sc.samplecollectionID END,
             p.PatientId, p.PatientCode, p.Salutation, p.FirstName, p.LastName;

    SELECT t.LabOrderId, t.BillNo, t.TokenNo, t.BarcodeNo, t.SentOn, t.SentDay, t.FromBranchId, t.FromBranch, t.ToBranchId, t.ToBranch,
           t.Direction, t.OtherBranchId, t.TransferStatus, t.ReceivedOn,
           -- a profile's parameters are one test on the sample
           (SELECT STRING_AGG(v.value, ', ') FROM (SELECT DISTINCT value FROM STRING_SPLIT(t.TestNamesRaw, '|')) v) AS TestNames,
           t.TestRows, t.SampleType, t.PatientId, t.PatientCode, t.PatientName,
           t.SentById, ISNULL(NULLIF(LTRIM(RTRIM(su.FullName)), ''), su.Username) AS SentBy,
           t.ReceivedById, ISNULL(NULLIF(LTRIM(RTRIM(ru.FullName)), ''), ru.Username) AS ReceivedBy,
           t.TransferRemarks, t.ReceiveRemarks,
           ISNULL(t.FromBranch, 'Branch ' + CAST(t.FromBranchId AS VARCHAR(10))) + N' → ' + ISNULL(t.ToBranch, 'Branch ' + CAST(t.ToBranchId AS VARCHAR(10))) AS BranchPair,
           CAST(DATEDIFF(MINUTE, t.SentOn, COALESCE(t.ReceivedOn, @Now)) / 60.0 AS DECIMAL(10, 1)) AS TransitHours
    INTO #R
    FROM #T t
    LEFT JOIN dbo.Users su ON su.Id = t.SentById
    LEFT JOIN dbo.Users ru ON ru.Id = t.ReceivedById;

    IF @Direction IS NOT NULL DELETE FROM #R WHERE Direction <> @Direction;
    IF @TransferStatus IS NOT NULL DELETE FROM #R WHERE TransferStatus <> @TransferStatus;
    IF @OtherBranchId IS NOT NULL DELETE FROM #R WHERE OtherBranchId <> @OtherBranchId;

    -- RS1 summary
    SELECT COUNT(1) AS SampleCount, ISNULL(SUM(TestRows), 0) AS TestCount,
           SUM(CASE WHEN Direction = 'SENT' THEN 1 ELSE 0 END) AS SentSamples,
           SUM(CASE WHEN Direction = 'RECEIVED' THEN 1 ELSE 0 END) AS IncomingSamples,
           SUM(CASE WHEN TransferStatus = 'TRANSIT' THEN 1 ELSE 0 END) AS InTransit,
           SUM(CASE WHEN TransferStatus = 'TRANSIT' AND Direction = 'RECEIVED' THEN 1 ELSE 0 END) AS AwaitingReceiptHere,
           CAST(AVG(CASE WHEN TransferStatus = 'RECEIVED' THEN TransitHours END) AS DECIMAL(10, 1)) AS AvgTransitHours,
           ISNULL(MAX(CASE WHEN TransferStatus = 'TRANSIT' THEN TransitHours END), 0) AS LongestInTransitHours
    FROM #R;

    -- RS2 groups
    SELECT 'byBranchPair' AS GroupKey, NULL AS GroupId, BranchPair AS GroupName, 0 AS SortOrder,
           COUNT(1) AS SampleCount, SUM(TestRows) AS TestCount, SUM(CASE WHEN TransferStatus = 'TRANSIT' THEN 1 ELSE 0 END) AS InTransit,
           CAST(AVG(CASE WHEN TransferStatus = 'RECEIVED' THEN TransitHours END) AS DECIMAL(10, 1)) AS AvgTransitHours,
           MAX(TransitHours) AS LongestHours
    FROM #R GROUP BY BranchPair
    UNION ALL
    SELECT 'byStatus', NULL, TransferStatus, CASE TransferStatus WHEN 'TRANSIT' THEN 1 ELSE 2 END,
           COUNT(1), SUM(TestRows), SUM(CASE WHEN TransferStatus = 'TRANSIT' THEN 1 ELSE 0 END),
           CAST(AVG(CASE WHEN TransferStatus = 'RECEIVED' THEN TransitHours END) AS DECIMAL(10, 1)), MAX(TransitHours)
    FROM #R GROUP BY TransferStatus
    UNION ALL
    SELECT 'byDirection', NULL, Direction, CASE Direction WHEN 'SENT' THEN 1 ELSE 2 END,
           COUNT(1), SUM(TestRows), SUM(CASE WHEN TransferStatus = 'TRANSIT' THEN 1 ELSE 0 END),
           CAST(AVG(CASE WHEN TransferStatus = 'RECEIVED' THEN TransitHours END) AS DECIMAL(10, 1)), MAX(TransitHours)
    FROM #R GROUP BY Direction
    UNION ALL
    SELECT 'byDate', NULL, SentDay, 0, COUNT(1), SUM(TestRows), SUM(CASE WHEN TransferStatus = 'TRANSIT' THEN 1 ELSE 0 END),
           CAST(AVG(CASE WHEN TransferStatus = 'RECEIVED' THEN TransitHours END) AS DECIMAL(10, 1)), MAX(TransitHours)
    FROM #R GROUP BY SentDay
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows: in transit first (oldest first), then the latest transfers
    SELECT * FROM #R ORDER BY CASE WHEN TransferStatus = 'TRANSIT' THEN 0 ELSE 1 END,
                              CASE WHEN TransferStatus = 'TRANSIT' THEN TransitHours END DESC, SentOn DESC;

    -- RS4 filter options
    SELECT DISTINCT 'otherBranchId' AS FilterKey, CAST(OtherBranchId AS VARCHAR(20)) AS Value,
           CASE WHEN Direction = 'SENT' THEN ToBranch ELSE FromBranch END AS Text
    FROM #R WHERE OtherBranchId IS NOT NULL;

    DROP TABLE #R; DROP TABLE #T;
END;
GO

PRINT 'Script 2183 applied: LR-10 / LR-11 / LR-12 and the sample status log.';
GO
