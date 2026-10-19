-- ============================================================================================================
-- Migration: 2296_lab_testwise_workload_report.sql
-- Reports > LAB > Testwise Workload: per test of the Investigation Master over a bill date range - test-wise patient-wise
-- details, test-wise patient count and the workload figures (sample, report, approval, turnaround against the test's
-- TAT, abnormal results), filtered by department, test category, sub category and tests; Excel / PDF built on the
-- server. Reads existing tables only (samplecollection, LabOrder, labentrydetails, LabInvestigationMaster).
-- Adds the page to Reports > LAB and maps its calls to it (a copy made earlier under the LAB menu is moved there,
-- keeping its Page_ID and any role grants). No role grants: give the page to roles in
-- Settings > Security as needed. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
DECLARE @co INT, @menu INT, @page INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = N'REPORTS.LAB';
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = (SELECT TOP 1 Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'REPORTS.LAB' AND CompanyId = @co);
    -- first version of this script put the page under the LAB menu: move it (same Page_ID, grants kept)
    UPDATE dbo.PageMaster SET Menu_ID = @menu, Page_Code = N'REPORTS.LABTESTWISEWORKLOAD', ModifiedDate = GETDATE()
     WHERE CompanyId = @co AND Page_Code = N'LAB.TESTWISEWORKLOAD'
       AND NOT EXISTS (SELECT 1 FROM dbo.PageMaster x WHERE x.CompanyId = @co AND x.Page_Code = N'REPORTS.LABTESTWISEWORKLOAD');
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'REPORTS.LABTESTWISEWORKLOAD', @Title = N'Testwise Workload',
         @Controller = N'LabTestWorkload', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 207, @Icon = N'bi bi-clipboard-data me-2',
         @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = N'REPORTS.LABTESTWISEWORKLOAD' AND Menu_ID = @menu;

    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabTestWorkload', @Action = N'Index',         @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabTestWorkload', @Action = N'Data',          @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabTestWorkload', @Action = N'Export',        @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabTestWorkload', @Action = N'Categories',    @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabTestWorkload', @Action = N'SubCategories', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabTestWorkload', @Action = N'Tests',         @Source = 'SEED';
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
-- the report reads tests by bill date
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_LabOrder_OrderDate_Branch' AND object_id = OBJECT_ID(N'dbo.LabOrder'))
    CREATE INDEX IX_LabOrder_OrderDate_Branch ON dbo.LabOrder (OrderDate, BranchId) INCLUDE (PatientId, IsActive, IsB2B);
GO
PRINT 'Script 2296 applied: Reports > LAB > Testwise Workload page.';
GO
