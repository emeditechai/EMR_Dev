-- ============================================================
-- 2018_lab_cancellation_refund_tables.sql
-- Module-agnostic Bill Cancellation & Refund tables and SPs
-- Supports: LAB, OPD (and future modules)
-- ============================================================

USE [Dev_EMR];
GO

-- ── 1. BillCancellation (header) ──────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'BillCancellation')
BEGIN
    CREATE TABLE dbo.BillCancellation (
        CancellationId       INT IDENTITY(1,1) NOT NULL,
        ModuleCode           CHAR(3)          NOT NULL,   -- 'LAB', 'OPD'
        ModuleRefId          INT              NOT NULL,   -- LabOrderId / OPDServiceId
        CancellationNo       NVARCHAR(50)     NOT NULL,
        CancellationType     CHAR(1)          NOT NULL,   -- 'F' Full, 'P' Partial
        CancellationDate     DATETIME         NOT NULL,
        CancelledAmount      DECIMAL(10,2)    NOT NULL DEFAULT 0,
        DiscountAdjusted     DECIMAL(10,2)    NOT NULL DEFAULT 0,
        Reason               NVARCHAR(500)    NULL,
        Status               CHAR(1)          NOT NULL DEFAULT 'C', -- 'C' Cancelled, 'X' Reversed
        CreatedBy            INT              NULL,
        CreatedDate          DATETIME         NOT NULL DEFAULT GETDATE(),
        IsActive             BIT              NOT NULL DEFAULT 1,
        CONSTRAINT PK_BillCancellation PRIMARY KEY (CancellationId)
    );
    CREATE INDEX IX_BillCancellation_Module ON dbo.BillCancellation (ModuleCode, ModuleRefId);
    PRINT 'Created table BillCancellation';
END
ELSE PRINT 'Table BillCancellation already exists';
GO

-- ── 2. BillCancellationItem (per-line-item detail) ────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'BillCancellationItem')
BEGIN
    CREATE TABLE dbo.BillCancellationItem (
        CancellationItemId   INT IDENTITY(1,1) NOT NULL,
        CancellationId       INT              NOT NULL,
        LineRefId            INT              NOT NULL,   -- LabOrderItemId / OPDServiceItemId
        OriginalAmount       DECIMAL(10,2)    NOT NULL DEFAULT 0,
        CancelledAmount      DECIMAL(10,2)    NOT NULL DEFAULT 0,
        IsActive             BIT              NOT NULL DEFAULT 1,
        CONSTRAINT PK_BillCancellationItem PRIMARY KEY (CancellationItemId),
        CONSTRAINT FK_BillCancellationItem_Cancel FOREIGN KEY (CancellationId) REFERENCES dbo.BillCancellation(CancellationId)
    );
    PRINT 'Created table BillCancellationItem';
END
ELSE PRINT 'Table BillCancellationItem already exists';
GO

-- ── 3. BillRefund ─────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'BillRefund')
BEGIN
    CREATE TABLE dbo.BillRefund (
        RefundId         INT IDENTITY(1,1) NOT NULL,
        CancellationId   INT              NOT NULL,
        ModuleCode       CHAR(3)          NOT NULL,
        ModuleRefId      INT              NOT NULL,
        RefundAmount     DECIMAL(10,2)    NOT NULL DEFAULT 0,
        RefundMode       NVARCHAR(50)     NOT NULL,  -- Cash, UPI, BankTransfer, Card
        RefundDate       DATETIME         NOT NULL,
        TransactionRef   NVARCHAR(200)    NULL,
        Notes            NVARCHAR(500)    NULL,
        Status           CHAR(1)          NOT NULL DEFAULT 'P',  -- 'P' Processed, 'X' Voided
        CreatedBy        INT              NULL,
        CreatedDate      DATETIME         NOT NULL DEFAULT GETDATE(),
        IsActive         BIT              NOT NULL DEFAULT 1,
        CONSTRAINT PK_BillRefund PRIMARY KEY (RefundId),
        CONSTRAINT FK_BillRefund_Cancel FOREIGN KEY (CancellationId) REFERENCES dbo.BillCancellation(CancellationId)
    );
    CREATE INDEX IX_BillRefund_Module ON dbo.BillRefund (ModuleCode, ModuleRefId);
    PRINT 'Created table BillRefund';
END
ELSE PRINT 'Table BillRefund already exists';
GO

-- ── 4. CancellationSequence (per-module counter) ─────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CancellationSequence')
BEGIN
    CREATE TABLE dbo.CancellationSequence (
        ModuleCode     CHAR(3)      NOT NULL,
        FinancialYear  NVARCHAR(4)  NOT NULL,
        BranchId       INT          NOT NULL,
        LastSeq        INT          NOT NULL DEFAULT 0,
        CONSTRAINT PK_CancellationSequence PRIMARY KEY (ModuleCode, FinancialYear, BranchId)
    );
    PRINT 'Created table CancellationSequence';
END
ELSE PRINT 'Table CancellationSequence already exists';
GO

-- ── 5. SP: usp_Bill_GetNextCancellationNo ────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Bill_GetNextCancellationNo
    @ModuleCode    CHAR(3),
    @BranchId      INT,
    @CancellationNo NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode))) FROM dbo.Branchmaster WHERE BranchID = @BranchId;
    IF @BranchCode IS NULL SET @BranchCode = 'BR';

    DECLARE @Month INT = MONTH(GETDATE()), @CalYear INT = YEAR(GETDATE());
    DECLARE @FYStart INT = CASE WHEN @Month >= 4 THEN @CalYear ELSE @CalYear - 1 END;
    DECLARE @FYEnd   INT = CASE WHEN @Month >= 4 THEN @CalYear + 1 ELSE @CalYear END;
    DECLARE @FY NVARCHAR(4) = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2) + RIGHT(CAST(@FYEnd AS NVARCHAR(4)), 2);

    DECLARE @NewSeq INT = 0;

    UPDATE dbo.CancellationSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE ModuleCode = @ModuleCode AND FinancialYear = @FY AND BranchId = @BranchId;

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.CancellationSequence (ModuleCode, FinancialYear, BranchId, LastSeq)
            VALUES (@ModuleCode, @FY, @BranchId, 1);
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
            BEGIN
                UPDATE dbo.CancellationSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE ModuleCode = @ModuleCode AND FinancialYear = @FY AND BranchId = @BranchId;
            END
            ELSE THROW;
        END CATCH
    END

    -- Format: CN-<ModuleCode>/<BranchCode><FY><5-digit seq>
    SET @CancellationNo = 'CN-' + @ModuleCode + '/' + @BranchCode + @FY + RIGHT('00000' + CAST(@NewSeq AS NVARCHAR(10)), 5);
END
GO

-- ── 6. SP: usp_BillSearch ────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_BillSearch
    @ModuleCode CHAR(3),
    @BranchId   INT,
    @SearchTerm NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;

    IF @ModuleCode = 'LAB'
    BEGIN
        SELECT TOP 20
            lo.LabOrderId         AS ModuleRefId,
            'LAB'                 AS ModuleCode,
            lo.BillNo,
            lo.OrderDate          AS BillDate,
            lo.TotalAmount,
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            CASE WHEN p.DateOfBirth IS NOT NULL 
                 THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)       AS TotalPaid,
            ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, lo.TotalAmount)  AS NetAmount,
            -- Cancellation status
            CASE WHEN EXISTS (SELECT 1 FROM dbo.BillCancellation bc 
                              WHERE bc.ModuleCode = 'LAB' AND bc.ModuleRefId = lo.LabOrderId AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS HasCancellation,
            (SELECT SUM(bc2.CancelledAmount) FROM dbo.BillCancellation bc2 
             WHERE bc2.ModuleCode = 'LAB' AND bc2.ModuleRefId = lo.LabOrderId AND bc2.IsActive = 1) AS TotalCancelled
        FROM dbo.LabOrder lo
        INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        WHERE lo.BranchId = @BranchId
          AND (
              lo.BillNo LIKE '%' + @SearchTerm + '%'
              OR CAST(p.PatientId AS NVARCHAR(20)) LIKE '%' + @SearchTerm + '%'
              OR p.PhoneNumber LIKE '%' + @SearchTerm + '%'
              OR (p.FirstName + ' ' + ISNULL(p.LastName, '')) LIKE '%' + @SearchTerm + '%'
              OR p.PatientCode LIKE '%' + @SearchTerm + '%'
          )
        ORDER BY lo.LabOrderId DESC;
    END

    IF @ModuleCode = 'OPD'
    BEGIN
        SELECT TOP 20
            os.OPDServiceId       AS ModuleRefId,
            'OPD'                 AS ModuleCode,
            os.OPDBillNo          AS BillNo,
            os.VisitDate          AS BillDate,
            os.TotalAmount,
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            CASE WHEN p.DateOfBirth IS NOT NULL 
                 THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)       AS TotalPaid,
            ISNULL(ph.BalanceDue, os.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, os.TotalAmount)  AS NetAmount,
            CASE WHEN EXISTS (SELECT 1 FROM dbo.BillCancellation bc 
                              WHERE bc.ModuleCode = 'OPD' AND bc.ModuleRefId = os.OPDServiceId AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS HasCancellation,
            (SELECT SUM(bc2.CancelledAmount) FROM dbo.BillCancellation bc2 
             WHERE bc2.ModuleCode = 'OPD' AND bc2.ModuleRefId = os.OPDServiceId AND bc2.IsActive = 1) AS TotalCancelled
        FROM dbo.PatientOPDService os
        INNER JOIN dbo.PatientMaster p ON p.PatientId = os.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = os.OPDServiceId AND ph.IsActive = 1
        WHERE os.BranchId = @BranchId
          AND (
              os.OPDBillNo LIKE '%' + @SearchTerm + '%'
              OR CAST(p.PatientId AS NVARCHAR(20)) LIKE '%' + @SearchTerm + '%'
              OR p.PhoneNumber LIKE '%' + @SearchTerm + '%'
              OR (p.FirstName + ' ' + ISNULL(p.LastName, '')) LIKE '%' + @SearchTerm + '%'
              OR p.PatientCode LIKE '%' + @SearchTerm + '%'
          )
        ORDER BY os.OPDServiceId DESC;
    END
END
GO

-- ── 7. SP: usp_Bill_GetDetailForCancellation ─────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Bill_GetDetailForCancellation
    @ModuleCode CHAR(3),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ModuleCode = 'LAB'
    BEGIN
        -- Header
        SELECT
            lo.LabOrderId          AS ModuleRefId,
            'LAB'                  AS ModuleCode,
            lo.BillNo,
            lo.OrderDate           AS BillDate,
            lo.TotalAmount,
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
            b.BranchName
        FROM dbo.LabOrder lo
        INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = lo.BranchId
        WHERE lo.LabOrderId = @ModuleRefId;

        -- Line Items
        SELECT
            loi.LabOrderItemId   AS LineRefId,
            loi.LabOrderId       AS ModuleRefId,
            lm.Test_Name         AS ItemName,
            lm.Test_Code         AS ItemCode,
            loi.Price            AS OriginalAmount,
            loi.Price            AS NetAmount,
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
            lst.Sample_Name      AS SampleTypeName,
            dm.DeptName          AS DepartmentName,
            lc.Category_Name     AS CategoryName
        FROM dbo.LabOrderItem loi
        LEFT JOIN dbo.LabInvestigationMaster lm  ON lm.Test_ID        = loi.InvestigationId
        LEFT JOIN dbo.LabSampleTypeMaster lst     ON lst.Sample_Type_ID = lm.Sample_Type_ID
        LEFT JOIN dbo.DepartmentMaster dm         ON dm.DeptId         = lm.Department_ID
        LEFT JOIN dbo.LabTestCategoryMaster lc    ON lc.Category_ID    = lm.Category_ID
        WHERE loi.LabOrderId = @ModuleRefId
        ORDER BY loi.LabOrderItemId;

        -- Payment details
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
        -- Header
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
            b.BranchName
        FROM dbo.PatientOPDService os
        INNER JOIN dbo.PatientMaster p ON p.PatientId = os.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = os.OPDServiceId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = os.BranchId
        WHERE os.OPDServiceId = @ModuleRefId;

        -- Line Items
        SELECT
            si.ItemId             AS LineRefId,
            si.OPDServiceId       AS ModuleRefId,
            ISNULL(sm.ItemName, si.ServiceType) AS ItemName,
            si.ServiceType        AS ItemCode,
            si.ServiceCharges     AS OriginalAmount,
            si.ServiceCharges     AS NetAmount,
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
        LEFT JOIN dbo.ServiceMaster sm ON sm.ServiceId = si.ServiceId
        WHERE si.OPDServiceId = @ModuleRefId
        ORDER BY si.ItemId;

        -- Payment details
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
END
GO

-- ── 8. SP: usp_Bill_Cancel ────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Bill_Cancel
    @ModuleCode          CHAR(3),
    @ModuleRefId         INT,
    @BranchId            INT,
    @LineItemsJson       NVARCHAR(MAX),   -- JSON: [{"lineRefId":1,"amount":500.00}, ...]
    @Reason              NVARCHAR(500),
    @DiscountAdjusted    DECIMAL(10,2),
    @UserId              INT,
    @CancellationId      INT OUTPUT,
    @CancellationNo      NVARCHAR(50) OUTPUT
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

        -- Update PaymentHeader: reduce NetAmount and BalanceDue
        UPDATE dbo.PaymentHeader
        SET NetAmount    = NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0)),
            BalanceDue   = CASE 
                             WHEN (BalanceDue - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 
                             THEN 0 
                             ELSE (BalanceDue - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0)))
                           END,
            HeaderDiscountAmount = HeaderDiscountAmount - ISNULL(@DiscountAdjusted, 0),
            LastModifiedDate = GETDATE(),
            LastModifiedBy   = @UserId
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

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

-- ── 9. SP: usp_Bill_Refund ────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Bill_Refund
    @ModuleCode    CHAR(3),
    @ModuleRefId   INT,
    @CancellationId INT,
    @RefundAmount  DECIMAL(10,2),
    @RefundMode    NVARCHAR(50),
    @TransactionRef NVARCHAR(200),
    @Notes         NVARCHAR(500),
    @UserId        INT,
    @RefundId      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Validate cancellation exists for this bill
        IF NOT EXISTS (
            SELECT 1 FROM dbo.BillCancellation 
            WHERE CancellationId = @CancellationId 
              AND ModuleCode = @ModuleCode 
              AND ModuleRefId = @ModuleRefId 
              AND IsActive = 1
        )
            THROW 50010, 'No valid cancellation found. Please cancel the bill first.', 1;

        -- Validate refund amount does not exceed total paid
        DECLARE @TotalPaid DECIMAL(10,2) = 0;
        SELECT @TotalPaid = ISNULL(TotalPaid, 0) 
        FROM dbo.PaymentHeader 
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        DECLARE @AlreadyRefunded DECIMAL(10,2) = 0;
        SELECT @AlreadyRefunded = ISNULL(SUM(RefundAmount), 0)
        FROM dbo.BillRefund
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND Status = 'P' AND IsActive = 1;

        IF (@AlreadyRefunded + @RefundAmount) > @TotalPaid
            THROW 50011, 'Refund amount exceeds total paid amount.', 1;

        -- Validate refund amount does not exceed the specific cancellation amount
        DECLARE @CancelledAmount DECIMAL(10,2) = 0;
        SELECT @CancelledAmount = ISNULL(CancelledAmount, 0)
        FROM dbo.BillCancellation
        WHERE CancellationId = @CancellationId AND ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        IF @RefundAmount > @CancelledAmount
            THROW 50012, 'Refund amount exceeds cancelled amount.', 1;

        -- Insert BillRefund
        INSERT INTO dbo.BillRefund 
            (CancellationId, ModuleCode, ModuleRefId, RefundAmount, RefundMode, RefundDate, TransactionRef, Notes, Status, CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@CancellationId, @ModuleCode, @ModuleRefId, @RefundAmount, @RefundMode, GETDATE(), @TransactionRef, @Notes, 'P', @UserId, GETDATE(), 1);

        SET @RefundId = SCOPE_IDENTITY();

        -- Reduce TotalPaid in PaymentHeader
        UPDATE dbo.PaymentHeader
        SET TotalPaid = TotalPaid - @RefundAmount,
            BalanceDue = BalanceDue + @RefundAmount,
            LastModifiedDate = GETDATE(),
            LastModifiedBy   = @UserId
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── 10. SP: usp_Bill_GetCancellationHistory ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Bill_GetCancellationHistory
    @ModuleCode  CHAR(3),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Cancellations
    SELECT
        bc.CancellationId,
        bc.CancellationNo,
        bc.CancellationType,
        bc.CancellationDate,
        bc.CancelledAmount,
        bc.DiscountAdjusted,
        bc.Reason,
        bc.Status,
        u.FullName AS CancelledBy
    FROM dbo.BillCancellation bc
    LEFT JOIN dbo.UserMaster u ON CAST(u.Id AS INT) = bc.CreatedBy
    WHERE bc.ModuleCode = @ModuleCode AND bc.ModuleRefId = @ModuleRefId AND bc.IsActive = 1
    ORDER BY bc.CancellationDate;

    -- Cancellation items
    SELECT
        bci.CancellationItemId,
        bci.CancellationId,
        bci.LineRefId,
        bci.OriginalAmount,
        bci.CancelledAmount
    FROM dbo.BillCancellationItem bci
    INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
    WHERE bc.ModuleCode = @ModuleCode AND bc.ModuleRefId = @ModuleRefId AND bc.IsActive = 1;

    -- Refunds
    SELECT
        br.RefundId,
        br.CancellationId,
        br.RefundAmount,
        br.RefundMode,
        br.RefundDate,
        br.TransactionRef,
        br.Notes,
        br.Status,
        u.FullName AS RefundedBy
    FROM dbo.BillRefund br
    LEFT JOIN dbo.UserMaster u ON CAST(u.Id AS INT) = br.CreatedBy
    WHERE br.ModuleCode = @ModuleCode AND br.ModuleRefId = @ModuleRefId AND br.IsActive = 1
    ORDER BY br.RefundDate;
END
GO

PRINT 'Migration 2018 completed successfully.';
GO
