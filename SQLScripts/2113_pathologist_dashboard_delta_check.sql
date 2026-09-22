-- ============================================================================
-- Migration: 2113_pathologist_dashboard_delta_check.sql
-- Description:
--   Pathologist sign-off screen (Approve.cshtml): the Result column should show the same
--   "Previous: <value> <unit> (date)" + delta check hint that the Lab Report Entry screen shows,
--   so the pathologist can see how far a value moved from the patient's last result for that test
--   without leaving the sign-off modal.
--
--   Adds PreviousTestValue / PreviousOrderDate / PreviousUnitSymbol to RS2 of
--   usp_Api_PathologistDashboard_GetDetail, using the same "most recent prior active result for
--   this patient + investigation, from a different order" lookup already used by
--   usp_LabReporting_GetEntryDetail (SQLScripts/2102_lab_reporting_source_branch_readonly.sql).
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PathologistDashboard_GetDetail
    @LabOrderId INT,
    @UserId     INT,
    @BranchId   INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT * INTO #S FROM dbo.ufn_LabPathologistScope(@UserId, @BranchId) WHERE LabOrderId = @LabOrderId;

    -- RS1: bill / patient header
    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.IsUrgent,
        lo.OrderDate AS BillingDate, ISNULL(lo.BookingDate, lo.OrderDate) AS BookingDateTime,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        CASE WHEN p.DateOfBirth IS NOT NULL
             THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                  - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
             END AS Age,
        p.Gender, p.PhoneNumber, p.EmailId,
        CASE WHEN lo.IsB2B = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        CASE WHEN lo.IsB2B = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END END AS ClientName,
        (SELECT COUNT(1) FROM #S)                                     AS ScopeTests,
        (SELECT COUNT(1) FROM #S WHERE CanApproveNow = 1)             AS AwaitingMeTests,
        (SELECT COUNT(1) FROM #S WHERE IsApproved = 1)                AS ApprovedTests
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.LabFranchiseMaster f    ON f.Franchise_ID    = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster    corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS2: the tests this pathologist may see, with the result and the level state
    SELECT
        s.SamplecollectionID, s.InvestigationID,
        lim.Test_Code AS TestCode, lim.Test_Name AS TestName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName) AS GroupName,
        sc.ProfileId,
        ISNULL(d.DeptName, '')        AS DepartmentName,
        ISNULL(c.Category_Name, '')   AS CategoryName,
        sc.BarcodeNo,
        led.TestValue, led.AbnormalFlag, led.Remarks, led.Reporting_Type AS ReportingType,
        ISNULL(u_unit.Unit_Symbol, u_unit.Unit_Name) AS UnitName,
        led.Validated_date AS ValidatedDate, led.Approved_Date AS ApprovedDate,
        ISNULL(NULLIF(LTRIM(RTRIM(uv.FullName)), ''), uv.Username) AS ValidatedByName,
        s.ReportStatusId, s.Flow_ID, s.Flow_Name, s.TotalLevels, s.LevelsDone, s.NextLevelNo,
        s.CanApproveNow, s.IsApproved,
        -- Prior result for delta check
        prev.PreviousTestValue,
        prev.PreviousOrderDate,
        prev.PreviousUnitSymbol,
        -- who is expected to sign the next level
        STUFF((SELECT DISTINCT ', ' + ISNULL(NULLIF(LTRIM(RTRIM(un.FullName)), ''), un.Username)
               FROM dbo.LabApprovalFlowLevel l
               JOIN dbo.LabApprovalFlowApprover ap ON ap.Level_ID = l.Level_ID
               JOIN dbo.Users un ON un.Id = ap.UserId
               WHERE l.Flow_ID = s.Flow_ID AND l.Level_No = s.NextLevelNo
               FOR XML PATH('')), 1, 2, '') AS NextLevelApprovers,
        (SELECT l.Level_Title FROM dbo.LabApprovalFlowLevel l
          WHERE l.Flow_ID = s.Flow_ID AND l.Level_No = s.NextLevelNo)  AS NextLevelTitle
    FROM #S s
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = s.SamplecollectionID
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = s.SamplecollectionID AND led.IsActive = 1
    LEFT  JOIN dbo.DepartmentMaster d ON d.DeptId = s.DepartmentId
    LEFT  JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = s.CategoryId
    LEFT  JOIN dbo.LabUnitMaster u_unit ON u_unit.Unit_ID = lim.Unit_ID
    LEFT  JOIN dbo.Users uv ON uv.Id = led.ModifiedBy
    OUTER APPLY (
        SELECT TOP 1
            prev_led.TestValue AS PreviousTestValue,
            prev_lo.OrderDate AS PreviousOrderDate,
            COALESCE(NULLIF(prev_u.Unit_Symbol, ''), prev_u.Unit_Name, '') AS PreviousUnitSymbol
        FROM dbo.labentrydetails prev_led
        INNER JOIN dbo.LabOrder prev_lo ON prev_lo.LabOrderId = prev_led.LabOrderId
        LEFT JOIN dbo.LabInvestigationMaster prev_lim ON prev_lim.Test_ID = prev_led.InvestigationID
        LEFT JOIN dbo.LabUnitMaster prev_u ON prev_u.Unit_ID = prev_lim.Unit_ID
        WHERE prev_led.PatientId = sc.PatientID
          AND prev_led.InvestigationID = sc.InvestigationID
          AND prev_led.LabOrderId != @LabOrderId
          AND prev_led.IsActive = 1
          AND prev_led.TestValue IS NOT NULL
          AND LTRIM(RTRIM(prev_led.TestValue)) <> ''
        ORDER BY prev_lo.OrderDate DESC, prev_led.LabEntryDetailId DESC
    ) prev
    ORDER BY ISNULL(d.DeptName, ''), COALESCE(sc.ProfileName, ''), lim.Test_Name;

    -- RS3: the sign-off history of this bill (every level already signed)
    SELECT a.SamplecollectionID, a.Level_No, a.TotalLevels, a.IsFinalLevel,
           a.ApprovedDate, a.Remarks,
           ISNULL(NULLIF(LTRIM(RTRIM(ua.FullName)), ''), ua.Username) AS ApprovedByName,
           lim.Test_Name AS TestName,
           (SELECT l.Level_Title FROM dbo.LabApprovalFlowLevel l
             WHERE l.Flow_ID = a.Flow_ID AND l.Level_No = a.Level_No) AS LevelTitle
    FROM dbo.LabReportApproval a
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = a.SamplecollectionID
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.Users ua ON ua.Id = a.ApprovedBy
    WHERE a.LabOrderId = @LabOrderId
    ORDER BY a.ApprovedDate DESC, a.Level_No DESC;

    DROP TABLE #S;
END;
GO

PRINT 'Updated dbo.usp_Api_PathologistDashboard_GetDetail (added previous-result delta check to RS2).';
GO
