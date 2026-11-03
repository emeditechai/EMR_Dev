-- ============================================================================================================
-- Migration: 2394_utility_app_downloads.sql
-- Utility > App Downloads: the Android apps uploaded in Hospital Settings (SQLScripts/2393) - the latest version of
-- each app first, then the earlier ones - downloaded from the App FTP server through the application.
--   usp_AppApk_Get: one release of the company (for the download).
--   Page UTILITY.APPDOWNLOADS under Utility. The link is open: no sign-in or permission is needed (endpoints public).
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_AppApk_Get
    @CompanyId INT, @ApkId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.ApkId, r.BranchId, r.AppName, r.VersionName, r.VersionCode, r.OriginalFileName, r.FileName, r.FilePath,
           r.FileSizeBytes, r.Sha256, r.ReleaseNotes, r.IsLatest, r.UploadedDate
      FROM dbo.AppApkRelease r
     WHERE r.ApkId = @ApkId AND r.CompanyId = @CompanyId AND r.IsActive = 1;
END
GO

DECLARE @co INT, @menu INT, @page INT, @view INT, @dl INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'UTILITY' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'UTILITY.APPDOWNLOADS',
             @Title = N'App Downloads', @Controller = N'AppDownloads', @Action = N'Index',
             @Show_In_Menu = 1, @Sort_Order = 55, @Icon = N'bi bi-android2 me-2', @Page_ID = @page OUTPUT;
        SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        SET @dl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'DOWNLOAD', @Title = N'Download app files', @Sort_Order = 20, @Control_ID = @dl OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'AppDownloads', @Action = N'Index', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @dl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'AppDownloads', @Action = N'Download', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

-- an open link: no sign-in and no permission needed for the page or the download
UPDATE dbo.PageEndpointMap SET Is_Public = 1 WHERE Controller = N'AppDownloads' AND Action IN (N'Index', N'Download');
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2394 applied: Utility > App Downloads.';
GO
