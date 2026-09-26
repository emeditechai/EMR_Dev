-- ============================================================================
-- Migration: 2139_signoff_panel_department_wise_flow.sql
-- Description:
--   Follows 2138. A report that covers more than one department is now signed by each
--   of those departments' own approvers, instead of a single signature for the bill.
--
--   dbo.usp_Api_LabReport_GetSignoffPanel, pathologist-approval case (a):
--   approvals were grouped by approval level alone, so two departments that each sign at
--   level 1 - a Pathology and a Biochemistry test on one numeric report, say - collapsed
--   into one signature block and only the earlier approver was printed. They are now
--   grouped by department and level, one block each, titled with the department name when
--   the report spans several. A single-department report is numbered and titled exactly
--   as before.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_GetSignoffPanel
    @LabOrderId       INT,
    @BranchId         INT = NULL,
    @DepartmentId     INT = NULL,
    @ReportingType    NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @BranchId IS NULL
        SELECT @BranchId = BranchId FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId;

    -- Check if Pathologist Approval is required in HospitalSettings for this branch
    DECLARE @PathologistApprovalRequired BIT = 0;
    SELECT TOP 1 @PathologistApprovalRequired = ISNULL(PathologistApprovalRequired, 0)
    FROM dbo.HospitalSettings
    WHERE BranchId = @BranchId AND IsActive = 1;

    -- ─────────────────────────────────────────────────────────────────────────
    -- Scope: which tests of this bill are actually being printed.
    -- A bill can hold tests of several departments and both reporting types (e.g. a
    -- Pathology numeric test and a Radiology image test). Each is signed by its own
    -- pathologist through its own approval flow, so the signature block must only ever
    -- consider the approvals of the tests on the report in hand. Without this, the
    -- earliest approval on the bill was printed on every report, which put a radiologist
    -- on a pathology report and vice versa.
    -- When the caller asks for nothing in particular, the scope stays open and the
    -- behaviour is exactly as before.
    -- ─────────────────────────────────────────────────────────────────────────
    DECLARE @ScopeAll BIT = CASE WHEN @ReportingType IS NULL
                                  AND (@DepartmentId IS NULL OR @DepartmentId <= 0)
                                 THEN 1 ELSE 0 END;

    DECLARE @ScopeSamples TABLE (SamplecollectionID BIGINT PRIMARY KEY);

    IF @ScopeAll = 0
    BEGIN
        INSERT INTO @ScopeSamples (SamplecollectionID)
        SELECT DISTINCT sc.samplecollectionID
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND ISNULL(sc.Iscancelled, 0) = 0
          AND (@ReportingType IS NULL
               OR LOWER(LTRIM(RTRIM(ISNULL(lim.Reporting_Type, 'Numeric')))) = LOWER(LTRIM(RTRIM(@ReportingType))))
          AND (@DepartmentId IS NULL OR @DepartmentId <= 0
               OR COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID) = @DepartmentId);
    END

    DECLARE @HasFlow  BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.LabReportApproval a
                                              WHERE a.LabOrderId = @LabOrderId AND a.[Source] = 'FLOW'
                                                AND (@ScopeAll = 1 OR a.SamplecollectionID IN (SELECT SamplecollectionID FROM @ScopeSamples))) THEN 1 ELSE 0 END;
    DECLARE @HasEntry BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.LabReportApproval a
                                              WHERE a.LabOrderId = @LabOrderId AND a.[Source] = 'ENTRY'
                                                AND (@ScopeAll = 1 OR a.SamplecollectionID IN (SELECT SamplecollectionID FROM @ScopeSamples))) THEN 1 ELSE 0 END;

    -- ─────────────────────────────────────────────────────────────────────────
    -- CASE 1: Pathologist Approval Required = YES (1)
    -- Whoever actually signed the printed tests signs the report. The level structure is
    -- unchanged; the only addition is the scope filter, so approvals of other departments
    -- or of the other reporting type on the same bill are no longer mistaken for these.
    -- ─────────────────────────────────────────────────────────────────────────
    IF @PathologistApprovalRequired = 1
    BEGIN
        -- (a) signed through the Pathologist Approval Flow
        IF @HasFlow = 1
        BEGIN
            -- One signature per department per level: a report covering two departments is signed
            -- by each department's own approver, the way the configured signatories in CASE 2 are.
            -- A single-department report is numbered 1..n exactly as before.
            ;WITH Scoped AS (
                SELECT a.Level_No, a.TotalLevels, a.Flow_ID, a.ApprovedBy, a.ApprovedDate,
                       COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID) AS DeptId
                FROM dbo.LabReportApproval a
                LEFT JOIN dbo.SampleCollection sc ON sc.samplecollectionID = a.SamplecollectionID
                LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = a.InvestigationID
                WHERE a.LabOrderId = @LabOrderId AND a.[Source] = 'FLOW'
                  AND (@ScopeAll = 1 OR a.SamplecollectionID IN (SELECT SamplecollectionID FROM @ScopeSamples))
            ),
            Signed AS (
                SELECT s.DeptId, s.Level_No, s.TotalLevels, s.Flow_ID, s.ApprovedBy,
                       MIN(s.ApprovedDate) AS SignedOn, COUNT(1) AS TestsSigned,
                       ROW_NUMBER() OVER (PARTITION BY s.DeptId, s.Level_No
                                          ORDER BY MIN(s.ApprovedDate), s.ApprovedBy) AS rn
                FROM Scoped s
                GROUP BY s.DeptId, s.Level_No, s.TotalLevels, s.Flow_ID, s.ApprovedBy
            ),
            Blocks AS (
                SELECT s.DeptId, s.Level_No, s.TotalLevels, s.Flow_ID, s.ApprovedBy, s.SignedOn, s.TestsSigned
                FROM Signed s
                WHERE s.rn = 1
            ),
            DeptStat AS (
                SELECT COUNT(1) AS DeptCount FROM (SELECT DISTINCT DeptId FROM Blocks) d
            ),
            Numbered AS (
                SELECT ROW_NUMBER() OVER (ORDER BY b.DeptId, b.Level_No) AS SeqNo,
                       COUNT(1) OVER ()                                  AS BlockCount,
                       COUNT(1) OVER (PARTITION BY b.DeptId)             AS DeptBlockCount,
                       ds.DeptCount,
                       b.*
                FROM Blocks b CROSS JOIN DeptStat ds
            )
            SELECT
                CAST(n.SeqNo AS INT)                                                  AS LevelNo,
                CAST(n.BlockCount AS INT)                                             AS TotalLevels,
                CASE
                     -- several departments on one report: name the department, and the level
                     -- inside it only when that department signs at more than one level
                     WHEN n.DeptCount > 1 AND dm.DeptName IS NOT NULL AND n.DeptBlockCount > 1
                          THEN dm.DeptName + ' - ' + ISNULL(NULLIF(l.Level_Title, ''), 'Signatory ' + CAST(n.Level_No AS VARCHAR(2)))
                     WHEN n.DeptCount > 1 AND dm.DeptName IS NOT NULL
                          THEN dm.DeptName
                     ELSE ISNULL(l.Level_Title, 'Signatory ' + CAST(n.Level_No AS VARCHAR(2)))
                END                                                                   AS LevelTitle,
                CAST(CASE WHEN n.SeqNo >= n.BlockCount THEN 1 ELSE 0 END AS BIT)      AS IsFinalLevel,
                n.ApprovedBy AS UserId,
                ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)              AS FullName,
                ISNULL(NULLIF(LTRIM(RTRIM(u.RegistrationNo)), ''), u.CertificationNo) AS RegistrationNo,
                u.SignaturePath,
                CAST(ISNULL(u.IsPathologist, 0) AS BIT)                               AS IsPathologist,
                n.SignedOn, n.TestsSigned,
                'FLOW'                                                                AS [Source]
            FROM Numbered n
            INNER JOIN dbo.Users u ON u.Id = n.ApprovedBy
            LEFT  JOIN dbo.LabApprovalFlowLevel l ON l.Flow_ID = n.Flow_ID AND l.Level_No = n.Level_No
            LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = n.DeptId
            ORDER BY n.SeqNo;
            RETURN;
        END

        -- (b) approved on the Entry screen with nothing configured: whoever approved it signs for it
        IF @HasEntry = 1
        BEGIN
            ;WITH Appr AS (
                SELECT a.ApprovedBy, MIN(a.ApprovedDate) AS SignedOn, COUNT(1) AS TestsSigned,
                       ROW_NUMBER() OVER (ORDER BY MIN(a.ApprovedDate), a.ApprovedBy) AS rn
                FROM dbo.LabReportApproval a
                WHERE a.LabOrderId = @LabOrderId AND a.[Source] = 'ENTRY'
                  AND (@ScopeAll = 1 OR a.SamplecollectionID IN (SELECT SamplecollectionID FROM @ScopeSamples))
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

        -- (c) fallback empty result
        SELECT TOP 0
            CAST(NULL AS INT) AS LevelNo, CAST(NULL AS INT) AS TotalLevels, CAST(NULL AS NVARCHAR(100)) AS LevelTitle,
            CAST(NULL AS BIT) AS IsFinalLevel, CAST(NULL AS INT) AS UserId, CAST(NULL AS NVARCHAR(200)) AS FullName,
            CAST(NULL AS NVARCHAR(100)) AS RegistrationNo, CAST(NULL AS NVARCHAR(260)) AS SignaturePath,
            CAST(NULL AS BIT) AS IsPathologist, CAST(NULL AS DATETIME) AS SignedOn, CAST(NULL AS INT) AS TestsSigned,
            CAST(NULL AS VARCHAR(10)) AS [Source];
        RETURN;
    END

    -- ─────────────────────────────────────────────────────────────────────────
    -- CASE 2: Pathologist Approval Required = NO (0)
    -- Apply department-wise signatories configured in Hospital Settings
    -- Works for both Lab Report (Numeric) and Image Report (Image)
    -- ─────────────────────────────────────────────────────────────────────────

    DECLARE @ReportDeptIds TABLE (DepartmentId INT PRIMARY KEY);

    IF @DepartmentId IS NOT NULL AND @DepartmentId > 0
    BEGIN
        INSERT INTO @ReportDeptIds (DepartmentId) VALUES (@DepartmentId);
    END
    ELSE
    BEGIN
        -- Find distinct departments of the investigations present in this order
        -- If @ReportingType is supplied ('Numeric' or 'Image'), only take matching investigations
        INSERT INTO @ReportDeptIds (DepartmentId)
        SELECT DISTINCT DeptId
        FROM (
            SELECT DISTINCT lim.Department_ID AS DeptId
            FROM dbo.labentrydetails led
            INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = led.InvestigationID
            WHERE led.LabOrderId = @LabOrderId
              AND led.IsActive = 1
              AND (@ReportingType IS NULL OR LOWER(LTRIM(RTRIM(ISNULL(lim.Reporting_Type, 'Numeric')))) = LOWER(LTRIM(RTRIM(@ReportingType))))
              AND lim.Department_ID IS NOT NULL

            UNION

            SELECT DISTINCT COALESCE(sc.DepartmentID, lim.Department_ID) AS DeptId
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            WHERE sc.Laborderid = @LabOrderId
              AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
              AND (@ReportingType IS NULL OR LOWER(LTRIM(RTRIM(ISNULL(lim.Reporting_Type, 'Numeric')))) = LOWER(LTRIM(RTRIM(@ReportingType))))
              AND COALESCE(sc.DepartmentID, lim.Department_ID) IS NOT NULL

            UNION

            SELECT DISTINCT lim.Department_ID AS DeptId
            FROM dbo.LabOrderItem loi
            INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId
            WHERE loi.LabOrderId = @LabOrderId
              AND loi.IsActive = 1
              AND (@ReportingType IS NULL OR LOWER(LTRIM(RTRIM(ISNULL(lim.Reporting_Type, 'Numeric')))) = LOWER(LTRIM(RTRIM(@ReportingType))))
              AND lim.Department_ID IS NOT NULL
        ) t;
    END

    -- (a) Return department-specific signatories configured for these departments
    IF EXISTS (
        SELECT 1 FROM dbo.LabReportDefaultSignatory d
        INNER JOIN @ReportDeptIds r ON r.DepartmentId = d.DepartmentId
        WHERE d.BranchId = @BranchId AND d.IsActive = 1
    )
    BEGIN
        ;WITH DeptSigs AS (
            SELECT
                d.DepartmentId,
                dm.DeptName AS DepartmentName,
                d.SlotNo,
                d.UserId,
                ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)              AS FullName,
                ISNULL(NULLIF(LTRIM(RTRIM(u.RegistrationNo)), ''), u.CertificationNo) AS RegistrationNo,
                -- the uploaded signature image wins, else the pathologist's profile signature
                ISNULL(d.SignaturePath, u.SignaturePath)                              AS SignaturePath,
                CAST(ISNULL(u.IsPathologist, 0) AS BIT)                               AS IsPathologist
            FROM dbo.LabReportDefaultSignatory d
            INNER JOIN @ReportDeptIds r ON r.DepartmentId = d.DepartmentId
            INNER JOIN dbo.Users u ON u.Id = d.UserId
            LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = d.DepartmentId
            WHERE d.BranchId = @BranchId AND d.IsActive = 1 AND ISNULL(u.IsActive, 1) = 1
        ),
        Numbered AS (
            SELECT
                ROW_NUMBER() OVER (ORDER BY s.DepartmentId, s.SlotNo) AS LevelNo,
                COUNT(1) OVER ()                                      AS TotalLevels,
                COUNT(1) OVER (PARTITION BY s.DepartmentId)           AS DeptSlotCount,
                s.*
            FROM DeptSigs s
        )
        SELECT
            n.LevelNo,
            n.TotalLevels,
            CASE 
                WHEN n.DeptSlotCount > 1 
                THEN ISNULL(n.DepartmentName, 'Signatory') + ' (' + CAST(n.SlotNo AS VARCHAR(2)) + ')'
                ELSE ISNULL(n.DepartmentName, 'Signatory')
            END                                                                   AS LevelTitle,
            CAST(CASE WHEN n.LevelNo >= n.TotalLevels THEN 1 ELSE 0 END AS BIT)   AS IsFinalLevel,
            n.UserId,
            n.FullName,
            n.RegistrationNo,
            n.SignaturePath,
            n.IsPathologist,
            CAST(NULL AS DATETIME)                                                AS SignedOn,
            0                                                                     AS TestsSigned,
            'CONFIG'                                                              AS [Source]
        FROM Numbered n
        ORDER BY n.LevelNo;
        RETURN;
    END

    -- (b) Fallback to Entry approver if recorded
    IF @HasEntry = 1
    BEGIN
        ;WITH Appr AS (
            SELECT a.ApprovedBy, MIN(a.ApprovedDate) AS SignedOn, COUNT(1) AS TestsSigned,
                   ROW_NUMBER() OVER (ORDER BY MIN(a.ApprovedDate), a.ApprovedBy) AS rn
            FROM dbo.LabReportApproval a
            WHERE a.LabOrderId = @LabOrderId AND a.[Source] = 'ENTRY'
              AND (@ScopeAll = 1 OR a.SamplecollectionID IN (SELECT SamplecollectionID FROM @ScopeSamples))
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

    -- (c) Fallback empty
    SELECT TOP 0
        CAST(NULL AS INT) AS LevelNo, CAST(NULL AS INT) AS TotalLevels, CAST(NULL AS NVARCHAR(100)) AS LevelTitle,
        CAST(NULL AS BIT) AS IsFinalLevel, CAST(NULL AS INT) AS UserId, CAST(NULL AS NVARCHAR(200)) AS FullName,
        CAST(NULL AS NVARCHAR(100)) AS RegistrationNo, CAST(NULL AS NVARCHAR(260)) AS SignaturePath,
        CAST(NULL AS BIT) AS IsPathologist, CAST(NULL AS DATETIME) AS SignedOn, CAST(NULL AS INT) AS TestsSigned,
        CAST(NULL AS VARCHAR(10)) AS [Source];
END;
GO

PRINT 'Script 2139 applied: sign-off panel signs per department per level.';
GO
