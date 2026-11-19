-- ============================================================================================================
-- Migration: 2488_CENTRAL_LIC_DB_central_company_remove.sql
-- RUN ON THE CENTRAL LICENCE DATABASE (Central_Lic_DB; Dev_CentralLic_DB for tests) - NOT on the application database.
-- The script refuses to run anywhere else. Needs 2467 (Central_Company), 2470 (Central_Users) and 2473 (WebUrl / validity).
--
-- Removing from the central register what an installation removed (application script 2487, Company > Remove data):
--   usp_CentralCompany_Remove   : "Delete the company" - the company's row and all its central users, in one transaction.
--                                 Only the calling installation's own row (InstanceKey + ApplicationCompanyID) can go;
--                                 another installation's company is never touched. @Preview = 1 only counts.
--   usp_CentralUser_RemoveByApp : "Everything" - the central rows of the application users that were removed
--                                 (@ApplicationUserIDs = JSON array of Users.Id), again only of the calling installation.
--   Both return Status REMOVED / NOT_FOUND / PREVIEW with the counts; NOT_FOUND (nothing registered) is not an error.
--
-- Delete audit: Central_Delete_Audit keeps every Central_Company / Central_Users row that is deleted - its key columns and
-- the whole row as JSON (RecordJson), with when, why (Reason), by whom (DeletedBy), from where (DeletedFrom, Reference)
-- and one BatchID per removal. It is written by AFTER DELETE triggers on both tables, so every delete is kept, whatever
-- removes it (these procedures, the stale-row clean-up of usp_CentralUser_Remove / _Release, the vendor application or a
-- manual DELETE - Reason DIRECT with the database login). A delete whose audit row cannot be written is rolled back.
-- The procedures pass who / why through SESSION_CONTEXT (keys ecare.Delete*). The plain-text DecryptedConnectionString
-- is not copied into the audit (the encrypted ConnectionString is).
--   usp_CentralDeleteAudit_List : the audit rows (filters: code, instance, from / to date).
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF DB_NAME() NOT IN (N'Central_Lic_DB', N'Dev_CentralLic_DB') OR OBJECT_ID(N'dbo.Central_Company', N'U') IS NULL
   OR OBJECT_ID(N'dbo.Central_Users', N'U') IS NULL OR COL_LENGTH(N'dbo.Central_Company', N'WebUrl') IS NULL
BEGIN
    RAISERROR('Script 2488 belongs to the central licence database (Central_Lic_DB / Dev_CentralLic_DB) and needs scripts 2467, 2470 and 2473 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── the delete audit ──────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID(N'dbo.Central_Delete_Audit', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Central_Delete_Audit
    (
        AuditID              BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Central_Delete_Audit PRIMARY KEY,
        TableName            NVARCHAR(128)    NOT NULL,          -- Central_Company | Central_Users
        RecordID             BIGINT           NOT NULL,          -- the deleted row's ID
        CentralCompanyID     INT              NULL,              -- Central_Company.ID (the user's company for a user row)
        CompanyCode          NVARCHAR(50)     NULL,
        CompanyName          NVARCHAR(200)    NULL,
        Username             NVARCHAR(256)    NULL,              -- user rows
        ApplicationCompanyID INT              NULL,
        ApplicationUserID    INT              NULL,
        InstanceKey          NVARCHAR(400)    NULL,
        RecordCreatedDate    DATETIME         NULL,
        RecordModifiedDate   DATETIME         NULL,
        RecordJson           NVARCHAR(MAX)    NULL,              -- the whole deleted row (DecryptedConnectionString left out)
        Reason               NVARCHAR(50)     NOT NULL,          -- COMPANY_DELETED | COMPANY_USERS_REMOVED | STALE_USER | RESERVATION_RELEASED | DIRECT
        DeletedBy            NVARCHAR(256)    NULL,              -- the application user who asked (else the database login)
        DeletedFrom          NVARCHAR(500)    NULL,              -- the installation's web address
        Reference            NVARCHAR(200)    NULL,              -- e.g. the installation's removal queue id
        BatchID              UNIQUEIDENTIFIER NULL,              -- one removal (a company and its users share it)
        DeletedAt            DATETIME         NOT NULL CONSTRAINT DF_Central_Delete_Audit_At DEFAULT (GETDATE()),
        DbLogin              NVARCHAR(128)    NOT NULL CONSTRAINT DF_Central_Delete_Audit_Login DEFAULT (SUSER_SNAME()),
        HostName             NVARCHAR(128)    NULL CONSTRAINT DF_Central_Delete_Audit_Host DEFAULT (HOST_NAME()),
        AppName              NVARCHAR(256)    NULL CONSTRAINT DF_Central_Delete_Audit_App DEFAULT (APP_NAME())
    );
    CREATE INDEX IX_Central_Delete_Audit_Code ON dbo.Central_Delete_Audit (CompanyCode, DeletedAt);
    CREATE INDEX IX_Central_Delete_Audit_At ON dbo.Central_Delete_Audit (DeletedAt);
END
GO

-- ── who / why of the current delete (SESSION_CONTEXT, read by the triggers) ────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_CentralDelete_SetContext
    @Reason      NVARCHAR(50)  = NULL,       -- NULL clears the context
    @DeletedBy   NVARCHAR(256) = NULL,
    @DeletedFrom NVARCHAR(500) = NULL,
    @Reference   NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @batch UNIQUEIDENTIFIER = CASE WHEN @Reason IS NULL THEN NULL ELSE NEWID() END;
    EXEC sys.sp_set_session_context @key = N'ecare.DeleteReason', @value = @Reason;
    EXEC sys.sp_set_session_context @key = N'ecare.DeletedBy',    @value = @DeletedBy;
    EXEC sys.sp_set_session_context @key = N'ecare.DeletedFrom',  @value = @DeletedFrom;
    EXEC sys.sp_set_session_context @key = N'ecare.DeleteRef',    @value = @Reference;
    EXEC sys.sp_set_session_context @key = N'ecare.DeleteBatch',  @value = @batch;
END
GO

CREATE OR ALTER TRIGGER dbo.trg_Central_Company_DeleteAudit ON dbo.Central_Company
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    INSERT dbo.Central_Delete_Audit (TableName, RecordID, CentralCompanyID, CompanyCode, CompanyName, ApplicationCompanyID, InstanceKey,
                                     RecordCreatedDate, RecordModifiedDate, RecordJson, Reason, DeletedBy, DeletedFrom, Reference, BatchID)
    SELECT N'Central_Company', d.ID, d.ID, d.CompanyCode, d.CompanyName, d.ApplicationCompanyID, d.InstanceKey,
           d.CreatedDate, d.ModifiedDate,
           (SELECT d.ID, d.CompanyCode, d.CompanyName, d.ApplicationCompanyID, d.ConnectionString, d.ApiUrl, d.WebUrl,
                   d.ValidFrom, d.ValidTo, d.InstanceKey, d.CreatedDate, d.ModifiedDate
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES),
           ISNULL(CAST(SESSION_CONTEXT(N'ecare.DeleteReason') AS NVARCHAR(50)), N'DIRECT'),
           ISNULL(CAST(SESSION_CONTEXT(N'ecare.DeletedBy') AS NVARCHAR(256)), SUSER_SNAME()),
           CAST(SESSION_CONTEXT(N'ecare.DeletedFrom') AS NVARCHAR(500)),
           CAST(SESSION_CONTEXT(N'ecare.DeleteRef') AS NVARCHAR(200)),
           CAST(SESSION_CONTEXT(N'ecare.DeleteBatch') AS UNIQUEIDENTIFIER)
      FROM deleted d;
END
GO

CREATE OR ALTER TRIGGER dbo.trg_Central_Users_DeleteAudit ON dbo.Central_Users
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    -- the company is read while it still exists (a company's users are deleted before the company)
    INSERT dbo.Central_Delete_Audit (TableName, RecordID, CentralCompanyID, CompanyCode, CompanyName, Username, ApplicationCompanyID,
                                     ApplicationUserID, InstanceKey, RecordCreatedDate, RecordModifiedDate, RecordJson,
                                     Reason, DeletedBy, DeletedFrom, Reference, BatchID)
    SELECT N'Central_Users', d.ID, d.CompanyID, c.CompanyCode, c.CompanyName, d.Username, c.ApplicationCompanyID,
           d.ApplicationUserID, d.InstanceKey, d.CreatedDate, d.ModifiedDate,
           (SELECT d.ID, d.Username, d.CompanyID, d.InstanceKey, d.ApplicationUserID, d.CreatedDate, d.ModifiedDate
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES),
           ISNULL(CAST(SESSION_CONTEXT(N'ecare.DeleteReason') AS NVARCHAR(50)), N'DIRECT'),
           ISNULL(CAST(SESSION_CONTEXT(N'ecare.DeletedBy') AS NVARCHAR(256)), SUSER_SNAME()),
           CAST(SESSION_CONTEXT(N'ecare.DeletedFrom') AS NVARCHAR(500)),
           CAST(SESSION_CONTEXT(N'ecare.DeleteRef') AS NVARCHAR(200)),
           CAST(SESSION_CONTEXT(N'ecare.DeleteBatch') AS UNIQUEIDENTIFIER)
      FROM deleted d
      LEFT JOIN dbo.Central_Company c ON c.ID = d.CompanyID;
END
GO

-- ── "Delete the company": the company and its central users ───────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_CentralCompany_Remove
    @InstanceKey          NVARCHAR(400),
    @ApplicationCompanyID INT,
    @Preview              BIT = 0,
    @DeletedBy            NVARCHAR(256) = NULL,   -- the application user who deleted the company (audit)
    @DeletedFrom          NVARCHAR(500) = NULL,   -- the installation's web address (audit)
    @Reference            NVARCHAR(200) = NULL    -- e.g. the installation's removal queue id (audit)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISNULL(@InstanceKey, N'') = N'' OR ISNULL(@ApplicationCompanyID, 0) <= 0
    BEGIN
        SELECT N'NOT_FOUND' AS Status, CAST(NULL AS NVARCHAR(50)) AS CompanyCode, 0 AS Companies, 0 AS Users;
        RETURN;
    END

    BEGIN TRANSACTION;
    DECLARE @Id INT, @Code NVARCHAR(50);
    SELECT @Id = ID, @Code = CompanyCode FROM dbo.Central_Company WITH (UPDLOCK, HOLDLOCK)
     WHERE InstanceKey = @InstanceKey AND ApplicationCompanyID = @ApplicationCompanyID;
    IF @Id IS NULL
    BEGIN
        COMMIT;
        SELECT N'NOT_FOUND' AS Status, CAST(NULL AS NVARCHAR(50)) AS CompanyCode, 0 AS Companies, 0 AS Users;
        RETURN;
    END

    DECLARE @Users INT = (SELECT COUNT(*) FROM dbo.Central_Users WHERE CompanyID = @Id);
    IF @Preview = 1
    BEGIN
        COMMIT;
        SELECT N'PREVIEW' AS Status, @Code AS CompanyCode, 1 AS Companies, @Users AS Users;
        RETURN;
    END

    EXEC dbo.usp_CentralDelete_SetContext @Reason = N'COMPANY_DELETED', @DeletedBy = @DeletedBy, @DeletedFrom = @DeletedFrom, @Reference = @Reference;
    DELETE dbo.Central_Users WHERE CompanyID = @Id;          -- audited (trigger), with the company's code / name
    SET @Users = @@ROWCOUNT;
    DELETE dbo.Central_Company WHERE ID = @Id;               -- audited (trigger)
    EXEC dbo.usp_CentralDelete_SetContext;                   -- cleared
    COMMIT;
    SELECT N'REMOVED' AS Status, @Code AS CompanyCode, 1 AS Companies, @Users AS Users;
END
GO

-- ── "Everything": the central rows of the removed application users ───────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_RemoveByApp
    @InstanceKey        NVARCHAR(400),
    @ApplicationUserIDs NVARCHAR(MAX),     -- JSON array of the application's Users.Id, e.g. [203,207]
    @Preview            BIT = 0,
    @DeletedBy          NVARCHAR(256) = NULL,
    @DeletedFrom        NVARCHAR(500) = NULL,
    @Reference          NVARCHAR(200) = NULL,
    @Reason             NVARCHAR(50)  = N'COMPANY_USERS_REMOVED'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ids TABLE (Id INT PRIMARY KEY);
    IF ISNULL(@InstanceKey, N'') <> N'' AND ISJSON(@ApplicationUserIDs) = 1
        INSERT @ids SELECT DISTINCT TRY_CAST(value AS INT) FROM OPENJSON(@ApplicationUserIDs) WHERE TRY_CAST(value AS INT) IS NOT NULL;

    DECLARE @n INT;
    IF @Preview = 1
        SET @n = (SELECT COUNT(*) FROM dbo.Central_Users WHERE InstanceKey = @InstanceKey AND ApplicationUserID IN (SELECT Id FROM @ids));
    ELSE
    BEGIN
        BEGIN TRANSACTION;
        EXEC dbo.usp_CentralDelete_SetContext @Reason = @Reason, @DeletedBy = @DeletedBy, @DeletedFrom = @DeletedFrom, @Reference = @Reference;
        DELETE dbo.Central_Users WHERE InstanceKey = @InstanceKey AND ApplicationUserID IN (SELECT Id FROM @ids);
        SET @n = @@ROWCOUNT;
        EXEC dbo.usp_CentralDelete_SetContext;
        COMMIT;
    END
    SELECT CASE WHEN @Preview = 1 THEN N'PREVIEW' WHEN @n > 0 THEN N'REMOVED' ELSE N'NOT_FOUND' END AS Status, @n AS Users;
END
GO

-- ── the existing clean-ups (2470) now say why they delete (audited as STALE_USER / RESERVATION_RELEASED) ─────────
CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_Release
    @CentralUserID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @n INT;
    BEGIN TRANSACTION;
    EXEC dbo.usp_CentralDelete_SetContext @Reason = N'RESERVATION_RELEASED', @DeletedBy = N'eCare360 (failed user save)';
    DELETE dbo.Central_Users WHERE ID = @CentralUserID AND ApplicationUserID IS NULL;
    SET @n = @@ROWCOUNT;
    EXEC dbo.usp_CentralDelete_SetContext;
    COMMIT;
    SELECT @n AS Released;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_CentralUser_Remove
    @CentralUserID BIGINT,
    @InstanceKey   NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @n INT;
    BEGIN TRANSACTION;
    EXEC dbo.usp_CentralDelete_SetContext @Reason = N'STALE_USER', @DeletedBy = N'eCare360 (user no longer in the installation)';
    DELETE dbo.Central_Users WHERE ID = @CentralUserID AND InstanceKey = @InstanceKey;
    SET @n = @@ROWCOUNT;
    EXEC dbo.usp_CentralDelete_SetContext;
    COMMIT;
    SELECT @n AS Removed;
END
GO

-- ── reading the audit ─────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_CentralDeleteAudit_List
    @CompanyCode NVARCHAR(50)  = NULL,
    @InstanceKey NVARCHAR(400) = NULL,
    @FromDate    DATE          = NULL,
    @ToDate      DATE          = NULL,
    @Top         INT           = 500
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) AuditID, TableName, RecordID, CentralCompanyID, CompanyCode, CompanyName, Username, ApplicationCompanyID,
           ApplicationUserID, InstanceKey, RecordCreatedDate, RecordModifiedDate, Reason, DeletedBy, DeletedFrom, Reference, BatchID,
           DeletedAt, DbLogin, HostName, AppName, RecordJson
      FROM dbo.Central_Delete_Audit
     WHERE (@CompanyCode IS NULL OR CompanyCode = @CompanyCode)
       AND (@InstanceKey IS NULL OR InstanceKey = @InstanceKey)
       AND (@FromDate IS NULL OR DeletedAt >= @FromDate)
       AND (@ToDate IS NULL OR DeletedAt < DATEADD(DAY, 1, @ToDate))
     ORDER BY AuditID DESC;
END
GO

PRINT 'Script 2488 applied on ' + DB_NAME() + ': central register removal (company / users) and Central_Delete_Audit.';
GO
SET NOEXEC OFF;
GO
