-- ============================================================================================================
-- Migration: 2467_CENTRAL_LIC_DB_central_company.sql
-- RUN ON THE CENTRAL LICENCE DATABASE (Central_Lic_DB; Dev_CentralLic_DB for tests) - NOT on the application database.
-- The script refuses to run anywhere else.
--
-- Central company register: every company created in any eCare360 installation is pushed here (Settings > Companies >
-- New Company / Create, and "Push to Central" on the company profile). Company Code is unique across ALL installations.
--   Central_Company           : one row per company (code, name, the application's CompanyId, the instance's connection
--                               string - ENC: encrypted, and decrypted in DecryptedConnectionString -, ApiUrl = the instance's EMR.Api
--                               address (ApiSettings:BaseUrl) and InstanceKey = server|database, which tells installations apart).
--   usp_CentralCompany_Get    : the row holding a code, and the row of this installation's company (status / validation).
--   usp_CentralCompany_Push   : create or refresh this installation's row; refuses a code held by another installation.
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF DB_NAME() NOT IN (N'Central_Lic_DB', N'Dev_CentralLic_DB')
BEGIN
    RAISERROR('Script 2467 belongs to the central licence database (Central_Lic_DB / Dev_CentralLic_DB). Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.Central_Company', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Central_Company
    (
        ID                   INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Central_Company PRIMARY KEY,
        CompanyCode          NVARCHAR(50)   NOT NULL,
        CompanyName          NVARCHAR(200)  NOT NULL,
        ApplicationCompanyID INT            NOT NULL,
        ConnectionString     NVARCHAR(2000) NULL,
        DecryptedConnectionString NVARCHAR(2000) NULL,
        ApiUrl               NVARCHAR(500)  NULL,
        InstanceKey          NVARCHAR(400)  NOT NULL,
        CreatedDate          DATETIME       NOT NULL CONSTRAINT DF_Central_Company_Created DEFAULT (GETDATE()),
        ModifiedDate         DATETIME       NULL
    );
    CREATE UNIQUE INDEX UX_Central_Company_Code ON dbo.Central_Company (CompanyCode);
    CREATE UNIQUE INDEX UX_Central_Company_Instance ON dbo.Central_Company (InstanceKey, ApplicationCompanyID);
END
GO
-- a table created by the first version of this script: the API address of the instance
IF COL_LENGTH(N'dbo.Central_Company', N'ApiUrl') IS NULL
    ALTER TABLE dbo.Central_Company ADD ApiUrl NVARCHAR(500) NULL;
GO
-- the instance's connection string in plain text (ConnectionString holds it ENC: encrypted; each encryption differs)
IF COL_LENGTH(N'dbo.Central_Company', N'DecryptedConnectionString') IS NULL
    ALTER TABLE dbo.Central_Company ADD DecryptedConnectionString NVARCHAR(2000) NULL;
GO

-- ── status: the row that holds the code, and this installation's row of the company (Match CODE / INSTANCE) ────
CREATE OR ALTER PROCEDURE dbo.usp_CentralCompany_Get
    @CompanyCode          NVARCHAR(50),
    @InstanceKey          NVARCHAR(400),
    @ApplicationCompanyID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT N'CODE' AS Match, c.ID, c.CompanyCode, c.CompanyName, c.ApplicationCompanyID, c.ApiUrl,
           CAST(CASE WHEN c.InstanceKey = @InstanceKey THEN 1 ELSE 0 END AS BIT) AS SameInstance, c.CreatedDate, c.ModifiedDate
      FROM dbo.Central_Company c
     WHERE c.CompanyCode = @CompanyCode
    UNION ALL
    SELECT N'INSTANCE', c.ID, c.CompanyCode, c.CompanyName, c.ApplicationCompanyID, c.ApiUrl, CAST(1 AS BIT), c.CreatedDate, c.ModifiedDate
      FROM dbo.Central_Company c
     WHERE @ApplicationCompanyID IS NOT NULL AND c.InstanceKey = @InstanceKey AND c.ApplicationCompanyID = @ApplicationCompanyID
       AND c.CompanyCode <> @CompanyCode;
END
GO

-- ── push: Status CREATED / UPDATED / UNCHANGED / CONFLICT ─────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_CentralCompany_Push
    @CompanyCode          NVARCHAR(50),
    @CompanyName          NVARCHAR(200),
    @ApplicationCompanyID INT,
    @ConnectionString     NVARCHAR(2000),
    @InstanceKey          NVARCHAR(400),
    @ApiUrl               NVARCHAR(500) = NULL,
    @DecryptedConnectionString NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

    SET @CompanyCode = UPPER(LTRIM(RTRIM(@CompanyCode)));
    SET @CompanyName = LTRIM(RTRIM(@CompanyName));
    SET @ApiUrl = NULLIF(LTRIM(RTRIM(@ApiUrl)), N'');
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
                    THEN N'Company code ' + @CompanyCode + N' is already registered centrally by another eCare360 installation (' + @CodeName + N'). Company codes must be unique across all installations - change the code and push again.'
                    ELSE N'Company code ' + @CompanyCode + N' is already registered centrally for another company of this installation (' + @CodeName + N').' END AS Message,
               @CodeId AS ID;
        RETURN;
    END

    DECLARE @OwnId INT = (SELECT ID FROM dbo.Central_Company WITH (UPDLOCK, HOLDLOCK)
                           WHERE InstanceKey = @InstanceKey AND ApplicationCompanyID = @ApplicationCompanyID);

    IF @OwnId IS NOT NULL
    BEGIN
        -- matched by this installation's company (its code when unchanged): name, code and API address kept in step
        IF EXISTS (SELECT 1 FROM dbo.Central_Company WHERE ID = @OwnId AND CompanyCode = @CompanyCode AND CompanyName COLLATE Latin1_General_CS_AS = @CompanyName
                     AND ISNULL(ApiUrl, N'') = ISNULL(@ApiUrl, N'') AND ConnectionString IS NOT NULL
                     AND ISNULL(DecryptedConnectionString, N'') COLLATE Latin1_General_CS_AS = ISNULL(@DecryptedConnectionString, N''))
        BEGIN
            COMMIT;
            SELECT N'UNCHANGED' AS Status, N'The company is already in the central register.' AS Message, @OwnId AS ID;
            RETURN;
        END
        -- the company's name or code, or the instance's API address, changed in the application
        UPDATE dbo.Central_Company
           SET CompanyCode = @CompanyCode, CompanyName = @CompanyName, ApiUrl = @ApiUrl,
               -- the encrypted value is rewritten only when the connection itself changed (each encryption differs)
               ConnectionString = CASE WHEN ConnectionString IS NOT NULL AND ISNULL(DecryptedConnectionString, N'') COLLATE Latin1_General_CS_AS = ISNULL(@DecryptedConnectionString, N'')
                                       THEN ConnectionString ELSE @ConnectionString END,
               DecryptedConnectionString = @DecryptedConnectionString, ModifiedDate = GETDATE()
         WHERE ID = @OwnId;
        COMMIT;
        SELECT N'UPDATED' AS Status, N'The central register was updated with this company''s name, code and API address.' AS Message, @OwnId AS ID;
        RETURN;
    END

    INSERT dbo.Central_Company (CompanyCode, CompanyName, ApplicationCompanyID, ConnectionString, DecryptedConnectionString, ApiUrl, InstanceKey, CreatedDate)
    VALUES (@CompanyCode, @CompanyName, @ApplicationCompanyID, @ConnectionString, @DecryptedConnectionString, @ApiUrl, @InstanceKey, GETDATE());
    DECLARE @Id INT = CAST(SCOPE_IDENTITY() AS INT);
    COMMIT;
    SELECT N'CREATED' AS Status, N'The company was added to the central register.' AS Message, @Id AS ID;
END
GO

PRINT 'Script 2467 applied on ' + DB_NAME() + ': Central_Company register.';
GO
SET NOEXEC OFF;
GO
