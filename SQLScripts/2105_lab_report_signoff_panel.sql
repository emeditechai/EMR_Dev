-- ============================================================================
-- Migration: 2105_lab_report_signoff_panel.sql
-- Description:
--   dbo.usp_Api_LabReport_GetSignoffPanel - the signature panel printed at the foot of a lab report.
--
--   One row per approval level actually signed for the bill (Pathologist Approval Flow), in level order, with the
--   signatory's name, registration number and the path of their uploaded signature image, so the PDF can print a
--   real signature block per level ("Signatory 1", "Signatory 2", ...) as a lab report is expected to carry.
--
--   A level signed by more than one pathologist across the bill's tests returns the earliest signer of that level.
--   Read-only; nothing existing is altered.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_GetSignoffPanel
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Signed AS (
        SELECT
            a.Level_No,
            a.TotalLevels,
            a.Flow_ID,
            a.ApprovedBy,
            MIN(a.ApprovedDate) AS SignedOn,
            COUNT(1)            AS TestsSigned,
            ROW_NUMBER() OVER (PARTITION BY a.Level_No ORDER BY MIN(a.ApprovedDate), a.ApprovedBy) AS rn
        FROM dbo.LabReportApproval a
        WHERE a.LabOrderId = @LabOrderId
        GROUP BY a.Level_No, a.TotalLevels, a.Flow_ID, a.ApprovedBy
    )
    SELECT
        s.Level_No                                                   AS LevelNo,
        s.TotalLevels,
        ISNULL(l.Level_Title, 'Signatory ' + CAST(s.Level_No AS VARCHAR(2))) AS LevelTitle,
        CAST(CASE WHEN s.Level_No >= s.TotalLevels THEN 1 ELSE 0 END AS BIT) AS IsFinalLevel,
        s.ApprovedBy                                                 AS UserId,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)     AS FullName,
        ISNULL(NULLIF(LTRIM(RTRIM(u.RegistrationNo)), ''), u.CertificationNo) AS RegistrationNo,
        u.SignaturePath,
        CAST(ISNULL(u.IsPathologist, 0) AS BIT)                      AS IsPathologist,
        s.SignedOn,
        s.TestsSigned
    FROM Signed s
    INNER JOIN dbo.Users u ON u.Id = s.ApprovedBy
    LEFT  JOIN dbo.LabApprovalFlowLevel l ON l.Flow_ID = s.Flow_ID AND l.Level_No = s.Level_No
    WHERE s.rn = 1
    ORDER BY s.Level_No;
END;
GO

PRINT 'Created dbo.usp_Api_LabReport_GetSignoffPanel';
GO
