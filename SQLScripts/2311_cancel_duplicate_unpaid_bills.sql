-- ============================================================================================================
-- Migration: 2311_cancel_duplicate_unpaid_bills.sql
-- Data fix for the duplicate bills made before SQLScripts/2310: when the payment of a LAB B2C booking / OPD
-- registration was refused, the bill stayed behind (no payment, no token) and "Collect" again created a second bill
-- for the same booking. The first bill of each such pair is fully cancelled here with the normal bill cancellation
-- (usp_Bill_Cancel: cancellation no., reason, ledger reversal, samples withdrawn) - nothing is deleted.
--
-- A bill is treated as a duplicate only when ALL of these hold:
--   * it has no payment at all (no active PaymentHeader) and no token (LAB), and it is still active
--   * LAB: a B2C bill with no result entered on any of its samples
--   * the same patient, branch and user billed exactly the same tests / services again within 30 minutes,
--     and that later bill IS paid (the one the patient actually paid for - it is kept)
--
-- HOW TO RUN: first run as is (@Apply = 0) - it only LISTS the bills it would cancel. Check the list, then set
-- @Apply = 1 below and run again to cancel them. Safe to re-run (a cancelled bill is no longer listed).
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;

DECLARE @Apply BIT = 0;      -- 0 = list only, 1 = cancel the listed bills

IF OBJECT_ID('tempdb..#Dup') IS NOT NULL DROP TABLE #Dup;
CREATE TABLE #Dup (
    ModuleCode CHAR(3), ModuleRefId INT, BillNo NVARCHAR(50), BranchId INT, CreatedBy INT, CreatedDate DATETIME,
    KeptRefId INT, KeptBillNo NVARCHAR(50), ItemsJson NVARCHAR(MAX)
);

-- ── LAB B2C ──────────────────────────────────────────────────────────────────────────────────────────────────
;WITH sig AS (
    SELECT lo.LabOrderId, lo.PatientId, lo.BranchId, lo.CreatedBy, lo.CreatedDate, lo.BillNo, lo.TokenNo, lo.IsActive,
           (SELECT STRING_AGG(CONCAT(i.Type, ':', i.InvestigationId, ':', CAST(i.Price AS DECIMAL(12,2))), ',')
                   WITHIN GROUP (ORDER BY i.Type, i.InvestigationId)
              FROM dbo.LabOrderItem i WHERE i.LabOrderId = lo.LabOrderId AND i.IsActive = 1) AS Items,
           CASE WHEN EXISTS (SELECT 1 FROM dbo.PaymentHeader ph WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1)
                THEN 1 ELSE 0 END AS Paid
    FROM dbo.LabOrder lo
    WHERE ISNULL(lo.IsB2B, 0) = 0
)
INSERT INTO #Dup (ModuleCode, ModuleRefId, BillNo, BranchId, CreatedBy, CreatedDate, KeptRefId, KeptBillNo, ItemsJson)
SELECT 'LAB', o.LabOrderId, o.BillNo, o.BranchId, o.CreatedBy, o.CreatedDate, k.LabOrderId, k.BillNo,
       (SELECT x.LineRefId AS lineRefId, 0 AS amount
          FROM (SELECT i.LabOrderItemId AS LineRefId FROM dbo.LabOrderItem i WHERE i.LabOrderId = o.LabOrderId AND i.IsActive = 1
                UNION ALL
                SELECT -m.LabOrderMiscChargeId FROM dbo.LabOrderMiscCharge m WHERE m.LabOrderId = o.LabOrderId AND m.IsActive = 1) x
         FOR JSON PATH)
FROM sig o
CROSS APPLY (SELECT TOP 1 k.LabOrderId, k.BillNo FROM sig k
              WHERE k.PatientId = o.PatientId AND k.BranchId = o.BranchId AND ISNULL(k.CreatedBy, -1) = ISNULL(o.CreatedBy, -1)
                AND k.Items = o.Items AND k.Paid = 1 AND k.IsActive = 1 AND k.LabOrderId > o.LabOrderId
                AND k.CreatedDate BETWEEN o.CreatedDate AND DATEADD(MINUTE, 30, o.CreatedDate)
              ORDER BY k.LabOrderId) k
WHERE o.Paid = 0 AND o.IsActive = 1 AND NULLIF(LTRIM(RTRIM(o.TokenNo)), '') IS NULL AND o.Items IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.labentrydetails led WHERE led.LabOrderId = o.LabOrderId AND led.IsActive = 1);

-- ── OPD ──────────────────────────────────────────────────────────────────────────────────────────────────────
;WITH sig AS (
    SELECT s.OPDServiceId, s.PatientId, s.BranchId, s.CreatedBy, s.CreatedDate, s.OPDBillNo, s.IsActive,
           (SELECT STRING_AGG(CONCAT(i.ServiceType, ':', ISNULL(i.ServiceId, 0), ':', CAST(i.ServiceCharges AS DECIMAL(12,2))), ',')
                   WITHIN GROUP (ORDER BY i.ServiceType, i.ServiceId)
              FROM dbo.PatientOPDServiceItem i WHERE i.OPDServiceId = s.OPDServiceId AND i.IsActive = 1) AS Items,
           CASE WHEN EXISTS (SELECT 1 FROM dbo.PaymentHeader ph WHERE ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1)
                THEN 1 ELSE 0 END AS Paid
    FROM dbo.PatientOPDService s
)
INSERT INTO #Dup (ModuleCode, ModuleRefId, BillNo, BranchId, CreatedBy, CreatedDate, KeptRefId, KeptBillNo, ItemsJson)
SELECT 'OPD', o.OPDServiceId, o.OPDBillNo, o.BranchId, o.CreatedBy, o.CreatedDate, k.OPDServiceId, k.OPDBillNo,
       (SELECT i.ItemId AS lineRefId, 0 AS amount FROM dbo.PatientOPDServiceItem i
         WHERE i.OPDServiceId = o.OPDServiceId AND i.IsActive = 1 FOR JSON PATH)
FROM sig o
CROSS APPLY (SELECT TOP 1 k.OPDServiceId, k.OPDBillNo FROM sig k
              WHERE k.PatientId = o.PatientId AND k.BranchId = o.BranchId AND ISNULL(k.CreatedBy, -1) = ISNULL(o.CreatedBy, -1)
                AND k.Items = o.Items AND k.Paid = 1 AND k.IsActive = 1 AND k.OPDServiceId > o.OPDServiceId
                AND k.CreatedDate BETWEEN o.CreatedDate AND DATEADD(MINUTE, 30, o.CreatedDate)
              ORDER BY k.OPDServiceId) k
WHERE o.Paid = 0 AND o.IsActive = 1 AND o.Items IS NOT NULL;

SELECT ModuleCode, BillNo AS DuplicateBill, CONVERT(VARCHAR(19), CreatedDate, 120) AS CreatedAt,
       KeptBillNo AS KeptPaidBill, CASE WHEN @Apply = 1 THEN 'cancelling' ELSE 'would be cancelled (set @Apply = 1)' END AS Action
  FROM #Dup ORDER BY ModuleCode, ModuleRefId;

IF @Apply = 1
BEGIN
    DECLARE @Mod CHAR(3), @Ref INT, @Branch INT, @By INT, @Bill NVARCHAR(50), @Kept NVARCHAR(50), @Json NVARCHAR(MAX),
            @Reason NVARCHAR(500), @CancelId INT, @CancelNo NVARCHAR(50), @Done INT = 0, @Failed INT = 0;
    DECLARE dc CURSOR LOCAL FAST_FORWARD FOR
        SELECT ModuleCode, ModuleRefId, BranchId, CreatedBy, BillNo, KeptBillNo, ItemsJson FROM #Dup ORDER BY ModuleCode, ModuleRefId;
    OPEN dc; FETCH NEXT FROM dc INTO @Mod, @Ref, @Branch, @By, @Bill, @Kept, @Json;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Reason = CONCAT(N'Duplicate bill: created by a refused payment and billed again as ', @Kept,
                             N' (system correction, SQLScripts/2311).');
        BEGIN TRY
            SET @CancelId = NULL; SET @CancelNo = NULL;
            EXEC dbo.usp_Bill_Cancel @ModuleCode = @Mod, @ModuleRefId = @Ref, @BranchId = @Branch, @LineItemsJson = @Json,
                 @Reason = @Reason, @DiscountAdjusted = 0, @UserId = @By,
                 @CancellationId = @CancelId OUTPUT, @CancellationNo = @CancelNo OUTPUT, @AcknowledgeLabWarnings = 1;
            PRINT CONCAT('Cancelled ', @Bill, ' (', @CancelNo, '); kept ', @Kept);
            SET @Done += 1;
        END TRY
        BEGIN CATCH
            PRINT CONCAT('NOT cancelled ', @Bill, ': ', ERROR_MESSAGE());
            SET @Failed += 1;
        END CATCH
        FETCH NEXT FROM dc INTO @Mod, @Ref, @Branch, @By, @Bill, @Kept, @Json;
    END
    CLOSE dc; DEALLOCATE dc;
    PRINT CONCAT('Script 2311: ', @Done, ' duplicate bill(s) cancelled, ', @Failed, ' not cancelled.');
END
ELSE
BEGIN
    DECLARE @Found INT = (SELECT COUNT(*) FROM #Dup);
    PRINT CONCAT('Script 2311: ', @Found, ' duplicate bill(s) found - nothing changed (set @Apply = 1 to cancel them).');
END

DROP TABLE #Dup;
GO
