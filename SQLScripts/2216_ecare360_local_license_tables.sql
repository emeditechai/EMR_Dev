-- ============================================================================
-- Migration: 2216_ecare360_local_license_tables.sql
-- Description: eCare360 licensing - the two LOCAL tables in the application database (never the central one).
--   dbo.ClientAppLicense               this installation's copy of its central licence row: hardware columns AES-GCM
--                                      encrypted, FingerprintHash (SHA-256 of MAC|DISK|BOARD) for lookup, and the local
--                                      LastRemoteValidatedAt + LocalSignature (HMAC) that decide the once-a-day skip
--   dbo.ClientAppLicenseValidationLog  one row per licence evaluation (Settings > Licence shows the latest)
--   The web app also creates them at startup when Licensing:Enabled is true (same statements); safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.ClientAppLicense', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ClientAppLicense (
        Id                    BIGINT IDENTITY(1,1) PRIMARY KEY,
        ClientCode            VARCHAR(32)   NOT NULL,
        ClientName            NVARCHAR(200) NOT NULL,
        ContactNumber         VARCHAR(30)   NULL,
        EmailID               NVARCHAR(200) NULL,
        LicenseKey            NVARCHAR(100) NOT NULL,
        ServerMacID           NVARCHAR(512) NOT NULL,   -- AES-GCM ciphertext
        HardDiskNumber        NVARCHAR(512) NOT NULL,   -- AES-GCM ciphertext
        MotherboardNumber     NVARCHAR(512) NOT NULL,   -- AES-GCM ciphertext
        FingerprintHash       CHAR(64)      NOT NULL,   -- SHA-256 of MAC|DISK|BOARD
        PublicIPAddress       VARCHAR(60)   NULL,
        AppUrl                NVARCHAR(500) NOT NULL,
        ProductType           NVARCHAR(100) NOT NULL,
        StartDate             DATETIME NOT NULL,
        ExpiryDate            DATETIME NOT NULL,
        AMC_Expireddate       DATETIME NULL,
        IsActive              BIT NOT NULL,
        OTP_Verified          BIT NOT NULL,
        LastLoginDate         DATETIME NULL,            -- copied from central, informational only
        IsDisplayAlerts       BIT NOT NULL CONSTRAINT DF_ClientAppLicense_IsDisplayAlerts DEFAULT 0,
        AlertStartdate        DATE NULL,
        AlertStartTime        TIME(0) NULL,
        AlertEnddate          DATE NULL,
        AlertEndTime          TIME(0) NULL,
        AlertMessage          NVARCHAR(MAX) NULL,
        CreatedAt             DATETIME NOT NULL,
        LastRemoteValidatedAt DATETIME NULL,            -- last time central said Valid
        LocalSignature        CHAR(64) NULL,            -- HMAC-SHA256
        SyncedAt              DATETIME NOT NULL CONSTRAINT DF_ClientAppLicense_SyncedAt DEFAULT GETDATE()
    );
    CREATE UNIQUE INDEX UX_Local_ClientCode ON dbo.ClientAppLicense(ClientCode);
    CREATE UNIQUE INDEX UX_Local_LicenseKey ON dbo.ClientAppLicense(LicenseKey);
    CREATE INDEX IX_Local_Fingerprint_Url ON dbo.ClientAppLicense(FingerprintHash, AppUrl);
END
GO

IF OBJECT_ID('dbo.ClientAppLicenseValidationLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ClientAppLicenseValidationLog (
        Id                BIGINT IDENTITY(1,1) PRIMARY KEY,
        ClientCode        VARCHAR(32)   NULL,
        LicenseKey        NVARCHAR(100) NULL,
        ValidatedAt       DATETIME      NOT NULL,
        FingerprintHash   CHAR(64)      NULL,
        IsMatch           BIT NOT NULL,
        IsExpired         BIT NOT NULL,
        IsRemoteReachable BIT NOT NULL,
        IsOfflineGrace    BIT NOT NULL CONSTRAINT DF_ClientAppLicenseValidationLog_Grace DEFAULT 0,
        Result            VARCHAR(40)   NOT NULL,
        FailureReason     NVARCHAR(500) NULL,
        RequestIp         VARCHAR(60)   NULL,
        AppUrl            NVARCHAR(500) NULL,
        CreatedAt         DATETIME NOT NULL CONSTRAINT DF_ClientAppLicenseValidationLog_CreatedAt DEFAULT GETDATE()
    );
    CREATE INDEX IX_LocalLog_ClientCode_ValidatedAt ON dbo.ClientAppLicenseValidationLog(ClientCode, ValidatedAt DESC);
END
GO

PRINT 'Script 2216 applied: eCare360 local licence tables.';
GO

-- ── Settings > Licence (administrators): page, controls and endpoints; no grant is seeded ──
DECLARE @co INT, @menu INT, @page INT, @ctl INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'SETTINGS' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'SETTINGS.LICENSE', @Title = N'Licence',
             @Controller = N'License', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 95, @Icon = N'bi bi-shield-check me-2',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'RECHECK', @Title = N'Re-check with licence server', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
        SET @ctl = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'License', @Action = N'Index', @Source = 'SEED';
        SET @ctl = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'RECHECK');
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'License', @Action = N'ClearCache', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2216: Settings > Licence page added.';
GO
