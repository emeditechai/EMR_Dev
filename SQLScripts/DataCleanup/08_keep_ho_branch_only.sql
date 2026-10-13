-- ============================================================================
-- DataCleanup / 08_keep_ho_branch_only.sql
-- Keep only the head-office branch (Branch Master > IsHOBranch = 1) of a company, and only the users of that branch.
-- ----------------------------------------------------------------------------
--   BRANCHES: every other branch of the company is removed with its own set-up:
--     settings (Hospital Settings, SMTP, WhatsApp), number series, barcode set-up, users' branch links, branch-wise
--     roles and permissions, doctor schedules / rooms / fees / branch links / Doctor IP / commission rules of the
--     branch, B2C rate lists of the branch, report signatories, approval flows, petty cash counters, book locks,
--     voucher numbers, stores, equipment (with its history), EQAS enrolments, IPD / OT / housekeeping set-up
--     (buildings, floors, wards, rooms, beds, ICU, OT, tariffs, packages, hospital services, shifts, staff), OPD
--     services, the branch's logs.
--   Moved to the head office instead (company-wide masters that only recorded where they were created): patients,
--     doctors' home branch, franchises' parent branch and barcode series, franchise / corporate rate lists,
--     corporates, TPAs, government schemes, consents, procedures, anaesthesia types, tariff and bed categories,
--     reporting conditions, discount types, clinical units, doctor sub-specialities.
--   USERS: every user of the company with no active link to the head office is removed, with their roles, branch
--     links, permissions, sessions and notifications; the Super Admin is always kept. Records that only name such a
--     user keep the record and lose the name (discount approver, phlebotomist, doctor login link, audit entries).
--
--   Transactions must be cleared first: the script stops if any bill, payment, voucher, day closing, sample,
--   membership card or quality record is still at a branch to remove. Run 07_clear_all_transactions.sql (for the
--   company, or with @BranchId for each of those branches) before this one.
--   Stand-alone: does not need 00_install_cleanup_procedures.sql.
--
--   HOW TO RUN
--     1. Select the database. Set @CompanyId. Run as it is (@Execute = 0): a DRY RUN - every change is made and then
--        rolled back; the result grid lists each table and how many rows WOULD change.
--     2. Stop the web and API sites and take a FULL database backup.
--     3. Set @Execute = 1 and @Confirm = 'CLEAR <database name>' and run again.
--   Any error rolls the whole run back: either everything listed is done, or nothing is.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @CompanyId  INT = 1;      -- the company whose branches are reduced to its head office
DECLARE @ClearUsers BIT = 1;      -- 1 = also remove the users with no link to the head office

DECLARE @Execute BIT           = 0;      -- 0 = dry run (nothing is changed)   1 = do it for real
DECLARE @Confirm NVARCHAR(200) = N'';    -- with @Execute = 1: 'CLEAR ' + the database name

-- ── checks ──────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyId = @CompanyId)
    THROW 50200, 'The company does not exist.', 1;
DECLARE @Ho INT, @HoCount INT;
SELECT @HoCount = COUNT(1), @Ho = MIN(BranchID) FROM dbo.Branchmaster WHERE CompanyId = @CompanyId AND IsHOBranch = 1;
IF @HoCount <> 1
    THROW 50201, 'The company must have exactly one head-office branch (Branch Master > Is HO Branch). Nothing was changed.', 1;
IF ISNULL(@Execute, 0) = 1 AND ISNULL(@Confirm, N'') <> N'CLEAR ' + DB_NAME()
    THROW 50202, 'To change for real set @Confirm to the exact text: CLEAR <database name>. Nothing was changed.', 1;

CREATE TABLE #Del (BranchId INT PRIMARY KEY);
INSERT INTO #Del SELECT BranchID FROM dbo.Branchmaster WHERE CompanyId = @CompanyId AND BranchID <> @Ho;

-- transactions still at a branch to remove: stop, nothing is changed
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
) x WHERE x.n > 0;
IF EXISTS (SELECT 1 FROM @Left)
BEGIN
    SELECT TableName AS [Transactions still at the branches to remove], RowsLeft FROM @Left ORDER BY TableName;
    THROW 50203, 'Transactions are still recorded at the branches to remove (listed above). Run 07_clear_all_transactions.sql for them first. Nothing was changed.', 1;
END

PRINT N'=== Keep the head-office branch only ===';
PRINT N'Database : ' + DB_NAME() + N' on ' + @@SERVERNAME;
DECLARE @KeepText NVARCHAR(300) = (SELECT BranchName + N' (' + BranchCode + N')' FROM dbo.Branchmaster WHERE BranchID = @Ho);
DECLARE @RemoveText NVARCHAR(MAX) = (SELECT STRING_AGG(BranchName + N' (' + BranchCode + N')', N', ') FROM dbo.Branchmaster WHERE BranchID IN (SELECT BranchId FROM #Del));
PRINT N'Keep     : ' + @KeepText;
PRINT N'Remove   : ' + ISNULL(@RemoveText, N'- none -');
PRINT N'Mode     : ' + CASE WHEN @Execute = 1 THEN N'EXECUTE - changes will be committed' ELSE N'DRY RUN - every change is rolled back at the end' END;

DECLARE @Report TABLE (Step INT IDENTITY(1, 1), Area NVARCHAR(40), TableName NVARCHAR(128), Action VARCHAR(10), RowsAffected INT, Note NVARCHAR(300));
DECLARE @n INT, @A NVARCHAR(40);

CREATE TABLE #DelUsers (UserId INT PRIMARY KEY);
DECLARE @Users TABLE (UserId INT, Username NVARCHAR(200), FullName NVARCHAR(300), UserType NVARCHAR(10));   -- survives a rollback

BEGIN TRY
    BEGIN TRANSACTION;

    -- ── 1. logs of the branches ─────────────────────────────────────────────
    SET @A = N'Branch logs';
    UPDATE dbo.AuditLogs SET BranchId = NULL WHERE BranchId IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'AuditLogs', 'UPDATE', @n, 'security / audit entries kept without the branch');
    DELETE FROM dbo.EmailLogs WHERE BranchId IN (SELECT BranchId FROM #Del);                  SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'EmailLogs', 'DELETE', @n, 'e-mail send log');
    DELETE FROM dbo.WhatsAppLog WHERE BranchId IN (SELECT BranchId FROM #Del);                SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'WhatsAppLog', 'DELETE', @n, 'WhatsApp send log');
    DELETE FROM dbo.UserNotification WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserNotification', 'DELETE', @n, 'bell notifications');
    DELETE FROM dbo.AuthorizationDecisionLog WHERE Branch_ID IN (SELECT BranchId FROM #Del);  SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'AuthorizationDecisionLog', 'DELETE', @n, 'permission decisions');
    DELETE FROM dbo.ApiRefreshToken WHERE Branch_ID IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'ApiRefreshToken', 'DELETE', @n, 'mobile / API sessions');
    DELETE FROM dbo.UserBranchLastLogin WHERE BranchId IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserBranchLastLogin', 'DELETE', @n, 'last login per branch');

    -- ── 2. company-wide masters move to the head office ─────────────────────
    SET @A = N'Moved to head office';
    UPDATE dbo.PatientMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);             SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'PatientMaster', 'UPDATE', @n, 'patients registered at the removed branches');
    UPDATE dbo.DoctorMaster SET CreatedBranchId = @Ho WHERE CreatedBranchId IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorMaster', 'UPDATE', @n, 'doctors'' home branch');
    UPDATE dbo.LabFranchiseMaster SET Parent_Branch_ID = @Ho WHERE Parent_Branch_ID IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabFranchiseMaster', 'UPDATE', @n, 'franchises'' parent branch');
    UPDATE dbo.LabFranchiseBarcodeSeries SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabFranchiseBarcodeSeries', 'UPDATE', @n, 'franchise barcode series');
    UPDATE dbo.LabRateCardMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del) AND Rate_Type IN ('Franchise', 'Corporate');
                                                                                                SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabRateCardMaster', 'UPDATE', @n, 'franchise / corporate rate lists');
    UPDATE dbo.CorporateMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'CorporateMaster', 'UPDATE', @n, 'corporates');
    UPDATE dbo.InsuranceTPAMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del);     SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'InsuranceTPAMaster', 'UPDATE', @n, 'insurance TPAs');
    UPDATE dbo.GovernmentSchemeMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'GovernmentSchemeMaster', 'UPDATE', @n, 'government schemes');
    UPDATE dbo.ProcedureMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'ProcedureMaster', 'UPDATE', @n, 'procedures');
    UPDATE dbo.ConsentMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'ConsentMaster', 'UPDATE', @n, 'consents');
    UPDATE dbo.AnaesthesiaTypeMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'AnaesthesiaTypeMaster', 'UPDATE', @n, 'anaesthesia types');
    UPDATE dbo.TariffCategoryMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);     SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'TariffCategoryMaster', 'UPDATE', @n, 'tariff categories');
    UPDATE dbo.BedCategoryMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'BedCategoryMaster', 'UPDATE', @n, 'bed categories');
    UPDATE dbo.LabReportingConditionMaster SET Branch_ID = @Ho WHERE Branch_ID IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabReportingConditionMaster', 'UPDATE', @n, 'conditions of reporting');
    UPDATE dbo.DiscountTypeMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);       SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DiscountTypeMaster', 'UPDATE', @n, 'discount types');
    UPDATE dbo.ClinicalUnitMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del);       SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'ClinicalUnitMaster', 'UPDATE', @n, 'clinical units');
    UPDATE dbo.DoctorSubSpecialityMaster SET BranchId = @Ho WHERE BranchId IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorSubSpecialityMaster', 'UPDATE', @n, 'doctor sub-specialities');

    -- ── 3. doctors' set-up at the removed branches ──────────────────────────
    SET @A = N'Doctor set-up';
    DELETE FROM dbo.DoctorScheduleException WHERE BranchId IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorScheduleException', 'DELETE', @n, 'schedule exceptions');
    DELETE FROM dbo.DoctorScheduleMaster WHERE BranchId IN (SELECT BranchId FROM #Del);      SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorScheduleMaster', 'DELETE', @n, 'schedules');
    DELETE FROM dbo.DoctorRoomMapping WHERE RoomId IN (SELECT r.RoomId FROM dbo.DoctorRoomMaster r WHERE r.BranchId IN (SELECT BranchId FROM #Del));
                                                                                              SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorRoomMapping', 'DELETE', @n, 'doctors in the branch''s rooms');
    DELETE FROM dbo.DoctorRoomMaster WHERE BranchId IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorRoomMaster', 'DELETE', @n, 'consulting rooms');
    DELETE FROM dbo.DoctorConsultingFeeMap WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorConsultingFeeMap', 'DELETE', @n, 'consulting fees');
    DELETE FROM dbo.DoctorBranchMap WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorBranchMap', 'DELETE', @n, 'doctors'' branch links');
    DELETE FROM dbo.Doctor_IP_Commission_Dtl WHERE Commission_Hdr_ID IN (SELECT h.Commission_Hdr_ID FROM dbo.Doctor_IP_Commission_Hdr h
                                                                     WHERE h.Branch_ID IN (SELECT BranchId FROM #Del)
                                                                        OR h.Doctor_IP_Hdr_ID IN (SELECT i.Doctor_IP_Hdr_ID FROM dbo.Doctor_IP_Hdr i WHERE i.Branch_ID IN (SELECT BranchId FROM #Del)));
    DELETE FROM dbo.Doctor_IP_Commission_Hdr WHERE Branch_ID IN (SELECT BranchId FROM #Del)
        OR Doctor_IP_Hdr_ID IN (SELECT i.Doctor_IP_Hdr_ID FROM dbo.Doctor_IP_Hdr i WHERE i.Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.Doctor_IP_Commission_RunLog WHERE Branch_ID IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.Doctor_IP_Dtl WHERE Doctor_IP_Hdr_ID IN (SELECT i.Doctor_IP_Hdr_ID FROM dbo.Doctor_IP_Hdr i WHERE i.Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.Doctor_IP_Hdr WHERE Branch_ID IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'Doctor_IP_Hdr', 'DELETE', @n, 'Doctor IP set-up (with its lines and commission runs)');
    DELETE FROM dbo.DoctorCommissionConfig WHERE BranchId IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorCommissionConfig', 'DELETE', @n, 'branch commission rules');
    DELETE FROM dbo.DoctorVisitProcessConfig WHERE BranchId IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorVisitProcessConfig', 'DELETE', @n, 'branch visit process rules');
    DELETE FROM dbo.ServiceMaster WHERE BranchId IN (SELECT BranchId FROM #Del);            SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'ServiceMaster', 'DELETE', @n, 'OPD services of the branch');

    -- ── 4. LAB, accounts and quality set-up of the removed branches ──────────
    SET @A = N'LAB / accounts / quality set-up';
    DELETE FROM dbo.LabRateCardDetail WHERE RateCard_ID IN (SELECT RateCard_ID FROM dbo.LabRateCardMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.LabRateCardMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);       SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabRateCardMaster', 'DELETE', @n, 'B2C rate lists of the branch (with their rates)');
    DELETE FROM dbo.LabReportDefaultSignatory WHERE BranchId IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabReportDefaultSignatory', 'DELETE', @n, 'report signatories');
    DELETE FROM dbo.LabApprovalFlowApprover WHERE Level_ID IN (SELECT l.Level_ID FROM dbo.LabApprovalFlowLevel l INNER JOIN dbo.LabApprovalFlow f ON f.Flow_ID = l.Flow_ID WHERE f.Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.LabApprovalFlowLevel WHERE Flow_ID IN (SELECT Flow_ID FROM dbo.LabApprovalFlow WHERE Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.LabApprovalFlow WHERE Branch_ID IN (SELECT BranchId FROM #Del);         SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabApprovalFlow', 'DELETE', @n, 'report approval flows (with levels and approvers)');
    DELETE FROM dbo.LabBarcodeConfig WHERE BranchId IN (SELECT BranchId FROM #Del);         SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabBarcodeConfig', 'DELETE', @n, 'barcode set-up');
    DELETE FROM dbo.Acc_PettyCashClosing WHERE CounterId IN (SELECT CounterId FROM dbo.Acc_PettyCashCounter WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.Acc_PettyCashCounter WHERE BranchId IN (SELECT BranchId FROM #Del);     SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'Acc_PettyCashCounter', 'DELETE', @n, 'petty cash counters (their ledgers stay in Ledger Master)');
    DELETE FROM dbo.Acc_BranchLock WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'Acc_BranchLock', 'DELETE', @n, 'book locks');
    DELETE FROM dbo.Acc_VoucherSequence WHERE BranchId IN (SELECT BranchId FROM #Del);      SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'Acc_VoucherSequence', 'DELETE', @n, 'voucher numbers');
    DELETE FROM dbo.InvStore WHERE BranchId IN (SELECT BranchId FROM #Del);                 SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'InvStore', 'DELETE', @n, 'stores');
    DELETE FROM dbo.QcEquipmentBreakdown WHERE EquipmentId IN (SELECT EquipmentId FROM dbo.QcEquipment WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEquipmentCalibration WHERE EquipmentId IN (SELECT EquipmentId FROM dbo.QcEquipment WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEquipmentMaintenance WHERE EquipmentId IN (SELECT EquipmentId FROM dbo.QcEquipment WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEquipment WHERE BranchId IN (SELECT BranchId FROM #Del);              SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'QcEquipment', 'DELETE', @n, 'equipment (with breakdowns, calibrations, maintenance)');
    DELETE FROM dbo.QcEqasResult WHERE CycleId IN (SELECT c.CycleId FROM dbo.QcEqasCycle c INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId WHERE p.BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEqasCycle WHERE ProgramId IN (SELECT ProgramId FROM dbo.QcEqasProgram WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEqasProgramTest WHERE ProgramId IN (SELECT ProgramId FROM dbo.QcEqasProgram WHERE BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.QcEqasProgram WHERE BranchId IN (SELECT BranchId FROM #Del);            SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'QcEqasProgram', 'DELETE', @n, 'EQAS enrolments (with tests and cycles)');

    -- ── 5. IPD / OT / housekeeping set-up of the removed branches ────────────
    SET @A = N'IPD / OT / housekeeping set-up';
    DELETE FROM dbo.BedRoomTariffHistory WHERE BedRateId IN (SELECT t.BedRateId FROM dbo.BedRoomTariffMaster t WHERE t.BranchId IN (SELECT BranchId FROM #Del)) OR BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.BedRoomTariffMaster WHERE BranchId IN (SELECT BranchId FROM #Del);      SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'BedRoomTariffMaster', 'DELETE', @n, 'bed / room tariffs (with history)');
    DELETE FROM dbo.BedMaster WHERE BranchId IN (SELECT BranchId FROM #Del);                SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'BedMaster', 'DELETE', @n, 'beds');
    DELETE FROM dbo.NursingStationMaster WHERE BranchId IN (SELECT BranchId FROM #Del);     SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'NursingStationMaster', 'DELETE', @n, 'nursing stations');
    DELETE FROM dbo.IcuTariffDetail WHERE IcuTariffId IN (SELECT t.IcuTariffId FROM dbo.IcuTariffMaster t WHERE t.BranchId IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.IcuTariffMaster WHERE BranchId IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'IcuTariffMaster', 'DELETE', @n, 'ICU tariffs (with details)');
    DELETE FROM dbo.IcuMaster WHERE BranchId IN (SELECT BranchId FROM #Del);                SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'IcuMaster', 'DELETE', @n, 'ICUs');
    DELETE FROM dbo.RoomMaster WHERE BranchId IN (SELECT BranchId FROM #Del);               SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'RoomMaster', 'DELETE', @n, 'rooms');
    DELETE FROM dbo.OtEquipmentMaster WHERE BranchId IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'OtEquipmentMaster', 'DELETE', @n, 'OT equipment');
    DELETE FROM dbo.OtTariffMaster WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'OtTariffMaster', 'DELETE', @n, 'OT tariffs');
    DELETE FROM dbo.OtMaster WHERE BranchId IN (SELECT BranchId FROM #Del);                 SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'OtMaster', 'DELETE', @n, 'operation theatres');
    DELETE FROM dbo.WardMaster WHERE BranchId IN (SELECT BranchId FROM #Del);               SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'WardMaster', 'DELETE', @n, 'wards');
    DELETE FROM dbo.FloorMaster WHERE BuildingId IN (SELECT BuildingId FROM dbo.BuildingMaster WHERE BranchId IN (SELECT BranchId FROM #Del));
                                                                                              SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'FloorMaster', 'DELETE', @n, 'floors');
    DELETE FROM dbo.BuildingMaster WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'BuildingMaster', 'DELETE', @n, 'buildings');
    DELETE FROM dbo.HospitalServiceRateMaster WHERE BranchId IN (SELECT BranchId FROM #Del)
        OR HospitalServiceId IN (SELECT HospitalServiceId FROM dbo.HospitalServiceMaster WHERE BranchId IN (SELECT BranchId FROM #Del));
                                                                                              SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'HospitalServiceRateMaster', 'DELETE', @n, 'hospital service rates');
    DELETE FROM dbo.HospitalServiceMaster WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'HospitalServiceMaster', 'DELETE', @n, 'hospital services');
    DELETE FROM dbo.HospitalPackageDetail WHERE HospitalPackage_ID IN (SELECT HospitalPackage_ID FROM dbo.HospitalPackageMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del));
    DELETE FROM dbo.HospitalPackageMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'HospitalPackageMaster', 'DELETE', @n, 'hospital packages (with details)');
    DELETE FROM dbo.ProcedureTariffMaster WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'ProcedureTariffMaster', 'DELETE', @n, 'procedure tariffs');
    DELETE FROM dbo.AnaesthesiaRateMaster WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'AnaesthesiaRateMaster', 'DELETE', @n, 'anaesthesia rates');
    DELETE FROM dbo.InsuranceTariffMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'InsuranceTariffMaster', 'DELETE', @n, 'insurance tariffs');
    DELETE FROM dbo.CorporateHospitalRateMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'CorporateHospitalRateMaster', 'DELETE', @n, 'corporate hospital rates');
    DELETE FROM dbo.HKCleaningMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'HKCleaningMaster', 'DELETE', @n, 'housekeeping cleaning');
    DELETE FROM dbo.HKChecklistTemplateMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'HKChecklistTemplateMaster', 'DELETE', @n, 'housekeeping checklists');
    DELETE FROM dbo.HKStaffMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'HKStaffMaster', 'DELETE', @n, 'housekeeping staff');
    DELETE FROM dbo.HKLocationMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);        SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'HKLocationMaster', 'DELETE', @n, 'housekeeping locations');
    DELETE FROM dbo.ShiftMaster WHERE Branch_ID IN (SELECT BranchId FROM #Del);             SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'ShiftMaster', 'DELETE', @n, 'shifts');

    -- ── 6. branch settings, numbering, access ───────────────────────────────
    SET @A = N'Branch settings & access';
    DELETE FROM dbo.HospitalSettings WHERE BranchID IN (SELECT BranchId FROM #Del);         SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'HospitalSettings', 'DELETE', @n, 'Hospital Settings');
    DELETE FROM dbo.SmtpEmailConfiguration WHERE BranchId IN (SELECT BranchId FROM #Del);   SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'SmtpEmailConfiguration', 'DELETE', @n, 'SMTP set-up');
    DELETE FROM dbo.WhatsAppConfiguration WHERE BranchId IN (SELECT BranchId FROM #Del);    SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'WhatsAppConfiguration', 'DELETE', @n, 'WhatsApp set-up');
    DELETE FROM dbo.EmailTemplates WHERE BranchId IN (SELECT BranchId FROM #Del);           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'EmailTemplates', 'DELETE', @n, 'branch e-mail templates');
    DELETE FROM dbo.OPDBillSequence WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.OPDTokenSequence WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.ReceiptSequence WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.CancellationSequence WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.LabBarcodeSequence WHERE BranchId IN (SELECT BranchId FROM #Del);
    DELETE FROM dbo.PatientCodeCounter WHERE BranchId IN (SELECT BranchId FROM #Del);       SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'number series', 'DELETE', @n, 'bill, token, receipt, cancellation, barcode and patient-code counters');
    DELETE FROM dbo.RolePermission WHERE Branch_ID IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'RolePermission', 'DELETE', @n, 'branch-wise role permissions');
    DELETE FROM dbo.UserPermission WHERE Branch_ID IN (SELECT BranchId FROM #Del);          SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserPermission', 'DELETE', @n, 'branch-wise user permissions');
    DELETE FROM dbo.Userroles WHERE Branch_ID IN (SELECT BranchId FROM #Del);               SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'Userroles', 'DELETE', @n, 'roles given for these branches only');
    DELETE FROM dbo.UserBranches WHERE BranchID IN (SELECT BranchId FROM #Del);             SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserBranches', 'DELETE', @n, 'users'' links to these branches');

    -- ── 7. the branches ─────────────────────────────────────────────────────
    DELETE FROM dbo.Branchmaster WHERE BranchID IN (SELECT BranchId FROM #Del);             SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (N'Branches', 'Branchmaster', 'DELETE', @n, 'branches removed (head office kept)');

    -- ── 8. users with no link to the head office ────────────────────────────
    IF @ClearUsers = 1
    BEGIN
        SET @A = N'Users';
        INSERT INTO #DelUsers SELECT u.Id FROM dbo.Users u
        WHERE ISNULL(u.IsSuperAdmin, 0) = 0
          AND (u.CompanyId = @CompanyId OR u.CompanyId IS NULL)
          AND NOT EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @Ho AND ISNULL(ub.IsActive, 1) = 1);
        INSERT INTO @Users SELECT u.Id, u.Username, u.FullName, ISNULL(u.User_Type, '') FROM dbo.Users u INNER JOIN #DelUsers d ON d.UserId = u.Id;

        UPDATE dbo.AuditLogs SET UserId = NULL WHERE UserId IN (SELECT UserId FROM #DelUsers);                     SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'AuditLogs', 'UPDATE', @n, 'audit entries kept without the user');
        UPDATE dbo.PaymentHeader SET DiscountApprovedBy = NULL WHERE DiscountApprovedBy IN (SELECT UserId FROM #DelUsers); SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'PaymentHeader', 'UPDATE', @n, 'discount approver removed from bills');
        UPDATE dbo.LabOrder SET PhlebotomistId = NULL WHERE PhlebotomistId IN (SELECT UserId FROM #DelUsers);     SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabOrder', 'UPDATE', @n, 'phlebotomist removed from bills');
        UPDATE dbo.DoctorMaster SET LinkedUserId = NULL WHERE LinkedUserId IN (SELECT UserId FROM #DelUsers);     SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'DoctorMaster', 'UPDATE', @n, 'doctors'' login link removed');
        UPDATE dbo.HKStaffMaster SET Supervisor_ID = NULL WHERE Supervisor_ID IN (SELECT UserId FROM #DelUsers);
        DELETE FROM dbo.HKStaffMaster WHERE Staff_ID IN (SELECT UserId FROM #DelUsers);                           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'HKStaffMaster', 'DELETE', @n, 'housekeeping staff records of these users');
        DELETE FROM dbo.LabApprovalFlowApprover WHERE UserId IN (SELECT UserId FROM #DelUsers);                   SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabApprovalFlowApprover', 'DELETE', @n, 'report approvers');
        DELETE FROM dbo.LabReportDefaultSignatory WHERE UserId IN (SELECT UserId FROM #DelUsers);                 SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'LabReportDefaultSignatory', 'DELETE', @n, 'report signatories');
        DELETE FROM dbo.UserNotification WHERE UserId IN (SELECT UserId FROM #DelUsers);                          SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserNotification', 'DELETE', @n, 'bell notifications');
        DELETE FROM dbo.ApiRefreshToken WHERE User_ID IN (SELECT UserId FROM #DelUsers);                          SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'ApiRefreshToken', 'DELETE', @n, 'sessions');
        DELETE FROM dbo.UserBranchLastLogin WHERE UserId IN (SELECT UserId FROM #DelUsers);
        DELETE FROM dbo.UserPermission WHERE User_ID IN (SELECT UserId FROM #DelUsers);                           SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserPermission', 'DELETE', @n, 'user permissions');
        DELETE FROM dbo.Userroles WHERE UserId IN (SELECT UserId FROM #DelUsers);                                 SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'Userroles', 'DELETE', @n, 'roles');
        DELETE FROM dbo.UserBranches WHERE UserId IN (SELECT UserId FROM #DelUsers);                              SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'UserBranches', 'DELETE', @n, 'branch links');
        DELETE FROM dbo.Users WHERE Id IN (SELECT UserId FROM #DelUsers);                                         SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES (@A, 'Users', 'DELETE', @n, 'users with no link to the head office (listed below)');
    END

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
SELECT UserId, Username, FullName, UserType, CASE WHEN @Execute = 1 THEN N'removed' ELSE N'would be removed' END AS [Status]
FROM @Users ORDER BY Username;
PRINT CASE WHEN @Execute = 1 THEN N'=== COMMITTED: only the head-office branch and its users are left ==='
           ELSE N'=== DRY RUN: nothing was changed. The counts show what an executed run would do. ===' END;
