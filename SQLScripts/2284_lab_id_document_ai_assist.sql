-- ============================================================================================================
-- Migration: 2284_lab_id_document_ai_assist.sql
-- LAB > B2C Booking - "Upload ID Document" AI assist: the uploaded ID document is read on the server (Tesseract OCR,
-- nothing stored or sent anywhere), its type recognised (ML.NET) and its number read (format / check digit), and the
-- page fills ID Type and ID Number. New control ID_AI_ASSIST on the page, reached through
-- POST LabOrderBooking/IdDocumentAssist.
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
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'ID_AI_ASSIST', @Title = N'AI ID document reading', @Sort_Order = 26, @Control_ID = @ctl OUTPUT;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'ID_AI_ASSIST';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabOrderBooking', @Action = N'IdDocumentAssist', @Route = N'LabOrderBooking/IdDocumentAssist', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2284 applied: LAB B2C Booking - AI ID document reading (ID_AI_ASSIST).';
GO
