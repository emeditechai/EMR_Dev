-- ============================================================================
-- Migration: 2129_lab_formula_calculation_on_entry.sql
-- Description:
--   Lab Reporting Entry calculates a "Target Test (Calculated Parameter)" from the configuration in
--   Lab Master > Lab Formula Component (dbo.LabFormulaParameterMaster). The value is worked out on the
--   server from the formula expression, never in the browser, so the same rule applies wherever it runs.
--
--   dbo.usp_Api_LabFormula_GetForOrder  new: the active formulas whose target test is on this lab order,
--                                       with the expression, rounding and validity note, plus the test
--                                       codes the expression needs.
--   Nothing else changes: no table, no existing procedure.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFormula_GetForOrder
    @LabOrderId INT,
    @CompanyId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Tests booked on this order (the formula target must be one of them to be calculated here)
    SELECT DISTINCT lim.Test_ID, lim.Test_Code
    INTO #OrderTests
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId
    WHERE loi.LabOrderId = @LabOrderId
    UNION
    SELECT DISTINCT lim2.Test_ID, lim2.Test_Code
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim2 ON lim2.Test_ID = sc.InvestigationID
    WHERE sc.Laborderid = @LabOrderId AND sc.Is_Active = 1;

    SELECT f.Parameter_ID,
           f.Test_ID                AS TargetTestId,
           t.Test_Code              AS TargetTestCode,
           t.Test_Name              AS TargetTestName,
           LTRIM(RTRIM(f.Formula_Expression)) AS FormulaExpression,
           f.Rounding_Precision     AS RoundingPrecision,
           f.Validity_Condition     AS ValidityCondition
    FROM dbo.LabFormulaParameterMaster f
    INNER JOIN dbo.LabInvestigationMaster t ON t.Test_ID = f.Test_ID
    WHERE f.IsActive = 1
      AND (@CompanyId IS NULL OR f.CompanyId = @CompanyId)
      AND EXISTS (SELECT 1 FROM #OrderTests ot WHERE ot.Test_ID = f.Test_ID)
    ORDER BY t.Test_Code;

    DROP TABLE #OrderTests;
END;
GO

PRINT 'Script 2129 applied: dbo.usp_Api_LabFormula_GetForOrder created.';
GO
