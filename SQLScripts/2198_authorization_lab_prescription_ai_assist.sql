-- ============================================================================
-- Migration: 2198_authorization_lab_prescription_ai_assist.sql
-- Description: LAB > B2C Booking - "AI assist" (read an uploaded prescription and suggest its tests) becomes a control
--   of the page, AI_ASSIST, reached through POST LabOrderBooking/PrescriptionAssist, so Settings > Security >
--   Role Permissions can decide per role who may use it.
--   No role or user grant is seeded: a control without a row follows the page, so every role that may use B2C Booking
--   can use the assist until it is denied in Role Permissions. Every user's Permission_Version is bumped so the new
--   control is picked up at once.
--   Run after 2197.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABORDERBOOKING.B2CBOOKING';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'AI_ASSIST', @Title = N'AI prescription assist', @Sort_Order = 25, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabOrderBooking', @Action = N'PrescriptionAssist', @Route = N'LabOrderBooking/PrescriptionAssist', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

SELECT c.Control_ID, c.Control_Code, c.Title, e.Http_Method, e.Route
FROM dbo.PageMaster p
JOIN dbo.PageControlMaster c ON c.Page_ID = p.Page_ID AND c.Control_Code = 'AI_ASSIST'
LEFT JOIN dbo.PageEndpointMap e ON e.Control_ID = c.Control_ID
WHERE p.Page_Code = N'LAB.LABORDERBOOKING.B2CBOOKING';
GO
