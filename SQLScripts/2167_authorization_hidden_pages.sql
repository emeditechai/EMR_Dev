-- ============================================================================
-- Migration: 2167_authorization_hidden_pages.sql
-- Description:
--   Server-Side Authorization - screens that exist in the code but have no menu entry,
--   added as pages with Show_In_Menu = 0 so they are protected like every other screen:
--     SETTINGS.ACCESS                       Branch-wise Role Mapping   (AccessController)
--     MASTER.LAB_MASTER.LABSAMPLEREJECTIONS Sample Rejection Master    (LabSampleRejectionsController)
--   Run after 2163 (the navigation seed).
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
DECLARE @co INT, @settings INT, @labMaster INT, @page INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN c; FETCH NEXT FROM c INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @settings = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'SETTINGS' AND CompanyId = @co;
    SELECT @labMaster = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.LAB_MASTER' AND CompanyId = @co;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @settings, @Page_Code = N'SETTINGS.ACCESS', @Title = N'Branch-wise Role Mapping',
         @Controller = N'Access', @Action = N'Index', @Show_In_Menu = 0, @Sort_Order = 900, @Icon = N'bi bi-diagram-2 me-2', @Page_ID = @page OUTPUT;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @labMaster, @Page_Code = N'MASTER.LAB_MASTER.LABSAMPLEREJECTIONS', @Title = N'Sample Rejection Master',
         @Controller = N'LabSampleRejections', @Action = N'Index', @Show_In_Menu = 0, @Sort_Order = 900, @Icon = N'bi bi-x-octagon me-2', @Page_ID = @page OUTPUT;
    FETCH NEXT FROM c INTO @co;
END
CLOSE c; DEALLOCATE c;
PRINT 'Script 2167 applied: hidden pages for Access and LabSampleRejections.';
GO
