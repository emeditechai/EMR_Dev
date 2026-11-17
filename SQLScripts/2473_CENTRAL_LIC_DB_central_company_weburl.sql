-- ============================================================================================================
-- Migration: 2473_CENTRAL_LIC_DB_central_company_weburl.sql
-- RUN ON THE CENTRAL LICENCE DATABASE (Central_Lic_DB; Dev_CentralLic_DB for tests) - NOT on the application database.
-- The script refuses to run anywhere else. Needs 2467 (Central_Company).
--
-- Central_Company.ValidFrom / ValidTo: the company's validity (Settings > Companies, application script 2472), sent with
-- every push (NULL = not known by this push: the stored dates are kept).
-- Central_Company.WebUrl: the web address of the installation the company is used on (e.g. https://ecare.hospital.in) -
-- Licensing:AppUrl when the installation has one, else the address the application was reached at when the company was
-- created / edited / pushed. Written on company create / update / push; a push that does not know it (a background sync
-- with no web request) keeps the stored value.
--   usp_CentralCompany_Get  : also returns WebUrl, ValidFrom, ValidTo
--   usp_CentralCompany_Push : @WebUrl, @ValidFrom, @ValidTo (NULL = keep the stored value)
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF DB_NAME() NOT IN (N'Central_Lic_DB', N'Dev_CentralLic_DB') OR OBJECT_ID(N'dbo.Central_Company', N'U') IS NULL
BEGIN
    RAISERROR('Script 2473 belongs to the central licence database (Central_Lic_DB / Dev_CentralLic_DB) and needs script 2467 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH(N'dbo.Central_Company', N'WebUrl') IS NULL
    ALTER TABLE dbo.Central_Company ADD WebUrl NVARCHAR(500) NULL;
GO
IF COL_LENGTH(N'dbo.Central_Company', N'ValidFrom') IS NULL
    ALTER TABLE dbo.Central_Company ADD ValidFrom DATE NULL;
GO
IF COL_LENGTH(N'dbo.Central_Company', N'ValidTo') IS NULL
    ALTER TABLE dbo.Central_Company ADD ValidTo DATE NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CentralCompany_Get
    @CompanyCode          NVARCHAR(50),
    @InstanceKey          NVARCHAR(400),
    @ApplicationCompanyID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT N'CODE' AS Match, c.ID, c.CompanyCode, c.CompanyName, c.ApplicationCompanyID, c.ApiUrl, c.WebUrl, c.ValidFrom, c.ValidTo,
           CAST(CASE WHEN c.InstanceKey = @InstanceKey THEN 1 ELSE 0 END AS BIT) AS SameInstance, c.CreatedDate, c.ModifiedDate
      FROM dbo.Central_Company c
     WHERE c.CompanyCode = @CompanyCode
    UNION ALL
    SELECT N'INSTANCE', c.ID, c.CompanyCode, c.CompanyName, c.ApplicationCompanyID, c.ApiUrl, c.WebUrl, c.ValidFrom, c.ValidTo, CAST(1 AS BIT), c.CreatedDate, c.ModifiedDate
      FROM dbo.Central_Company c
     WHERE @ApplicationCompanyID IS NOT NULL AND c.InstanceKey = @InstanceKey AND c.ApplicationCompanyID = @ApplicationCompanyID
       AND c.CompanyCode <> @CompanyCode;
END
GO

-- push: Status CREATED / UPDATED / UNCHANGED / CONFLICT (as 2467, plus the web address)
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
                    THEN N'Company code ' + @CompanyCode + N' is already registered centrally by another eCare360 installation (' + @CodeName + N'). Company codes must be unique across all installations - change the code and push again.'
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

PRINT 'Script 2473 applied on ' + DB_NAME() + ': Central_Company.WebUrl, ValidFrom, ValidTo.';
GO
SET NOEXEC OFF;
GO
