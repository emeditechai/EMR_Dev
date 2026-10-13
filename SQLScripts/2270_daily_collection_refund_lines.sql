-- ============================================================================================================
-- Migration: 2270_daily_collection_refund_lines.sql
-- Reports > LAB > Daily Collection Register: the cancellations and refunds behind the cash hand-over (2269) are listed
-- line by line, so "cash refunds paid" can be traced to the bill, the items cancelled and who paid the money back.
--   RS10 one row per cancellation made in the period, and per refund paid in the period for an older cancellation:
--        cancellation no / date / full or partial / reason / by, bill, patient, items cancelled, amount cancelled,
--        refund amount / mode / date / by (or pending), and whether it was paid in cash (it is then in the hand-over).
--   Same scope as the receipts: the branch, the billing type filter and the search; a non-administrator sees the
--   cancellations they made and the refunds they paid.
-- Patches the live procedure in place. Run after 2269. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabReport_B2CCollectionRegister'));
IF @def IS NULL THROW 55230, 'usp_Api_LabReport_B2CCollectionRegister not found.', 1;
IF CHARINDEX(N'-- RS7: cash hand-over', @def) = 0 THROW 55231, 'Run script 2269 first.', 1;
IF CHARINDEX(N'-- RS10: cancellations and refunds', @def) = 0
BEGIN
    DECLARE @a NVARCHAR(200) = N'    DROP TABLE #CashIn; DROP TABLE #CashRefund; DROP TABLE #Petty;';
    IF CHARINDEX(@a, @def) = 0 THROW 55232, 'usp_Api_LabReport_B2CCollectionRegister: anchor not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@a, @def), LEN(@a), N'    -- RS10: cancellations and refunds (2270) - cancellations of the period, and refunds of the period
    SELECT bc.CancellationId, bc.CancellationNo, bc.CancellationDate,
           CASE WHEN bc.CancellationType LIKE ''F%'' THEN ''Full'' ELSE ''Partial'' END AS CancellationType,
           bc.CancelledAmount, NULLIF(LTRIM(RTRIM(bc.Reason)), '''') AS Reason, bc.CreatedBy AS CancelledById,
           ISNULL(NULLIF(LTRIM(RTRIM(uc.FullName)), ''''), ISNULL(uc.Username, ''Not recorded'')) AS CancelledBy,
           lo.LabOrderId, lo.BillNo, lo.TokenNo,
           CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ''B2B'' ELSE ''B2C'' END AS BillingType,
           p.PatientCode, LTRIM(RTRIM(ISNULL(p.Salutation, '''') + '' '' + ISNULL(p.FirstName, '''') + '' '' + ISNULL(p.LastName, ''''))) AS PatientName,
           (SELECT STRING_AGG(CONVERT(NVARCHAR(400), COALESCE(CASE WHEN li.[Type] = ''P'' THEN h.Profile_Name END, m.Test_Name, ''Item'')), '', '')
            FROM dbo.BillCancellationItem ci
            LEFT JOIN dbo.LabOrderItem li ON li.LabOrderItemId = ci.LineRefId
            LEFT JOIN dbo.LabInvestigationMaster m ON li.[Type] <> ''P'' AND m.Test_ID = li.InvestigationId
            LEFT JOIN dbo.LabInvestigationProfileHeader h ON li.[Type] = ''P'' AND h.Profile_ID = li.InvestigationId
            WHERE ci.CancellationId = bc.CancellationId AND ISNULL(ci.IsActive, 1) = 1) AS ItemsCancelled,
           rf.RefundId, rf.RefundAmount, NULLIF(LTRIM(RTRIM(rf.RefundMode)), '''') AS RefundMode, rf.RefundDate,
           rf.CreatedBy AS RefundedById,
           ISNULL(NULLIF(LTRIM(RTRIM(ur.FullName)), ''''), ur.Username) AS RefundedBy,
           CAST(CASE WHEN rf.RefundMode LIKE ''%cash%'' THEN 1 ELSE 0 END AS BIT) AS IsCashRefund,
           CAST(CASE WHEN rf.RefundDate >= @From AND rf.RefundDate < @To THEN 1 ELSE 0 END AS BIT) AS RefundInPeriod,
           CASE WHEN rf.RefundId IS NULL THEN ''Refund pending'' WHEN rf.RefundDate >= @From AND rf.RefundDate < @To THEN ''Refunded'' ELSE ''Refunded earlier'' END AS RefundStatus
    FROM dbo.BillCancellation bc
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bc.ModuleRefId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.BillRefund rf ON rf.CancellationId = bc.CancellationId AND rf.ModuleCode = ''LAB'' AND rf.IsActive = 1 AND ISNULL(rf.Status, ''P'') = ''P''
    LEFT  JOIN dbo.Users uc ON uc.Id = bc.CreatedBy
    LEFT  JOIN dbo.Users ur ON ur.Id = rf.CreatedBy
    WHERE bc.ModuleCode = ''LAB'' AND ISNULL(bc.IsActive, 1) = 1 AND lo.BranchId = @BranchId
      AND ((bc.CancellationDate >= @From AND bc.CancellationDate < @To) OR (rf.RefundDate >= @From AND rf.RefundDate < @To))
      AND (@BillingType IS NULL OR (@BillingType = ''B2B'' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = ''B2C'' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (@CollectedBy IS NULL OR bc.CreatedBy = @CollectedBy OR rf.CreatedBy = @CollectedBy)
      AND (@Search IS NULL OR bc.CancellationNo LIKE ''%'' + @Search + ''%'' OR lo.BillNo LIKE ''%'' + @Search + ''%''
           OR lo.TokenNo LIKE ''%'' + @Search + ''%'' OR p.PatientCode LIKE ''%'' + @Search + ''%'' OR p.PhoneNumber LIKE ''%'' + @Search + ''%''
           OR p.FirstName LIKE ''%'' + @Search + ''%'' OR p.LastName LIKE ''%'' + @Search + ''%'')
    ORDER BY COALESCE(rf.RefundDate, bc.CancellationDate) DESC, bc.CancellationId DESC;

' + @a);
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55233, 'usp_Api_LabReport_B2CCollectionRegister: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2270 applied: Daily Collection Register - cancellation and refund lines.';
GO
