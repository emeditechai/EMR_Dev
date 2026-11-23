-- ============================================================================
-- DataCleanup / 09_clear_users.sql
-- Remove the users of a branch (User Master), with everything that belongs only to them.
-- ----------------------------------------------------------------------------
--   SUPER ADMIN: a user with Users.IsSuperAdmin = 1 is NEVER removed and never loses a branch link.
--
--   Users of the branch (@BranchId, by User Master > branch links):
--     * linked to this branch only      -> removed completely
--     * also linked to another branch   -> only the link to this branch is removed (with the roles / permissions given
--                                          for this branch); the user keeps working in the other branches.
--                                          @RemoveMultiBranchUsers = 1 removes these users completely as well.
--   Removed with a user: roles, branch links, permissions, sessions (API refresh tokens), last-login rows, bell
--   notifications, password-reset codes / links, approved phlebotomist phones and areas, report-approval and
--   approval-matrix approver entries, audit-notification recipients, report signatories, housekeeping staff record.
--   Records that only NAME the user stay and lose the name: audit entries, bill phlebotomist, discount approver,
--   doctor login link, marketing-executive login, "reports to" of other users.
--   KEPT (listed, with the reason; only the link to this branch is removed): a user who still has phlebotomist field
--   records (home-collection visits, attendance, cash ledger, sample hand-overs - clear LAB transactions first with 07),
--   or pre-printed barcodes assigned to them (re-assign them first).
--   Not touched: roles themselves, permissions of roles, the branch, any master or transaction.
--   Stand-alone: does not need 00_install_cleanup_procedures.sql.
--
--   HOW TO RUN
--     1. Select the database. Set @BranchId (Branch Master > BranchID). Run as it is (@Execute = 0): a DRY RUN -
--        everything is done and then rolled back; the result grids list each table and the users.
--     2. Take a FULL database backup.
--     3. Set @Execute = 1 and @Confirm = 'CLEAR <database name>' and run again.
--   Any error rolls the whole run back: either everything listed is done, or nothing is.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @BranchId               INT = NULL;   -- required: the branch whose users are removed
DECLARE @RemoveMultiBranchUsers BIT = 0;      -- 1 = also remove users who are linked to other branches as well

DECLARE @Execute BIT           = 0;      -- 0 = dry run (nothing is changed)   1 = do it for real
DECLARE @Confirm NVARCHAR(200) = N'';    -- with @Execute = 1: 'CLEAR ' + the database name

-- ── checks ──────────────────────────────────────────────────────────────────
IF @BranchId IS NULL THROW 50300, 'Set @BranchId (Branch Master > BranchID). Nothing was changed.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId) THROW 50301, 'The branch does not exist. Nothing was changed.', 1;
IF ISNULL(@Execute, 0) = 1 AND ISNULL(@Confirm, N'') <> N'CLEAR ' + DB_NAME()
    THROW 50302, 'To change for real set @Confirm to the exact text: CLEAR <database name>. Nothing was changed.', 1;

-- users of the branch (Super Admin never)
CREATE TABLE #U (UserId INT PRIMARY KEY, OnlyThisBranch BIT NOT NULL);
INSERT INTO #U (UserId, OnlyThisBranch)
SELECT u.Id,
       CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.UserBranches o WHERE o.UserId = u.Id AND o.BranchID <> @BranchId AND ISNULL(o.IsActive, 1) = 1) THEN 0 ELSE 1 END AS BIT)
FROM dbo.Users u
WHERE ISNULL(u.IsSuperAdmin, 0) = 0
  AND EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId);

-- remove completely / only the link to this branch
CREATE TABLE #Del (UserId INT PRIMARY KEY);
CREATE TABLE #Unlink (UserId INT PRIMARY KEY);
INSERT INTO #Del SELECT UserId FROM #U WHERE OnlyThisBranch = 1 OR @RemoveMultiBranchUsers = 1;
INSERT INTO #Unlink SELECT UserId FROM #U WHERE UserId NOT IN (SELECT UserId FROM #Del);

-- users whose phlebotomist field records are still there are kept (those records are transactions)
CREATE TABLE #Keep (UserId INT PRIMARY KEY, Reason NVARCHAR(200));
INSERT INTO #Keep (UserId, Reason)
SELECT d.UserId,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.LabPhleboBarcodePool x WHERE x.PhlebotomistId = d.UserId)
                 AND NOT EXISTS (SELECT 1 FROM dbo.PhleboAttendance x WHERE x.UserId = d.UserId)
                 AND NOT EXISTS (SELECT 1 FROM dbo.LabHomeVisit x WHERE x.PhlebotomistId = d.UserId)
            THEN N'pre-printed barcodes are assigned to this phlebotomist (LAB > Phlebotomist Barcode Assignment) - re-assign them first'
            ELSE N'phlebotomist field records still exist (home visits / attendance / cash ledger / hand-overs) - clear LAB transactions (07) first' END
FROM #Del d
WHERE EXISTS (SELECT 1 FROM dbo.PhleboAttendance x WHERE x.UserId = d.UserId)
   OR EXISTS (SELECT 1 FROM dbo.PhleboCashLedger x WHERE x.UserId = d.UserId)
   OR EXISTS (SELECT 1 FROM dbo.PhleboHandover x WHERE x.PhlebotomistId = d.UserId)
   OR EXISTS (SELECT 1 FROM dbo.LabHomeVisit x WHERE x.PhlebotomistId = d.UserId)           -- the visit must keep its phlebotomist
   OR EXISTS (SELECT 1 FROM dbo.LabPhleboBarcodePool x WHERE x.PhlebotomistId = d.UserId);  -- barcode stock assigned to them
DELETE FROM #Del WHERE UserId IN (SELECT UserId FROM #Keep);
-- a kept user still loses the link to this branch
INSERT INTO #Unlink SELECT UserId FROM #Keep WHERE UserId NOT IN (SELECT UserId FROM #Unlink);

-- the Super Admin can never be in the lists (checked again, belt and braces)
IF EXISTS (SELECT 1 FROM dbo.Users u WHERE ISNULL(u.IsSuperAdmin, 0) = 1 AND (u.Id IN (SELECT UserId FROM #Del) OR u.Id IN (SELECT UserId FROM #Unlink)))
    THROW 50303, 'A Super Admin (IsSuperAdmin = 1) would be changed - stopped. Nothing was changed.', 1;

PRINT N'=== Remove the users of a branch ===';
PRINT N'Database : ' + DB_NAME() + N' on ' + @@SERVERNAME;
DECLARE @BranchText NVARCHAR(300) = (SELECT BranchName + N' (' + BranchCode + N')' FROM dbo.Branchmaster WHERE BranchID = @BranchId);
PRINT N'Branch   : ' + @BranchText;
PRINT N'Mode     : ' + CASE WHEN @Execute = 1 THEN N'EXECUTE - changes will be committed' ELSE N'DRY RUN - every change is rolled back at the end' END;

DECLARE @Report TABLE (Step INT IDENTITY(1, 1), Area NVARCHAR(40), TableName NVARCHAR(128), Action VARCHAR(10), RowsAffected INT, Note NVARCHAR(300));
DECLARE @Users TABLE (UserId INT, Username NVARCHAR(200), FullName NVARCHAR(300), Outcome NVARCHAR(100), Note NVARCHAR(300));   -- survives a rollback
INSERT INTO @Users
SELECT u.Id, u.Username, u.FullName,
       CASE WHEN u.Id IN (SELECT UserId FROM #Del) THEN N'removed'
            WHEN u.Id IN (SELECT UserId FROM #Keep) THEN N'kept - branch link removed'
            ELSE N'kept - branch link removed (other branches)' END,
       (SELECT Reason FROM #Keep k WHERE k.UserId = u.Id)
FROM dbo.Users u WHERE u.Id IN (SELECT UserId FROM #Del) OR u.Id IN (SELECT UserId FROM #Unlink);
INSERT INTO @Users
SELECT u.Id, u.Username, u.FullName, N'kept - Super Admin', N'IsSuperAdmin = 1 is never removed'
FROM dbo.Users u WHERE ISNULL(u.IsSuperAdmin, 0) = 1 AND EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId);

DECLARE @n INT, @A NVARCHAR(40);

BEGIN TRY
    BEGIN TRANSACTION;

    -- ── 1. users linked to other branches as well: only this branch goes ──────
    SET @A = N'Branch link removed';
    DELETE FROM dbo.UserPermission WHERE Branch_ID = @BranchId AND User_ID IN (SELECT UserId FROM #Unlink);   SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserPermission', 'DELETE', @n, 'user permissions given for this branch');
    DELETE FROM dbo.Userroles WHERE Branch_ID = @BranchId AND UserId IN (SELECT UserId FROM #Unlink);        SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'Userroles', 'DELETE', @n, 'roles given for this branch only');
    DELETE FROM dbo.UserBranchLastLogin WHERE BranchId = @BranchId AND UserId IN (SELECT UserId FROM #Unlink);
    DELETE FROM dbo.UserBranches WHERE BranchID = @BranchId AND UserId IN (SELECT UserId FROM #Unlink);       SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserBranches', 'DELETE', @n, 'links to this branch');

    -- ── 2. records that only name a removed user keep the record, lose the name ─
    SET @A = N'Kept without the user';
    UPDATE dbo.AuditLogs SET UserId = NULL WHERE UserId IN (SELECT UserId FROM #Del);                          SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'AuditLogs', 'UPDATE', @n, 'audit entries kept without the user');
    UPDATE dbo.LabOrder SET PhlebotomistId = NULL WHERE PhlebotomistId IN (SELECT UserId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabOrder', 'UPDATE', @n, 'phlebotomist removed from bills');
    UPDATE dbo.PaymentHeader SET DiscountApprovedBy = NULL WHERE DiscountApprovedBy IN (SELECT UserId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'PaymentHeader', 'UPDATE', @n, 'discount approver removed from bills');
    UPDATE dbo.DoctorMaster SET LinkedUserId = NULL WHERE LinkedUserId IN (SELECT UserId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorMaster', 'UPDATE', @n, 'doctors'' login link removed');
    UPDATE dbo.MarketingExecutive SET LoginUserId = NULL WHERE LoginUserId IN (SELECT UserId FROM #Del);      SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'MarketingExecutive', 'UPDATE', @n, 'marketing executives kept without their login');
    UPDATE dbo.Users SET ReportsToUserId = NULL WHERE ReportsToUserId IN (SELECT UserId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'Users', 'UPDATE', @n, '"reports to" cleared on other users');
    UPDATE dbo.HKStaffMaster SET Supervisor_ID = NULL WHERE Supervisor_ID IN (SELECT UserId FROM #Del);

    -- ── 3. what belongs only to the removed users ────────────────────────────
    SET @A = N'Users removed';
    DELETE FROM dbo.HKStaffMaster WHERE Staff_ID IN (SELECT UserId FROM #Del);                                SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'HKStaffMaster', 'DELETE', @n, 'housekeeping staff records');
    DELETE FROM dbo.LabApprovalFlowApprover WHERE UserId IN (SELECT UserId FROM #Del);                        SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabApprovalFlowApprover', 'DELETE', @n, 'report approvers');
    DELETE FROM dbo.LabReportDefaultSignatory WHERE UserId IN (SELECT UserId FROM #Del);                      SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabReportDefaultSignatory', 'DELETE', @n, 'report signatories');
    DELETE FROM dbo.ApprovalMatrixApprover WHERE UserId IN (SELECT UserId FROM #Del);                         SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'ApprovalMatrixApprover', 'DELETE', @n, 'approval matrix approvers');
    DELETE FROM dbo.AuditNotifyRecipient WHERE UserId IN (SELECT UserId FROM #Del);                           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'AuditNotifyRecipient', 'DELETE', @n, 'audit-notification recipients');
    DELETE FROM dbo.UserNotification WHERE UserId IN (SELECT UserId FROM #Del);                               SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserNotification', 'DELETE', @n, 'bell notifications');
    DELETE FROM dbo.ApiRefreshToken WHERE User_ID IN (SELECT UserId FROM #Del);                               SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'ApiRefreshToken', 'DELETE', @n, 'sessions');
    DELETE FROM dbo.UserPasswordResetOtp WHERE UserId IN (SELECT UserId FROM #Del);
    DELETE FROM dbo.UserPasswordResetToken WHERE UserId IN (SELECT UserId FROM #Del);                         SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserPasswordReset*', 'DELETE', @n, 'password reset codes / links');
    DELETE FROM dbo.PhleboLocationPoint WHERE UserId IN (SELECT UserId FROM #Del);
    DELETE FROM dbo.MarketingLocationPoint WHERE UserId IN (SELECT UserId FROM #Del);
    DELETE FROM dbo.PhleboDevice WHERE UserId IN (SELECT UserId FROM #Del);                                   SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'PhleboDevice', 'DELETE', @n, 'approved phones');
    DELETE FROM dbo.UserPhleboArea WHERE UserId IN (SELECT UserId FROM #Del);                                 SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserPhleboArea', 'DELETE', @n, 'phlebotomist areas');
    DELETE FROM dbo.UserBranchLastLogin WHERE UserId IN (SELECT UserId FROM #Del);
    DELETE FROM dbo.UserPermission WHERE User_ID IN (SELECT UserId FROM #Del);                                SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserPermission', 'DELETE', @n, 'user permissions');
    DELETE FROM dbo.Userroles WHERE UserId IN (SELECT UserId FROM #Del);                                      SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'Userroles', 'DELETE', @n, 'roles');
    DELETE FROM dbo.UserBranches WHERE UserId IN (SELECT UserId FROM #Del);                                   SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserBranches', 'DELETE', @n, 'branch links');
    DELETE FROM dbo.Users WHERE Id IN (SELECT UserId FROM #Del) AND ISNULL(IsSuperAdmin, 0) = 0;              SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'Users', 'DELETE', @n, 'users removed (listed below)');

    UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;   -- everyone re-reads permissions on next request

    IF @Execute = 1 COMMIT TRANSACTION; ELSE ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT N'*** ERROR - everything was rolled back, nothing changed ***';
    PRINT N'Message : ' + ERROR_MESSAGE();
    PRINT N'Line    : ' + CAST(ERROR_LINE() AS NVARCHAR(10));
    THROW;
END CATCH

SELECT Step, Area, TableName AS [Table], Action, RowsAffected AS [Rows], Note FROM @Report WHERE RowsAffected > 0 OR Action = 'DELETE' ORDER BY Step;
SELECT UserId, Username, FullName,
       CASE WHEN @Execute = 1 THEN Outcome ELSE N'would be ' + Outcome END AS [Outcome], Note
FROM @Users ORDER BY CASE WHEN Outcome LIKE N'kept - Super%' THEN 0 WHEN Outcome = N'removed' THEN 1 ELSE 2 END, Username;
PRINT CASE WHEN @Execute = 1 THEN N'=== COMMITTED ===' ELSE N'=== DRY RUN: nothing was changed. The counts show what an executed run would do. ===' END;
