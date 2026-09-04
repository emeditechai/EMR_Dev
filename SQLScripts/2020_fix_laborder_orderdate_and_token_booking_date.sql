-- =============================================================
-- Migration 2020: Fix LabOrder OrderDate and Token Booking Date
-- =============================================================
-- PROBLEM:
--   OrderDate was set to BookingDate ?? GETDATE(), causing it to
--   reflect the appointment date instead of the bill creation date.
-- FIX:
--   OrderDate  = GETDATE()    (always = bill creation time)
--   BookingDate = @BookingDate (user-chosen, can be NULL)
--   Token generation uses BookingDate if available, else OrderDate
-- =============================================================

-- 1. Fix usp_CreateLabOrder
--    OrderDate = bill creation (GETDATE()), BookingDate = user chosen
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.usp_CreateLabOrder
    @PatientId        INT,
    @BranchId         INT,
    @CreatedBy        INT,
    @TotalAmount      DECIMAL(10,2),
    @Items            dbo.udt_LabOrderItem READONLY,
    @CollectionType   NVARCHAR(50) = 'Lab',
    @PhlebotomistId   INT          = NULL,
    @BookingDate      DATETIME     = NULL,
    @LabOrderId       INT          OUTPUT,
    @BillNo           NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Insert Header
        -- OrderDate   = GETDATE() => Bill creation timestamp (Bill Date)
        -- BookingDate = @BookingDate => User-chosen appointment date (may be NULL)
        INSERT INTO dbo.LabOrder 
            (PatientId, BranchId, OrderDate, BillNo, TotalAmount,
             CollectionType, PhlebotomistId, BookingDate,
             CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@PatientId, @BranchId, GETDATE(), @BillNo, @TotalAmount,
             ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @BookingDate,
             @CreatedBy, GETDATE(), 1);
        
        SET @LabOrderId = SCOPE_IDENTITY();

        -- Insert Items
        INSERT INTO dbo.LabOrderItem (LabOrderId, InvestigationId, Price, CreatedBy, CreatedDate, IsActive)
        SELECT @LabOrderId, InvestigationId, Price, @CreatedBy, GETDATE(), 1
        FROM @Items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- =============================================================
-- 2. Fix usp_LAB_AssignTokenOnPayment
--    Token date should use BookingDate if available,
--    otherwise fall back to OrderDate (bill creation date)
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.usp_LAB_AssignTokenOnPayment
    @LabOrderId     INT,
    @TokenNo        NVARCHAR(20)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchId        INT;
    DECLARE @AppointmentDate DATE;
    DECLARE @ExistingToken   NVARCHAR(20);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT  @BranchId        = BranchId,
                -- Use BookingDate for token sequence if set, else fall back to OrderDate (bill date)
                @AppointmentDate = CAST(ISNULL(BookingDate, OrderDate) AS DATE),
                @ExistingToken   = TokenNo
        FROM    dbo.LabOrder WITH (UPDLOCK, ROWLOCK)
        WHERE   LabOrderId = @LabOrderId;

        IF @ExistingToken IS NOT NULL
        BEGIN
            SET @TokenNo = @ExistingToken;

            -- Sync SampleCollection TokenNo
            UPDATE dbo.SampleCollection
            SET TokenNo = @ExistingToken
            WHERE Laborderid = @LabOrderId AND (TokenNo IS NULL OR TokenNo <> @ExistingToken);

            COMMIT TRANSACTION;
            RETURN;
        END

        EXEC dbo.usp_LAB_GetNextTokenNo @BranchId, @AppointmentDate, @TokenNo OUTPUT;

        UPDATE dbo.LabOrder
        SET    TokenNo = @TokenNo
        WHERE  LabOrderId = @LabOrderId;

        -- Sync SampleCollection TokenNo
        UPDATE dbo.SampleCollection
        SET TokenNo = @TokenNo
        WHERE Laborderid = @LabOrderId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO

PRINT 'Migration 2020 applied: OrderDate = bill creation, BookingDate = appointment, Token uses BookingDate.';
