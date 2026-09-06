Text
----

-- 4. Recreate usp_CreateLabOrder
CREATE   PROCEDURE dbo.usp_CreateLabOrder
    @PatientId        INT,
    @BranchId         INT,
    @CreatedBy        INT,
    @TotalAmount      DECIMAL(10,2),
    @Items            dbo.udt_LabOrderItem READONLY,
    @Co
llectionType   NVARCHAR(50) = 'Lab',
    @PhlebotomistId   INT          = NULL,
    @BookingDate      DATETIME     = NULL,
    @LabOrderId       INT          OUTPUT,
    @BillNo           NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT
 ON;
    
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Insert Header
        INSERT INTO dbo.LabOrder 
            (
PatientId, BranchId, OrderDate, BillNo, TotalAmount,
             CollectionType, PhlebotomistId, BookingDate,
             CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@PatientId, @BranchId, GETDATE(), @BillNo, @TotalAmount,
           
  ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @BookingDate,
             @CreatedBy, GETDATE(), 1);
        
        SET @LabOrderId = SCOPE_IDENTITY();

        -- Insert Items
        INSERT INTO dbo.LabOrderItem (LabOrderId, InvestigationId, Type,
 Price, CreatedBy, CreatedDate, IsActive)
        SELECT @LabOrderId, InvestigationId, ISNULL(Type, 'I'), Price, @CreatedBy, GETDATE(), 1
        FROM @Items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            
ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

