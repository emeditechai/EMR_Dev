-- ============================================================================================================
-- Migration: 2297_lab_audit_history_workflow.sql
-- Audit History modal (Lab Reporting / Image / Microbiology / Un-Authorize / Report Approval): a workflow tracker
-- above the activity list shows every stage of the bill from booking to report delivery. Its data call,
-- LabReporting/GetOrderWorkflowJson, is mapped exactly like the modal's existing call (GetAuditHistoryJson): same
-- pages and controls, so whoever sees the audit history sees the workflow. No role grants change. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
DECLARE @page INT, @ctl INT;
DECLARE m CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT Page_ID, Control_ID FROM dbo.PageEndpointMap
     WHERE App = 'WEB' AND Controller = N'LabReporting' AND Action = N'GetAuditHistoryJson';
OPEN m; FETCH NEXT FROM m INTO @page, @ctl;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'LabReporting', @Action = N'GetOrderWorkflowJson', @Source = 'SEED';
    FETCH NEXT FROM m INTO @page, @ctl;
END
CLOSE m; DEALLOCATE m;
GO
PRINT 'Script 2297 applied: Audit History workflow tracker endpoint mapped.';
GO
