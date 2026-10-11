-- ============================================================================
-- Migration: 2240_lab_misc_charges_billing_part1.sql
-- Description: Misc charges (Misc Charges Master, 2239) on LAB bills - B2C and B2B. Part 1: new objects.
--   * LabOrderMiscCharge: one row per misc line of a bill - a snapshot of the master (name, type, unit amount,
--     discountable, GST %) with quantity, discount, CGST / SGST and net. LabOrderItem is NOT used, so samples,
--     worklists, TAT and lab reports never see a misc line.
--   * LabOrder.MiscAmount / MiscGstAmount: the bill's active misc taxable amount and GST (kept by
--     usp_LabOrder_MiscSyncTotals). LabOrder.TotalAmount stays the tests' total; a B2B bill's B2BTotal includes the
--     misc lines with their GST (what the franchise / company is charged).
--   * PaymentLineItem.LabOrderMiscChargeId: a misc payment line; its ModuleLineRefId is the NEGATIVE misc line id,
--     so no existing join on LabOrderItemId / InvestigationId can ever match it.
--   * BillCancellationItem.GstAmount: the GST inside a cancelled misc line (LineRefId = - misc line id).
--   * GST is added on top of the amount: GST of a line = 2 x ROUND((amount - discount) x GST% / 200, 2)
--     (CGST = SGST = half), the same rounding as the payment screen.
--   * usp_Ledger_SyncLabGst: keeps "GST Output Payable" for a LAB bill equal to its active misc GST
--     (Dr the patient / partner receivable, Cr GST Output Payable; reference LAB_GST). Idempotent.
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabOrderMiscCharge' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabOrderMiscCharge
    (
        LabOrderMiscChargeId INT IDENTITY(1,1) CONSTRAINT PK_LabOrderMiscCharge PRIMARY KEY,
        LabOrderId       INT NOT NULL,
        MiscChargeId     INT NOT NULL,
        ChargeName       NVARCHAR(150) NOT NULL,
        ChargeType       VARCHAR(20) NOT NULL,
        Quantity         INT NOT NULL CONSTRAINT DF_LabOrderMiscCharge_Qty DEFAULT 1,
        UnitAmount       DECIMAL(10,2) NOT NULL,
        Amount           DECIMAL(12,2) NOT NULL,              -- UnitAmount x Quantity (taxable, before discount)
        IsDiscountable   BIT NOT NULL,
        IsGstRequired    BIT NOT NULL,
        GstPercentage    DECIMAL(5,2) NULL,
        DiscountAmount   DECIMAL(12,2) NOT NULL CONSTRAINT DF_LabOrderMiscCharge_Disc DEFAULT 0,
        CgstAmount       DECIMAL(12,2) NOT NULL CONSTRAINT DF_LabOrderMiscCharge_Cgst DEFAULT 0,
        SgstAmount       DECIMAL(12,2) NOT NULL CONSTRAINT DF_LabOrderMiscCharge_Sgst DEFAULT 0,
        GstAmount        DECIMAL(12,2) NOT NULL CONSTRAINT DF_LabOrderMiscCharge_Gst DEFAULT 0,
        NetAmount        DECIMAL(12,2) NOT NULL,              -- Amount - DiscountAmount + GstAmount
        IsActive         BIT NOT NULL CONSTRAINT DF_LabOrderMiscCharge_Active DEFAULT 1,
        CancellationId   INT NULL,
        CreatedBy        INT NULL,
        CreatedDate      DATETIME NOT NULL CONSTRAINT DF_LabOrderMiscCharge_Created DEFAULT GETDATE(),
        CancelledBy      INT NULL,
        CancelledDate    DATETIME NULL,
        CONSTRAINT FK_LabOrderMiscCharge_Order FOREIGN KEY (LabOrderId) REFERENCES dbo.LabOrder(LabOrderId),
        CONSTRAINT FK_LabOrderMiscCharge_Master FOREIGN KEY (MiscChargeId) REFERENCES dbo.LabMiscChargeMaster(Misc_Charge_ID),
        CONSTRAINT CK_LabOrderMiscCharge_Qty CHECK (Quantity BETWEEN 1 AND 99),
        CONSTRAINT CK_LabOrderMiscCharge_Amt CHECK (Amount >= 0 AND DiscountAmount >= 0 AND DiscountAmount <= Amount AND GstAmount >= 0)
    );
    CREATE INDEX IX_LabOrderMiscCharge_Order ON dbo.LabOrderMiscCharge(LabOrderId, IsActive);
END
GO

IF COL_LENGTH('dbo.LabOrder', 'MiscAmount') IS NULL
    ALTER TABLE dbo.LabOrder ADD MiscAmount DECIMAL(12,2) NOT NULL CONSTRAINT DF_LabOrder_MiscAmount DEFAULT 0;
GO
IF COL_LENGTH('dbo.LabOrder', 'MiscGstAmount') IS NULL
    ALTER TABLE dbo.LabOrder ADD MiscGstAmount DECIMAL(12,2) NOT NULL CONSTRAINT DF_LabOrder_MiscGst DEFAULT 0;
GO
IF COL_LENGTH('dbo.PaymentLineItem', 'LabOrderMiscChargeId') IS NULL
    ALTER TABLE dbo.PaymentLineItem ADD LabOrderMiscChargeId INT NULL;
GO
IF COL_LENGTH('dbo.BillCancellationItem', 'GstAmount') IS NULL
    ALTER TABLE dbo.BillCancellationItem ADD GstAmount DECIMAL(12,2) NULL;
GO

IF TYPE_ID('dbo.udt_LabOrderMiscCharge') IS NULL
    CREATE TYPE dbo.udt_LabOrderMiscCharge AS TABLE (MiscChargeId INT NOT NULL, Quantity INT NOT NULL);
GO

-- GST Output Payable (liability) for the GST collected on misc charges
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'GST Output Payable')
    INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
    SELECT TOP 1 'GST Output Payable', LedgerGroupId, 0, 'Cr', 1, GETDATE() FROM dbo.Acc_LedgerGroup
    WHERE GroupName IN ('Duties & Taxes', 'Current Liabilities') ORDER BY CASE GroupName WHEN 'Duties & Taxes' THEN 0 ELSE 1 END;
GO

-- the bill's active misc taxable amount and GST onto LabOrder
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_MiscSyncTotals
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE lo SET MiscAmount = ISNULL(x.Amt, 0), MiscGstAmount = ISNULL(x.Gst, 0)
    FROM dbo.LabOrder lo
    OUTER APPLY (SELECT SUM(m.Amount) AS Amt, SUM(m.GstAmount) AS Gst FROM dbo.LabOrderMiscCharge m
                 WHERE m.LabOrderId = lo.LabOrderId AND m.IsActive = 1) x
    WHERE lo.LabOrderId = @LabOrderId;
END;
GO

-- GST Output Payable of a LAB bill follows its active misc GST: the difference to what is posted is posted
-- (Dr receivable / Cr GST when it rises, the reverse when it falls). Patient receivable for B2C, partner's for B2B.
CREATE OR ALTER PROCEDURE dbo.usp_Ledger_SyncLabGst
    @LabOrderId INT,
    @UserId     INT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Gst INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'GST Output Payable');
    DECLARE @Sales INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Sales');
    DECLARE @Cn INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Credit Note');
    IF @Gst IS NULL OR @Sales IS NULL OR @Cn IS NULL RETURN;

    DECLARE @IsB2B BIT, @AgentType VARCHAR(10), @BranchId INT, @BillNo NVARCHAR(60), @Target DECIMAL(18,2);
    SELECT @IsB2B = CAST(ISNULL(IsB2B, 0) AS BIT), @AgentType = AgentType, @BranchId = BranchId, @BillNo = BillNo,
           @Target = ISNULL(MiscGstAmount, 0)
    FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId;
    IF @BillNo IS NULL RETURN;

    DECLARE @Posted DECIMAL(18,2) = ISNULL((
        SELECT SUM(d.CreditAmount - d.DebitAmount)
        FROM dbo.Acc_LedgerTransaction t
        INNER JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId AND d.LedgerId = @Gst
        WHERE t.ReferenceType = 'LAB_GST' AND t.ReferenceId = @LabOrderId AND t.IsActive = 1), 0);
    DECLARE @Diff DECIMAL(18,2) = @Target - @Posted;
    IF ABS(@Diff) < 0.01 RETURN;

    DECLARE @Party INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName =
        CASE WHEN @IsB2B = 1 THEN CASE WHEN @AgentType = 'C' THEN 'Corporate Receivable' ELSE 'Franchise Receivable' END ELSE 'Patient Receivable' END);
    IF @Party IS NULL RETURN;

    DECLARE @Amt DECIMAL(18,2) = ABS(@Diff), @Now DATETIME = GETDATE(), @NewId BIGINT, @U INT = ISNULL(@UserId, 1),
            @Vt INT = CASE WHEN @Diff > 0 THEN @Sales ELSE @Cn END,
            @Dr INT = CASE WHEN @Diff > 0 THEN @Party ELSE @Gst END,
            @Cr INT = CASE WHEN @Diff > 0 THEN @Gst ELSE @Party END,
            @B INT = ISNULL(@BranchId, 1);
    DECLARE @Narr NVARCHAR(300) = CONCAT('GST on misc charges, LAB Bill ', @BillNo, CASE WHEN @Diff < 0 THEN ' (reduced / reversed)' ELSE '' END);
    EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Vt, @TransactionDate = @Now, @ReferenceType = 'LAB_GST', @ReferenceId = @LabOrderId,
         @BranchId = @B, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Cr,
         @CreatedBy = @U, @NewTransactionId = @NewId OUTPUT;
END;
GO

-- active misc charges offered on the booking screens
CREATE OR ALTER PROCEDURE dbo.usp_LabMiscCharge_ForBilling
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Misc_Charge_ID AS MiscChargeId, Charge_Name AS ChargeName, Charge_Type AS ChargeType, Amount,
           Is_Discountable AS IsDiscountable, Is_GST_Required AS IsGstRequired, GST_Percentage AS GstPercentage, Description
    FROM dbo.LabMiscChargeMaster
    WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND Status = 1
    ORDER BY CASE Charge_Type WHEN 'Home Collection' THEN 0 ELSE 1 END, Display_Order, Charge_Name;
END;
GO

PRINT 'Script 2240 part 1 applied: misc charge tables / columns, GST ledger sync.';
GO
