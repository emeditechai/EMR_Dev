-- ============================================================================================================
-- Migration: 2272_lab_cashier_closing_discount.sql
-- Reports > LAB > Cashier Day-end Closing (LR-03): a Discount column.
--   Receipt / paid-from-wallet rows: the bill's discount (header discount, else the line discounts, plus the membership
--   discount - as the LAB Discount Register and 2271), shown on the bill's FIRST receipt only, so a bill paid in parts
--   or collected on a later day is not counted twice.
--   Refund rows: the discount taken back by that cancellation (BillCancellation.DiscountAdjusted), as a minus.
--   RS1 summary gets Discount / DiscountBills, RS2 groups get Discount (net of the discount taken back).
-- Patches the live procedure in place. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabReport_CashierClosing'));
IF @def IS NULL THROW 55250, 'usp_Api_LabReport_CashierClosing not found.', 1;
IF CHARINDEX(N'-- 2272: discount', @def) = 0
BEGIN
    DECLARE @a NVARCHAR(400) = N'ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''''), ISNULL(u.Username, ''Not recorded'')) AS Cashier
    INTO #R
    FROM #E e LEFT JOIN dbo.Users u ON u.Id = e.CashierId;';
    DECLARE @w NVARCHAR(100) = N'ISNULL(SUM(WalletUsed), 0) AS WalletUsed,';
    IF CHARINDEX(@a, @def) = 0 OR CHARINDEX(@w, @def) = 0
        THROW 55251, 'usp_Api_LabReport_CashierClosing: anchor not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@a, @def), LEN(@a), N'ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''''), ISNULL(u.Username, ''Not recorded'')) AS Cashier,
           -- 2272: discount - the bill''s discount on its first receipt; the discount taken back on a refund, as a minus
           CAST(CASE WHEN e.EntryType IN (''RECEIPT'', ''WALLET'') AND fr.ReceiptNo = e.ReceiptNo THEN ISNULL(bd.Discount, 0)
                     WHEN e.EntryType = ''REFUND'' THEN -ISNULL(ca.DiscountAdjusted, 0)
                     ELSE 0 END AS DECIMAL(18, 2)) AS Discount
    INTO #R
    FROM #E e LEFT JOIN dbo.Users u ON u.Id = e.CashierId
    OUTER APPLY (SELECT TOP 1 CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END
                              + ISNULL(ph.MembershipDiscountAmount, 0) AS Discount, ph.PaymentHeaderId
                 FROM dbo.PaymentHeader ph
                 WHERE e.EntryType IN (''RECEIPT'', ''WALLET'') AND ph.ModuleCode = ''LAB'' AND ph.ModuleRefId = e.LabOrderId AND ph.IsActive = 1
                 ORDER BY ph.PaymentHeaderId) bd
    OUTER APPLY (SELECT TOP 1 pd.ReceiptNo FROM dbo.PaymentDetail pd
                 WHERE bd.PaymentHeaderId IS NOT NULL AND pd.PaymentHeaderId = bd.PaymentHeaderId AND pd.IsActive = 1
                 ORDER BY COALESCE(pd.PaymentDate, pd.CreatedDate), pd.PaymentDetailId) fr
    OUTER APPLY (SELECT TOP 1 bc.DiscountAdjusted FROM dbo.BillCancellation bc
                 WHERE e.EntryType = ''REFUND'' AND bc.ModuleCode = ''LAB'' AND bc.ModuleRefId = e.LabOrderId AND bc.CancellationNo = e.ReceiptNo) ca;');
    -- RS1 and RS2 both total WalletUsed: add the discount next to it
    SET @def = REPLACE(@def, @w, @w + N' ISNULL(SUM(Discount), 0) AS Discount,
           SUM(CASE WHEN Discount > 0 THEN 1 ELSE 0 END) AS DiscountBills,');
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55252, 'usp_Api_LabReport_CashierClosing: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2272 applied: Cashier Day-end Closing - discount column.';
GO
