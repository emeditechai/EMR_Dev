-- ============================================================================================================
-- Migration: 2353_lab_collection_membership_discount_fix.sql
-- Reports > LAB > Daily Collection Register (money receipts: Discount) and Cashier Day-end Closing (Discount):
-- a bill with a membership discount showed it twice (e.g. LAB/HO2627000309: Rs 135 instead of Rs 67.50).
--   LAB billing writes the membership discount into the line discounts (PaymentLineItem.LineDiscountAmount, so
--   PaymentHeader.LineDiscountTotal = header discount + membership discount), and 2271 / 2272 added
--   PaymentHeader.MembershipDiscountAmount on top of that.
--   The bill's discount is now the larger of the header discount and the line discounts: for every bill without a
--   membership discount this is the same figure as before; with one it is the true total once.
-- Patches the live procedures in place. Run after 2271 and 2272. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @oldCase NVARCHAR(200) = N'ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END';
DECLARE @newCase NVARCHAR(200) = N'ISNULL(ph.HeaderDiscountAmount, 0) > ISNULL(ph.LineDiscountTotal, 0) THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END';
DECLARE @def NVARCHAR(MAX), @c INT, @m NVARCHAR(200);

-- ── Daily Collection Register ──────────────────────────────────────────────────────────────────
SET @def = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabReport_B2CCollectionRegister'));
IF @def IS NULL THROW 55260, 'usp_Api_LabReport_B2CCollectionRegister not found.', 1;
IF CHARINDEX(N'-- 2353', @def) = 0
BEGIN
    SET @m = N'+ ISNULL(ph.MembershipDiscountAmount, 0) AS DECIMAL(18, 2)) AS BillDiscountAmount,';
    IF CHARINDEX(@oldCase, @def) = 0 OR CHARINDEX(@m, @def) = 0
        THROW 55261, 'usp_Api_LabReport_B2CCollectionRegister: run 2271 first (anchor not found); not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@oldCase, @def), LEN(@oldCase), @newCase);
    SET @def = STUFF(@def, CHARINDEX(@m, @def), LEN(@m),
        N'AS DECIMAL(18, 2)) AS BillDiscountAmount,   -- 2353: membership is already in the line discounts');
    SET @c = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55262, 'usp_Api_LabReport_B2CCollectionRegister: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

-- ── Cashier Day-end Closing ────────────────────────────────────────────────────────────────────
DECLARE @oldCase NVARCHAR(200) = N'ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END';
DECLARE @newCase NVARCHAR(200) = N'ISNULL(ph.HeaderDiscountAmount, 0) > ISNULL(ph.LineDiscountTotal, 0) THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END';
DECLARE @def NVARCHAR(MAX), @c INT, @m NVARCHAR(200);
SET @def = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabReport_CashierClosing'));
IF @def IS NULL THROW 55263, 'usp_Api_LabReport_CashierClosing not found.', 1;
IF CHARINDEX(N'-- 2353', @def) = 0
BEGIN
    SET @m = N'+ ISNULL(ph.MembershipDiscountAmount, 0) AS Discount, ph.PaymentHeaderId';
    IF CHARINDEX(@oldCase, @def) = 0 OR CHARINDEX(@m, @def) = 0
        THROW 55264, 'usp_Api_LabReport_CashierClosing: run 2272 first (anchor not found); not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@oldCase, @def), LEN(@oldCase), @newCase);
    SET @def = STUFF(@def, CHARINDEX(@m, @def), LEN(@m),
        N'AS Discount, ph.PaymentHeaderId   -- 2353: membership is already in the line discounts');
    SET @c = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55265, 'usp_Api_LabReport_CashierClosing: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2353 applied: Daily Collection Register / Cashier Closing - membership discount counted once.';
GO
