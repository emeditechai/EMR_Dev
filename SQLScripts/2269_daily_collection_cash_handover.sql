-- ============================================================================================================
-- Migration: 2269_daily_collection_cash_handover.sql
-- Reports > LAB > Daily Collection Register: the money receipts stay as they are (gross collection); added is the
-- cash hand-over reconciliation, now that petty cash (Utility > Accounts, scripts 2244-2246) takes cash out of the till.
--   Petty cash is an imprest: a counter is given a float FROM the Cash ledger (Contra), expenses are paid from that
--   float (Dr expense, Cr the counter) and the float is topped up (replenished) from the Cash ledger again. So:
--     cash collected (cash-mode receipts of this register, every filter of the page applies)
--   - cash refunds paid (LAB refunds paid in cash; the LR-03 Cashier Closing rule)
--   - cash given to petty cash (float issued / replenished from a CASH ledger)
--   + petty cash returned (float returned to a CASH ledger)
--   = net cash to hand over.
--   Petty expenses are listed for information: they were paid from the float, so deducting them again would count
--   them twice.
--   New result sets, after the existing six (callers that read six are unchanged):
--     RS7 cash hand-over per person   RS8 petty cash movements of the period   RS9 petty cash counters of the branch
--   Who: refunds by who paid them, float movements by who made them, petty expenses by who entered them; a
--   non-administrator sees only their own lines (as the receipts).
-- Patches the live procedure in place. Run after 2268. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabReport_B2CCollectionRegister'));
IF @def IS NULL THROW 55220, 'usp_Api_LabReport_B2CCollectionRegister not found.', 1;
IF CHARINDEX(N'-- RS7: cash hand-over', @def) = 0
BEGIN
    DECLARE @a NVARCHAR(100) = N'    DROP TABLE #R;
END';
    IF CHARINDEX(@a, @def) = 0 THROW 55221, 'usp_Api_LabReport_B2CCollectionRegister: end anchor not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@a, @def), LEN(@a), N'    -- 2269: cash hand-over (receipts above stay the gross collection) ─────────────────────────────────
    -- cash-mode receipts of this register
    SELECT r.CollectedById AS PersonId, SUM(r.PaidAmount) AS Amount
    INTO #CashIn
    FROM #R r INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = r.PaymentMethodId
    WHERE pm.MethodCode = ''CASH''
    GROUP BY r.CollectedById;

    -- LAB refunds paid in cash (as LR-03 Cashier Closing)
    SELECT r.CreatedBy AS PersonId, SUM(r.RefundAmount) AS Amount
    INTO #CashRefund
    FROM dbo.BillRefund r
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = r.ModuleRefId
    WHERE r.ModuleCode = ''LAB'' AND r.IsActive = 1 AND ISNULL(r.Status, ''P'') = ''P'' AND lo.BranchId = @BranchId
      AND r.RefundMode LIKE ''%cash%''
      AND r.RefundDate >= @From AND r.RefundDate < @To
      AND (@CollectedBy IS NULL OR r.CreatedBy = @CollectedBy)
    GROUP BY r.CreatedBy;

    -- petty cash of the period: float movements against a CASH ledger, and approved expenses (paid from the float)
    SELECT f.FloatId AS RefId, CASE f.Kind WHEN ''ISSUE'' THEN ''Float issued'' WHEN ''REPLENISH'' THEN ''Float replenished'' ELSE ''Float returned'' END AS Movement,
           f.Kind, CAST(f.TxnDate AS DATETIME) AS TxnDate, c.CounterName, f.VoucherNo,
           CAST(f.Amount AS DECIMAL(18, 2)) AS Amount,
           CAST(CASE WHEN f.Kind = ''RETURN'' THEN f.Amount ELSE -f.Amount END AS DECIMAL(18, 2)) AS CashEffect,
           CAST(NULL AS NVARCHAR(150)) AS PayeeName, ISNULL(NULLIF(f.Remarks, ''''), f.ReferenceNo) AS Detail, f.CreatedBy AS PersonId
    INTO #Petty
    FROM dbo.Acc_PettyCashFloat f
    INNER JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = f.CounterId
    INNER JOIN dbo.Acc_LedgerMaster src ON src.LedgerId = f.SourceLedgerId AND src.LedgerType = ''CASH''
    WHERE c.BranchId = @BranchId AND f.TxnDate >= @FromDate AND f.TxnDate <= @ToDate
      AND (@CollectedBy IS NULL OR f.CreatedBy = @CollectedBy)
    UNION ALL
    SELECT e.ExpenseId, ''Petty expense (from the float)'', ''EXPENSE'', CAST(e.ExpenseDate AS DATETIME), c.CounterName, e.VoucherNo,
           CAST(e.TotalAmount AS DECIMAL(18, 2)), CAST(0 AS DECIMAL(18, 2)), e.PayeeName,
           (SELECT STRING_AGG(h.HeadName, '', '') FROM (SELECT DISTINCT eh.HeadName FROM dbo.Acc_PettyExpenseLine l
                   INNER JOIN dbo.Acc_ExpenseHead eh ON eh.ExpenseHeadId = l.ExpenseHeadId WHERE l.ExpenseId = e.ExpenseId) h),
           e.CreatedBy
    FROM dbo.Acc_PettyExpense e
    INNER JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = e.CounterId
    WHERE e.BranchId = @BranchId AND e.Status = ''A'' AND e.ExpenseDate >= @FromDate AND e.ExpenseDate <= @ToDate
      AND (@CollectedBy IS NULL OR e.CreatedBy = @CollectedBy);

    -- RS7: cash hand-over per person
    ;WITH people AS (SELECT PersonId FROM #CashIn UNION SELECT PersonId FROM #CashRefund UNION SELECT PersonId FROM #Petty WHERE Kind <> ''EXPENSE'')
    SELECT p.PersonId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''''), ISNULL(u.Username, ''Not recorded'')) AS PersonName,
           ISNULL(ci.Amount, 0) AS CashCollected,
           ISNULL(cr.Amount, 0) AS CashRefunds,
           ISNULL((SELECT SUM(Amount) FROM #Petty x WHERE ISNULL(x.PersonId, -1) = ISNULL(p.PersonId, -1) AND x.Kind IN (''ISSUE'', ''REPLENISH'')), 0) AS ToPettyCash,
           ISNULL((SELECT SUM(Amount) FROM #Petty x WHERE ISNULL(x.PersonId, -1) = ISNULL(p.PersonId, -1) AND x.Kind = ''RETURN''), 0) AS FromPettyCash,
           ISNULL(ci.Amount, 0) - ISNULL(cr.Amount, 0)
             - ISNULL((SELECT SUM(Amount) FROM #Petty x WHERE ISNULL(x.PersonId, -1) = ISNULL(p.PersonId, -1) AND x.Kind IN (''ISSUE'', ''REPLENISH'')), 0)
             + ISNULL((SELECT SUM(Amount) FROM #Petty x WHERE ISNULL(x.PersonId, -1) = ISNULL(p.PersonId, -1) AND x.Kind = ''RETURN''), 0) AS NetCash
    FROM people p
    LEFT JOIN #CashIn ci ON ISNULL(ci.PersonId, -1) = ISNULL(p.PersonId, -1)
    LEFT JOIN #CashRefund cr ON ISNULL(cr.PersonId, -1) = ISNULL(p.PersonId, -1)
    LEFT JOIN dbo.Users u ON u.Id = p.PersonId
    ORDER BY ISNULL(ci.Amount, 0) DESC, PersonName;

    -- RS8: petty cash movements of the period (expenses: information only, already paid from the float)
    SELECT pt.Movement, pt.Kind, pt.TxnDate, pt.CounterName, pt.VoucherNo, pt.Amount, pt.CashEffect, pt.PayeeName, pt.Detail,
           pt.PersonId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''''), ISNULL(u.Username, ''Not recorded'')) AS PersonName
    FROM #Petty pt LEFT JOIN dbo.Users u ON u.Id = pt.PersonId
    ORDER BY pt.TxnDate DESC, pt.Kind, pt.RefId DESC;

    -- RS9: petty cash counters of the branch: float, balance now (counter ledger), to replenish
    SELECT c.CounterId, c.CounterName, CAST(c.FloatAmount AS DECIMAL(18, 2)) AS FloatAmount,
           CAST(ISNULL(b.Balance, 0) AS DECIMAL(18, 2)) AS Balance,
           CAST(CASE WHEN c.FloatAmount - ISNULL(b.Balance, 0) > 0 THEN c.FloatAmount - ISNULL(b.Balance, 0) ELSE 0 END AS DECIMAL(18, 2)) AS ToReplenish,
           CAST(CASE WHEN c.LowBalanceAlert IS NOT NULL AND ISNULL(b.Balance, 0) <= c.LowBalanceAlert THEN 1 ELSE 0 END AS BIT) AS IsLow
    FROM dbo.Acc_PettyCashCounter c
    OUTER APPLY (SELECT SUM(d.DebitAmount - d.CreditAmount) AS Balance
                 FROM dbo.Acc_LedgerTransactionDetail d
                 INNER JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId
                 WHERE d.LedgerId = c.LedgerId AND t.BranchId = c.BranchId) b
    WHERE c.BranchId = @BranchId AND c.IsActive = 1
    ORDER BY c.CounterName;

    DROP TABLE #CashIn; DROP TABLE #CashRefund; DROP TABLE #Petty;
    DROP TABLE #R;
END');
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55222, 'usp_Api_LabReport_B2CCollectionRegister: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2269 applied: Daily Collection Register - cash hand-over with petty cash.';
GO
