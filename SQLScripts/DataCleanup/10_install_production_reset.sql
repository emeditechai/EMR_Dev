-- ============================================================================
-- DataCleanup / 10_install_production_reset.sql
-- ----------------------------------------------------------------------------
-- Adds the procedures used by 11_production_reset.sql (the one consolidated clean-up for production go-live).
-- Run 00_install_cleanup_procedures.sql first (current copy), then this file. Both are removed again by
-- 99_remove_cleanup_procedures.sql.
--
--   cleanup.usp_ClearCorporates     Corporate (Company) Master with its corporate LAB rate lists, hospital rates,
--                                    commission overrides; only corporates with no bill / invoice / IPD payer left.
--   cleanup.usp_ClearUsersScoped    Users of the company / branch, with everything that belongs only to them.
--                                    The Super Admin (IsSuperAdmin = 1) is never removed: only his own data goes.
--   cleanup.usp_RemoveBranches      Every branch except the head office (company scope), or the one branch chosen
--                                    (never the head office), with all its set-up. The head office is always kept.
--   cleanup.usp_ProductionReset     The runner: everything in one transaction, dry run by default.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('cleanup.usp_Run', 'P') IS NULL
    THROW 51000, 'Run 00_install_cleanup_procedures.sql first.', 1;
GO

-- ============================================================================
-- Corporate (Company) Master and its rate lists - only corporates nothing refers to any more
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearCorporates
    @CompanyId INT = NULL,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'Corporates';

    CREATE TABLE #C (Corporate_ID INT PRIMARY KEY);
    INSERT INTO #C SELECT c.Corporate_ID FROM dbo.CorporateMaster c
    WHERE (@CompanyId IS NULL OR c.CompanyId = @CompanyId) AND (@BranchId IS NULL OR c.Branch_ID = @BranchId);

    CREATE TABLE #Keep (Corporate_ID INT PRIMARY KEY);
    INSERT INTO #Keep SELECT c.Corporate_ID FROM #C c
    WHERE EXISTS (SELECT 1 FROM dbo.LabOrder x WHERE x.AgentType = 'C' AND x.B2BAgentID = c.Corporate_ID)
       OR EXISTS (SELECT 1 FROM dbo.B2BInvoice x WHERE x.PartnerType = 'C' AND x.PartnerId = c.Corporate_ID)
       OR EXISTS (SELECT 1 FROM dbo.IpdAdmissionPayer x WHERE x.CorporateId = c.Corporate_ID);
    DELETE c FROM #C c INNER JOIN #Keep k ON k.Corporate_ID = c.Corporate_ID;
    SELECT @n = COUNT(1) FROM #Keep;
    IF @n > 0 EXEC cleanup.usp_Report @A, 'CorporateMaster', 'KEPT', @n, 'still have B2B bills / invoices / IPD payers (of another branch, or not cleared)';

    DELETE d FROM dbo.LabRateCardDetail d INNER JOIN dbo.LabRateCardMaster rc ON rc.RateCard_ID = d.RateCard_ID
    WHERE rc.Rate_Type = 'Corporate' AND rc.B2CIdentity_ID IN (SELECT Corporate_ID FROM #C);          SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabRateCardDetail', 'DELETE', @n, 'corporate rates';
    DELETE rc FROM dbo.LabRateCardMaster rc WHERE rc.Rate_Type = 'Corporate' AND rc.B2CIdentity_ID IN (SELECT Corporate_ID FROM #C);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabRateCardMaster', 'DELETE', @n, 'corporate LAB rate lists';
    DELETE x FROM dbo.CorporateHospitalRateMaster x INNER JOIN #C c ON c.Corporate_ID = x.Corporate_ID; SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'CorporateHospitalRateMaster', 'DELETE', @n, 'corporate hospital rates';
    DELETE x FROM dbo.DoctorCommissionConfig x INNER JOIN #C c ON c.Corporate_ID = x.CorporateId;      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorCommissionConfig', 'DELETE', @n, 'doctor commission overrides for the corporate';
    DELETE x FROM dbo.CorporateMaster x INNER JOIN #C c ON c.Corporate_ID = x.Corporate_ID;            SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'CorporateMaster', 'DELETE', @n, 'Master > Corporate (Company) Master';
END;
GO

-- ============================================================================
-- Users of the company / branch. Super Admin kept (his own data removed).
--   company scope: every user of the company is removed.
--   branch scope : users of this branch only are removed; users linked to other branches as well only lose this
--                  branch (all of them are removed when @RemoveMultiBranchUsers = 1).
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearUsersScoped
    @CompanyId              INT,
    @BranchId               INT = NULL,
    @RemoveMultiBranchUsers BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40);

    CREATE TABLE #SB (BranchId INT PRIMARY KEY);
    INSERT INTO #SB SELECT BranchId FROM cleanup.ufn_ScopeBranches(@CompanyId, @BranchId);

    -- users in scope (Super Admin never)
    CREATE TABLE #U (UserId INT PRIMARY KEY, OtherBranch BIT NOT NULL);
    INSERT INTO #U
    SELECT u.Id,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.UserBranches o WHERE o.UserId = u.Id AND o.BranchID NOT IN (SELECT BranchId FROM #SB) AND ISNULL(o.IsActive, 1) = 1) THEN 1 ELSE 0 END AS BIT)
    FROM dbo.Users u
    WHERE ISNULL(u.IsSuperAdmin, 0) = 0
      AND (EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID IN (SELECT BranchId FROM #SB))
           OR (@BranchId IS NULL AND u.CompanyId = @CompanyId));

    CREATE TABLE #Del (UserId INT PRIMARY KEY);
    CREATE TABLE #Unlink (UserId INT PRIMARY KEY);
    INSERT INTO #Del SELECT UserId FROM #U WHERE OtherBranch = 0 OR @RemoveMultiBranchUsers = 1;
    INSERT INTO #Unlink SELECT UserId FROM #U WHERE UserId NOT IN (SELECT UserId FROM #Del);

    -- field records that are still there (another branch, not cleared) keep their phlebotomist
    CREATE TABLE #Keep (UserId INT PRIMARY KEY);
    INSERT INTO #Keep SELECT d.UserId FROM #Del d
    WHERE EXISTS (SELECT 1 FROM dbo.PhleboAttendance x WHERE x.UserId = d.UserId)
       OR EXISTS (SELECT 1 FROM dbo.PhleboCashLedger x WHERE x.UserId = d.UserId)
       OR EXISTS (SELECT 1 FROM dbo.PhleboHandover x WHERE x.PhlebotomistId = d.UserId)
       OR EXISTS (SELECT 1 FROM dbo.LabHomeVisit x WHERE x.PhlebotomistId = d.UserId)
       OR EXISTS (SELECT 1 FROM dbo.LabPhleboBarcodePool x WHERE x.PhlebotomistId = d.UserId AND x.Status <> 1);
    DELETE FROM #Del WHERE UserId IN (SELECT UserId FROM #Keep);
    INSERT INTO #Unlink SELECT UserId FROM #Keep WHERE UserId NOT IN (SELECT UserId FROM #Unlink);
    SELECT @n = COUNT(1) FROM #Keep;
    IF @n > 0 EXEC cleanup.usp_Report N'Users', 'Users', 'KEPT', @n, 'phlebotomist field records / used barcodes still name them (only the branch link removed)';

    IF EXISTS (SELECT 1 FROM dbo.Users u WHERE ISNULL(u.IsSuperAdmin, 0) = 1 AND (u.Id IN (SELECT UserId FROM #Del) OR u.Id IN (SELECT UserId FROM #Unlink)))
        THROW 51001, 'A Super Admin (IsSuperAdmin = 1) would be removed - stopped.', 1;

    IF OBJECT_ID('tempdb..#ResetUsers') IS NOT NULL
        INSERT INTO #ResetUsers (UserId, Username, FullName, Outcome)
        SELECT u.Id, u.Username, u.FullName,
               CASE WHEN u.Id IN (SELECT UserId FROM #Del) THEN N'removed'
                    WHEN u.Id IN (SELECT UserId FROM #Keep) THEN N'kept - field records, branch link removed'
                    ELSE N'kept - branch link removed (works in other branches)' END
        FROM dbo.Users u WHERE u.Id IN (SELECT UserId FROM #Del) OR u.Id IN (SELECT UserId FROM #Unlink)
        UNION ALL
        SELECT u.Id, u.Username, u.FullName, N'kept - Super Admin (his data removed)' FROM dbo.Users u WHERE ISNULL(u.IsSuperAdmin, 0) = 1;

    -- ── 1. users linked to other branches as well: only the scope branches go ──
    SET @A = N'Users - branch link removed';
    DELETE FROM dbo.UserPermission WHERE Branch_ID IN (SELECT BranchId FROM #SB) AND User_ID IN (SELECT UserId FROM #Unlink);   SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'UserPermission', 'DELETE', @n, 'user permissions given for the branch';
    DELETE FROM dbo.Userroles WHERE Branch_ID IN (SELECT BranchId FROM #SB) AND UserId IN (SELECT UserId FROM #Unlink);        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Userroles', 'DELETE', @n, 'roles given for the branch only';
    DELETE FROM dbo.UserBranchLastLogin WHERE BranchId IN (SELECT BranchId FROM #SB) AND UserId IN (SELECT UserId FROM #Unlink);
    DELETE FROM dbo.UserBranches WHERE BranchID IN (SELECT BranchId FROM #SB) AND UserId IN (SELECT UserId FROM #Unlink);       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'UserBranches', 'DELETE', @n, 'links to the branch';

    -- ── 2. records that only name a removed user keep the record, lose the name ──
    SET @A = N'Users - name cleared';
    UPDATE dbo.AuditLogs SET UserId = NULL WHERE UserId IN (SELECT UserId FROM #Del);                          SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'AuditLogs', 'UPDATE', @n, 'audit entries kept without the user';
    UPDATE dbo.LabOrder SET PhlebotomistId = NULL WHERE PhlebotomistId IN (SELECT UserId FROM #Del);          SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabOrder', 'UPDATE', @n, 'phlebotomist removed from bills';
    UPDATE dbo.PaymentHeader SET DiscountApprovedBy = NULL WHERE DiscountApprovedBy IN (SELECT UserId FROM #Del); SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PaymentHeader', 'UPDATE', @n, 'discount approver removed from bills';
    UPDATE dbo.DoctorMaster SET LinkedUserId = NULL WHERE LinkedUserId IN (SELECT UserId FROM #Del);          SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorMaster', 'UPDATE', @n, 'doctors'' login link removed';
    UPDATE dbo.MarketingExecutive SET LoginUserId = NULL WHERE LoginUserId IN (SELECT UserId FROM #Del);      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'MarketingExecutive', 'UPDATE', @n, 'marketing executives kept without their login';
    UPDATE dbo.Users SET ReportsToUserId = NULL WHERE ReportsToUserId IN (SELECT UserId FROM #Del);           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Users', 'UPDATE', @n, '"reports to" cleared on other users';
    UPDATE dbo.HKStaffMaster SET Supervisor_ID = NULL WHERE Supervisor_ID IN (SELECT UserId FROM #Del);

    -- ── 3. removed users and the Super Admin: their own data ─────────────────
    -- #Own = removed users + Super Admin (Super Admin: only data, never the login, roles or head-office link)
    CREATE TABLE #Own (UserId INT PRIMARY KEY);
    INSERT INTO #Own SELECT UserId FROM #Del;
    INSERT INTO #Own SELECT u.Id FROM dbo.Users u WHERE ISNULL(u.IsSuperAdmin, 0) = 1 AND u.Id NOT IN (SELECT UserId FROM #Own);

    SET @A = N'Users - their data';
    DELETE FROM dbo.LabPhleboBarcodePool WHERE PhlebotomistId IN (SELECT UserId FROM #Del) AND Status = 1;    SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabPhleboBarcodePool', 'DELETE', @n, 'unused pre-printed barcodes assigned to removed phlebotomists';
    DELETE FROM dbo.HKStaffMaster WHERE Staff_ID IN (SELECT UserId FROM #Del);                                SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'HKStaffMaster', 'DELETE', @n, 'housekeeping staff records';
    DELETE FROM dbo.LabApprovalFlowApprover WHERE UserId IN (SELECT UserId FROM #Own);                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabApprovalFlowApprover', 'DELETE', @n, 'report approvers';
    DELETE FROM dbo.LabReportDefaultSignatory WHERE UserId IN (SELECT UserId FROM #Own);                      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabReportDefaultSignatory', 'DELETE', @n, 'report signatories';
    DELETE FROM dbo.ApprovalMatrixApprover WHERE UserId IN (SELECT UserId FROM #Own);                         SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'ApprovalMatrixApprover', 'DELETE', @n, 'approval matrix approvers';
    DELETE FROM dbo.AuditNotifyRecipient WHERE UserId IN (SELECT UserId FROM #Own);                           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'AuditNotifyRecipient', 'DELETE', @n, 'audit-notification recipients';
    DELETE FROM dbo.UserNotification WHERE UserId IN (SELECT UserId FROM #Own);                               SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'UserNotification', 'DELETE', @n, 'bell notifications';
    DELETE FROM dbo.ApiRefreshToken WHERE User_ID IN (SELECT UserId FROM #Own);                               SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'ApiRefreshToken', 'DELETE', @n, 'sessions (mobile / API)';
    DELETE FROM dbo.UserPasswordResetOtp WHERE UserId IN (SELECT UserId FROM #Own);
    DELETE FROM dbo.UserPasswordResetToken WHERE UserId IN (SELECT UserId FROM #Own);                         SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'UserPasswordReset*', 'DELETE', @n, 'password reset codes / links';
    DELETE FROM dbo.PhleboLocationPoint WHERE UserId IN (SELECT UserId FROM #Own);
    DELETE FROM dbo.MarketingLocationPoint WHERE UserId IN (SELECT UserId FROM #Own);                         SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Location points', 'DELETE', @n, 'GPS points';
    DELETE FROM dbo.PhleboDevice WHERE UserId IN (SELECT UserId FROM #Own);                                   SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PhleboDevice', 'DELETE', @n, 'approved phones';
    DELETE FROM dbo.UserPhleboArea WHERE UserId IN (SELECT UserId FROM #Own);                                 SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'UserPhleboArea', 'DELETE', @n, 'phlebotomist areas';
    DELETE FROM dbo.UserBranchLastLogin WHERE UserId IN (SELECT UserId FROM #Own);                            SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'UserBranchLastLogin', 'DELETE', @n, 'last login per branch';

    SET @A = N'Users removed';
    DELETE FROM dbo.UserPermission WHERE User_ID IN (SELECT UserId FROM #Del);                                SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'UserPermission', 'DELETE', @n, 'user permissions';
    DELETE FROM dbo.Userroles WHERE UserId IN (SELECT UserId FROM #Del);                                      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Userroles', 'DELETE', @n, 'roles';
    DELETE FROM dbo.UserBranches WHERE UserId IN (SELECT UserId FROM #Del);                                   SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'UserBranches', 'DELETE', @n, 'branch links';
    DELETE FROM dbo.Users WHERE Id IN (SELECT UserId FROM #Del) AND ISNULL(IsSuperAdmin, 0) = 0;              SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Users', 'DELETE', @n, 'User Master (listed in the last grid)';

    UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;   -- everyone re-reads permissions on next request
END;
GO

-- ============================================================================
-- Remove branches (never the head office). Company scope: every branch except the HO. Branch scope: that branch.
-- Company-wide masters registered at a removed branch move to the head office.
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_RemoveBranches
    @CompanyId INT,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40);

    DECLARE @Ho INT, @HoCount INT;
    SELECT @HoCount = COUNT(1), @Ho = MIN(BranchID) FROM dbo.Branchmaster WHERE CompanyId = @CompanyId AND IsHOBranch = 1;
    IF @HoCount <> 1
        THROW 51010, 'The company must have exactly one head-office branch (Branch Master > Is HO Branch).', 1;

    CREATE TABLE #Del (BranchId INT PRIMARY KEY);
    INSERT INTO #Del SELECT BranchID FROM dbo.Branchmaster
    WHERE CompanyId = @CompanyId AND BranchID <> @Ho AND (@BranchId IS NULL OR BranchID = @BranchId);
    IF EXISTS (SELECT 1 FROM #Del d INNER JOIN dbo.Branchmaster b ON b.BranchID = d.BranchId WHERE b.IsHOBranch = 1)
        THROW 51012, 'The head-office branch would be removed - stopped. Everything was rolled back.', 1;
    IF NOT EXISTS (SELECT 1 FROM #Del)
    BEGIN
        EXEC cleanup.usp_Report N'Branches', 'Branchmaster', 'KEPT', 1, 'head-office branch kept (its data was cleared)';
        RETURN;
    END

    -- every transaction of these branches must be gone by now (cleared earlier in the same run)
    DECLARE @Left TABLE (TableName NVARCHAR(128), RowsLeft INT);
    INSERT INTO @Left
    SELECT x.t, x.n FROM (
        SELECT N'LabOrder' AS t, COUNT(1) AS n FROM dbo.LabOrder WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PatientOPDService', COUNT(1) FROM dbo.PatientOPDService WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PaymentHeader', COUNT(1) FROM dbo.PaymentHeader WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'SampleCollection', COUNT(1) FROM dbo.SampleCollection
                  WHERE BranchID IN (SELECT BranchId FROM #Del) OR SourceBranchID IN (SELECT BranchId FROM #Del) OR TargetBranchID IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'B2BInvoice', COUNT(1) FROM dbo.B2BInvoice WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'Acc_LedgerTransaction', COUNT(1) FROM dbo.Acc_LedgerTransaction WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'Acc_PettyExpense', COUNT(1) FROM dbo.Acc_PettyExpense WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'Acc_PettyCashFloat', COUNT(1) FROM dbo.Acc_PettyCashFloat f INNER JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = f.CounterId WHERE c.BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'Acc_Voucher', COUNT(1) FROM dbo.Acc_Voucher WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'CashClosing', COUNT(1) FROM dbo.CashClosing WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'MembershipCard', COUNT(1) FROM dbo.MembershipCard WHERE IssueBranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'MembershipLedger', COUNT(1) FROM dbo.MembershipLedger WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'LabFranchiseWalletTransaction', COUNT(1) FROM dbo.LabFranchiseWalletTransaction WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'DoctorDisbursal', COUNT(1) FROM dbo.DoctorDisbursal WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'DoctorSettlement', COUNT(1) FROM dbo.DoctorSettlement WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'QcConsumption', COUNT(1) FROM dbo.QcConsumption WHERE BranchId IN (SELECT BranchId FROM #Del) OR SampleBranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'IqcRun', COUNT(1) FROM dbo.IqcRun WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'QcCapa', COUNT(1) FROM dbo.QcCapa WHERE BranchId IN (SELECT BranchId FROM #Del)
        -- 2026-11-12: IPD, pharmacy, LAB field work, estimates, certificates, marketing
        UNION ALL SELECT N'IpdAdmission', COUNT(1) FROM dbo.IpdAdmission WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'IpdEstimate', COUNT(1) FROM dbo.IpdEstimate WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'IpdBedReservation', COUNT(1) FROM dbo.IpdBedReservation WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'IpdPhIssue', COUNT(1) FROM dbo.IpdPhIssue WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PhSale', COUNT(1) FROM dbo.PhSale WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PhGrn', COUNT(1) FROM dbo.PhGrn WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PhPurchaseOrder', COUNT(1) FROM dbo.PhPurchaseOrder WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PhPurchaseIndent', COUNT(1) FROM dbo.PhPurchaseIndent WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PhSupplierPayment', COUNT(1) FROM dbo.PhSupplierPayment WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PhTransfer', COUNT(1) FROM dbo.PhTransfer WHERE FromBranchId IN (SELECT BranchId FROM #Del) OR ToBranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PhStockLedger', COUNT(1) FROM dbo.PhStockLedger WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PhStock', COUNT(1) FROM dbo.PhStock WHERE BranchId IN (SELECT BranchId FROM #Del) AND QtyOnHand <> 0
        UNION ALL SELECT N'LabHomeVisit', COUNT(1) FROM dbo.LabHomeVisit WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PhleboAttendance', COUNT(1) FROM dbo.PhleboAttendance WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PhleboCashLedger', COUNT(1) FROM dbo.PhleboCashLedger WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'LabEstimate', COUNT(1) FROM dbo.LabEstimate WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'PatientCertificate', COUNT(1) FROM dbo.PatientCertificate WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'ForecastDoctor', COUNT(1) FROM dbo.ForecastDoctor WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'MarketingDoctorVisit', COUNT(1) FROM dbo.MarketingDoctorVisit WHERE BranchId IN (SELECT BranchId FROM #Del)
        UNION ALL SELECT N'MarketingFieldDay', COUNT(1) FROM dbo.MarketingFieldDay WHERE BranchId IN (SELECT BranchId FROM #Del)
    ) x WHERE x.n > 0;
    IF EXISTS (SELECT 1 FROM @Left)
    BEGIN
        SELECT TableName AS [Transactions still at the branches to remove], RowsLeft FROM @Left ORDER BY TableName;
        THROW 51011, 'Transactions are still recorded at the branches to remove (listed above). Everything was rolled back.', 1;
    END

    -- ── 1. logs of the branches ─────────────────────────────────────────────
    SET @A = N'Branch logs';
    UPDATE dbo.AuditLogs SET BranchId = NULL WHERE BranchId IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'AuditLogs', 'UPDATE', @n, 'security / audit entries kept without the branch');
    DELETE FROM dbo.EmailLogs WHERE BranchId IN (SELECT BranchId FROM #Del);                  SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'EmailLogs', 'DELETE', @n, 'e-mail send log');
    DELETE FROM dbo.WhatsAppLog WHERE BranchId IN (SELECT BranchId FROM #Del);                SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'WhatsAppLog', 'DELETE', @n, 'WhatsApp send log');
    DELETE FROM dbo.UserNotification WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'UserNotification', 'DELETE', @n, 'bell notifications');
    DELETE FROM dbo.AuthorizationDecisionLog WHERE Branch_ID IN (SELECT BranchId FROM #Del);  SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'AuthorizationDecisionLog', 'DELETE', @n, 'permission decisions');
    DELETE FROM dbo.ApiRefreshToken WHERE Branch_ID IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'ApiRefreshToken', 'DELETE', @n, 'mobile / API sessions');
    DELETE FROM dbo.UserBranchLastLogin WHERE BranchId IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'UserBranchLastLogin', 'DELETE', @n, 'last login per branch');

    -- ── 2. company-wide masters move to the head office ─────────────────────
    SET @A = N'Moved to head office';
    UPDATE dbo.PatientMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);             SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'PatientMaster', 'UPDATE', @n, 'patients registered at the removed branches');
    UPDATE dbo.DoctorMaster SET CreatedBranchId = @Ho WHERE CreatedBranchId IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'DoctorMaster', 'UPDATE', @n, 'doctors'' home branch');
    UPDATE dbo.LabFranchiseMaster SET Parent_Branch_ID = @Ho WHERE Parent_Branch_ID IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'LabFranchiseMaster', 'UPDATE', @n, 'franchises'' parent branch');
    UPDATE dbo.LabFranchiseBarcodeSeries SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'LabFranchiseBarcodeSeries', 'UPDATE', @n, 'franchise barcode series');
    UPDATE dbo.LabRateCardMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del) AND Rate_Type IN ('Franchise', 'Corporate');
                                                                                                SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'LabRateCardMaster', 'UPDATE', @n, 'franchise / corporate rate lists');
    UPDATE dbo.CorporateMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'CorporateMaster', 'UPDATE', @n, 'corporates');
    UPDATE dbo.InsuranceTPAMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del);     SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'InsuranceTPAMaster', 'UPDATE', @n, 'insurance TPAs');
    UPDATE dbo.GovernmentSchemeMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'GovernmentSchemeMaster', 'UPDATE', @n, 'government schemes');
    UPDATE dbo.ProcedureMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'ProcedureMaster', 'UPDATE', @n, 'procedures');
    UPDATE dbo.ConsentMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'ConsentMaster', 'UPDATE', @n, 'consents');
    UPDATE dbo.AnaesthesiaTypeMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'AnaesthesiaTypeMaster', 'UPDATE', @n, 'anaesthesia types');
    UPDATE dbo.TariffCategoryMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);     SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'TariffCategoryMaster', 'UPDATE', @n, 'tariff categories');
    UPDATE dbo.BedCategoryMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'BedCategoryMaster', 'UPDATE', @n, 'bed categories');
    UPDATE dbo.LabReportingConditionMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'LabReportingConditionMaster', 'UPDATE', @n, 'conditions of reporting');
    UPDATE dbo.DiscountTypeMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);       SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'DiscountTypeMaster', 'UPDATE', @n, 'discount types');
    UPDATE dbo.ClinicalUnitMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);       SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'ClinicalUnitMaster', 'UPDATE', @n, 'clinical units');
    UPDATE dbo.DoctorSubSpecialityMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'DoctorSubSpecialityMaster', 'UPDATE', @n, 'doctor sub-specialities');

    -- ── 3. doctors' set-up at the removed branches ──────────────────────────
    SET @A = N'Doctor set-up';
    DELETE FROM dbo.DoctorScheduleException WHERE BranchId IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'DoctorScheduleException', 'DELETE', @n, 'schedule exceptions');
    DELETE FROM dbo.DoctorScheduleMaster WHERE BranchId IN (SELECT BranchId FROM #Del);      SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'DoctorScheduleMaster', 'DELETE', @n, 'schedules');
    DELETE FROM dbo.DoctorRoomMapping WHERE RoomId IN (SELECT r.RoomId FROM dbo.DoctorRoomMaster r WHERE r.BranchId IN (SELECT BranchId FROM #Del));
                                                                                              SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'DoctorRoomMapping', 'DELETE', @n, 'doctors in the branch''s rooms');
    DELETE FROM dbo.DoctorRoomMaster WHERE BranchId IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'DoctorRoomMaster', 'DELETE', @n, 'consulting rooms');
    DELETE FROM dbo.DoctorConsultingFeeMap WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'DoctorConsultingFeeMap', 'DELETE', @n, 'consulting fees');
    DELETE FROM dbo.DoctorBranchMap WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'DoctorBranchMap', 'DELETE', @n, 'doctors'' branch links');
    DELETE FROM dbo.Doctor_IP_Commission_Dtl WHERE Commission_Hdr_ID IN (SELECT h.Commission_Hdr_ID FROM dbo.Doctor_IP_Commission_Hdr h
                                                                     WHERE h.Branch_ID IN (SELECT BranchId FROM #Del)
                                                                        OR h.Doctor_IP_Hdr_ID IN (SELECT i.Doctor_IP_Hdr_ID FROM dbo.Doctor_IP_Hdr i WHERE i.Branch_ID IN (SELECT BranchId FROM #Del)));
    DELETE FROM dbo.Doctor_IP_Commission_Hdr WHERE Branch_ID IN (SELECT BranchId FROM #Del)
        OR Doctor_IP_Hdr_ID IN (SELECT i.Doctor_IP_Hdr_ID FROM dbo.Doctor_IP_Hdr i WHERE i.Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.Doctor_IP_Commission_RunLog WHERE Branch_ID IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.Doctor_IP_Dtl WHERE Doctor_IP_Hdr_ID IN (SELECT i.Doctor_IP_Hdr_ID FROM dbo.Doctor_IP_Hdr i WHERE i.Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.Doctor_IP_Hdr WHERE Branch_ID IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'Doctor_IP_Hdr', 'DELETE', @n, 'Doctor IP set-up (with its lines and commission runs)');
    DELETE FROM dbo.DoctorCommissionConfig WHERE BranchId IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'DoctorCommissionConfig', 'DELETE', @n, 'branch commission rules');
    DELETE FROM dbo.DoctorVisitProcessConfig WHERE BranchId IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'DoctorVisitProcessConfig', 'DELETE', @n, 'branch visit process rules');
    DELETE FROM dbo.ServiceMaster WHERE BranchId IN (SELECT BranchId FROM #Del);            SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'ServiceMaster', 'DELETE', @n, 'OPD services of the branch');

    -- ── 4. LAB, accounts and quality set-up of the removed branches ──────────
    SET @A = N'LAB / accounts / quality set-up';
    DELETE FROM dbo.LabRateCardDetail WHERE RateCard_ID IN (SELECT RateCard_ID FROM dbo.LabRateCardMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.LabRateCardMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);       SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'LabRateCardMaster', 'DELETE', @n, 'B2C rate lists of the branch (with their rates)');
    DELETE FROM dbo.LabReportDefaultSignatory WHERE BranchId IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'LabReportDefaultSignatory', 'DELETE', @n, 'report signatories');
    DELETE FROM dbo.LabApprovalFlowApprover WHERE Level_ID IN (SELECT l.Level_ID FROM dbo.LabApprovalFlowLevel l INNER JOIN dbo.LabApprovalFlow f ON f.Flow_ID = l.Flow_ID WHERE f.Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.LabApprovalFlowLevel WHERE Flow_ID IN (SELECT Flow_ID FROM dbo.LabApprovalFlow WHERE Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.LabApprovalFlow WHERE Branch_ID IN (SELECT BranchId FROM #Del);         SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'LabApprovalFlow', 'DELETE', @n, 'report approval flows (with levels and approvers)');
    DELETE FROM dbo.LabBarcodeConfig WHERE BranchId IN (SELECT BranchId FROM #Del);         SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'LabBarcodeConfig', 'DELETE', @n, 'barcode set-up');
    DELETE FROM dbo.Acc_PettyCashClosing WHERE CounterId IN (SELECT CounterId FROM dbo.Acc_PettyCashCounter WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.Acc_PettyCashCounter WHERE BranchId IN (SELECT BranchId FROM #Del);     SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'Acc_PettyCashCounter', 'DELETE', @n, 'petty cash counters (their ledgers stay in Ledger Master)');
    DELETE FROM dbo.Acc_BranchLock WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'Acc_BranchLock', 'DELETE', @n, 'book locks');
    DELETE FROM dbo.Acc_VoucherSequence WHERE BranchId IN (SELECT BranchId FROM #Del);      SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'Acc_VoucherSequence', 'DELETE', @n, 'voucher numbers');
    DELETE FROM dbo.InvStore WHERE BranchId IN (SELECT BranchId FROM #Del);                 SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'InvStore', 'DELETE', @n, 'stores');
    DELETE FROM dbo.QcEquipmentBreakdown WHERE EquipmentId IN (SELECT EquipmentId FROM dbo.QcEquipment WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEquipmentCalibration WHERE EquipmentId IN (SELECT EquipmentId FROM dbo.QcEquipment WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEquipmentMaintenance WHERE EquipmentId IN (SELECT EquipmentId FROM dbo.QcEquipment WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEquipment WHERE BranchId IN (SELECT BranchId FROM #Del);              SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'QcEquipment', 'DELETE', @n, 'equipment (with breakdowns, calibrations, maintenance)');
    DELETE FROM dbo.QcEqasResult WHERE CycleId IN (SELECT c.CycleId FROM dbo.QcEqasCycle c INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId WHERE p.BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEqasCycle WHERE ProgramId IN (SELECT ProgramId FROM dbo.QcEqasProgram WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEqasProgramTest WHERE ProgramId IN (SELECT ProgramId FROM dbo.QcEqasProgram WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEqasProgram WHERE BranchId IN (SELECT BranchId FROM #Del);            SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'QcEqasProgram', 'DELETE', @n, 'EQAS enrolments (with tests and cycles)');

    -- ── 5. IPD / OT / housekeeping set-up of the removed branches ────────────
    SET @A = N'IPD / OT / housekeeping set-up';
    DELETE FROM dbo.BedRoomTariffHistory WHERE BedRateId IN (SELECT t.BedRateId FROM dbo.BedRoomTariffMaster t WHERE t.BranchId IN (SELECT BranchId FROM #Del)) OR BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.BedRoomTariffMaster WHERE BranchId IN (SELECT BranchId FROM #Del);      SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'BedRoomTariffMaster', 'DELETE', @n, 'bed / room tariffs (with history)');
    DELETE FROM dbo.BedMaster WHERE BranchId IN (SELECT BranchId FROM #Del);                SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'BedMaster', 'DELETE', @n, 'beds');
    DELETE FROM dbo.NursingStationMaster WHERE BranchId IN (SELECT BranchId FROM #Del);     SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'NursingStationMaster', 'DELETE', @n, 'nursing stations');
    DELETE FROM dbo.IcuTariffDetail WHERE IcuTariffId IN (SELECT t.IcuTariffId FROM dbo.IcuTariffMaster t WHERE t.BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.IcuTariffMaster WHERE BranchId IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'IcuTariffMaster', 'DELETE', @n, 'ICU tariffs (with details)');
    DELETE FROM dbo.IcuMaster WHERE BranchId IN (SELECT BranchId FROM #Del);                SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'IcuMaster', 'DELETE', @n, 'ICUs');
    DELETE FROM dbo.RoomMaster WHERE BranchId IN (SELECT BranchId FROM #Del);               SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'RoomMaster', 'DELETE', @n, 'rooms');
    DELETE FROM dbo.OtEquipmentMaster WHERE BranchId IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'OtEquipmentMaster', 'DELETE', @n, 'OT equipment');
    DELETE FROM dbo.OtTariffMaster WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'OtTariffMaster', 'DELETE', @n, 'OT tariffs');
    DELETE FROM dbo.OtMaster WHERE BranchId IN (SELECT BranchId FROM #Del);                 SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'OtMaster', 'DELETE', @n, 'operation theatres');
    DELETE FROM dbo.WardMaster WHERE BranchId IN (SELECT BranchId FROM #Del);               SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'WardMaster', 'DELETE', @n, 'wards');
    DELETE FROM dbo.FloorMaster WHERE BuildingId IN (SELECT BuildingId FROM dbo.BuildingMaster WHERE BranchId IN (SELECT BranchId FROM #Del));
                                                                                              SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'FloorMaster', 'DELETE', @n, 'floors');
    DELETE FROM dbo.BuildingMaster WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'BuildingMaster', 'DELETE', @n, 'buildings');
    DELETE FROM dbo.HospitalServiceRateMaster WHERE BranchId IN (SELECT BranchId FROM #Del)
        OR HospitalServiceId IN (SELECT HospitalServiceId FROM dbo.HospitalServiceMaster WHERE BranchId IN (SELECT BranchId FROM #Del));
                                                                                              SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'HospitalServiceRateMaster', 'DELETE', @n, 'hospital service rates');
    DELETE FROM dbo.HospitalServiceMaster WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'HospitalServiceMaster', 'DELETE', @n, 'hospital services');
    DELETE FROM dbo.HospitalPackageDetail WHERE HospitalPackage_ID IN (SELECT HospitalPackage_ID FROM dbo.HospitalPackageMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.HospitalPackageMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'HospitalPackageMaster', 'DELETE', @n, 'hospital packages (with details)');
    DELETE FROM dbo.ProcedureTariffMaster WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'ProcedureTariffMaster', 'DELETE', @n, 'procedure tariffs');
    DELETE FROM dbo.AnaesthesiaRateMaster WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'AnaesthesiaRateMaster', 'DELETE', @n, 'anaesthesia rates');
    DELETE FROM dbo.InsuranceTariffMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'InsuranceTariffMaster', 'DELETE', @n, 'insurance tariffs');
    DELETE FROM dbo.CorporateHospitalRateMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'CorporateHospitalRateMaster', 'DELETE', @n, 'corporate hospital rates');
    DELETE FROM dbo.HKCleaningMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'HKCleaningMaster', 'DELETE', @n, 'housekeeping cleaning');
    DELETE FROM dbo.HKChecklistTemplateMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'HKChecklistTemplateMaster', 'DELETE', @n, 'housekeeping checklists');
    DELETE FROM dbo.HKStaffMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'HKStaffMaster', 'DELETE', @n, 'housekeeping staff');
    DELETE FROM dbo.HKLocationMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'HKLocationMaster', 'DELETE', @n, 'housekeeping locations');
    DELETE FROM dbo.ShiftMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);             SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'ShiftMaster', 'DELETE', @n, 'shifts');

    -- ── 5b. 2026-11-12: pharmacy, field work, IPD numbering, marketing, approvals, notifications, app set-up ──
    SET @A = N'Newer module set-up';
    DELETE FROM dbo.PhStoreStock WHERE BranchId IN (SELECT BranchId FROM #Del);              -- zero-quantity rows only (stock was checked above)
    DELETE FROM dbo.PhStock WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.PhStore WHERE BranchId IN (SELECT BranchId FROM #Del);                   SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'PhStore', 'DELETE', @n, 'pharmacy stores');
    DELETE FROM dbo.PhItemBranch WHERE BranchId IN (SELECT BranchId FROM #Del);              SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'PhItemBranch', 'DELETE', @n, 'item rack / reorder levels of the branch');
    DELETE FROM dbo.PhNumberCounter WHERE SeriesId IN (SELECT SeriesId FROM dbo.PhNumberSeries WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.PhNumberSeries WHERE BranchId IN (SELECT BranchId FROM #Del);            SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'PhNumberSeries', 'DELETE', @n, 'pharmacy number series (with counters)');
    DELETE FROM dbo.LabPhleboBarcodePool WHERE SeriesId IN (SELECT SeriesId FROM dbo.LabPhleboBarcodeSeries WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.LabPhleboBarcodeSeries WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'LabPhleboBarcodeSeries', 'DELETE', @n, 'phlebotomist pre-printed barcode series (with barcodes)');
    DELETE FROM dbo.IpdNumberCounter WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.CertificateSequence WHERE BranchId IN (SELECT BranchId FROM #Del);       SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'IPD / certificate counters', 'DELETE', @n, 'IP and certificate numbers');
    DELETE FROM dbo.IpdDoctorVisitFee WHERE BranchId IN (SELECT BranchId FROM #Del);         SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'IpdDoctorVisitFee', 'DELETE', @n, 'IPD doctor visit fees of the branch');
    DELETE FROM dbo.MarketingTargetBucket WHERE TargetId IN (SELECT TargetId FROM dbo.MarketingTarget WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.MarketingTarget WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'MarketingTarget', 'DELETE', @n, 'marketing sales / visit targets (with buckets)');
    DELETE FROM dbo.ApprovalRequest WHERE Branch_ID IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'ApprovalRequest', 'DELETE', @n, 'approval requests of the branch');
    DELETE FROM dbo.ApprovalMatrixApprover WHERE Matrix_ID IN (SELECT Matrix_ID FROM dbo.ApprovalMatrix WHERE Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.ApprovalMatrix WHERE Branch_ID IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'ApprovalMatrix', 'DELETE', @n, 'approval matrices (with approvers)');
    DELETE FROM dbo.AuditNotifyLog WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.AuditNotifyRecipient WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.AuditNotifyEventSetting WHERE BranchId IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'AuditNotifyEventSetting', 'DELETE', @n, 'audit notification set-up (with recipients and log)');
    DELETE FROM dbo.Acc_PaymentModeLedger WHERE BranchId IN (SELECT BranchId FROM #Del);     SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'Acc_PaymentModeLedger', 'DELETE', @n, 'payment-mode ledgers of the branch');
    DELETE FROM dbo.PaymentQrConfig WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'PaymentQrConfig', 'DELETE', @n, 'payment QR set-up');
    DELETE FROM dbo.PrintTemplateAssignment WHERE BranchId IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'PrintTemplateAssignment', 'DELETE', @n, 'print template assignments (templates kept)');
    DELETE FROM dbo.AppApkRelease WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.AppFtpSettings WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.LabFtpSettings WHERE BranchId IN (SELECT BranchId FROM #Del);            SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'App / FTP settings', 'DELETE', @n, 'app release and FTP settings of the branch');
    DELETE FROM dbo.CampaignRecipient WHERE CampaignId IN (SELECT CampaignId FROM dbo.Campaign WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.Campaign WHERE BranchId IN (SELECT BranchId FROM #Del);                  SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'Campaign', 'DELETE', @n, 'campaigns of the branch (with recipients)');
    DELETE FROM dbo.LabAiSuggestionFeedback WHERE BranchId IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'LabAiSuggestionFeedback', 'DELETE', @n, 'test suggestion feedback of the branch');
    DELETE FROM dbo.CertificateNotificationLog WHERE BranchId IN (SELECT BranchId FROM #Del);

    -- ── 6. branch settings, numbering, access ───────────────────────────────
    SET @A = N'Branch settings & access';
    DELETE FROM dbo.HospitalSettings WHERE BranchID IN (SELECT BranchId FROM #Del);         SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'HospitalSettings', 'DELETE', @n, 'Hospital Settings');
    DELETE FROM dbo.SmtpEmailConfiguration WHERE BranchId IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'SmtpEmailConfiguration', 'DELETE', @n, 'SMTP set-up');
    DELETE FROM dbo.WhatsAppConfiguration WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'WhatsAppConfiguration', 'DELETE', @n, 'WhatsApp set-up');
    DELETE FROM dbo.EmailTemplates WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'EmailTemplates', 'DELETE', @n, 'branch e-mail templates');
    DELETE FROM dbo.OPDBillSequence WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.OPDTokenSequence WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.ReceiptSequence WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.CancellationSequence WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.LabBarcodeSequence WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.PatientCodeCounter WHERE BranchId IN (SELECT BranchId FROM #Del);       SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'number series', 'DELETE', @n, 'bill, token, receipt, cancellation, barcode and patient-code counters');
    DELETE FROM dbo.RolePermission WHERE Branch_ID IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'RolePermission', 'DELETE', @n, 'branch-wise role permissions');
    DELETE FROM dbo.UserPermission WHERE Branch_ID IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'UserPermission', 'DELETE', @n, 'branch-wise user permissions');
    DELETE FROM dbo.Userroles WHERE Branch_ID IN (SELECT BranchId FROM #Del);               SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'Userroles', 'DELETE', @n, 'roles given for these branches only');
    DELETE FROM dbo.UserBranches WHERE BranchID IN (SELECT BranchId FROM #Del);             SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@A, 'UserBranches', 'DELETE', @n, 'users'' links to these branches');

    -- ── 7. the branches ─────────────────────────────────────────────────────
    DELETE FROM dbo.Branchmaster WHERE BranchID IN (SELECT BranchId FROM #Del);             SET @n = @@ROWCOUNT; INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (N'Branches', 'Branchmaster', 'DELETE', @n, 'branches removed (head office kept)');
    EXEC cleanup.usp_Report N'Branches', 'Branchmaster', 'KEPT', 1, 'head-office branch kept (its data was cleared)';
    UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
END;
GO

-- ============================================================================
-- The runner: one transaction, dry run unless @Execute = 1 and @Confirm match
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ProductionReset
    @CompanyId              INT,
    @BranchId               INT = NULL,
    @ClearTransactions      BIT = 1,     -- LAB, OPD, IPD, PHARMACY, marketing, membership, accounts, quality, ledger, logs
    @ClearPatients          BIT = 1,
    @ClearDoctors           BIT = 1,     -- Doctor Master with schedules, fees, rooms, commission, Doctor IP, visit fees
    @ClearFranchises        BIT = 1,     -- Franchise Master with rate lists, wallet, credit limit, barcodes
    @ClearCorporates        BIT = 1,     -- Corporate (Company) Master with rate lists, hospital rates
    @ClearB2CRateLists      BIT = 1,
    @ClearUsers             BIT = 1,     -- Super Admin kept, his data removed
    @RemoveMultiBranchUsers BIT = 0,     -- branch scope: 1 = also remove users who work in other branches too
    @RemoveBranches         BIT = 1,     -- every branch except the HO (company scope) / the chosen branch if not HO
    @Execute                BIT = 0,
    @Confirm                NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @CompanyId IS NULL AND @BranchId IS NOT NULL SELECT @CompanyId = CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId;
    IF @CompanyId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyId = @CompanyId)
        THROW 51020, 'Set @CompanyId to an existing company (Company Master > CompanyId). Nothing was changed.', 1;
    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND CompanyId = @CompanyId)
        THROW 51021, 'The branch does not exist or does not belong to the company. Nothing was changed.', 1;
    IF (SELECT COUNT(1) FROM dbo.Branchmaster WHERE CompanyId = @CompanyId AND IsHOBranch = 1) <> 1
        THROW 51022, 'The company must have exactly one head-office branch (Branch Master > Is HO Branch). Nothing was changed.', 1;
    IF ISNULL(@Execute, 0) = 1 AND ISNULL(@Confirm, N'') <> N'CLEAR ' + DB_NAME()
        THROW 51023, 'To delete for real set @Confirm to the exact text: CLEAR <database name> (e.g. CLEAR EMR_Live). Nothing was changed.', 1;
    IF @RemoveBranches = 1 AND @ClearTransactions = 0
        THROW 51024, 'Removing branches needs @ClearTransactions = 1 (their transactions go first). Nothing was changed.', 1;

    DECLARE @Ho INT = (SELECT BranchID FROM dbo.Branchmaster WHERE CompanyId = @CompanyId AND IsHOBranch = 1);
    DECLARE @IsHo BIT = CASE WHEN @BranchId = @Ho THEN 1 ELSE 0 END;

    PRINT N'=== Production reset ===';
    PRINT N'Database : ' + DB_NAME() + N' on ' + @@SERVERNAME;
    PRINT N'Company  : ' + ISNULL((SELECT TOP 1 CompanyName FROM dbo.CompanyMaster WHERE CompanyId = @CompanyId), N'?');
    PRINT N'Scope    : ' + CASE WHEN @BranchId IS NULL THEN N'whole company (head office kept, its data cleared; other branches '
                                     + CASE WHEN @RemoveBranches = 1 THEN N'removed)' ELSE N'kept, data cleared)' END
                                ELSE N'branch ' + (SELECT BranchName + N' (' + BranchCode + N')' FROM dbo.Branchmaster WHERE BranchID = @BranchId)
                                     + CASE WHEN @IsHo = 1 THEN N' - head office: kept, data cleared'
                                            WHEN @RemoveBranches = 1 THEN N' - removed after its data' ELSE N' - kept, data cleared' END END;
    PRINT N'Mode     : ' + CASE WHEN @Execute = 1 THEN N'EXECUTE - changes will be committed' ELSE N'DRY RUN - every change is rolled back at the end' END;
    PRINT N'Started  : ' + CONVERT(NVARCHAR(30), GETDATE(), 120);

    CREATE TABLE #CleanupReport (Step INT IDENTITY(1, 1), Area NVARCHAR(40), ObjectName NVARCHAR(128), Action VARCHAR(10), RowsAffected INT, Note NVARCHAR(400));
    CREATE TABLE #CleanupFiles (Area NVARCHAR(40), FilePath NVARCHAR(500));
    CREATE TABLE #ResetUsers (UserId INT, Username NVARCHAR(200), FullName NVARCHAR(300), Outcome NVARCHAR(100));
    DECLARE @Report TABLE (Step INT, Area NVARCHAR(40), ObjectName NVARCHAR(128), Action VARCHAR(10), RowsAffected INT, Note NVARCHAR(400));
    DECLARE @Files TABLE (Area NVARCHAR(40), FilePath NVARCHAR(500));
    DECLARE @Users TABLE (UserId INT, Username NVARCHAR(200), FullName NVARCHAR(300), Outcome NVARCHAR(100));

    -- what must survive: the head office and every Super Admin (checked again before commit)
    DECLARE @SuperAdmins TABLE (UserId INT PRIMARY KEY);
    INSERT INTO @SuperAdmins SELECT Id FROM dbo.Users WHERE ISNULL(IsSuperAdmin, 0) = 1;
    IF NOT EXISTS (SELECT 1 FROM @SuperAdmins)
        THROW 51025, 'No Super Admin user (Users.IsSuperAdmin = 1) exists - nobody could sign in afterwards. Nothing was changed.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. transactions (IPD first: its charges, ward issues and LAB orders point at LAB, pharmacy and OPD)
        IF @ClearTransactions = 1
        BEGIN
            EXEC cleanup.usp_ClearIpdTransactions @CompanyId, @BranchId, 1;
            EXEC cleanup.usp_ClearLabTransactions @CompanyId, @BranchId, 1;
            EXEC cleanup.usp_ClearOpdTransactions @CompanyId, @BranchId, 1;
            EXEC cleanup.usp_ClearPharmacy @CompanyId, @BranchId, 1;
            EXEC cleanup.usp_ClearMarketing @CompanyId, @BranchId;
            EXEC cleanup.usp_ClearMembership @CompanyId, @BranchId;
            EXEC cleanup.usp_ClearAccounts @CompanyId, @BranchId;
            EXEC cleanup.usp_ClearQuality @CompanyId, @BranchId;
            EXEC cleanup.usp_ClearRemainingLedger @CompanyId, @BranchId;
            EXEC cleanup.usp_ClearActivityLogs @CompanyId, @BranchId;
        END

        -- 2. masters and rate lists
        IF @ClearB2CRateLists = 1 EXEC cleanup.usp_ClearLabRateLists @CompanyId, @BranchId, N'B2C';
        IF @ClearFranchises = 1   EXEC cleanup.usp_ClearFranchises @CompanyId, @BranchId;
        IF @ClearCorporates = 1   EXEC cleanup.usp_ClearCorporates @CompanyId, @BranchId;
        IF @BranchId IS NULL AND @ClearFranchises = 1 AND @ClearCorporates = 1
            EXEC cleanup.usp_ClearLabRateLists @CompanyId, NULL, N'Franchise,Corporate';   -- rate lists left without a party
        IF @ClearPatients = 1     EXEC cleanup.usp_ClearPatients @CompanyId, @BranchId;
        IF @ClearDoctors = 1      EXEC cleanup.usp_ClearDoctors @CompanyId, @BranchId;

        -- 3. users (Super Admin kept, his data removed)
        IF @ClearUsers = 1        EXEC cleanup.usp_ClearUsersScoped @CompanyId, @BranchId, @RemoveMultiBranchUsers;

        -- 4. number series of what is kept start again at 1
        IF @ClearTransactions = 1 EXEC cleanup.usp_ResetSequences @CompanyId, @BranchId;

        -- 5. branches: the head office is always kept
        IF @RemoveBranches = 1    EXEC cleanup.usp_RemoveBranches @CompanyId, @BranchId;

        -- safety net: never commit without the head office or a Super Admin
        IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @Ho AND IsHOBranch = 1)
            THROW 51026, 'The head-office branch would be lost - stopped. Everything was rolled back.', 1;
        IF EXISTS (SELECT 1 FROM @SuperAdmins s WHERE NOT EXISTS (SELECT 1 FROM dbo.Users u WHERE u.Id = s.UserId AND ISNULL(u.IsSuperAdmin, 0) = 1))
            THROW 51027, 'A Super Admin user would be lost - stopped. Everything was rolled back.', 1;

        INSERT INTO @Report SELECT Step, Area, ObjectName, Action, RowsAffected, Note FROM #CleanupReport;
        INSERT INTO @Files SELECT DISTINCT Area, FilePath FROM #CleanupFiles;
        INSERT INTO @Users SELECT DISTINCT UserId, Username, FullName, Outcome FROM #ResetUsers;

        IF @Execute = 1 COMMIT TRANSACTION; ELSE ROLLBACK TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT N'*** ERROR - everything was rolled back, nothing changed ***';
        PRINT N'Message : ' + ERROR_MESSAGE();
        PRINT N'In      : ' + ISNULL(ERROR_PROCEDURE(), N'-') + N' line ' + CAST(ERROR_LINE() AS NVARCHAR(10));
        THROW;
    END CATCH

    SELECT Area, SUM(CASE WHEN Action = 'DELETE' THEN RowsAffected ELSE 0 END) AS RowsDeleted,
           SUM(CASE WHEN Action IN ('UPDATE', 'RESET') THEN RowsAffected ELSE 0 END) AS RowsUpdated,
           SUM(CASE WHEN Action = 'KEPT' THEN RowsAffected ELSE 0 END) AS RecordsKept
    FROM @Report GROUP BY Area ORDER BY MIN(Step);
    SELECT Step, Area, ObjectName AS [Table], Action, RowsAffected AS [Rows], Note FROM @Report WHERE RowsAffected > 0 ORDER BY Step;
    SELECT UserId, Username, FullName, CASE WHEN @Execute = 1 THEN Outcome ELSE N'would be ' + Outcome END AS Outcome
    FROM @Users ORDER BY CASE WHEN Outcome LIKE N'kept - Super%' THEN 0 WHEN Outcome = N'removed' THEN 1 ELSE 2 END, Username;
    IF EXISTS (SELECT 1 FROM @Files)
        SELECT Area, FilePath AS [File to remove from the server (uploads) after an executed run] FROM @Files ORDER BY Area, FilePath;

    PRINT N'Finished : ' + CONVERT(NVARCHAR(30), GETDATE(), 120);
    PRINT CASE WHEN @Execute = 1 THEN N'=== COMMITTED ===' ELSE N'=== DRY RUN: nothing was changed. The counts show what an executed run would do. ===' END;
END;
GO

PRINT 'Production reset procedures installed in schema [cleanup].';
GO
