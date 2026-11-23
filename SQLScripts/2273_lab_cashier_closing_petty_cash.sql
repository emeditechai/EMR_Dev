-- ============================================================================================================
-- Migration: 2273_lab_cashier_closing_petty_cash.sql
-- Reports > LAB > Cashier Day-end Closing (LR-03): petty cash in the hand-over, as the Daily Collection Register (2269).
--   Petty cash is an imprest: a counter is given a float FROM the Cash ledger, expenses are paid from that float and the
--   float is topped up from the Cash ledger again. So the till is reduced by the cash given to petty cash (float issued /
--   replenished from a CASH ledger) and increased by a float returned to it:
--     net cash to hand over = cash received - cash refunds - given to petty cash + returned from petty cash.
--   Petty expenses (approved) are listed too, for information: they were paid from the float, deducting them again would
--   count them twice.
--   New rows: PETTYOUT (float issued / replenished), PETTYIN (float returned), PETTYEXP (expense, from the float).
--   New columns: PettyCash (effect on the till: minus out, plus back), PettyExpense (expense amount, information).
--   RS1 summary gets PettyOut / PettyIn / PettyExpense / PettyCount; RS2 groups get PettyCash / PettyExpense;
--   NetCash includes the petty cash effect. Same scope as the rest: branch, period, cashier (who made the entry), search.
-- Patches the live procedure in place. Run after 2272. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabReport_CashierClosing'));
IF @def IS NULL THROW 55260, 'usp_Api_LabReport_CashierClosing not found.', 1;
IF CHARINDEX(N'-- 2272: discount', @def) = 0 THROW 55261, 'Run script 2272 first.', 1;
IF CHARINDEX(N'-- 2273: petty cash', @def) = 0
BEGIN
    DECLARE @a NVARCHAR(200) = N'    DELETE FROM #E
    WHERE (@CollectedBy IS NOT NULL';
    DECLARE @n NVARCHAR(200) = N'ISNULL(SUM(CASE WHEN Bucket = ''CASH'' THEN Received - Refunded END), 0) AS NetCash';
    DECLARE @d NVARCHAR(100) = N'ISNULL(SUM(Discount), 0) AS Discount,';
    IF CHARINDEX(@a, @def) = 0 OR CHARINDEX(@n, @def) = 0 OR CHARINDEX(@d, @def) = 0
        THROW 55262, 'usp_Api_LabReport_CashierClosing: anchor not found; not changed.', 1;

    SET @def = STUFF(@def, CHARINDEX(@a, @def), LEN(@a), N'    -- 2273: petty cash - float given out of the till / returned to it (against a CASH ledger), and approved
    -- expenses (paid from the float: information only)
    ALTER TABLE #E ADD PettyCash DECIMAL(18, 2) NOT NULL DEFAULT 0, PettyExpense DECIMAL(18, 2) NOT NULL DEFAULT 0;
    DECLARE @CashMethodId INT = (SELECT TOP 1 PaymentMethodId FROM dbo.PaymentMethodMaster WHERE MethodCode = ''CASH'' ORDER BY PaymentMethodId);

    INSERT INTO #E (EntryType, EntryOn, ReceiptNo, LabOrderId, BillNo, PartyName, PartyCode, IsB2B, MethodId, ModeName, Bucket, Reference,
                    Received, Refunded, WalletUsed, CashierId, PettyCash, PettyExpense)
    SELECT CASE WHEN f.Kind = ''RETURN'' THEN ''PETTYIN'' ELSE ''PETTYOUT'' END,
           CASE WHEN CAST(f.CreatedDate AS DATE) = f.TxnDate THEN f.CreatedDate ELSE CAST(f.TxnDate AS DATETIME) END,
           f.VoucherNo, NULL, NULL, c.CounterName,
           CASE f.Kind WHEN ''ISSUE'' THEN N''Float issued'' WHEN ''REPLENISH'' THEN N''Float replenished'' ELSE N''Float returned'' END,
           0, @CashMethodId, N''Petty cash'', ''PETTY'', NULLIF(LTRIM(RTRIM(ISNULL(NULLIF(f.Remarks, ''''), f.ReferenceNo))), ''''),
           0, 0, 0, f.CreatedBy,
           CAST(CASE WHEN f.Kind = ''RETURN'' THEN f.Amount ELSE -f.Amount END AS DECIMAL(18, 2)), 0
    FROM dbo.Acc_PettyCashFloat f
    INNER JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = f.CounterId
    INNER JOIN dbo.Acc_LedgerMaster src ON src.LedgerId = f.SourceLedgerId AND src.LedgerType = ''CASH''
    WHERE c.BranchId = @BranchId AND f.TxnDate >= @FromDate AND f.TxnDate <= @ToDate
    UNION ALL
    SELECT ''PETTYEXP'',
           CASE WHEN CAST(e.CreatedDate AS DATE) = e.ExpenseDate THEN e.CreatedDate ELSE CAST(e.ExpenseDate AS DATETIME) END,
           e.VoucherNo, NULL, NULL, c.CounterName, NULLIF(LTRIM(RTRIM(e.PayeeName)), ''''),
           0, @CashMethodId, N''Petty cash'', ''PETTY'',
           (SELECT STRING_AGG(h.HeadName, '', '') FROM (SELECT DISTINCT eh.HeadName FROM dbo.Acc_PettyExpenseLine l
                   INNER JOIN dbo.Acc_ExpenseHead eh ON eh.ExpenseHeadId = l.ExpenseHeadId WHERE l.ExpenseId = e.ExpenseId) h),
           0, 0, 0, e.CreatedBy, 0, CAST(e.TotalAmount AS DECIMAL(18, 2))
    FROM dbo.Acc_PettyExpense e
    INNER JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = e.CounterId
    WHERE e.BranchId = @BranchId AND e.Status = ''A'' AND e.ExpenseDate >= @FromDate AND e.ExpenseDate <= @ToDate;

' + @a);
    -- net cash: cash received - cash refunds + the petty cash effect (minus given out, plus returned)
    SET @def = REPLACE(@def, @n, N'ISNULL(SUM(CASE WHEN Bucket = ''CASH'' THEN Received - Refunded END), 0) + ISNULL(SUM(PettyCash), 0) AS NetCash');
    SET @def = REPLACE(@def, @d, @d + N'
           ISNULL(SUM(CASE WHEN PettyCash < 0 THEN -PettyCash END), 0) AS PettyOut,
           ISNULL(SUM(CASE WHEN PettyCash > 0 THEN PettyCash END), 0) AS PettyIn,
           ISNULL(SUM(PettyCash), 0) AS PettyCash,
           ISNULL(SUM(PettyExpense), 0) AS PettyExpense,
           SUM(CASE WHEN EntryType LIKE ''PETTY%'' THEN 1 ELSE 0 END) AS PettyCount,');
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55263, 'usp_Api_LabReport_CashierClosing: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2273 applied: Cashier Day-end Closing - petty cash in the hand-over.';
GO
