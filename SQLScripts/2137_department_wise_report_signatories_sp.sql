-- ============================================================================
-- Migration: 2137_department_wise_report_signatories_sp.sql
-- Description:
--   Updates dbo.usp_Api_LabReport_GetSignoffPanel to support department-wise
--   pathologist signatures for both Lab Report and Image Report when
--   Hospital Settings parameter "Pathologist Approval Required" = No.
--   When "Pathologist Approval Required" = Yes, logic is 100% untouched.
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

    DECLARE @HasFlow  BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.LabReportApproval
                                              WHERE LabOrderId = @LabOrderId AND [Source] = 'FLOW') THEN 1 ELSE 0 END;
    DECLARE @HasEntry BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.LabReportApproval
                                              WHERE LabOrderId = @LabOrderId AND [Source] = 'ENTRY') THEN 1 ELSE 0 END;

    -- ─────────────────────────────────────────────────────────────────────────
    -- CASE 1: Pathologist Approval Required = YES (1)
    -- DO NOT TOUCH THIS LOGIC - Left 100% as existing
    -- ─────────────────────────────────────────────────────────────────────────
    IF @PathologistApprovalRequired = 1
    BEGIN
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

        -- (b) approved on the Entry screen with nothing configured: whoever approved it signs for it
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
PRINT 'Updated dbo.usp_Api_LabReport_GetSignoffPanel for department-wise signatories';
GO
