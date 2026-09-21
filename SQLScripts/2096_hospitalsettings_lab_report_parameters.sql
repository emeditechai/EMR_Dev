-- ==============================================================================
-- Migration Script: 2096_hospitalsettings_lab_report_parameters.sql
-- Description: Two new LAB parameters on dbo.HospitalSettings (Hospital Settings > LAB tab, group "Reporting"):
--   LabReportEmailNotificationRequired  "Email Notification to patient (LAB Reports)"  Yes / No
--   PathologistApprovalRequired         "Pathologist Approval Required"                Yes / No
--
--   Both are per branch and default to 0 (No), so nothing changes until they are switched on.
--   These are configuration values: the screens that will act on them (report e-mail, approval step)
--   read them from here.
-- ==============================================================================

SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE Name = N'LabReportEmailNotificationRequired' AND Object_ID = Object_ID(N'[dbo].[HospitalSettings]'))
BEGIN
    ALTER TABLE [dbo].[HospitalSettings]
        ADD [LabReportEmailNotificationRequired] BIT NOT NULL CONSTRAINT DF_HospitalSettings_LabReportEmailNotificationRequired DEFAULT 0;
    PRINT 'Added LabReportEmailNotificationRequired to dbo.HospitalSettings (default 0 = No).';
END
ELSE PRINT 'LabReportEmailNotificationRequired already exists.';
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE Name = N'PathologistApprovalRequired' AND Object_ID = Object_ID(N'[dbo].[HospitalSettings]'))
BEGIN
    ALTER TABLE [dbo].[HospitalSettings]
        ADD [PathologistApprovalRequired] BIT NOT NULL CONSTRAINT DF_HospitalSettings_PathologistApprovalRequired DEFAULT 0;
    PRINT 'Added PathologistApprovalRequired to dbo.HospitalSettings (default 0 = No).';
END
ELSE PRINT 'PathologistApprovalRequired already exists.';
GO
