-- ============================================================================================================
-- Migration: 2291_b2b_partner_billing_test_lines.sql
-- Reports > LAB > B2B Partner Billing Register: the Detail tab shows every test of each bill as a line item (code, name,
-- type, department, MRP, contract rate, margin, urgent), and the Excel / PDF exports carry the same lines.
-- dbo.usp_Api_LabReport_B2BPartnerBilling is patched in place: a 5th result set ("lines") is added after the existing
-- four; the summary, groups, rows and filter options are unchanged. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_Api_LabReport_B2BPartnerBilling'));
IF @def IS NULL THROW 50291, 'dbo.usp_Api_LabReport_B2BPartnerBilling not found.', 1;

IF CHARINDEX(N'RS5 lines v2', @def) = 0
BEGIN
    DECLARE @anchor NVARCHAR(50) = N'DROP TABLE #R;';
    -- an earlier version of this patch (tests only): take its block out first
    DECLARE @old INT = CHARINDEX(N'-- RS5 lines', @def);
    IF @old > 0 SET @def = STUFF(@def, @old, CHARINDEX(@anchor, @def, @old) - @old, N'');
    IF (LEN(@def) - LEN(REPLACE(@def, @anchor, ''))) / LEN(@anchor) <> 1
        THROW 50292, 'usp_Api_LabReport_B2BPartnerBilling is not the expected version; patch not applied.', 1;

    SET @def = REPLACE(@def, @anchor, N'-- RS5 lines v2: every test and misc charge of the bills above (script 2291)
    SELECT x.LabOrderId, ROW_NUMBER() OVER (PARTITION BY x.LabOrderId ORDER BY x.Kind, x.ItemId) AS LineSeq,
           x.TestCode, x.TestName, x.ItemType, x.Department, x.MrpAmount, x.ContractAmount, x.MarginAmount, x.IsUrgent
      FROM (
    SELECT loi.LabOrderId, 0 AS Kind, loi.LabOrderItemId AS ItemId,
           CASE WHEN loi.Type = ''P'' THEN pkg.Profile_Code ELSE lim.Test_Code END AS TestCode,
           ISNULL(CASE WHEN loi.Type = ''P'' THEN pkg.Profile_Name ELSE lim.Test_Name END, ''Unknown test'') AS TestName,
           CASE WHEN loi.Type = ''P'' THEN ''Package'' WHEN ISNULL(lim.Is_Profile_Test, 0) = 1 THEN ''Profile'' ELSE ''Test'' END AS ItemType,
           dm.DeptName AS Department,
           CAST(ISNULL(loi.Price, 0) AS DECIMAL(18, 2)) AS MrpAmount,
           CAST(ISNULL(loi.B2BRate, ISNULL(loi.Price, 0)) AS DECIMAL(18, 2)) AS ContractAmount,
           CAST(ISNULL(loi.Price, 0) - ISNULL(loi.B2BRate, ISNULL(loi.Price, 0)) AS DECIMAL(18, 2)) AS MarginAmount,
           CAST(ISNULL(loi.IsUrgent, 0) AS BIT) AS IsUrgent
      FROM #R r
      JOIN dbo.LabOrder lo ON lo.LabOrderId = r.LabOrderId
      JOIN dbo.LabOrderItem loi ON loi.LabOrderId = r.LabOrderId AND (loi.IsActive = 1 OR lo.IsActive = 0)
      LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = ''P''
      LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, ''I'') <> ''P''
      LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    UNION ALL
    -- misc charges billed with the tests (Home Collection / Misc, SQLScripts/2240): amount with GST
    SELECT mc.LabOrderId, 1, mc.LabOrderMiscChargeId, ''MISC'', mc.ChargeName, ''Misc'', ISNULL(mc.ChargeType, ''Misc Charge''),
           CAST(ISNULL(mc.NetAmount, mc.Amount) AS DECIMAL(18, 2)), CAST(ISNULL(mc.NetAmount, mc.Amount) AS DECIMAL(18, 2)), CAST(0 AS DECIMAL(18, 2)), CAST(0 AS BIT)
      FROM #R r
      JOIN dbo.LabOrder lo ON lo.LabOrderId = r.LabOrderId
      JOIN dbo.LabOrderMiscCharge mc ON mc.LabOrderId = r.LabOrderId AND (mc.IsActive = 1 OR lo.IsActive = 0)
      ) x
     ORDER BY x.LabOrderId DESC, LineSeq;

    ' + @anchor);

    DECLARE @p INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    IF @p > 0 AND SUBSTRING(@def, @p, 15) NOT LIKE N'CREATE OR ALTER%'
        SET @def = STUFF(@def, @p, CHARINDEX(N'PROCEDURE', @def, @p) - @p, N'CREATE OR ALTER ');
    EXEC sys.sp_executesql @def;
    PRINT 'usp_Api_LabReport_B2BPartnerBilling: test lines (RS5) added.';
END
ELSE PRINT 'usp_Api_LabReport_B2BPartnerBilling already returns test lines.';
GO
PRINT 'Script 2291 applied.';
GO
