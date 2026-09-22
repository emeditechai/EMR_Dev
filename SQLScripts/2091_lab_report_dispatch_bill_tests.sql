-- ============================================================================
-- Migration: 2091_lab_report_dispatch_bill_tests.sql
-- Description:
--   Adds dbo.usp_LabReportDispatch_GetBillTests - a READ-ONLY procedure behind the
--   "view tests" icon of the Lab Report Dispatch list. One row per test of a bill with
--   its sample collection date/time, receipt, entry / validation / approval stamps and
--   the person who approved it, so the dispatch desk can see why a bill is not ready yet.
--
--   No existing table or procedure is altered.
-- ============================================================================

USE [Dev_EMR];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReportDispatch_GetBillTests
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sc.samplecollectionID                                   AS SamplecollectionID,
        lim.Test_Code                                           AS TestCode,
        lim.Test_Name                                           AS TestName,
        ISNULL(d.DeptName, '')                                  AS DepartmentName,
        c.Category_Name                                         AS CategoryName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName) AS GroupName,
        ISNULL(stm.Sample_Name, '')                             AS SampleTypeName,
        NULLIF(stm.Container_Type, '')                          AS ContainerType,
        sc.BarcodeNo,

        -- ── sample ───────────────────────────────────────────────────────────
        ISNULL(sc.CollectionstatusID, 2)                        AS CollectionstatusID,
        ISNULL(scs.StatusName, 'Collected')                     AS SampleStatusName,
        sc.RejectionReason,
        CASE WHEN sc.Samplecollectiondate IS NULL THEN NULL
             ELSE DATEADD(SECOND,
                      DATEDIFF(SECOND, 0, ISNULL(sc.Samplecollectiontime, '00:00:00')),
                      CAST(CAST(sc.Samplecollectiondate AS DATE) AS DATETIME))
        END                                                     AS CollectedOn,
        sc.ReceivedDate,
        CAST(ISNULL(sc.IsTransferred, 0) AS BIT)                AS IsTransferred,
        tgt.BranchName                                          AS TargetBranchName,

        -- ── reporting ────────────────────────────────────────────────────────
        CASE WHEN sc.CollectionstatusID IN (3, 4) THEN 0
             WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 0
             ELSE ISNULL(led.ReportStatusId, 0) END             AS ReportStatusId,
        CASE WHEN sc.CollectionstatusID IN (3, 4) THEN 'Pending Entry'
             WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'Pending Entry'
             ELSE ISNULL(res.StatusName, 'Pending Entry') END   AS ReportStatusName,
        led.Drafted_Date                                        AS DraftedDate,
        led.Submitted_Date                                      AS SubmittedDate,
        led.Validated_date                                      AS ValidatedDate,
        led.Approved_Date                                       AS ApprovedDate,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS ApprovedByName,

        -- collection -> approval, in minutes (only once approved)
        CASE WHEN led.ReportStatusId = 5 AND led.Approved_Date IS NOT NULL AND sc.Samplecollectiondate IS NOT NULL
             THEN DATEDIFF(MINUTE,
                      DATEADD(SECOND,
                          DATEDIFF(SECOND, 0, ISNULL(sc.Samplecollectiontime, '00:00:00')),
                          CAST(CAST(sc.Samplecollectiondate AS DATE) AS DATETIME)),
                      led.Approved_Date)
        END                                                     AS TatMinutes
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.DepartmentMaster d         ON d.DeptId = COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID)
    LEFT  JOIN dbo.LabTestCategoryMaster c    ON c.Category_ID = COALESCE(NULLIF(sc.TestcategoryID, 0), lim.Category_ID)
    LEFT  JOIN dbo.LabSampleTypeMaster stm    ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT  JOIN dbo.SampleCollectionStatus scs ON scs.StatusID = sc.CollectionstatusID
    LEFT  JOIN dbo.Branchmaster tgt           ON tgt.BranchID = sc.TargetBranchID
    LEFT  JOIN dbo.labentrydetails led        ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT  JOIN dbo.Reportentrystatus res      ON res.ReportStatusId = led.ReportStatusId
    LEFT  JOIN dbo.Users u                    ON u.Id = led.ModifiedBy AND led.ReportStatusId = 5
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND sc.Iscancelled = 0
      AND ISNULL(sc.IsoutSource, 0) = 0
    ORDER BY
        ISNULL(d.DeptName, ''),
        ISNULL(c.Display_Order, 9999),
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName, ''),
        lim.Test_Name;
END;
GO

PRINT 'Created procedure dbo.usp_LabReportDispatch_GetBillTests';
GO
