-- ============================================================================================================
-- Migration: 2516_marketing_executive_check_email_generic.sql   (application database)
-- Master > Marketing Executive: the live e-mail check no longer names who holds the e-mail ("Already used by the login of
-- <name>" told the user about another account) - a standard message instead, as User Master / Doctor / Franchise.
-- usp_Api_MarketingExecutive_CheckEmail (2444) is replaced; its result columns are unchanged. Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_MarketingExecutive_CheckEmail @CompanyId INT, @ExecutiveId INT = NULL, @EmailId NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    SET @EmailId = NULLIF(LOWER(LTRIM(RTRIM(@EmailId))), N'');
    DECLARE @Own INT = (SELECT LoginUserId FROM dbo.MarketingExecutive WHERE ExecutiveId = @ExecutiveId AND CompanyId = @CompanyId AND IsDeleted = 0);
    DECLARE @Taken BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.Users
                                            WHERE Id <> ISNULL(@Own, 0) AND (LOWER(LTRIM(RTRIM(Email))) = @EmailId OR Username = @EmailId))
                              THEN 1 ELSE 0 END;
    SELECT CAST(CASE WHEN @EmailId IS NOT NULL AND @Taken = 0 THEN 1 ELSE 0 END AS BIT) AS Available,
           CASE WHEN @EmailId IS NULL THEN N'Enter an e-mail ID.'
                WHEN @Taken = 1 THEN N'This e-mail is already in use as a sign-in and cannot be used. Please use a different e-mail address.'
                ELSE N'Available for the login.' END AS Message,
           CAST(CASE WHEN @Own IS NULL THEN 0 ELSE 1 END AS BIT) AS HasLogin;
END;
GO
PRINT 'Script 2516 applied: Marketing Executive e-mail check - generic message.';
GO
