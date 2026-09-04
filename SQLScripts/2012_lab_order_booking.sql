-- ============================================================
-- 2012_lab_order_booking.sql
-- Creates LabOrder and LabOrderItem tables for B2C Billing
-- Seeds LAB Revenue ledger
-- ============================================================

-- ── 1. LabOrder (Header) ──────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'LabOrder')
BEGIN
    CREATE TABLE LabOrder (
        LabOrderId      INT             IDENTITY(1,1) PRIMARY KEY,
        PatientId       INT             NOT NULL,
        BranchId        INT             NOT NULL,
        OrderDate       DATETIME        NOT NULL DEFAULT GETDATE(),
        BillNo          NVARCHAR(50)    NULL,
        TokenNo         NVARCHAR(50)    NULL,
        TotalAmount     DECIMAL(10,2)   NOT NULL DEFAULT 0,
        
        IsActive        BIT             NOT NULL DEFAULT 1,
        CreatedBy       INT             NULL,
        CreatedDate     DATETIME        NOT NULL DEFAULT GETDATE(),
        ModifiedBy      INT             NULL,
        ModifiedDate    DATETIME        NULL,
        
        CONSTRAINT FK_LabOrder_Patient FOREIGN KEY (PatientId) REFERENCES PatientMaster(PatientId),
        CONSTRAINT FK_LabOrder_Branch  FOREIGN KEY (BranchId)  REFERENCES BranchMaster(BranchID)
    );

    CREATE INDEX IX_LabOrder_PatientId ON LabOrder(PatientId);
    CREATE INDEX IX_LabOrder_BranchId ON LabOrder(BranchId);
END;
GO

-- ── 2. LabOrderItem (Line Items) ──────────────────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'LabOrderItem')
BEGIN
    CREATE TABLE LabOrderItem (
        LabOrderItemId  INT             IDENTITY(1,1) PRIMARY KEY,
        LabOrderId      INT             NOT NULL,
        InvestigationId INT             NOT NULL,
        Price           DECIMAL(10,2)   NOT NULL DEFAULT 0,
        
        IsActive        BIT             NOT NULL DEFAULT 1,
        CreatedBy       INT             NULL,
        CreatedDate     DATETIME        NOT NULL DEFAULT GETDATE(),
        
        CONSTRAINT FK_LabOrderItem_LabOrder FOREIGN KEY (LabOrderId) REFERENCES LabOrder(LabOrderId),
        CONSTRAINT FK_LabOrderItem_Investigation FOREIGN KEY (InvestigationId) REFERENCES LabInvestigationMaster(Test_ID)
    );

    CREATE INDEX IX_LabOrderItem_LabOrderId ON LabOrderItem(LabOrderId);
END;
GO

-- ── 3. Seed LAB Revenue Ledger ────────────────────────────────
-- Verify if 'LAB Revenue' exists, if not insert it.
IF NOT EXISTS (SELECT 1 FROM Acc_LedgerMaster WHERE LedgerName = 'LAB Revenue')
BEGIN
    DECLARE @SalesGroupId INT;
    SELECT @SalesGroupId = LedgerGroupId FROM Acc_LedgerGroup WHERE GroupName = 'Direct Income' OR GroupName = 'Income';
    
    IF @SalesGroupId IS NOT NULL
    BEGIN
        INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, IsActive, CreatedDate)
        VALUES ('LAB Revenue', @SalesGroupId, 1, GETDATE());
    END
END;
GO

PRINT '2012_lab_order_booking.sql applied successfully.';
