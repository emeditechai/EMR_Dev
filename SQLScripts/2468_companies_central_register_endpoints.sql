-- ============================================================================================================
-- Migration: 2468_companies_central_register_endpoints.sql   (application database)
-- Settings > Companies > company profile: "Central Company Register" card (status + Push to Central). The register itself
-- lives in the central licence database (script 2467). Both actions are Super Admin only in code; mapped here to the
-- Companies page like the New Company wizard (no control), so the endpoint catalogue knows them. No role is granted.
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO

DECLARE @page INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'SETTINGS.COMPANIES';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'Companies', @Action = N'CentralStatus', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'Companies', @Action = N'PushToCentral', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2468 applied: Companies - Central Status / Push to Central endpoints.';
GO
