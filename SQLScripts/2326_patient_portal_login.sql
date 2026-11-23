-- 2326 Patient Portal login by Patient ID
--
-- * Staff create or reset a patient's portal login from Master > Patient Master (new control MASTER.OPD:PORTAL_LOGIN,
--   granted to no role here): a random password, e-mailed / WhatsApp'd to the patient, changed at first sign-in.
-- * The portal signs in by Patient ID only; 5 wrong passwords lock the portal account for 10 minutes
--   (PortalFailedAttempts / PortalLockoutUntil). A staff reset also unlocks it.
-- Data goes EMR.Web -> EMR.Api (api/Patients/{id}/portal-login) -> usp_PatientPortal_SetLogin; the portal sign-in
-- (EMR.Web PatientPortalController) uses usp_PatientPortal_LoginFailure / _LoginSuccess.

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF COL_LENGTH('dbo.PatientMaster', 'PortalFailedAttempts') IS NULL
    ALTER TABLE dbo.PatientMaster ADD PortalFailedAttempts INT NOT NULL CONSTRAINT DF_PatientMaster_PortalFailedAttempts DEFAULT 0;
GO
IF COL_LENGTH('dbo.PatientMaster', 'PortalLockoutUntil') IS NULL
    ALTER TABLE dbo.PatientMaster ADD PortalLockoutUntil DATETIME NULL;
GO

-- A new portal password (hash made by EMR.Web): the login is (re)created, must be changed at first sign-in, unlocked.
CREATE OR ALTER PROCEDURE dbo.usp_PatientPortal_SetLogin
    @PatientId    INT,
    @PasswordHash NVARCHAR(255),
    @Salt         NVARCHAR(255),
    @CompanyId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.PatientMaster
       SET IsLoginGenerated = 1, PasswordHash = @PasswordHash, Salt = @Salt, IsPasswordchanged = 0,
           PortalFailedAttempts = 0, PortalLockoutUntil = NULL
     WHERE PatientId = @PatientId AND ISNULL(IsActive, 1) = 1
       AND (@CompanyId IS NULL OR CompanyId IS NULL OR CompanyId = @CompanyId);

    IF @@ROWCOUNT = 0 RETURN;

    SELECT PatientId, PatientCode, LTRIM(RTRIM(ISNULL(FirstName, '') + ' ' + ISNULL(LastName, ''))) AS FullName,
           NULLIF(LTRIM(RTRIM(EmailId)), '') AS EmailId, NULLIF(LTRIM(RTRIM(PhoneNumber)), '') AS PhoneNumber
    FROM dbo.PatientMaster WHERE PatientId = @PatientId;
END
GO

-- A wrong portal password: counts it; the 5th in a row locks the portal account for 10 minutes.
CREATE OR ALTER PROCEDURE dbo.usp_PatientPortal_LoginFailure
    @PatientId   INT,
    @MaxAttempts INT = 5,
    @LockMinutes INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.PatientMaster
       SET PortalFailedAttempts = CASE WHEN PortalLockoutUntil IS NOT NULL AND PortalLockoutUntil <= GETDATE() THEN 1
                                       ELSE PortalFailedAttempts + 1 END,
           PortalLockoutUntil   = CASE WHEN PortalLockoutUntil IS NOT NULL AND PortalLockoutUntil <= GETDATE() THEN NULL
                                       ELSE PortalLockoutUntil END
     WHERE PatientId = @PatientId;

    UPDATE dbo.PatientMaster
       SET PortalLockoutUntil = DATEADD(MINUTE, @LockMinutes, GETDATE())
     WHERE PatientId = @PatientId AND PortalFailedAttempts >= @MaxAttempts AND PortalLockoutUntil IS NULL;

    SELECT CASE WHEN PortalLockoutUntil > GETDATE() THEN PortalLockoutUntil END AS LockedUntil,
           CASE WHEN @MaxAttempts - PortalFailedAttempts < 0 THEN 0 ELSE @MaxAttempts - PortalFailedAttempts END AS AttemptsLeft
    FROM dbo.PatientMaster WHERE PatientId = @PatientId;
END
GO

-- A correct portal password: the wrong-password count starts again and the sign-in time is kept.
CREATE OR ALTER PROCEDURE dbo.usp_PatientPortal_LoginSuccess
    @PatientId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PatientMaster
       SET PortalFailedAttempts = 0, PortalLockoutUntil = NULL, Lastlogin = GETDATE()
     WHERE PatientId = @PatientId;
END
GO

-- ── Master > Patient Master: "Create / reset portal login" control and its endpoints (no role grants) ─────────
DECLARE @co INT, @page INT, @ctl INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @page = (SELECT TOP 1 Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.OPD' AND CompanyId = @co);
    IF @page IS NOT NULL
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'PORTAL_LOGIN',
             @Title = N'Create / reset patient portal login', @Sort_Order = 60, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
             @Controller = N'OPD', @Action = N'PortalLogin', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'API', @Http_Method = 'POST',
             @Controller = N'Patients', @Action = N'SetPortalLogin', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2326 applied: Patient Portal login by Patient ID (staff create / reset, lockout).';
GO
