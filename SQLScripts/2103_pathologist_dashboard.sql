-- ============================================================================
-- Migration: 2103_pathologist_dashboard.sql
-- Description:
--   "Pathologist Dashboard" (LAB menu): the screen a pathologist signs reports off from.
--
--   Scope of what a pathologist sees (all three must hold):
--     1. the user is a pathologist (Users.IsPathologist = 1), active, and assigned to the branch
--     2. the test's Department is in Users.DepartmentIds  AND its Test Category is in
--        Users.PathologistCategoryIds  (an empty list means "no restriction on that axis")
--     3. the Pathologist Approval Flow: when a flow covers the test's department / category, only the
--        approvers of the CURRENT pending level may sign it off. With no flow, any in-scope pathologist may.
--
--   Multi-level sign-off: a flow with Required_Levels = N needs N sequential approvals. Each one is written to
--   dbo.LabReportApproval; the test only becomes Approved (labentrydetails.ReportStatusId = 5) on the last level.
--
--   Objects
--     dbo.LabReportApproval                         per-level sign-off record
--     dbo.ufn_LabPathologistScope                   the tests one pathologist may act on (inline TVF)
--     dbo.usp_Api_PathologistDashboard_GetAccess    profile + the departments / categories to filter by
--     dbo.usp_Api_PathologistDashboard_GetHeaderList stats + the bill list
--     dbo.usp_Api_PathologistDashboard_GetDetail    one bill: header, tests, level state, sign-off history
--     dbo.usp_Api_PathologistDashboard_Approve      sign off the selected tests at the next level
--
--   Nothing existing is altered here (usp_LabUnapprove_Execute is updated in 2104 to clear the level records).
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. per-level sign-off record ────────────────────────────────────────────
IF OBJECT_ID('dbo.LabReportApproval', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabReportApproval
    (
        ApprovalId         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabReportApproval PRIMARY KEY,
        LabOrderId         INT           NOT NULL,
        SamplecollectionID BIGINT        NOT NULL,
        InvestigationID    INT           NULL,
        Flow_ID            INT           NULL,          -- NULL = approved without a configured flow
        Level_No           TINYINT       NOT NULL,
        TotalLevels        TINYINT       NOT NULL,
        IsFinalLevel       BIT           NOT NULL,
        ApprovedBy         INT           NOT NULL,
        ApprovedDate       DATETIME      NOT NULL CONSTRAINT DF_LabReportApproval_Date DEFAULT (GETDATE()),
        Remarks            NVARCHAR(500) NULL,
        BranchId           INT           NULL
    );
    CREATE UNIQUE INDEX UQ_LabReportApproval_Sample_Level ON dbo.LabReportApproval (SamplecollectionID, Level_No);
    CREATE INDEX IX_LabReportApproval_Order ON dbo.LabReportApproval (LabOrderId, ApprovedDate DESC);
    PRINT 'Created table dbo.LabReportApproval';
END
GO

-- ── 2. the tests a pathologist may act on ───────────────────────────────────
-- Returns one row per in-scope test of the branch with its level state.
-- @OnlyPending = 1 keeps only the tests still waiting for THIS pathologist's signature.
CREATE OR ALTER FUNCTION dbo.ufn_LabPathologistScope
(
    @UserId   INT,
    @BranchId INT
)
RETURNS TABLE
AS
RETURN
(
    WITH Me AS (
        SELECT u.Id, u.CompanyId,
               NULLIF(LTRIM(RTRIM(u.DepartmentIds)), '')            AS DepartmentIds,
               NULLIF(LTRIM(RTRIM(u.PathologistCategoryIds)), '')   AS CategoryIds
        FROM dbo.Users u
        WHERE u.Id = @UserId AND ISNULL(u.IsPathologist, 0) = 1 AND ISNULL(u.IsActive, 0) = 1
    ),
    MyDept AS (
        SELECT TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) AS Id
        FROM Me CROSS APPLY STRING_SPLIT(Me.DepartmentIds, ',') s
        WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) IS NOT NULL
    ),
    MyCat AS (
        SELECT TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) AS Id
        FROM Me CROSS APPLY STRING_SPLIT(Me.CategoryIds, ',') s
        WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) IS NOT NULL
    ),
    Tests AS (
        SELECT
            sc.samplecollectionID                                        AS SamplecollectionID,
            sc.Laborderid                                                AS LabOrderId,
            sc.InvestigationID,
            COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID)      AS DepartmentId,
            COALESCE(NULLIF(sc.TestcategoryID, 0), lim.Category_ID)      AS CategoryId,
            ISNULL(led.ReportStatusId, 0)                                AS ReportStatusId,
            led.TestValue,
            (SELECT me2.CompanyId FROM Me me2)                           AS CompanyId
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
        WHERE sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND sc.CollectionstatusID = 2
          AND ISNULL(sc.IsoutSource, 0) = 0
          -- the branch that holds the sample (same rule as the Report Entry screen)
          AND (
                (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
             OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1)
              )
          -- only results that are ready for sign-off (Validated) or already signed off
          AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> ''
          AND led.ReportStatusId IN (3, 5)
          -- department / category access of this pathologist ('' = unrestricted on that axis)
          AND (NOT EXISTS (SELECT 1 FROM MyDept)
               OR COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID) IN (SELECT Id FROM MyDept))
          AND (NOT EXISTS (SELECT 1 FROM MyCat)
               OR COALESCE(NULLIF(sc.TestcategoryID, 0), lim.Category_ID) IN (SELECT Id FROM MyCat))
          AND EXISTS (SELECT 1 FROM Me)
          -- the pathologist must belong to this branch
          AND EXISTS (SELECT 1 FROM dbo.UserBranches ub
                      WHERE ub.UserId = @UserId AND ub.BranchID = @BranchId AND ISNULL(ub.IsActive, 1) = 1)
    ),
    Flowed AS (
        SELECT
            t.*,
            f.Flow_ID,
            f.Flow_Name,
            ISNULL(f.Required_Levels, 1)                                                      AS TotalLevels,
            (SELECT COUNT(1) FROM dbo.LabReportApproval a WHERE a.SamplecollectionID = t.SamplecollectionID) AS LevelsDone
        FROM Tests t
        OUTER APPLY (
            -- the flow that governs this test: category beats department beats branch beats company
            SELECT TOP 1 f2.Flow_ID, f2.Flow_Name, f2.Required_Levels
            FROM dbo.LabApprovalFlow f2
            WHERE f2.CompanyId = t.CompanyId
              AND f2.IsDeleted = 0 AND f2.Status = 1
              AND (f2.Branch_ID IS NULL OR f2.Branch_ID = @BranchId)
              AND (
                    (f2.Category_IDs IS NOT NULL AND t.CategoryId IS NOT NULL
                     AND EXISTS (SELECT 1 FROM STRING_SPLIT(f2.Category_IDs, ',') s
                                 WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) = t.CategoryId))
                 OR (f2.Category_IDs IS NULL AND (f2.Department_ID IS NULL OR f2.Department_ID = t.DepartmentId))
                  )
            ORDER BY
                CASE WHEN f2.Category_IDs IS NOT NULL THEN 3 WHEN f2.Department_ID IS NOT NULL THEN 2 ELSE 1 END DESC,
                CASE WHEN f2.Branch_ID IS NOT NULL THEN 1 ELSE 0 END DESC,
                f2.Flow_ID
        ) f
    )
    SELECT
        fl.SamplecollectionID,
        fl.LabOrderId,
        fl.InvestigationID,
        fl.DepartmentId,
        fl.CategoryId,
        fl.ReportStatusId,
        fl.Flow_ID,
        fl.Flow_Name,
        fl.TotalLevels,
        fl.LevelsDone,
        CAST(CASE WHEN fl.LevelsDone < fl.TotalLevels THEN fl.LevelsDone + 1 END AS INT) AS NextLevelNo,
        -- may THIS pathologist sign the next level?
        CAST(CASE
                WHEN fl.ReportStatusId = 5 THEN 0                          -- already fully approved
                WHEN fl.LevelsDone >= fl.TotalLevels THEN 0
                WHEN fl.Flow_ID IS NULL THEN 1                             -- no flow configured: in-scope pathologist may sign
                WHEN EXISTS (
                        SELECT 1
                        FROM dbo.LabApprovalFlowLevel l
                        JOIN dbo.LabApprovalFlowApprover ap ON ap.Level_ID = l.Level_ID
                        WHERE l.Flow_ID = fl.Flow_ID
                          AND l.Level_No = fl.LevelsDone + 1
                          AND ap.UserId = @UserId) THEN 1
                ELSE 0
             END AS BIT) AS CanApproveNow,
        CAST(CASE WHEN fl.ReportStatusId = 5 THEN 1 ELSE 0 END AS BIT) AS IsApproved
    FROM Flowed fl
);
GO
PRINT 'Created function dbo.ufn_LabPathologistScope';
GO
