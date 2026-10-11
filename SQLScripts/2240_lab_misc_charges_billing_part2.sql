-- ============================================================================
-- Migration: 2240_lab_misc_charges_billing_part2.sql   (run after part 1)
-- Description: Misc charges on LAB bills - the existing procedures, taken from their live definitions with only the
--   2240-marked changes:
--   * usp_CreateLabOrder: optional @MiscCharges (MiscChargeId, Quantity) - priced from the active master inside the
--     order's transaction; B2BTotal of a B2B bill includes them with GST. Omitted = unchanged behaviour.
--   * usp_Bill_Cancel: a misc line (LineRefId = - misc line id) can be cancelled on its own, at amount + GST; a bill is
--     fully cancelled only with its misc lines; header GST and the GST ledger follow.
--   * usp_Ledger_PostBillMoney: CANCEL reverses revenue without the GST of cancelled misc lines; ADJUST syncs the GST
--     ledger and counts the bill's GST (0 for every bill without misc charges, so their result is unchanged).
--   * usp_Bill_GetDetailForCancellation / usp_Api_PaymentSummary_GetByBill: misc lines listed after the tests.
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CreateLabOrder
    @PatientId        INT,
    @BranchId         INT,
    @CreatedBy        INT,
    @TotalAmount      DECIMAL(10,2),
    @Items            dbo.udt_LabOrderItem READONLY,
    @CollectionType   NVARCHAR(50) = 'Lab',
    @PhlebotomistId   INT          = NULL,
    @BookingDate      DATETIME     = NULL,
    @IsB2B            BIT          = 0,
    @B2BAgentID       INT          = NULL,
    @AgentType        VARCHAR(10)  = NULL,
    @B2BTotal         DECIMAL(18,2)= NULL,
    @ReferralDoctorId INT          = NULL,
    @MiscCharges      dbo.udt_LabOrderMiscCharge READONLY,   -- 2240: misc charges (Misc Charges Master); may be empty
    @LabOrderId       INT          OUTPUT,
    @BillNo           NVARCHAR(50) OUTPUT,
    @TokenNo          NVARCHAR(50) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Strict validation: Cannot create lab order without at least one valid test investigation
    IF NOT EXISTS (SELECT 1 FROM @Items WHERE ISNULL(InvestigationId, 0) > 0)
    BEGIN
        RAISERROR('Cannot create a laboratory bill without at least one valid test investigation (InvestigationId > 0).', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM @Items WHERE ISNULL(InvestigationId, 0) <= 0)
    BEGIN
        RAISERROR('One or more test items have an invalid Investigation ID (InvestigationId <= 0). Billing cannot proceed.', 16, 1);
        RETURN;
    END

    -- Rate list (script 2199): every item must be on the branch's active rate list - B2C bills the branch B2C list,
    -- B2B bills the partner's list or the branch B2C list - never a test that is only in the master. A B2C item is
    -- billed at its rate-list price.
    DECLARE @RateType VARCHAR(50) = CASE WHEN ISNULL(@IsB2B, 0) = 1
                                         THEN CASE @AgentType WHEN 'F' THEN 'Franchise' WHEN 'C' THEN 'Corporate' ELSE @AgentType END
                                         ELSE 'B2C' END;
    DECLARE @Lines TABLE (InvestigationId INT, ItemType VARCHAR(10), Price DECIMAL(18,2), Code NVARCHAR(100), Name NVARCHAR(300));
    INSERT INTO @Lines (InvestigationId, ItemType, Price, Code, Name)
    SELECT it.InvestigationId,
           CASE WHEN it.[Type] = 'P' THEN 'Package' WHEN ISNULL(i.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END,
           it.Price,
           COALESCE(CASE WHEN it.[Type] = 'P' THEN h.Profile_Code END, i.Test_Code, CAST(it.InvestigationId AS NVARCHAR(20))),
           COALESCE(CASE WHEN it.[Type] = 'P' THEN h.Profile_Name END, i.Test_Name, N'Item ' + CAST(it.InvestigationId AS NVARCHAR(20)))
    FROM @Items it
    LEFT JOIN dbo.LabInvestigationMaster i ON it.[Type] <> 'P' AND i.Test_ID = it.InvestigationId
    LEFT JOIN dbo.LabInvestigationProfileHeader h ON it.[Type] = 'P' AND h.Profile_ID = it.InvestigationId;

    DECLARE @NotListed NVARCHAR(2000) = (
        SELECT STRING_AGG(CONVERT(NVARCHAR(400), l.Name + N' (' + l.Code + N')'), N', ')
        FROM @Lines l
        WHERE NOT EXISTS (SELECT 1 FROM dbo.fn_LabBookableItems(@BranchId, @RateType, @B2BAgentID) b
                          WHERE b.Item_Type = l.ItemType AND b.Item_ID = l.InvestigationId));
    IF @NotListed IS NOT NULL
    BEGIN
        DECLARE @NotListedMsg NVARCHAR(2048) = LEFT(N'Not on this branch''s rate list, so it cannot be billed: ' + @NotListed
            + N'. Add it to the rate list first, or remove it from the bill and refresh the page.', 2000);
        RAISERROR(@NotListedMsg, 16, 1);
        RETURN;
    END

    IF ISNULL(@IsB2B, 0) = 0
    BEGIN
        DECLARE @Repriced NVARCHAR(2000) = (
            SELECT STRING_AGG(CONVERT(NVARCHAR(400), l.Name + N' (rate list ' + FORMAT(b.B2CRate, 'N2') + N', bill ' + FORMAT(l.Price, 'N2') + N')'), N', ')
            FROM @Lines l
            INNER JOIN dbo.fn_LabBookableItems(@BranchId, 'B2C', NULL) b ON b.Item_Type = l.ItemType AND b.Item_ID = l.InvestigationId
            WHERE ABS(ISNULL(l.Price, 0) - ISNULL(b.B2CRate, 0)) > 0.01);
        IF @Repriced IS NOT NULL
        BEGIN
            DECLARE @RepricedMsg NVARCHAR(2048) = LEFT(N'The rate has changed in the rate list for: ' + @Repriced
                + N'. Refresh the page and add the test again.', 2000);
            RAISERROR(@RepricedMsg, 16, 1);
            RETURN;
        END
    END

    -- 2240: misc charges - each must be an active charge of the branch's company; priced from the master here
    DECLARE @Misc TABLE (MiscChargeId INT, Quantity INT, ChargeName NVARCHAR(150), ChargeType VARCHAR(20), UnitAmount DECIMAL(10,2),
                         Amount DECIMAL(12,2), IsDiscountable BIT, IsGstRequired BIT, GstPercentage DECIMAL(5,2), HalfGst DECIMAL(12,2));
    IF EXISTS (SELECT 1 FROM @MiscCharges)
    BEGIN
        IF EXISTS (SELECT 1 FROM @MiscCharges WHERE ISNULL(Quantity, 0) < 1 OR Quantity > 99)
        BEGIN RAISERROR('Misc charge quantity must be between 1 and 99.', 16, 1); RETURN; END
        IF (SELECT COUNT(DISTINCT MiscChargeId) FROM @MiscCharges) > 20
        BEGIN RAISERROR('A bill can carry at most 20 misc charges.', 16, 1); RETURN; END
        DECLARE @MiscCompany INT = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId);
        INSERT INTO @Misc (MiscChargeId, Quantity, ChargeName, ChargeType, UnitAmount, Amount, IsDiscountable, IsGstRequired, GstPercentage, HalfGst)
        SELECT m.Misc_Charge_ID, q.Qty, m.Charge_Name, m.Charge_Type, m.Amount, m.Amount * q.Qty, m.Is_Discountable, m.Is_GST_Required,
               CASE WHEN m.Is_GST_Required = 1 THEN m.GST_Percentage END,
               CASE WHEN m.Is_GST_Required = 1 THEN ROUND(m.Amount * q.Qty * m.GST_Percentage / 200.0, 2) ELSE 0 END
        FROM (SELECT MiscChargeId, SUM(Quantity) AS Qty FROM @MiscCharges GROUP BY MiscChargeId) q
        INNER JOIN dbo.LabMiscChargeMaster m ON m.Misc_Charge_ID = q.MiscChargeId AND m.IsDeleted = 0 AND m.Status = 1
             AND (@MiscCompany IS NULL OR m.CompanyId = @MiscCompany);
        IF (SELECT COUNT(*) FROM @Misc) <> (SELECT COUNT(DISTINCT MiscChargeId) FROM @MiscCharges)
        BEGIN RAISERROR('A selected misc charge is no longer active. Refresh the page and add it again.', 16, 1); RETURN; END
        IF EXISTS (SELECT 1 FROM @Misc WHERE Quantity > 99)
        BEGIN RAISERROR('Misc charge quantity must be between 1 and 99.', 16, 1); RETURN; END
    END

    -- Referral doctor = Doctor Master doctor marked Is Referral Doctor, assigned to an active LAB-type department (2127, 2173)
    SET @ReferralDoctorId = NULLIF(@ReferralDoctorId, 0);
    IF @ReferralDoctorId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dbo.DoctorMaster d
        INNER JOIN dbo.DoctorDepartmentMap ddm ON ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1
        INNER JOIN dbo.DepartmentMaster dm ON dm.DeptId = ddm.DeptId AND dm.IsActive = 1 AND dm.DeptType = 'LAB'
        WHERE d.DoctorId = @ReferralDoctorId AND d.IsActive = 1 AND d.IsReferralDoctor = 1)
    BEGIN
        RAISERROR('The selected referral doctor is not an active referral doctor of a LAB department.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Set effective booking date
        DECLARE @EffectiveDate DATETIME = ISNULL(@BookingDate, GETDATE());

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Generate Token immediately for each B2B billing
        IF ISNULL(@IsB2B, 0) = 1
        BEGIN
            DECLARE @DateOnly DATE = CAST(@EffectiveDate AS DATE);
            EXEC dbo.usp_B2B_LAB_GetNextTokenNo 
                @BranchId  = @BranchId, 
                @TokenDate = @DateOnly, 
                @TokenNo   = @TokenNo OUTPUT;
        END
        ELSE
        BEGIN
            SET @TokenNo = NULL; -- B2C tokens are assigned upon payment
        END

        -- Check if any item is marked urgent
        DECLARE @HasUrgent BIT = 0;
        IF EXISTS (SELECT 1 FROM @Items WHERE IsUrgent = 1)
            SET @HasUrgent = 1;

        -- Insert Header with generated TokenNo
        INSERT INTO dbo.LabOrder 
            (PatientId, BranchId, OrderDate, BillNo, TokenNo, TotalAmount, CollectionType, PhlebotomistId, BookingDate, IsUrgent, CreatedBy, CreatedDate, IsActive, IsB2B, B2BAgentID, AgentType, B2BTotal, RefDoctorId)
        VALUES 
            (@PatientId, @BranchId, @EffectiveDate, @BillNo, @TokenNo, @TotalAmount, ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @EffectiveDate, @HasUrgent, @CreatedBy, GETDATE(), 1, ISNULL(@IsB2B, 0), @B2BAgentID, @AgentType, @B2BTotal, @ReferralDoctorId);
        
        SET @LabOrderId = SCOPE_IDENTITY();

        -- Insert Items (include Type, IsUrgent, and B2BRate from @Items)
        INSERT INTO dbo.LabOrderItem (LabOrderId, InvestigationId, [Type], Price, IsUrgent, CreatedBy, CreatedDate, IsActive, B2BRate)
        SELECT 
            @LabOrderId, 
            InvestigationId, 
            ISNULL(NULLIF([Type], ''), 'I'), 
            Price, 
            ISNULL(IsUrgent, 0), 
            @CreatedBy, 
            GETDATE(), 
            1,
            B2BRate
        FROM @Items
        WHERE InvestigationId > 0;

        -- 2240: misc lines (GST on top: CGST = SGST = half); a B2B partner is charged them with their GST
        IF EXISTS (SELECT 1 FROM @Misc)
        BEGIN
            INSERT INTO dbo.LabOrderMiscCharge (LabOrderId, MiscChargeId, ChargeName, ChargeType, Quantity, UnitAmount, Amount, IsDiscountable,
                                                IsGstRequired, GstPercentage, DiscountAmount, CgstAmount, SgstAmount, GstAmount, NetAmount, IsActive, CreatedBy, CreatedDate)
            SELECT @LabOrderId, MiscChargeId, ChargeName, ChargeType, Quantity, UnitAmount, Amount, IsDiscountable,
                   IsGstRequired, GstPercentage, 0, HalfGst, HalfGst, HalfGst * 2, Amount + HalfGst * 2, 1, @CreatedBy, GETDATE()
            FROM @Misc ORDER BY CASE ChargeType WHEN 'Home Collection' THEN 0 ELSE 1 END, ChargeName;
            EXEC dbo.usp_LabOrder_MiscSyncTotals @LabOrderId = @LabOrderId;
            IF ISNULL(@IsB2B, 0) = 1
                UPDATE dbo.LabOrder SET B2BTotal = ISNULL(B2BTotal, 0) + MiscAmount + MiscGstAmount WHERE LabOrderId = @LabOrderId;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
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

CREATE OR ALTER PROCEDURE dbo.usp_Ledger_PostBillMoney
    @Kind     VARCHAR(10),          -- RECEIPT | ADJUST | REFUND | CANCEL
    @RefId    INT,                  -- PaymentDetailId | PaymentHeaderId | RefundId | CancellationId
    @UserId   INT = 1,
    @TxDate   DATETIME = NULL       -- default: when it happened (receipt / refund) or now (adjust)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Receivable INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable');
    DECLARE @Cash INT       = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Cash Account');
    DECLARE @Bank INT       = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Bank Account');
    DECLARE @Disc INT       = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Discount Allowed');
    DECLARE @RoundOff INT   = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Round Off');
    DECLARE @Receipt INT    = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
    DECLARE @Journal INT    = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Credit Note');
    IF @Receivable IS NULL OR @Cash IS NULL OR @Bank IS NULL OR @Receipt IS NULL RETURN;

    DECLARE @Module VARCHAR(5), @ModuleRefId INT, @HeaderId INT, @BranchId INT, @IsB2B BIT, @AgentType VARCHAR(5),
            @BillNo NVARCHAR(60), @Party INT, @NewId BIGINT, @Amt DECIMAL(18,2), @RefType NVARCHAR(50), @Narr NVARCHAR(500),
            @When DATETIME, @Dr INT, @Cr INT;

    IF @Kind = 'RECEIPT'
    BEGIN
        DECLARE @MethodCode NVARCHAR(30), @Ref NVARCHAR(200), @ReceiptNo NVARCHAR(50);
        SELECT @HeaderId = ph.PaymentHeaderId, @Module = RTRIM(ph.ModuleCode), @ModuleRefId = ph.ModuleRefId, @BranchId = ph.BranchId,
               @Amt = pd.PaidAmount, @When = COALESCE(pd.PaymentDate, pd.CreatedDate), @MethodCode = UPPER(pm.MethodCode),
               @Ref = pd.TransactionRef, @ReceiptNo = pd.ReceiptNo
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE pd.PaymentDetailId = @RefId AND pd.IsActive = 1 AND (pd.PaidAmount > 0 OR (pd.PaidAmount < 0 AND pm.MethodCode = 'POINTS'));
        IF @HeaderId IS NULL OR @Module NOT IN ('LAB', 'OPD') RETURN;
        IF ISNULL(@Ref, '') LIKE 'WALLET-DEBIT-%' RETURN;                     -- franchise wallet: posted as B2B_WALLET_PAY
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t                  -- B2B settlement: posted as B2B_SETTLEMENT
                   WHERE t.ReferenceType = 'B2B_SETTLEMENT' AND t.Narration LIKE '%Receipt: ' + @ReceiptNo + ')%') RETURN;
        SET @RefType = @Module + '_RECEIPT';
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @RefType AND ReferenceId = @RefId AND IsActive = 1) RETURN;
    END
    ELSE IF @Kind = 'REFUND'
    BEGIN
        DECLARE @Mode NVARCHAR(50);
        SELECT @Module = RTRIM(r.ModuleCode), @ModuleRefId = r.ModuleRefId, @Amt = r.RefundAmount, @When = r.RefundDate, @Mode = UPPER(LTRIM(RTRIM(r.RefundMode)))
        FROM dbo.BillRefund r WHERE r.RefundId = @RefId AND r.IsActive = 1;
        IF @Module IS NULL OR @Module NOT IN ('LAB', 'OPD') OR ISNULL(@Amt, 0) <= 0 RETURN;
        SELECT @HeaderId = PaymentHeaderId, @BranchId = BranchId FROM dbo.PaymentHeader WHERE RTRIM(ModuleCode) = @Module AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        SET @RefType = @Module + '_REFUND';
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @RefType AND ReferenceId = @RefId AND IsActive = 1) RETURN;
        SET @MethodCode = CASE WHEN @Mode = 'CASH' THEN 'CASH' ELSE 'BANK' END;
    END
    ELSE IF @Kind = 'CANCEL'
    BEGIN
        DECLARE @CnNo NVARCHAR(50);
        SELECT @Module = RTRIM(c.ModuleCode), @ModuleRefId = c.ModuleRefId, @Amt = c.CancelledAmount, @When = c.CancellationDate, @CnNo = c.CancellationNo
        FROM dbo.BillCancellation c WHERE c.CancellationId = @RefId AND c.IsActive = 1;
        -- 2240: the GST inside cancelled misc lines is reversed by usp_Ledger_SyncLabGst, not against revenue
        SET @Amt = ISNULL(@Amt, 0) - ISNULL((SELECT SUM(GstAmount) FROM dbo.BillCancellationItem WHERE CancellationId = @RefId AND IsActive = 1), 0);
        IF @Module IS NULL OR @Module NOT IN ('LAB', 'OPD') OR ISNULL(@Amt, 0) <= 0 RETURN;
        SET @RefType = @Module + '_CANCEL';
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @RefType AND ReferenceId = @ModuleRefId AND IsActive = 1
                   AND Narration LIKE '%' + @CnNo + '%') RETURN;
        SELECT @BranchId = BranchId FROM dbo.PaymentHeader WHERE RTRIM(ModuleCode) = @Module AND ModuleRefId = @ModuleRefId AND IsActive = 1;
    END
    ELSE IF @Kind = 'ADJUST'
    BEGIN
        SELECT @HeaderId = PaymentHeaderId, @Module = RTRIM(ModuleCode), @ModuleRefId = ModuleRefId, @BranchId = BranchId
        FROM dbo.PaymentHeader WHERE PaymentHeaderId = @RefId;
        IF @HeaderId IS NULL OR @Module NOT IN ('LAB', 'OPD') RETURN;
    END
    ELSE RETURN;

    -- whose receivable: the patient's, or the B2B partner's
    IF @Module = 'LAB'
        SELECT @IsB2B = CAST(ISNULL(IsB2B, 0) AS BIT), @AgentType = AgentType, @BillNo = BillNo FROM dbo.LabOrder WHERE LabOrderId = @ModuleRefId;
    ELSE
        SELECT @IsB2B = 0, @BillNo = OPDBillNo FROM dbo.PatientOPDService WHERE OPDServiceId = @ModuleRefId;
    SET @Party = @Receivable;
    IF @IsB2B = 1
        SET @Party = COALESCE((SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster
                               WHERE LedgerName = CASE WHEN @AgentType = 'C' THEN 'Corporate Receivable' ELSE 'Franchise Receivable' END), @Receivable);
    SET @BranchId = ISNULL(@BranchId, 1);
    SET @BillNo = ISNULL(@BillNo, CONVERT(NVARCHAR(20), @ModuleRefId));

    IF @Kind = 'RECEIPT' AND @MethodCode = 'POINTS'
    BEGIN
        -- 2236: membership points paid part of the bill - Dr Membership Points Liability / Cr the receivable;
        -- points given back (a negative line after a cancellation) the other way
        DECLARE @PtsLiab INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Liability');
        IF @PtsLiab IS NULL RETURN;
        SET @Narr = CASE WHEN @Amt > 0 THEN N'Membership points redeemed on ' ELSE N'Membership points given back on ' END + @Module + N' Bill ' + @BillNo
                  + N' (' + ISNULL(@ReceiptNo, 'no receipt') + N')';
        SET @When = ISNULL(@TxDate, @When);
        IF @Amt > 0
            EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
                 @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @PtsLiab, @CreditLedgerId = @Party,
                 @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        ELSE
        BEGIN
            SET @Amt = -@Amt;
            EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
                 @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Party, @CreditLedgerId = @PtsLiab,
                 @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        END
        RETURN;
    END

    IF @Kind = 'RECEIPT'
    BEGIN
        SET @Dr = CASE WHEN @MethodCode = 'CASH' THEN @Cash ELSE @Bank END;
        SET @Narr = N'Payment received on ' + @Module + N' Bill ' + @BillNo + N' (Receipt: ' + ISNULL(@ReceiptNo, '-') + N')';
        SET @When = ISNULL(@TxDate, @When);
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Party,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        RETURN;
    END

    IF @Kind = 'CANCEL'
    BEGIN
        -- Dr the revenue booked for the bill / Cr the receivable it was booked to (the gross of the cancelled lines)
        DECLARE @Revenue INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = CASE WHEN @Module = 'LAB' THEN 'LAB Revenue' ELSE 'OPD Revenue' END);
        IF @Revenue IS NULL OR @Journal IS NULL RETURN;
        SET @Narr = N'Cancellation reversal for ' + @Module + N' Bill ' + @BillNo + N' [' + @CnNo + N']';
        SET @When = ISNULL(@TxDate, @When);
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Journal, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @ModuleRefId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Revenue, @CreditLedgerId = @Party,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        RETURN;
    END

    IF @Kind = 'REFUND'
    BEGIN
        SET @Cr = CASE WHEN @MethodCode = 'CASH' THEN @Cash ELSE @Bank END;
        SET @Narr = N'Refund on ' + @Module + N' Bill ' + @BillNo + N' (Refund #' + CONVERT(NVARCHAR(20), @RefId) + N')';
        SET @When = ISNULL(@TxDate, @When);
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Party, @CreditLedgerId = @Cr,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        RETURN;
    END

    -- 2240: GST on misc charges (B2C and B2B) follows the bill's active misc lines
    IF @Module = 'LAB' EXEC dbo.usp_Ledger_SyncLabGst @LabOrderId = @ModuleRefId, @UserId = @UserId;

    -- ADJUST: B2B bills are posted at their B2B total by usp_B2B_PostBillLedger (no patient discount / round-off)
    IF @IsB2B = 1 OR @Disc IS NULL OR @RoundOff IS NULL OR @Journal IS NULL RETURN;
    DECLARE @TargetDisc DECIMAL(18,2), @TargetRound DECIMAL(18,2), @PostedDisc DECIMAL(18,2), @PostedRound DECIMAL(18,2), @Diff DECIMAL(18,2);
    -- the discount still standing on the bill, from what is posted: bill - cancellations + round-off - bill now
    -- (a cancellation takes its share of the discount with it), so the receivable always equals what is due
    DECLARE @NetNow DECIMAL(18,2), @BillPosted DECIMAL(18,2), @CancelPosted DECIMAL(18,2);
    SELECT @NetNow = ISNULL(NetAmount, 0), @TargetRound = ISNULL(RoundOffAmount, 0), @When = ISNULL(@TxDate, GETDATE())
    FROM dbo.PaymentHeader WHERE PaymentHeaderId = @HeaderId;
    SELECT @BillPosted = ISNULL(SUM(TotalAmount), 0) FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @Module + '_BILL' AND ReferenceId = @ModuleRefId AND IsActive = 1;
    SELECT @CancelPosted = ISNULL(SUM(TotalAmount), 0) FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @Module + '_CANCEL' AND ReferenceId = @ModuleRefId AND IsActive = 1;
    IF @BillPosted <= 0 RETURN;                       -- bill never posted: nothing to adjust against
    -- 2240: the bill now includes the misc GST (posted to GST Output Payable, not to revenue); 0 for every other bill
    DECLARE @GstNow DECIMAL(18,2) = CASE WHEN @Module = 'LAB' THEN ISNULL((SELECT MiscGstAmount FROM dbo.LabOrder WHERE LabOrderId = @ModuleRefId), 0) ELSE 0 END;
    SET @TargetDisc = @BillPosted - @CancelPosted + @TargetRound + @GstNow - @NetNow;

    SELECT @PostedDisc = ISNULL(SUM(d.DebitAmount - d.CreditAmount), 0)
    FROM dbo.Acc_LedgerTransaction t INNER JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId AND d.LedgerId = @Disc
    WHERE t.ReferenceType = @Module + '_DISCOUNT' AND t.ReferenceId = @HeaderId AND t.IsActive = 1;
    SET @Diff = @TargetDisc - @PostedDisc;
    IF ABS(@Diff) >= 0.01
    BEGIN
        SET @RefType = @Module + '_DISCOUNT';
        SET @Narr = N'Discount on ' + @Module + N' Bill ' + @BillNo + CASE WHEN @Diff < 0 THEN N' (reversed / reduced)' ELSE N'' END;
        SET @Amt = ABS(@Diff);
        SET @Dr = CASE WHEN @Diff > 0 THEN @Disc ELSE @Receivable END;
        SET @Cr = CASE WHEN @Diff > 0 THEN @Receivable ELSE @Disc END;
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Journal, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @HeaderId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Cr,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
    END

    -- round-off raises (+) or lowers (-) what the patient owes
    SELECT @PostedRound = ISNULL(SUM(d.CreditAmount - d.DebitAmount), 0)
    FROM dbo.Acc_LedgerTransaction t INNER JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId AND d.LedgerId = @RoundOff
    WHERE t.ReferenceType = @Module + '_ROUNDOFF' AND t.ReferenceId = @HeaderId AND t.IsActive = 1;
    SET @Diff = @TargetRound - @PostedRound;
    IF ABS(@Diff) >= 0.01
    BEGIN
        SET @RefType = @Module + '_ROUNDOFF';
        SET @Narr = N'Round-off on ' + @Module + N' Bill ' + @BillNo;
        SET @Amt = ABS(@Diff);
        SET @Dr = CASE WHEN @Diff > 0 THEN @Receivable ELSE @RoundOff END;
        SET @Cr = CASE WHEN @Diff > 0 THEN @RoundOff ELSE @Receivable END;
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Journal, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @HeaderId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Cr,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
    END
END;
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
            CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0) END AS TotalAmount,   -- 2235, 2240 + misc
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
            CASE WHEN loi.IsActive = 0 THEN 'CANCELLED' ELSE ISNULL(cs.CancelStage, 'ALLOWED') END AS CancelStage,
            0 AS LineSort, loi.LabOrderItemId AS LineSortId
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
        
        -- 2240: misc lines (LineRefId = - misc line id), billed amount = amount + GST; no lab work, always cancellable
        UNION ALL
        SELECT -m.LabOrderMiscChargeId, m.LabOrderId,
               m.ChargeName + CASE WHEN m.Quantity > 1 THEN ' x ' + CAST(m.Quantity AS NVARCHAR(5)) ELSE '' END,
               CASE WHEN m.ChargeType = 'Home Collection' THEN 'HOME-COLL' ELSE 'MISC' END,
               m.Amount + m.GstAmount, m.NetAmount, m.Amount + m.GstAmount, m.DiscountAmount, m.IsActive,
               ISNULL((SELECT SUM(bci.CancelledAmount) FROM dbo.BillCancellationItem bci
                       INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                       WHERE bci.LineRefId = -m.LabOrderMiscChargeId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1), 0),
               CASE WHEN m.IsActive = 0 THEN 1 ELSE 0 END,
               m.ChargeType, 'Misc Charge', CASE WHEN m.IsGstRequired = 1 THEN 'incl. GST ' + FORMAT(m.GstPercentage, '0.##') + '%' ELSE 'Misc' END,
               0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               CASE WHEN m.IsActive = 0 THEN 'CANCELLED' ELSE 'ALLOWED' END,
               1, m.LabOrderMiscChargeId
        FROM dbo.LabOrderMiscCharge m
        WHERE m.LabOrderId = @ModuleRefId
        ORDER BY LineSort, LineSortId;

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

CREATE OR ALTER PROCEDURE [dbo].[usp_Api_PaymentSummary_GetByBill]
    @ModuleCode  NVARCHAR(20),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    IF @ModuleCode = 'OPD'
    BEGIN
        SELECT
            s.OPDServiceId          AS ModuleRefId,
            'OPD'                   AS ModuleCode,
            s.OPDServiceId,
            s.OPDBillNo,
            s.TokenNo,
            p.PatientId,
            p.PatientCode,
            (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
            p.PhoneNumber           AS PatientPhone,
            ISNULL(s.BranchId, 0)  AS BranchId,
            ISNULL(s.TotalAmount, 0) AS SubTotal
        FROM PatientOPDService s
        INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
        WHERE s.OPDServiceId = @ModuleRefId;

        DECLARE @PaymentHeaderId_OPD INT;
        SELECT @PaymentHeaderId_OPD = PaymentHeaderId 
        FROM PaymentHeader 
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        SELECT
            si.ItemId                        AS LineRefId,
            si.ServiceType,
            ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
            ISNULL(si.ServiceCharges, 0)     AS OriginalAmount,
            ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
            ISNULL(pli.NetLineAmount, ISNULL(si.ServiceCharges, 0)) AS NetLineAmount,
            ISNULL(sm.IsGstRequired, 0)      AS IsGstRequired,
            sm.GstPercentage                 AS GstPercentage,
            ISNULL(pli.CgstAmount, 0)        AS CgstAmount,
            ISNULL(pli.SgstAmount, 0)        AS SgstAmount,
            ISNULL(pli.IgstAmount, 0)        AS IgstAmount,
            CAST(ISNULL(sm.IsDiscountable, 1) AS BIT) AS IsDiscountAllowed   -- 2228: Service Master "Is Discountable"
        FROM PatientOPDServiceItem si
        LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
        LEFT JOIN PaymentLineItem pli ON pli.PaymentHeaderId = @PaymentHeaderId_OPD AND pli.ModuleLineRefId = si.ItemId AND pli.IsActive = 1
        WHERE si.OPDServiceId = @ModuleRefId AND si.IsActive = 1
        ORDER BY si.ItemId;

        SELECT
            PaymentHeaderId,
            ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
            HeaderDiscountType,
            HeaderDiscountValue,
            ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
            ISNULL(NetAmount, 0)              AS NetAmount,
            ISNULL(TotalPaid, 0)              AS TotalPaid,
            ISNULL(BalanceDue, 0)             AS BalanceDue,
            ISNULL(PaymentStatus, 'U')        AS PaymentStatus,
            DiscountReason,
            DiscountApprovedBy,
            (SELECT ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) FROM Users u WHERE u.Id = PaymentHeader.DiscountApprovedBy) AS DiscountApprovedByName
        FROM PaymentHeader
        WHERE PaymentHeaderId = @PaymentHeaderId_OPD;
    END
    ELSE IF @ModuleCode = 'LAB'
    BEGIN
        SELECT
            s.LabOrderId            AS ModuleRefId,
            'LAB'                   AS ModuleCode,
            s.LabOrderId            AS OPDServiceId, 
            s.BillNo                AS OPDBillNo,
            s.TokenNo               AS TokenNo,
            p.PatientId,
            p.PatientCode,
            (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
            p.PhoneNumber           AS PatientPhone,
            ISNULL(s.BranchId, 0)   AS BranchId,
            ISNULL(s.TotalAmount, 0) + ISNULL(s.MiscAmount, 0)
              + CASE WHEN ISNULL(s.IsB2B, 0) = 1 THEN ISNULL(s.MiscGstAmount, 0) ELSE 0 END AS SubTotal   -- 2240: + misc charges
        FROM LabOrder s
        INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
        WHERE s.LabOrderId = @ModuleRefId;

        DECLARE @PaymentHeaderId_LAB INT;
        SELECT @PaymentHeaderId_LAB = PaymentHeaderId 
        FROM PaymentHeader 
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        SELECT
            si.LabOrderItemId                AS LineRefId,
            CASE WHEN si.Type = 'P' THEN 'Package' ELSE 'Test' END AS ServiceType,
            CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, '(Unknown Package)') ELSE ISNULL(im.Test_Name, '(Unknown)') END AS ItemName,
            ISNULL(si.Price, 0)              AS OriginalAmount,
            ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
            ISNULL(pli.NetLineAmount, ISNULL(si.Price, 0)) AS NetLineAmount,
            0                                AS IsGstRequired,
            0                                AS GstPercentage,
            0                                AS CgstAmount,
            0                                AS SgstAmount,
            0                                AS IgstAmount,
            CAST(ISNULL(e.Allowed, 0) AS BIT) AS IsDiscountAllowed,          -- 2228: branch B2C rate card "Discount Allowed"
            0 AS LineSort, si.LabOrderItemId AS LineSortId
        FROM LabOrderItem si
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
        LEFT JOIN dbo.LabInvestigationMaster im ON im.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
        OUTER APPLY (
            SELECT TOP 1 CAST(ISNULL(d.Is_Discount_Allowed, 0) AS BIT) AS Allowed
            FROM dbo.LabRateCardMaster m
            INNER JOIN dbo.LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID AND d.IsDeleted = 0
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = si.LabOrderId
            WHERE m.Branch_ID = lo.BranchId AND m.Rate_Type = 'B2C' AND m.Status = 1 AND m.IsDeleted = 0
              AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
              AND d.Item_ID = si.InvestigationId
              AND d.Item_Type = CASE WHEN si.Type = 'P' THEN 'Package' WHEN im.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END
            ORDER BY m.Effective_From DESC, m.RateCard_ID DESC) e
        LEFT JOIN PaymentLineItem pli ON pli.PaymentHeaderId = @PaymentHeaderId_LAB AND pli.ModuleLineRefId = si.LabOrderItemId AND pli.IsActive = 1
        WHERE si.LabOrderId = @ModuleRefId AND si.IsActive = 1
        
        -- 2240: misc lines. B2C: GST on top (a saved bill's due-collection discount never touches a GST line);
        -- B2B: the partner's amount already includes the GST
        UNION ALL
        SELECT -m.LabOrderMiscChargeId, 'Misc',
               m.ChargeName + CASE WHEN m.Quantity > 1 THEN ' x ' + CAST(m.Quantity AS NVARCHAR(5)) ELSE '' END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN m.Amount + m.GstAmount ELSE m.Amount END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE m.DiscountAmount END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN m.Amount + m.GstAmount ELSE m.Amount - m.DiscountAmount END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE m.IsGstRequired END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(m.GstPercentage, 0) END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE m.CgstAmount END,
               CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE m.SgstAmount END,
               0,
               CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 0 AND m.IsDiscountable = 1 AND (m.IsGstRequired = 0 OR @PaymentHeaderId_LAB IS NULL) THEN 1 ELSE 0 END AS BIT),
               1, m.LabOrderMiscChargeId
        FROM dbo.LabOrderMiscCharge m
        INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = m.LabOrderId
        WHERE m.LabOrderId = @ModuleRefId AND m.IsActive = 1
        ORDER BY LineSort, LineSortId;

        SELECT
            PaymentHeaderId,
            ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
            HeaderDiscountType,
            HeaderDiscountValue,
            ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
            ISNULL(NetAmount, 0)              AS NetAmount,
            ISNULL(TotalPaid, 0)              AS TotalPaid,
            ISNULL(BalanceDue, 0)             AS BalanceDue,
            ISNULL(PaymentStatus, 'U')        AS PaymentStatus,
            DiscountReason,
            DiscountApprovedBy,
            (SELECT ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) FROM Users u WHERE u.Id = PaymentHeader.DiscountApprovedBy) AS DiscountApprovedByName
        FROM PaymentHeader
        WHERE PaymentHeaderId = @PaymentHeaderId_LAB;
    END
END;
GO

PRINT 'Script 2240 part 2 applied: misc charges in order creation, cancellation, ledger, cancel detail and payment summary.';
GO
