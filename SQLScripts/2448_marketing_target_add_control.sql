-- 2448: LAB > Marketing Executive Sales Target - separate rights for setting a new target (ADD) and changing a saved one (EDIT).
-- Save is mapped to VIEW (one control per endpoint), and MarketingTargetsController.Save checks ADD for a new target and
-- EDIT for a saved one, so neither right alone is blocked by the filter. Roles that had EDIT keep it (EDIT = change);
-- grant ADD in Role Permissions. Run after 2447. Safe to re-run.
SET NOCOUNT ON;
GO
DECLARE @page INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = 'LAB.MARKETINGTARGETS'), @ctl INT, @edit INT;
IF @page IS NULL THROW 51480, 'Page LAB.MARKETINGTARGETS is missing - run 2447 first.', 1;
SELECT @edit = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'EDIT';
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Change a saved target', @Sort_Order = 30, @Control_ID = @edit OUTPUT;
SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'ADD';
IF @ctl IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'ADD', @Title = N'Set a new target', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
DECLARE @view INT = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'POST', @Controller = N'MarketingTargets', @Action = N'Save', @Source = 'SEED';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2448 Marketing target ADD control - done.';
GO
