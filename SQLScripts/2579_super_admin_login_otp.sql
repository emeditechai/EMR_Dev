-- ============================================================================
-- Migration: 2579_super_admin_login_otp.sql
-- Description:
--   Super Admin sign-in (Users.IsSuperAdmin = 1) needs a one-time code after the password: a 6-digit code is sent on
--   WhatsApp (Users.PhoneNumber / Phone) and by e-mail (Users.Email) and must be typed before the session starts.
--   dbo.UserLoginOtp keeps one row per code sent. Only a SHA-256 hash of the code is stored; a code works once,
--   expires after 5 minutes and is cancelled after 5 wrong tries.
--   Safe to run more than once.
-- ============================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.UserLoginOtp', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserLoginOtp
    (
        LoginOtpId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_UserLoginOtp PRIMARY KEY,
        UserId          INT            NOT NULL CONSTRAINT FK_UserLoginOtp_Users REFERENCES dbo.Users (Id),
        CodeHash        CHAR(64)       NOT NULL,
        ExpiresAt       DATETIME       NOT NULL,
        WrongAttempts   INT            NOT NULL CONSTRAINT DF_UserLoginOtp_WrongAttempts DEFAULT (0),
        SentWhatsApp    BIT            NOT NULL CONSTRAINT DF_UserLoginOtp_SentWhatsApp DEFAULT (0),
        SentEmail       BIT            NOT NULL CONSTRAINT DF_UserLoginOtp_SentEmail DEFAULT (0),
        RequestIp       NVARCHAR(45)   NULL,
        UsedAt          DATETIME       NULL,
        CancelledAt     DATETIME       NULL,
        CreatedDate     DATETIME       NOT NULL CONSTRAINT DF_UserLoginOtp_CreatedDate DEFAULT (GETDATE())
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_UserLoginOtp_User_Created' AND object_id = OBJECT_ID(N'dbo.UserLoginOtp'))
    CREATE INDEX IX_UserLoginOtp_User_Created ON dbo.UserLoginOtp (UserId, CreatedDate DESC);
GO

PRINT '2579: dbo.UserLoginOtp ready.';
GO
