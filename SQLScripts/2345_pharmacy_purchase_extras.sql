-- ============================================================================================================
-- 2345  Pharmacy > Purchase extras (after 2344):
--   * GRN: scanned supplier bill attachment (PDF / image) - control ATTACH; rate history look-up.
--   * Purchase Order: e-mail the order to the supplier - control EMAIL; rate history look-up.
--   * New page Pharmacy > Purchase > Purchase Register (GRN-wise purchases with GST split, rate-wise summary).
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.PhGrn', 'AttachmentPath') IS NULL
    ALTER TABLE dbo.PhGrn ADD AttachmentPath NVARCHAR(300) NULL, AttachmentName NVARCHAR(150) NULL;
GO
IF COL_LENGTH('dbo.PhPurchaseOrder', 'EmailedTo') IS NULL
    ALTER TABLE dbo.PhPurchaseOrder ADD EmailedTo NVARCHAR(150) NULL, EmailedDate DATETIME NULL;
GO

DECLARE @co INT, @menu INT, @page INT, @view INT, @ctl INT;
SELECT TOP 1 @menu = Menu_ID, @co = CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY.PURCHASE';

-- GRN: rate history + attachment view (VIEW), attach (ATTACH)
SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = N'PHARMACY.GRN';
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhGrns', @Action = N'RateHistory', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhGrns', @Action = N'Attachment', @Source = 'SEED';
SET @ctl = NULL;
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'ATTACH', @Title = N'Attach the scanned supplier bill', @Sort_Order = 50, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhGrns', @Action = N'Attach', @Source = 'SEED';

-- Purchase Order: rate history (VIEW), e-mail (EMAIL)
SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = N'PHARMACY.PURCHASEORDER';
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhPurchaseOrders', @Action = N'RateHistory', @Source = 'SEED';
SET @ctl = NULL;
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EMAIL', @Title = N'E-mail the order to the supplier', @Sort_Order = 60, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhPurchaseOrders', @Action = N'Email', @Source = 'SEED';

-- Purchase Register (view only)
SET @page = NULL;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'PHARMACY.PURCHASEREGISTER', @Title = N'Purchase Register', @Controller = N'PhPurchaseRegister', @Action = N'Index',
     @Show_In_Menu = 1, @Sort_Order = 60, @Icon = N'bi bi-journal-text me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhPurchaseRegister', @Action = N'Index', @Source = 'SEED';
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2345 applied: Pharmacy purchase extras (GRN bill attachment, PO e-mail, rate history, Purchase Register).';
GO
