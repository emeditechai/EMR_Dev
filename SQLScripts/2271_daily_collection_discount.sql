-- ============================================================================================================
-- Migration: 2271_daily_collection_discount.sql
-- Reports > LAB > Daily Collection Register: the discount is shown on the line items.
--   RS5 money receipts: BillGrossAmount (bill before discount) and BillDiscountAmount (the bill's discount, as the LAB
--       Discount Register: the header discount, else the line discounts; plus the membership discount (2241)).
--   RS10 cancellations: DiscountAdjusted (the discount taken back with the cancelled items).
-- Patches the live procedure in place. Run after 2270. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabReport_B2CCollectionRegister'));
IF @def IS NULL THROW 55240, 'usp_Api_LabReport_B2CCollectionRegister not found.', 1;
IF CHARINDEX(N'-- RS10: cancellations and refunds', @def) = 0 THROW 55241, 'Run script 2270 first.', 1;
IF CHARINDEX(N'AS BillDiscountAmount', @def) = 0
BEGIN
    DECLARE @a NVARCHAR(200) = N'ISNULL(ph.NetAmount, lo.TotalAmount)             AS BillNetAmount,';
    DECLARE @b NVARCHAR(200) = N'bc.CancelledAmount, NULLIF(';
    IF CHARINDEX(@a, @def) = 0 OR CHARINDEX(@b, @def) = 0
        THROW 55242, 'usp_Api_LabReport_B2CCollectionRegister: anchor not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@a, @def), LEN(@a), @a + N'
        ISNULL(ph.SubTotal, lo.TotalAmount)              AS BillGrossAmount,      -- 2271
        CAST(CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END
             + ISNULL(ph.MembershipDiscountAmount, 0) AS DECIMAL(18, 2)) AS BillDiscountAmount,   -- 2271');
    SET @def = STUFF(@def, CHARINDEX(@b, @def), LEN(@b), N'bc.CancelledAmount, ISNULL(bc.DiscountAdjusted, 0) AS DiscountAdjusted, NULLIF(');
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55243, 'usp_Api_LabReport_B2CCollectionRegister: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2271 applied: Daily Collection Register - discount on the line items.';
GO
