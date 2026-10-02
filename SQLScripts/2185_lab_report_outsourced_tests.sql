-- ============================================================================
-- Migration: 2185_lab_report_outsourced_tests.sql
-- Description:
--   Reports > LAB (LAB Reports Roadmap): LR-13 Outsourced Test Register - dbo.usp_Api_LabReport_OutsourcedTests
--
--   An outsourced test was only flagged (SampleCollection.IsoutSource); nothing recorded where it went or whether the
--   result came back. dbo.LabOutsourceTracking now records, per outsourced sample: the outside lab, its reference no,
--   when and by whom the sample was sent, when and by whom the result was received, and remarks. It is filled from the
--   register itself (Mark sent / Mark result received), through:
--     dbo.usp_LabOutsource_MarkSent       - only a collected, outsourced sample of the branch; sent date not in the future
--                                            nor before the collection; can be corrected until the result is received
--     dbo.usp_LabOutsource_MarkReceived   - only after the sample was sent; received date not before the sent date
--   Errors raised with 50020 are messages for the user.
--
--   The register: one line per billed outsourced test (a profile is one line), by bill date, with its stage:
--     AWAITING_SAMPLE (not collected yet) > TO_SEND (collected, not sent) > AWAITING_RESULT (sent) > RECEIVED,
--   days at that stage, and overdue when a sent test is past its TAT (Investigation Master TAT hours).
--   Same four result sets as every register (SQLScripts/2124). Own data: samples the user collected, sent or received.
--   Run after 2184.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.LabOutsourceTracking', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabOutsourceTracking (
        TrackingId         BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_LabOutsourceTracking PRIMARY KEY,
        SampleCollectionId BIGINT        NOT NULL,
        LabOrderId         INT           NOT NULL,
        BranchId           INT           NOT NULL,
        OutsideLabName     NVARCHAR(150) NOT NULL,
        ExternalRefNo      NVARCHAR(100) NULL,
        SentOn             DATETIME      NOT NULL,
        SentBy             INT           NULL,
        SentRemarks        NVARCHAR(500) NULL,
        ResultReceivedOn   DATETIME      NULL,
        ReceivedBy         INT           NULL,
        ReceivedRemarks    NVARCHAR(500) NULL,
        CreatedOn          DATETIME      NOT NULL CONSTRAINT DF_LabOutsourceTracking_CreatedOn DEFAULT (GETDATE()),
        ModifiedOn         DATETIME      NULL,
        ModifiedBy         INT           NULL,
        CONSTRAINT UQ_LabOutsourceTracking_Sample UNIQUE (SampleCollectionId)
    );
    CREATE INDEX IX_LabOutsourceTracking_Order ON dbo.LabOutsourceTracking (LabOrderId);
END
GO

-- The samples of one billed test, validated for an outsourcing action (shared by the two actions).
CREATE OR ALTER PROCEDURE dbo.usp_LabOutsource_ResolveSamples
    @BranchId   INT,
    @LabOrderId INT,
    @SampleIds  NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ids TABLE (Id BIGINT PRIMARY KEY);
    INSERT INTO @ids (Id) SELECT DISTINCT TRY_CAST(value AS BIGINT) FROM STRING_SPLIT(ISNULL(@SampleIds, ''), ',') WHERE TRY_CAST(value AS BIGINT) IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM @ids) THROW 50020, 'Select the outsourced test first.', 1;

    IF EXISTS (SELECT 1 FROM @ids i LEFT JOIN dbo.SampleCollection sc ON sc.samplecollectionID = i.Id
                WHERE sc.samplecollectionID IS NULL OR sc.Laborderid <> @LabOrderId OR sc.BranchID <> @BranchId
                   OR ISNULL(sc.IsoutSource, 0) = 0 OR sc.Is_Active = 0 OR ISNULL(sc.Iscancelled, 0) = 1)
        THROW 50020, 'This test is not an active outsourced test of this branch.', 1;

    SELECT sc.samplecollectionID, sc.Laborderid, sc.CollectionstatusID,
           CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME) AS CollectedOn
    FROM @ids i INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = i.Id;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabOutsource_MarkSent
    @BranchId      INT,
    @LabOrderId    INT,
    @SampleIds     NVARCHAR(MAX),
    @OutsideLab    NVARCHAR(150),
    @ExternalRefNo NVARCHAR(100) = NULL,
    @SentOn        DATETIME      = NULL,
    @Remarks       NVARCHAR(500) = NULL,
    @UserId        INT           = NULL,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    SET @OutsideLab = NULLIF(LTRIM(RTRIM(@OutsideLab)), '');
    SET @ExternalRefNo = NULLIF(LTRIM(RTRIM(@ExternalRefNo)), '');
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), '');
    SET @SentOn = ISNULL(@SentOn, GETDATE());
    IF @OutsideLab IS NULL THROW 50020, 'Enter the outside lab the sample was sent to.', 1;
    IF @SentOn > DATEADD(MINUTE, 5, GETDATE()) THROW 50020, 'The sent date cannot be in the future.', 1;

    DECLARE @s TABLE (Id BIGINT PRIMARY KEY, LabOrderId INT, StatusId INT, CollectedOn DATETIME);
    INSERT INTO @s EXEC dbo.usp_LabOutsource_ResolveSamples @BranchId, @LabOrderId, @SampleIds;

    IF EXISTS (SELECT 1 FROM @s WHERE ISNULL(StatusId, 0) <> 2)
        THROW 50020, 'The sample is not collected yet. Collect it before sending it to the outside lab.', 1;
    IF EXISTS (SELECT 1 FROM @s WHERE CollectedOn IS NOT NULL AND @SentOn < DATEADD(MINUTE, -1, CollectedOn))
        THROW 50020, 'The sent date cannot be before the sample was collected.', 1;
    IF EXISTS (SELECT 1 FROM dbo.LabOutsourceTracking t INNER JOIN @s s ON s.Id = t.SampleCollectionId WHERE t.ResultReceivedOn IS NOT NULL)
        THROW 50020, 'The result of this test is already received; the sending details can no longer be changed.', 1;

    MERGE dbo.LabOutsourceTracking AS t
    USING @s AS s ON t.SampleCollectionId = s.Id
    WHEN MATCHED THEN UPDATE SET OutsideLabName = @OutsideLab, ExternalRefNo = @ExternalRefNo, SentOn = @SentOn, SentBy = @UserId,
                                 SentRemarks = @Remarks, ModifiedOn = GETDATE(), ModifiedBy = @UserId
    WHEN NOT MATCHED THEN INSERT (SampleCollectionId, LabOrderId, BranchId, OutsideLabName, ExternalRefNo, SentOn, SentBy, SentRemarks)
                          VALUES (s.Id, s.LabOrderId, @BranchId, @OutsideLab, @ExternalRefNo, @SentOn, @UserId, @Remarks);

    SELECT @@ROWCOUNT AS RowsAffected;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabOutsource_MarkReceived
    @BranchId     INT,
    @LabOrderId   INT,
    @SampleIds    NVARCHAR(MAX),
    @ReceivedOn   DATETIME      = NULL,
    @Remarks      NVARCHAR(500) = NULL,
    @UserId       INT           = NULL,
    @IsSuperAdmin BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), '');
    SET @ReceivedOn = ISNULL(@ReceivedOn, GETDATE());
    IF @ReceivedOn > DATEADD(MINUTE, 5, GETDATE()) THROW 50020, 'The received date cannot be in the future.', 1;

    DECLARE @s TABLE (Id BIGINT PRIMARY KEY, LabOrderId INT, StatusId INT, CollectedOn DATETIME);
    INSERT INTO @s EXEC dbo.usp_LabOutsource_ResolveSamples @BranchId, @LabOrderId, @SampleIds;

    IF EXISTS (SELECT 1 FROM @s s LEFT JOIN dbo.LabOutsourceTracking t ON t.SampleCollectionId = s.Id WHERE t.TrackingId IS NULL)
        THROW 50020, 'Mark the sample as sent to the outside lab first.', 1;
    IF EXISTS (SELECT 1 FROM @s s INNER JOIN dbo.LabOutsourceTracking t ON t.SampleCollectionId = s.Id WHERE @ReceivedOn < t.SentOn)
        THROW 50020, 'The result cannot be received before the sample was sent.', 1;

    UPDATE t SET ResultReceivedOn = @ReceivedOn, ReceivedBy = @UserId, ReceivedRemarks = @Remarks, ModifiedOn = GETDATE(), ModifiedBy = @UserId
    FROM dbo.LabOutsourceTracking t INNER JOIN @s s ON s.Id = t.SampleCollectionId;

    SELECT @@ROWCOUNT AS RowsAffected;
END;
GO

-- ============================================================================
-- LR-13 Outsourced Test Register
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_OutsourcedTests
    @BranchId        INT,
    @FromDate        DATE,
    @ToDate          DATE,
    @OutsourceStatus VARCHAR(20)   = NULL,   -- AWAITING_SAMPLE / TO_SEND / AWAITING_RESULT / RECEIVED / OVERDUE
    @OutsideLab      NVARCHAR(150) = NULL,
    @Search          NVARCHAR(100) = NULL,
    @UserId          INT           = NULL,
    @IsAdmin         BIT           = 0,
    @IsSuperAdmin    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)), @Now DATETIME = GETDATE();
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @OutsourceStatus = NULLIF(UPPER(LTRIM(RTRIM(@OutsourceStatus))), '');
    SET @OutsideLab = NULLIF(LTRIM(RTRIM(@OutsideLab)), '');

    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        p.PatientId, p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        COALESCE(NULLIF(sc.ProfileName, ''), lim.Test_Name) AS TestName,
        COUNT(1) AS ParameterCount,
        STRING_AGG(CAST(sc.samplecollectionID AS VARCHAR(MAX)), ',') AS SampleIds,
        MIN(sc.samplecollectionID) AS FirstSampleId,
        MAX(NULLIF(sc.BarcodeNo, '')) AS BarcodeNo,
        MIN(ISNULL(st.Sample_Name, 'Not set')) AS SampleType,
        MAX(ISNULL(lim.TAT_Hours, 0)) AS TatHours,
        MIN(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) AS AllCollected,
        MAX(CASE WHEN sc.CollectionstatusID = 2
                 THEN CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME) END) AS CollectedOn,
        COUNT(t.TrackingId) AS SentRows,
        COUNT(t.ResultReceivedOn) AS ReceivedRows,
        MAX(t.OutsideLabName) AS OutsideLab, MAX(t.ExternalRefNo) AS ExternalRefNo,
        MAX(t.SentOn) AS SentOn, MAX(t.SentBy) AS SentById, MAX(t.SentRemarks) AS SentRemarks,
        MAX(t.ResultReceivedOn) AS ReceivedOn, MAX(t.ReceivedBy) AS ReceivedById, MAX(t.ReceivedRemarks) AS ReceivedRemarks
    INTO #T
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = lim.Sample_Type_ID
    LEFT  JOIN dbo.LabOutsourceTracking t ON t.SampleCollectionId = sc.samplecollectionID
    WHERE sc.BranchID = @BranchId
      AND ISNULL(sc.IsoutSource, 0) = 1
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
      AND lo.IsActive = 1
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR sc.BarcodeNo LIKE '%' + @Search + '%' OR lim.Test_Name LIKE '%' + @Search + '%' OR sc.ProfileName LIKE '%' + @Search + '%'
           OR t.OutsideLabName LIKE '%' + @Search + '%' OR t.ExternalRefNo LIKE '%' + @Search + '%')
    GROUP BY lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate, p.PatientId, p.PatientCode, p.Salutation, p.FirstName, p.LastName, p.PhoneNumber,
             CASE WHEN sc.ProfileId IS NOT NULL THEN -sc.ProfileId ELSE sc.samplecollectionID END,
             COALESCE(NULLIF(sc.ProfileName, ''), lim.Test_Name);

    SELECT x.*,
           DATEDIFF(MINUTE, x.StageSince, ISNULL(x.StageUntil, @Now)) / 1440.0 AS StageDaysRaw
    INTO #S
    FROM (SELECT t.*,
                 CASE WHEN t.AllCollected = 0 THEN 'AWAITING_SAMPLE'
                      WHEN t.SentRows < t.ParameterCount THEN 'TO_SEND'
                      WHEN t.ReceivedRows < t.ParameterCount THEN 'AWAITING_RESULT'
                      ELSE 'RECEIVED' END AS OutsourceStatus,
                 CASE WHEN t.AllCollected = 0 THEN t.BillDate
                      WHEN t.SentRows < t.ParameterCount THEN ISNULL(t.CollectedOn, t.BillDate)
                      ELSE t.SentOn END AS StageSince,
                 CASE WHEN t.AllCollected = 1 AND t.SentRows = t.ParameterCount AND t.ReceivedRows = t.ParameterCount THEN t.ReceivedOn END AS StageUntil
          FROM #T t) x;

    SELECT s.LabOrderId, s.BillNo, s.TokenNo, s.BillDate, s.BillDay, s.PatientId, s.PatientCode, s.PatientName, s.PhoneNumber,
           s.TestName, s.ParameterCount, s.SampleIds, s.BarcodeNo, s.SampleType, s.TatHours, s.CollectedOn,
           s.OutsideLab, s.ExternalRefNo, s.SentOn, s.SentById, ISNULL(NULLIF(LTRIM(RTRIM(su.FullName)), ''), su.Username) AS SentBy, s.SentRemarks,
           s.ReceivedOn, s.ReceivedById, ISNULL(NULLIF(LTRIM(RTRIM(ru.FullName)), ''), ru.Username) AS ReceivedBy, s.ReceivedRemarks,
           s.OutsourceStatus,
           CAST(s.StageDaysRaw AS DECIMAL(10, 1)) AS DaysAtStage,
           CAST(CASE WHEN s.OutsourceStatus = 'RECEIVED' THEN DATEDIFF(MINUTE, s.SentOn, s.ReceivedOn) / 1440.0 END AS DECIMAL(10, 1)) AS TurnaroundDays,
           CAST(CASE WHEN s.OutsourceStatus = 'AWAITING_RESULT' AND s.TatHours > 0
                      AND DATEDIFF(MINUTE, s.SentOn, @Now) > s.TatHours * 60 THEN 1 ELSE 0 END AS BIT) AS IsOverdue,
           col.ChangedBy AS CollectedById,
           ISNULL(NULLIF(LTRIM(RTRIM(cu.FullName)), ''), cu.Username) AS CollectedBy,
           ISNULL(s.OutsideLab, 'Not sent yet') AS OutsideLabGroup
    INTO #R
    FROM #S s
    LEFT JOIN dbo.Users su ON su.Id = s.SentById
    LEFT JOIN dbo.Users ru ON ru.Id = s.ReceivedById
    OUTER APPLY (SELECT TOP 1 c.ChangedBy FROM dbo.LabSampleStatusLog c
                  WHERE c.SampleCollectionId = s.FirstSampleId AND c.ToStatusId = 2 ORDER BY c.ChangedOn DESC, c.LogId DESC) col
    LEFT JOIN dbo.Users cu ON cu.Id = col.ChangedBy
    WHERE (@OwnOnly = 0 OR col.ChangedBy = @UserId OR s.SentById = @UserId OR s.ReceivedById = @UserId);

    IF @OutsourceStatus = 'OVERDUE' DELETE FROM #R WHERE IsOverdue = 0;
    ELSE IF @OutsourceStatus IS NOT NULL DELETE FROM #R WHERE OutsourceStatus <> @OutsourceStatus;
    IF @OutsideLab IS NOT NULL DELETE FROM #R WHERE ISNULL(OutsideLab, '') NOT LIKE @OutsideLab + '%';

    -- RS1 summary
    SELECT COUNT(1) AS TestCount, COUNT(DISTINCT LabOrderId) AS BillCount,
           SUM(CASE WHEN OutsourceStatus = 'AWAITING_SAMPLE' THEN 1 ELSE 0 END) AS AwaitingSample,
           SUM(CASE WHEN OutsourceStatus = 'TO_SEND' THEN 1 ELSE 0 END) AS ToSend,
           SUM(CASE WHEN OutsourceStatus = 'AWAITING_RESULT' THEN 1 ELSE 0 END) AS AwaitingResult,
           SUM(CASE WHEN IsOverdue = 1 THEN 1 ELSE 0 END) AS Overdue,
           SUM(CASE WHEN OutsourceStatus = 'RECEIVED' THEN 1 ELSE 0 END) AS Received,
           CAST(AVG(TurnaroundDays) AS DECIMAL(10, 1)) AS AvgTurnaroundDays,
           CAST(MAX(CASE WHEN OutsourceStatus = 'AWAITING_RESULT' THEN DaysAtStage END) AS DECIMAL(10, 1)) AS LongestPendingDays
    FROM #R;

    -- RS2 groups
    SELECT 'byStatus' AS GroupKey, NULL AS GroupId, OutsourceStatus AS GroupName,
           CASE OutsourceStatus WHEN 'AWAITING_SAMPLE' THEN 1 WHEN 'TO_SEND' THEN 2 WHEN 'AWAITING_RESULT' THEN 3 ELSE 4 END AS SortOrder,
           COUNT(1) AS TestCount, COUNT(DISTINCT LabOrderId) AS BillCount, SUM(CASE WHEN IsOverdue = 1 THEN 1 ELSE 0 END) AS Overdue,
           SUM(CASE WHEN OutsourceStatus = 'RECEIVED' THEN 1 ELSE 0 END) AS Received,
           CAST(AVG(TurnaroundDays) AS DECIMAL(10, 1)) AS AvgTurnaroundDays, MAX(DaysAtStage) AS LongestDays
    FROM #R GROUP BY OutsourceStatus
    UNION ALL
    SELECT 'byOutsideLab', NULL, OutsideLabGroup, CASE WHEN OutsideLab IS NULL THEN 1 ELSE 0 END,
           COUNT(1), COUNT(DISTINCT LabOrderId), SUM(CASE WHEN IsOverdue = 1 THEN 1 ELSE 0 END),
           SUM(CASE WHEN OutsourceStatus = 'RECEIVED' THEN 1 ELSE 0 END), CAST(AVG(TurnaroundDays) AS DECIMAL(10, 1)), MAX(DaysAtStage)
    FROM #R GROUP BY OutsideLabGroup, CASE WHEN OutsideLab IS NULL THEN 1 ELSE 0 END
    UNION ALL
    SELECT 'byTest', NULL, TestName, 0, COUNT(1), COUNT(DISTINCT LabOrderId), SUM(CASE WHEN IsOverdue = 1 THEN 1 ELSE 0 END),
           SUM(CASE WHEN OutsourceStatus = 'RECEIVED' THEN 1 ELSE 0 END), CAST(AVG(TurnaroundDays) AS DECIMAL(10, 1)), MAX(DaysAtStage)
    FROM #R GROUP BY TestName
    UNION ALL
    SELECT 'byDate', NULL, BillDay, 0, COUNT(1), COUNT(DISTINCT LabOrderId), SUM(CASE WHEN IsOverdue = 1 THEN 1 ELSE 0 END),
           SUM(CASE WHEN OutsourceStatus = 'RECEIVED' THEN 1 ELSE 0 END), CAST(AVG(TurnaroundDays) AS DECIMAL(10, 1)), MAX(DaysAtStage)
    FROM #R GROUP BY BillDay
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows: overdue first, then what still needs action, oldest first
    SELECT * FROM #R ORDER BY IsOverdue DESC,
             CASE OutsourceStatus WHEN 'AWAITING_RESULT' THEN 1 WHEN 'TO_SEND' THEN 2 WHEN 'AWAITING_SAMPLE' THEN 3 ELSE 4 END,
             DaysAtStage DESC, LabOrderId;

    -- RS4 options: outside labs of this report, and every outside lab used by the branch (suggestions when sending)
    SELECT DISTINCT 'outsideLab' AS FilterKey, OutsideLab AS Value, OutsideLab AS Text FROM #R WHERE OutsideLab IS NOT NULL
    UNION
    SELECT DISTINCT 'labName', OutsideLabName, OutsideLabName FROM dbo.LabOutsourceTracking WHERE BranchId = @BranchId;

    DROP TABLE #R; DROP TABLE #S; DROP TABLE #T;
END;
GO

PRINT 'Script 2185 applied: LR-13 Outsourced Test Register and outsourcing tracking.';
GO
