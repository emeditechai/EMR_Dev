-- ============================================================================================================
-- Migration: 2515_lab_franchise_check_login_email.sql   (application database)
-- Master > Lab Franchises: live check of the franchise's login e-mail (LabFranchises/CheckLoginEmail, GET) - free in this
-- application and in the central user register (SQLScripts/2490), as User Master / Doctor / Marketing Executive.
-- Mapped to the page (no control), like the page itself. No role is granted. Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
DECLARE @page INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.LABFRANCHISES';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'LabFranchises', @Action = N'CheckLoginEmail', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2515 applied: Lab Franchises > live login e-mail check.';
GO
