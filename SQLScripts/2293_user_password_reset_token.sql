-- ============================================================================================================
-- Migration: 2293_user_password_reset_token.sql
-- Login > "Forgot password?": a user asks for a reset link by user name or email; the link is mailed with the mail
-- settings of the Head Office branch (Branchmaster.IsHOBranch = 1) of the user's company. Each link is single-use and
-- expires after 30 minutes; only a SHA-256 hash of the token is stored, never the token itself. Asking for a new link
-- cancels the earlier unused ones. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID(N'dbo.UserPasswordResetToken', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserPasswordResetToken
    (
        ResetTokenId  INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_UserPasswordResetToken PRIMARY KEY,
        UserId        INT              NOT NULL CONSTRAINT FK_UserPasswordResetToken_Users REFERENCES dbo.Users (Id),
        TokenHash     CHAR(64)         NOT NULL,            -- SHA-256 (hex) of the token in the mailed link
        CreatedDate   DATETIME         NOT NULL CONSTRAINT DF_UserPasswordResetToken_CreatedDate DEFAULT (GETDATE()),
        ExpiresAt     DATETIME         NOT NULL,
        UsedAt        DATETIME         NULL,                -- password changed with this link
        CancelledAt   DATETIME         NULL,                -- replaced by a newer link
        RequestIp     VARCHAR(45)      NULL,
        UsedIp        VARCHAR(45)      NULL,
        MailSent      BIT              NOT NULL CONSTRAINT DF_UserPasswordResetToken_MailSent DEFAULT (0)
    );
    CREATE UNIQUE INDEX UX_UserPasswordResetToken_TokenHash ON dbo.UserPasswordResetToken (TokenHash);
    CREATE INDEX IX_UserPasswordResetToken_User ON dbo.UserPasswordResetToken (UserId, CreatedDate);
END
GO
PRINT 'Script 2293 applied: password reset tokens (Forgot password).';
GO
