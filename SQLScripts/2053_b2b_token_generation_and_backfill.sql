-- ==============================================================================
-- Migration: 2053_b2b_token_generation_and_backfill.sql
-- Description: Implement dedicated Day-Wise B2B Laboratory Token No generation pattern:
--              Pattern: B2B-LAB-{BranchCode}-{Seq:D4} (e.g., B2B-LAB-HO-0001).
--              Maintains separate daily sequence from B2C LAB tokens via ModuleCode = 'B2B_LAB'.
--              Generates immediately on each B2B billing/order creation.
--              Backfills all existing B2B LabOrders and SampleCollection records day-wise.
-- ==============================================================================

-- 1. Create B2B Token Generator Procedure
CREATE OR ALTER PROCEDURE dbo.usp_B2B_LAB_GetNextTokenNo
    @BranchId  INT,
    @TokenDate DATE          = NULL,
    @TokenNo   NVARCHAR(50)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    SET @TokenDate = ISNULL(@TokenDate, CAST(GETDATE() AS DATE));

    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode))) FROM dbo.BranchMaster WHERE BranchID = @BranchId;
    IF @BranchCode IS NULL SET @BranchCode = 'HO';

    DECLARE @NewSeq INT = 0;

    UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'B2B_LAB';

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDTokenSequence (BranchId, TokenDate, ModuleCode, LastSeq, CompanyId)
            VALUES (@BranchId, @TokenDate, 'B2B_LAB', 1, 1);
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
            BEGIN
                UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'B2B_LAB';
            END
            ELSE THROW;
        END CATCH
    END

    SET @TokenNo = 'B2B-LAB-' + @BranchCode + '-' + RIGHT('0000' + CAST(@NewSeq AS VARCHAR(10)), 4);
END;
GO

-- 2. Update dbo.usp_CreateLabOrder to generate B2B Token immediately on each billing
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
            (PatientId, BranchId, OrderDate, BillNo, TokenNo, TotalAmount, CollectionType, PhlebotomistId, BookingDate, IsUrgent, CreatedBy, CreatedDate, IsActive, IsB2B, B2BAgentID, AgentType, B2BTotal)
        VALUES 
            (@PatientId, @BranchId, @EffectiveDate, @BillNo, @TokenNo, @TotalAmount, ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @EffectiveDate, @HasUrgent, @CreatedBy, GETDATE(), 1, ISNULL(@IsB2B, 0), @B2BAgentID, @AgentType, @B2BTotal);
        
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

-- 3. Update dbo.usp_LAB_AssignTokenOnPayment to maintain separate B2B sequence if called
CREATE OR ALTER PROCEDURE dbo.usp_LAB_AssignTokenOnPayment
    @LabOrderId     INT,
    @TokenNo        NVARCHAR(50)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchId        INT;
    DECLARE @AppointmentDate DATE;
    DECLARE @ExistingToken   NVARCHAR(50);
    DECLARE @IsB2B           BIT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT  @BranchId        = BranchId,
                @AppointmentDate = CAST(ISNULL(BookingDate, OrderDate) AS DATE),
                @ExistingToken   = TokenNo,
                @IsB2B           = ISNULL(IsB2B, 0)
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

        -- Generate new token
        IF @IsB2B = 1
        BEGIN
            EXEC dbo.usp_B2B_LAB_GetNextTokenNo @BranchId, @AppointmentDate, @TokenNo OUTPUT;
        END
        ELSE
        BEGIN
            EXEC dbo.usp_LAB_GetNextTokenNo @BranchId, @AppointmentDate, @TokenNo OUTPUT;
        END

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
END;
GO

-- 4. Backfill all existing B2B records day-wise per branch
;WITH B2BOrdersRanked AS (
    SELECT 
        LabOrderId,
        BranchId,
        CAST(ISNULL(BookingDate, OrderDate) AS DATE) AS TokenDate,
        ROW_NUMBER() OVER (
            PARTITION BY BranchId, CAST(ISNULL(BookingDate, OrderDate) AS DATE)
            ORDER BY CreatedDate ASC, LabOrderId ASC
        ) AS DaySeq
    FROM dbo.LabOrder
    WHERE IsB2B = 1
)
UPDATE lo
SET lo.TokenNo = 'B2B-LAB-' + UPPER(ISNULL(bm.BranchCode, 'HO')) + '-' + RIGHT('0000' + CAST(r.DaySeq AS VARCHAR(10)), 4)
FROM dbo.LabOrder lo
JOIN B2BOrdersRanked r ON lo.LabOrderId = r.LabOrderId
LEFT JOIN dbo.BranchMaster bm ON lo.BranchId = bm.BranchID;

-- Sync SampleCollection for backfilled orders
UPDATE sc
SET sc.TokenNo = lo.TokenNo
FROM dbo.SampleCollection sc
JOIN dbo.LabOrder lo ON sc.Laborderid = lo.LabOrderId
WHERE lo.IsB2B = 1 AND (sc.TokenNo IS NULL OR sc.TokenNo <> lo.TokenNo);

-- Seed OPDTokenSequence with the max day-wise sequence for B2B_LAB
;WITH MaxB2BSeq AS (
    SELECT 
        BranchId,
        CAST(ISNULL(BookingDate, OrderDate) AS DATE) AS TokenDate,
        COUNT(*) AS MaxSeq
    FROM dbo.LabOrder
    WHERE IsB2B = 1
    GROUP BY BranchId, CAST(ISNULL(BookingDate, OrderDate) AS DATE)
)
MERGE dbo.OPDTokenSequence AS target
USING MaxB2BSeq AS source
ON (target.BranchId = source.BranchId AND target.TokenDate = source.TokenDate AND target.ModuleCode = 'B2B_LAB')
WHEN MATCHED THEN
    UPDATE SET target.LastSeq = source.MaxSeq
WHEN NOT MATCHED THEN
    INSERT (BranchId, TokenDate, ModuleCode, LastSeq, CompanyId)
    VALUES (source.BranchId, source.TokenDate, 'B2B_LAB', source.MaxSeq, 1);

-- Clean up B2C 'LAB' sequence for 2026-09-13 if it was only incremented by Order 84
IF NOT EXISTS (SELECT 1 FROM dbo.LabOrder WHERE IsB2B = 0 AND CAST(ISNULL(BookingDate, OrderDate) AS DATE) = '2026-09-13' AND TokenNo IS NOT NULL)
BEGIN
    DELETE FROM dbo.OPDTokenSequence WHERE TokenDate = '2026-09-13' AND ModuleCode = 'LAB';
END
GO
