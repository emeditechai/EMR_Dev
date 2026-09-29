-- ============================================================================
-- Migration: 2169_authorization_api_tokens.sql
-- Description:
--   Server-Side Authorization - EMR.Api sign-in and account protection:
--     Users.Lockout_Until            temporary lockout after repeated wrong passwords
--                                    (IsLockedOut stays the administrator's permanent lock)
--     dbo.ApiRefreshToken            refresh tokens of api/auth, stored as SHA-256 hashes only;
--                                    rotated on every use, a reused token revokes its whole family
--   Procedures:
--     usp_Auth_Login_RecordFailure   count a wrong password; lock for @LockMinutes after @MaxAttempts
--     usp_Auth_Login_RecordSuccess   reset the counter
--     usp_Auth_RefreshToken_Create / _Rotate / _RevokeFamily / _RevokeUser
--   Run after 2168.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.Users', 'Lockout_Until') IS NULL
    ALTER TABLE dbo.Users ADD Lockout_Until DATETIME2(0) NULL;
GO

IF OBJECT_ID('dbo.ApiRefreshToken', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ApiRefreshToken
    (
        Token_ID        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ApiRefreshToken PRIMARY KEY,
        Token_Hash      CHAR(64)         NOT NULL,
        Family_ID       UNIQUEIDENTIFIER NOT NULL,
        User_ID         INT              NOT NULL CONSTRAINT FK_ApiRefreshToken_User REFERENCES dbo.Users(Id),
        Company_ID      INT              NOT NULL,
        Branch_ID       INT              NOT NULL,
        Role_Name       NVARCHAR(100)    NULL,
        Created_On      DATETIME2(0)     NOT NULL CONSTRAINT DF_ApiRefreshToken_Created DEFAULT SYSDATETIME(),
        Expires_On      DATETIME2(0)     NOT NULL,
        Used_On         DATETIME2(0)     NULL,
        Revoked_On      DATETIME2(0)     NULL,
        Revoked_Reason  NVARCHAR(100)    NULL,
        Created_IP      NVARCHAR(64)     NULL,
        User_Agent      NVARCHAR(300)    NULL
    );
    CREATE UNIQUE INDEX UX_ApiRefreshToken_Hash ON dbo.ApiRefreshToken(Token_Hash);
    CREATE INDEX IX_ApiRefreshToken_Family ON dbo.ApiRefreshToken(Family_ID);
    CREATE INDEX IX_ApiRefreshToken_User ON dbo.ApiRefreshToken(User_ID) INCLUDE (Revoked_On, Expires_On);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Login_RecordFailure
    @UserId INT, @MaxAttempts INT = 5, @LockMinutes INT = 15
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Users
    SET FailedLoginAttempts = ISNULL(FailedLoginAttempts, 0) + 1,
        Lockout_Until = CASE WHEN ISNULL(FailedLoginAttempts, 0) + 1 >= @MaxAttempts
                             THEN DATEADD(MINUTE, @LockMinutes, SYSDATETIME()) ELSE Lockout_Until END
    WHERE Id = @UserId;
    SELECT FailedLoginAttempts, Lockout_Until FROM dbo.Users WHERE Id = @UserId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Login_RecordSuccess
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Users SET FailedLoginAttempts = 0, Lockout_Until = NULL, LastLoginDate = SYSDATETIME() WHERE Id = @UserId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_RefreshToken_Create
    @TokenHash CHAR(64), @FamilyId UNIQUEIDENTIFIER, @UserId INT, @CompanyId INT, @BranchId INT, @RoleName NVARCHAR(100),
    @ExpiresOn DATETIME2(0), @CreatedIp NVARCHAR(64) = NULL, @UserAgent NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.ApiRefreshToken (Token_Hash, Family_ID, User_ID, Company_ID, Branch_ID, Role_Name, Expires_On, Created_IP, User_Agent)
    VALUES (@TokenHash, @FamilyId, @UserId, @CompanyId, @BranchId, @RoleName, @ExpiresOn, @CreatedIp, LEFT(@UserAgent, 300));
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_RefreshToken_RevokeFamily
    @FamilyId UNIQUEIDENTIFIER, @Reason NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.ApiRefreshToken SET Revoked_On = SYSDATETIME(), Revoked_Reason = @Reason
    WHERE Family_ID = @FamilyId AND Revoked_On IS NULL;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_RefreshToken_RevokeUser
    @UserId INT, @Reason NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.ApiRefreshToken SET Revoked_On = SYSDATETIME(), Revoked_Reason = @Reason
    WHERE User_ID = @UserId AND Revoked_On IS NULL;
END;
GO

-- Exchanges a refresh token for a new one in the same family.
-- Result: Status = OK | INVALID | EXPIRED | REUSED | REVOKED | INACTIVE, plus the family's context when OK.
-- A token presented a second time (already used) means it was copied: the whole family is revoked.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_RefreshToken_Rotate
    @TokenHash CHAR(64), @NewTokenHash CHAR(64), @NewExpiresOn DATETIME2(0), @CreatedIp NVARCHAR(64) = NULL, @UserAgent NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;

    DECLARE @id BIGINT, @family UNIQUEIDENTIFIER, @userId INT, @companyId INT, @branchId INT, @role NVARCHAR(100),
            @expires DATETIME2(0), @used DATETIME2(0), @revoked DATETIME2(0);
    SELECT @id = Token_ID, @family = Family_ID, @userId = User_ID, @companyId = Company_ID, @branchId = Branch_ID,
           @role = Role_Name, @expires = Expires_On, @used = Used_On, @revoked = Revoked_On
    FROM dbo.ApiRefreshToken WITH (UPDLOCK, HOLDLOCK)
    WHERE Token_Hash = @TokenHash;

    IF @id IS NULL
    BEGIN COMMIT; SELECT 'INVALID' AS Status; RETURN; END

    IF @used IS NOT NULL
    BEGIN
        UPDATE dbo.ApiRefreshToken SET Revoked_On = SYSDATETIME(), Revoked_Reason = 'Refresh token reused'
        WHERE Family_ID = @family AND Revoked_On IS NULL;
        COMMIT; SELECT 'REUSED' AS Status, @userId AS User_ID; RETURN;
    END
    IF @revoked IS NOT NULL BEGIN COMMIT; SELECT 'REVOKED' AS Status, @userId AS User_ID; RETURN; END
    IF @expires <= SYSDATETIME() BEGIN COMMIT; SELECT 'EXPIRED' AS Status, @userId AS User_ID; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @userId AND IsActive = 1 AND ISNULL(IsLockedOut, 0) = 0)
    BEGIN
        UPDATE dbo.ApiRefreshToken SET Revoked_On = SYSDATETIME(), Revoked_Reason = 'User inactive'
        WHERE Family_ID = @family AND Revoked_On IS NULL;
        COMMIT; SELECT 'INACTIVE' AS Status, @userId AS User_ID; RETURN;
    END

    UPDATE dbo.ApiRefreshToken SET Used_On = SYSDATETIME() WHERE Token_ID = @id;
    INSERT INTO dbo.ApiRefreshToken (Token_Hash, Family_ID, User_ID, Company_ID, Branch_ID, Role_Name, Expires_On, Created_IP, User_Agent)
    VALUES (@NewTokenHash, @family, @userId, @companyId, @branchId, @role, @NewExpiresOn, @CreatedIp, LEFT(@UserAgent, 300));
    COMMIT;

    SELECT 'OK' AS Status, @userId AS User_ID, @companyId AS Company_ID, @branchId AS Branch_ID, @role AS Role_Name, @family AS Family_ID;
END;
GO
PRINT 'Script 2169 applied: API sign-in, refresh tokens and lockout ready.';
GO
