-- ============================================================================================================
-- 2420  Rate List (Franchise): the Franchise Name list offers only franchises with no rate list yet in the chosen branch
--       (endpoint LabRateListFranchise/AvailableFranchises on the page's VIEW control). No table changes. Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
DECLARE @co INT, @page INT, @view INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT p.CompanyId FROM dbo.PageMaster p JOIN dbo.PageEndpointMap e ON e.Page_ID = p.Page_ID WHERE e.Controller = N'LabRateListFranchise';
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @page = NULL; SET @view = NULL;
    SELECT TOP 1 @page = e.Page_ID, @view = e.Control_ID FROM dbo.PageEndpointMap e JOIN dbo.PageMaster p ON p.Page_ID = e.Page_ID
     WHERE p.CompanyId = @co AND e.Controller = N'LabRateListFranchise' AND e.Action = N'GetAllItems';
    IF @view IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'LabRateListFranchise', @Action = N'AvailableFranchises', @Source = 'SEED';
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2420 applied: Rate List (Franchise) offers only franchises without a rate list in the branch.';
GO
