-- 2429  Master > IPD > Bed: Building -> Floor -> Ward -> Room on the bed form. The two new lookups belong to the
--       Bed master page (same control as its ward / room lookups). Safe to re-run.
SET NOCOUNT ON;
DECLARE @page INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.BEDS' AND CompanyId = 1);
DECLARE @view INT = (SELECT Control_ID FROM dbo.PageEndpointMap WHERE Page_ID = @page AND Controller = N'Beds' AND Action = N'GetWardsByBuilding' AND Http_Method = 'GET');
IF @page IS NOT NULL AND @view IS NOT NULL
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Beds', @Action = N'GetFloorsByBuilding', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Beds', @Action = N'GetWardsByFloor', @Source = 'SEED';
END
PRINT '2429 bed master floor lookups mapped.';
GO
