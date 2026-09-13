-- ==============================================================================
-- Migration: 2052_enforce_lab_order_at_least_one_test_validation.sql
-- Description: Enforces strict validation that laboratory bills cannot be created
--              without at least one valid test investigation (InvestigationId > 0).
--              Also corrects investigation IDs for Order 84.
-- ==============================================================================

-- 1. Correct any legacy / test orders with InvestigationId = 0
UPDATE dbo.LabOrderItem 
SET InvestigationId = 1 
WHERE LabOrderItemId = 165 AND LabOrderId = 84 AND InvestigationId = 0;

UPDATE dbo.LabOrderItem 
SET InvestigationId = 50 
WHERE LabOrderItemId = 166 AND LabOrderId = 84 AND InvestigationId = 0;
GO

-- 2. Update dbo.usp_CreateLabOrder with strict test validation
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
    @LabOrderId       INT          OUTPUT,
    @BillNo           NVARCHAR(50) OUTPUT
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

    -- Strict validation: Check for any invalid row with InvestigationId <= 0
    IF EXISTS (SELECT 1 FROM @Items WHERE ISNULL(InvestigationId, 0) <= 0)
    BEGIN
        RAISERROR('One or more test items have an invalid Investigation ID (InvestigationId <= 0). Billing cannot proceed.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Set effective booking date
        DECLARE @EffectiveDate DATETIME = ISNULL(@BookingDate, GETDATE());

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Check if any item is marked urgent
        DECLARE @HasUrgent BIT = 0;
        IF EXISTS (SELECT 1 FROM @Items WHERE IsUrgent = 1)
            SET @HasUrgent = 1;

        -- Insert Header
        INSERT INTO dbo.LabOrder 
            (PatientId, BranchId, OrderDate, BillNo, TotalAmount, CollectionType, PhlebotomistId, BookingDate, IsUrgent, CreatedBy, CreatedDate, IsActive, IsB2B, B2BAgentID, AgentType, B2BTotal)
        VALUES 
            (@PatientId, @BranchId, @EffectiveDate, @BillNo, @TotalAmount, ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @EffectiveDate, @HasUrgent, @CreatedBy, GETDATE(), 1, ISNULL(@IsB2B, 0), @B2BAgentID, @AgentType, @B2BTotal);
        
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

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
