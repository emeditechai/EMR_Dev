-- ==============================================================================
-- Migration Script: 2114_hospitalsettings_show_lab_report_print_on_list.sql
-- Description: New LAB parameter on dbo.HospitalSettings (Hospital Settings > LAB tab, group "Reporting"):
--   ShowLabReportPrintOnList   "Show LAB Report Print on List"   Yes / No
--
--   Per branch, defaults to 0 (No), so nothing changes until switched on. Controls whether a
--   Print action is shown against each report row in LAB listing screens (Report Dispatch,
--   Pathologist Dashboard, etc.).
-- ==============================================================================

SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE Name = N'ShowLabReportPrintOnList' AND Object_ID = Object_ID(N'[dbo].[HospitalSettings]'))
BEGIN
    ALTER TABLE [dbo].[HospitalSettings]
        ADD [ShowLabReportPrintOnList] BIT NOT NULL CONSTRAINT DF_HospitalSettings_ShowLabReportPrintOnList DEFAULT 0;
    PRINT 'Added ShowLabReportPrintOnList to dbo.HospitalSettings (default 0 = No).';
END
ELSE PRINT 'ShowLabReportPrintOnList already exists.';
GO
