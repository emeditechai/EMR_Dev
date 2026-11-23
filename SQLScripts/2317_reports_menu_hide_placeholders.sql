-- ============================================================================================================
-- Migration: 2317_reports_menu_hide_placeholders.sql
-- Reports menu: IPD Report, Patient Report, Billing Report and Pharmacy Report (Reports/IPDReport, PatientReport,
-- BillingReport, PharmacyReport) are taken out of the menu for every company. The pages and their role grants are
-- kept (only Show_In_Menu changes), so this can be undone by setting Show_In_Menu back to 1. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

UPDATE dbo.PageMaster
   SET Show_In_Menu = 0
 WHERE Controller = N'Reports'
   AND Action IN (N'IPDReport', N'PatientReport', N'BillingReport', N'PharmacyReport')
   AND Show_In_Menu = 1;
PRINT CONCAT('Report pages hidden from the menu: ', @@ROWCOUNT);
GO

-- menus are cached per user: refresh them
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2317 applied: IPD / Patient / Billing / Pharmacy Report removed from the Reports menu.';
GO
