-- ============================================================================================================
-- Migration: 2466_lab_report_dispatch_collect_payment.sql
-- LAB > Report Dispatch: "Collect Payment" in the Action menu of a B2C bill with a balance due. It opens the same
-- payment dialog as the B2C Order List (shared _PaymentModal -> /OPD/SavePayment), so receipts, day closing, split
-- payment and money receipt work exactly as there.
--   Permission: new control COLLECT_PAYMENT ("Collect payment") on page LAB.LABREPORTDISPATCH. The endpoints the payment
--   dialog calls are also mapped to this page under that control (an endpoint mapped to several pages is allowed when
--   the user holds any of them), so a Dispatch user with Collect payment needs no B2C Order List rights.
--   Discount inside the dialog still needs DISCOUNT on a LAB billing screen (unchanged rule of /OPD/SavePayment).
--   No role is granted here: tick "Collect payment" for LAB > Lab Report Dispatch in Settings > Security.
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO

DECLARE @page INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABREPORTDISPATCH';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'COLLECT_PAYMENT', @Title = N'Collect payment',
         @Sort_Order = 35, @Control_ID = @ctl OUTPUT;

    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'OPD',             @Action = N'SavePayment',             @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'OPD',             @Action = N'GetPaymentSummary',       @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'OPD',             @Action = N'GetPaymentMethods',       @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'OPD',             @Action = N'GetDiscountApprovers',    @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabOrderBooking', @Action = N'MembershipForBilling',    @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabOrderBooking', @Action = N'MembershipSendRedeemOtp', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabOrderBooking', @Action = N'DiscountHeads',           @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'MoneyReceipt',    @Action = N'Print',                   @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2466 applied: Report Dispatch - Collect Payment (control COLLECT_PAYMENT).';
GO
