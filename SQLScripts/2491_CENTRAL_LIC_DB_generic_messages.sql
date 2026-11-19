-- ============================================================================================================
-- Migration: 2491_CENTRAL_LIC_DB_generic_messages.sql
-- RUN ON THE CENTRAL LICENCE DATABASE (Central_Lic_DB; Dev_CentralLic_DB for tests) - NOT on the application database.
-- The script refuses to run anywhere else. Needs 2473 and 2490.
--
-- Nothing about another client is told to an installation: a sign-in e-mail or a company code held by ANOTHER
-- installation gets a standard, generic message - no company code, no company name (2490 / 2473 named them).
--   usp_CentralUser_Check   : the holder's company code / name are no longer returned
--   usp_CentralUser_Save    : CONFLICT of Scope GLOBAL - "This e-mail is already in use as a sign-in and cannot be used ..."
--   usp_CentralCompany_Push : CONFLICT with another installation - "Company code X is not available ..."
-- Same-installation messages are unchanged (they concern the installation's own data). Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF DB_NAME() NOT IN (N'Central_Lic_DB', N'Dev_CentralLic_DB') OR OBJECT_ID(N'dbo.Central_Users', N'U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Central_Users_Username_Global')
BEGIN
    RAISERROR('Script 2491 belongs to the central licence database (Central_Lic_DB / Dev_CentralLic_DB) and needs scripts 2473 and 2490 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

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
           CASE WHEN u.InstanceKey = @InstanceKey THEN N'INSTALLATION' ELSE N'GLOBAL' END AS Scope
      FROM dbo.Central_Users u
     WHERE u.Username = @Username
       AND (@Username <> @Shared OR u.InstanceKey = @InstanceKey)
       AND NOT (u.InstanceKey = @InstanceKey AND u.ID = ISNULL(@CentralUserID, -1))
       AND NOT (u.InstanceKey = @InstanceKey AND @ApplicationUserID IS NOT NULL AND u.ApplicationUserID = @ApplicationUserID)
     ORDER BY CASE WHEN u.InstanceKey = @InstanceKey THEN 0 ELSE 1 END, u.ID;
END
GO

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
               N'INSTALLATION' AS Scope;
        RETURN;
    END

    BEGIN TRANSACTION;

    -- this user's own row: by its ID, else by (installation, application user) - always within this installation
    DECLARE @Target BIGINT = (SELECT ID FROM dbo.Central_Users WITH (UPDLOCK, HOLDLOCK) WHERE ID = @CentralUserID AND InstanceKey = @InstanceKey);
    IF @Target IS NULL AND @ApplicationUserID IS NOT NULL
        SET @Target = (SELECT ID FROM dbo.Central_Users WITH (UPDLOCK, HOLDLOCK)
                        WHERE InstanceKey = @InstanceKey AND ApplicationUserID = @ApplicationUserID);

    -- the username is unique across all installations (the platform super admin: within this installation)
    DECLARE @Holder BIGINT, @HolderApp INT, @HolderInstance NVARCHAR(400);
    SELECT TOP 1 @Holder = u.ID, @HolderApp = u.ApplicationUserID, @HolderInstance = u.InstanceKey
      FROM dbo.Central_Users u WITH (UPDLOCK, HOLDLOCK)
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
                    -- another client: nothing about it is told (2491)
                    ELSE N'This e-mail is already in use as a sign-in and cannot be used. Please use a different e-mail address.' END AS Message,
               @Holder AS ID,
               CASE WHEN @HolderInstance = @InstanceKey THEN N'INSTALLATION' ELSE N'GLOBAL' END AS Scope;
        RETURN;
    END

    IF @Target IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.Central_Users WHERE ID = @Target AND Username = @Username AND CompanyID = @CompanyID AND InstanceKey = @InstanceKey
                     AND (@ApplicationUserID IS NULL OR ApplicationUserID = @ApplicationUserID))
        BEGIN
            COMMIT;
            SELECT N'UNCHANGED' AS Status, N'The user is already in the central register.' AS Message, @Target AS ID,
                   N'INSTALLATION' AS Scope;
            RETURN;
        END
        UPDATE dbo.Central_Users
           SET Username = @Username, CompanyID = @CompanyID, InstanceKey = @InstanceKey,
               ApplicationUserID = ISNULL(@ApplicationUserID, ApplicationUserID), ModifiedDate = GETDATE()
         WHERE ID = @Target;
        COMMIT;
        SELECT N'UPDATED' AS Status, N'The central user was updated.' AS Message, @Target AS ID,
               N'INSTALLATION' AS Scope;
        RETURN;
    END

    INSERT dbo.Central_Users (Username, CompanyID, InstanceKey, ApplicationUserID, CreatedDate) VALUES (@Username, @CompanyID, @InstanceKey, @ApplicationUserID, GETDATE());
    DECLARE @Id BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
    COMMIT;
    SELECT N'CREATED' AS Status, N'The user was added to the central register.' AS Message, @Id AS ID,
           N'INSTALLATION' AS Scope;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_CentralCompany_Push
    @CompanyCode          NVARCHAR(50),
    @CompanyName          NVARCHAR(200),
    @ApplicationCompanyID INT,
    @ConnectionString     NVARCHAR(2000),
    @InstanceKey          NVARCHAR(400),
    @ApiUrl               NVARCHAR(500) = NULL,
    @DecryptedConnectionString NVARCHAR(2000) = NULL,
    @WebUrl               NVARCHAR(500) = NULL,  -- NULL = not known by this push: the stored web address is kept
    @ValidFrom            DATE          = NULL,  -- the company's validity (NULL = keep the stored dates)
    @ValidTo              DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

    SET @CompanyCode = UPPER(LTRIM(RTRIM(@CompanyCode)));
    SET @CompanyName = LTRIM(RTRIM(@CompanyName));
    SET @ApiUrl = NULLIF(LTRIM(RTRIM(@ApiUrl)), N'');
    SET @WebUrl = NULLIF(LOWER(LTRIM(RTRIM(@WebUrl))), N'');
    WHILE RIGHT(@WebUrl, 1) = N'/' SET @WebUrl = LEFT(@WebUrl, LEN(@WebUrl) - 1);   -- no trailing slash
    SET @WebUrl = NULLIF(@WebUrl, N'');
    IF ISNULL(@CompanyCode, N'') = N'' OR ISNULL(@CompanyName, N'') = N'' OR ISNULL(@InstanceKey, N'') = N'' OR ISNULL(@ApplicationCompanyID, 0) <= 0
    BEGIN
        SELECT N'CONFLICT' AS Status, N'Company code, name, company ID and instance are required.' AS Message, CAST(NULL AS INT) AS ID;
        RETURN;
    END

    BEGIN TRANSACTION;

    DECLARE @CodeId INT, @CodeInstance NVARCHAR(400), @CodeAppId INT, @CodeName NVARCHAR(200);
    SELECT @CodeId = ID, @CodeInstance = InstanceKey, @CodeAppId = ApplicationCompanyID, @CodeName = CompanyName
      FROM dbo.Central_Company WITH (UPDLOCK, HOLDLOCK)
     WHERE CompanyCode = @CompanyCode;

    IF @CodeId IS NOT NULL AND (@CodeInstance <> @InstanceKey OR @CodeAppId <> @ApplicationCompanyID)
    BEGIN
        ROLLBACK;
        SELECT N'CONFLICT' AS Status,
               CASE WHEN @CodeInstance <> @InstanceKey
                    THEN N'Company code ' + @CompanyCode + N' is not available. Company codes must be unique - change the code and push again.'
                    ELSE N'Company code ' + @CompanyCode + N' is already registered centrally for another company of this installation (' + @CodeName + N').' END AS Message,
               @CodeId AS ID;
        RETURN;
    END

    DECLARE @OwnId INT = (SELECT ID FROM dbo.Central_Company WITH (UPDLOCK, HOLDLOCK)
                           WHERE InstanceKey = @InstanceKey AND ApplicationCompanyID = @ApplicationCompanyID);

    IF @OwnId IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.Central_Company WHERE ID = @OwnId AND CompanyCode = @CompanyCode AND CompanyName COLLATE Latin1_General_CS_AS = @CompanyName
                     AND ISNULL(ApiUrl, N'') = ISNULL(@ApiUrl, N'') AND ConnectionString IS NOT NULL
                     AND ISNULL(DecryptedConnectionString, N'') COLLATE Latin1_General_CS_AS = ISNULL(@DecryptedConnectionString, N'')
                     AND (@WebUrl IS NULL OR ISNULL(WebUrl, N'') = @WebUrl)
                     AND (@ValidFrom IS NULL OR ValidFrom = @ValidFrom) AND (@ValidTo IS NULL OR ValidTo = @ValidTo))
        BEGIN
            COMMIT;
            SELECT N'UNCHANGED' AS Status, N'The company is already in the central register.' AS Message, @OwnId AS ID;
            RETURN;
        END
        UPDATE dbo.Central_Company
           SET CompanyCode = @CompanyCode, CompanyName = @CompanyName, ApiUrl = @ApiUrl,
               WebUrl = ISNULL(@WebUrl, WebUrl), ValidFrom = ISNULL(@ValidFrom, ValidFrom), ValidTo = ISNULL(@ValidTo, ValidTo),
               ConnectionString = CASE WHEN ConnectionString IS NOT NULL AND ISNULL(DecryptedConnectionString, N'') COLLATE Latin1_General_CS_AS = ISNULL(@DecryptedConnectionString, N'')
                                       THEN ConnectionString ELSE @ConnectionString END,
               DecryptedConnectionString = @DecryptedConnectionString, ModifiedDate = GETDATE()
         WHERE ID = @OwnId;
        COMMIT;
        SELECT N'UPDATED' AS Status, N'The central register was updated with this company''s name, code, validity, API and web address.' AS Message, @OwnId AS ID;
        RETURN;
    END

    INSERT dbo.Central_Company (CompanyCode, CompanyName, ApplicationCompanyID, ConnectionString, DecryptedConnectionString, ApiUrl, WebUrl,
                                ValidFrom, ValidTo, InstanceKey, CreatedDate)
    VALUES (@CompanyCode, @CompanyName, @ApplicationCompanyID, @ConnectionString, @DecryptedConnectionString, @ApiUrl, @WebUrl,
            @ValidFrom, @ValidTo, @InstanceKey, GETDATE());
    DECLARE @Id INT = CAST(SCOPE_IDENTITY() AS INT);
    COMMIT;
    SELECT N'CREATED' AS Status, N'The company was added to the central register.' AS Message, @Id AS ID;
END
GO

PRINT 'Script 2491 applied on ' + DB_NAME() + ': generic messages for another installation''s e-mails / company codes.';
GO
SET NOEXEC OFF;
GO
