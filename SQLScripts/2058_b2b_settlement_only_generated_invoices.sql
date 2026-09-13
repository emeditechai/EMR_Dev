-- ============================================================================
-- Migration: 2058_b2b_settlement_only_generated_invoices.sql
-- Description: In B2B Multi-Bill Payment Settlement, ONLY list bills that belong
--              to active Generated Invoices. Uninvoiced bills are excluded from settlement.
-- ============================================================================

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Update usp_B2B_GetOutstandingBillsForSettlement ────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetOutstandingBillsForSettlement
    @AgentType VARCHAR(10), -- 'F' or 'C'
    @AgentId   INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Return only unpaid/partially paid B2B LabOrders that belong to an active GENERATED INVOICE
    SELECT 
        lo.LabOrderId,
        lo.BillNo,
        lo.OrderDate,
        ISNULL(bi.DueDate, ISNULL(lo.DueDate, DATEADD(DAY, 30, lo.OrderDate))) AS DueDate,
        ISNULL(lo.B2BTotal, lo.TotalAmount) AS BillAmount,
        CASE 
            WHEN ISNULL(ph.TotalPaid, 0.00) >= ISNULL(lo.B2BTotal, lo.TotalAmount) 
                THEN ISNULL(lo.B2BTotal, lo.TotalAmount)
            ELSE ISNULL(ph.TotalPaid, 0.00)
        END AS PaidAmount,
        CASE 
            WHEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) <= 0 
                THEN 0.00 
            ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) 
        END AS BalanceDue,
        CASE 
            WHEN ISNULL(ph.TotalPaid, 0.00) >= ISNULL(lo.B2BTotal, lo.TotalAmount) THEN 'P'
            WHEN ISNULL(ph.TotalPaid, 0.00) > 0 THEN 'R'
            ELSE 'U'
        END AS PaymentStatus,
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber AS PatientPhone,
        bii.InvoiceId,
        bi.InvoiceNo,
        CASE WHEN ISNULL(bi.DueDate, ISNULL(lo.DueDate, DATEADD(DAY, 30, lo.OrderDate))) < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END AS IsOverdue,
        DATEDIFF(DAY, ISNULL(bi.DueDate, ISNULL(lo.DueDate, DATEADD(DAY, 30, lo.OrderDate))), CAST(GETDATE() AS DATE)) AS OverdueDays,
        STUFF((
            SELECT ', ' + CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Profile') ELSE ISNULL(sm.Test_Name, 'Test') END
            FROM dbo.LabOrderItem si
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster sm ON sm.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
            WHERE si.LabOrderId = lo.LabOrderId AND si.IsActive = 1
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS TestNames
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    INNER JOIN dbo.B2BInvoiceItem bii ON bii.LabOrderId = lo.LabOrderId
    INNER JOIN dbo.B2BInvoice bi ON bi.InvoiceId = bii.InvoiceId AND bi.Status NOT IN ('C', 'P')
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.IsB2B = 1
      AND lo.AgentType = @AgentType
      AND lo.B2BAgentID = @AgentId
      AND lo.IsActive = 1
      AND (ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0.00)) > 0.00
    ORDER BY bi.InvoiceDate ASC, lo.OrderDate ASC;
END;
GO

-- ── 2. Update usp_B2B_GetPartnerCreditStatus to also return InvoicedOutstanding ─
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetPartnerCreditStatus
    @AgentType VARCHAR(10), -- 'F' or 'C'
    @AgentId   INT,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @AgentType = 'F'
    BEGIN
        -- Franchise Details
        DECLARE @FranchiseName NVARCHAR(100), @FranchiseCode NVARCHAR(50), @IsActive BIT, @IsSuspended BIT;
        DECLARE @CreditFacilityType INT = 1; -- Default 1: Prepaid
        DECLARE @CreditLimit DECIMAL(18,2) = 0.00;
        DECLARE @TempLimit DECIMAL(18,2) = 0.00;
        DECLARE @TempValidTill DATE = NULL;
        DECLARE @CreditDays INT = 0;
        DECLARE @GraceDays INT = 0;
        DECLARE @WalletBalance DECIMAL(18,2) = 0.00;
        DECLARE @CurrentOutstanding DECIMAL(18,2) = 0.00;
        DECLARE @InvoicedOutstanding DECIMAL(18,2) = 0.00;

        SELECT 
            @FranchiseName = f.Franchise_Name,
            @FranchiseCode = f.Franchise_Code,
            @IsActive = f.IsActive,
            @IsSuspended = f.Status,
            @CreditFacilityType = ISNULL(c.Credit_Facility_Type, 1),
            @CreditLimit = ISNULL(c.Credit_Limit, 0.00),
            @TempLimit = ISNULL(c.Temporary_Limit_Increase, 0.00),
            @TempValidTill = c.Temp_Limit_Valid_Till,
            @CreditDays = ISNULL(c.Credit_Days, 0),
            @GraceDays = ISNULL(c.Grace_Days, 0),
            @WalletBalance = ISNULL(w.CurrentBalance, 0.00)
        FROM dbo.LabFranchiseMaster f
        LEFT JOIN dbo.LabFranchiseCreditLimitMaster c ON c.Franchise_ID = f.Franchise_ID
        LEFT JOIN dbo.LabFranchiseWallet w ON w.Franchise_ID = f.Franchise_ID
        WHERE f.Franchise_ID = @AgentId;

        IF @FranchiseName IS NULL
        BEGIN
            SELECT 0 AS Found, 'Franchise not found.' AS Message;
            RETURN;
        END

        -- Add temporary limit if valid
        IF @TempValidTill IS NOT NULL AND @TempValidTill >= CAST(GETDATE() AS DATE)
            SET @CreditLimit = @CreditLimit + @TempLimit;

        -- Calculate Current Outstanding from all unpaid/partial B2B LabOrders for this franchise
        SELECT @CurrentOutstanding = ISNULL(SUM(
            CASE 
                WHEN ph.PaymentHeaderId IS NOT NULL THEN ph.BalanceDue
                ELSE ISNULL(lo.B2BTotal, lo.TotalAmount)
            END
        ), 0.00)
        FROM dbo.LabOrder lo
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        WHERE lo.IsB2B = 1 
          AND lo.AgentType = 'F' 
          AND lo.B2BAgentID = @AgentId 
          AND lo.IsActive = 1
          AND (ph.PaymentStatus IS NULL OR ph.PaymentStatus IN ('U', 'R'));

        -- Calculate Invoiced Outstanding (sum of active unpaid/partially paid invoices)
        SELECT @InvoicedOutstanding = ISNULL(SUM(bi.BalanceAmount), 0.00)
        FROM dbo.B2BInvoice bi
        WHERE bi.PartnerType = 'F'
          AND bi.PartnerId = @AgentId
          AND bi.Status IN ('U', 'R');

        DECLARE @AvailableCredit DECIMAL(18,2) = CASE 
            WHEN @CreditFacilityType = 1 THEN 0.00
            ELSE (@CreditLimit - @CurrentOutstanding)
        END;

        DECLARE @CanBook BIT = 1;
        DECLARE @BlockReason NVARCHAR(500) = NULL;

        IF @IsActive = 0
        BEGIN
            SET @CanBook = 0;
            SET @BlockReason = 'Franchise account is inactive.';
        END
        ELSE IF @IsSuspended = 1
        BEGIN
            SET @CanBook = 0;
            SET @BlockReason = 'Franchise account is suspended.';
        END
        ELSE IF @CreditFacilityType = 2 AND @CreditLimit > 0 AND @AvailableCredit <= 0
        BEGIN
            SET @CanBook = 0;
            SET @BlockReason = 'Credit limit exhausted. Outstanding (₹' + FORMAT(@CurrentOutstanding, 'N2') + ') meets or exceeds limit (₹' + FORMAT(@CreditLimit, 'N2') + ').';
        END

        SELECT 
            1 AS Found,
            @AgentType AS AgentType,
            @AgentId AS AgentId,
            @FranchiseName AS PartnerName,
            @FranchiseCode AS PartnerCode,
            @CreditFacilityType AS CreditFacilityType,
            CASE @CreditFacilityType
                WHEN 1 THEN 'Prepaid (Wallet)'
                WHEN 2 THEN 'Postpaid (Credit)'
                WHEN 3 THEN 'Hybrid'
                ELSE 'Prepaid (Wallet)'
            END AS CreditFacilityTypeName,
            @CreditLimit AS CreditLimit,
            @CreditDays AS CreditDays,
            @GraceDays AS GraceDays,
            CAST(NULL AS NVARCHAR(50)) AS BillingCycle,
            CAST(NULL AS DATETIME2) AS EffectiveFrom,
            CAST(NULL AS DATETIME2) AS EffectiveTo,
            CAST(1 AS BIT) AS IsContractValid,
            @WalletBalance AS WalletBalance,
            @CurrentOutstanding AS CurrentOutstanding,
            @InvoicedOutstanding AS InvoicedOutstanding,
            @AvailableCredit AS AvailableCredit,
            @CanBook AS CanBook,
            @BlockReason AS BlockReason;
    END
    ELSE IF @AgentType = 'C'
    BEGIN
        -- Corporate Details
        DECLARE @CorpName NVARCHAR(200), @CorpCode NVARCHAR(50), @CorpActive BIT;
        DECLARE @EffectiveFrom DATETIME2, @EffectiveTo DATETIME2;
        DECLARE @CorpCreditLimit DECIMAL(18,2) = 0.00;
        DECLARE @CorpCreditDays INT = 0;
        DECLARE @BillingCycle NVARCHAR(50) = 'Monthly';
        DECLARE @CorpOutstanding DECIMAL(18,2) = 0.00;
        DECLARE @CorpInvoicedOutstanding DECIMAL(18,2) = 0.00;

        SELECT 
            @CorpName = c.Corporate_Name,
            @CorpCode = c.Corporate_Code,
            @CorpActive = c.Status,
            @EffectiveFrom = c.Effective_From,
            @EffectiveTo = c.Effective_To,
            @CorpCreditLimit = ISNULL(c.Credit_Limit, 0.00),
            @CorpCreditDays = ISNULL(c.Credit_Days, 0),
            @BillingCycle = ISNULL(c.BillingCycle, 'Monthly')
        FROM dbo.CorporateMaster c
        WHERE c.Corporate_ID = @AgentId;

        IF @CorpName IS NULL
        BEGIN
            SELECT 0 AS Found, 'Corporate company not found.' AS Message;
            RETURN;
        END

        -- Calculate Outstanding
        SELECT @CorpOutstanding = ISNULL(SUM(
            CASE 
                WHEN ph.PaymentHeaderId IS NOT NULL THEN ph.BalanceDue
                ELSE ISNULL(lo.B2BTotal, lo.TotalAmount)
            END
        ), 0.00)
        FROM dbo.LabOrder lo
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        WHERE lo.IsB2B = 1 
          AND lo.AgentType = 'C' 
          AND lo.B2BAgentID = @AgentId 
          AND lo.IsActive = 1
          AND (ph.PaymentStatus IS NULL OR ph.PaymentStatus IN ('U', 'R'));

        -- Calculate Invoiced Outstanding
        SELECT @CorpInvoicedOutstanding = ISNULL(SUM(bi.BalanceAmount), 0.00)
        FROM dbo.B2BInvoice bi
        WHERE bi.PartnerType = 'C'
          AND bi.PartnerId = @AgentId
          AND bi.Status IN ('U', 'R');

        DECLARE @CorpAvailableCredit DECIMAL(18,2) = @CorpCreditLimit - @CorpOutstanding;
        DECLARE @IsContractValid BIT = 0;

        IF CAST(GETDATE() AS DATE) BETWEEN CAST(@EffectiveFrom AS DATE) AND CAST(@EffectiveTo AS DATE)
            SET @IsContractValid = 1;

        DECLARE @CorpCanBook BIT = 1;
        DECLARE @CorpBlockReason NVARCHAR(500) = NULL;

        IF @CorpActive = 0
        BEGIN
            SET @CorpCanBook = 0;
            SET @CorpBlockReason = 'Corporate tie-up account is inactive.';
        END
        ELSE IF @IsContractValid = 0
        BEGIN
            SET @CorpCanBook = 0;
            SET @CorpBlockReason = 'Corporate tie-up contract is not active (Valid from ' + FORMAT(@EffectiveFrom, 'dd/MM/yyyy') + ' to ' + FORMAT(@EffectiveTo, 'dd/MM/yyyy') + ').';
        END
        ELSE IF @CorpCreditLimit > 0 AND @CorpAvailableCredit <= 0
        BEGIN
            SET @CorpCanBook = 0;
            SET @CorpBlockReason = 'Corporate credit limit exhausted. Outstanding (₹' + FORMAT(@CorpOutstanding, 'N2') + ') meets or exceeds limit (₹' + FORMAT(@CorpCreditLimit, 'N2') + ').';
        END

        SELECT 
            1 AS Found,
            @AgentType AS AgentType,
            @AgentId AS AgentId,
            @CorpName AS PartnerName,
            @CorpCode AS PartnerCode,
            2 AS CreditFacilityType, -- Corporate is postpaid
            'Postpaid (Credit)' AS CreditFacilityTypeName,
            @CorpCreditLimit AS CreditLimit,
            @CorpCreditDays AS CreditDays,
            0 AS GraceDays,
            @BillingCycle AS BillingCycle,
            @EffectiveFrom AS EffectiveFrom,
            @EffectiveTo AS EffectiveTo,
            @IsContractValid AS IsContractValid,
            0.00 AS WalletBalance,
            @CorpOutstanding AS CurrentOutstanding,
            @CorpInvoicedOutstanding AS InvoicedOutstanding,
            @CorpAvailableCredit AS AvailableCredit,
            @CorpCanBook AS CanBook,
            @CorpBlockReason AS BlockReason;
    END
END;
GO
