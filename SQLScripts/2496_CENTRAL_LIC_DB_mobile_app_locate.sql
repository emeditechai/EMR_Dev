-- ============================================================================================================
-- Migration: 2496_CENTRAL_LIC_DB_mobile_app_locate.sql
-- RUN ON THE CENTRAL LICENCE DATABASE (Central_Lic_DB; Dev_CentralLic_DB for tests) - NOT on the application database.
-- The script refuses to run anywhere else. Needs 2467, 2470 and 2490 (usernames unique across installations).
--
-- Mobile apps find their client's API from the sign-in name: one app build serves every client.
--   Central_Users.Username -> CompanyID + ApplicationUserID -> Central_Company (ID) -> ApplicationCompanyID + ApiUrl.
-- Central_Company.ApiUrl (ApiSettings:BaseUrl, pushed by the web application) must be an address phones can reach,
-- e.g. http://103.178.113.61:9011 - not localhost. A localhost / 127.x / [::1] or empty ApiUrl gives Code NO_ADDRESS,
-- so the app shows "not set up for your organisation" instead of trying an address it cannot reach.
--   usp_CentralUser_Locate : one row for a username (none when unknown): ApiUrl (NULL when not phone-usable),
--                            ApplicationCompanyID, ApplicationUserID, ValidTo, plus the code for the reason.
-- Safe to re-run. Removes Central_Company.MobileApiUrl if an earlier draft of this script added it (only when empty).
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

IF COL_LENGTH(N'dbo.Central_Company', N'MobileApiUrl') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.Central_Company WHERE NULLIF(LTRIM(RTRIM(MobileApiUrl)), N'') IS NOT NULL)
    EXEC (N'ALTER TABLE dbo.Central_Company DROP COLUMN MobileApiUrl;');
GO

CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_Locate
    @Username NVARCHAR(256)
AS
BEGIN
    SET NOCOUNT ON;
    SET @Username = LTRIM(RTRIM(ISNULL(@Username, N'')));
    IF @Username = N'' RETURN;

    SELECT TOP (1)
           CASE WHEN x.PhoneUsable = 1 THEN x.Url END AS ApiUrl,
           c.ApplicationCompanyID,
           u.ApplicationUserID,
           c.ValidTo,
           CASE WHEN c.ValidTo IS NOT NULL AND c.ValidTo < CAST(GETDATE() AS DATE) THEN 'EXPIRED'
                WHEN x.PhoneUsable = 0 THEN 'NO_ADDRESS'
                WHEN u.ApplicationUserID IS NULL THEN 'NOT_LINKED'
                ELSE 'OK' END AS Code
      FROM dbo.Central_Users u
      JOIN dbo.Central_Company c ON c.ID = u.CompanyID
     CROSS APPLY (SELECT NULLIF(LTRIM(RTRIM(c.ApiUrl)), N'') AS Url) a
     CROSS APPLY (SELECT a.Url,
                         CASE WHEN a.Url IS NULL OR a.Url LIKE N'%://localhost%' OR a.Url LIKE N'%://127.%' OR a.Url LIKE N'%://[[]::1]%'
                              THEN 0 ELSE 1 END AS PhoneUsable) x
     WHERE u.Username = @Username
     ORDER BY u.ID;
END
GO
PRINT 'Script 2496 applied on ' + DB_NAME() + ': usp_CentralUser_Locate (mobile apps find their API from Central_Company.ApiUrl).';
GO
SET NOEXEC OFF;
GO
