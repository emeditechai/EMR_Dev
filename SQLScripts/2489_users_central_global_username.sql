-- ============================================================================================================
-- Migration: 2489_users_central_global_username.sql   (application database; needs 2471 and 2487)
-- Central user register, usernames unique across ALL installations (central DB script 2490; the platform super admin
-- ecare360plusadmin@emeditechplus.com excepted - every installation registers it):
--   * a user whose username another installation already holds centrally is SKIPPED by the sync - not registered, not
--     retried on every run: Users.CentralSyncSkipReason / CentralSyncSkippedUsername / CentralSyncSkippedAt. It is tried
--     again when its username changes, or by "Sync Users" on the company profile.
--   * a user deleted from this application database (any way: company removal, clean-up script, by hand) is queued by
--     trg_Users_CentralRemoval in dbo.CentralRegisterRemoval (outbox, 2487), in the same transaction as the delete; the
--     application then removes it from Central_Users, where a copy is kept in Central_Delete_Audit (Reason USER_DELETED,
--     or COMPANY_DELETED / COMPANY_USERS_REMOVED when Company > Remove data deleted it - session context ecare.UserDelete*).
--   usp_User_CentralSkip     : mark a user skipped (and drop a central ID that is not its own any more)
--   usp_User_CentralSet      : (2471) also clears the skip
--   usp_User_CentralPending  : (2471) skipped users are left out until their username changes
--   usp_User_CentralList     : (2471) also returns the skip
--   usp_User_CentralExisting : which of the given user IDs still exist (removing central rows of deleted users)
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF OBJECT_ID(N'dbo.CentralRegisterRemoval', N'U') IS NULL OR COL_LENGTH(N'dbo.CentralRegisterRemoval', N'Reason') IS NULL
BEGIN
    RAISERROR('Script 2489 needs script 2487 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH(N'dbo.Users', N'CentralSyncSkipReason') IS NULL
    ALTER TABLE dbo.Users ADD CentralSyncSkipReason NVARCHAR(400) NULL;
GO
IF COL_LENGTH(N'dbo.Users', N'CentralSyncSkippedUsername') IS NULL
    ALTER TABLE dbo.Users ADD CentralSyncSkippedUsername NVARCHAR(256) NULL;
GO
IF COL_LENGTH(N'dbo.Users', N'CentralSyncSkippedAt') IS NULL
    ALTER TABLE dbo.Users ADD CentralSyncSkippedAt DATETIME NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_User_CentralGet
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id, u.Username, u.CompanyId, u.CentralUserID, u.CentralSyncSkipReason FROM dbo.Users u WHERE u.Id = @UserId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_User_CentralSet
    @UserId        INT,
    @CentralUserID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    -- synced: the central ID stored, the pending flag and any skip cleared (written only when something changes)
    UPDATE dbo.Users
       SET CentralUserID = @CentralUserID, CentralSyncPending = 0,
           CentralSyncSkipReason = NULL, CentralSyncSkippedUsername = NULL, CentralSyncSkippedAt = NULL
     WHERE Id = @UserId
       AND (ISNULL(CentralUserID, -1) <> ISNULL(@CentralUserID, -1) OR CentralSyncPending = 1 OR CentralSyncSkipReason IS NOT NULL);
END
GO

-- the username is held by another installation: not synced, not retried until the username changes
CREATE OR ALTER PROCEDURE dbo.usp_User_CentralSkip
    @UserId INT,
    @Reason NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Users
       SET CentralUserID = NULL,               -- a central row of this user cannot exist under a name held elsewhere
           CentralSyncPending = 0,
           CentralSyncSkipReason = LEFT(@Reason, 400),
           CentralSyncSkippedUsername = Username,
           CentralSyncSkippedAt = GETDATE()
     WHERE Id = @UserId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_User_CentralPending
    @Top INT = 200
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) u.Id, u.Username, u.CompanyId, u.CentralUserID, u.CentralSyncSkipReason
      FROM dbo.Users u
     WHERE u.CompanyId IS NOT NULL AND ISNULL(u.Username, N'') <> N''
       AND (u.CentralUserID IS NULL OR u.CentralSyncPending = 1)
       -- skipped (username held by another installation): only once the username changed
       AND (u.CentralSyncSkipReason IS NULL OR ISNULL(u.CentralSyncSkippedUsername, N'') <> u.Username)
     ORDER BY u.Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_User_CentralList
    @CompanyId    INT,
    @OnlyPending  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id, u.Username, u.CompanyId, u.CentralUserID, u.CentralSyncSkipReason
      FROM dbo.Users u
     WHERE u.CompanyId = @CompanyId AND (@OnlyPending = 0 OR u.CentralUserID IS NULL)
     ORDER BY u.Id;
END
GO

-- of the given user IDs (JSON array), the ones that still exist in this application database
CREATE OR ALTER PROCEDURE dbo.usp_User_CentralExisting
    @UserIds NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id FROM dbo.Users u
     WHERE u.Id IN (SELECT TRY_CAST(value AS INT) FROM OPENJSON(@UserIds));
END
GO

-- ── a deleted user leaves the central register: queued with the delete itself (outbox, dbo.CentralRegisterRemoval) ──
CREATE OR ALTER TRIGGER dbo.trg_Users_CentralRemoval ON dbo.Users
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    INSERT dbo.CentralRegisterRemoval (Kind, ApplicationCompanyID, CompanyCode, CompanyName, ApplicationUserIDs, RequestedBy, RequestedByName, Reason)
    SELECT 'USERS', ISNULL(d.CompanyId, 0), MAX(c.CompanyCode), MAX(c.CompanyName),
           N'[' + STRING_AGG(CAST(CAST(d.Id AS NVARCHAR(12)) AS NVARCHAR(MAX)), N',') + N']',
           TRY_CAST(SESSION_CONTEXT(N'ecare.UserDeleteBy') AS INT),
           ISNULL(CAST(SESSION_CONTEXT(N'ecare.UserDeleteByName') AS NVARCHAR(256)), SUSER_SNAME()),
           ISNULL(CAST(SESSION_CONTEXT(N'ecare.UserDeleteReason') AS NVARCHAR(50)), N'USER_DELETED')
      FROM deleted d
      LEFT JOIN dbo.CompanyMaster c ON c.CompanyId = d.CompanyId
     GROUP BY ISNULL(d.CompanyId, 0);
END
GO

PRINT 'Script 2489 applied: central user register - usernames unique across installations, deleted users leave it.';
GO
SET NOEXEC OFF;
GO
