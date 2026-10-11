-- ============================================================================
-- Migration: 2217_doctor_dashboard_my_roster.sql
-- Description: OPD > Doctor Dashboard gets "My Roster": the Doctor Roster page limited to the signed-in doctor
--   (OPD/MyRoster and its look-ups). The endpoints belong to the Doctor Dashboard page's VIEW, so whoever can open
--   the dashboard can see their own roster; the full Doctor Roster page and its grants are unchanged. The server
--   always uses the doctor linked to the login, so no other doctor's roster or bookings are reachable.
--   No grant changes. Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'OPD.DOCTORDASHBOARD';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'OPD', @Action = N'MyRoster', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'OPD', @Action = N'MyRosterSchedules', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'OPD', @Action = N'MyRosterBookingCounts', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'OPD', @Action = N'MyRosterDateBookings', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'OPD', @Action = N'MyRosterSlots', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2217: Doctor Dashboard > My Roster endpoints mapped.';
GO
