-- ============================================================================================================
-- Migration: 2471_users_central_user_id.sql   (application database)
-- Central user register (central DB script 2470): Users.CentralUserID holds the user's Central_Users.ID.
--   usp_User_CentralGet    : a user's username / company / central ID (to register it)
--   usp_User_CentralSet    : store the central ID on the user
--   usp_Company_CentralGet : a company's code / name
--   usp_User_CentralFindByCentralId : the user linked to a central row (reconciling a username clash)
--   usp_User_CentralMarkPending / usp_User_CentralPending : changes the central server missed, and the background sync's list
--   usp_User_CentralList   : a company's users (all, or only those not registered yet) - "Sync Users"
-- Endpoints: Companies/SyncUsers (POST) on the Companies page (Super Admin only in code). No role is granted.
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH(N'dbo.Users', N'CentralUserID') IS NULL
    ALTER TABLE dbo.Users ADD CentralUserID BIGINT NULL;
GO
-- 1 = the user changed (username / company) while the central server was unreachable: the background sync updates it later
IF COL_LENGTH(N'dbo.Users', N'CentralSyncPending') IS NULL
    ALTER TABLE dbo.Users ADD CentralSyncPending BIT NOT NULL CONSTRAINT DF_Users_CentralSyncPending DEFAULT (0);
GO

CREATE OR ALTER PROCEDURE dbo.usp_User_CentralGet
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id, u.Username, u.CompanyId, u.CentralUserID FROM dbo.Users u WHERE u.Id = @UserId;
END
GO

-- the company's code and name (to find / register it in Central_Company)
CREATE OR ALTER PROCEDURE dbo.usp_Company_CentralGet
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.CompanyId, c.CompanyCode, c.CompanyName FROM dbo.CompanyMaster c WHERE c.CompanyId = @CompanyId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_User_CentralSet
    @UserId        INT,
    @CentralUserID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    -- synced: the central ID stored, the pending flag cleared (written only when something changes)
    UPDATE dbo.Users SET CentralUserID = @CentralUserID, CentralSyncPending = 0
     WHERE Id = @UserId AND (ISNULL(CentralUserID, -1) <> ISNULL(@CentralUserID, -1) OR CentralSyncPending = 1);
END
GO

-- the application user linked to a central row (a reservation left without its link while the central server was down)
CREATE OR ALTER PROCEDURE dbo.usp_User_CentralFindByCentralId
    @CentralUserID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 u.Id, u.Username, u.CompanyId, u.CentralUserID FROM dbo.Users u WHERE u.CentralUserID = @CentralUserID ORDER BY u.Id;
END
GO

-- not synced: an already-registered user whose change could not reach the central server is flagged for the background sync
CREATE OR ALTER PROCEDURE dbo.usp_User_CentralMarkPending
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Users SET CentralSyncPending = 1 WHERE Id = @UserId AND CentralUserID IS NOT NULL AND CentralSyncPending = 0;
END
GO

-- the background sync's work list: users never registered centrally, or changed since, oldest first, at most @Top
CREATE OR ALTER PROCEDURE dbo.usp_User_CentralPending
    @Top INT = 200
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) u.Id, u.Username, u.CompanyId, u.CentralUserID
      FROM dbo.Users u
     WHERE u.CompanyId IS NOT NULL AND ISNULL(u.Username, N'') <> N''
       AND (u.CentralUserID IS NULL OR u.CentralSyncPending = 1)
     ORDER BY u.Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_User_CentralList
    @CompanyId    INT,
    @OnlyPending  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id, u.Username, u.CompanyId, u.CentralUserID
      FROM dbo.Users u
     WHERE u.CompanyId = @CompanyId AND (@OnlyPending = 0 OR u.CentralUserID IS NULL)
     ORDER BY u.Id;
END
GO

DECLARE @page INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'SETTINGS.COMPANIES';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'Companies', @Action = N'SyncUsers', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2471 applied: Users.CentralUserID and the central user procedures.';
GO
