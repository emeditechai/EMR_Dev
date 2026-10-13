-- ============================================================================================================
-- Migration: 2274_opd_daily_collection_petty_cash.sql
-- Reports > OPD > Daily Collection Register: petty cash in the cash hand-over, as the LAB register (2269) and the
-- Cashier Day-end Closing (2273).
--   Petty cash is an imprest of the branch: a counter is given a float FROM the Cash ledger, expenses are paid from the
--   float, the float is topped up from the Cash ledger again. So the till is reduced by the cash given to petty cash
--   (float issued / replenished from a CASH ledger) and increased by a float returned; petty expenses are listed for
--   information (paid from the float - deducting them again would count them twice).
--   New rows: EntryType PETTYOUT (float issued / replenished), PETTYIN (float returned), PETTYEXP (approved expense):
--     ReceiptNo = voucher no, BillNo = the movement, PatientName = the counter, DoctorName = the payee,
--     Reference = remarks / expense heads, Amount = the amount, PaymentMode = 'Petty cash', CollectedBy = who entered it.
--   New columns on every row: PettyCash (effect on the till: minus out, plus back), PettyExpense (expense amount).
--   Receipt and refund rows are unchanged (both new columns 0).
-- Patches the live procedure in place. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_Report_DailyCollectionRegister'));
IF @def IS NULL THROW 55270, 'usp_Api_Report_DailyCollectionRegister not found.', 1;
IF CHARINDEX(N'-- 2274: petty cash', @def) = 0
BEGIN
    DECLARE @r NVARCHAR(300) = N'COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''''), u.Username, ''System'') AS CollectedBy
    FROM dbo.PaymentDetail pd';
    DECLARE @f NVARCHAR(300) = N'COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''''), u.Username, ''System'')
    FROM dbo.BillRefund r';
    DECLARE @o NVARCHAR(100) = N'    ORDER BY PaymentDate, EntryId;';
    IF CHARINDEX(@r, @def) = 0 OR CHARINDEX(@f, @def) = 0 OR CHARINDEX(@o, @def) = 0
        THROW 55271, 'usp_Api_Report_DailyCollectionRegister: anchor not found; not changed.', 1;

    SET @def = STUFF(@def, CHARINDEX(@r, @def), LEN(@r), N'COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''''), u.Username, ''System'') AS CollectedBy,
        CAST(0 AS DECIMAL(18, 2)) AS PettyCash, CAST(0 AS DECIMAL(18, 2)) AS PettyExpense
    FROM dbo.PaymentDetail pd');
    SET @def = STUFF(@def, CHARINDEX(@f, @def), LEN(@f), N'COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''''), u.Username, ''System''),
        0, 0
    FROM dbo.BillRefund r');
    SET @def = STUFF(@def, CHARINDEX(@o, @def), LEN(@o), N'    UNION ALL

    -- 2274: petty cash of the branch - float given out of the till / returned to it (against a CASH ledger)
    SELECT CASE WHEN f.Kind = ''RETURN'' THEN ''PETTYIN'' ELSE ''PETTYOUT'' END, f.FloatId, NULL,
           CASE WHEN CAST(f.CreatedDate AS DATE) = f.TxnDate THEN f.CreatedDate ELSE CAST(f.TxnDate AS DATETIME) END,
           f.VoucherNo, ''PETTY'', NULL,
           CASE f.Kind WHEN ''ISSUE'' THEN N''Float issued'' WHEN ''REPLENISH'' THEN N''Float replenished'' ELSE N''Float returned'' END,
           NULL, NULL, NULL, NULL, c.CounterName, NULL, NULL,
           0, 0, 0, 0, 0, NULL,
           CAST(f.Amount AS DECIMAL(18, 2)), N''Petty cash'',
           NULLIF(LTRIM(RTRIM(ISNULL(NULLIF(f.Remarks, ''''), f.ReferenceNo))), ''''),
           COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''''), u.Username, ''System''),
           CAST(CASE WHEN f.Kind = ''RETURN'' THEN f.Amount ELSE -f.Amount END AS DECIMAL(18, 2)), 0
    FROM dbo.Acc_PettyCashFloat f
    INNER JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = f.CounterId
    INNER JOIN dbo.Acc_LedgerMaster src ON src.LedgerId = f.SourceLedgerId AND src.LedgerType = ''CASH''
    LEFT  JOIN dbo.Users u ON u.Id = f.CreatedBy
    WHERE c.BranchId = @BranchId AND f.TxnDate >= @From AND f.TxnDate < @ToExcl

    UNION ALL

    -- 2274: approved petty expenses (paid from the float: information only, no effect on the till)
    SELECT ''PETTYEXP'', e.ExpenseId, NULL,
           CASE WHEN CAST(e.CreatedDate AS DATE) = e.ExpenseDate THEN e.CreatedDate ELSE CAST(e.ExpenseDate AS DATETIME) END,
           e.VoucherNo, ''PETTY'', NULL, N''Petty expense (from the float)'',
           NULL, NULL, NULL, NULL, c.CounterName, NULL, NULLIF(LTRIM(RTRIM(e.PayeeName)), ''''),
           0, 0, 0, 0, 0, NULL,
           CAST(e.TotalAmount AS DECIMAL(18, 2)), N''Petty cash'',
           (SELECT STRING_AGG(h.HeadName, '', '') FROM (SELECT DISTINCT eh.HeadName FROM dbo.Acc_PettyExpenseLine l
                   INNER JOIN dbo.Acc_ExpenseHead eh ON eh.ExpenseHeadId = l.ExpenseHeadId WHERE l.ExpenseId = e.ExpenseId) h),
           COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''''), u.Username, ''System''),
           0, CAST(e.TotalAmount AS DECIMAL(18, 2))
    FROM dbo.Acc_PettyExpense e
    INNER JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = e.CounterId
    LEFT  JOIN dbo.Users u ON u.Id = e.CreatedBy
    WHERE e.BranchId = @BranchId AND e.Status = ''A'' AND e.ExpenseDate >= @From AND e.ExpenseDate < @ToExcl

' + @o);
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55272, 'usp_Api_Report_DailyCollectionRegister: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2274 applied: OPD Daily Collection Register - petty cash rows.';
GO
