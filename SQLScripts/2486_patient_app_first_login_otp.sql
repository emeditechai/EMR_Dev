-- ============================================================================================================
-- 2486  Patient app: first sign-in by WhatsApp code, forgot password, and refresh tokens - as the marketing
--       executive app does it (2384, 2457, 2169), for PatientMaster instead of Users.
--   1. PatientMaster.Is_App_Verified: 0 until the patient has confirmed a code sent to the mobile number of the
--      patient record. An unverified patient cannot sign in to the app: the app asks for a code
--      (usp_PatientApp_Otp_Create), confirms it (_Verify) and sets the password (_Reset), which verifies the patient,
--      creates the portal login if there was none and unlocks it. Patients who already set a password of their own
--      (IsLoginGenerated = 1 and IsPasswordchanged = 1) stay verified.
--   2. dbo.PatientAppOtp: 6-digit codes valid for 10 minutes, one a minute and five an hour per patient; five wrong
--      tries cancel a code; a right code opens a 10-minute reset token that works once. Only SHA-256 hashes are kept.
--   3. dbo.PatientApiRefreshToken: the patient app's refresh tokens (EMR.Api api/auth/patient-refresh), rotated on
--      every use; a token presented twice revokes its whole family. A password reset signs the patient out everywhere.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.PatientMaster', 'Is_App_Verified') IS NULL
BEGIN
    ALTER TABLE dbo.PatientMaster ADD Is_App_Verified BIT NOT NULL CONSTRAINT DF_PatientMaster_Is_App_Verified DEFAULT (0);
    -- a patient with a password of their own is verified already
    EXEC (N'UPDATE dbo.PatientMaster SET Is_App_Verified = 1
             WHERE ISNULL(IsLoginGenerated, 0) = 1 AND ISNULL(IsPasswordchanged, 0) = 1 AND NULLIF(PasswordHash, N'''') IS NOT NULL');
END
GO
IF COL_LENGTH('dbo.PatientMaster', 'App_Verified_Date') IS NULL
    ALTER TABLE dbo.PatientMaster ADD App_Verified_Date DATETIME NULL;
GO

IF OBJECT_ID(N'dbo.PatientAppOtp', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PatientAppOtp
    (
        OtpId          INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PatientAppOtp PRIMARY KEY,
        PatientId      INT         NOT NULL CONSTRAINT FK_PatientAppOtp_PatientMaster REFERENCES dbo.PatientMaster (PatientId),
        OtpHash        CHAR(64)    NOT NULL,            -- SHA-256 (hex) of patient id + code
        Attempts       TINYINT     NOT NULL CONSTRAINT DF_PatientAppOtp_Attempts DEFAULT (0),
        CreatedDate    DATETIME    NOT NULL CONSTRAINT DF_PatientAppOtp_CreatedDate DEFAULT (GETDATE()),
        ExpiresAt      DATETIME    NOT NULL,
        VerifiedAt     DATETIME    NULL,
        ResetTokenHash CHAR(64)    NULL,                -- SHA-256 (hex) of the token given after the right code
        ResetExpiresAt DATETIME    NULL,
        UsedAt         DATETIME    NULL,                -- password set
        CancelledAt    DATETIME    NULL,                -- replaced, or too many wrong tries
        RequestIp      VARCHAR(45) NULL
    );
    CREATE INDEX IX_PatientAppOtp_Patient ON dbo.PatientAppOtp (PatientId, CreatedDate);
    CREATE UNIQUE INDEX UX_PatientAppOtp_Token ON dbo.PatientAppOtp (ResetTokenHash) WHERE ResetTokenHash IS NOT NULL;
END
GO

IF OBJECT_ID(N'dbo.PatientApiRefreshToken', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PatientApiRefreshToken
    (
        Token_ID        BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PatientApiRefreshToken PRIMARY KEY,
        Token_Hash      CHAR(64)         NOT NULL,
        Family_ID       UNIQUEIDENTIFIER NOT NULL,
        Patient_ID      INT              NOT NULL CONSTRAINT FK_PatientApiRefreshToken_PatientMaster REFERENCES dbo.PatientMaster (PatientId),
        Created_On      DATETIME2(0)     NOT NULL CONSTRAINT DF_PatientApiRefreshToken_Created DEFAULT SYSDATETIME(),
        Expires_On      DATETIME2(0)     NOT NULL,
        Used_On         DATETIME2(0)     NULL,
        Revoked_On      DATETIME2(0)     NULL,
        Revoked_Reason  NVARCHAR(100)    NULL,
        Device_Id       NVARCHAR(100)    NULL,
        Created_IP      NVARCHAR(64)     NULL,
        User_Agent      NVARCHAR(300)    NULL
    );
    CREATE UNIQUE INDEX UX_PatientApiRefreshToken_Hash ON dbo.PatientApiRefreshToken (Token_Hash);
    CREATE INDEX IX_PatientApiRefreshToken_Family ON dbo.PatientApiRefreshToken (Family_ID);
    CREATE INDEX IX_PatientApiRefreshToken_Patient ON dbo.PatientApiRefreshToken (Patient_ID) INCLUDE (Revoked_On, Expires_On);
END
GO

-- descriptions (picked up by the data dictionary)
DECLARE @t SYSNAME, @c SYSNAME, @v NVARCHAR(400);
DECLARE dc CURSOR LOCAL FAST_FORWARD FOR
    SELECT 'PatientMaster', 'Is_App_Verified', N'0 = the patient has not confirmed a WhatsApp code in the patient app yet and cannot sign in there; 1 = verified. Set when the code is confirmed and the password is set.'
    UNION ALL SELECT 'PatientMaster', 'App_Verified_Date', N'When the patient was verified by WhatsApp code in the patient app (first sign-in).'
    UNION ALL SELECT 'PatientAppOtp', NULL, N'Patient app first sign-in and forgot password: WhatsApp codes and the reset token a right code opens. Only hashes are stored.'
    UNION ALL SELECT 'PatientApiRefreshToken', NULL, N'Refresh tokens of the patient app (api/auth/patient-refresh), stored as SHA-256 hashes only; rotated on every use.';
OPEN dc; FETCH NEXT FROM dc INTO @t, @c, @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @c IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.' + @t) AND minor_id = 0 AND name = 'MS_Description')
            EXEC sys.sp_updateextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t;
        ELSE EXEC sys.sp_addextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t;
    END
    ELSE IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.' + @t) AND minor_id = COLUMNPROPERTY(OBJECT_ID('dbo.' + @t), @c, 'ColumnId') AND name = 'MS_Description')
        EXEC sys.sp_updateextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t, 'COLUMN', @c;
    ELSE EXEC sys.sp_addextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t, 'COLUMN', @c;
    FETCH NEXT FROM dc INTO @t, @c, @v;
END
CLOSE dc; DEALLOCATE dc;
GO

-- Returns the new OtpId, or no row while the patient has had a code in the last minute or five in the last hour.
CREATE OR ALTER PROCEDURE dbo.usp_PatientApp_Otp_Create
    @PatientId INT,
    @OtpHash   CHAR(64),
    @Minutes   INT,
    @Ip        VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;
        IF EXISTS (SELECT 1 FROM dbo.PatientAppOtp WITH (UPDLOCK, HOLDLOCK) WHERE PatientId = @PatientId AND CreatedDate > DATEADD(MINUTE, -1, GETDATE()))
           OR (SELECT COUNT(*) FROM dbo.PatientAppOtp WITH (UPDLOCK, HOLDLOCK) WHERE PatientId = @PatientId AND CreatedDate > DATEADD(HOUR, -1, GETDATE())) >= 5
        BEGIN
            COMMIT;
            RETURN;
        END

        UPDATE dbo.PatientAppOtp SET CancelledAt = GETDATE()
         WHERE PatientId = @PatientId AND UsedAt IS NULL AND CancelledAt IS NULL;

        INSERT dbo.PatientAppOtp (PatientId, OtpHash, ExpiresAt, RequestIp)
        VALUES (@PatientId, @OtpHash, DATEADD(MINUTE, @Minutes, GETDATE()), @Ip);
        DECLARE @Id INT = SCOPE_IDENTITY();
    COMMIT;

    SELECT @Id AS OtpId;
END
GO

-- Returns 1 when the code is right and the reset token is open, else 0.
CREATE OR ALTER PROCEDURE dbo.usp_PatientApp_Otp_Verify
    @PatientId      INT,
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
          FROM dbo.PatientAppOtp WITH (UPDLOCK, HOLDLOCK)
         WHERE PatientId = @PatientId AND UsedAt IS NULL AND CancelledAt IS NULL AND VerifiedAt IS NULL AND ExpiresAt > GETDATE()
         ORDER BY OtpId DESC;

        IF @Id IS NOT NULL
        BEGIN
            IF @Hash = @OtpHash
            BEGIN
                UPDATE dbo.PatientAppOtp
                   SET VerifiedAt = GETDATE(), ResetTokenHash = @ResetTokenHash, ResetExpiresAt = DATEADD(MINUTE, @Minutes, GETDATE())
                 WHERE OtpId = @Id;
                SET @Ok = 1;
            END
            ELSE
                UPDATE dbo.PatientAppOtp
                   SET Attempts = @Tries + 1, CancelledAt = CASE WHEN @Tries + 1 >= 5 THEN GETDATE() END
                 WHERE OtpId = @Id;
        END
    COMMIT;

    SELECT @Ok AS Verified;
END
GO

-- Returns the patient's id when the token was good and the password is set, else no row. A right code proves the
-- mobile number: the patient is verified, the portal login is created if there was none, unlocked, and needs no
-- further change; every refresh token of the patient is revoked.
CREATE OR ALTER PROCEDURE dbo.usp_PatientApp_Otp_Reset
    @ResetTokenHash CHAR(64),
    @PasswordHash   NVARCHAR(255),
    @Salt           NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Id INT, @PatientId INT;

    BEGIN TRANSACTION;
        SELECT @Id = o.OtpId, @PatientId = o.PatientId
          FROM dbo.PatientAppOtp o WITH (UPDLOCK, HOLDLOCK)
          JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId AND ISNULL(p.IsActive, 1) = 1
         WHERE o.ResetTokenHash = @ResetTokenHash AND o.UsedAt IS NULL AND o.CancelledAt IS NULL AND o.ResetExpiresAt > GETDATE();

        IF @Id IS NULL
        BEGIN
            COMMIT;
            RETURN;
        END

        UPDATE dbo.PatientAppOtp SET UsedAt = GETDATE() WHERE OtpId = @Id;
        UPDATE dbo.PatientAppOtp SET CancelledAt = GETDATE() WHERE PatientId = @PatientId AND OtpId <> @Id AND UsedAt IS NULL AND CancelledAt IS NULL;
        UPDATE dbo.PatientMaster
           SET PasswordHash = @PasswordHash, Salt = @Salt, IsLoginGenerated = 1, IsPasswordchanged = 1,
               PortalFailedAttempts = 0, PortalLockoutUntil = NULL,
               App_Verified_Date = CASE WHEN Is_App_Verified = 0 THEN GETDATE() ELSE App_Verified_Date END, Is_App_Verified = 1
         WHERE PatientId = @PatientId;
        UPDATE dbo.PatientApiRefreshToken SET Revoked_On = SYSDATETIME(), Revoked_Reason = 'Password reset by WhatsApp code'
         WHERE Patient_ID = @PatientId AND Revoked_On IS NULL;
    COMMIT;

    SELECT @PatientId AS PatientId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PatientApp_RefreshToken_Create
    @TokenHash CHAR(64), @FamilyId UNIQUEIDENTIFIER, @PatientId INT, @ExpiresOn DATETIME2(0),
    @DeviceId NVARCHAR(100) = NULL, @CreatedIp NVARCHAR(64) = NULL, @UserAgent NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.PatientApiRefreshToken (Token_Hash, Family_ID, Patient_ID, Expires_On, Device_Id, Created_IP, User_Agent)
    VALUES (@TokenHash, @FamilyId, @PatientId, @ExpiresOn, LEFT(@DeviceId, 100), @CreatedIp, LEFT(@UserAgent, 300));
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PatientApp_RefreshToken_RevokeFamily
    @FamilyId UNIQUEIDENTIFIER, @Reason NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PatientApiRefreshToken SET Revoked_On = SYSDATETIME(), Revoked_Reason = @Reason
     WHERE Family_ID = @FamilyId AND Revoked_On IS NULL;
END
GO

-- Exchanges a refresh token for a new one in the same family.
-- Result: Status = OK | INVALID | EXPIRED | REUSED | REVOKED | INACTIVE (| UNVERIFIED), with Patient_ID.
-- A token presented a second time (already used) means it was copied: the whole family is revoked.
CREATE OR ALTER PROCEDURE dbo.usp_PatientApp_RefreshToken_Rotate
    @TokenHash CHAR(64), @NewTokenHash CHAR(64), @NewExpiresOn DATETIME2(0),
    @DeviceId NVARCHAR(100) = NULL, @CreatedIp NVARCHAR(64) = NULL, @UserAgent NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;

    DECLARE @id BIGINT, @family UNIQUEIDENTIFIER, @patientId INT, @expires DATETIME2(0), @used DATETIME2(0), @revoked DATETIME2(0);
    SELECT @id = Token_ID, @family = Family_ID, @patientId = Patient_ID, @expires = Expires_On, @used = Used_On, @revoked = Revoked_On
      FROM dbo.PatientApiRefreshToken WITH (UPDLOCK, HOLDLOCK)
     WHERE Token_Hash = @TokenHash;

    IF @id IS NULL
    BEGIN COMMIT; SELECT 'INVALID' AS Status; RETURN; END

    IF @used IS NOT NULL
    BEGIN
        UPDATE dbo.PatientApiRefreshToken SET Revoked_On = SYSDATETIME(), Revoked_Reason = 'Refresh token reused'
         WHERE Family_ID = @family AND Revoked_On IS NULL;
        COMMIT; SELECT 'REUSED' AS Status, @patientId AS Patient_ID; RETURN;
    END
    IF @revoked IS NOT NULL BEGIN COMMIT; SELECT 'REVOKED' AS Status, @patientId AS Patient_ID; RETURN; END
    IF @expires <= SYSDATETIME() BEGIN COMMIT; SELECT 'EXPIRED' AS Status, @patientId AS Patient_ID; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM dbo.PatientMaster
                    WHERE PatientId = @patientId AND ISNULL(IsActive, 1) = 1 AND ISNULL(IsLoginGenerated, 0) = 1 AND Is_App_Verified = 1)
    BEGIN
        UPDATE dbo.PatientApiRefreshToken SET Revoked_On = SYSDATETIME(), Revoked_Reason = 'Patient inactive or login removed'
         WHERE Family_ID = @family AND Revoked_On IS NULL;
        COMMIT; SELECT 'INACTIVE' AS Status, @patientId AS Patient_ID; RETURN;
    END

    UPDATE dbo.PatientApiRefreshToken SET Used_On = SYSDATETIME() WHERE Token_ID = @id;
    INSERT dbo.PatientApiRefreshToken (Token_Hash, Family_ID, Patient_ID, Expires_On, Device_Id, Created_IP, User_Agent)
    VALUES (@NewTokenHash, @family, @patientId, @NewExpiresOn, LEFT(@DeviceId, 100), @CreatedIp, LEFT(@UserAgent, 300));
    COMMIT;

    SELECT 'OK' AS Status, @patientId AS Patient_ID;
END
GO
PRINT 'Script 2486 applied: patient app first sign-in by WhatsApp code, forgot password and refresh tokens.';
GO
