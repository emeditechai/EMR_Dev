-- ============================================================================
-- Migration: 2174_authorization_reset_user_exceptions.sql
-- Description:
--   Settings > Security > User Permissions > "Reset to role": removes every exception of one user
--   (all branches, menus, pages and actions), so the user gets exactly what their roles give.
--     dbo.usp_Auth_Admin_ResetUserGrants
--       - same safeguards as Save: company check, "someone else saved meanwhile" (version),
--         and the saver must still be able to open the Security screen afterwards (self-lockout guard);
--       - every removed row goes to PermissionAuditLog ("Grant removed") and the user's
--         Permission_Version moves on (usp_Auth_UserPermission_Clear), so it applies on their next request.
--   Run after 2173.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_ResetUserGrants
    @User_ID         INT,
    @CompanyId       INT,
    @ExpectedVersion INT,
    @ChangedBy       INT,
    @ActorBranchId   INT,
    @ActorRoleId     INT = NULL,
    @GuardPageCode   NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @User_ID AND ISNULL(CompanyId, @CompanyId) = @CompanyId)
    BEGIN RAISERROR('That user belongs to another company.', 16, 1); RETURN; END

    BEGIN TRANSACTION;

    DECLARE @Current INT = (SELECT ISNULL(MAX(Log_ID), 0) FROM dbo.PermissionAuditLog WITH (UPDLOCK, HOLDLOCK) WHERE Entity = 'USER' AND Target_ID = @User_ID);
    IF @Current <> @ExpectedVersion
    BEGIN
        DECLARE @who NVARCHAR(150), @when VARCHAR(30);
        SELECT TOP 1 @who = ISNULL(NULLIF(u.FullName, ''), u.Username), @when = CONVERT(VARCHAR(30), l.Changed_On, 106) + ' ' + CONVERT(VARCHAR(5), l.Changed_On, 108)
        FROM dbo.PermissionAuditLog l LEFT JOIN dbo.Users u ON u.Id = l.Changed_By
        WHERE l.Entity = 'USER' AND l.Target_ID = @User_ID ORDER BY l.Log_ID DESC;
        ROLLBACK TRANSACTION;
        RAISERROR('CONCURRENT|%s saved changes for this user on %s. Reload to review what changed, then reset again.', 16, 1, @who, @when);
        RETURN;
    END

    DECLARE @Changes INT = 0, @m INT, @p INT, @c INT, @b INT;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT Menu_ID, Page_ID, Control_ID, Branch_ID FROM dbo.UserPermission WHERE User_ID = @User_ID;
    OPEN cur; FETCH NEXT FROM cur INTO @m, @p, @c, @b;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Auth_UserPermission_Clear @User_ID = @User_ID, @Menu_ID = @m, @Page_ID = @p, @Control_ID = @c, @Branch_ID = @b, @ChangedBy = @ChangedBy;
        SET @Changes += 1;
        FETCH NEXT FROM cur INTO @m, @p, @c, @b;
    END
    CLOSE cur; DEALLOCATE cur;

    EXEC dbo.usp_Auth_Admin_AssertCanStillOpen @UserId = @ChangedBy, @BranchId = @ActorBranchId, @RoleId = @ActorRoleId, @GuardPageCode = @GuardPageCode;
    COMMIT TRANSACTION;

    SELECT 'OK' AS Status, @Changes AS Changes, 1 AS AffectedUsers,
           (SELECT ISNULL(MAX(Log_ID), 0) FROM dbo.PermissionAuditLog WHERE Entity = 'USER' AND Target_ID = @User_ID) AS Version;
    SELECT @User_ID AS UserId;
END;
GO
PRINT 'Script 2174 applied: User Permissions > Reset to role ready.';
GO
