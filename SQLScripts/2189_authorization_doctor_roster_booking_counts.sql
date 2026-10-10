-- ============================================================================
-- Migration: 2189_authorization_doctor_roster_booking_counts.sql
-- Description: OPD > Doctor Roster loads the booked count of every doctor and day of the view in one call
--   (GET DoctorRoster/GetBookingCounts) instead of one call per doctor and date. The endpoint belongs to the page's
--   VIEW, like the roster's other look-ups (GetDoctorSchedules, GetDateBookings). No grant changes.
--   Run after 2188.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'OPD.DOCTORROSTER';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'DoctorRoster', @Action = N'GetBookingCounts', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
GO
