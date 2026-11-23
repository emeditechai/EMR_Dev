-- ============================================================================================================
-- Migration: 2323_opd_last_visit_badge.sql
-- OPD Patient Registration / New Service Booking: when a patient is loaded, the last OPD visit (date, doctor) shows
-- beside the registration badge. EMR.Web OPD/GetLastVisit is mapped to the same pages and control as
-- OPD/GetRegistrationValidity (VIEW). No role grants change. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
DECLARE @page INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT e.Page_ID, e.Control_ID FROM dbo.PageEndpointMap e
    WHERE e.App = 'WEB' AND e.Controller = N'OPD' AND e.Action = N'GetRegistrationValidity';
OPEN pc; FETCH NEXT FROM pc INTO @page, @ctl;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'OPD', @Action = N'GetLastVisit', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page, @ctl;
END
CLOSE pc; DEALLOCATE pc;
GO
PRINT 'Script 2323 applied: OPD last visit badge endpoint.';
GO
