-- ============================================================================================================
-- Migration: 2383_login_failure_whatsapp_alert.sql
-- Login screen: WhatsApp security alert to the user after repeated wrong passwords on their account.
--   1. Hospital Settings > OPD Configuration: "Login Alert After Wrong Attempts" (LoginAlertCount, per branch,
--      default 0 = no alert). The lowest value set on the user's branches applies (as Login Retry Count, 2320).
--   2. usp_Auth_Login_RecordFailure (2320): every wrong password is now counted, also when the lock is off (Login Retry
--      Count 0), so the alert works on its own. The lock itself is unchanged: only when Login Retry Count > 0.
--   3. usp_Auth_Login_FailureAlert: after a wrong password, says whether to alert now and to whom - when the count
--      reaches the alert value, and once more when the account gets locked later. The web sign-in sends the WhatsApp
--      message (time, public IP, browser) through the branch's WhatsApp configuration.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'LoginAlertCount') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD LoginAlertCount INT NOT NULL
        CONSTRAINT DF_HospitalSettings_LoginAlertCount DEFAULT (0);
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_HospitalSettings_LoginAlertCount')
    ALTER TABLE dbo.HospitalSettings ADD CONSTRAINT CK_HospitalSettings_LoginAlertCount CHECK (LoginAlertCount BETWEEN 0 AND 20);
GO

-- the alert value of a user: the lowest one above 0 on the user's branches (a user without branches: the HO branch's)
CREATE OR ALTER FUNCTION dbo.fn_Auth_LoginAlertCount (@UserId INT)
RETURNS INT
AS
BEGIN
    DECLARE @n INT;
    ;WITH s AS (
        SELECT hs.BranchId, hs.LoginAlertCount,
               ROW_NUMBER() OVER (PARTITION BY hs.BranchId ORDER BY hs.IsActive DESC, hs.Id DESC) AS rn
        FROM dbo.HospitalSettings hs)
    SELECT @n = MIN(s.LoginAlertCount)
    FROM s
    WHERE s.rn = 1 AND s.LoginAlertCount > 0
      AND s.BranchId IN (SELECT ub.BranchID FROM dbo.UserBranches ub WHERE ub.UserId = @UserId AND ub.IsActive = 1);

    IF @n IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = @UserId AND ub.IsActive = 1)
    BEGIN
        ;WITH s AS (
            SELECT hs.BranchId, hs.LoginAlertCount,
                   ROW_NUMBER() OVER (PARTITION BY hs.BranchId ORDER BY hs.IsActive DESC, hs.Id DESC) AS rn
            FROM dbo.HospitalSettings hs)
        SELECT @n = MIN(s.LoginAlertCount)
        FROM s INNER JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId AND b.IsHOBranch = 1
        WHERE s.rn = 1 AND s.LoginAlertCount > 0;
    END
    RETURN ISNULL(@n, 0);
END
GO

-- Wrong password (2320 + 2383): always counted; the account locks only when Login Retry Count > 0.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Login_RecordFailure
    @UserId INT, @MaxAttempts INT = NULL, @LockMinutes INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Retry INT = dbo.fn_Auth_LoginRetryCount(@UserId);

    UPDATE dbo.Users
    SET FailedLoginAttempts = ISNULL(FailedLoginAttempts, 0) + 1,
        Lockout_Until = CASE WHEN @Retry > 0 AND ISNULL(FailedLoginAttempts, 0) + 1 >= @Retry
                             THEN DATEADD(MINUTE, 10, SYSDATETIME()) ELSE Lockout_Until END
    WHERE Id = @UserId;

    SELECT FailedLoginAttempts, Lockout_Until, @Retry AS RetryCount FROM dbo.Users WHERE Id = @UserId;
END
GO

-- After a wrong password has been counted: alert now? (the count reached the alert value, or the account was just
-- locked after it). Returns one row: ShouldAlert, the count, lock time, the user's name / mobile and the branch whose
-- WhatsApp configuration sends it.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Login_FailureAlert
    @UserId INT, @JustLocked BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AlertAt INT = dbo.fn_Auth_LoginAlertCount(@UserId);
    SELECT CAST(CASE WHEN @AlertAt > 0 AND (ISNULL(u.FailedLoginAttempts, 0) = @AlertAt
                                            OR (@JustLocked = 1 AND ISNULL(u.FailedLoginAttempts, 0) > @AlertAt)) THEN 1 ELSE 0 END AS BIT) AS ShouldAlert,
           ISNULL(u.FailedLoginAttempts, 0) AS FailedAttempts,
           u.Lockout_Until AS LockedUntil,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UserName,
           u.Email,
           COALESCE(NULLIF(LTRIM(RTRIM(u.PhoneNumber)), ''), NULLIF(LTRIM(RTRIM(u.Phone)), '')) AS Mobile,
           COALESCE((SELECT TOP 1 ub.BranchID FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.IsActive = 1 ORDER BY ub.BranchID),
                    (SELECT TOP 1 b.BranchID FROM dbo.Branchmaster b WHERE b.IsHOBranch = 1 ORDER BY b.BranchID)) AS BranchId
    FROM dbo.Users u
    WHERE u.Id = @UserId;
END
GO

PRINT 'Script 2383 applied: WhatsApp alert after wrong passwords (Hospital Settings > Login Alert After Wrong Attempts).';
GO
