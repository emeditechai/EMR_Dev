-- ====================================================================================================
-- Script: 2245_accounts_reports.sql
-- Description: Utility > Accounts > Reports - read-only procedures over the ledger (Acc_LedgerTransaction), which
--   holds the LAB / OPD billing entries and the petty cash / manual vouchers of script 2244 together.
--     usp_AccRpt_LedgerStatement  one ledger: opening balance, every line with the opposite ledgers, for the
--                                 Ledger Statement, Cash Book, Bank Book and Petty Cash Book
--     usp_AccRpt_DayBook          every voucher of a period, line by line (Day Book / Voucher Register)
--     usp_AccRpt_TrialBalance     opening, period debit / credit and closing per ledger (also feeds Income & Expense)
--     usp_AccRpt_ExpenseSummary   approved petty expenses by head and month
--     usp_AccRpt_PostingAudit     what should be in the ledger and is not: bills, receipts, refunds, petty cash and
--                                 manual vouchers without their entry, entries that do not balance or differ in amount
--   @BranchId NULL = all branches. Ledger opening balances are company-wide, so they are counted only then.
--   A cancelled voucher and its reversal both stay in the books (they cancel each other out).
--   Safe to re-run.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_AccRpt_LedgerStatement
    @LedgerId INT,
    @FromDate DATE,
    @ToDate   DATE,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATETIME = @FromDate, @to DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));

    -- 1. opening balance (Dr positive)
    SELECT l.LedgerId, l.LedgerName, l.LedgerCode, l.LedgerType, g.GroupName, g.GroupType,
           CAST(CASE WHEN @BranchId IS NULL THEN CASE WHEN l.OpeningBalanceType = 'Cr' THEN -l.OpeningBalance ELSE l.OpeningBalance END ELSE 0 END
                + ISNULL((SELECT SUM(d.DebitAmount - d.CreditAmount)
                          FROM dbo.Acc_LedgerTransactionDetail d JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId
                          WHERE d.LedgerId = l.LedgerId AND t.IsActive = 1 AND t.TransactionDate < @from AND (@BranchId IS NULL OR t.BranchId = @BranchId)), 0)
                AS DECIMAL(18,2)) AS OpeningBalance
    FROM dbo.Acc_LedgerMaster l JOIN dbo.Acc_LedgerGroup g ON g.LedgerGroupId = l.LedgerGroupId
    WHERE l.LedgerId = @LedgerId;

    -- 2. lines of the period
    SELECT t.TransactionId, t.TransactionDate, t.VoucherNo, v.VoucherTypeName, v.VoucherTypeCode, b.BranchName,
           ISNULL((SELECT STRING_AGG(x.LedgerName, ', ') FROM (SELECT DISTINCT l2.LedgerName FROM dbo.Acc_LedgerTransactionDetail d2
                    JOIN dbo.Acc_LedgerMaster l2 ON l2.LedgerId = d2.LedgerId
                    WHERE d2.TransactionId = t.TransactionId AND d2.LedgerId <> @LedgerId) x), '') AS Particulars,
           ISNULL(d.Narration, t.Narration) AS Narration, t.PayeeName, t.ReferenceType, t.ReferenceId,
           d.DebitAmount, d.CreditAmount, t.Status, CAST(CASE WHEN t.ReversalOfTransactionId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsReversal
    FROM dbo.Acc_LedgerTransactionDetail d
    JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId
    JOIN dbo.Acc_VoucherType v ON v.VoucherTypeId = t.VoucherTypeId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = t.BranchId
    WHERE d.LedgerId = @LedgerId AND t.IsActive = 1 AND t.TransactionDate >= @from AND t.TransactionDate < @to
      AND (@BranchId IS NULL OR t.BranchId = @BranchId)
    ORDER BY t.TransactionDate, t.TransactionId, d.TransactionDetailId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AccRpt_DayBook
    @FromDate      DATE,
    @ToDate        DATE,
    @BranchId      INT = NULL,
    @VoucherTypeId INT = NULL,
    @ManualOnly    BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATETIME = @FromDate, @to DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));

    SELECT t.TransactionId, t.TransactionDate, t.VoucherNo, v.VoucherTypeName, v.VoucherTypeCode, b.BranchName, t.PayeeName, t.PaymentMode, t.InstrumentNo,
           t.Narration AS VoucherNarration, t.TotalAmount, t.Status, CAST(CASE WHEN t.ReversalOfTransactionId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsReversal,
           t.ReferenceType, t.ReferenceId, ISNULL(NULLIF(u.FullName, ''), u.Username) AS EnteredBy,
           l.LedgerName, d.DebitAmount, d.CreditAmount
    FROM dbo.Acc_LedgerTransaction t
    JOIN dbo.Acc_VoucherType v ON v.VoucherTypeId = t.VoucherTypeId
    JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId
    JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = d.LedgerId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = t.BranchId
    LEFT JOIN dbo.Users u ON u.Id = t.CreatedBy
    WHERE t.IsActive = 1 AND t.TransactionDate >= @from AND t.TransactionDate < @to
      AND (@BranchId IS NULL OR t.BranchId = @BranchId)
      AND (@VoucherTypeId IS NULL OR t.VoucherTypeId = @VoucherTypeId)
      AND (@ManualOnly = 0 OR t.IsManual = 1 OR v.VoucherTypeCode IN ('PCV', 'CTR', 'JRN', 'PMT'))
    ORDER BY t.TransactionDate, t.TransactionId, CASE WHEN d.DebitAmount > 0 THEN 0 ELSE 1 END, d.TransactionDetailId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AccRpt_TrialBalance
    @FromDate DATE,
    @ToDate   DATE,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATETIME = @FromDate, @to DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));

    ;WITH mv AS (
        SELECT d.LedgerId,
               SUM(CASE WHEN t.TransactionDate < @from THEN d.DebitAmount - d.CreditAmount ELSE 0 END) AS OpenMove,
               SUM(CASE WHEN t.TransactionDate >= @from THEN d.DebitAmount ELSE 0 END) AS PeriodDr,
               SUM(CASE WHEN t.TransactionDate >= @from THEN d.CreditAmount ELSE 0 END) AS PeriodCr
        FROM dbo.Acc_LedgerTransactionDetail d JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId
        WHERE t.IsActive = 1 AND t.TransactionDate < @to AND (@BranchId IS NULL OR t.BranchId = @BranchId)
        GROUP BY d.LedgerId)
    SELECT l.LedgerId, l.LedgerName, l.LedgerCode, l.LedgerType, g.LedgerGroupId, g.GroupName, g.GroupType,
           CAST(x.Opening AS DECIMAL(18,2)) AS OpeningBalance, CAST(ISNULL(mv.PeriodDr, 0) AS DECIMAL(18,2)) AS PeriodDebit,
           CAST(ISNULL(mv.PeriodCr, 0) AS DECIMAL(18,2)) AS PeriodCredit,
           CAST(x.Opening + ISNULL(mv.PeriodDr, 0) - ISNULL(mv.PeriodCr, 0) AS DECIMAL(18,2)) AS ClosingBalance
    FROM dbo.Acc_LedgerMaster l
    JOIN dbo.Acc_LedgerGroup g ON g.LedgerGroupId = l.LedgerGroupId
    LEFT JOIN mv ON mv.LedgerId = l.LedgerId
    CROSS APPLY (SELECT CASE WHEN @BranchId IS NULL THEN CASE WHEN l.OpeningBalanceType = 'Cr' THEN -l.OpeningBalance ELSE l.OpeningBalance END ELSE 0 END
                        + ISNULL(mv.OpenMove, 0) AS Opening) x
    WHERE x.Opening <> 0 OR ISNULL(mv.PeriodDr, 0) <> 0 OR ISNULL(mv.PeriodCr, 0) <> 0
    ORDER BY CASE g.GroupType WHEN 'Asset' THEN 1 WHEN 'Liability' THEN 2 WHEN 'Income' THEN 3 ELSE 4 END, g.GroupName, l.LedgerName;

    -- vouchers that do not balance (should be none): shown as a warning on the report
    SELECT COUNT(*) AS UnbalancedVouchers
    FROM (SELECT d.TransactionId FROM dbo.Acc_LedgerTransactionDetail d JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId
          WHERE t.IsActive = 1 GROUP BY d.TransactionId HAVING SUM(d.DebitAmount) <> SUM(d.CreditAmount)) u;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AccRpt_ExpenseSummary
    @CompanyId INT,
    @FromDate  DATE,
    @ToDate    DATE,
    @BranchId  INT = NULL,
    @CounterId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.ExpenseHeadId, h.HeadName, b.BranchName, FORMAT(e.ExpenseDate, 'yyyy-MM') AS YearMonth,
           COUNT(DISTINCT e.ExpenseId) AS Vouchers, CAST(SUM(l.Amount) AS DECIMAL(18,2)) AS Amount
    FROM dbo.Acc_PettyExpense e
    JOIN dbo.Acc_PettyExpenseLine l ON l.ExpenseId = e.ExpenseId
    JOIN dbo.Acc_ExpenseHead h ON h.ExpenseHeadId = l.ExpenseHeadId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = e.BranchId
    WHERE e.CompanyId = @CompanyId AND e.Status = 'A' AND e.ExpenseDate BETWEEN @FromDate AND @ToDate
      AND (@BranchId IS NULL OR e.BranchId = @BranchId) AND (@CounterId IS NULL OR e.CounterId = @CounterId)
    GROUP BY h.ExpenseHeadId, h.HeadName, b.BranchName, FORMAT(e.ExpenseDate, 'yyyy-MM')
    ORDER BY h.HeadName, YearMonth, b.BranchName;
END
GO

-- Posting audit: every source document of the period against its ledger entry. One row per problem; no rows = clean.
-- Result 1: the problems. Result 2: per source, how many documents were checked and how many have a problem.
CREATE OR ALTER PROCEDURE dbo.usp_AccRpt_PostingAudit
    @CompanyId INT,
    @FromDate  DATE,
    @ToDate    DATE,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATETIME = @FromDate, @to DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @issues TABLE (Source NVARCHAR(40), DocNo NVARCHAR(60), DocDate DATETIME, BranchId INT, Amount DECIMAL(18,2), Issue NVARCHAR(200), TransactionId BIGINT NULL);
    DECLARE @checked TABLE (Source NVARCHAR(40), Checked INT);

    -- LAB B2C bills (as script 2232 posts them: a bill with a payment header)
    INSERT INTO @checked SELECT 'LAB bill (B2C)', COUNT(*) FROM dbo.LabOrder lo
        WHERE ISNULL(lo.IsB2B, 0) = 0 AND ISNULL(lo.TotalAmount, 0) > 0 AND lo.CreatedDate >= @from AND lo.CreatedDate < @to AND (@BranchId IS NULL OR lo.BranchId = @BranchId)
          AND EXISTS (SELECT 1 FROM dbo.PaymentHeader ph WHERE RTRIM(ph.ModuleCode) = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1);
    INSERT INTO @issues
    SELECT 'LAB bill (B2C)', ISNULL(lo.BillNo, CONCAT('#', lo.LabOrderId)), lo.CreatedDate, lo.BranchId, lo.TotalAmount, 'Bill is not posted to the ledger', NULL
    FROM dbo.LabOrder lo
    WHERE ISNULL(lo.IsB2B, 0) = 0 AND ISNULL(lo.TotalAmount, 0) > 0 AND lo.CreatedDate >= @from AND lo.CreatedDate < @to AND (@BranchId IS NULL OR lo.BranchId = @BranchId)
      AND EXISTS (SELECT 1 FROM dbo.PaymentHeader ph WHERE RTRIM(ph.ModuleCode) = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1)
      AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'LAB_BILL' AND t.ReferenceId = lo.LabOrderId);

    -- LAB B2B bills
    INSERT INTO @checked SELECT 'LAB bill (B2B)', COUNT(*) FROM dbo.LabOrder lo
        WHERE lo.IsB2B = 1 AND lo.B2BAgentID IS NOT NULL AND ISNULL(lo.B2BTotal, lo.TotalAmount) > 0 AND lo.CreatedDate >= @from AND lo.CreatedDate < @to
          AND (@BranchId IS NULL OR lo.BranchId = @BranchId);
    INSERT INTO @issues
    SELECT 'LAB bill (B2B)', ISNULL(lo.BillNo, CONCAT('#', lo.LabOrderId)), lo.CreatedDate, lo.BranchId, ISNULL(lo.B2BTotal, lo.TotalAmount), 'Bill is not posted to the ledger', NULL
    FROM dbo.LabOrder lo
    WHERE lo.IsB2B = 1 AND lo.B2BAgentID IS NOT NULL AND ISNULL(lo.B2BTotal, lo.TotalAmount) > 0 AND lo.CreatedDate >= @from AND lo.CreatedDate < @to
      AND (@BranchId IS NULL OR lo.BranchId = @BranchId)
      AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'B2B_LAB_BILL' AND t.ReferenceId = lo.LabOrderId);

    -- OPD bills
    INSERT INTO @checked SELECT 'OPD bill', COUNT(*) FROM dbo.PatientOPDService s
        INNER JOIN dbo.PaymentHeader ph ON RTRIM(ph.ModuleCode) = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
        WHERE ISNULL(s.TotalAmount, 0) > 0 AND ISNULL(s.VisitDate, ph.CreatedDate) >= @from AND ISNULL(s.VisitDate, ph.CreatedDate) < @to AND (@BranchId IS NULL OR s.BranchId = @BranchId);
    INSERT INTO @issues
    SELECT 'OPD bill', ISNULL(s.OPDBillNo, CONCAT('#', s.OPDServiceId)), ISNULL(s.VisitDate, ph.CreatedDate), s.BranchId, s.TotalAmount, 'Bill is not posted to the ledger', NULL
    FROM dbo.PatientOPDService s
    INNER JOIN dbo.PaymentHeader ph ON RTRIM(ph.ModuleCode) = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    WHERE ISNULL(s.TotalAmount, 0) > 0 AND ISNULL(s.VisitDate, ph.CreatedDate) >= @from AND ISNULL(s.VisitDate, ph.CreatedDate) < @to AND (@BranchId IS NULL OR s.BranchId = @BranchId)
      AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'OPD_BILL' AND t.ReferenceId = s.OPDServiceId);

    -- receipts (franchise wallet debits and B2B settlement receipts have their own entries and are left out, as in usp_Ledger_PostBillMoney)
    ;WITH r AS (
        SELECT pd.PaymentDetailId, pd.ReceiptNo, COALESCE(pd.PaymentDate, pd.CreatedDate) AS At, ph.BranchId, pd.PaidAmount, RTRIM(ph.ModuleCode) AS Module
        FROM dbo.PaymentDetail pd INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        WHERE pd.IsActive = 1 AND pd.PaidAmount > 0 AND RTRIM(ph.ModuleCode) IN ('LAB', 'OPD')
          AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @from AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @to AND (@BranchId IS NULL OR ph.BranchId = @BranchId)
          AND ISNULL(pd.TransactionRef, '') NOT LIKE 'WALLET-DEBIT-%'
          AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'B2B_SETTLEMENT' AND t.Narration LIKE '%Receipt: ' + pd.ReceiptNo + ')%'))
    INSERT INTO @issues
    SELECT r.Module + ' receipt', ISNULL(r.ReceiptNo, CONCAT('#', r.PaymentDetailId)), r.At, r.BranchId, r.PaidAmount,
           CASE WHEN t.TransactionId IS NULL THEN 'Receipt is not posted to the ledger' ELSE 'Ledger amount differs from the receipt' END, t.TransactionId
    FROM r
    OUTER APPLY (SELECT TOP 1 t.TransactionId, t.TotalAmount FROM dbo.Acc_LedgerTransaction t
                 WHERE t.ReferenceType = r.Module + '_RECEIPT' AND t.ReferenceId = r.PaymentDetailId AND t.IsActive = 1) t
    WHERE t.TransactionId IS NULL OR t.TotalAmount <> r.PaidAmount;
    INSERT INTO @checked
    SELECT RTRIM(ph.ModuleCode) + ' receipt', COUNT(*)
    FROM dbo.PaymentDetail pd INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
    WHERE pd.IsActive = 1 AND pd.PaidAmount > 0 AND RTRIM(ph.ModuleCode) IN ('LAB', 'OPD')
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @from AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @to AND (@BranchId IS NULL OR ph.BranchId = @BranchId)
      AND ISNULL(pd.TransactionRef, '') NOT LIKE 'WALLET-DEBIT-%'
    GROUP BY RTRIM(ph.ModuleCode);

    -- refunds
    INSERT INTO @checked
    SELECT RTRIM(r.ModuleCode) + ' refund', COUNT(*) FROM dbo.BillRefund r
    LEFT JOIN dbo.PaymentHeader ph ON RTRIM(ph.ModuleCode) = RTRIM(r.ModuleCode) AND ph.ModuleRefId = r.ModuleRefId AND ph.IsActive = 1
    WHERE r.IsActive = 1 AND r.RefundAmount > 0 AND RTRIM(r.ModuleCode) IN ('LAB', 'OPD') AND r.RefundDate >= @from AND r.RefundDate < @to AND (@BranchId IS NULL OR ph.BranchId = @BranchId)
    GROUP BY RTRIM(r.ModuleCode);
    INSERT INTO @issues
    SELECT RTRIM(r.ModuleCode) + ' refund', CONCAT('Refund #', r.RefundId), r.RefundDate, ph.BranchId, r.RefundAmount, 'Refund is not posted to the ledger', NULL
    FROM dbo.BillRefund r
    LEFT JOIN dbo.PaymentHeader ph ON RTRIM(ph.ModuleCode) = RTRIM(r.ModuleCode) AND ph.ModuleRefId = r.ModuleRefId AND ph.IsActive = 1
    WHERE r.IsActive = 1 AND r.RefundAmount > 0 AND RTRIM(r.ModuleCode) IN ('LAB', 'OPD') AND r.RefundDate >= @from AND r.RefundDate < @to AND (@BranchId IS NULL OR ph.BranchId = @BranchId)
      AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = RTRIM(r.ModuleCode) + '_REFUND' AND t.ReferenceId = r.RefundId AND t.IsActive = 1);

    -- petty expenses: approved ones must have a posted entry of the same amount; cancelled ones must be reversed
    INSERT INTO @checked SELECT 'Petty expense', COUNT(*) FROM dbo.Acc_PettyExpense e
        WHERE e.CompanyId = @CompanyId AND e.Status IN ('A', 'C') AND e.ExpenseDate BETWEEN @FromDate AND @ToDate AND (@BranchId IS NULL OR e.BranchId = @BranchId);
    INSERT INTO @issues
    SELECT 'Petty expense', ISNULL(e.VoucherNo, CONCAT('PE-', e.ExpenseId)), e.ExpenseDate, e.BranchId, e.TotalAmount,
           CASE WHEN e.Status = 'A' AND t.TransactionId IS NULL THEN 'Approved expense has no ledger entry'
                WHEN e.Status = 'A' AND t.Status <> 'P' THEN 'Approved expense, but its ledger entry is cancelled'
                WHEN e.Status = 'A' AND t.TotalAmount <> e.TotalAmount THEN 'Ledger amount differs from the expense'
                ELSE 'Cancelled expense, but its ledger entry is not reversed' END, t.TransactionId
    FROM dbo.Acc_PettyExpense e
    LEFT JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = e.TransactionId AND t.IsActive = 1
    WHERE e.CompanyId = @CompanyId AND e.Status IN ('A', 'C') AND e.ExpenseDate BETWEEN @FromDate AND @ToDate AND (@BranchId IS NULL OR e.BranchId = @BranchId)
      AND ((e.Status = 'A' AND (t.TransactionId IS NULL OR t.Status <> 'P' OR t.TotalAmount <> e.TotalAmount))
        OR (e.Status = 'C' AND t.TransactionId IS NOT NULL
            AND (t.Status <> 'C' OR NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction r WHERE r.ReversalOfTransactionId = t.TransactionId AND r.IsActive = 1))));

    -- petty cash float movements
    INSERT INTO @checked SELECT 'Petty cash float', COUNT(*) FROM dbo.Acc_PettyCashFloat f JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = f.CounterId
        WHERE c.CompanyId = @CompanyId AND f.TxnDate BETWEEN @FromDate AND @ToDate AND (@BranchId IS NULL OR c.BranchId = @BranchId);
    INSERT INTO @issues
    SELECT 'Petty cash float', ISNULL(f.VoucherNo, CONCAT('Float #', f.FloatId)), f.TxnDate, c.BranchId, f.Amount,
           CASE WHEN t.TransactionId IS NULL THEN 'Float movement has no ledger entry' ELSE 'Ledger amount differs from the float movement' END, t.TransactionId
    FROM dbo.Acc_PettyCashFloat f JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = f.CounterId
    LEFT JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = f.TransactionId AND t.IsActive = 1
    WHERE c.CompanyId = @CompanyId AND f.TxnDate BETWEEN @FromDate AND @ToDate AND (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (t.TransactionId IS NULL OR t.TotalAmount <> f.Amount);

    -- manual vouchers
    INSERT INTO @checked SELECT 'Manual voucher', COUNT(*) FROM dbo.Acc_Voucher v
        WHERE v.CompanyId = @CompanyId AND v.Status IN ('A', 'C') AND v.VoucherDate BETWEEN @FromDate AND @ToDate AND (@BranchId IS NULL OR v.BranchId = @BranchId);
    INSERT INTO @issues
    SELECT 'Manual voucher', ISNULL(v.VoucherNo, CONCAT('Voucher #', v.VoucherId)), v.VoucherDate, v.BranchId, v.TotalAmount,
           CASE WHEN v.Status = 'A' AND t.TransactionId IS NULL THEN 'Posted voucher has no ledger entry'
                WHEN v.Status = 'A' AND t.Status <> 'P' THEN 'Posted voucher, but its ledger entry is cancelled'
                WHEN v.Status = 'A' AND t.TotalAmount <> v.TotalAmount THEN 'Ledger amount differs from the voucher'
                ELSE 'Cancelled voucher, but its ledger entry is not reversed' END, t.TransactionId
    FROM dbo.Acc_Voucher v
    LEFT JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = v.TransactionId AND t.IsActive = 1
    WHERE v.CompanyId = @CompanyId AND v.Status IN ('A', 'C') AND v.VoucherDate BETWEEN @FromDate AND @ToDate AND (@BranchId IS NULL OR v.BranchId = @BranchId)
      AND ((v.Status = 'A' AND (t.TransactionId IS NULL OR t.Status <> 'P' OR t.TotalAmount <> v.TotalAmount))
        OR (v.Status = 'C' AND t.TransactionId IS NOT NULL
            AND (t.Status <> 'C' OR NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction r WHERE r.ReversalOfTransactionId = t.TransactionId AND r.IsActive = 1))));

    -- ledger entries of the period that do not balance, or have no branch
    INSERT INTO @checked SELECT 'Ledger entry', COUNT(*) FROM dbo.Acc_LedgerTransaction t
        WHERE t.IsActive = 1 AND t.TransactionDate >= @from AND t.TransactionDate < @to AND (@BranchId IS NULL OR t.BranchId = @BranchId);
    INSERT INTO @issues
    SELECT 'Ledger entry', ISNULL(t.VoucherNo, CONCAT('#', t.TransactionId)), t.TransactionDate, t.BranchId, t.TotalAmount,
           CONCAT('Entry does not balance: debit ', FORMAT(x.Dr, 'N2'), ', credit ', FORMAT(x.Cr, 'N2')), t.TransactionId
    FROM dbo.Acc_LedgerTransaction t
    CROSS APPLY (SELECT ISNULL(SUM(d.DebitAmount), 0) AS Dr, ISNULL(SUM(d.CreditAmount), 0) AS Cr FROM dbo.Acc_LedgerTransactionDetail d WHERE d.TransactionId = t.TransactionId) x
    WHERE t.IsActive = 1 AND t.TransactionDate >= @from AND t.TransactionDate < @to AND (@BranchId IS NULL OR t.BranchId = @BranchId) AND x.Dr <> x.Cr;
    IF @BranchId IS NULL
        INSERT INTO @issues
        SELECT 'Ledger entry', ISNULL(t.VoucherNo, CONCAT('#', t.TransactionId)), t.TransactionDate, NULL, t.TotalAmount, 'Entry has no branch: it is missing from every branch-wise report', t.TransactionId
        FROM dbo.Acc_LedgerTransaction t
        WHERE t.IsActive = 1 AND t.TransactionDate >= @from AND t.TransactionDate < @to AND t.BranchId IS NULL;

    SELECT i.Source, i.DocNo, i.DocDate, b.BranchName, i.Amount, i.Issue, i.TransactionId
    FROM @issues i LEFT JOIN dbo.Branchmaster b ON b.BranchID = i.BranchId
    ORDER BY i.Source, i.DocDate, i.DocNo;

    SELECT c.Source, SUM(c.Checked) AS Checked, ISNULL((SELECT COUNT(*) FROM @issues i WHERE i.Source = c.Source), 0) AS Problems
    FROM @checked c GROUP BY c.Source ORDER BY c.Source;
END
GO

PRINT 'Script 2245 applied: Accounts reports (ledger statement, day book, trial balance, expense summary, posting audit).';
GO
