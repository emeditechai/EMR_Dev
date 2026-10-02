-- ============================================================================
-- Migration: 2187_user_branch_last_login.sql
-- Description: Sign-in remembers the user's last branch and, per branch, the last role.
--   * UserBranchLastLogin - one row per user and branch: when the user last worked in it (sign-in or Switch Branch)
--     and the role last used there. Kept apart from UserBranches on purpose: User Master and the doctor login sync
--     re-create a user's UserBranches rows on every save, which would lose this.
--     The Select Branch step pre-selects the branch with the latest LastLoginDate; the Select Role step pre-selects
--     LastRoleName of the chosen branch. A user with no row (first sign-in) sees the steps as before. A branch or
--     role the user no longer has is simply not pre-selected.
--   * usp_UserBranchLastLogin_Save - stamps the branch (and the role, when given).
--   * Backfill from the sign-in audit trail (AuditLogs: SelectBranch / SwitchBranch / SelectRole), so users who
--     signed in before this change get their defaults on the next sign-in.
--   Run after 2186.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.UserBranchLastLogin', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserBranchLastLogin
    (
        UserId        INT            NOT NULL,
        BranchId      INT            NOT NULL,
        LastRoleName  NVARCHAR(200)  NULL,
        LastLoginDate DATETIME2      NOT NULL CONSTRAINT DF_UserBranchLastLogin_LastLoginDate DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_UserBranchLastLogin PRIMARY KEY (UserId, BranchId),
        CONSTRAINT FK_UserBranchLastLogin_Users  FOREIGN KEY (UserId)   REFERENCES dbo.Users (Id)              ON DELETE CASCADE,
        CONSTRAINT FK_UserBranchLastLogin_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster (BranchID) ON DELETE CASCADE
    );
END
GO

-- @RoleName NULL keeps the role already remembered for the branch (the branch is chosen before the role).
CREATE OR ALTER PROCEDURE dbo.usp_UserBranchLastLogin_Save
    @UserId   INT,
    @BranchId INT,
    @RoleName NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @RoleName = NULLIF(LTRIM(RTRIM(@RoleName)), N'');

    UPDATE dbo.UserBranchLastLogin
    SET LastLoginDate = SYSDATETIME(),
        LastRoleName  = COALESCE(@RoleName, LastRoleName)
    WHERE UserId = @UserId AND BranchId = @BranchId;

    IF @@ROWCOUNT = 0
        INSERT INTO dbo.UserBranchLastLogin (UserId, BranchId, LastRoleName, LastLoginDate)
        SELECT @UserId, @BranchId, @RoleName, SYSDATETIME()
        WHERE EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId)
          AND EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId);
END
GO

-- Backfill from the sign-in audit trail (only users / branches that still exist; rows already present are kept).
;WITH Visits AS
(
    SELECT a.UserId, a.BranchId, MAX(a.CreatedDate) AS LastLoginDate
    FROM dbo.AuditLogs a
    WHERE a.UserId IS NOT NULL AND a.BranchId IS NOT NULL
      AND ((a.EventType = 'AuthSuccess' AND a.ActionName = 'SelectBranch') OR (a.EventType = 'Auth' AND a.ActionName IN ('SwitchBranch', 'SelectRole')))
    GROUP BY a.UserId, a.BranchId
),
Roles AS
(
    SELECT a.UserId, a.BranchId, LTRIM(RTRIM(SUBSTRING(a.Description, LEN('Active role set to:') + 1, 200))) AS RoleName,
           ROW_NUMBER() OVER (PARTITION BY a.UserId, a.BranchId ORDER BY a.CreatedDate DESC, a.Id DESC) AS rn
    FROM dbo.AuditLogs a
    WHERE a.EventType = 'Auth' AND a.ActionName = 'SelectRole' AND a.Description LIKE 'Active role set to:%'
      AND a.UserId IS NOT NULL AND a.BranchId IS NOT NULL
)
INSERT INTO dbo.UserBranchLastLogin (UserId, BranchId, LastRoleName, LastLoginDate)
SELECT v.UserId, v.BranchId, NULLIF(r.RoleName, N''), v.LastLoginDate
FROM Visits v
LEFT JOIN Roles r ON r.UserId = v.UserId AND r.BranchId = v.BranchId AND r.rn = 1
WHERE EXISTS (SELECT 1 FROM dbo.Users u WHERE u.Id = v.UserId)
  AND EXISTS (SELECT 1 FROM dbo.Branchmaster b WHERE b.BranchID = v.BranchId)
  AND NOT EXISTS (SELECT 1 FROM dbo.UserBranchLastLogin x WHERE x.UserId = v.UserId AND x.BranchId = v.BranchId);
GO
