-- ============================================================
-- 2016_seed_lab_revenue_ledger_and_backfill.sql
-- Seeds LAB Revenue ledger into Acc_LedgerMaster
-- Backfills ledger transactions for existing LabOrders
-- ============================================================

USE [Dev_EMR];
GO

-- 1. Ensure 'Direct Income' or 'Income' group exists
IF NOT EXISTS (SELECT 1 FROM Acc_LedgerGroup WHERE GroupName = 'Direct Income' OR GroupName = 'Income')
BEGIN
    INSERT INTO Acc_LedgerGroup (GroupName, GroupType, IsActive, CreatedDate)
    VALUES ('Direct Income', 'Income', 1, GETDATE());
END
GO

-- 2. Ensure 'LAB Revenue' ledger exists
DECLARE @IncomeGroupId INT = (
    SELECT TOP 1 LedgerGroupId 
    FROM Acc_LedgerGroup 
    WHERE GroupName = 'Direct Income' OR GroupName = 'Income' OR GroupType = 'Income'
);

IF NOT EXISTS (SELECT 1 FROM Acc_LedgerMaster WHERE LedgerName = 'LAB Revenue')
BEGIN
    INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
    VALUES ('LAB Revenue', @IncomeGroupId, 0, 'Cr', 1, GETDATE());
    PRINT 'Inserted LAB Revenue ledger into Acc_LedgerMaster.';
END
ELSE
BEGIN
    PRINT 'LAB Revenue ledger already exists in Acc_LedgerMaster.';
END
GO

-- 3. Backfill Ledger Transactions for existing Lab Orders
DECLARE @VoucherTypeId INT = (SELECT TOP 1 VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = 'Sales');
DECLARE @DebitLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable');
DECLARE @CreditLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'LAB Revenue');

IF @VoucherTypeId IS NOT NULL AND @DebitLedgerId IS NOT NULL AND @CreditLedgerId IS NOT NULL
BEGIN
    DECLARE @LabOrderId INT, @BillNo NVARCHAR(50), @TotalAmount DECIMAL(10,2), @OrderDate DATETIME, @CreatedBy INT, @BranchId INT;

    DECLARE order_cursor CURSOR FOR
    SELECT lo.LabOrderId, lo.BillNo, lo.TotalAmount, lo.OrderDate, lo.CreatedBy, lo.BranchId
    FROM LabOrder lo
    WHERE lo.TotalAmount > 0
      AND NOT EXISTS (
          SELECT 1 
          FROM Acc_LedgerTransaction lt 
          WHERE lt.ReferenceType = 'LAB_BILL' AND lt.ReferenceId = lo.LabOrderId
      );

    OPEN order_cursor;
    FETCH NEXT FROM order_cursor INTO @LabOrderId, @BillNo, @TotalAmount, @OrderDate, @CreatedBy, @BranchId;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @NewTxId BIGINT;
        DECLARE @Narration NVARCHAR(MAX) = 'Revenue recognized for LAB Bill ' + ISNULL(@BillNo, CAST(@LabOrderId AS NVARCHAR(50)));

        EXEC dbo.usp_Ledger_PostEntry
            @VoucherTypeId = @VoucherTypeId,
            @TransactionDate = @OrderDate,
            @ReferenceType = 'LAB_BILL',
            @ReferenceId = @LabOrderId,
            @BranchId = @BranchId,
            @CompanyId = 1,
            @TotalAmount = @TotalAmount,
            @Narration = @Narration,
            @DebitLedgerId = @DebitLedgerId,
            @CreditLedgerId = @CreditLedgerId,
            @CreatedBy = @CreatedBy,
            @NewTransactionId = @NewTxId OUTPUT;

        PRINT 'Backfilled ledger transaction ' + CAST(@NewTxId AS NVARCHAR(50)) + ' for LabOrder #' + CAST(@LabOrderId AS NVARCHAR(50));

        FETCH NEXT FROM order_cursor INTO @LabOrderId, @BillNo, @TotalAmount, @OrderDate, @CreatedBy, @BranchId;
    END

    CLOSE order_cursor;
    DEALLOCATE order_cursor;
END
GO
