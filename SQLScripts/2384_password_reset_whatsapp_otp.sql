-- ============================================================================================================
-- 2384  Phlebotomist app > Forgot password: a code on WhatsApp, then a new password.
--   1. usp_Auth_PasswordOtp_Create: a 6-digit code valid for 10 minutes, one a minute and five an hour per user.
--      A new code cancels the earlier one.
--   2. usp_Auth_PasswordOtp_Verify: five wrong tries cancel the code. A right code opens a 10-minute reset token.
--   3. usp_Auth_PasswordOtp_Reset: the token works once. It sets the password and cancels unused codes and mailed
--      reset links. EMR.Api signs the user out of every device.
-- Only SHA-256 hashes of the code and of the token are stored. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID(N'dbo.UserPasswordResetOtp', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserPasswordResetOtp
    (
        OtpId          INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_UserPasswordResetOtp PRIMARY KEY,
        UserId         INT         NOT NULL CONSTRAINT FK_UserPasswordResetOtp_Users REFERENCES dbo.Users (Id),
        OtpHash        CHAR(64)    NOT NULL,            -- SHA-256 (hex) of user id + code
        Attempts       TINYINT     NOT NULL CONSTRAINT DF_UserPasswordResetOtp_Attempts DEFAULT (0),
        CreatedDate    DATETIME    NOT NULL CONSTRAINT DF_UserPasswordResetOtp_CreatedDate DEFAULT (GETDATE()),
        ExpiresAt      DATETIME    NOT NULL,
        VerifiedAt     DATETIME    NULL,
        ResetTokenHash CHAR(64)    NULL,                -- SHA-256 (hex) of the token given after the right code
        ResetExpiresAt DATETIME    NULL,
        UsedAt         DATETIME    NULL,                -- password changed
        CancelledAt    DATETIME    NULL,                -- replaced, or too many wrong tries
        RequestIp      VARCHAR(45) NULL
    );
    CREATE INDEX IX_UserPasswordResetOtp_User ON dbo.UserPasswordResetOtp (UserId, CreatedDate);
    CREATE UNIQUE INDEX UX_UserPasswordResetOtp_Token ON dbo.UserPasswordResetOtp (ResetTokenHash) WHERE ResetTokenHash IS NOT NULL;
END
GO

-- description (picked up by the data dictionary)
IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.UserPasswordResetOtp') AND minor_id = 0 AND name = 'MS_Description')
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
         @value = N'Forgot password in the phlebotomist app: WhatsApp codes and the reset token a right code opens. Only hashes are stored.',
         @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'UserPasswordResetOtp';
GO

-- Returns the new OtpId, or no row while the user has had a code in the last minute or five in the last hour.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_PasswordOtp_Create
    @UserId  INT,
    @OtpHash CHAR(64),
    @Minutes INT,
    @Ip      VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;
        IF EXISTS (SELECT 1 FROM dbo.UserPasswordResetOtp WITH (UPDLOCK, HOLDLOCK) WHERE UserId = @UserId AND CreatedDate > DATEADD(MINUTE, -1, GETDATE()))
           OR (SELECT COUNT(*) FROM dbo.UserPasswordResetOtp WITH (UPDLOCK, HOLDLOCK) WHERE UserId = @UserId AND CreatedDate > DATEADD(HOUR, -1, GETDATE())) >= 5
        BEGIN
            COMMIT;
            RETURN;
        END

        UPDATE dbo.UserPasswordResetOtp SET CancelledAt = GETDATE()
         WHERE UserId = @UserId AND UsedAt IS NULL AND CancelledAt IS NULL;

        INSERT dbo.UserPasswordResetOtp (UserId, OtpHash, ExpiresAt, RequestIp)
        VALUES (@UserId, @OtpHash, DATEADD(MINUTE, @Minutes, GETDATE()), @Ip);
        DECLARE @Id INT = SCOPE_IDENTITY();
    COMMIT;

    SELECT @Id AS OtpId;
END
GO

-- Returns 1 when the code is right and the reset token is open, else 0.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_PasswordOtp_Verify
    @UserId         INT,
    @OtpHash        CHAR(64),
    @ResetTokenHash CHAR(64),
    @Minutes        INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Id INT, @Hash CHAR(64), @Tries TINYINT, @Ok BIT = 0;

    BEGIN TRANSACTION;
        SELECT TOP 1 @Id = OtpId, @Hash = OtpHash, @Tries = Attempts
          FROM dbo.UserPasswordResetOtp WITH (UPDLOCK, HOLDLOCK)
         WHERE UserId = @UserId AND UsedAt IS NULL AND CancelledAt IS NULL AND VerifiedAt IS NULL AND ExpiresAt > GETDATE()
         ORDER BY OtpId DESC;

        IF @Id IS NOT NULL
        BEGIN
            IF @Hash = @OtpHash
            BEGIN
                UPDATE dbo.UserPasswordResetOtp
                   SET VerifiedAt = GETDATE(), ResetTokenHash = @ResetTokenHash, ResetExpiresAt = DATEADD(MINUTE, @Minutes, GETDATE())
                 WHERE OtpId = @Id;
                SET @Ok = 1;
            END
            ELSE
                UPDATE dbo.UserPasswordResetOtp
                   SET Attempts = @Tries + 1, CancelledAt = CASE WHEN @Tries + 1 >= 5 THEN GETDATE() END
                 WHERE OtpId = @Id;
        END
    COMMIT;

    SELECT @Ok AS Verified;
END
GO

-- Returns the user's id when the token was good and the password is changed, else no row.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_PasswordOtp_Reset
    @ResetTokenHash CHAR(64),
    @PasswordHash   NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Id INT, @UserId INT;

    BEGIN TRANSACTION;
        SELECT @Id = o.OtpId, @UserId = o.UserId
          FROM dbo.UserPasswordResetOtp o WITH (UPDLOCK, HOLDLOCK)
          JOIN dbo.Users u ON u.Id = o.UserId AND u.IsActive = 1 AND ISNULL(u.IsLockedOut, 0) = 0
         WHERE o.ResetTokenHash = @ResetTokenHash AND o.UsedAt IS NULL AND o.CancelledAt IS NULL AND o.ResetExpiresAt > GETDATE();

        IF @Id IS NULL
        BEGIN
            COMMIT;
            RETURN;
        END

        UPDATE dbo.UserPasswordResetOtp SET UsedAt = GETDATE() WHERE OtpId = @Id;
        UPDATE dbo.UserPasswordResetOtp SET CancelledAt = GETDATE() WHERE UserId = @UserId AND OtpId <> @Id AND UsedAt IS NULL AND CancelledAt IS NULL;
        UPDATE dbo.UserPasswordResetToken SET CancelledAt = GETDATE() WHERE UserId = @UserId AND UsedAt IS NULL AND CancelledAt IS NULL;
        UPDATE dbo.Users
           SET PasswordHash = @PasswordHash, PasswordLastChanged = SYSDATETIME(), MustChangePassword = 0, Permission_Version = Permission_Version + 1
         WHERE Id = @UserId;
    COMMIT;

    SELECT @UserId AS UserId;
END
GO
PRINT 'Script 2384 applied: forgot password by WhatsApp code.';
GO
