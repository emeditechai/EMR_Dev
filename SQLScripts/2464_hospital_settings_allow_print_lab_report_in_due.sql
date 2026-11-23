-- ============================================================================================================
-- Migration: 2464_hospital_settings_allow_print_lab_report_in_due.sql
-- Hospital Settings > LAB: "Allow Print Lab Report in Due" (HospitalSettings.AllowPrintLabReportInDue, per branch,
-- default 0 = No). No: a B2C bill with a balance due cannot print its Lab / Microbiology report (Lab Report Entry,
-- Microbiology Report Entry, Report Dispatch). Yes: the report prints even with a due. B2B bills always print.
-- Shown and edited on the LAB tab (view and edit). Safe to re-run.
-- ============================================================================================================
IF COL_LENGTH('dbo.HospitalSettings', 'AllowPrintLabReportInDue') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD AllowPrintLabReportInDue BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_AllowPrintLabReportInDue DEFAULT (0);
GO
PRINT 'Script 2464 applied: Hospital Settings > Allow Print Lab Report in Due.';
GO
