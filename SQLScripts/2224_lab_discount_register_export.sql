-- ============================================================================
-- Migration: 2224_lab_discount_register_export.sql
-- Description: Reports > LAB > Discount Register - Excel and PDF are now built on the server (bill-wise with each
--   bill's test-wise discount): GET Reports/ExportLabDiscountRegister. It returns the same data as the page's
--   GetLabDiscountRegisterData, so it belongs to the page's VIEW, as that endpoint does. No grant changes.
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'REPORTS.LABDISCOUNTREGISTER';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'Reports', @Action = N'ExportLabDiscountRegister', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2224: Reports/ExportLabDiscountRegister mapped to the Discount Register VIEW.';
GO
