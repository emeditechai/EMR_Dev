-- ============================================================================
-- DataCleanup / 00_install_cleanup_procedures.sql
-- ----------------------------------------------------------------------------
-- Installs the procedures used by the data clean-up scripts in this folder (schema [cleanup]).
-- Run this once before any 01..05 script (and before SQLScripts/19_clear_transaction_data.sql).
-- Remove them again after go-live with 99_remove_cleanup_procedures.sql.
--
-- The procedures never run on their own: each one requires an open transaction and the #CleanupReport table that
-- the runner scripts create, so they only work through a runner, which decides to commit or roll back.
--
-- Scope (every procedure):  @CompanyId / @BranchId
--   both NULL          -> every company and branch (runners demand @AllCompanies = 1 for this)
--   @CompanyId only    -> every branch of that company
--   @BranchId          -> that branch only (of @CompanyId when both are given)
--
-- Areas
--   cleanup.usp_ClearLabTransactions   LAB bills and everything that hangs off them: sample collection, transfers,
--                                       result entry, approval / un-approval, report e-mail / WhatsApp, outsourcing,
--                                       payments, cancellation & refund, B2B invoices & settlement postings, wallet
--                                       debits, ledger postings, LAB audit entries. Franchise barcodes used by a bill
--                                       go back to "available".
--   cleanup.usp_ClearOpdTransactions   OPD bookings / bills: service items, payments, cancellation & refund,
--                                       consultations (EMR), video consultations, doctor disbursal & adjustments,
--                                       vitals, ledger postings, OPD audit entries.
--                                       (2026-10-13: also misc charges, critical value calls, BOM consumption, doctor IP
--                                       commission, membership points of the bills, and every LAB / OPD ledger kind:
--                                       GST, discount, membership discount, round-off, receipt, refund; doctor settlements)
--   cleanup.usp_ClearMembership        Membership cards, members, points ledger, redeem OTPs, WhatsApp log, card-fee
--                                       payments (module MEM) and MEM_* ledger vouchers.
--   cleanup.usp_ClearAccounts          OPD / LAB Day Closing; petty cash floats, expenses (bill scans), closings; manual
--                                       vouchers (bill scans); their ledger vouchers. Counters, ledgers, heads kept.
--   cleanup.usp_ClearQuality           BOM consumption, IQC runs / results, EQAS cycles / results, CAPA, equipment
--                                       breakdowns / calibrations / maintenance (equipment and programmes kept).
--   cleanup.usp_ClearRemainingLedger   Every ledger voucher still left on the branch (only with LAB, OPD, MEMBERSHIP and
--                                       ACCOUNTS), so the books start from the ledger opening balances.
--   cleanup.usp_ClearLabRateLists      Lab rate lists: B2C, Franchise, Corporate (header + detail).
--   cleanup.usp_ClearPatients          Patient Master (OPD > Patient Master) - only patients with no transaction left.
--   cleanup.usp_ClearDoctors           Doctor Master and its set-up (branches, departments, fees, schedules, rooms,
--                                       commission, visit process, Doctor IP) - only doctors with no transaction left.
--   cleanup.usp_ClearFranchises        Lab Franchise Master and its set-up (credit limit, wallet & top-ups, barcode
--                                       series & pool, franchise rate lists) - only franchises with no bill left.
--   cleanup.usp_ClearActivityLogs      Page-view / activity audit entries, e-mail and WhatsApp send logs, bell
--                                       notifications, page-permission decisions, Doctor IP access log.
--                                       Security history (SEC entries, PermissionAuditLog) is kept.
--   cleanup.usp_ResetSequences         Bill, token, receipt, cancellation, barcode, accounts voucher and patient-code counters of a
--                                       branch, reset only when that branch has no document of that kind left.
--
-- Masters and configuration are never touched: company, branches, users & roles, permissions, departments,
-- investigation / profile / reference-range masters, services, settings, IPD masters, ledger masters.
-- Files on disk (prescriptions, OVD / consent documents, patient photos, uploads) are not deleted by SQL; the
-- runners list the file paths of the records they removed.
-- ============================================================================

-- Run in the database to clean (no USE statement on purpose: select the database first).
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF SCHEMA_ID('cleanup') IS NULL EXEC ('CREATE SCHEMA cleanup');
GO

-- ── shared helpers ──────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE cleanup.usp_Guard
AS
BEGIN
    SET NOCOUNT ON;
    IF @@TRANCOUNT = 0
        THROW 50100, 'Run the clean-up procedures only through the DataCleanup scripts: they open the transaction that is committed or rolled back.', 1;
    IF OBJECT_ID('tempdb..#CleanupReport') IS NULL
        THROW 50101, 'The #CleanupReport table of the runner script is missing. Run a DataCleanup script, not the procedure itself.', 1;
END;
GO

CREATE OR ALTER PROCEDURE cleanup.usp_Report
    @Area   NVARCHAR(40),
    @Object NVARCHAR(128),
    @Action VARCHAR(10),
    @Rows   INT,
    @Note   NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO #CleanupReport (Area, ObjectName, Action, RowsAffected, Note) VALUES (@Area, @Object, @Action, @Rows, @Note);
END;
GO

-- Deletes the ledger vouchers listed in the caller's #L (TransactionId), with any voucher that reverses one of them
-- (a cancelled voucher's reversal), and reports the rows.
CREATE OR ALTER PROCEDURE cleanup.usp_DeleteLedger
    @Area NVARCHAR(40),
    @Note NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT;
    WHILE 1 = 1
    BEGIN
        INSERT INTO #L (TransactionId)
        SELECT t.TransactionId FROM dbo.Acc_LedgerTransaction t
        WHERE t.ReversalOfTransactionId IN (SELECT TransactionId FROM #L) AND t.TransactionId NOT IN (SELECT TransactionId FROM #L);
        IF @@ROWCOUNT = 0 BREAK;
    END
    DELETE d FROM dbo.Acc_LedgerTransactionDetail d INNER JOIN #L l ON l.TransactionId = d.TransactionId; SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @Area, 'Acc_LedgerTransactionDetail', 'DELETE', @n, 'ledger lines';
    DELETE t FROM dbo.Acc_LedgerTransaction t INNER JOIN #L l ON l.TransactionId = t.TransactionId;      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @Area, 'Acc_LedgerTransaction', 'DELETE', @n, @Note;
END;
GO

-- Membership points of the cards in the caller's #MC: card balance = the sum of its ledger points; what is left of
-- each earning (RemainingPoints) is worked out again, oldest earning used first.
CREATE OR ALTER PROCEDURE cleanup.usp_RecalcMembershipPoints
    @Area NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT;
    ;WITH e AS (SELECT l.LedgerId, l.CardId, l.Points,
                       SUM(l.Points) OVER (PARTITION BY l.CardId ORDER BY l.CreatedDate, l.LedgerId ROWS UNBOUNDED PRECEDING) AS Cum
                FROM dbo.MembershipLedger l INNER JOIN #MC m ON m.CardId = l.CardId WHERE l.Points > 0),
          u AS (SELECT l.CardId, -SUM(l.Points) AS Used FROM dbo.MembershipLedger l INNER JOIN #MC m ON m.CardId = l.CardId
                WHERE l.Points < 0 GROUP BY l.CardId)
    UPDATE l SET l.RemainingPoints = CASE WHEN e.Cum - ISNULL(u.Used, 0) >= e.Points THEN e.Points
                                          WHEN e.Cum - ISNULL(u.Used, 0) <= 0 THEN 0 ELSE e.Cum - ISNULL(u.Used, 0) END
    FROM dbo.MembershipLedger l INNER JOIN e ON e.LedgerId = l.LedgerId LEFT JOIN u ON u.CardId = e.CardId;
    UPDATE c SET c.PointsBalance = ISNULL((SELECT SUM(l.Points) FROM dbo.MembershipLedger l WHERE l.CardId = c.CardId), 0)
    FROM dbo.MembershipCard c INNER JOIN #MC m ON m.CardId = c.CardId;                                SET @n = @@ROWCOUNT;
    IF @n > 0 EXEC cleanup.usp_Report @Area, 'MembershipCard', 'UPDATE', @n, 'points balances recalculated from the remaining points entries';
END;
GO

-- Branches in scope.
CREATE OR ALTER FUNCTION cleanup.ufn_ScopeBranches (@CompanyId INT, @BranchId INT)
RETURNS TABLE
AS RETURN
    SELECT b.BranchID AS BranchId, b.CompanyId
    FROM dbo.Branchmaster b
    WHERE (@CompanyId IS NULL OR b.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR b.BranchID = @BranchId);
GO

-- ============================================================================
-- LAB transactions
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearLabTransactions
    @CompanyId      INT = NULL,
    @BranchId       INT = NULL,
    @ClearAuditLogs BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'LAB transactions';
    DECLARE @WholeCompany BIT = CASE WHEN @BranchId IS NULL THEN 1 ELSE 0 END;

    CREATE TABLE #B (BranchId INT PRIMARY KEY, CompanyId INT);
    INSERT INTO #B SELECT BranchId, CompanyId FROM cleanup.ufn_ScopeBranches(@CompanyId, @BranchId);

    -- the bills in scope (a bill belongs to its billing branch, also when samples were transferred elsewhere)
    CREATE TABLE #O (LabOrderId INT PRIMARY KEY);
    INSERT INTO #O SELECT lo.LabOrderId FROM dbo.LabOrder lo INNER JOIN #B b ON b.BranchId = lo.BranchId;

    -- files referenced by these bills (listed by the runner; not deleted by SQL)
    IF OBJECT_ID('tempdb..#CleanupFiles') IS NOT NULL
        INSERT INTO #CleanupFiles (Area, FilePath)
        SELECT @A, v.FilePath FROM dbo.LabOrder lo INNER JOIN #O o ON o.LabOrderId = lo.LabOrderId
        CROSS APPLY (VALUES (lo.PrescriptionFilePath), (lo.OVDDocumentFilePath), (lo.ConsentFilePath)) v(FilePath)
        WHERE NULLIF(LTRIM(RTRIM(v.FilePath)), '') IS NOT NULL;

    -- result entry, approval and report delivery
    DELETE l FROM dbo.labentrydetails l INNER JOIN #O o ON o.LabOrderId = l.LabOrderId;              SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'labentrydetails', 'DELETE', @n, 'result entry';
    DELETE l FROM dbo.labentrydetails l WHERE EXISTS (SELECT 1 FROM dbo.SampleCollection sc INNER JOIN #O o ON o.LabOrderId = sc.Laborderid WHERE sc.samplecollectionID = l.SamplecollectionID);
                                                                                                       SET @n = @@ROWCOUNT; IF @n > 0 EXEC cleanup.usp_Report @A, 'labentrydetails', 'DELETE', @n, 'result entry linked by sample';
    DELETE x FROM dbo.LabReportApproval x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;            SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabReportApproval', 'DELETE', @n, 'pathologist sign-off levels';
    DELETE x FROM dbo.LabReportUnapproval x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;          SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabReportUnapproval', 'DELETE', @n, 'un-authorize history';
    DELETE x FROM dbo.LabReportTestRemarks x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;         SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabReportTestRemarks', 'DELETE', @n, 'lab remarks';
    DELETE x FROM dbo.LabReportEmailLog x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;            SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabReportEmailLog', 'DELETE', @n, 'report e-mails';
    DELETE x FROM dbo.LabReportWhatsAppLog x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;         SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabReportWhatsAppLog', 'DELETE', @n, 'report WhatsApp';

    -- sample collection, transfer, outsourcing
    DELETE x FROM dbo.LabSampleStatusLog x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabSampleStatusLog', 'DELETE', @n, 'sample status history';
    IF OBJECT_ID('dbo.LabOutsourceTracking', 'U') IS NOT NULL
    BEGIN
        DELETE x FROM dbo.LabOutsourceTracking x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;     SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabOutsourceTracking', 'DELETE', @n, 'outsourced tests sent / received';
    END
    DELETE x FROM dbo.SampleTransferAudit x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;          SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'SampleTransferAudit', 'DELETE', @n, 'branch transfer / receipt history';
    UPDATE bp SET bp.Status = 1, bp.LabOrderId = NULL, bp.SamplecollectionID = NULL, bp.InvestigationId = NULL, bp.UsedDate = NULL, bp.UsedBy = NULL
    FROM dbo.LabFranchiseBarcodePool bp INNER JOIN #O o ON o.LabOrderId = bp.LabOrderId
    WHERE bp.Status = 2;                                                                               SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabFranchiseBarcodePool', 'UPDATE', @n, 'pre-printed barcodes used by these bills made available again';
    DELETE sc FROM dbo.SampleCollection sc INNER JOIN #O o ON o.LabOrderId = sc.Laborderid;          SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'SampleCollection', 'DELETE', @n, 'Sample Collection';

    -- B2B invoices and settlement: an invoice of the branch, or one that carries a cleared bill, is removed whole
    -- (its other bills, if any, simply become un-invoiced again)
    CREATE TABLE #I (InvoiceId INT PRIMARY KEY);
    INSERT INTO #I SELECT i.InvoiceId FROM dbo.B2BInvoice i
    WHERE i.BranchId IN (SELECT BranchId FROM #B)
       OR EXISTS (SELECT 1 FROM dbo.B2BInvoiceItem ii INNER JOIN #O o ON o.LabOrderId = ii.LabOrderId WHERE ii.InvoiceId = i.InvoiceId);
    SELECT @n = COUNT(1) FROM dbo.B2BInvoiceItem ii INNER JOIN #I i ON i.InvoiceId = ii.InvoiceId
    WHERE ii.LabOrderId NOT IN (SELECT LabOrderId FROM #O);
    IF @n > 0 EXEC cleanup.usp_Report @A, 'B2BInvoiceItem', 'KEPT', @n, 'bills of other branches on these invoices stay, un-invoiced';
    DELETE ii FROM dbo.B2BInvoiceItem ii INNER JOIN #I i ON i.InvoiceId = ii.InvoiceId;              SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'B2BInvoiceItem', 'DELETE', @n, 'B2B invoice lines';
    DELETE ii FROM dbo.B2BInvoiceItem ii INNER JOIN #O o ON o.LabOrderId = ii.LabOrderId;            SET @n = @@ROWCOUNT; IF @n > 0 EXEC cleanup.usp_Report @A, 'B2BInvoiceItem', 'DELETE', @n, 'other invoice lines of these bills';
    DELETE i FROM dbo.B2BInvoice i INNER JOIN #I x ON x.InvoiceId = i.InvoiceId;                     SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'B2BInvoice', 'DELETE', @n, 'B2B Invoices / settlement status';

    -- payments (B2C collection, B2B settlement receipts)
    CREATE TABLE #P (PaymentHeaderId INT PRIMARY KEY);
    INSERT INTO #P SELECT ph.PaymentHeaderId FROM dbo.PaymentHeader ph
    WHERE ph.ModuleCode = 'LAB' AND (ph.ModuleRefId IN (SELECT LabOrderId FROM #O) OR ph.BranchId IN (SELECT BranchId FROM #B));

    -- membership points earned / redeemed on these bills (the cards stay; their balances are worked out again)
    CREATE TABLE #MC (CardId INT PRIMARY KEY);
    INSERT INTO #MC SELECT DISTINCT l.CardId FROM dbo.MembershipLedger l INNER JOIN #P p ON p.PaymentHeaderId = l.PaymentHeaderId;
    DELETE x FROM dbo.MembershipPointsWhatsAppLog x INNER JOIN #P p ON p.PaymentHeaderId = x.PaymentHeaderId; SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'MembershipPointsWhatsAppLog', 'DELETE', @n, 'points WhatsApp messages of these bills';
    DELETE x FROM dbo.MembershipRedeemOtp x INNER JOIN #P p ON p.PaymentHeaderId = x.UsedPaymentHeaderId;    SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'MembershipRedeemOtp', 'DELETE', @n, 'redeem OTPs used on these bills';
    DELETE x FROM dbo.MembershipLedger x INNER JOIN #P p ON p.PaymentHeaderId = x.PaymentHeaderId;           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'MembershipLedger', 'DELETE', @n, 'points earned / redeemed on these bills';
    EXEC cleanup.usp_RecalcMembershipPoints @A;

    DELETE d FROM dbo.PaymentDetail d INNER JOIN #P p ON p.PaymentHeaderId = d.PaymentHeaderId;      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PaymentDetail', 'DELETE', @n, 'money receipts';
    DELETE l FROM dbo.PaymentLineItem l INNER JOIN #P p ON p.PaymentHeaderId = l.PaymentHeaderId;    SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PaymentLineItem', 'DELETE', @n, 'bill lines';
    DELETE h FROM dbo.PaymentHeader h INNER JOIN #P p ON p.PaymentHeaderId = h.PaymentHeaderId;      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PaymentHeader', 'DELETE', @n, 'bill payment headers';

    -- cancellation & refund
    CREATE TABLE #C (CancellationId INT PRIMARY KEY);
    INSERT INTO #C SELECT bc.CancellationId FROM dbo.BillCancellation bc WHERE bc.ModuleCode = 'LAB' AND bc.ModuleRefId IN (SELECT LabOrderId FROM #O);
    DELETE r FROM dbo.BillRefund r INNER JOIN #C c ON c.CancellationId = r.CancellationId;           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'BillRefund', 'DELETE', @n, 'refunds';
    DELETE i FROM dbo.BillCancellationItem i INNER JOIN #C c ON c.CancellationId = i.CancellationId; SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'BillCancellationItem', 'DELETE', @n, 'cancelled lines';
    DELETE bc FROM dbo.BillCancellation bc INNER JOIN #C c ON c.CancellationId = bc.CancellationId;  SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'BillCancellation', 'DELETE', @n, 'Bill Cancellation (LAB)';

    -- franchise wallet: the debits of these bills; top-ups only when the whole company is cleared (a top-up has no branch)
    CREATE TABLE #F (Franchise_ID INT PRIMARY KEY);
    INSERT INTO #F SELECT f.Franchise_ID FROM dbo.LabFranchiseMaster f WHERE f.CompanyId IN (SELECT DISTINCT CompanyId FROM #B);
    DELETE w FROM dbo.LabFranchiseWalletTransaction w
    WHERE w.ReferenceType = 'LAB_BILL' AND w.ReferenceId IN (SELECT LabOrderId FROM #O);              SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabFranchiseWalletTransaction', 'DELETE', @n, 'wallet debits of these bills';
    IF @WholeCompany = 1
    BEGIN
        DELETE w FROM dbo.LabFranchiseWalletTransaction w INNER JOIN #F f ON f.Franchise_ID = w.Franchise_ID;
                                                                                                       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabFranchiseWalletTransaction', 'DELETE', @n, 'wallet top-ups of the company''s franchises';
    END
    -- balances follow what is left
    ;WITH r AS (SELECT w.TransactionId,
                       SUM(CASE WHEN w.TransactionType = 'CREDIT' THEN w.Amount ELSE -w.Amount END)
                           OVER (PARTITION BY w.Franchise_ID ORDER BY w.CreatedDate, w.TransactionId ROWS UNBOUNDED PRECEDING) AS Running
                FROM dbo.LabFranchiseWalletTransaction w INNER JOIN #F f ON f.Franchise_ID = w.Franchise_ID)
    UPDATE w SET w.BalanceAfter = r.Running FROM dbo.LabFranchiseWalletTransaction w INNER JOIN r ON r.TransactionId = w.TransactionId;
    UPDATE wl SET wl.CurrentBalance = ISNULL((SELECT SUM(CASE WHEN t.TransactionType = 'CREDIT' THEN t.Amount ELSE -t.Amount END)
                                              FROM dbo.LabFranchiseWalletTransaction t WHERE t.Franchise_ID = wl.Franchise_ID), 0),
                  wl.LastUpdatedDate = GETDATE()
    FROM dbo.LabFranchiseWallet wl INNER JOIN #F f ON f.Franchise_ID = wl.Franchise_ID;              SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabFranchiseWallet', 'UPDATE', @n, 'wallet balances recalculated from the remaining transactions';

    -- ledger postings
    -- every LAB kind of the branch: bill, GST, discount, membership discount, round-off, receipt, cancellation, refund;
    -- B2B bill / wallet payment / settlement; membership points earned or reversed on LAB bills (MEM_EARN, MEM_REVERSE)
    CREATE TABLE #L (TransactionId BIGINT PRIMARY KEY);
    INSERT INTO #L SELECT t.TransactionId FROM dbo.Acc_LedgerTransaction t
    WHERE (t.ReferenceType IN ('LAB_BILL', 'B2B_LAB_BILL', 'B2B_WALLET_PAY', 'LAB_CANCEL') AND t.ReferenceId IN (SELECT LabOrderId FROM #O))
       OR (t.BranchId IN (SELECT BranchId FROM #B)
           AND (t.ReferenceType LIKE 'LAB[_]%' OR t.ReferenceType IN ('B2B_LAB_BILL', 'B2B_WALLET_PAY', 'B2B_SETTLEMENT', 'MEM_EARN', 'MEM_REVERSE')))
       OR (@WholeCompany = 1 AND t.ReferenceType = 'B2B_WALLET_TOPUP' AND t.ReferenceId IN (SELECT Franchise_ID FROM #F));
    EXEC cleanup.usp_DeleteLedger @A, N'ledger vouchers (LAB bill, GST, discount, round-off, receipt, cancel, refund; B2B bill / wallet / settlement; points earned)';

    -- messages and audit entries of these bills
    DELETE w FROM dbo.WhatsAppLog w WHERE w.ModuleCode IN ('LAB', 'LABREPORT')
      AND (w.ModuleRefId IN (SELECT LabOrderId FROM #O) OR w.BranchId IN (SELECT BranchId FROM #B));  SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'WhatsAppLog', 'DELETE', @n, 'LAB WhatsApp messages';
    IF @ClearAuditLogs = 1
    BEGIN
        DELETE a FROM dbo.AuditLogs a WHERE a.ModuleCode = 'LAB' AND a.ReferenceId IN (SELECT LabOrderId FROM #O);
                                                                                                       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'AuditLogs', 'DELETE', @n, 'LAB audit entries of these bills';
    END

    -- critical value calls, reagent consumption (BOM) and referring-doctor (IP) commission worked out on these bills
    DELETE x FROM dbo.LabCriticalCommunication x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;     SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabCriticalCommunication', 'DELETE', @n, 'critical value communication';
    DELETE x FROM dbo.QcConsumptionLine x WHERE x.ConsumptionId IN (SELECT c.ConsumptionId FROM dbo.QcConsumption c INNER JOIN #O o ON o.LabOrderId = c.LabOrderId);
                                                                                                       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'QcConsumptionLine', 'DELETE', @n, 'reagent / consumable lines used by these tests';
    DELETE x FROM dbo.QcConsumption x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;                SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'QcConsumption', 'DELETE', @n, 'BOM consumption of these tests';
    DELETE x FROM dbo.QcConsumptionLog x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;             SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'QcConsumptionLog', 'DELETE', @n, 'BOM consumption errors';
    DELETE x FROM dbo.Doctor_IP_Commission_Dtl x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;     SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Doctor_IP_Commission_Dtl', 'DELETE', @n, 'doctor IP commission lines of these bills';
    DELETE h FROM dbo.Doctor_IP_Commission_Hdr h
    WHERE h.Branch_ID IN (SELECT BranchId FROM #B) AND NOT EXISTS (SELECT 1 FROM dbo.Doctor_IP_Commission_Dtl d WHERE d.Commission_Hdr_ID = h.Commission_Hdr_ID);
                                                                                                       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Doctor_IP_Commission_Hdr', 'DELETE', @n, 'doctor IP commission runs left without lines';
    DELETE x FROM dbo.Doctor_IP_Commission_RunLog x WHERE x.Branch_ID IN (SELECT BranchId FROM #B);  SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Doctor_IP_Commission_RunLog', 'DELETE', @n, 'doctor IP commission run log';
    DELETE x FROM dbo.UserNotification x WHERE x.RefModule = 'LAB' AND x.RefId IN (SELECT LabOrderId FROM #O);
                                                                                                       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'UserNotification', 'DELETE', @n, 'bell notifications about these bills';

    -- the bills
    DELETE x FROM dbo.LabOrderMiscCharge x INNER JOIN #O o ON o.LabOrderId = x.LabOrderId;           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabOrderMiscCharge', 'DELETE', @n, 'misc charges on the bills';
    DELETE i FROM dbo.LabOrderItem i INNER JOIN #O o ON o.LabOrderId = i.LabOrderId;                 SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabOrderItem', 'DELETE', @n, 'billed tests';
    DELETE lo FROM dbo.LabOrder lo INNER JOIN #O o ON o.LabOrderId = lo.LabOrderId;                  SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabOrder', 'DELETE', @n, 'B2C / B2B LAB bills';
END;
GO

-- ============================================================================
-- OPD transactions
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearOpdTransactions
    @CompanyId      INT = NULL,
    @BranchId       INT = NULL,
    @ClearAuditLogs BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'OPD transactions';

    CREATE TABLE #B (BranchId INT PRIMARY KEY, CompanyId INT);
    INSERT INTO #B SELECT BranchId, CompanyId FROM cleanup.ufn_ScopeBranches(@CompanyId, @BranchId);

    CREATE TABLE #S (OPDServiceId INT PRIMARY KEY);
    INSERT INTO #S SELECT s.OPDServiceId FROM dbo.PatientOPDService s INNER JOIN #B b ON b.BranchId = s.BranchId;

    DELETE x FROM dbo.PatientOPDServiceItem x INNER JOIN #S s ON s.OPDServiceId = x.OPDServiceId;     SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PatientOPDServiceItem', 'DELETE', @n, 'booked services';
    DELETE x FROM dbo.OPDTokenStatusLog x INNER JOIN #S s ON s.OPDServiceId = x.OPDServiceId;         SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'OPDTokenStatusLog', 'DELETE', @n, 'token status history';
    DELETE x FROM dbo.EmrPatientConsultation x INNER JOIN #S s ON s.OPDServiceId = x.OPDServiceId;    SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'EmrPatientConsultation', 'DELETE', @n, 'doctor consultations (EMR)';
    DELETE x FROM dbo.tbl_VideoConsultation x INNER JOIN #S s ON s.OPDServiceId = x.OPDServiceId;     SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'tbl_VideoConsultation', 'DELETE', @n, 'video consultations';

    -- doctor payouts of these visits
    DELETE x FROM dbo.DoctorBillingAdjustment x
    WHERE x.VisitId IN (SELECT OPDServiceId FROM #S) OR x.BranchId IN (SELECT BranchId FROM #B)
       OR x.DisbursalId IN (SELECT d.DisbursalId FROM dbo.DoctorDisbursal d WHERE d.VisitId IN (SELECT OPDServiceId FROM #S) OR d.BranchId IN (SELECT BranchId FROM #B));
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorBillingAdjustment', 'DELETE', @n, 'doctor bill adjustments';
    DELETE x FROM dbo.DoctorDisbursal x WHERE x.VisitId IN (SELECT OPDServiceId FROM #S) OR x.BranchId IN (SELECT BranchId FROM #B);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorDisbursal', 'DELETE', @n, 'doctor disbursal';
    DELETE x FROM dbo.DoctorSettlement x WHERE x.BranchId IN (SELECT BranchId FROM #B);               SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorSettlement', 'DELETE', @n, 'doctor settlements / payout vouchers of the branch';

    -- payments: OPD payments only. A payment of another module that points at one of these visits (OPDServiceId)
    -- keeps its record and loses only that link.
    UPDATE ph SET ph.OPDServiceId = NULL FROM dbo.PaymentHeader ph
    WHERE ph.ModuleCode <> 'OPD' AND ph.OPDServiceId IN (SELECT OPDServiceId FROM #S);                SET @n = @@ROWCOUNT; IF @n > 0 EXEC cleanup.usp_Report @A, 'PaymentHeader', 'UPDATE', @n, 'LAB payments linked to these visits kept; only the visit link removed';
    CREATE TABLE #P (PaymentHeaderId INT PRIMARY KEY);
    INSERT INTO #P SELECT ph.PaymentHeaderId FROM dbo.PaymentHeader ph
    WHERE ph.ModuleCode = 'OPD'
      AND (ph.ModuleRefId IN (SELECT OPDServiceId FROM #S) OR ph.OPDServiceId IN (SELECT OPDServiceId FROM #S) OR ph.BranchId IN (SELECT BranchId FROM #B));
    DELETE d FROM dbo.PaymentDetail d INNER JOIN #P p ON p.PaymentHeaderId = d.PaymentHeaderId;       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PaymentDetail', 'DELETE', @n, 'money receipts';
    DELETE l FROM dbo.PaymentLineItem l INNER JOIN #P p ON p.PaymentHeaderId = l.PaymentHeaderId;     SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PaymentLineItem', 'DELETE', @n, 'bill lines';
    DELETE h FROM dbo.PaymentHeader h INNER JOIN #P p ON p.PaymentHeaderId = h.PaymentHeaderId;       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PaymentHeader', 'DELETE', @n, 'bill payment headers';

    -- cancellation & refund
    CREATE TABLE #C (CancellationId INT PRIMARY KEY);
    INSERT INTO #C SELECT bc.CancellationId FROM dbo.BillCancellation bc WHERE bc.ModuleCode = 'OPD' AND bc.ModuleRefId IN (SELECT OPDServiceId FROM #S);
    DELETE r FROM dbo.BillRefund r INNER JOIN #C c ON c.CancellationId = r.CancellationId;            SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'BillRefund', 'DELETE', @n, 'refunds';
    DELETE i FROM dbo.BillCancellationItem i INNER JOIN #C c ON c.CancellationId = i.CancellationId;  SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'BillCancellationItem', 'DELETE', @n, 'cancelled lines';
    DELETE bc FROM dbo.BillCancellation bc INNER JOIN #C c ON c.CancellationId = bc.CancellationId;   SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'BillCancellation', 'DELETE', @n, 'Bill Cancellation (OPD)';

    -- ledger postings
    -- every OPD kind of the branch: bill, discount, round-off, receipt, cancellation, refund
    CREATE TABLE #L (TransactionId BIGINT PRIMARY KEY);
    INSERT INTO #L SELECT t.TransactionId FROM dbo.Acc_LedgerTransaction t
    WHERE (t.ReferenceType IN ('OPD_BILL', 'OPD_CANCEL') AND t.ReferenceId IN (SELECT OPDServiceId FROM #S))
       OR (t.ReferenceType LIKE 'OPD[_]%' AND t.BranchId IN (SELECT BranchId FROM #B));
    EXEC cleanup.usp_DeleteLedger @A, N'ledger vouchers (OPD bill, discount, round-off, receipt, cancel, refund)';
    DELETE x FROM dbo.UserNotification x WHERE x.RefModule = 'OPD' AND x.RefId IN (SELECT OPDServiceId FROM #S);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'UserNotification', 'DELETE', @n, 'bell notifications about these bills';

    -- vitals: recorded against the patient (no branch on the record) - those of patients of the branches in scope
    DELETE v FROM dbo.PatientVitals v
    WHERE v.PatientId IN (SELECT p.PatientId FROM dbo.PatientMaster p WHERE p.BranchId IN (SELECT BranchId FROM #B))
       OR (@BranchId IS NULL AND (@CompanyId IS NULL OR v.CompanyId = @CompanyId));                    SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PatientVitals', 'DELETE', @n, 'vitals';

    DELETE w FROM dbo.WhatsAppLog w WHERE w.ModuleCode IN ('OPD', 'VIDEO')
      AND (w.ModuleRefId IN (SELECT OPDServiceId FROM #S) OR w.BranchId IN (SELECT BranchId FROM #B));   SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'WhatsAppLog', 'DELETE', @n, 'OPD / video WhatsApp messages';
    IF @ClearAuditLogs = 1
    BEGIN
        DELETE a FROM dbo.AuditLogs a WHERE a.ModuleCode = 'OPD' AND a.ReferenceId IN (SELECT OPDServiceId FROM #S);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'AuditLogs', 'DELETE', @n, 'OPD audit entries of these bills';
    END

    DELETE s FROM dbo.PatientOPDService s INNER JOIN #S x ON x.OPDServiceId = s.OPDServiceId;         SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PatientOPDService', 'DELETE', @n, 'OPD bookings / bills';
END;
GO

-- ============================================================================
-- Semi-transaction: lab rate lists (B2C / Franchise / Corporate)
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearLabRateLists
    @CompanyId INT = NULL,
    @BranchId  INT = NULL,
    @RateTypes NVARCHAR(100) = N'B2C,Franchise,Corporate'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'Lab rate lists';

    CREATE TABLE #R (RateCard_ID INT PRIMARY KEY);
    INSERT INTO #R SELECT rc.RateCard_ID FROM dbo.LabRateCardMaster rc
    WHERE rc.Rate_Type IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@RateTypes, ','))
      AND (@CompanyId IS NULL OR rc.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR rc.Branch_ID = @BranchId);

    DELETE d FROM dbo.LabRateCardDetail d INNER JOIN #R r ON r.RateCard_ID = d.RateCard_ID;           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabRateCardDetail', 'DELETE', @n, 'test / profile rates';
    DELETE rc FROM dbo.LabRateCardMaster rc INNER JOIN #R r ON r.RateCard_ID = rc.RateCard_ID;        SET @n = @@ROWCOUNT; DECLARE @note NVARCHAR(200) = N'rate lists: ' + @RateTypes; EXEC cleanup.usp_Report @A, 'LabRateCardMaster', 'DELETE', @n, @note;
END;
GO

-- ============================================================================
-- Semi-transaction: Patient Master - only patients with nothing left that refers to them
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearPatients
    @CompanyId INT = NULL,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'Patients';

    CREATE TABLE #Pt (PatientId INT PRIMARY KEY);
    INSERT INTO #Pt SELECT p.PatientId FROM dbo.PatientMaster p
    WHERE (@CompanyId IS NULL OR p.CompanyId = @CompanyId OR p.BranchId IN (SELECT BranchId FROM cleanup.ufn_ScopeBranches(@CompanyId, NULL)))
      AND (@BranchId IS NULL OR p.BranchId = @BranchId);

    -- a patient with a bill of another branch / company (or any other record) is kept
    CREATE TABLE #Keep (PatientId INT PRIMARY KEY);
    INSERT INTO #Keep SELECT pt.PatientId FROM #Pt pt
    WHERE EXISTS (SELECT 1 FROM dbo.LabOrder x WHERE x.PatientId = pt.PatientId)
       OR EXISTS (SELECT 1 FROM dbo.PatientOPDService x WHERE x.PatientId = pt.PatientId)
       OR EXISTS (SELECT 1 FROM dbo.PaymentHeader x WHERE x.PatientId = pt.PatientId)
       OR EXISTS (SELECT 1 FROM dbo.SampleCollection x WHERE x.PatientID = pt.PatientId)
       OR EXISTS (SELECT 1 FROM dbo.EmrPatientConsultation x WHERE x.PatientId = pt.PatientId)
       OR EXISTS (SELECT 1 FROM dbo.tbl_VideoConsultation x WHERE x.PatientId = pt.PatientId)
       OR EXISTS (SELECT 1 FROM dbo.MembershipCard x WHERE x.PrimaryPatientId = pt.PatientId)
       OR EXISTS (SELECT 1 FROM dbo.MembershipCardMember x WHERE x.PatientId = pt.PatientId);
    DELETE pt FROM #Pt pt INNER JOIN #Keep k ON k.PatientId = pt.PatientId;
    SELECT @n = COUNT(1) FROM #Keep;
    IF @n > 0 EXEC cleanup.usp_Report @A, 'PatientMaster', 'KEPT', @n, 'still have bills / bookings / a membership card (of another branch, or not cleared)';

    IF OBJECT_ID('tempdb..#CleanupFiles') IS NOT NULL
        INSERT INTO #CleanupFiles (Area, FilePath)
        SELECT @A, v.FilePath FROM dbo.PatientMaster p INNER JOIN #Pt pt ON pt.PatientId = p.PatientId
        CROSS APPLY (VALUES (p.PhotoPath), (p.IdentificationFilePath)) v(FilePath)
        WHERE NULLIF(LTRIM(RTRIM(v.FilePath)), '') IS NOT NULL;

    DELETE v FROM dbo.PatientVitals v INNER JOIN #Pt pt ON pt.PatientId = v.PatientId;                SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PatientVitals', 'DELETE', @n, 'vitals';
    DELETE p FROM dbo.PatientMaster p INNER JOIN #Pt pt ON pt.PatientId = p.PatientId;                SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PatientMaster', 'DELETE', @n, 'OPD > Patient Master';
END;
GO

-- ============================================================================
-- Semi-master: Doctor Master - only doctors no remaining transaction refers to
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearDoctors
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'Doctors';

    CREATE TABLE #D (DoctorId INT PRIMARY KEY);
    INSERT INTO #D SELECT d.DoctorId FROM dbo.DoctorMaster d WHERE @CompanyId IS NULL OR d.CompanyId = @CompanyId;

    CREATE TABLE #Keep (DoctorId INT PRIMARY KEY);
    INSERT INTO #Keep SELECT d.DoctorId FROM #D d
    WHERE EXISTS (SELECT 1 FROM dbo.LabOrder x WHERE x.RefDoctorId = d.DoctorId)
       OR EXISTS (SELECT 1 FROM dbo.PatientOPDService x WHERE x.ConsultingDoctorId = d.DoctorId)
       OR EXISTS (SELECT 1 FROM dbo.EmrPatientConsultation x WHERE x.DoctorId = d.DoctorId)
       OR EXISTS (SELECT 1 FROM dbo.tbl_VideoConsultation x WHERE x.DoctorId = d.DoctorId)
       OR EXISTS (SELECT 1 FROM dbo.DoctorDisbursal x WHERE x.DoctorId = d.DoctorId)
       OR EXISTS (SELECT 1 FROM dbo.DoctorBillingAdjustment x WHERE x.DoctorId = d.DoctorId);
    DELETE d FROM #D d INNER JOIN #Keep k ON k.DoctorId = d.DoctorId;
    SELECT @n = COUNT(1) FROM #Keep;
    IF @n > 0 EXEC cleanup.usp_Report @A, 'DoctorMaster', 'KEPT', @n, 'still referred to by LAB / OPD transactions of another company or not cleared';

    DELETE x FROM dbo.Doctor_IP_Dtl x WHERE x.Doctor_IP_Hdr_ID IN (SELECT h.Doctor_IP_Hdr_ID FROM dbo.Doctor_IP_Hdr h INNER JOIN #D d ON d.DoctorId = h.Doctor_ID);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Doctor_IP_Dtl', 'DELETE', @n, 'Doctor IP lines';
    DELETE h FROM dbo.Doctor_IP_Hdr h INNER JOIN #D d ON d.DoctorId = h.Doctor_ID;                    SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Doctor_IP_Hdr', 'DELETE', @n, 'Doctor IP';
    DELETE x FROM dbo.DoctorVisitProcessConfig x INNER JOIN #D d ON d.DoctorId = x.DoctorId;          SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorVisitProcessConfig', 'DELETE', @n, 'visit process';
    DELETE x FROM dbo.DoctorCommissionConfig x INNER JOIN #D d ON d.DoctorId = x.DoctorId;            SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorCommissionConfig', 'DELETE', @n, 'commission set-up';
    DELETE x FROM dbo.DoctorRoomMapping x INNER JOIN #D d ON d.DoctorId = x.DoctorId;                 SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorRoomMapping', 'DELETE', @n, 'room assignment';
    DELETE x FROM dbo.DoctorScheduleException x INNER JOIN #D d ON d.DoctorId = x.DoctorId;           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorScheduleException', 'DELETE', @n, 'schedule exceptions';
    DELETE x FROM dbo.DoctorScheduleMaster x INNER JOIN #D d ON d.DoctorId = x.DoctorId;              SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorScheduleMaster', 'DELETE', @n, 'schedules';
    DELETE x FROM dbo.DoctorConsultingFeeMap x INNER JOIN #D d ON d.DoctorId = x.DoctorId;            SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorConsultingFeeMap', 'DELETE', @n, 'consulting fees';
    DELETE x FROM dbo.DoctorDepartmentMap x INNER JOIN #D d ON d.DoctorId = x.DoctorId;               SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorDepartmentMap', 'DELETE', @n, 'departments';
    DELETE x FROM dbo.DoctorBranchMap x INNER JOIN #D d ON d.DoctorId = x.DoctorId;                   SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorBranchMap', 'DELETE', @n, 'branches';
    UPDATE cu SET cu.ConsultantInChargeDoctorId = NULL FROM dbo.ClinicalUnitMaster cu INNER JOIN #D d ON d.DoctorId = cu.ConsultantInChargeDoctorId;
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'ClinicalUnitMaster', 'UPDATE', @n, 'consultant in charge cleared (clinical unit kept)';
    SELECT @n = COUNT(1) FROM dbo.DoctorMaster dm INNER JOIN #D d ON d.DoctorId = dm.DoctorId WHERE dm.LinkedUserId IS NOT NULL;
    IF @n > 0 EXEC cleanup.usp_Report @A, 'Users', 'KEPT', @n, 'login users linked to these doctors are kept (deactivate them in User Master if not needed)';
    DELETE dm FROM dbo.DoctorMaster dm INNER JOIN #D d ON d.DoctorId = dm.DoctorId;                   SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorMaster', 'DELETE', @n, 'Master > Doctors';
END;
GO

-- ============================================================================
-- Semi-master: Lab Franchise Master - only franchises with no bill or invoice left
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearFranchises
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'Franchises';

    CREATE TABLE #F (Franchise_ID INT PRIMARY KEY);
    INSERT INTO #F SELECT f.Franchise_ID FROM dbo.LabFranchiseMaster f WHERE @CompanyId IS NULL OR f.CompanyId = @CompanyId;

    CREATE TABLE #Keep (Franchise_ID INT PRIMARY KEY);
    INSERT INTO #Keep SELECT f.Franchise_ID FROM #F f
    WHERE EXISTS (SELECT 1 FROM dbo.LabOrder x WHERE x.AgentType = 'F' AND x.B2BAgentID = f.Franchise_ID)
       OR EXISTS (SELECT 1 FROM dbo.B2BInvoice x WHERE x.PartnerType = 'F' AND x.PartnerId = f.Franchise_ID);
    DELETE f FROM #F f INNER JOIN #Keep k ON k.Franchise_ID = f.Franchise_ID;
    SELECT @n = COUNT(1) FROM #Keep;
    IF @n > 0 EXEC cleanup.usp_Report @A, 'LabFranchiseMaster', 'KEPT', @n, 'still have B2B bills / invoices (clear LAB transactions first)';

    -- ledger postings of their wallet top-ups
    CREATE TABLE #L (TransactionId BIGINT PRIMARY KEY);
    INSERT INTO #L SELECT t.TransactionId FROM dbo.Acc_LedgerTransaction t
    WHERE t.ReferenceType = 'B2B_WALLET_TOPUP' AND t.ReferenceId IN (SELECT Franchise_ID FROM #F);
    DELETE d FROM dbo.Acc_LedgerTransactionDetail d INNER JOIN #L l ON l.TransactionId = d.TransactionId; SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Acc_LedgerTransactionDetail', 'DELETE', @n, 'wallet top-up ledger lines';
    DELETE t FROM dbo.Acc_LedgerTransaction t INNER JOIN #L l ON l.TransactionId = t.TransactionId;   SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Acc_LedgerTransaction', 'DELETE', @n, 'wallet top-up vouchers';

    DELETE x FROM dbo.LabFranchiseWalletTransaction x INNER JOIN #F f ON f.Franchise_ID = x.Franchise_ID; SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabFranchiseWalletTransaction', 'DELETE', @n, 'wallet transactions';
    DELETE x FROM dbo.LabFranchiseWallet x INNER JOIN #F f ON f.Franchise_ID = x.Franchise_ID;        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabFranchiseWallet', 'DELETE', @n, 'wallets';
    DELETE x FROM dbo.LabFranchiseCreditLimitMaster x INNER JOIN #F f ON f.Franchise_ID = x.Franchise_ID; SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabFranchiseCreditLimitMaster', 'DELETE', @n, 'credit limits';
    DELETE x FROM dbo.LabFranchiseBarcodePool x INNER JOIN #F f ON f.Franchise_ID = x.Franchise_ID;   SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabFranchiseBarcodePool', 'DELETE', @n, 'pre-printed barcodes';
    DELETE x FROM dbo.LabFranchiseBarcodeSeries x INNER JOIN #F f ON f.Franchise_ID = x.Franchise_ID; SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabFranchiseBarcodeSeries', 'DELETE', @n, 'barcode series';
    DELETE d FROM dbo.LabRateCardDetail d INNER JOIN dbo.LabRateCardMaster rc ON rc.RateCard_ID = d.RateCard_ID
    WHERE rc.Rate_Type = 'Franchise' AND rc.B2CIdentity_ID IN (SELECT Franchise_ID FROM #F);           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabRateCardDetail', 'DELETE', @n, 'franchise rates';
    DELETE rc FROM dbo.LabRateCardMaster rc WHERE rc.Rate_Type = 'Franchise' AND rc.B2CIdentity_ID IN (SELECT Franchise_ID FROM #F);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabRateCardMaster', 'DELETE', @n, 'franchise rate lists';
    DELETE f FROM dbo.LabFranchiseMaster f INNER JOIN #F x ON x.Franchise_ID = f.Franchise_ID;        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabFranchiseMaster', 'DELETE', @n, 'Master > Lab Franchises';
END;
GO

-- ============================================================================
-- Activity logs: page views / access, e-mail and WhatsApp send logs. Security history is kept.
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearActivityLogs
    @CompanyId INT = NULL,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'Activity logs';
    CREATE TABLE #B (BranchId INT PRIMARY KEY);
    INSERT INTO #B SELECT BranchId FROM cleanup.ufn_ScopeBranches(@CompanyId, @BranchId);
    DECLARE @All BIT = CASE WHEN @CompanyId IS NULL AND @BranchId IS NULL THEN 1 ELSE 0 END;

    DELETE a FROM dbo.AuditLogs a
    WHERE ISNULL(a.ModuleCode, '') <> 'SEC'
      AND (@All = 1 OR a.BranchId IN (SELECT BranchId FROM #B) OR (@BranchId IS NULL AND a.BranchId IS NULL AND a.CompanyId = @CompanyId));
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'AuditLogs', 'DELETE', @n, 'activity / page-view / module audit entries (security entries kept)';
    DELETE e FROM dbo.EmailLogs e WHERE @All = 1 OR e.BranchId IN (SELECT BranchId FROM #B);           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'EmailLogs', 'DELETE', @n, 'e-mail send log';
    DELETE w FROM dbo.WhatsAppLog w WHERE @All = 1 OR w.BranchId IN (SELECT BranchId FROM #B);         SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'WhatsAppLog', 'DELETE', @n, 'WhatsApp send log';
    DELETE x FROM dbo.UserNotification x
    WHERE @All = 1 OR x.BranchId IN (SELECT BranchId FROM #B) OR (@BranchId IS NULL AND x.BranchId IS NULL AND x.CompanyId = @CompanyId);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'UserNotification', 'DELETE', @n, 'bell notifications';
    DELETE x FROM dbo.AuthorizationDecisionLog x WHERE @All = 1 OR x.Branch_ID IN (SELECT BranchId FROM #B);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'AuthorizationDecisionLog', 'DELETE', @n, 'page permission decisions (audit mode)';
    DELETE x FROM dbo.DoctorIpAccessLog x WHERE @All = 1 OR (@BranchId IS NULL AND x.CompanyId = @CompanyId);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'DoctorIpAccessLog', 'DELETE', @n, 'Doctor IP screen access log';
END;
GO

-- ============================================================================
-- Number series: reset a branch's counter only when that branch has no document of that kind left,
-- so the next bill / token / receipt / barcode / patient code starts again at 1.
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ResetSequences
    @CompanyId INT = NULL,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'Number series';
    CREATE TABLE #B (BranchId INT PRIMARY KEY);
    INSERT INTO #B SELECT BranchId FROM cleanup.ufn_ScopeBranches(@CompanyId, @BranchId);

    -- LAB bills and tokens (B2C and B2B)
    UPDATE s SET s.LastSeq = 0 FROM dbo.OPDBillSequence s INNER JOIN #B b ON b.BranchId = s.BranchId
    WHERE s.ModuleCode = 'LAB' AND NOT EXISTS (SELECT 1 FROM dbo.LabOrder x WHERE x.BranchId = s.BranchId);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'OPDBillSequence (LAB)', 'RESET', @n, 'LAB bill numbers restart at 1';
    DELETE s FROM dbo.OPDTokenSequence s INNER JOIN #B b ON b.BranchId = s.BranchId
    WHERE s.ModuleCode IN ('LAB', 'B2B_LAB') AND NOT EXISTS (SELECT 1 FROM dbo.LabOrder x WHERE x.BranchId = s.BranchId);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'OPDTokenSequence (LAB)', 'RESET', @n, 'LAB / B2B tokens';
    UPDATE s SET s.LastSeq = 0 FROM dbo.LabBarcodeSequence s INNER JOIN #B b ON b.BranchId = s.BranchId
    WHERE NOT EXISTS (SELECT 1 FROM dbo.SampleCollection x WHERE x.BranchID = s.BranchId);              SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'LabBarcodeSequence', 'RESET', @n, 'sample barcodes';
    UPDATE s SET s.LastSeq = 0 FROM dbo.CancellationSequence s INNER JOIN #B b ON b.BranchId = s.BranchId
    WHERE s.ModuleCode = 'LAB' AND NOT EXISTS (SELECT 1 FROM dbo.BillCancellation x INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = x.ModuleRefId
                                               WHERE x.ModuleCode = 'LAB' AND lo.BranchId = s.BranchId);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'CancellationSequence (LAB)', 'RESET', @n, 'LAB cancellation numbers';

    -- OPD bills and tokens
    UPDATE s SET s.LastSeq = 0 FROM dbo.OPDBillSequence s INNER JOIN #B b ON b.BranchId = s.BranchId
    WHERE s.ModuleCode = 'OPD' AND NOT EXISTS (SELECT 1 FROM dbo.PatientOPDService x WHERE x.BranchId = s.BranchId);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'OPDBillSequence (OPD)', 'RESET', @n, 'OPD bill numbers restart at 1';
    DELETE s FROM dbo.OPDTokenSequence s INNER JOIN #B b ON b.BranchId = s.BranchId
    WHERE s.ModuleCode = 'OPD' AND NOT EXISTS (SELECT 1 FROM dbo.PatientOPDService x WHERE x.BranchId = s.BranchId);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'OPDTokenSequence (OPD)', 'RESET', @n, 'OPD tokens';
    UPDATE s SET s.LastSeq = 0 FROM dbo.CancellationSequence s INNER JOIN #B b ON b.BranchId = s.BranchId
    WHERE s.ModuleCode = 'OPD' AND NOT EXISTS (SELECT 1 FROM dbo.BillCancellation x INNER JOIN dbo.PatientOPDService o ON o.OPDServiceId = x.ModuleRefId
                                               WHERE x.ModuleCode = 'OPD' AND o.BranchId = s.BranchId);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'CancellationSequence (OPD)', 'RESET', @n, 'OPD cancellation numbers';

    -- money receipts are numbered across OPD and LAB: reset only when the branch has no payment of either
    UPDATE s SET s.LastSeq = 0 FROM dbo.ReceiptSequence s INNER JOIN #B b ON b.BranchId = s.BranchId
    WHERE NOT EXISTS (SELECT 1 FROM dbo.PaymentHeader x WHERE x.BranchId = s.BranchId);                SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'ReceiptSequence', 'RESET', @n, 'money receipt numbers (OPD and LAB share it)';

    -- accounts voucher numbers (petty cash, contra, journal, payment, receipt ...): per voucher type and financial year,
    -- restarted when the branch has no voucher of that type and year left
    DELETE s FROM dbo.Acc_VoucherSequence s INNER JOIN #B b ON b.BranchId = s.BranchId
    WHERE NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t
                      WHERE t.BranchId = s.BranchId AND t.VoucherTypeId = s.VoucherTypeId AND t.FinancialYear = s.FinancialYear);
                                                                                                        SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Acc_VoucherSequence', 'RESET', @n, 'accounts voucher numbers';

    -- patient codes
    UPDATE s SET s.LastSeq = 0 FROM dbo.PatientCodeCounter s INNER JOIN #B b ON b.BranchId = s.BranchId
    WHERE NOT EXISTS (SELECT 1 FROM dbo.PatientMaster x WHERE x.BranchId = s.BranchId);                SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PatientCodeCounter', 'RESET', @n, 'patient codes';
END;
GO

-- ============================================================================
-- Membership cards (OPD / LAB > Membership): cards issued at the branches in scope, their members, points, redeem
-- OTPs, WhatsApp messages, the card-fee payments and their ledger vouchers. A card still used by a bill that is not
-- being cleared is kept.
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearMembership
    @CompanyId INT = NULL,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'Membership';
    CREATE TABLE #B (BranchId INT PRIMARY KEY, CompanyId INT);
    INSERT INTO #B SELECT BranchId, CompanyId FROM cleanup.ufn_ScopeBranches(@CompanyId, @BranchId);

    CREATE TABLE #Card (CardId INT PRIMARY KEY);
    INSERT INTO #Card SELECT c.CardId FROM dbo.MembershipCard c
    WHERE c.IssueBranchId IN (SELECT BranchId FROM #B)
       OR (@BranchId IS NULL AND c.IssueBranchId IS NULL AND c.CompanyId IN (SELECT CompanyId FROM #B));
    CREATE TABLE #KeepCard (CardId INT PRIMARY KEY);
    INSERT INTO #KeepCard SELECT DISTINCT ph.MembershipCardId FROM dbo.PaymentHeader ph
    WHERE ph.MembershipCardId IN (SELECT CardId FROM #Card) AND ph.ModuleCode <> 'MEM';
    DELETE c FROM #Card c INNER JOIN #KeepCard k ON k.CardId = c.CardId;
    SELECT @n = COUNT(1) FROM #KeepCard;
    IF @n > 0 EXEC cleanup.usp_Report @A, 'MembershipCard', 'KEPT', @n, 'still used by OPD / LAB bills that were not cleared';

    DELETE x FROM dbo.MembershipRedeemOtp x INNER JOIN #Card c ON c.CardId = x.CardId;               SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'MembershipRedeemOtp', 'DELETE', @n, 'points redeem OTPs';
    DELETE x FROM dbo.MembershipPointsWhatsAppLog x INNER JOIN #Card c ON c.CardId = x.CardId;       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'MembershipPointsWhatsAppLog', 'DELETE', @n, 'points WhatsApp messages';
    DELETE x FROM dbo.MembershipLedger x INNER JOIN #Card c ON c.CardId = x.CardId;                  SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'MembershipLedger', 'DELETE', @n, 'points earned / redeemed / issued';
    DELETE x FROM dbo.MembershipCardMember x INNER JOIN #Card c ON c.CardId = x.CardId;              SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'MembershipCardMember', 'DELETE', @n, 'family members on the cards';

    -- card fees (payments of module MEM)
    CREATE TABLE #P (PaymentHeaderId INT PRIMARY KEY);
    INSERT INTO #P SELECT ph.PaymentHeaderId FROM dbo.PaymentHeader ph
    WHERE ph.ModuleCode = 'MEM'
      AND (ph.BranchId IN (SELECT BranchId FROM #B)
           OR ph.PaymentHeaderId IN (SELECT c.FeePaymentHeaderId FROM dbo.MembershipCard c INNER JOIN #Card x ON x.CardId = c.CardId));
    DELETE d FROM dbo.PaymentDetail d INNER JOIN #P p ON p.PaymentHeaderId = d.PaymentHeaderId;      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PaymentDetail', 'DELETE', @n, 'card fee receipts';
    DELETE l FROM dbo.PaymentLineItem l INNER JOIN #P p ON p.PaymentHeaderId = l.PaymentHeaderId;    SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PaymentLineItem', 'DELETE', @n, 'card fee lines';
    DELETE h FROM dbo.PaymentHeader h INNER JOIN #P p ON p.PaymentHeaderId = h.PaymentHeaderId;      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'PaymentHeader', 'DELETE', @n, 'card fee payments';

    -- ledger: card sale, fee receipt, points earned / expired / reversed
    CREATE TABLE #L (TransactionId BIGINT PRIMARY KEY);
    INSERT INTO #L SELECT t.TransactionId FROM dbo.Acc_LedgerTransaction t
    WHERE t.ReferenceType LIKE 'MEM[_]%' AND t.BranchId IN (SELECT BranchId FROM #B);
    EXEC cleanup.usp_DeleteLedger @A, N'ledger vouchers (card sale, fee receipt, points earned / expired / reversed)';

    DELETE x FROM dbo.MembershipCard x INNER JOIN #Card c ON c.CardId = x.CardId;                    SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'MembershipCard', 'DELETE', @n, 'membership cards (numbering restarts from the highest card left)';
END;
GO

-- ============================================================================
-- Accounts (Utility > Accounts) and day closing: OPD / LAB Day Closing with their petty cash links, petty cash
-- floats, expenses (with bill scans) and closings, manual vouchers (with bill scans), and their ledger vouchers.
-- Kept: ledgers, groups, expense heads, payees, petty cash counters, voucher types, accounts settings, book locks.
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearAccounts
    @CompanyId INT = NULL,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'Accounts & day closing';
    CREATE TABLE #B (BranchId INT PRIMARY KEY, CompanyId INT);
    INSERT INTO #B SELECT BranchId, CompanyId FROM cleanup.ufn_ScopeBranches(@CompanyId, @BranchId);

    -- OPD / LAB Day Closing
    CREATE TABLE #CC (CashClosingId INT PRIMARY KEY);
    INSERT INTO #CC SELECT c.CashClosingId FROM dbo.CashClosing c INNER JOIN #B b ON b.BranchId = c.BranchId;
    DELETE x FROM dbo.CashClosingPetty x INNER JOIN #CC c ON c.CashClosingId = x.CashClosingId;      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'CashClosingPetty', 'DELETE', @n, 'petty cash floats taken by day closings';
    DELETE x FROM dbo.CashClosingLine x INNER JOIN #CC c ON c.CashClosingId = x.CashClosingId;       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'CashClosingLine', 'DELETE', @n, 'day closing breakdown lines';
    DELETE x FROM dbo.CashClosing x INNER JOIN #CC c ON c.CashClosingId = x.CashClosingId;           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'CashClosing', 'DELETE', @n, 'OPD / LAB day closings (count, hand-over, verification)';

    -- petty cash of the counters of these branches
    CREATE TABLE #Ctr (CounterId INT PRIMARY KEY);
    INSERT INTO #Ctr SELECT c.CounterId FROM dbo.Acc_PettyCashCounter c INNER JOIN #B b ON b.BranchId = c.BranchId;
    CREATE TABLE #PE (ExpenseId INT PRIMARY KEY);
    INSERT INTO #PE SELECT e.ExpenseId FROM dbo.Acc_PettyExpense e
    WHERE e.BranchId IN (SELECT BranchId FROM #B) OR e.CounterId IN (SELECT CounterId FROM #Ctr);
    CREATE TABLE #V (VoucherId INT PRIMARY KEY);
    INSERT INTO #V SELECT v.VoucherId FROM dbo.Acc_Voucher v INNER JOIN #B b ON b.BranchId = v.BranchId;

    -- bill scans (stored under App_Data/accounts on the web server: listed, not deleted by SQL)
    IF OBJECT_ID('tempdb..#CleanupFiles') IS NOT NULL
        INSERT INTO #CleanupFiles (Area, FilePath)
        SELECT @A, N'App_Data/accounts/' + a.StoredName FROM dbo.Acc_Attachment a
        WHERE (a.RefType = 'PETTY_EXP' AND a.RefId IN (SELECT ExpenseId FROM #PE)) OR (a.RefType = 'VOUCHER' AND a.RefId IN (SELECT VoucherId FROM #V));
    DELETE a FROM dbo.Acc_Attachment a
    WHERE (a.RefType = 'PETTY_EXP' AND a.RefId IN (SELECT ExpenseId FROM #PE)) OR (a.RefType = 'VOUCHER' AND a.RefId IN (SELECT VoucherId FROM #V));
                                                                                                       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Acc_Attachment', 'DELETE', @n, 'bill scans of petty expenses and vouchers';
    DELETE x FROM dbo.Acc_PettyExpenseLine x INNER JOIN #PE e ON e.ExpenseId = x.ExpenseId;          SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Acc_PettyExpenseLine', 'DELETE', @n, 'petty expense lines';
    DELETE x FROM dbo.Acc_PettyExpense x INNER JOIN #PE e ON e.ExpenseId = x.ExpenseId;              SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Acc_PettyExpense', 'DELETE', @n, 'petty expenses';
    DELETE x FROM dbo.Acc_PettyCashFloat x INNER JOIN #Ctr c ON c.CounterId = x.CounterId;           SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Acc_PettyCashFloat', 'DELETE', @n, 'petty cash floats issued / replenished / returned';
    DELETE x FROM dbo.Acc_PettyCashClosing x INNER JOIN #Ctr c ON c.CounterId = x.CounterId;         SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Acc_PettyCashClosing', 'DELETE', @n, 'petty cash day closings';
    DELETE x FROM dbo.Acc_VoucherLine x INNER JOIN #V v ON v.VoucherId = x.VoucherId;                SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Acc_VoucherLine', 'DELETE', @n, 'manual voucher lines';
    DELETE x FROM dbo.Acc_Voucher x INNER JOIN #V v ON v.VoucherId = x.VoucherId;                    SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'Acc_Voucher', 'DELETE', @n, 'manual vouchers (payment, receipt, contra, journal)';

    CREATE TABLE #L (TransactionId BIGINT PRIMARY KEY);
    INSERT INTO #L SELECT t.TransactionId FROM dbo.Acc_LedgerTransaction t
    WHERE t.BranchId IN (SELECT BranchId FROM #B) AND t.ReferenceType IN ('CASH_CLOSE', 'PETTY_EXP', 'PETTY_FLOAT', 'PETTY_CLOSE', 'MANUAL_VCH');
    EXEC cleanup.usp_DeleteLedger @A, N'ledger vouchers (day closing difference, petty expense / float / closing, manual vouchers)';

    SELECT @n = COUNT(1) FROM dbo.Acc_BranchLock l INNER JOIN #B b ON b.BranchId = l.BranchId WHERE l.LockedUpTo IS NOT NULL;
    IF @n > 0 EXEC cleanup.usp_Report @A, 'Acc_BranchLock', 'KEPT', @n, 'books locked up to a date: unlock in Accounts Settings if needed';
END;
GO

-- ============================================================================
-- Quality & compliance records (not masters): reagent consumption, IQC runs and results, EQAS cycles and results,
-- CAPA, equipment breakdowns / calibrations / maintenance. Kept: equipment, analyzers, IQC materials / lots /
-- targets, EQAS programmes and their tests, BOMs, inventory items.
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearQuality
    @CompanyId INT = NULL,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @n INT, @A NVARCHAR(40) = N'Quality & compliance';
    CREATE TABLE #B (BranchId INT PRIMARY KEY, CompanyId INT);
    INSERT INTO #B SELECT BranchId, CompanyId FROM cleanup.ufn_ScopeBranches(@CompanyId, @BranchId);
    DECLARE @WholeCompany BIT = CASE WHEN @BranchId IS NULL THEN 1 ELSE 0 END;

    DELETE x FROM dbo.QcConsumptionLine x WHERE x.ConsumptionId IN (SELECT c.ConsumptionId FROM dbo.QcConsumption c WHERE c.BranchId IN (SELECT BranchId FROM #B));
                                                                                                       SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'QcConsumptionLine', 'DELETE', @n, 'reagent / consumable lines';
    DELETE x FROM dbo.QcConsumption x WHERE x.BranchId IN (SELECT BranchId FROM #B);                  SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'QcConsumption', 'DELETE', @n, 'BOM consumption';

    CREATE TABLE #Run (RunId BIGINT PRIMARY KEY);
    INSERT INTO #Run SELECT r.RunId FROM dbo.IqcRun r WHERE r.BranchId IN (SELECT BranchId FROM #B);
    DELETE x FROM dbo.IqcResult x INNER JOIN #Run r ON r.RunId = x.RunId;                            SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'IqcResult', 'DELETE', @n, 'IQC results';
    DELETE x FROM dbo.IqcRun x INNER JOIN #Run r ON r.RunId = x.RunId;                               SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'IqcRun', 'DELETE', @n, 'IQC runs';

    CREATE TABLE #Cyc (CycleId BIGINT PRIMARY KEY);
    INSERT INTO #Cyc SELECT c.CycleId FROM dbo.QcEqasCycle c INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId
    WHERE p.BranchId IN (SELECT BranchId FROM #B) OR (@WholeCompany = 1 AND p.BranchId IS NULL AND p.CompanyId IN (SELECT CompanyId FROM #B));
    CREATE TABLE #Eq (EquipmentId BIGINT PRIMARY KEY);
    INSERT INTO #Eq SELECT e.EquipmentId FROM dbo.QcEquipment e
    WHERE e.BranchId IN (SELECT BranchId FROM #B) OR (@WholeCompany = 1 AND e.BranchId IS NULL AND e.CompanyId IN (SELECT CompanyId FROM #B));
    IF OBJECT_ID('tempdb..#CleanupFiles') IS NOT NULL
        INSERT INTO #CleanupFiles (Area, FilePath)
        SELECT @A, v.FilePath FROM (
            SELECT c.ReportPath AS FilePath FROM dbo.QcEqasCycle c INNER JOIN #Cyc x ON x.CycleId = c.CycleId
            UNION ALL SELECT k.CertificatePath FROM dbo.QcEquipmentCalibration k INNER JOIN #Eq e ON e.EquipmentId = k.EquipmentId
            UNION ALL SELECT m.ReportPath FROM dbo.QcEquipmentMaintenance m INNER JOIN #Eq e ON e.EquipmentId = m.EquipmentId) v
        WHERE NULLIF(LTRIM(RTRIM(v.FilePath)), '') IS NOT NULL;
    DELETE x FROM dbo.QcEqasResult x INNER JOIN #Cyc c ON c.CycleId = x.CycleId;                     SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'QcEqasResult', 'DELETE', @n, 'EQAS results';
    DELETE x FROM dbo.QcEqasCycle x INNER JOIN #Cyc c ON c.CycleId = x.CycleId;                      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'QcEqasCycle', 'DELETE', @n, 'EQAS cycles (programmes kept)';
    DELETE x FROM dbo.QcEquipmentBreakdown x INNER JOIN #Eq e ON e.EquipmentId = x.EquipmentId;      SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'QcEquipmentBreakdown', 'DELETE', @n, 'equipment breakdowns';
    DELETE x FROM dbo.QcEquipmentCalibration x INNER JOIN #Eq e ON e.EquipmentId = x.EquipmentId;    SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'QcEquipmentCalibration', 'DELETE', @n, 'equipment calibrations';
    DELETE x FROM dbo.QcEquipmentMaintenance x INNER JOIN #Eq e ON e.EquipmentId = x.EquipmentId;    SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'QcEquipmentMaintenance', 'DELETE', @n, 'equipment maintenance';

    CREATE TABLE #Capa (CapaId BIGINT PRIMARY KEY);
    INSERT INTO #Capa SELECT c.CapaId FROM dbo.QcCapa c
    WHERE c.BranchId IN (SELECT BranchId FROM #B) OR (@WholeCompany = 1 AND c.BranchId IS NULL AND c.CompanyId IN (SELECT CompanyId FROM #B));
    UPDATE x SET x.CapaId = NULL FROM dbo.IqcRun x INNER JOIN #Capa c ON c.CapaId = x.CapaId;
    UPDATE x SET x.CapaId = NULL FROM dbo.QcEqasResult x INNER JOIN #Capa c ON c.CapaId = x.CapaId;
    UPDATE x SET x.CapaId = NULL FROM dbo.QcEquipmentBreakdown x INNER JOIN #Capa c ON c.CapaId = x.CapaId;
    DELETE x FROM dbo.QcCapa x INNER JOIN #Capa c ON c.CapaId = x.CapaId;                            SET @n = @@ROWCOUNT; EXEC cleanup.usp_Report @A, 'QcCapa', 'DELETE', @n, 'CAPA records';
END;
GO

-- ============================================================================
-- Every ledger voucher still left on the branches in scope (any kind). Only run together with LAB, OPD, MEMBERSHIP
-- and ACCOUNTS, so no document is left without its voucher. A franchise wallet top-up voucher stays unless the whole
-- company is cleared (the top-up itself belongs to the franchise, not a branch). Ledger masters and their opening
-- balances are kept.
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_ClearRemainingLedger
    @CompanyId INT = NULL,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC cleanup.usp_Guard;
    DECLARE @A NVARCHAR(40) = N'Ledger (remaining)', @kinds NVARCHAR(400);
    CREATE TABLE #B (BranchId INT PRIMARY KEY, CompanyId INT);
    INSERT INTO #B SELECT BranchId, CompanyId FROM cleanup.ufn_ScopeBranches(@CompanyId, @BranchId);
    CREATE TABLE #L (TransactionId BIGINT PRIMARY KEY);
    INSERT INTO #L SELECT t.TransactionId FROM dbo.Acc_LedgerTransaction t
    WHERE t.BranchId IN (SELECT BranchId FROM #B) AND (@BranchId IS NULL OR ISNULL(t.ReferenceType, '') <> 'B2B_WALLET_TOPUP');
    SELECT @kinds = STRING_AGG(CONCAT(ISNULL(t.ReferenceType, 'none'), ' ', t.Cnt), ', ')
    FROM (SELECT t.ReferenceType, COUNT(1) AS Cnt FROM dbo.Acc_LedgerTransaction t INNER JOIN #L l ON l.TransactionId = t.TransactionId GROUP BY t.ReferenceType) t;
    SET @kinds = N'every other ledger voucher of the branch' + ISNULL(N' (' + @kinds + N')', N'');
    EXEC cleanup.usp_DeleteLedger @A, @kinds;
END;
GO

-- ============================================================================
-- The runner: validates the request, runs the areas in dependency order in ONE transaction, and either commits
-- (@Execute = 1 with the confirmation text) or rolls everything back (dry run - the default), then reports.
-- ============================================================================
CREATE OR ALTER PROCEDURE cleanup.usp_Run
    @Areas          NVARCHAR(400),            -- LAB, OPD, MEMBERSHIP, ACCOUNTS, QUALITY, LEDGER, RATELISTS, PATIENTS, DOCTORS, FRANCHISES, LOGS, SEQUENCES
    @CompanyId      INT           = NULL,
    @BranchId       INT           = NULL,
    @AllCompanies   BIT           = 0,        -- required to run without a company / branch
    @RateTypes      NVARCHAR(100) = N'B2C,Franchise,Corporate',
    @ClearAuditLogs BIT           = 1,        -- LAB / OPD audit entries of the cleared bills
    @Execute        BIT           = 0,        -- 0 = dry run: everything is deleted and then rolled back
    @Confirm        NVARCHAR(200) = N''       -- must be 'CLEAR ' + database name when @Execute = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ── what to run ──
    DECLARE @a TABLE (Area VARCHAR(20) PRIMARY KEY);
    INSERT INTO @a SELECT DISTINCT UPPER(LTRIM(RTRIM(value))) FROM STRING_SPLIT(@Areas, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF EXISTS (SELECT 1 FROM @a WHERE Area NOT IN ('LAB', 'OPD', 'MEMBERSHIP', 'ACCOUNTS', 'QUALITY', 'LEDGER', 'RATELISTS', 'PATIENTS', 'DOCTORS', 'FRANCHISES', 'LOGS', 'SEQUENCES'))
        THROW 50110, 'Unknown area. Use LAB, OPD, MEMBERSHIP, ACCOUNTS, QUALITY, LEDGER, RATELISTS, PATIENTS, DOCTORS, FRANCHISES, LOGS, SEQUENCES.', 1;
    IF NOT EXISTS (SELECT 1 FROM @a) THROW 50111, 'Nothing to clear: @Areas is empty.', 1;
    IF EXISTS (SELECT 1 FROM @a WHERE Area = 'LEDGER')
       AND (SELECT COUNT(1) FROM @a WHERE Area IN ('LAB', 'OPD', 'MEMBERSHIP', 'ACCOUNTS')) < 4
        THROW 50118, 'LEDGER removes every voucher of the branch: run it only together with LAB, OPD, MEMBERSHIP and ACCOUNTS.', 1;

    -- ── scope ──
    IF @CompanyId IS NULL AND @BranchId IS NULL AND ISNULL(@AllCompanies, 0) = 0
        THROW 50112, 'Choose the scope: set @CompanyId and / or @BranchId, or set @AllCompanies = 1 to clear every company.', 1;
    IF @CompanyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyId = @CompanyId)
        THROW 50113, 'The company does not exist.', 1;
    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId)
        THROW 50114, 'The branch does not exist.', 1;
    IF @CompanyId IS NOT NULL AND @BranchId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND CompanyId = @CompanyId)
        THROW 50115, 'The branch does not belong to the company.', 1;
    IF @BranchId IS NOT NULL AND EXISTS (SELECT 1 FROM @a WHERE Area IN ('DOCTORS', 'FRANCHISES'))
        THROW 50116, 'Doctors and franchises belong to the whole company: clear them with @CompanyId only (no @BranchId).', 1;
    IF @BranchId IS NOT NULL AND @CompanyId IS NULL SELECT @CompanyId = CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    -- ── confirmation ──
    DECLARE @Expected NVARCHAR(200) = N'CLEAR ' + DB_NAME();
    IF ISNULL(@Execute, 0) = 1 AND ISNULL(@Confirm, N'') <> @Expected
        THROW 50117, 'To delete for real set @Confirm to the exact text: CLEAR <database name> (e.g. CLEAR EMR_Live). Nothing was changed.', 1;

    DECLARE @ScopeText NVARCHAR(400) =
        CASE WHEN @BranchId IS NOT NULL THEN N'Branch ' + ISNULL((SELECT BranchName + N' (' + BranchCode + N')' FROM dbo.Branchmaster WHERE BranchID = @BranchId), N'?')
             WHEN @CompanyId IS NOT NULL THEN N'Company ' + ISNULL((SELECT TOP 1 CompanyName FROM dbo.CompanyMaster WHERE CompanyId = @CompanyId), CAST(@CompanyId AS NVARCHAR(20))) + N', all its branches'
             ELSE N'EVERY company and branch' END;
    PRINT N'=== Data clean-up ===';
    PRINT N'Database : ' + DB_NAME() + N' on ' + @@SERVERNAME;
    PRINT N'Scope    : ' + @ScopeText;
    PRINT N'Areas    : ' + @Areas;
    PRINT N'Mode     : ' + CASE WHEN @Execute = 1 THEN N'EXECUTE - changes will be committed' ELSE N'DRY RUN - every change is rolled back at the end' END;
    PRINT N'Started  : ' + CONVERT(NVARCHAR(30), GETDATE(), 120);

    CREATE TABLE #CleanupReport (Step INT IDENTITY(1, 1), Area NVARCHAR(40), ObjectName NVARCHAR(128), Action VARCHAR(10), RowsAffected INT, Note NVARCHAR(400));
    CREATE TABLE #CleanupFiles (Area NVARCHAR(40), FilePath NVARCHAR(500));
    DECLARE @Report TABLE (Step INT, Area NVARCHAR(40), ObjectName NVARCHAR(128), Action VARCHAR(10), RowsAffected INT, Note NVARCHAR(400));
    DECLARE @Files TABLE (Area NVARCHAR(40), FilePath NVARCHAR(500));

    BEGIN TRY
        BEGIN TRANSACTION;

        -- dependency order: transactions first, then what they referred to, number series last
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'LAB')        EXEC cleanup.usp_ClearLabTransactions @CompanyId, @BranchId, @ClearAuditLogs;
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'OPD')        EXEC cleanup.usp_ClearOpdTransactions @CompanyId, @BranchId, @ClearAuditLogs;
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'MEMBERSHIP') EXEC cleanup.usp_ClearMembership @CompanyId, @BranchId;
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'ACCOUNTS')   EXEC cleanup.usp_ClearAccounts @CompanyId, @BranchId;
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'QUALITY')    EXEC cleanup.usp_ClearQuality @CompanyId, @BranchId;
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'LEDGER')     EXEC cleanup.usp_ClearRemainingLedger @CompanyId, @BranchId;
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'RATELISTS')  EXEC cleanup.usp_ClearLabRateLists @CompanyId, @BranchId, @RateTypes;
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'FRANCHISES') EXEC cleanup.usp_ClearFranchises @CompanyId;
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'PATIENTS')   EXEC cleanup.usp_ClearPatients @CompanyId, @BranchId;
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'DOCTORS')    EXEC cleanup.usp_ClearDoctors @CompanyId;
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'LOGS')       EXEC cleanup.usp_ClearActivityLogs @CompanyId, @BranchId;
        IF EXISTS (SELECT 1 FROM @a WHERE Area = 'SEQUENCES')  EXEC cleanup.usp_ResetSequences @CompanyId, @BranchId;

        -- the report survives a rollback in table variables
        INSERT INTO @Report SELECT Step, Area, ObjectName, Action, RowsAffected, Note FROM #CleanupReport;
        INSERT INTO @Files SELECT DISTINCT Area, FilePath FROM #CleanupFiles;

        IF @Execute = 1 COMMIT TRANSACTION; ELSE ROLLBACK TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT N'*** ERROR - everything was rolled back, nothing changed ***';
        PRINT N'Message : ' + ERROR_MESSAGE();
        PRINT N'In      : ' + ISNULL(ERROR_PROCEDURE(), N'-') + N' line ' + CAST(ERROR_LINE() AS NVARCHAR(10));
        THROW;
    END CATCH

    SELECT Step, Area, ObjectName AS [Table], Action, RowsAffected AS [Rows], Note FROM @Report ORDER BY Step;
    SELECT Area, SUM(CASE WHEN Action = 'DELETE' THEN RowsAffected ELSE 0 END) AS RowsDeleted,
           SUM(CASE WHEN Action IN ('UPDATE', 'RESET') THEN RowsAffected ELSE 0 END) AS RowsUpdated,
           SUM(CASE WHEN Action = 'KEPT' THEN RowsAffected ELSE 0 END) AS RecordsKept
    FROM @Report GROUP BY Area ORDER BY MIN(Step);
    IF EXISTS (SELECT 1 FROM @Files)
        SELECT Area, FilePath AS [File to remove from the server (uploads) after an executed run] FROM @Files ORDER BY Area, FilePath;

    PRINT N'Finished : ' + CONVERT(NVARCHAR(30), GETDATE(), 120);
    PRINT CASE WHEN @Execute = 1 THEN N'=== COMMITTED: the rows listed were deleted / reset ==='
               ELSE N'=== DRY RUN: nothing was changed. The counts show what an executed run would do. ===' END;
END;
GO

PRINT 'DataCleanup procedures installed in schema [cleanup].';
GO
