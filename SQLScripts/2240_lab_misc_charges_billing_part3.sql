-- ============================================================================
-- Migration: 2240_lab_misc_charges_billing_part3.sql   (run after part 2)
-- Description: LabOrderBooking/MiscChargesForBilling (the misc charges offered on the booking screens) is opened with
--   the VIEW control of the B2C and B2B booking pages. No role grants are changed. Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code IN (N'LAB.LABORDERBOOKING.B2CBOOKING', N'LAB.LABORDERBOOKING.B2BBOOKING');
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'LabOrderBooking', @Action = N'MiscChargesForBilling', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2240 part 3 applied: MiscChargesForBilling endpoint mapped to the B2C / B2B booking pages.';
GO
