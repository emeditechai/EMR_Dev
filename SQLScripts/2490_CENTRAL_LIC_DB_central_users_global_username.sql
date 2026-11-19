-- ============================================================================================================
-- Migration: 2490_CENTRAL_LIC_DB_central_users_global_username.sql
-- RUN ON THE CENTRAL LICENCE DATABASE (Central_Lic_DB; Dev_CentralLic_DB for tests) - NOT on the application database.
-- The script refuses to run anywhere else. Needs 2467, 2470, 2473 and 2488 (Central_Delete_Audit).
--
-- Central_Users.Username is now unique across ALL installations (it was unique per installation, 2470). The one exception
-- is the platform super admin ecare360plusadmin@emeditechplus.com: every installation has it, so it stays unique per
-- installation only and is registered by each of them.
--   1. Clean-up of the usernames held more than once (the super admin excepted): the row of the keeper installation
--      (@KeepInstance = 103.178.113.61,1232|dev_emr) stays - when no row is of that installation, the oldest one -
--      and the others are deleted. Every deleted row is kept in Central_Delete_Audit (Reason DUPLICATE_USERNAME).
--   2. UX_Central_Users_Username_Global: unique Username, the super admin excepted (filtered index).
--   3. usp_CentralUser_Check / _Save: the username is checked in every installation (the super admin: this installation).
--      A name held by another installation is Scope GLOBAL (the application skips that user, it is not synced); a row
--      is only ever matched by ID within the calling installation.
--   4. usp_CentralUser_ListInstance: the central users of an installation (the application removes the ones whose user
--      no longer exists there - Reason USER_DELETED, audited).
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF DB_NAME() NOT IN (N'Central_Lic_DB', N'Dev_CentralLic_DB') OR OBJECT_ID(N'dbo.Central_Users', N'U') IS NULL
   OR OBJECT_ID(N'dbo.Central_Delete_Audit', N'U') IS NULL OR OBJECT_ID(N'dbo.usp_CentralDelete_SetContext', N'P') IS NULL
BEGIN
    RAISERROR('Script 2490 belongs to the central licence database (Central_Lic_DB / Dev_CentralLic_DB) and needs scripts 2467, 2470, 2473 and 2488 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ── 1. one row per username (the super admin excepted) ────────────────────────────────────────────────────────
DECLARE @KeepInstance NVARCHAR(400) = N'103.178.113.61,1232|dev_emr',
        @Shared       NVARCHAR(256) = N'ecare360plusadmin@emeditechplus.com';
DECLARE @drop TABLE (ID BIGINT PRIMARY KEY);
INSERT @drop (ID)
SELECT x.ID
  FROM (SELECT u.ID, ROW_NUMBER() OVER (PARTITION BY u.Username
                                        ORDER BY CASE WHEN u.InstanceKey = @KeepInstance THEN 0 ELSE 1 END,
                                                 CASE WHEN u.ApplicationUserID IS NOT NULL THEN 0 ELSE 1 END, u.CreatedDate, u.ID) AS rn
          FROM dbo.Central_Users u
         WHERE u.Username <> @Shared) x
 WHERE x.rn > 1;

IF EXISTS (SELECT 1 FROM @drop)
BEGIN
    BEGIN TRANSACTION;
    EXEC dbo.usp_CentralDelete_SetContext @Reason = N'DUPLICATE_USERNAME',
         @DeletedBy = N'Script 2490 (username made unique across installations)', @Reference = N'kept: 103.178.113.61,1232|dev_emr';
    DELETE dbo.Central_Users WHERE ID IN (SELECT ID FROM @drop);
    DECLARE @n INT = @@ROWCOUNT;
    EXEC dbo.usp_CentralDelete_SetContext;
    COMMIT;
    PRINT '2490: ' + CAST(@n AS VARCHAR(10)) + ' duplicate central user row(s) removed (kept in Central_Delete_Audit).';
END
GO

-- ── 2. unique across installations (the super admin excepted) ─────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Central_Users_Username_Global' AND object_id = OBJECT_ID(N'dbo.Central_Users'))
    CREATE UNIQUE INDEX UX_Central_Users_Username_Global ON dbo.Central_Users (Username)
        WHERE Username <> N'ecare360plusadmin@emeditechplus.com';
GO

-- ── 3a. is the username free? (a row = held; Scope INSTALLATION = by another user here, GLOBAL = by another installation) ──
CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_Check
    @InstanceKey       NVARCHAR(400),
    @Username          NVARCHAR(256),
    @CentralUserID     BIGINT = NULL,   -- this user's own row (edit)
    @ApplicationUserID INT    = NULL    -- this user (edit)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Shared NVARCHAR(256) = N'ecare360plusadmin@emeditechplus.com';
    SET @Username = LOWER(LTRIM(RTRIM(@Username)));
    SELECT TOP 1 CAST(1 AS BIT) AS Taken, u.ID, u.ApplicationUserID, u.InstanceKey,
           CASE WHEN u.InstanceKey = @InstanceKey THEN N'INSTALLATION' ELSE N'GLOBAL' END AS Scope,
           c.CompanyCode, c.CompanyName
      FROM dbo.Central_Users u
      LEFT JOIN dbo.Central_Company c ON c.ID = u.CompanyID
     WHERE u.Username = @Username
       AND (@Username <> @Shared OR u.InstanceKey = @InstanceKey)
       AND NOT (u.InstanceKey = @InstanceKey AND u.ID = ISNULL(@CentralUserID, -1))
       AND NOT (u.InstanceKey = @InstanceKey AND @ApplicationUserID IS NOT NULL AND u.ApplicationUserID = @ApplicationUserID)
     ORDER BY CASE WHEN u.InstanceKey = @InstanceKey THEN 0 ELSE 1 END, u.ID;
END
GO

-- ── 3b. create / update: Status CREATED / UPDATED / UNCHANGED / CONFLICT (Scope INSTALLATION | GLOBAL) ──────────
CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_Save
    @CompanyID         INT,
    @Username          NVARCHAR(256),
    @ApplicationUserID INT    = NULL,   -- NULL = reserve the username before the application user exists
    @CentralUserID     BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
    DECLARE @Shared NVARCHAR(256) = N'ecare360plusadmin@emeditechplus.com';
    SET @Username = LOWER(LTRIM(RTRIM(@Username)));
    DECLARE @InstanceKey NVARCHAR(400) = (SELECT InstanceKey FROM dbo.Central_Company WHERE ID = @CompanyID);
    IF ISNULL(@Username, N'') = N'' OR @InstanceKey IS NULL
    BEGIN
        SELECT N'CONFLICT' AS Status, N'Username and a central company are required.' AS Message, CAST(NULL AS BIGINT) AS ID,
               N'INSTALLATION' AS Scope, CAST(NULL AS NVARCHAR(50)) AS HolderCompanyCode;
        RETURN;
    END

    BEGIN TRANSACTION;

    -- this user's own row: by its ID, else by (installation, application user) - always within this installation
    DECLARE @Target BIGINT = (SELECT ID FROM dbo.Central_Users WITH (UPDLOCK, HOLDLOCK) WHERE ID = @CentralUserID AND InstanceKey = @InstanceKey);
    IF @Target IS NULL AND @ApplicationUserID IS NOT NULL
        SET @Target = (SELECT ID FROM dbo.Central_Users WITH (UPDLOCK, HOLDLOCK)
                        WHERE InstanceKey = @InstanceKey AND ApplicationUserID = @ApplicationUserID);

    -- the username is unique across all installations (the platform super admin: within this installation)
    DECLARE @Holder BIGINT, @HolderApp INT, @HolderInstance NVARCHAR(400), @HolderCode NVARCHAR(50);
    SELECT TOP 1 @Holder = u.ID, @HolderApp = u.ApplicationUserID, @HolderInstance = u.InstanceKey, @HolderCode = c.CompanyCode
      FROM dbo.Central_Users u WITH (UPDLOCK, HOLDLOCK)
      LEFT JOIN dbo.Central_Company c ON c.ID = u.CompanyID
     WHERE u.Username = @Username AND u.ID <> ISNULL(@Target, -1)
       AND (@Username <> @Shared OR u.InstanceKey = @InstanceKey)
     ORDER BY CASE WHEN u.InstanceKey = @InstanceKey THEN 0 ELSE 1 END, u.ID;

    IF @Holder IS NOT NULL
    BEGIN
        ROLLBACK;
        SELECT N'CONFLICT' AS Status,
               CASE WHEN @HolderInstance = @InstanceKey
                    THEN N'The username ' + @Username + N' is already registered centrally for this installation'
                         + CASE WHEN @HolderApp IS NULL THEN N' (being created by another user right now).' ELSE N'.' END
                    ELSE N'The username ' + @Username + N' is already registered centrally by another eCare360 installation'
                         + ISNULL(N' (company ' + @HolderCode + N')', N'') + N' - usernames are unique across all installations.' END AS Message,
               @Holder AS ID,
               CASE WHEN @HolderInstance = @InstanceKey THEN N'INSTALLATION' ELSE N'GLOBAL' END AS Scope,
               @HolderCode AS HolderCompanyCode;
        RETURN;
    END

    IF @Target IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.Central_Users WHERE ID = @Target AND Username = @Username AND CompanyID = @CompanyID AND InstanceKey = @InstanceKey
                     AND (@ApplicationUserID IS NULL OR ApplicationUserID = @ApplicationUserID))
        BEGIN
            COMMIT;
            SELECT N'UNCHANGED' AS Status, N'The user is already in the central register.' AS Message, @Target AS ID,
                   N'INSTALLATION' AS Scope, CAST(NULL AS NVARCHAR(50)) AS HolderCompanyCode;
            RETURN;
        END
        UPDATE dbo.Central_Users
           SET Username = @Username, CompanyID = @CompanyID, InstanceKey = @InstanceKey,
               ApplicationUserID = ISNULL(@ApplicationUserID, ApplicationUserID), ModifiedDate = GETDATE()
         WHERE ID = @Target;
        COMMIT;
        SELECT N'UPDATED' AS Status, N'The central user was updated.' AS Message, @Target AS ID,
               N'INSTALLATION' AS Scope, CAST(NULL AS NVARCHAR(50)) AS HolderCompanyCode;
        RETURN;
    END

    INSERT dbo.Central_Users (Username, CompanyID, InstanceKey, ApplicationUserID, CreatedDate) VALUES (@Username, @CompanyID, @InstanceKey, @ApplicationUserID, GETDATE());
    DECLARE @Id BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
    COMMIT;
    SELECT N'CREATED' AS Status, N'The user was added to the central register.' AS Message, @Id AS ID,
           N'INSTALLATION' AS Scope, CAST(NULL AS NVARCHAR(50)) AS HolderCompanyCode;
END
GO

-- ── 4. the central users of an installation (optionally of one central company), for removing deleted users ──────
CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_ListInstance
    @InstanceKey NVARCHAR(400),
    @CompanyID   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.ID, u.Username, u.CompanyID, u.ApplicationUserID,
           DATEDIFF(MINUTE, ISNULL(u.ModifiedDate, u.CreatedDate), GETDATE()) AS AgeMinutes
      FROM dbo.Central_Users u
     WHERE u.InstanceKey = @InstanceKey AND (@CompanyID IS NULL OR u.CompanyID = @CompanyID)
     ORDER BY u.ID;
END
GO

PRINT 'Script 2490 applied on ' + DB_NAME() + ': Central_Users usernames unique across installations (super admin excepted).';
GO
SET NOEXEC OFF;
GO
