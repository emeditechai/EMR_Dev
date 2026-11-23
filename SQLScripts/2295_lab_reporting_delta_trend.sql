-- ============================================================================================================
-- Migration: 2295_lab_reporting_delta_trend.sql
-- Lab Report Entry > delta check: a graph icon beside "Previous:" opens the patient's last 5 results of the test with a
-- small trend graph (read-only). Its data call, LabReporting/DeltaHistoryJson, belongs to the Lab Reporting page
-- (LAB.LABREPORTING) like the page's other calls: whoever can open the page can see the trend. No role grants change.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
DECLARE @page INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABREPORTING';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'LabReporting', @Action = N'DeltaHistoryJson', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
GO
PRINT 'Script 2295 applied: Lab Report Entry delta trend endpoint mapped.';
GO
