-- ============================================================================
-- Migration: 2107_lab_report_approval_source.sql
-- Description:
--   A lab report can be approved two ways, and the printed signature must follow the one that was actually used:
--     FLOW  - signed level by level on the Pathologist Dashboard (Pathologist Approval Flow)
--     ENTRY - approved straight from the Lab Reporting Entry screen (branch does not require pathologist approval)
--
--   1. dbo.LabReportApproval.Source                 'FLOW' (default, existing rows) | 'ENTRY'
--   2. dbo.usp_Api_LabReport_RecordEntryApproval    records an Entry-screen approval, so every approval is stored
--   3. dbo.usp_Api_LabReport_GetSignoffPanel        now decides the printed panel SERVER SIDE:
--         a. the bill has FLOW approvals   -> the pathologists who signed each level
--         b. otherwise it has ENTRY ones   -> the branch's configured signatories (Hospital Settings),
--                                             or the approving user when none are configured
--         c. nothing recorded (legacy)     -> no rows; the report keeps its old "Approved by" block
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.LabReportApproval') AND name = 'Source')
BEGIN
    ALTER TABLE dbo.LabReportApproval
        ADD [Source] VARCHAR(10) NOT NULL CONSTRAINT DF_LabReportApproval_Source DEFAULT ('FLOW');
    PRINT 'Added column dbo.LabReportApproval.Source';
END
GO

-- ── an approval made on the Lab Reporting Entry screen ──────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_RecordEntryApproval
    @LabOrderId          INT,
    @SamplecollectionIds NVARCHAR(MAX),
    @UserId              INT,
    @BranchId            INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0 RETURN;

    DECLARE @Ids TABLE (Id BIGINT PRIMARY KEY);
    INSERT @Ids (Id)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT)
    FROM STRING_SPLIT(ISNULL(@SamplecollectionIds, ''), ',')
    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) IS NOT NULL;

    -- one row per approved test, only for tests that really are approved and have no record yet
    INSERT dbo.LabReportApproval
        (LabOrderId, SamplecollectionID, InvestigationID, Flow_ID, Level_No, TotalLevels, IsFinalLevel,
         ApprovedBy, ApprovedDate, BranchId, [Source])
    SELECT @LabOrderId, led.SamplecollectionID, led.InvestigationID, NULL, 1, 1, 1,
           @UserId, ISNULL(led.Approved_Date, GETDATE()), @BranchId, 'ENTRY'
    FROM dbo.labentrydetails led
    INNER JOIN @Ids i ON i.Id = led.SamplecollectionID
    WHERE led.LabOrderId = @LabOrderId
      AND led.IsActive = 1
      AND led.ReportStatusId = 5
      AND NOT EXISTS (SELECT 1 FROM dbo.LabReportApproval a
                      WHERE a.SamplecollectionID = led.SamplecollectionID AND a.Level_No = 1);

    SELECT @@ROWCOUNT AS RecordedCount;
END;
GO
PRINT 'Created dbo.usp_Api_LabReport_RecordEntryApproval';
GO

-- ── the signature panel printed at the foot of the report ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_GetSignoffPanel
    @LabOrderId INT,
    @BranchId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @BranchId IS NULL
        SELECT @BranchId = BranchId FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId;

    DECLARE @HasFlow  BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.LabReportApproval
                                              WHERE LabOrderId = @LabOrderId AND [Source] = 'FLOW') THEN 1 ELSE 0 END;
    DECLARE @HasEntry BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.LabReportApproval
                                              WHERE LabOrderId = @LabOrderId AND [Source] = 'ENTRY') THEN 1 ELSE 0 END;

    -- (a) signed through the Pathologist Approval Flow
    IF @HasFlow = 1
    BEGIN
        ;WITH Signed AS (
            SELECT a.Level_No, a.TotalLevels, a.Flow_ID, a.ApprovedBy,
                   MIN(a.ApprovedDate) AS SignedOn, COUNT(1) AS TestsSigned,
                   ROW_NUMBER() OVER (PARTITION BY a.Level_No ORDER BY MIN(a.ApprovedDate), a.ApprovedBy) AS rn
            FROM dbo.LabReportApproval a
            WHERE a.LabOrderId = @LabOrderId AND a.[Source] = 'FLOW'
            GROUP BY a.Level_No, a.TotalLevels, a.Flow_ID, a.ApprovedBy
        )
        SELECT
            s.Level_No AS LevelNo, s.TotalLevels,
            ISNULL(l.Level_Title, 'Signatory ' + CAST(s.Level_No AS VARCHAR(2))) AS LevelTitle,
            CAST(CASE WHEN s.Level_No >= s.TotalLevels THEN 1 ELSE 0 END AS BIT)  AS IsFinalLevel,
            s.ApprovedBy AS UserId,
            ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)              AS FullName,
            ISNULL(NULLIF(LTRIM(RTRIM(u.RegistrationNo)), ''), u.CertificationNo) AS RegistrationNo,
            u.SignaturePath,
            CAST(ISNULL(u.IsPathologist, 0) AS BIT)                               AS IsPathologist,
            s.SignedOn, s.TestsSigned,
            'FLOW'                                                                AS [Source]
        FROM Signed s
        INNER JOIN dbo.Users u ON u.Id = s.ApprovedBy
        LEFT  JOIN dbo.LabApprovalFlowLevel l ON l.Flow_ID = s.Flow_ID AND l.Level_No = s.Level_No
        WHERE s.rn = 1
        ORDER BY s.Level_No;
        RETURN;
    END

    -- (b) approved on the Entry screen: the branch's configured signatories speak for the lab
    IF @HasEntry = 1 AND EXISTS (SELECT 1 FROM dbo.LabReportDefaultSignatory WHERE BranchId = @BranchId AND IsActive = 1)
    BEGIN
        DECLARE @Levels INT = (SELECT COUNT(1) FROM dbo.LabReportDefaultSignatory WHERE BranchId = @BranchId AND IsActive = 1);

        SELECT
            d.LevelNo, @Levels AS TotalLevels,
            'Signatory ' + CAST(d.LevelNo AS VARCHAR(2))                          AS LevelTitle,
            CAST(0 AS BIT)                                                        AS IsFinalLevel,
            d.UserId,
            ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)              AS FullName,
            ISNULL(NULLIF(LTRIM(RTRIM(u.RegistrationNo)), ''), u.CertificationNo) AS RegistrationNo,
            -- the level's own upload wins, else the pathologist's profile signature
            ISNULL(d.SignaturePath, u.SignaturePath)                              AS SignaturePath,
            CAST(ISNULL(u.IsPathologist, 0) AS BIT)                               AS IsPathologist,
            CAST(NULL AS DATETIME)                                                AS SignedOn,
            0                                                                     AS TestsSigned,
            'CONFIG'                                                              AS [Source]
        FROM dbo.LabReportDefaultSignatory d
        INNER JOIN dbo.Users u ON u.Id = d.UserId
        WHERE d.BranchId = @BranchId AND d.IsActive = 1
        ORDER BY d.LevelNo;
        RETURN;
    END

    -- (b2) approved on the Entry screen with nothing configured: whoever approved it signs for it
    IF @HasEntry = 1
    BEGIN
        ;WITH Appr AS (
            SELECT a.ApprovedBy, MIN(a.ApprovedDate) AS SignedOn, COUNT(1) AS TestsSigned,
                   ROW_NUMBER() OVER (ORDER BY MIN(a.ApprovedDate), a.ApprovedBy) AS rn
            FROM dbo.LabReportApproval a
            WHERE a.LabOrderId = @LabOrderId AND a.[Source] = 'ENTRY'
            GROUP BY a.ApprovedBy
        )
        SELECT
            CAST(ap.rn AS INT)                                                    AS LevelNo,
            (SELECT COUNT(1) FROM Appr)                                           AS TotalLevels,
            'Approved by'                                                         AS LevelTitle,
            CAST(1 AS BIT)                                                        AS IsFinalLevel,
            ap.ApprovedBy                                                         AS UserId,
            ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)              AS FullName,
            ISNULL(NULLIF(LTRIM(RTRIM(u.RegistrationNo)), ''), u.CertificationNo) AS RegistrationNo,
            u.SignaturePath,
            CAST(ISNULL(u.IsPathologist, 0) AS BIT)                               AS IsPathologist,
            ap.SignedOn, ap.TestsSigned,
            'ENTRY'                                                               AS [Source]
        FROM Appr ap
        INNER JOIN dbo.Users u ON u.Id = ap.ApprovedBy
        WHERE ap.rn <= 3
        ORDER BY ap.rn;
        RETURN;
    END

    -- (c) nothing recorded: the report falls back to its previous "Approved by" block
    SELECT TOP 0
        CAST(NULL AS INT) AS LevelNo, CAST(NULL AS INT) AS TotalLevels, CAST(NULL AS NVARCHAR(100)) AS LevelTitle,
        CAST(NULL AS BIT) AS IsFinalLevel, CAST(NULL AS INT) AS UserId, CAST(NULL AS NVARCHAR(200)) AS FullName,
        CAST(NULL AS NVARCHAR(100)) AS RegistrationNo, CAST(NULL AS NVARCHAR(260)) AS SignaturePath,
        CAST(NULL AS BIT) AS IsPathologist, CAST(NULL AS DATETIME) AS SignedOn, CAST(NULL AS INT) AS TestsSigned,
        CAST(NULL AS VARCHAR(10)) AS [Source];
END;
GO
PRINT 'Updated dbo.usp_Api_LabReport_GetSignoffPanel (per approval route)';
GO
