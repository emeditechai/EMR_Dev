-- ============================================================================================================
-- Migration: 2393_app_apk_ftp_upload.sql
-- Hospital Settings > LAB: "FTP server for App (APK) Upload" - its own FTP credentials (same pattern as the External
-- Document FTP, SQLScripts/2354) and an upload of Android app files (.apk) with a version history.
--   AppFtpSettings : host / port / user / password (encrypted by the application) / root folder / passive / FTPS, per branch
--                    (a branch without its own uses its company's HO branch settings)
--   AppApkRelease  : every uploaded APK - app name, version name / code, file, size, SHA-256, FTP path, notes, who / when;
--                    one release per app is marked Latest (the newest upload, or the one chosen)
--   Procedures: usp_AppFtp_Get / usp_AppFtp_Save, usp_AppApk_Save / usp_AppApk_List / usp_AppApk_SetLatest / usp_AppApk_Remove
--   Endpoints on SETTINGS.HOSPITALSETTINGS (like the FTP endpoints of 2354). No role is granted here.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.AppFtpSettings', 'U') IS NULL
CREATE TABLE dbo.AppFtpSettings
(
    FtpSettingId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppFtpSettings PRIMARY KEY,
    CompanyId     INT            NOT NULL,
    BranchId      INT            NOT NULL,
    Host          NVARCHAR(200)  NOT NULL,
    Port          INT            NOT NULL CONSTRAINT DF_AppFtpSettings_Port DEFAULT (21),
    UserName      NVARCHAR(150)  NOT NULL,
    PasswordEnc   NVARCHAR(MAX)  NULL,
    RootFolder    NVARCHAR(300)  NOT NULL CONSTRAINT DF_AppFtpSettings_Root DEFAULT (N'emedidoc/apps'),
    UsePassive    BIT            NOT NULL CONSTRAINT DF_AppFtpSettings_Passive DEFAULT (1),
    UseFtps       BIT            NOT NULL CONSTRAINT DF_AppFtpSettings_Ftps DEFAULT (0),
    IsActive      BIT            NOT NULL CONSTRAINT DF_AppFtpSettings_Active DEFAULT (1),
    ModifiedBy    INT            NULL,
    ModifiedDate  DATETIME       NOT NULL CONSTRAINT DF_AppFtpSettings_Modified DEFAULT (GETDATE()),
    CONSTRAINT UQ_AppFtpSettings_Branch UNIQUE (BranchId)
);
GO

IF OBJECT_ID('dbo.AppApkRelease', 'U') IS NULL
CREATE TABLE dbo.AppApkRelease
(
    ApkId            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppApkRelease PRIMARY KEY,
    CompanyId        INT            NOT NULL,
    BranchId         INT            NOT NULL,
    AppName          NVARCHAR(100)  NOT NULL,
    VersionName      NVARCHAR(50)   NOT NULL,
    VersionCode      INT            NULL,
    OriginalFileName NVARCHAR(260)  NOT NULL,
    FileName         NVARCHAR(260)  NOT NULL,
    FilePath         NVARCHAR(600)  NOT NULL,
    FileSizeBytes    BIGINT         NOT NULL,
    Sha256           CHAR(64)       NULL,
    ReleaseNotes     NVARCHAR(1000) NULL,
    IsLatest         BIT            NOT NULL CONSTRAINT DF_AppApkRelease_Latest DEFAULT (0),
    IsActive         BIT            NOT NULL CONSTRAINT DF_AppApkRelease_Active DEFAULT (1),
    UploadedBy       INT            NULL,
    UploadedDate     DATETIME       NOT NULL CONSTRAINT DF_AppApkRelease_Uploaded DEFAULT (GETDATE()),
    ModifiedBy       INT            NULL,
    ModifiedDate     DATETIME       NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AppApkRelease_Company_App')
    CREATE INDEX IX_AppApkRelease_Company_App ON dbo.AppApkRelease (CompanyId, AppName, IsActive, UploadedDate DESC);
GO

-- the settings a branch uses: its own (@OwnOnly = 1) or, without them, its company's HO branch's / any of the company
CREATE OR ALTER PROCEDURE dbo.usp_AppFtp_Get
    @CompanyId INT, @BranchId INT, @OwnOnly BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 s.FtpSettingId, s.CompanyId, s.BranchId, s.Host, s.Port, s.UserName, s.PasswordEnc, s.RootFolder,
           s.UsePassive, s.UseFtps, s.ModifiedDate
      FROM dbo.AppFtpSettings s
      LEFT JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId
     WHERE s.IsActive = 1
       AND (s.BranchId = @BranchId OR (@OwnOnly = 0 AND s.CompanyId = @CompanyId))
     ORDER BY CASE WHEN s.BranchId = @BranchId THEN 0 WHEN ISNULL(b.IsHOBranch, 0) = 1 THEN 1 ELSE 2 END, s.FtpSettingId;
END
GO

-- @PasswordEnc NULL keeps the saved password
CREATE OR ALTER PROCEDURE dbo.usp_AppFtp_Save
    @CompanyId INT, @BranchId INT, @Host NVARCHAR(200), @Port INT, @UserName NVARCHAR(150), @PasswordEnc NVARCHAR(MAX) = NULL,
    @RootFolder NVARCHAR(300), @UsePassive BIT, @UseFtps BIT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dbo.AppFtpSettings AS t
    USING (SELECT @BranchId AS BranchId) AS src ON t.BranchId = src.BranchId
    WHEN MATCHED THEN UPDATE SET Host = @Host, Port = @Port, UserName = @UserName, PasswordEnc = COALESCE(@PasswordEnc, t.PasswordEnc),
         RootFolder = @RootFolder, UsePassive = @UsePassive, UseFtps = @UseFtps, IsActive = 1, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHEN NOT MATCHED THEN INSERT (CompanyId, BranchId, Host, Port, UserName, PasswordEnc, RootFolder, UsePassive, UseFtps, ModifiedBy)
         VALUES (@CompanyId, @BranchId, @Host, @Port, @UserName, @PasswordEnc, @RootFolder, @UsePassive, @UseFtps, @UserId);
END
GO

-- a new upload: kept in the history and marked Latest for its app (the app's other releases lose the mark)
CREATE OR ALTER PROCEDURE dbo.usp_AppApk_Save
    @CompanyId INT, @BranchId INT, @AppName NVARCHAR(100), @VersionName NVARCHAR(50), @VersionCode INT = NULL,
    @OriginalFileName NVARCHAR(260), @FileName NVARCHAR(260), @FilePath NVARCHAR(600), @FileSizeBytes BIGINT,
    @Sha256 CHAR(64) = NULL, @ReleaseNotes NVARCHAR(1000) = NULL, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
        UPDATE dbo.AppApkRelease SET IsLatest = 0
         WHERE CompanyId = @CompanyId AND AppName = @AppName AND IsLatest = 1;
        INSERT dbo.AppApkRelease (CompanyId, BranchId, AppName, VersionName, VersionCode, OriginalFileName, FileName, FilePath,
                                  FileSizeBytes, Sha256, ReleaseNotes, IsLatest, UploadedBy)
        VALUES (@CompanyId, @BranchId, @AppName, @VersionName, @VersionCode, @OriginalFileName, @FileName, @FilePath,
                @FileSizeBytes, @Sha256, NULLIF(LTRIM(RTRIM(@ReleaseNotes)), N''), 1, @UserId);
    COMMIT;
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS ApkId;
END
GO

-- the company's releases, newest first (the app names for the upload's suggestions come from here too)
CREATE OR ALTER PROCEDURE dbo.usp_AppApk_List
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.ApkId, r.BranchId, br.BranchName, r.AppName, r.VersionName, r.VersionCode, r.OriginalFileName, r.FileName, r.FilePath,
           r.FileSizeBytes, r.Sha256, r.ReleaseNotes, r.IsLatest, r.UploadedDate,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UploadedByName
      FROM dbo.AppApkRelease r
      LEFT JOIN dbo.Users u ON u.Id = r.UploadedBy
      LEFT JOIN dbo.Branchmaster br ON br.BranchID = r.BranchId
     WHERE r.CompanyId = @CompanyId AND r.IsActive = 1
     ORDER BY r.AppName, r.UploadedDate DESC, r.ApkId DESC;
END
GO

-- marks an earlier release as the app's Latest (e.g. to roll back)
CREATE OR ALTER PROCEDURE dbo.usp_AppApk_SetLatest
    @CompanyId INT, @ApkId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @App NVARCHAR(100) = (SELECT AppName FROM dbo.AppApkRelease WHERE ApkId = @ApkId AND CompanyId = @CompanyId AND IsActive = 1);
    IF @App IS NULL BEGIN RAISERROR('The release was not found.', 16, 1); RETURN; END
    BEGIN TRANSACTION;
        UPDATE dbo.AppApkRelease SET IsLatest = CASE WHEN ApkId = @ApkId THEN 1 ELSE 0 END,
               ModifiedBy = CASE WHEN ApkId = @ApkId THEN @UserId ELSE ModifiedBy END,
               ModifiedDate = CASE WHEN ApkId = @ApkId THEN GETDATE() ELSE ModifiedDate END
         WHERE CompanyId = @CompanyId AND AppName = @App AND IsActive = 1;
    COMMIT;
END
GO

-- removes a release from the list (the row is kept, inactive); a removed Latest passes the mark to the newest one left
CREATE OR ALTER PROCEDURE dbo.usp_AppApk_Remove
    @CompanyId INT, @ApkId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @App NVARCHAR(100), @WasLatest BIT;
    SELECT @App = AppName, @WasLatest = IsLatest FROM dbo.AppApkRelease WHERE ApkId = @ApkId AND CompanyId = @CompanyId AND IsActive = 1;
    IF @App IS NULL BEGIN RAISERROR('The release was not found.', 16, 1); RETURN; END
    BEGIN TRANSACTION;
        UPDATE dbo.AppApkRelease SET IsActive = 0, IsLatest = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE ApkId = @ApkId;
        IF @WasLatest = 1
            UPDATE dbo.AppApkRelease SET IsLatest = 1
             WHERE ApkId = (SELECT TOP 1 ApkId FROM dbo.AppApkRelease WHERE CompanyId = @CompanyId AND AppName = @App AND IsActive = 1
                             ORDER BY UploadedDate DESC, ApkId DESC);
    COMMIT;
END
GO

-- endpoints of the Hospital Settings page (like the report-document FTP endpoints of 2354)
DECLARE @settings INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'SETTINGS.HOSPITALSETTINGS';
OPEN pc; FETCH NEXT FROM pc INTO @settings;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @settings, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'HospitalSettings', @Action = N'AppFtpSettings',     @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @settings, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'HospitalSettings', @Action = N'SaveAppFtpSettings', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @settings, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'HospitalSettings', @Action = N'TestAppFtpSettings', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @settings, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'HospitalSettings', @Action = N'ApkReleases',        @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @settings, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'HospitalSettings', @Action = N'UploadApk',          @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @settings, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'HospitalSettings', @Action = N'SetLatestApk',       @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @settings, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'HospitalSettings', @Action = N'RemoveApk',          @Source = 'SEED';
    FETCH NEXT FROM pc INTO @settings;
END
CLOSE pc; DEALLOCATE pc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2393 applied: FTP server for App (APK) Upload + APK version history.';
GO
