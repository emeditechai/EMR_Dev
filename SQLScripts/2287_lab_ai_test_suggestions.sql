-- ============================================================================================================
-- Migration: 2287_lab_ai_test_suggestions.sql
-- LAB > B2C Booking - AI test suggestions: tests usually billed with the selected ones (learned from past B2C bills) and
-- profiles / packages covering several selected tests; shown only when Hospital Settings > Enable AI Features at
-- Billing is Yes. New control AI_SUGGEST on the page, reached through
-- GET LabOrderBooking/TestSuggestions.
-- No role or user grant is seeded: a control without a row follows the page, so every role that may use B2C Booking
-- can use it until it is denied in Settings > Security > Role Permissions. Safe to re-run.
-- ============================================================================================================
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
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'AI_SUGGEST', @Title = N'AI test suggestions', @Sort_Order = 27, @Control_ID = @ctl OUTPUT;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'AI_SUGGEST';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'LabOrderBooking', @Action = N'TestSuggestions', @Route = N'LabOrderBooking/TestSuggestions', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2287 applied: LAB B2C Booking - AI test suggestions (AI_SUGGEST).';
GO
