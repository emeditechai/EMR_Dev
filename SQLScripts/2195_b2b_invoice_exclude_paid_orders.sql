-- ============================================================================
-- Migration: 2195_b2b_invoice_exclude_paid_orders.sql
-- Description: Generate B2B Invoice no longer offers (or accepts) orders that are already paid in full - whether
--   paid at the counter when booked (on-spot payment, e.g. LAB/HO2627000168 in cash) or deducted from the franchise
--   wallet (prepaid partner, e.g. LAB/HO2627000170). Such an order is settled; invoicing it would bill it twice.
--   * usp_B2B_GetUninvoicedOrders leaves them out of "Uninvoiced Lab Orders Available".
--   * usp_B2B_GenerateInvoice drops them from the selected orders as a safety check.
--   Unchanged: unpaid and part-paid orders are invoiced as before (a part payment is carried as paid on the invoice).
--   Existing invoices are not touched.
--   Run after 2194.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetUninvoicedOrders
    @AgentType VARCHAR(10), -- 'F' or 'C'
    @AgentId   INT = NULL,
    @AgentIds  NVARCHAR(MAX) = NULL,
    @FromDate  DATETIME2 = NULL,
    @ToDate    DATETIME2 = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        lo.LabOrderId,
        lo.BillNo,
        lo.OrderDate,
        lo.DueDate,
        ISNULL(lo.B2BTotal, lo.TotalAmount) AS BillAmount,
        ISNULL(ph.TotalPaid, 0.00) AS PaidAmount,
        ISNULL(ph.BalanceDue, ISNULL(lo.B2BTotal, lo.TotalAmount)) AS BalanceDue,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber AS PatientPhone,
        (SELECT COUNT(1) FROM dbo.LabOrderItem WHERE LabOrderId = lo.LabOrderId AND IsActive = 1) AS ItemCount,
        STUFF((
            SELECT ', ' + CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Profile') ELSE ISNULL(sm.Test_Name, 'Test') END
            FROM dbo.LabOrderItem si
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster sm ON sm.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
            WHERE si.LabOrderId = lo.LabOrderId AND si.IsActive = 1
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS TestNames,
        lo.AgentType,
        lo.B2BAgentID AS AgentId,
        CASE lo.AgentType 
            WHEN 'F' THEN f.Franchise_Name 
            WHEN 'C' THEN corp.Corporate_Name 
            ELSE 'Unknown' 
        END AS PartnerName,
        CASE lo.AgentType 
            WHEN 'F' THEN f.Franchise_Code 
            WHEN 'C' THEN corp.Corporate_Code 
            ELSE '' 
        END AS PartnerCode
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE lo.IsB2B = 1
      AND lo.AgentType = @AgentType
      AND lo.IsActive = 1
      AND (
          (@AgentIds IS NOT NULL AND @AgentIds <> '' AND @AgentIds <> 'ALL' AND lo.B2BAgentID IN (
              SELECT CAST(value AS INT) FROM STRING_SPLIT(@AgentIds, ',') WHERE LTRIM(RTRIM(value)) <> '' AND ISNUMERIC(value) = 1
          ))
          OR (@AgentIds = 'ALL')
          OR (
              (@AgentIds IS NULL OR @AgentIds = '') 
              AND (@AgentId IS NULL OR @AgentId <= 0 OR lo.B2BAgentID = @AgentId)
          )
      )
      AND (@FromDate IS NULL OR lo.OrderDate >= @FromDate)
      AND (@ToDate IS NULL OR lo.OrderDate <= @ToDate)
      -- Exclude orders already tied to an active invoice
      AND NOT EXISTS (
          SELECT 1 FROM dbo.B2BInvoiceItem bii 
          INNER JOIN dbo.B2BInvoice bi ON bi.InvoiceId = bii.InvoiceId 
          WHERE bii.LabOrderId = lo.LabOrderId AND bi.Status <> 'C'
      )
      -- Exclude orders already paid in full (on-spot at the counter or deducted from the franchise wallet):
      -- they are settled and need no invoice. (script 2195)
      AND NOT (ISNULL(ph.PaymentStatus, 'U') = 'P' AND ISNULL(ph.BalanceDue, 0) <= 0)
    ORDER BY PartnerName ASC, lo.OrderDate ASC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_B2B_GenerateInvoice
    @AgentType        VARCHAR(10), -- 'F' or 'C'
    @AgentId          INT,
    @BranchId         INT,
    @SelectedOrderIds NVARCHAR(MAX), -- comma-separated list of LabOrderIds
    @BillingCycle     NVARCHAR(50) = 'On-Demand',
    @Notes            NVARCHAR(MAX) = NULL,
    @UserId           INT = 1,
    @InvoiceId        INT OUTPUT,
    @InvoiceNo        NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Determine Credit Days
        DECLARE @CreditDays INT = 0;
        IF @AgentType = 'F'
        BEGIN
            SELECT @CreditDays = ISNULL(c.Credit_Days, 0)
            FROM dbo.LabFranchiseCreditLimitMaster c
            WHERE c.Franchise_ID = @AgentId;
        END
        ELSE IF @AgentType = 'C'
        BEGIN
            SELECT @CreditDays = ISNULL(c.Credit_Days, 0), @BillingCycle = ISNULL(@BillingCycle, c.BillingCycle)
            FROM dbo.CorporateMaster c
            WHERE c.Corporate_ID = @AgentId;
        END

        IF @CreditDays <= 0 SET @CreditDays = 30;

        -- 2. Generate Invoice Number: B2B-INV-YYYYMM-XXXXX
        DECLARE @YearMonth NVARCHAR(6) = FORMAT(GETDATE(), 'yyyyMM');
        DECLARE @NextNum INT;
        SELECT @NextNum = ISNULL(MAX(InvoiceId), 0) + 1 FROM dbo.B2BInvoice;
        SET @InvoiceNo = 'B2B-INV-' + @YearMonth + '-' + RIGHT('00000' + CAST(@NextNum AS VARCHAR(10)), 5);

        -- 3. Calculate Totals from selected orders
        DECLARE @TotalAmount DECIMAL(18,2) = 0.00;
        DECLARE @DueDate DATETIME2 = DATEADD(DAY, @CreditDays, GETDATE());

        DECLARE @OrderList TABLE (LabOrderId INT);
        INSERT INTO @OrderList (LabOrderId)
        SELECT CAST(value AS INT) 
        FROM STRING_SPLIT(@SelectedOrderIds, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

        -- Orders already paid in full (on-spot at the counter or from the franchise wallet) are never invoiced (script 2195)
        DELETE ol
        FROM @OrderList ol
        INNER JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = ol.LabOrderId AND ph.IsActive = 1
        WHERE ISNULL(ph.PaymentStatus, 'U') = 'P' AND ISNULL(ph.BalanceDue, 0) <= 0;

        SELECT @TotalAmount = ISNULL(SUM(ISNULL(lo.B2BTotal, lo.TotalAmount)), 0.00)
        FROM dbo.LabOrder lo
        INNER JOIN @OrderList ol ON ol.LabOrderId = lo.LabOrderId
        WHERE lo.IsB2B = 1 AND lo.IsActive = 1;

        IF @TotalAmount <= 0
        BEGIN
            THROW 50003, 'No valid orders found or total amount is zero.', 1;
        END

        -- Calculate any existing payments recorded on selected orders (capped at B2B rate)
        DECLARE @InitialPaidAmount DECIMAL(18,2) = 0.00;
        SELECT @InitialPaidAmount = ISNULL(SUM(
            CASE 
                WHEN ISNULL(ph.TotalPaid, 0) >= ISNULL(lo.B2BTotal, lo.TotalAmount) THEN ISNULL(lo.B2BTotal, lo.TotalAmount)
                ELSE ISNULL(ph.TotalPaid, 0)
            END
        ), 0.00)
        FROM dbo.LabOrder lo
        INNER JOIN @OrderList ol ON ol.LabOrderId = lo.LabOrderId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        WHERE lo.IsB2B = 1 AND lo.IsActive = 1;

        IF @InitialPaidAmount > @TotalAmount SET @InitialPaidAmount = @TotalAmount;
        DECLARE @InitialBalance DECIMAL(18,2) = CASE WHEN @TotalAmount - @InitialPaidAmount <= 0 THEN 0.00 ELSE @TotalAmount - @InitialPaidAmount END;
        DECLARE @InitialStatus VARCHAR(10) = CASE WHEN @InitialBalance <= 0 THEN 'P' WHEN @InitialPaidAmount > 0 THEN 'R' ELSE 'U' END;

        -- 4. Insert Invoice Header
        INSERT INTO dbo.B2BInvoice
            (InvoiceNo, PartnerType, PartnerId, BranchId, BillingCycle, InvoiceDate, DueDate, TotalAmount, DiscountAmount, TaxAmount, NetAmount, PaidAmount, BalanceAmount, Status, Notes, CreatedBy, CreatedDate)
        VALUES
            (@InvoiceNo, @AgentType, @AgentId, @BranchId, @BillingCycle, GETDATE(), @DueDate, @TotalAmount, 0.00, 0.00, @TotalAmount, @InitialPaidAmount, @InitialBalance, @InitialStatus, @Notes, @UserId, GETDATE());

        SET @InvoiceId = SCOPE_IDENTITY();

        -- 5. Insert Invoice Items
        INSERT INTO dbo.B2BInvoiceItem
            (InvoiceId, LabOrderId, BillNo, OrderDate, PatientName, B2BTotal, Amount)
        SELECT 
            @InvoiceId,
            lo.LabOrderId,
            lo.BillNo,
            lo.OrderDate,
            LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName, ''))),
            ISNULL(lo.B2BTotal, lo.TotalAmount),
            ISNULL(lo.B2BTotal, lo.TotalAmount)
        FROM dbo.LabOrder lo
        INNER JOIN @OrderList ol ON ol.LabOrderId = lo.LabOrderId
        INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
        WHERE lo.IsB2B = 1 AND lo.IsActive = 1;

        -- Update DueDate on LabOrders
        UPDATE lo
        SET DueDate = @DueDate
        FROM dbo.LabOrder lo
        INNER JOIN @OrderList ol ON ol.LabOrderId = lo.LabOrderId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
