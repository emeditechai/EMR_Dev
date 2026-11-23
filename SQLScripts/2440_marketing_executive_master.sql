-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2440  Master > General > Marketing Executive
--   The company's marketing executives by business line (OPD / LAB / IPD / MED), with a monthly target.
--   Code: unique in the company (case and spaces ignored), letters / digits / - / _ only. Mobile: 10 digits starting
--   6-9 (Indian mobile). E-mail: name@domain.tld. Monthly target: 0 or more. Deleting hides the executive (kept for
--   history); a code stays taken by a deleted executive's record only while it exists - a deleted code can be reused.
--   usp_Api_MarketingExecutive_List, _Get, _Save, _SetStatus, _Delete (EMR.Api api/marketing-executives).
--   Page MASTER.MARKETINGEXECUTIVES: VIEW, ADD, EDIT, STATUS, DELETE. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('dbo.MarketingExecutive', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MarketingExecutive
    (
        ExecutiveId    INT IDENTITY(1,1) CONSTRAINT PK_MarketingExecutive PRIMARY KEY,
        CompanyId      INT            NOT NULL,
        ExecutiveType  VARCHAR(5)     NOT NULL,   -- OPD LAB IPD MED
        ExecutiveName  NVARCHAR(150)  NOT NULL,
        ExecutiveCode  NVARCHAR(30)   NOT NULL,
        PhoneNumber    VARCHAR(10)    NOT NULL,
        EmailId        NVARCHAR(150)  NULL,
        Address        NVARCHAR(500)  NULL,
        MonthlyTarget  DECIMAL(18,2)  NOT NULL CONSTRAINT DF_MarketingExecutive_Target DEFAULT (0),
        IsActive       BIT            NOT NULL CONSTRAINT DF_MarketingExecutive_Active DEFAULT (1),
        IsDeleted      BIT            NOT NULL CONSTRAINT DF_MarketingExecutive_Deleted DEFAULT (0),
        CreatedBy      INT            NULL,
        CreatedDate    DATETIME       NOT NULL CONSTRAINT DF_MarketingExecutive_Created DEFAULT (GETDATE()),
        ModifiedBy     INT            NULL,
        ModifiedDate   DATETIME       NULL,
        CONSTRAINT CK_MarketingExecutive_Type CHECK (ExecutiveType IN ('OPD', 'LAB', 'IPD', 'MED')),
        CONSTRAINT CK_MarketingExecutive_Phone CHECK (LEN(PhoneNumber) = 10 AND PhoneNumber NOT LIKE '%[^0-9]%'),
        CONSTRAINT CK_MarketingExecutive_Target CHECK (MonthlyTarget >= 0)
    );
    -- one live executive per code in a company
    CREATE UNIQUE INDEX UX_MarketingExecutive_Code ON dbo.MarketingExecutive (CompanyId, ExecutiveCode) WHERE IsDeleted = 0;
    CREATE INDEX IX_MarketingExecutive_Type ON dbo.MarketingExecutive (CompanyId, ExecutiveType, IsActive) WHERE IsDeleted = 0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MarketingExecutive_List
    @CompanyId INT, @Type VARCHAR(5) = NULL, @Search NVARCHAR(100) = NULL, @Status VARCHAR(10) = NULL   -- ACTIVE / INACTIVE / NULL = all
AS
BEGIN
    SET NOCOUNT ON;
    SET @Type = NULLIF(UPPER(@Type), ''); SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N''); SET @Status = NULLIF(UPPER(@Status), '');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT e.ExecutiveId, e.ExecutiveType, e.ExecutiveName, e.ExecutiveCode, e.PhoneNumber, e.EmailId, e.Address, e.MonthlyTarget, e.IsActive,
           e.CreatedDate, uc.FullName AS CreatedByName, e.ModifiedDate, um.FullName AS ModifiedByName
    FROM dbo.MarketingExecutive e
    LEFT JOIN dbo.Users uc ON uc.Id = e.CreatedBy
    LEFT JOIN dbo.Users um ON um.Id = e.ModifiedBy
    WHERE e.CompanyId = @CompanyId AND e.IsDeleted = 0
      AND (@Type IS NULL OR e.ExecutiveType = @Type)
      AND (@Status IS NULL OR (@Status = 'ACTIVE' AND e.IsActive = 1) OR (@Status = 'INACTIVE' AND e.IsActive = 0))
      AND (@Search IS NULL OR e.ExecutiveName LIKE @like OR e.ExecutiveCode LIKE @like OR e.PhoneNumber LIKE @like OR e.EmailId LIKE @like)
    ORDER BY e.ExecutiveType, e.ExecutiveName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MarketingExecutive_Get @CompanyId INT, @ExecutiveId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.ExecutiveId, e.ExecutiveType, e.ExecutiveName, e.ExecutiveCode, e.PhoneNumber, e.EmailId, e.Address, e.MonthlyTarget, e.IsActive,
           e.CreatedDate, uc.FullName AS CreatedByName, e.ModifiedDate, um.FullName AS ModifiedByName
    FROM dbo.MarketingExecutive e
    LEFT JOIN dbo.Users uc ON uc.Id = e.CreatedBy
    LEFT JOIN dbo.Users um ON um.Id = e.ModifiedBy
    WHERE e.ExecutiveId = @ExecutiveId AND e.CompanyId = @CompanyId AND e.IsDeleted = 0;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MarketingExecutive_Save
    @CompanyId INT, @UserId INT, @ExecutiveId INT = NULL, @ExecutiveType VARCHAR(5), @ExecutiveName NVARCHAR(150), @ExecutiveCode NVARCHAR(30),
    @PhoneNumber VARCHAR(20), @EmailId NVARCHAR(150) = NULL, @Address NVARCHAR(500) = NULL, @MonthlyTarget DECIMAL(18,2) = 0, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(400);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN me_sp;
        SET @ExecutiveType = UPPER(LTRIM(RTRIM(ISNULL(@ExecutiveType, ''))));
        SET @ExecutiveName = LTRIM(RTRIM(ISNULL(@ExecutiveName, N'')));
        SET @ExecutiveCode = UPPER(LTRIM(RTRIM(ISNULL(@ExecutiveCode, N''))));
        SET @PhoneNumber = LTRIM(RTRIM(ISNULL(@PhoneNumber, '')));
        SET @EmailId = NULLIF(LOWER(LTRIM(RTRIM(@EmailId))), N'');
        SET @Address = NULLIF(LTRIM(RTRIM(@Address)), N'');
        IF @ExecutiveType NOT IN ('OPD', 'LAB', 'IPD', 'MED') THROW 56001, 'Choose the type (OPD, LAB, IPD or MED).', 1;
        IF LEN(@ExecutiveName) < 2 THROW 56002, 'Enter the marketing executive''s name.', 1;
        IF @ExecutiveName LIKE N'%[0-9]%' THROW 56003, 'The name cannot contain digits.', 1;
        IF LEN(@ExecutiveCode) = 0 THROW 56004, 'Enter the code.', 1;
        IF LEN(@ExecutiveCode) > 20 OR @ExecutiveCode LIKE N'%[^A-Z0-9_-]%' THROW 56005, 'The code can have up to 20 letters, digits, - or _ (no spaces).', 1;
        IF LEN(@PhoneNumber) <> 10 OR @PhoneNumber LIKE '%[^0-9]%' OR LEFT(@PhoneNumber, 1) NOT IN ('6', '7', '8', '9')
            THROW 56006, 'Enter a valid 10-digit mobile number (starting with 6, 7, 8 or 9).', 1;
        IF @EmailId IS NOT NULL AND (@EmailId NOT LIKE N'_%@_%._%' OR @EmailId LIKE N'% %' OR @EmailId LIKE N'%@%@%' OR @EmailId LIKE N'%..%' OR @EmailId LIKE N'%.' OR @EmailId LIKE N'@%')
            THROW 56007, 'Enter a valid e-mail ID (e.g. name@example.com).', 1;
        IF @MonthlyTarget IS NULL OR @MonthlyTarget < 0 THROW 56008, 'The monthly target must be 0 or more.', 1;
        IF @ExecutiveId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.MarketingExecutive WITH (UPDLOCK) WHERE ExecutiveId = @ExecutiveId AND CompanyId = @CompanyId AND IsDeleted = 0)
            THROW 56009, 'The marketing executive was not found.', 1;
        DECLARE @dup NVARCHAR(150) = (SELECT TOP 1 ExecutiveName FROM dbo.MarketingExecutive WITH (UPDLOCK, HOLDLOCK)
                                      WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND ExecutiveCode = @ExecutiveCode AND ExecutiveId <> ISNULL(@ExecutiveId, 0));
        IF @dup IS NOT NULL BEGIN SET @msg = N'Code ' + @ExecutiveCode + N' is already used by ' + @dup + N'. Enter a different code.'; THROW 56010, @msg, 1; END;
        IF @ExecutiveId IS NULL
        BEGIN
            INSERT dbo.MarketingExecutive (CompanyId, ExecutiveType, ExecutiveName, ExecutiveCode, PhoneNumber, EmailId, Address, MonthlyTarget, IsActive, CreatedBy)
            VALUES (@CompanyId, @ExecutiveType, @ExecutiveName, @ExecutiveCode, @PhoneNumber, @EmailId, @Address, @MonthlyTarget, ISNULL(@IsActive, 1), @UserId);
            SET @ExecutiveId = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
            UPDATE dbo.MarketingExecutive SET ExecutiveType = @ExecutiveType, ExecutiveName = @ExecutiveName, ExecutiveCode = @ExecutiveCode, PhoneNumber = @PhoneNumber,
                   EmailId = @EmailId, Address = @Address, MonthlyTarget = @MonthlyTarget, IsActive = ISNULL(@IsActive, IsActive), ModifiedBy = @UserId, ModifiedDate = GETDATE()
            WHERE ExecutiveId = @ExecutiveId;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @ExecutiveId AS ExecutiveId, @ExecutiveCode AS ExecutiveCode;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN me_sp;
        IF ERROR_NUMBER() IN (2601, 2627) SELECT CAST(0 AS BIT) AS Success, CAST(N'This code is already used. Enter a different code.' AS NVARCHAR(400)) AS Error;
        ELSE IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MarketingExecutive_SetStatus @CompanyId INT, @UserId INT, @ExecutiveId INT, @IsActive BIT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.MarketingExecutive SET IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE ExecutiveId = @ExecutiveId AND CompanyId = @CompanyId AND IsDeleted = 0;
    IF @@ROWCOUNT = 0 SELECT CAST(0 AS BIT) AS Success, CAST(N'The marketing executive was not found.' AS NVARCHAR(400)) AS Error;
    ELSE SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @ExecutiveId AS ExecutiveId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MarketingExecutive_Delete @CompanyId INT, @UserId INT, @ExecutiveId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.MarketingExecutive SET IsDeleted = 1, IsActive = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE ExecutiveId = @ExecutiveId AND CompanyId = @CompanyId AND IsDeleted = 0;
    IF @@ROWCOUNT = 0 SELECT CAST(0 AS BIT) AS Success, CAST(N'The marketing executive was not found.' AS NVARCHAR(400)) AS Error;
    ELSE SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @ExecutiveId AS ExecutiveId;
END;
GO

-- ── page: Master > General > Marketing Executive ──────────────────────────────────────────────────────────────
SET NOCOUNT ON;
DECLARE @co INT = 1, @menu INT = (SELECT Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.GENERAL'), @page INT, @view INT, @ctl INT;
IF @menu IS NULL THROW 51400, 'Menu MASTER.GENERAL is missing.', 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'MASTER.MARKETINGEXECUTIVES', @Title = N'Marketing Executive Master',
     @Controller = N'MarketingExecutives', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 95, @Icon = N'bi bi-person-badge me-2',
     @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingExecutives', @Action = N'Index', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingExecutives', @Action = N'ListData', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingExecutives', @Action = N'Get', @Source = 'SEED';
DECLARE @c TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT, Act NVARCHAR(60));
INSERT @c VALUES ('ADD', N'Add a marketing executive', 20, N'Save'), ('EDIT', N'Edit a marketing executive', 30, N'Save'),
                 ('STATUS', N'Activate / deactivate', 40, N'SetStatus'), ('DELETE', N'Delete a marketing executive', 50, N'Delete');
DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @ca NVARCHAR(60);
DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort, Act FROM @c;
OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'MarketingExecutives', @Action = @ca, @Source = 'SEED';
    FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
END
CLOSE k; DEALLOCATE k;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2440 Marketing Executive master - done.';
GO
