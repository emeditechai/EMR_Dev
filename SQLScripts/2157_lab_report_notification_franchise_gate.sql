-- ============================================================================
-- Migration: 2157_lab_report_notification_franchise_gate.sql
-- Description:
--   B2B Lab Bill + its associated Approved Report: the patient is only ever emailed or
--   WhatsApp'd (bill on creation, report on final approval) when the booking Franchise's
--   dbo.LabFranchiseMaster.IsNotificationRequired flag (Master > Franchise Setup) is ON.
--   When a franchise has it OFF, the franchise is expected to hand the bill/report to the
--   patient itself, so neither channel fires for that franchise's B2B orders.
--   B2C orders are entirely unaffected - they have no franchise and keep their existing behaviour.
--
--   Extends the two existing "is this bill final, who to notify" procs with the same
--   dbo.LabFranchiseMaster join already used everywhere else B2B orders resolve their franchise
--   (e.g. SQLScripts/2054_b2b_print_bill_and_b2b_rate_status.sql):
--     dbo.usp_LabReportEmail_GetState     (SQLScripts/2117) + IsB2B, NotificationAllowed
--     dbo.usp_LabReportWhatsApp_GetState  (SQLScripts/2156) + NotificationAllowed (was: hard B2B skip)
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReportEmail_GetState
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Total INT, @Approved INT, @FinalApprovedOn DATETIME2(0);

    SELECT
        @Total    = COUNT(1),
        @Approved = SUM(CASE WHEN led.ReportStatusId = 5 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN 1 ELSE 0 END),
        @FinalApprovedOn = MAX(CASE WHEN led.ReportStatusId = 5 THEN COALESCE(led.Approved_Date, led.ModifiedDate) END)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND ISNULL(sc.Iscancelled, 0) = 0
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND sc.CollectionstatusID <> 4;

    SELECT
        lo.LabOrderId,
        lo.BranchId,
        lo.BillNo,
        lo.TokenNo,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        NULLIF(LTRIM(RTRIM(p.EmailId)), '') AS PatientEmail,
        ISNULL(@Total, 0)    AS TotalTests,
        ISNULL(@Approved, 0) AS ApprovedTests,
        CAST(CASE WHEN ISNULL(@Total, 0) > 0 AND @Approved = @Total AND @FinalApprovedOn IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsFinal,
        @FinalApprovedOn AS FinalApprovedOn,
        CAST(ISNULL(hs.LabReportEmailNotificationRequired, 0) AS BIT) AS EmailEnabled,
        CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 AND lo.AgentType = 'F'
                  THEN ISNULL(f.IsNotificationRequired, 0)
                  ELSE 1 END AS BIT) AS NotificationAllowed
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    OUTER APPLY (SELECT TOP 1 h.LabReportEmailNotificationRequired
                   FROM dbo.HospitalSettings h
                  WHERE h.BranchID = lo.BranchId AND h.IsActive = 1
                  ORDER BY h.Id DESC) hs
    WHERE lo.LabOrderId = @LabOrderId AND lo.IsActive = 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReportWhatsApp_GetState
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Total INT, @Approved INT, @FinalApprovedOn DATETIME2(0);

    SELECT
        @Total    = COUNT(1),
        @Approved = SUM(CASE WHEN led.ReportStatusId = 5 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN 1 ELSE 0 END),
        @FinalApprovedOn = MAX(CASE WHEN led.ReportStatusId = 5 THEN COALESCE(led.Approved_Date, led.ModifiedDate) END)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND ISNULL(sc.Iscancelled, 0) = 0
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND sc.CollectionstatusID <> 4;

    SELECT
        lo.LabOrderId,
        lo.BranchId,
        lo.BillNo,
        lo.TokenNo,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        NULLIF(LTRIM(RTRIM(p.PhoneNumber)), '') AS PatientPhone,
        CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B,
        ISNULL(@Total, 0)    AS TotalTests,
        ISNULL(@Approved, 0) AS ApprovedTests,
        CAST(CASE WHEN ISNULL(@Total, 0) > 0 AND @Approved = @Total AND @FinalApprovedOn IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsFinal,
        @FinalApprovedOn AS FinalApprovedOn,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 AND lo.AgentType = 'F'
                  THEN ISNULL(f.IsNotificationRequired, 0)
                  ELSE 1 END AS BIT) AS NotificationAllowed
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    WHERE lo.LabOrderId = @LabOrderId AND lo.IsActive = 1;
END;
GO

PRINT 'Script 2157 applied: LAB Report notification franchise gate ready.';
GO
