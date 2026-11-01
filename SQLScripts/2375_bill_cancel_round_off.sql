-- ============================================================================================================
-- Migration: 2375_bill_cancel_round_off.sql
-- Partial bill cancellation re-rounds the reduced bill to the rupee (as billing does). Before this, cancelling a
-- test from a bill with a membership discount (e.g. 15% of Rs 150 = 22.50) left the bill at Rs 1,062.50 with no
-- round off. Now: Net 1,063.00, round off +0.50, and the refund is the rounded excess (Rs 127 of Rs 1,190 paid).
-- usp_Bill_Cancel as in 2241_membership_benefits_b2c_lab.sql + the "2375" block. Existing bills are not changed.
-- ============================================================================================================
SET ANSI_NULLS ON;
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
        DECLARE @Items TABLE (LineRefId INT, Amount DECIMAL(10,2), GstAmount DECIMAL(12,2) NULL);   -- 2240: GstAmount of a misc line
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
            -- 2240: a negative LineRefId is a misc line of the bill (LabOrderMiscCharge), still active
            IF EXISTS (SELECT 1 FROM @Items i WHERE ISNULL(i.LineRefId, 0) = 0
                          OR (i.LineRefId > 0 AND NOT EXISTS (SELECT 1 FROM dbo.LabOrderItem loi WHERE loi.LabOrderItemId = i.LineRefId AND loi.LabOrderId = @ModuleRefId))
                          OR (i.LineRefId < 0 AND NOT EXISTS (SELECT 1 FROM dbo.LabOrderMiscCharge m WHERE m.LabOrderMiscChargeId = -i.LineRefId AND m.LabOrderId = @ModuleRefId AND m.IsActive = 1)))
                THROW 50003, 'A selected item does not belong to this bill.', 1;
            UPDATE i SET Amount = CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(loi.B2BRate, ISNULL(loi.Price, 0)) ELSE ISNULL(loi.Price, 0) END
            FROM @Items i
            INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = i.LineRefId
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId;
            -- 2240: a misc line is cancelled at what it was billed: amount + its GST (B2C and B2B alike)
            UPDATE i SET Amount = m.Amount + m.GstAmount, GstAmount = m.GstAmount
            FROM @Items i INNER JOIN dbo.LabOrderMiscCharge m ON m.LabOrderMiscChargeId = -i.LineRefId
            WHERE i.LineRefId < 0;
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
            -- 2240: + the active misc lines (a bill is fully cancelled only with them)
            SET @TotalBillItems = @TotalBillItems + (SELECT COUNT(*) FROM dbo.LabOrderMiscCharge WHERE LabOrderId = @ModuleRefId AND IsActive = 1);
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
        INSERT INTO dbo.BillCancellationItem (CancellationId, LineRefId, OriginalAmount, CancelledAmount, IsActive, GstAmount)
        SELECT @CancellationId, LineRefId, Amount, Amount, 1, GstAmount
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

            -- 2240: cancelled misc lines
            UPDATE m SET IsActive = 0, CancellationId = @CancellationId, CancelledBy = @UserId, CancelledDate = GETDATE()
            FROM dbo.LabOrderMiscCharge m INNER JOIN @Items i ON -i.LineRefId = m.LabOrderMiscChargeId
            WHERE i.LineRefId < 0 AND m.LabOrderId = @ModuleRefId;
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            UPDATE dbo.PatientOPDServiceItem 
            SET IsActive = 0
            WHERE ItemId IN (SELECT LineRefId FROM @Items);
        END

        -- 2241: the membership discount on the cancelled lines (tests: LabOrderItemId, misc lines: - misc line id)
        DECLARE @MemCancelled DECIMAL(18,2) = 0, @MemTestCancelled DECIMAL(18,2) = 0;
        IF @ModuleCode = 'LAB'
            SELECT @MemCancelled = ISNULL(SUM(pli.MembershipDiscountAmount), 0),
                   @MemTestCancelled = ISNULL(SUM(CASE WHEN pli.ModuleLineRefId > 0 THEN pli.MembershipDiscountAmount ELSE 0 END), 0)
            FROM dbo.PaymentLineItem pli
            INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pli.PaymentHeaderId AND ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @ModuleRefId AND ph.IsActive = 1
            WHERE pli.IsActive = 1 AND pli.ModuleLineRefId IN (SELECT LineRefId FROM @Items);
        IF @MemCancelled > ISNULL(@DiscountAdjusted, 0) SET @MemCancelled = ISNULL(@DiscountAdjusted, 0);

        -- Update PaymentHeader
        IF @CancellationType = 'F'
        BEGIN
            -- Full cancellation: NetAmount and BalanceDue become 0
            UPDATE dbo.PaymentHeader
            SET NetAmount            = 0,
                BalanceDue           = 0,
                HeaderDiscountAmount = 0,
                MembershipDiscountAmount = 0,   -- 2241
                MembershipTestDiscount   = 0,
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
                HeaderDiscountAmount = CASE WHEN (HeaderDiscountAmount - (ISNULL(@DiscountAdjusted, 0) - @MemCancelled)) < 0 THEN 0 ELSE (HeaderDiscountAmount - (ISNULL(@DiscountAdjusted, 0) - @MemCancelled)) END,
                -- 2241: the membership share of the discount leaves with its lines
                MembershipDiscountAmount = CASE WHEN MembershipDiscountAmount - @MemCancelled < 0 THEN 0 ELSE MembershipDiscountAmount - @MemCancelled END,
                MembershipTestDiscount = CASE WHEN MembershipTestDiscount - @MemTestCancelled < 0 THEN 0 ELSE MembershipTestDiscount - @MemTestCancelled END,
                -- 2231: status follows the reduced bill: covered = Paid (any excess is for refund), else Partial / Unpaid
                PaymentStatus = CASE WHEN TotalPaid >= (CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0
                                                           ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END) THEN 'P'
                                     WHEN TotalPaid > 0 THEN 'R' ELSE 'U' END,
                LastModifiedDate = GETDATE(),
                LastModifiedBy   = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END

        -- 2375: a partly cancelled bill is rounded to the rupee again, as at billing (membership / manual discounts
        -- can leave paise on the reduced bill); round off, due and status follow, and the refund is the rounded excess
        IF @CancellationType = 'P'
            UPDATE ph
            SET RoundOffAmount = x.Rounded - u.Unrounded,
                NetAmount      = x.Rounded,
                BalanceDue     = CASE WHEN x.Rounded - ph.TotalPaid > 0 THEN x.Rounded - ph.TotalPaid ELSE 0 END,
                PaymentStatus  = CASE WHEN ph.TotalPaid >= x.Rounded THEN 'P' WHEN ph.TotalPaid > 0 THEN 'R' ELSE 'U' END
            FROM dbo.PaymentHeader ph
            CROSS APPLY (SELECT Unrounded = CASE WHEN ph.NetAmount - ISNULL(ph.RoundOffAmount, 0) < 0 THEN 0
                                                 ELSE ph.NetAmount - ISNULL(ph.RoundOffAmount, 0) END) u
            CROSS APPLY (SELECT Rounded = ROUND(u.Unrounded, 0)) x
            WHERE ph.ModuleCode = @ModuleCode AND ph.ModuleRefId = @ModuleRefId AND ph.IsActive = 1;

        -- 2240: the bill's misc totals / GST follow its active misc lines (header GST and the GST ledger)
        IF @ModuleCode = 'LAB'
        BEGIN
            EXEC dbo.usp_LabOrder_MiscSyncTotals @LabOrderId = @ModuleRefId;
            UPDATE ph SET TotalCgstAmount = ISNULL(x.Cgst, 0), TotalSgstAmount = ISNULL(x.Sgst, 0)
            FROM dbo.PaymentHeader ph
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = ph.ModuleRefId AND ISNULL(lo.IsB2B, 0) = 0
            OUTER APPLY (SELECT SUM(CgstAmount) AS Cgst, SUM(SgstAmount) AS Sgst FROM dbo.LabOrderMiscCharge
                         WHERE LabOrderId = @ModuleRefId AND IsActive = 1) x
            WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @ModuleRefId AND ph.IsActive = 1
              AND EXISTS (SELECT 1 FROM dbo.LabOrderMiscCharge WHERE LabOrderId = @ModuleRefId);
            EXEC dbo.usp_Ledger_SyncLabGst @LabOrderId = @ModuleRefId, @UserId = @UserId;
        END

        -- 2232: the cancellation entry (Dr Revenue / Cr the bill's receivable), then discount / round-off follow the bill
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'CANCEL', @RefId = @CancellationId, @UserId = @UserId;
        DECLARE @AdjHeaderId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1);
        IF @AdjHeaderId IS NOT NULL
            EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'ADJUST', @RefId = @AdjHeaderId, @UserId = @UserId;
        -- 2236: membership points of a B2C LAB bill - points used beyond the reduced bill go back to the card,
        -- points earned follow what is paid on the bill as it stands
        IF @AdjHeaderId IS NOT NULL AND @ModuleCode = 'LAB'
            EXEC dbo.usp_Membership_SyncBill @PaymentHeaderId = @AdjHeaderId, @UserId = @UserId;

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
