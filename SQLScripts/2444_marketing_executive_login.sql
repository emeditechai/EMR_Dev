-- 2444: Marketing Executive login. When an executive has an e-mail ID, a login is created with it (Users, User_Type 'U',
-- Is_MarketingExecutive = 1, role "Marketing", the creating user's branch; more branches can be added in User Master).
-- Created on add, or on edit for an executive that has no login yet. The login follows the executive's name, mobile, e-mail
-- and status. Run after 2440-2443. The new role gets no rights: grant them in Role Permissions.
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.Users', 'Is_MarketingExecutive') IS NULL
    ALTER TABLE dbo.Users ADD Is_MarketingExecutive BIT NOT NULL CONSTRAINT DF_Users_Is_MarketingExecutive DEFAULT (0);
GO
IF COL_LENGTH('dbo.MarketingExecutive', 'LoginUserId') IS NULL
    ALTER TABLE dbo.MarketingExecutive ADD LoginUserId INT NULL CONSTRAINT FK_MarketingExecutive_LoginUser REFERENCES dbo.Users (Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_MarketingExecutive_LoginUser' AND object_id = OBJECT_ID('dbo.MarketingExecutive'))
    CREATE UNIQUE INDEX UX_MarketingExecutive_LoginUser ON dbo.MarketingExecutive (LoginUserId) WHERE LoginUserId IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.roles WHERE Name = N'Marketing')
    INSERT dbo.roles (Name, Description, IsSystemRole, CreatedDate, IconClass, CompanyId)
    VALUES (N'Marketing', N'Marketing executives (login created from the Marketing Executive Master)', 0, SYSUTCDATETIME(), N'fas fa-bullhorn', 1);
GO

-- is the e-mail free for the executive's login? (live check on the form; the save checks it again)
CREATE OR ALTER PROCEDURE dbo.usp_Api_MarketingExecutive_CheckEmail @CompanyId INT, @ExecutiveId INT = NULL, @EmailId NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    SET @EmailId = NULLIF(LOWER(LTRIM(RTRIM(@EmailId))), N'');
    DECLARE @Own INT = (SELECT LoginUserId FROM dbo.MarketingExecutive WHERE ExecutiveId = @ExecutiveId AND CompanyId = @CompanyId AND IsDeleted = 0);
    DECLARE @By NVARCHAR(200) = (SELECT TOP 1 ISNULL(NULLIF(FullName, N''), Username) FROM dbo.Users
                                 WHERE Id <> ISNULL(@Own, 0) AND (LOWER(LTRIM(RTRIM(Email))) = @EmailId OR Username = @EmailId));
    SELECT CAST(CASE WHEN @EmailId IS NOT NULL AND @By IS NULL THEN 1 ELSE 0 END AS BIT) AS Available,
           CASE WHEN @EmailId IS NULL THEN N'Enter an e-mail ID.' WHEN @By IS NOT NULL THEN N'Already used by the login of ' + @By + N'.'
                ELSE N'Available for the login.' END AS Message,
           CAST(CASE WHEN @Own IS NULL THEN 0 ELSE 1 END AS BIT) AS HasLogin;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MarketingExecutive_List
    @CompanyId INT, @Type VARCHAR(5) = NULL, @Search NVARCHAR(100) = NULL, @Status VARCHAR(10) = NULL   -- ACTIVE / INACTIVE / NULL = all
AS
BEGIN
    SET NOCOUNT ON;
    SET @Type = NULLIF(UPPER(@Type), ''); SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N''); SET @Status = NULLIF(UPPER(@Status), '');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT e.ExecutiveId, e.ExecutiveType, e.ExecutiveName, e.ExecutiveCode, e.PhoneNumber, e.EmailId, e.Address, e.MonthlyTarget, e.IsActive,
           e.CreatedDate, uc.FullName AS CreatedByName, e.ModifiedDate, um.FullName AS ModifiedByName,
           e.LoginUserId, lu.Username AS LoginUsername, CAST(CASE WHEN lu.Id IS NULL THEN 0 ELSE 1 END AS BIT) AS HasLogin, lu.IsActive AS LoginActive
    FROM dbo.MarketingExecutive e
    LEFT JOIN dbo.Users uc ON uc.Id = e.CreatedBy
    LEFT JOIN dbo.Users um ON um.Id = e.ModifiedBy
    LEFT JOIN dbo.Users lu ON lu.Id = e.LoginUserId
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
           e.CreatedDate, uc.FullName AS CreatedByName, e.ModifiedDate, um.FullName AS ModifiedByName,
           e.LoginUserId, lu.Username AS LoginUsername, CAST(CASE WHEN lu.Id IS NULL THEN 0 ELSE 1 END AS BIT) AS HasLogin, lu.IsActive AS LoginActive
    FROM dbo.MarketingExecutive e
    LEFT JOIN dbo.Users uc ON uc.Id = e.CreatedBy
    LEFT JOIN dbo.Users um ON um.Id = e.ModifiedBy
    LEFT JOIN dbo.Users lu ON lu.Id = e.LoginUserId
    WHERE e.ExecutiveId = @ExecutiveId AND e.CompanyId = @CompanyId AND e.IsDeleted = 0;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MarketingExecutive_Save
    @CompanyId INT, @UserId INT, @ExecutiveId INT = NULL, @ExecutiveType VARCHAR(5), @ExecutiveName NVARCHAR(150), @ExecutiveCode NVARCHAR(30),
    @PhoneNumber VARCHAR(20), @EmailId NVARCHAR(150) = NULL, @Address NVARCHAR(500) = NULL, @MonthlyTarget DECIMAL(18,2) = 0, @IsActive BIT = 1,
    @BranchId INT = NULL, @LoginPasswordHash NVARCHAR(500) = NULL, @LoginSalt NVARCHAR(500) = NULL   -- 2444: login of the executive
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
        -- 2444: the executive signs in with the e-mail; it must be free among all sign-ins (other than the executive's own login)
        DECLARE @OwnLogin INT = (SELECT LoginUserId FROM dbo.MarketingExecutive WHERE ExecutiveId = @ExecutiveId);
        IF @OwnLogin IS NOT NULL AND @EmailId IS NULL THROW 56011, 'This executive has a login - the e-mail ID (the sign-in) cannot be removed.', 1;
        IF @EmailId IS NOT NULL AND (@OwnLogin IS NOT NULL OR @LoginPasswordHash IS NOT NULL) AND LEN(@EmailId) > 100
            THROW 56012, 'For a login the e-mail ID can be up to 100 characters.', 1;
        IF @EmailId IS NOT NULL AND (@OwnLogin IS NOT NULL OR @LoginPasswordHash IS NOT NULL)
           AND EXISTS (SELECT 1 FROM dbo.Users WITH (UPDLOCK, HOLDLOCK) WHERE Id <> ISNULL(@OwnLogin, 0) AND (LOWER(LTRIM(RTRIM(Email))) = @EmailId OR Username = @EmailId))
        BEGIN SET @msg = N'The e-mail ID ' + @EmailId + N' is already used by another login. Enter a different e-mail ID.'; THROW 56013, @msg, 1; END;
        IF @OwnLogin IS NULL AND @EmailId IS NOT NULL AND @LoginPasswordHash IS NULL THROW 56014, 'Set a password for the executive''s login.', 1;
        IF @OwnLogin IS NULL AND @LoginPasswordHash IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId) THROW 56015, 'Your branch could not be found - sign in again.', 1;
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
        -- 2444: create the login (User_Type U, Is_MarketingExecutive = 1, role Marketing, the creator's branch) or keep it in step
        DECLARE @LoginId INT = (SELECT LoginUserId FROM dbo.MarketingExecutive WHERE ExecutiveId = @ExecutiveId), @Created BIT = 0, @Active BIT;
        SELECT @Active = IsActive FROM dbo.MarketingExecutive WHERE ExecutiveId = @ExecutiveId;
        DECLARE @First NVARCHAR(150) = LEFT(@ExecutiveName, CHARINDEX(N' ', @ExecutiveName + N' ') - 1);
        DECLARE @Last NVARCHAR(150) = LTRIM(SUBSTRING(@ExecutiveName, LEN(@First) + 1, 150));
        IF @LoginId IS NULL AND @EmailId IS NOT NULL
        BEGIN
            INSERT dbo.Users (Username, Email, PasswordHash, Salt, FirstName, LastName, FullName, PhoneNumber, Phone, IsActive, CompanyId,
                              PasswordLastChanged, CreatedDate, LastModifiedDate, User_Type, Is_MarketingExecutive)
            VALUES (@EmailId, @EmailId, @LoginPasswordHash, @LoginSalt, @First, @Last, @ExecutiveName, @PhoneNumber, @PhoneNumber, @Active, @CompanyId,
                    GETDATE(), GETDATE(), GETDATE(), 'U', 1);
            SET @LoginId = CAST(SCOPE_IDENTITY() AS INT); SET @Created = 1;
            INSERT dbo.UserBranches (UserId, BranchID, IsActive, CreatedBy, CreatedDate, ModifiedBy, ModifiedDate, CompanyId)
            VALUES (@LoginId, @BranchId, 1, @UserId, GETDATE(), @UserId, GETDATE(), @CompanyId);
            DECLARE @RoleId INT = (SELECT TOP 1 Id FROM dbo.roles WHERE Name = N'Marketing' ORDER BY Id);
            IF @RoleId IS NULL THROW 56016, 'The Marketing role is missing (SQLScripts/2444).', 1;
            INSERT dbo.Userroles (UserId, RoleId, IsActive, AssignedDate, AssignedBy, CreatedBy, CreatedDate, ModifiedBy, ModifiedDate)
            VALUES (@LoginId, @RoleId, 1, GETDATE(), @UserId, @UserId, GETDATE(), @UserId, GETDATE());
            UPDATE dbo.MarketingExecutive SET LoginUserId = @LoginId WHERE ExecutiveId = @ExecutiveId;
        END
        ELSE IF @LoginId IS NOT NULL
            UPDATE dbo.Users SET Username = @EmailId, Email = @EmailId, FirstName = @First, LastName = @Last, FullName = @ExecutiveName,
                   PhoneNumber = @PhoneNumber, Phone = @PhoneNumber, IsActive = @Active, LastModifiedDate = GETDATE()
            WHERE Id = @LoginId;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @ExecutiveId AS ExecutiveId, @ExecutiveCode AS ExecutiveCode,
               @LoginId AS LoginUserId, @Created AS LoginCreated, CASE WHEN @LoginId IS NOT NULL THEN @EmailId END AS LoginUsername;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN me_sp;
        IF ERROR_NUMBER() IN (2601, 2627) SELECT CAST(0 AS BIT) AS Success, CAST(CASE WHEN ERROR_MESSAGE() LIKE N'%Users%' THEN N'This e-mail ID is already used by another login.' ELSE N'This code is already used. Enter a different code.' END AS NVARCHAR(400)) AS Error;
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
    IF @@ROWCOUNT = 0 BEGIN SELECT CAST(0 AS BIT) AS Success, CAST(N'The marketing executive was not found.' AS NVARCHAR(400)) AS Error; RETURN; END;
    UPDATE u SET IsActive = @IsActive, LastModifiedDate = GETDATE() FROM dbo.Users u JOIN dbo.MarketingExecutive e ON e.LoginUserId = u.Id WHERE e.ExecutiveId = @ExecutiveId;
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @ExecutiveId AS ExecutiveId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MarketingExecutive_Delete @CompanyId INT, @UserId INT, @ExecutiveId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT = (SELECT COUNT(*) FROM dbo.DoctorMaster WHERE MarketingExecutiveId = @ExecutiveId AND CompanyId = @CompanyId);
    IF @n > 0
    BEGIN
        SELECT CAST(0 AS BIT) AS Success,
               CAST(CONCAT(N'This marketing executive is assigned to ', @n, N' doctor(s). Change them in Doctor Master first, or deactivate the executive instead.') AS NVARCHAR(400)) AS Error;
        RETURN;
    END
    UPDATE dbo.MarketingExecutive SET IsDeleted = 1, IsActive = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE ExecutiveId = @ExecutiveId AND CompanyId = @CompanyId AND IsDeleted = 0;
    IF @@ROWCOUNT = 0 BEGIN SELECT CAST(0 AS BIT) AS Success, CAST(N'The marketing executive was not found.' AS NVARCHAR(400)) AS Error; RETURN; END;
    -- 2444: a deleted executive can no longer sign in
    UPDATE u SET IsActive = 0, LastModifiedDate = GETDATE() FROM dbo.Users u JOIN dbo.MarketingExecutive e ON e.LoginUserId = u.Id WHERE e.ExecutiveId = @ExecutiveId;
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @ExecutiveId AS ExecutiveId;
END;
GO

-- the live e-mail check of the form opens with the page (VIEW)
DECLARE @page INT = (SELECT TOP 1 Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.MARKETINGEXECUTIVES');
DECLARE @view INT = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
IF @view IS NULL THROW 51401, 'Page MASTER.MARKETINGEXECUTIVES (SQLScripts/2440) is missing.', 1;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingExecutives', @Action = N'CheckEmail', @Source = 'SEED';
GO

PRINT '2444 Marketing Executive login - done.';
GO
