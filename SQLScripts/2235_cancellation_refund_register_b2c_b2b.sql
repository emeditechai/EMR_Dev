-- ============================================================================
-- Migration: 2235_cancellation_refund_register_b2c_b2b.sql
-- Description: Cancellation & Refund Register - B2C and B2B tabs and test-wise cancelled details; B2B valued at the
--   franchise / company contract rate:
--   * usp_Bill_Cancel: each cancelled line is valued from the bill (LAB B2C price, LAB B2B contract rate B2BRate,
--     OPD charges) and must belong to the bill - the screen's amounts are no longer trusted.
--   * usp_Bill_GetDetailForCancellation: a B2B bill shows its tests at the contract rate (MRP alongside).
--   * usp_Api_LabReport_CancellationRefund: @BillingType (B2C / B2B), partner (franchise / company) on each row,
--     refund pending by the standard rule (received - bill as it stands, shared out over the bill's cancellations
--     oldest first, never more than a cancellation's own amount), and RS5 = the cancelled tests (MRP, discount,
--     contract rate, net).
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Bill_Cancel
    @ModuleCode          CHAR(3),
    @ModuleRefId         INT,
    @BranchId            INT,
    @LineItemsJson       NVARCHAR(MAX),
    @Reason              NVARCHAR(500),
    @DiscountAdjusted    DECIMAL(10,2),
    @UserId              INT,
    @CancellationId      INT OUTPUT,
    @CancellationNo      NVARCHAR(50) OUTPUT,
    @AcknowledgeLabWarnings BIT = 0      -- LAB: user confirmed that collected samples / draft results will be discarded
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate cancellation number
        EXEC dbo.usp_Bill_GetNextCancellationNo @ModuleCode, @BranchId, @CancellationNo OUTPUT;

        -- Parse line items from JSON
        DECLARE @Items TABLE (LineRefId INT, Amount DECIMAL(10,2));
        INSERT INTO @Items (LineRefId, Amount)
        SELECT 
            CAST(JSON_VALUE(j.value, '$.lineRefId') AS INT),
            CAST(JSON_VALUE(j.value, '$.amount') AS DECIMAL(10,2))
        FROM OPENJSON(@LineItemsJson) j;

        DECLARE @TotalItems INT = (SELECT COUNT(*) FROM @Items);
        IF @TotalItems = 0
            THROW 50001, 'No items selected for cancellation.', 1;

        -- 2235: every line must belong to this bill, and is valued from the bill itself (not from the screen):
        -- LAB B2C at its price, LAB B2B at the franchise / company contract rate (B2BRate), OPD at its charges
        IF @ModuleCode = 'LAB'
        BEGIN
            IF EXISTS (SELECT 1 FROM @Items i WHERE NOT EXISTS (SELECT 1 FROM dbo.LabOrderItem loi WHERE loi.LabOrderItemId = i.LineRefId AND loi.LabOrderId = @ModuleRefId))
                THROW 50003, 'A selected item does not belong to this bill.', 1;
            UPDATE i SET Amount = CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(loi.B2BRate, ISNULL(loi.Price, 0)) ELSE ISNULL(loi.Price, 0) END
            FROM @Items i
            INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = i.LineRefId
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId;
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            IF EXISTS (SELECT 1 FROM @Items i WHERE NOT EXISTS (SELECT 1 FROM dbo.PatientOPDServiceItem si WHERE si.ItemId = i.LineRefId AND si.OPDServiceId = @ModuleRefId))
                THROW 50003, 'A selected item does not belong to this bill.', 1;
            UPDATE i SET Amount = ISNULL(si.ServiceCharges, 0)
            FROM @Items i INNER JOIN dbo.PatientOPDServiceItem si ON si.ItemId = i.LineRefId;
        END

        -- LAB: a test whose result is already submitted / validated / approved cannot be cancelled from billing;
        -- the lab has to withdraw the result first (reject the sample on Report Entry, or Un-Authorize an approved report).
        IF @ModuleCode = 'LAB'
        BEGIN
            DECLARE @LabMsg NVARCHAR(2048);

            SELECT @LabMsg = STRING_AGG(CAST(
                       ISNULL(pkg.Profile_Name, lm.Test_Name) + ' ('
                       + CASE WHEN cs.ApprovedCount > 0 THEN 'report approved'
                              WHEN cs.ValidatedCount > 0 THEN 'result validated'
                              ELSE 'result submitted' END + ')' AS NVARCHAR(MAX)), '; ')
            FROM @Items i
            INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = i.LineRefId AND loi.LabOrderId = @ModuleRefId
            INNER JOIN dbo.ufn_LabOrderItemCancelState(@ModuleRefId) cs ON cs.LabOrderItemId = loi.LabOrderItemId
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster lm ON lm.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
            WHERE cs.CancelStage = 'BLOCKED';

            IF @LabMsg IS NOT NULL
            BEGIN
                SET @LabMsg = LEFT(N'Cannot cancel: ' + @LabMsg
                    + N'. The lab must first withdraw the result (reject the sample on Report Entry; an approved report has to be Un-Authorized first).', 2048);
                THROW 50003, @LabMsg, 1;
            END

            IF ISNULL(@AcknowledgeLabWarnings, 0) = 0
               AND EXISTS (SELECT 1 FROM @Items i
                           INNER JOIN dbo.ufn_LabOrderItemCancelState(@ModuleRefId) cs ON cs.LabOrderItemId = i.LineRefId
                           WHERE cs.CancelStage = 'WARN')
                THROW 50004, 'Some selected tests already have a collected sample or a draft result. Confirm that they will be discarded to continue.', 1;
        END

        -- Validate: check items are not already cancelled
        IF EXISTS (
            SELECT 1 FROM @Items i
            INNER JOIN dbo.BillCancellationItem bci ON bci.LineRefId = i.LineRefId
            INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
            WHERE bc.ModuleCode = @ModuleCode AND bc.IsActive = 1
        )
            THROW 50002, 'One or more selected items are already cancelled.', 1;

        DECLARE @CancelledAmount DECIMAL(10,2) = (SELECT SUM(Amount) FROM @Items);

        -- Determine full or partial
        DECLARE @TotalBillItems INT;
        DECLARE @CancellationType CHAR(1);

        IF @ModuleCode = 'LAB'
        BEGIN
            SELECT @TotalBillItems = COUNT(*) FROM dbo.LabOrderItem 
            WHERE LabOrderId = @ModuleRefId AND IsActive = 1;
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            SELECT @TotalBillItems = COUNT(*) FROM dbo.PatientOPDServiceItem 
            WHERE OPDServiceId = @ModuleRefId AND IsActive = 1;
        END

        SET @CancellationType = CASE WHEN @TotalItems >= @TotalBillItems THEN 'F' ELSE 'P' END;

        -- Insert BillCancellation header
        INSERT INTO dbo.BillCancellation 
            (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate,
             CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@ModuleCode, @ModuleRefId, @CancellationNo, @CancellationType, GETDATE(),
             @CancelledAmount, ISNULL(@DiscountAdjusted, 0), @Reason, 'C', @UserId, GETDATE(), 1);

        SET @CancellationId = SCOPE_IDENTITY();

        -- Insert BillCancellationItem rows
        INSERT INTO dbo.BillCancellationItem (CancellationId, LineRefId, OriginalAmount, CancelledAmount, IsActive)
        SELECT @CancellationId, LineRefId, Amount, Amount, 1
        FROM @Items;

        -- Mark items as inactive in source table
        IF @ModuleCode = 'LAB'
        BEGIN
            -- the samples of the cancelled lines leave every lab worklist, and a draft result is discarded
            DECLARE @CancelledSamples TABLE (SampleCollectionId BIGINT PRIMARY KEY);
            INSERT INTO @CancelledSamples (SampleCollectionId)
            SELECT DISTINCT m.SampleCollectionId
            FROM dbo.ufn_LabOrderItemSamples(@ModuleRefId) m
            WHERE m.LabOrderItemId IN (SELECT LineRefId FROM @Items);

            UPDATE led SET led.IsActive = 0, led.ModifiedBy = @UserId, led.ModifiedDate = GETDATE()
            FROM dbo.labentrydetails led
            INNER JOIN @CancelledSamples x ON x.SampleCollectionId = led.SamplecollectionID
            WHERE led.IsActive = 1;

            UPDATE sc SET sc.Iscancelled = 1, sc.ModifiedBy = @UserId, sc.ModifiedDate = GETDATE()
            FROM dbo.SampleCollection sc
            INNER JOIN @CancelledSamples x ON x.SampleCollectionId = sc.samplecollectionID;

            UPDATE dbo.LabOrderItem 
            SET IsActive = 0
            WHERE LabOrderItemId IN (SELECT LineRefId FROM @Items);
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            UPDATE dbo.PatientOPDServiceItem 
            SET IsActive = 0
            WHERE ItemId IN (SELECT LineRefId FROM @Items);
        END

        -- Update PaymentHeader
        IF @CancellationType = 'F'
        BEGIN
            -- Full cancellation: NetAmount and BalanceDue become 0
            UPDATE dbo.PaymentHeader
            SET NetAmount            = 0,
                BalanceDue           = 0,
                HeaderDiscountAmount = 0,
                RoundOffAmount       = 0,
                LineDiscountTotal    = 0,
                LastModifiedDate     = GETDATE(),
                LastModifiedBy       = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END
        ELSE
        BEGIN
            -- Partial cancellation: reduce NetAmount by (CancelledAmount - DiscountAdjusted)
            UPDATE dbo.PaymentHeader
            SET NetAmount    = CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0 ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END,
                -- 2230: due = the reduced bill - what has been paid (an overpayment stays visible for the refund)
                BalanceDue   = CASE WHEN (CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0
                                               ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END) - TotalPaid > 0
                                    THEN (CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0
                                               ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END) - TotalPaid
                                    ELSE 0 END,
                HeaderDiscountAmount = CASE WHEN (HeaderDiscountAmount - ISNULL(@DiscountAdjusted, 0)) < 0 THEN 0 ELSE (HeaderDiscountAmount - ISNULL(@DiscountAdjusted, 0)) END,
                -- 2231: status follows the reduced bill: covered = Paid (any excess is for refund), else Partial / Unpaid
                PaymentStatus = CASE WHEN TotalPaid >= (CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0
                                                           ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END) THEN 'P'
                                     WHEN TotalPaid > 0 THEN 'R' ELSE 'U' END,
                LastModifiedDate = GETDATE(),
                LastModifiedBy   = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END

        -- 2232: the cancellation entry (Dr Revenue / Cr the bill's receivable), then discount / round-off follow the bill
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'CANCEL', @RefId = @CancellationId, @UserId = @UserId;
        DECLARE @AdjHeaderId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1);
        IF @AdjHeaderId IS NOT NULL
            EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'ADJUST', @RefId = @AdjHeaderId, @UserId = @UserId;

        -- If full cancellation, mark LabOrder/OPDService as inactive
        IF @CancellationType = 'F'
        BEGIN
            IF @ModuleCode = 'LAB'
                UPDATE dbo.LabOrder SET IsActive = 0 WHERE LabOrderId = @ModuleRefId;
            IF @ModuleCode = 'OPD'
                UPDATE dbo.PatientOPDService SET IsActive = 0 WHERE OPDServiceId = @ModuleRefId;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Bill_GetDetailForCancellation
    @ModuleCode  NVARCHAR(20),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ModuleCode = 'LAB'
    BEGIN
        SELECT
            lo.LabOrderId        AS ModuleRefId,
            'LAB'                AS ModuleCode,
            lo.BillNo,
            lo.OrderDate         AS BillDate,
            CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE lo.TotalAmount END AS TotalAmount,   -- 2235
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.EmailId,
            p.Address,
            CASE WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentHeaderId, 0)   AS PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U')   AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)         AS TotalPaid,
            ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, lo.TotalAmount)  AS NetAmount,
            ISNULL(ph.HeaderDiscountAmount, 0)    AS TotalDiscountAmount,
            ISNULL(ph.LineDiscountTotal, 0)       AS LineDiscountTotal,
            ISNULL(ph.RoundOffAmount, 0)          AS RoundOffAmount,
            b.BranchName
        FROM dbo.LabOrder lo
        INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = lo.BranchId
        WHERE lo.LabOrderId = @ModuleRefId;

        SELECT
            loi.LabOrderItemId   AS LineRefId,
            loi.LabOrderId       AS ModuleRefId,
            ISNULL(pkg.Profile_Name, lm.Test_Name) AS ItemName,
            ISNULL(pkg.Profile_Code, lm.Test_Code) AS ItemCode,
            -- 2235: a B2B bill is charged at the franchise / company contract rate
            CASE WHEN ISNULL(lo2.IsB2B, 0) = 1 THEN ISNULL(loi.B2BRate, loi.Price) ELSE loi.Price END AS OriginalAmount,
            CASE WHEN ISNULL(lo2.IsB2B, 0) = 1 THEN ISNULL(loi.B2BRate, loi.Price) ELSE ISNULL(pli.NetLineAmount, loi.Price) END AS NetAmount,
            loi.Price            AS Mrp,
            ISNULL(pli.LineDiscountAmount, 0)    AS DiscountAmount,
            loi.IsActive,
            ISNULL(
                (SELECT SUM(bci.CancelledAmount) 
                 FROM dbo.BillCancellationItem bci
                 INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                 WHERE bci.LineRefId = loi.LabOrderItemId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1)
            , 0) AS CancelledAmount,
            CASE WHEN loi.IsActive = 0 THEN 1
                 WHEN EXISTS (SELECT 1 FROM dbo.BillCancellationItem bci
                              INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                              WHERE bci.LineRefId = loi.LabOrderItemId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS IsCancelled,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE lst.Sample_Name END AS SampleTypeName,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE dm.DeptName END AS DepartmentName,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE lc.Category_Name END AS CategoryName,
            -- Lab progress of this line's tests: decides whether it may be cancelled (dbo.ufn_LabOrderItemCancelState)
            ISNULL(cs.TestCount, 0)          AS TestCount,
            ISNULL(cs.NotCollectedCount, 0)  AS NotCollectedCount,
            ISNULL(cs.RejectedCount, 0)      AS RejectedCount,
            ISNULL(cs.CollectedCount, 0)     AS CollectedCount,
            ISNULL(cs.DraftCount, 0)         AS DraftCount,
            ISNULL(cs.SubmittedCount, 0)     AS SubmittedCount,
            ISNULL(cs.ValidatedCount, 0)     AS ValidatedCount,
            ISNULL(cs.ApprovedCount, 0)      AS ApprovedCount,
            ISNULL(cs.TransferredCount, 0)   AS TransferredCount,
            ISNULL(cs.OutsourcedCount, 0)    AS OutsourcedCount,
            CASE WHEN loi.IsActive = 0 THEN 'CANCELLED' ELSE ISNULL(cs.CancelStage, 'ALLOWED') END AS CancelStage
        FROM dbo.LabOrderItem loi
        INNER JOIN dbo.LabOrder lo2 ON lo2.LabOrderId = loi.LabOrderId
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
        LEFT JOIN dbo.LabInvestigationMaster lm ON lm.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
        LEFT JOIN dbo.LabSampleTypeMaster lst ON lst.Sample_Type_ID = lm.Sample_Type_ID
        LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lm.Department_ID
        LEFT JOIN dbo.LabTestCategoryMaster lc ON lc.Category_ID = lm.Category_ID
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = loi.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId 
            AND (pli.ModuleLineRefId = loi.LabOrderItemId OR pli.ModuleLineRefId = loi.InvestigationId)
            AND pli.IsActive = 1
        LEFT JOIN dbo.ufn_LabOrderItemCancelState(@ModuleRefId) cs ON cs.LabOrderItemId = loi.LabOrderItemId
        WHERE loi.LabOrderId = @ModuleRefId
        ORDER BY loi.LabOrderItemId;

        SELECT
            pd.PaymentDetailId,
            pm.MethodName,
            pm.MethodCode,
            pd.PaidAmount,
            pd.PaymentDate,
            pd.ReceiptNo,
            pd.TransactionRef
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @ModuleRefId AND pd.IsActive = 1;
    END

    IF @ModuleCode = 'OPD'
    BEGIN
        SELECT
            os.OPDServiceId         AS ModuleRefId,
            'OPD'                   AS ModuleCode,
            os.OPDBillNo            AS BillNo,
            os.VisitDate            AS BillDate,
            os.TotalAmount,
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.EmailId,
            p.Address,
            CASE WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentHeaderId, 0)   AS PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U')   AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)         AS TotalPaid,
            ISNULL(ph.BalanceDue, os.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, os.TotalAmount)  AS NetAmount,
            ISNULL(ph.HeaderDiscountAmount, 0)    AS TotalDiscountAmount,
            ISNULL(ph.LineDiscountTotal, 0)       AS LineDiscountTotal,
            ISNULL(ph.RoundOffAmount, 0)          AS RoundOffAmount,
            b.BranchName
        FROM dbo.PatientOPDService os
        INNER JOIN dbo.PatientMaster p ON p.PatientId = os.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = os.OPDServiceId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = os.BranchId
        WHERE os.OPDServiceId = @ModuleRefId;

        SELECT
            si.ItemId             AS LineRefId,
            si.OPDServiceId       AS ModuleRefId,
            ISNULL(sm.ItemName, si.ServiceType) AS ItemName,
            si.ServiceType        AS ItemCode,
            si.ServiceCharges     AS OriginalAmount,
            ISNULL(pli.NetLineAmount, si.ServiceCharges) AS NetAmount,
            ISNULL(pli.LineDiscountAmount, 0)           AS DiscountAmount,
            si.IsActive,
            ISNULL(
                (SELECT SUM(bci.CancelledAmount) 
                 FROM dbo.BillCancellationItem bci
                 INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                 WHERE bci.LineRefId = si.ItemId AND bc.ModuleCode = 'OPD' AND bc.IsActive = 1)
            , 0) AS CancelledAmount,
            CASE WHEN si.IsActive = 0 THEN 1
                 WHEN EXISTS (SELECT 1 FROM dbo.BillCancellationItem bci
                              INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                              WHERE bci.LineRefId = si.ItemId AND bc.ModuleCode = 'OPD' AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS IsCancelled,
            NULL AS SampleTypeName,
            NULL AS DepartmentName,
            NULL AS CategoryName
        FROM dbo.PatientOPDServiceItem si
        LEFT JOIN dbo.ServiceMaster sm    ON sm.ServiceId = si.ServiceId
        LEFT JOIN dbo.PaymentHeader ph     ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = si.OPDServiceId AND ph.IsActive = 1
        LEFT JOIN dbo.PaymentLineItem pli  ON pli.PaymentHeaderId = ph.PaymentHeaderId 
                                           AND pli.ModuleLineRefId = si.ItemId 
                                           AND pli.IsActive = 1
        WHERE si.OPDServiceId = @ModuleRefId
        ORDER BY si.ItemId;

        SELECT
            pd.PaymentDetailId,
            pm.MethodName,
            pm.MethodCode,
            pd.PaidAmount,
            pd.PaymentDate,
            pd.ReceiptNo,
            pd.TransactionRef
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE ph.ModuleCode = 'OPD' AND ph.ModuleRefId = @ModuleRefId AND pd.IsActive = 1;
    END
END;
GO

-- ── the register ────────────────────────────────────────────────────────────
-- ============================================================================
-- LR-06 Cancellation & Refund Register - LAB cancellations in the period (cancellation date) with the refund made
-- against each. B2C and B2B separately (@BillingType); a B2B cancellation is valued at the partner's contract rate.
-- Refund pending (standard rule, all billing types): what the bill received (receipts - refunds) over the bill as it
-- stands after its cancellations, shared out over the bill's cancellations oldest first, each capped at its own net
-- amount less what was already refunded against it.
-- Own data: cancellations the user made, or refunds the user processed.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_CancellationRefund
    @BranchId         INT,
    @FromDate         DATE,
    @ToDate           DATE,
    @CancellationType CHAR(1)       = NULL,   -- F / P
    @RefundStatus     VARCHAR(10)   = NULL,   -- REFUNDED / PENDING / NOTDUE
    @CancelledBy      INT           = NULL,
    @Search           NVARCHAR(100) = NULL,
    @UserId           INT           = NULL,
    @IsAdmin          BIT           = 0,
    @IsSuperAdmin     BIT           = 0,
    @BillingType      VARCHAR(5)    = NULL    -- B2C / B2B (2235); NULL = both
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @RefundStatus = NULLIF(UPPER(LTRIM(RTRIM(@RefundStatus))), '');
    SET @CancellationType = NULLIF(UPPER(LTRIM(RTRIM(@CancellationType))), '');
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');

    -- every active LAB cancellation of the branch's bills, with its net amount and what was refunded against it
    ;WITH c AS (
        SELECT bc.CancellationId, bc.ModuleRefId AS LabOrderId, bc.CancellationDate,
               CAST(bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) AS DECIMAL(18, 2)) AS NetCancelled,
               CAST(ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.BillRefund r WHERE r.CancellationId = bc.CancellationId AND r.IsActive = 1), 0) AS DECIMAL(18, 2)) AS Refunded
        FROM dbo.BillCancellation bc
        INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bc.ModuleRefId
        WHERE bc.ModuleCode = 'LAB' AND bc.IsActive = 1 AND lo.BranchId = @BranchId),
    -- what each bill still has to give back: received (receipts - refunds) over the bill as it stands now
    b AS (
        SELECT x.LabOrderId,
               CASE WHEN x.Received - x.BillNow > 0 THEN x.Received - x.BillNow ELSE 0 END AS Refundable
        FROM (SELECT lo.LabOrderId,
                     ISNULL(ph.NetAmount, 0) AS BillNow,
                     ISNULL((SELECT SUM(d.PaidAmount) FROM dbo.PaymentDetail d WHERE d.PaymentHeaderId = ph.PaymentHeaderId AND d.IsActive = 1), 0)
                   - ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.BillRefund r WHERE r.ModuleCode = 'LAB' AND r.ModuleRefId = lo.LabOrderId AND r.IsActive = 1), 0) AS Received
              FROM dbo.LabOrder lo
              INNER JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
              WHERE lo.LabOrderId IN (SELECT LabOrderId FROM c)) x),
    -- shared out over the bill's cancellations, oldest first, each up to what it can still take back
    a AS (
        SELECT c.CancellationId,
               CASE WHEN c.NetCancelled - c.Refunded > 0 THEN c.NetCancelled - c.Refunded ELSE 0 END AS Capacity,
               ISNULL(b.Refundable, 0) AS BillRefundable,
               SUM(CASE WHEN c.NetCancelled - c.Refunded > 0 THEN c.NetCancelled - c.Refunded ELSE 0 END)
                   OVER (PARTITION BY c.LabOrderId ORDER BY c.CancellationDate, c.CancellationId ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS Before
        FROM c LEFT JOIN b ON b.LabOrderId = c.LabOrderId)
    SELECT
        bc.CancellationId, bc.CancellationNo, bc.CancellationDate,
        CONVERT(VARCHAR(10), CAST(bc.CancellationDate AS DATE), 23) AS CancellationDay,
        CASE bc.CancellationType WHEN 'F' THEN 'Full' ELSE 'Partial' END AS CancellationType,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        -- partner of a B2B bill only (a B2C bill can carry an agent type from its booking screen)
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.AgentType = 'F' THEN 'Franchise' WHEN lo.AgentType = 'C' THEN 'Company' END END AS PartnerType,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name WHEN lo.AgentType = 'C' THEN corp.Corporate_Name END END AS PartnerName,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Code WHEN lo.AgentType = 'C' THEN corp.Corporate_Code END END AS PartnerCode,
        lo.LabOrderId, lo.BillNo, lo.OrderDate AS BillDate,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        itm.ItemCount, itm.ItemNames, CAST(ISNULL(itm.MrpTotal, 0) AS DECIMAL(18, 2)) AS MrpTotal,
        CAST(bc.CancelledAmount AS DECIMAL(18, 2)) AS CancelledAmount,
        CAST(ISNULL(bc.DiscountAdjusted, 0) AS DECIMAL(18, 2)) AS DiscountAdjusted,
        CAST(bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) AS DECIMAL(18, 2)) AS NetCancelled,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidOnBill,
        CAST(ISNULL(ph.NetAmount, 0) AS DECIMAL(18, 2)) AS BillNow,
        CAST(ISNULL(rf.RefundedAmount, 0) AS DECIMAL(18, 2)) AS RefundedAmount,
        rf.RefundModes, rf.LastRefundDate, rf.RefundedBy,
        CAST(CASE WHEN ISNULL(a.BillRefundable, 0) - ISNULL(a.Before, 0) <= 0 THEN 0
                  WHEN ISNULL(a.BillRefundable, 0) - ISNULL(a.Before, 0) < ISNULL(a.Capacity, 0) THEN ISNULL(a.BillRefundable, 0) - ISNULL(a.Before, 0)
                  ELSE ISNULL(a.Capacity, 0) END AS DECIMAL(18, 2)) AS PendingRefund,
        NULLIF(LTRIM(RTRIM(bc.Reason)), '') AS Reason,
        bc.CreatedBy AS CancelledById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CancelledBy,
        rf.RefundUserIds
    INTO #R
    FROM dbo.BillCancellation bc
    INNER JOIN dbo.LabOrder lo     ON lo.LabOrderId = bc.ModuleRefId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN a ON a.CancellationId = bc.CancellationId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    LEFT  JOIN dbo.Users u ON u.Id = bc.CreatedBy
    OUTER APPLY (SELECT COUNT(1) AS ItemCount, SUM(ISNULL(loi.Price, 0)) AS MrpTotal,
                        STRING_AGG(CAST(ISNULL(pkg.Profile_Name, lim.Test_Name) AS NVARCHAR(MAX)), ', ') AS ItemNames
                   FROM dbo.BillCancellationItem bci
                   INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = bci.LineRefId
                   LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                   LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
                  WHERE bci.CancellationId = bc.CancellationId AND bci.IsActive = 1) itm
    OUTER APPLY (SELECT SUM(r.RefundAmount) AS RefundedAmount,
                        STRING_AGG(CAST(r.RefundMode AS NVARCHAR(MAX)), ', ') AS RefundModes,
                        MAX(r.RefundDate) AS LastRefundDate,
                        STRING_AGG(CAST(ISNULL(NULLIF(LTRIM(RTRIM(ru.FullName)), ''), ru.Username) AS NVARCHAR(MAX)), ', ') AS RefundedBy,
                        ',' + STRING_AGG(CAST(r.CreatedBy AS VARCHAR(MAX)), ',') + ',' AS RefundUserIds
                   FROM dbo.BillRefund r
                   LEFT JOIN dbo.Users ru ON ru.Id = r.CreatedBy
                  WHERE r.CancellationId = bc.CancellationId AND r.IsActive = 1) rf
    WHERE bc.ModuleCode = 'LAB'
      AND bc.IsActive = 1
      AND lo.BranchId = @BranchId
      AND bc.CancellationDate >= @From AND bc.CancellationDate < @To
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (@CancellationType IS NULL OR bc.CancellationType = @CancellationType)
      AND (@CancelledBy IS NULL OR bc.CreatedBy = @CancelledBy)
      AND (@Search IS NULL OR bc.CancellationNo LIKE '%' + @Search + '%' OR lo.BillNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR bc.Reason LIKE '%' + @Search + '%'
           OR f.Franchise_Name LIKE '%' + @Search + '%' OR corp.Corporate_Name LIKE '%' + @Search + '%');

    -- own data: cancellations they made, or refunds they processed
    IF @OwnOnly = 1
        DELETE FROM #R WHERE ISNULL(CancelledById, 0) <> @UserId
                         AND ISNULL(RefundUserIds, '') NOT LIKE '%,' + CAST(@UserId AS VARCHAR(20)) + ',%';
    IF @RefundStatus = 'REFUNDED' DELETE FROM #R WHERE NOT (RefundedAmount > 0 AND PendingRefund = 0);
    IF @RefundStatus = 'PENDING'  DELETE FROM #R WHERE PendingRefund <= 0;
    IF @RefundStatus = 'NOTDUE'   DELETE FROM #R WHERE NOT (RefundedAmount = 0 AND PendingRefund = 0);

    -- RS1 summary
    SELECT COUNT(1) AS CancellationCount,
           SUM(CASE WHEN CancellationType = 'Full' THEN 1 ELSE 0 END) AS FullCount,
           SUM(CASE WHEN CancellationType = 'Partial' THEN 1 ELSE 0 END) AS PartialCount,
           COUNT(DISTINCT LabOrderId) AS BillCount,
           ISNULL(SUM(ItemCount), 0) AS ItemCount,
           ISNULL(SUM(MrpTotal), 0) AS MrpTotal,
           ISNULL(SUM(CancelledAmount), 0) AS CancelledAmount, ISNULL(SUM(NetCancelled), 0) AS NetCancelled,
           ISNULL(SUM(RefundedAmount), 0) AS RefundedAmount, ISNULL(SUM(PendingRefund), 0) AS PendingRefund,
           SUM(CASE WHEN PendingRefund > 0 THEN 1 ELSE 0 END) AS PendingRefundCount
    FROM #R;

    -- RS2 groups
    SELECT 'byReason' AS GroupKey, NULL AS GroupId, ISNULL(Reason, 'Not recorded') AS GroupName, 0 AS SortOrder,
           COUNT(1) AS CancellationCount, SUM(ItemCount) AS ItemCount, SUM(NetCancelled) AS NetCancelled,
           SUM(RefundedAmount) AS RefundedAmount, SUM(PendingRefund) AS PendingRefund
    FROM #R GROUP BY Reason
    UNION ALL
    SELECT 'byCancelledBy', CancelledById, CancelledBy, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancelledById, CancelledBy
    UNION ALL
    SELECT 'byType', NULL, CancellationType, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancellationType
    UNION ALL
    SELECT 'byDate', NULL, CancellationDay, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancellationDay
    UNION ALL
    SELECT 'byPartner', NULL, ISNULL(PartnerName + ISNULL(' (' + PartnerCode + ')', ''), 'Walk-in (B2C)'), 0,
           COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY PartnerName, PartnerCode
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT CancellationId, CancellationNo, CancellationDate, CancellationDay, CancellationType, BillingType, PartnerType, PartnerName, PartnerCode,
           ISNULL(PartnerName + ISNULL(' (' + PartnerCode + ')', ''), 'Walk-in (B2C)') AS PartnerLabel,
           LabOrderId, BillNo, BillDate, PatientCode, PatientName, PhoneNumber, ItemCount, ItemNames, MrpTotal, CancelledAmount, DiscountAdjusted,
           NetCancelled, PaidOnBill, BillNow, RefundedAmount, RefundModes, LastRefundDate, RefundedBy, PendingRefund,
           ISNULL(Reason, 'Not recorded') AS Reason, CancelledById, CancelledBy
    FROM #R ORDER BY CancellationDate DESC, CancellationId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'cancelledBy' AS FilterKey, CAST(CancelledById AS VARCHAR(20)) AS Value, CancelledBy AS Text FROM #R WHERE CancelledById IS NOT NULL;

    -- RS5 test-wise: every test of the listed cancellations
    SELECT bci.CancellationId, bci.LineRefId AS LabOrderItemId,
           ISNULL(pkg.Profile_Name, lim.Test_Name) AS TestName,
           ISNULL(pkg.Profile_Code, lim.Test_Code) AS TestCode,
           CASE WHEN loi.Type = 'P' THEN 'Package' WHEN lim.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END AS ItemType,
           CASE WHEN loi.Type = 'P' THEN 'Packages' ELSE dm.DeptName END AS Department,
           CAST(ISNULL(loi.Price, 0) AS DECIMAL(18, 2)) AS Mrp,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(loi.B2BRate, loi.Price) END AS DECIMAL(18, 2)) AS ContractRate,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(pli.LineDiscountAmount, 0) END AS DECIMAL(18, 2)) AS LineDiscount,
           CAST(bci.CancelledAmount AS DECIMAL(18, 2)) AS CancelledAmount,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN bci.CancelledAmount
                     ELSE bci.CancelledAmount - ISNULL(pli.LineDiscountAmount, 0) END AS DECIMAL(18, 2)) AS NetAmount
    FROM dbo.BillCancellationItem bci
    INNER JOIN #R r ON r.CancellationId = bci.CancellationId
    INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = bci.LineRefId
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId
    LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId AND pli.IsActive = 1
                                     AND (pli.ModuleLineRefId = loi.LabOrderItemId)
    WHERE bci.IsActive = 1
    ORDER BY bci.CancellationId, bci.LineRefId;

    DROP TABLE #R;
END;
GO

PRINT 'Script 2235 applied: Cancellation & Refund Register B2C / B2B, test-wise; B2B cancellations at the contract rate.';
GO
