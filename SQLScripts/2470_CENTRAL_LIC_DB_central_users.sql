-- ============================================================================================================
-- Migration: 2470_CENTRAL_LIC_DB_central_users.sql
-- RUN ON THE CENTRAL LICENCE DATABASE (Central_Lic_DB; Dev_CentralLic_DB for tests) - NOT on the application database.
-- The script refuses to run anywhere else. Needs 2467 (Central_Company).
--
-- Central user register: every sign-in of every eCare360 installation, Username unique per INSTALLATION
-- (Central_Company.InstanceKey = server|database of the application database; one installation may hold several companies). User Master creates the central row first, then the application user (existing flow), then links
-- them; every other login (doctor, corporate, franchise, administrator, marketing executive) is registered right after
-- it is created, and username / company changes are carried over. Sign-in itself is unchanged (application database).
--   Central_Users            : ID (PK), Username, CompanyID (NOT NULL, FK Central_Company.ID), InstanceKey (the company's -
--                              composite FK CompanyID + InstanceKey -> Central_Company), ApplicationUserID, CreatedDate, ModifiedDate.
--                              Unique: (InstanceKey, Username) and (InstanceKey, ApplicationUserID). No company, no central user.
--   usp_CentralUser_Check    : is the username free in that installation (for a new user, or for this user)?
--   usp_CentralUser_Save     : create / update a user's row - Status CREATED / UPDATED / UNCHANGED / CONFLICT
--   usp_CentralUser_Release  : drop a reservation that never got its application user (failed save)
--   usp_CentralUser_List     : the central users of a central company (sync status)
--   usp_CentralUser_Get / _Remove : the row holding a username, and removing a stale one - the application reconciles a
--                              username clash with its own Users table (the source of truth of its installation) before
--                              reporting it: renamed / removed users and abandoned reservations are corrected, a real clash is reported
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF DB_NAME() NOT IN (N'Central_Lic_DB', N'Dev_CentralLic_DB') OR OBJECT_ID(N'dbo.Central_Company', N'U') IS NULL
BEGIN
    RAISERROR('Script 2470 belongs to the central licence database (Central_Lic_DB / Dev_CentralLic_DB) and needs script 2467 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.Central_Users', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Central_Users
    (
        ID                BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Central_Users PRIMARY KEY,
        Username          NVARCHAR(256) NOT NULL,
        CompanyID         INT           NOT NULL CONSTRAINT FK_Central_Users_Company REFERENCES dbo.Central_Company (ID),
        InstanceKey       NVARCHAR(400) NOT NULL,
        ApplicationUserID INT           NULL,
        CreatedDate       DATETIME      NOT NULL CONSTRAINT DF_Central_Users_Created DEFAULT (GETDATE()),
        ModifiedDate      DATETIME      NULL
    );
END
GO

-- ── upgrade of a table made by the first version (unique per company) to unique per installation ────────────
IF COL_LENGTH(N'dbo.Central_Users', N'InstanceKey') IS NULL
    ALTER TABLE dbo.Central_Users ADD InstanceKey NVARCHAR(400) NULL;
GO
UPDATE u SET InstanceKey = c.InstanceKey
  FROM dbo.Central_Users u JOIN dbo.Central_Company c ON c.ID = u.CompanyID
 WHERE u.InstanceKey IS NULL OR u.InstanceKey <> c.InstanceKey;
GO
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.Central_Users') AND name = N'InstanceKey' AND is_nullable = 1)
    ALTER TABLE dbo.Central_Users ALTER COLUMN InstanceKey NVARCHAR(400) NOT NULL;
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Central_Users_Company_Username' AND object_id = OBJECT_ID(N'dbo.Central_Users'))
    DROP INDEX UX_Central_Users_Company_Username ON dbo.Central_Users;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Central_Users_Company_AppUser' AND object_id = OBJECT_ID(N'dbo.Central_Users'))
    DROP INDEX UX_Central_Users_Company_AppUser ON dbo.Central_Users;
GO
-- a username held twice in one installation cannot get the unique index: stop and say which
IF EXISTS (SELECT 1 FROM dbo.Central_Users GROUP BY InstanceKey, Username HAVING COUNT(*) > 1)
BEGIN
    DECLARE @dups NVARCHAR(MAX) = (SELECT STRING_AGG(Username, N', ') FROM (SELECT Username FROM dbo.Central_Users GROUP BY InstanceKey, Username HAVING COUNT(*) > 1) d);
    RAISERROR('Central_Users holds these usernames twice in one installation - remove the extra rows, then run 2470 again: %s', 16, 1, @dups);
    SET NOEXEC ON;
END
GO
-- keys: a central user always belongs to an existing central company (CompanyID NOT NULL, FK to Central_Company.ID), and its
-- InstanceKey is that company's own (composite FK on CompanyID + InstanceKey) - a company with users cannot be removed
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_Central_Company_ID_Instance')
    ALTER TABLE dbo.Central_Company ADD CONSTRAINT UQ_Central_Company_ID_Instance UNIQUE (ID, InstanceKey);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Central_Users_Company_Instance')
    ALTER TABLE dbo.Central_Users WITH CHECK ADD CONSTRAINT FK_Central_Users_Company_Instance
        FOREIGN KEY (CompanyID, InstanceKey) REFERENCES dbo.Central_Company (ID, InstanceKey);
GO
-- the username is unique within an installation (Central_Company.InstanceKey)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Central_Users_Instance_Username' AND object_id = OBJECT_ID(N'dbo.Central_Users'))
    CREATE UNIQUE INDEX UX_Central_Users_Instance_Username ON dbo.Central_Users (InstanceKey, Username);
-- one central row per application user of the installation (application user IDs are unique in its database)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Central_Users_Instance_AppUser' AND object_id = OBJECT_ID(N'dbo.Central_Users'))
    CREATE UNIQUE INDEX UX_Central_Users_Instance_AppUser ON dbo.Central_Users (InstanceKey, ApplicationUserID) WHERE ApplicationUserID IS NOT NULL;
GO

-- ── is the username free in the installation? (a row = held by another user) ─────────────────────────────────
-- The first version took @CompanyID; it is dropped and recreated with @InstanceKey.
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(N'dbo.usp_CentralUser_Check') AND name = N'@CompanyID')
    DROP PROCEDURE dbo.usp_CentralUser_Check;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_Check
    @InstanceKey       NVARCHAR(400),
    @Username          NVARCHAR(256),
    @CentralUserID     BIGINT = NULL,   -- this user's own row (edit)
    @ApplicationUserID INT    = NULL    -- this user (edit)
AS
BEGIN
    SET NOCOUNT ON;
    SET @Username = LOWER(LTRIM(RTRIM(@Username)));
    SELECT TOP 1 CAST(1 AS BIT) AS Taken, u.ID, u.ApplicationUserID
      FROM dbo.Central_Users u
     WHERE u.InstanceKey = @InstanceKey AND u.Username = @Username
       AND u.ID <> ISNULL(@CentralUserID, -1)
       AND NOT (@ApplicationUserID IS NOT NULL AND u.ApplicationUserID = @ApplicationUserID);
END
GO

-- ── create / update: the row is found by its ID, else by (company, application user) ─────────────────────────
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
    SET @Username = LOWER(LTRIM(RTRIM(@Username)));
    DECLARE @InstanceKey NVARCHAR(400) = (SELECT InstanceKey FROM dbo.Central_Company WHERE ID = @CompanyID);
    IF ISNULL(@Username, N'') = N'' OR @InstanceKey IS NULL
    BEGIN
        SELECT N'CONFLICT' AS Status, N'Username and a central company are required.' AS Message, CAST(NULL AS BIGINT) AS ID;
        RETURN;
    END

    BEGIN TRANSACTION;

    DECLARE @Target BIGINT = (SELECT ID FROM dbo.Central_Users WITH (UPDLOCK, HOLDLOCK) WHERE ID = @CentralUserID);
    IF @Target IS NULL AND @ApplicationUserID IS NOT NULL
        SET @Target = (SELECT ID FROM dbo.Central_Users WITH (UPDLOCK, HOLDLOCK)
                        WHERE InstanceKey = @InstanceKey AND ApplicationUserID = @ApplicationUserID);

    -- the username is unique within the installation (every company of it)
    DECLARE @Holder BIGINT, @HolderApp INT;
    SELECT @Holder = ID, @HolderApp = ApplicationUserID FROM dbo.Central_Users WITH (UPDLOCK, HOLDLOCK)
     WHERE InstanceKey = @InstanceKey AND Username = @Username AND ID <> ISNULL(@Target, -1);

    IF @Holder IS NOT NULL
    BEGIN
        ROLLBACK;
        SELECT N'CONFLICT' AS Status,
               N'The username ' + @Username + N' is already registered centrally for this installation'
               + CASE WHEN @HolderApp IS NULL THEN N' (being created by another user right now).' ELSE N'.' END AS Message,
               @Holder AS ID;
        RETURN;
    END

    IF @Target IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.Central_Users WHERE ID = @Target AND Username = @Username AND CompanyID = @CompanyID AND InstanceKey = @InstanceKey
                     AND (@ApplicationUserID IS NULL OR ApplicationUserID = @ApplicationUserID))
        BEGIN
            COMMIT;
            SELECT N'UNCHANGED' AS Status, N'The user is already in the central register.' AS Message, @Target AS ID;
            RETURN;
        END
        UPDATE dbo.Central_Users
           SET Username = @Username, CompanyID = @CompanyID, InstanceKey = @InstanceKey,
               ApplicationUserID = ISNULL(@ApplicationUserID, ApplicationUserID), ModifiedDate = GETDATE()
         WHERE ID = @Target;
        COMMIT;
        SELECT N'UPDATED' AS Status, N'The central user was updated.' AS Message, @Target AS ID;
        RETURN;
    END

    INSERT dbo.Central_Users (Username, CompanyID, InstanceKey, ApplicationUserID, CreatedDate) VALUES (@Username, @CompanyID, @InstanceKey, @ApplicationUserID, GETDATE());
    DECLARE @Id BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
    COMMIT;
    SELECT N'CREATED' AS Status, N'The user was added to the central register.' AS Message, @Id AS ID;
END
GO

-- ── a reservation whose application user was never saved ────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_Release
    @CentralUserID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE dbo.Central_Users WHERE ID = @CentralUserID AND ApplicationUserID IS NULL;
    SELECT @@ROWCOUNT AS Released;
END
GO

-- ── one central row (the holder of a username, for reconciling with the application database) ────────────────
CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_Get
    @CentralUserID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ID, Username, CompanyID, InstanceKey, ApplicationUserID, CreatedDate, ModifiedDate,
           DATEDIFF(MINUTE, ISNULL(ModifiedDate, CreatedDate), GETDATE()) AS AgeMinutes
      FROM dbo.Central_Users WHERE ID = @CentralUserID;
END
GO

-- ── a stale row: its application user no longer exists in that installation (the application database decides) ──
CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_Remove
    @CentralUserID BIGINT,
    @InstanceKey   NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    DELETE dbo.Central_Users WHERE ID = @CentralUserID AND InstanceKey = @InstanceKey;
    SELECT @@ROWCOUNT AS Removed;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_List
    @CompanyID INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ID, Username, ApplicationUserID, CreatedDate, ModifiedDate FROM dbo.Central_Users WHERE CompanyID = @CompanyID ORDER BY Username;
END
GO

PRINT 'Script 2470 applied on ' + DB_NAME() + ': Central_Users register.';
GO
SET NOEXEC OFF;
GO
