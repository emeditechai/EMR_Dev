-- ============================================================================================================
-- Migration: 2496_CENTRAL_LIC_DB_mobile_app_locate.sql
-- RUN ON THE CENTRAL LICENCE DATABASE (Central_Lic_DB; Dev_CentralLic_DB for tests) - NOT on the application database.
-- The script refuses to run anywhere else. Needs 2467, 2470 and 2490 (usernames unique across installations).
--
-- Mobile apps find their client's API from the sign-in name: one app build serves every client.
--   Central_Users.Username -> CompanyID + ApplicationUserID -> Central_Company (ID) -> ApplicationCompanyID + API address.
-- Central_Company.MobileApiUrl: the API address phones use (e.g. http://103.178.113.61:9011). Set by hand once per
-- installation; no push overwrites it. ApiUrl (ApiSettings:BaseUrl, pushed by the web application) is often a
-- localhost address the web server uses for itself, which a phone cannot reach - it is used only when MobileApiUrl is
-- empty and ApiUrl is not a localhost address.
--   usp_CentralUser_Locate : one row for a username (none when unknown): ApiUrl (NULL when no phone-usable address),
--                            ApplicationCompanyID, ApplicationUserID, ValidTo, plus the code for the reason.
-- Safe to re-run.
--
-- After running, set the phone address of each installation, e.g.:
--   UPDATE dbo.Central_Company SET MobileApiUrl = N'http://103.178.113.61:9011' WHERE InstanceKey = N'103.178.113.61,1232|dev_emr';
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF DB_NAME() NOT IN (N'Central_Lic_DB', N'Dev_CentralLic_DB') OR OBJECT_ID(N'dbo.Central_Users', N'U') IS NULL
BEGIN
    RAISERROR('Script 2496 belongs to the central licence database (Central_Lic_DB / Dev_CentralLic_DB) and needs scripts 2467 and 2470 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH(N'dbo.Central_Company', N'MobileApiUrl') IS NULL
    ALTER TABLE dbo.Central_Company ADD MobileApiUrl NVARCHAR(500) NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_Locate
    @Username NVARCHAR(256)
AS
BEGIN
    SET NOCOUNT ON;
    SET @Username = LTRIM(RTRIM(ISNULL(@Username, N'')));
    IF @Username = N'' RETURN;

    SELECT TOP (1)
           CASE WHEN NULLIF(LTRIM(RTRIM(c.MobileApiUrl)), N'') IS NOT NULL THEN LTRIM(RTRIM(c.MobileApiUrl))
                WHEN c.ApiUrl LIKE N'%://localhost%' OR c.ApiUrl LIKE N'%://127.%' OR c.ApiUrl LIKE N'%://[[]::1]%'
                  OR NULLIF(LTRIM(RTRIM(c.ApiUrl)), N'') IS NULL THEN NULL
                ELSE LTRIM(RTRIM(c.ApiUrl)) END AS ApiUrl,
           c.ApplicationCompanyID,
           u.ApplicationUserID,
           c.ValidTo,
           CASE WHEN c.ValidTo IS NOT NULL AND c.ValidTo < CAST(GETDATE() AS DATE) THEN 'EXPIRED'
                WHEN NULLIF(LTRIM(RTRIM(c.MobileApiUrl)), N'') IS NULL
                 AND (c.ApiUrl LIKE N'%://localhost%' OR c.ApiUrl LIKE N'%://127.%' OR c.ApiUrl LIKE N'%://[[]::1]%'
                      OR NULLIF(LTRIM(RTRIM(c.ApiUrl)), N'') IS NULL) THEN 'NO_ADDRESS'
                WHEN u.ApplicationUserID IS NULL THEN 'NOT_LINKED'
                ELSE 'OK' END AS Code
      FROM dbo.Central_Users u
      JOIN dbo.Central_Company c ON c.ID = u.CompanyID
     WHERE u.Username = @Username
     ORDER BY u.ID;
END
GO
PRINT 'Script 2496 applied on ' + DB_NAME() + ': Central_Company.MobileApiUrl, usp_CentralUser_Locate (mobile apps find their API).';
GO
SET NOEXEC OFF;
GO
