-- ============================================================================================================
-- Migration: 2307_user_email_login.sql
-- Sign-in by e-mail: users sign in with their e-mail address instead of a user name; new users get
-- Username = their e-mail (User Master shows it read-only). E-mail must be unique in the whole application
-- (checked by the application for new and changed e-mails).
-- Backfill: every user without an e-mail gets a placeholder  <username>@<company code>.invalid  - a reserved
-- domain that can never receive mail, so no password-reset link can reach a stranger. Users who already have an
-- e-mail keep it (even when shared - sign-in then matches e-mail and password). Administrators replace the
-- placeholders with real addresses in User Master.
-- Then every user's user name becomes the e-mail (as for new users), unless that would clash (shared e-mail: only the
-- oldest user takes it; e-mail over 100 characters; already another user's user name) - those keep their user name
-- and still sign in with the e-mail. Safe to re-run (only empty e-mails / differing, free user names change).
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- placeholder e-mails for users that have none: user name (spaces -> dots) @ company code . invalid
UPDATE u
   SET u.Email = LOWER(REPLACE(LTRIM(RTRIM(u.Username)), ' ', '.')) + '@'
               + LOWER(ISNULL(NULLIF(REPLACE(LTRIM(RTRIM(c.CompanyCode)), ' ', '-'), ''), 'ecare360')) + '.invalid',
       u.LastModifiedDate = GETDATE()
  FROM dbo.Users u
  LEFT JOIN dbo.CompanyMaster c ON c.CompanyId = u.CompanyId
 WHERE NULLIF(LTRIM(RTRIM(u.Email)), '') IS NULL;
PRINT CONCAT('Placeholder e-mails given: ', @@ROWCOUNT);
GO

-- user name = e-mail for existing users too (as for new users). Skipped, keeping the old user name, when that would
-- clash: an e-mail over 100 characters, an e-mail already used as another user's user name, or an e-mail shared by
-- several users (only the oldest of them takes it). They still sign in with the e-mail.
;WITH c AS (
    SELECT u.Id, LOWER(LTRIM(RTRIM(u.Email))) AS NewName,
           ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(u.Email))) ORDER BY u.Id) AS rn
      FROM dbo.Users u
     WHERE NULLIF(LTRIM(RTRIM(u.Email)), '') IS NOT NULL
)
UPDATE u
   SET u.Username = c.NewName, u.LastModifiedDate = GETDATE()
  FROM dbo.Users u
  JOIN c ON c.Id = u.Id
 WHERE c.rn = 1 AND LEN(c.NewName) <= 100 AND u.Username <> c.NewName COLLATE Latin1_General_BIN
   AND NOT EXISTS (SELECT 1 FROM dbo.Users x WHERE x.Id <> u.Id AND x.Username = c.NewName);
PRINT CONCAT('User names set to the e-mail: ', @@ROWCOUNT);
GO

-- sign-in looks users up by e-mail
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Users_Email' AND object_id = OBJECT_ID(N'dbo.Users'))
    CREATE INDEX IX_Users_Email ON dbo.Users (Email) INCLUDE (IsActive);
GO

-- User Master: the e-mail availability check while typing
DECLARE @page INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'SETTINGS.USERS';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Users', @Action = N'CheckEmail', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

-- Doctor Master: the login e-mail availability check, mapped like the username suggestions it replaces
DECLARE @dp INT, @dc INT;
DECLARE dm CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT Page_ID, Control_ID FROM dbo.PageEndpointMap WHERE App = 'WEB' AND Controller = N'Doctors' AND Action = N'SuggestLoginUsernames';
OPEN dm; FETCH NEXT FROM dm INTO @dp, @dc;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @dp, @Control_ID = @dc, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Doctors', @Action = N'CheckLoginEmail', @Source = 'SEED';
    FETCH NEXT FROM dm INTO @dp, @dc;
END
CLOSE dm; DEALLOCATE dm;
GO

PRINT 'Script 2307 applied: sign-in by e-mail (placeholder e-mails for users without one).';
GO
