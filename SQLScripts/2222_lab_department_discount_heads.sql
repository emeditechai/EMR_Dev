-- ============================================================================
-- Migration: 2222_lab_department_discount_heads.sql
-- Description: B2C LAB department-wise discount. The payment screen's "Department-wise" popup loads the bill's
--   discount heads (one per department + Packages) from POST LabOrderBooking/DiscountHeads. The endpoint belongs to
--   the VIEW of the two pages that open the payment screen for a B2C bill: B2C Booking and B2C Order List.
--   No table changes (each test's discount is kept in the existing PaymentLineItem columns) and no grant changes.
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code IN (N'LAB.LABORDERBOOKING.B2CBOOKING', N'LAB.LABORDERBOOKING.B2CORDERLIST');
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabOrderBooking', @Action = N'DiscountHeads', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2222: LabOrderBooking/DiscountHeads mapped to B2C Booking and B2C Order List.';
GO
