-- ============================================================================
-- Migration: 2196_b2b_partner_billing_payment_method.sql
-- Description: Reports > LAB > B2B Partner Billing Register shows how each B2B bill was paid, with a filter on it.
--   usp_Api_LabReport_B2BPartnerBilling adds per bill: SpotAmount / WalletAmount / CreditAmount, SpotModes and
--   PaymentMethod - the spot payment mode(s) when paid at the counter (e.g. 'Cash'), 'Wallet' when deducted from the
--   franchise wallet, 'Credit' for what was left to the partner's account (invoiced / settled later); a bill paid partly
--   shows both, e.g. 'Cash + Credit'. A spot payment is a non-wallet payment taken before the bill was first invoiced.
--   New filter @PaymentMethod ('CREDIT' / 'WALLET' / 'SPOT' / 'M-<PaymentMethodId>'), a 'byPayMethod' summary group,
--   spot / wallet / credit totals in the summary and the payment modes as filter options. Everything else unchanged.
--   Run after 2195.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
-- ============================================================================
-- LR-07 B2B Partner Billing Register - B2B bills in the period (bill date): MRP vs contract price, margin given,
-- collected, due, invoice.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_B2BPartnerBilling
    @BranchId     INT,
    @FromDate     DATE,
    @ToDate       DATE,
    @PartnerType  CHAR(1)       = NULL,   -- F / C
    @Partner      VARCHAR(20)   = NULL,   -- 'F-1' / 'C-3'
    @PaymentMethod VARCHAR(20)  = NULL,   -- 'CREDIT' / 'WALLET' / 'SPOT' (any spot payment) / 'M-<PaymentMethodId>' (script 2196)
    @Search       NVARCHAR(100) = NULL,
    @UserId       INT           = NULL,
    @IsAdmin      BIT           = 0,
    @IsSuperAdmin BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @PartnerType = NULLIF(UPPER(LTRIM(RTRIM(@PartnerType))), '');
    SET @Partner = NULLIF(UPPER(LTRIM(RTRIM(@Partner))), '');
    SET @PaymentMethod = NULLIF(UPPER(LTRIM(RTRIM(@PaymentMethod))), '');

    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        lo.AgentType + '-' + CAST(lo.B2BAgentID AS VARCHAR(10)) AS PartnerKey,
        CASE lo.AgentType WHEN 'F' THEN 'Franchise' WHEN 'C' THEN 'Corporate' ELSE 'Other' END AS PartnerType,
        CASE lo.AgentType WHEN 'F' THEN f.Franchise_Code ELSE corp.Corporate_Code END AS PartnerCode,
        ISNULL(CASE lo.AgentType WHEN 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END, 'Unknown partner') AS PartnerName,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        items.TestCount, items.TestNames,
        CAST(lo.TotalAmount AS DECIMAL(18, 2)) AS MrpAmount,
        CAST(ISNULL(lo.B2BTotal, lo.TotalAmount) AS DECIMAL(18, 2)) AS ContractAmount,
        CAST(lo.TotalAmount - ISNULL(lo.B2BTotal, lo.TotalAmount) AS DECIMAL(18, 2)) AS MarginAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        CAST(CASE WHEN lo.IsActive = 0 THEN 0
                  WHEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0
                  ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) END AS DECIMAL(18, 2)) AS DueAmount,
        inv.InvoiceNo,
        -- how the bill was paid (script 2196): spot payment at the counter (its modes), franchise wallet, or credit
        -- (left to the partner's account - invoiced / settled later). Spot = not a wallet deduction and taken before the
        -- bill was first invoiced (invoice settlements can only come after the invoice).
        CAST(ISNULL(pay.SpotAmount, 0) AS DECIMAL(18, 2)) AS SpotAmount,
        CAST(ISNULL(pay.WalletAmount, 0) AS DECIMAL(18, 2)) AS WalletAmount,
        CAST(CASE WHEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(pay.SpotAmount, 0) - ISNULL(pay.WalletAmount, 0) > 0
                  THEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(pay.SpotAmount, 0) - ISNULL(pay.WalletAmount, 0) ELSE 0 END AS DECIMAL(18, 2)) AS CreditAmount,
        spot.SpotModes,
        spot.SpotMethodIds,
        CAST(NULL AS NVARCHAR(200)) AS PaymentMethod,
        CAST(CASE WHEN lo.IsActive = 0 THEN 1 ELSE 0 END AS BIT) AS IsCancelled,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CreatedBy
    INTO #R
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    LEFT  JOIN dbo.Users u ON u.Id = lo.CreatedBy
    OUTER APPLY (SELECT COUNT(1) AS TestCount,
                        STRING_AGG(CAST(ISNULL(pkg.Profile_Name, lim.Test_Name) AS NVARCHAR(MAX)), ', ') AS TestNames
                   FROM dbo.LabOrderItem loi
                   LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                   LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
                  WHERE loi.LabOrderId = lo.LabOrderId AND (loi.IsActive = 1 OR lo.IsActive = 0)) items
    OUTER APPLY (SELECT TOP 1 i.InvoiceNo FROM dbo.B2BInvoiceItem ii JOIN dbo.B2BInvoice i ON i.InvoiceId = ii.InvoiceId
                  WHERE ii.LabOrderId = lo.LabOrderId ORDER BY i.InvoiceId DESC) inv
    OUTER APPLY (SELECT MIN(i.CreatedDate) AS FirstInvoicedOn FROM dbo.B2BInvoiceItem ii JOIN dbo.B2BInvoice i ON i.InvoiceId = ii.InvoiceId
                  WHERE ii.LabOrderId = lo.LabOrderId AND ISNULL(i.Status, '') <> 'C') fi
    OUTER APPLY (SELECT SUM(CASE WHEN x.Kind = 'W' THEN x.PaidAmount ELSE 0 END) AS WalletAmount,
                        SUM(CASE WHEN x.Kind = 'S' THEN x.PaidAmount ELSE 0 END) AS SpotAmount
                   FROM (SELECT pd.PaidAmount,
                                CASE WHEN ISNULL(pd.TransactionRef, '') LIKE 'WALLET-DEBIT-%' THEN 'W'
                                     WHEN fi.FirstInvoicedOn IS NULL OR pd.CreatedDate < fi.FirstInvoicedOn THEN 'S'
                                     ELSE 'C' END AS Kind
                           FROM dbo.PaymentDetail pd
                          WHERE pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1) x) pay
    OUTER APPLY (SELECT STRING_AGG(CAST(m.MethodName AS NVARCHAR(MAX)), ' + ') AS SpotModes,
                        ',' + STRING_AGG(CAST(m.PaymentMethodId AS VARCHAR(MAX)), ',') + ',' AS SpotMethodIds
                   FROM (SELECT DISTINCT pm.PaymentMethodId, ISNULL(pm.MethodName, 'Other') AS MethodName
                           FROM dbo.PaymentDetail pd
                           LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
                          WHERE pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1 AND pd.PaidAmount > 0
                            AND ISNULL(pd.TransactionRef, '') NOT LIKE 'WALLET-DEBIT-%'
                            AND (fi.FirstInvoicedOn IS NULL OR pd.CreatedDate < fi.FirstInvoicedOn)) m) spot
    WHERE ISNULL(lo.IsB2B, 0) = 1
      AND lo.BranchId = @BranchId
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@PartnerType IS NULL OR lo.AgentType = @PartnerType)
      AND (@Partner IS NULL OR lo.AgentType + '-' + CAST(lo.B2BAgentID AS VARCHAR(10)) = @Partner)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR f.Franchise_Name LIKE '%' + @Search + '%' OR corp.Corporate_Name LIKE '%' + @Search + '%');

    -- payment method label: spot modes, then Wallet, then Credit for any part left to the account
    UPDATE #R SET PaymentMethod = ISNULL(NULLIF(STUFF(
            CASE WHEN SpotAmount > 0 THEN ' + ' + ISNULL(SpotModes, 'Spot payment') ELSE '' END
          + CASE WHEN WalletAmount > 0 THEN ' + Wallet' ELSE '' END
          + CASE WHEN CreditAmount > 0 THEN ' + Credit' ELSE '' END, 1, 3, ''), ''), 'Credit');

    IF @PaymentMethod IS NOT NULL
        DELETE FROM #R
        WHERE NOT (   (@PaymentMethod = 'CREDIT' AND (CreditAmount > 0 OR (SpotAmount <= 0 AND WalletAmount <= 0)))
                   OR (@PaymentMethod = 'WALLET' AND WalletAmount > 0)
                   OR (@PaymentMethod = 'SPOT'   AND SpotAmount > 0)
                   OR (@PaymentMethod LIKE 'M-%' AND SpotAmount > 0 AND SpotMethodIds LIKE '%,' + SUBSTRING(@PaymentMethod, 3, 10) + ',%'));

    -- RS1 summary
    SELECT COUNT(1) AS BillCount, COUNT(DISTINCT PartnerKey) AS PartnerCount, ISNULL(SUM(TestCount), 0) AS TestCount,
           ISNULL(SUM(MrpAmount), 0) AS MrpAmount, ISNULL(SUM(ContractAmount), 0) AS ContractAmount, ISNULL(SUM(MarginAmount), 0) AS MarginAmount,
           CAST(CASE WHEN SUM(MrpAmount) > 0 THEN SUM(MarginAmount) * 100.0 / SUM(MrpAmount) ELSE 0 END AS DECIMAL(9, 2)) AS MarginPercent,
           ISNULL(SUM(PaidAmount), 0) AS PaidAmount, ISNULL(SUM(DueAmount), 0) AS DueAmount,
           ISNULL(SUM(SpotAmount), 0) AS SpotAmount, ISNULL(SUM(WalletAmount), 0) AS WalletAmount, ISNULL(SUM(CreditAmount), 0) AS CreditAmount,
           SUM(CASE WHEN InvoiceNo IS NULL AND IsCancelled = 0 THEN 1 ELSE 0 END) AS NotInvoiced
    FROM #R;

    -- RS2 groups
    SELECT 'byPartner' AS GroupKey, NULL AS GroupId, PartnerName AS GroupName, 0 AS SortOrder, MAX(PartnerType) AS Detail,
           COUNT(1) AS BillCount, SUM(TestCount) AS TestCount, SUM(MrpAmount) AS MrpAmount, SUM(ContractAmount) AS ContractAmount,
           SUM(MarginAmount) AS MarginAmount, SUM(PaidAmount) AS PaidAmount, SUM(DueAmount) AS DueAmount
    FROM #R GROUP BY PartnerName
    UNION ALL
    SELECT 'byPartnerType', NULL, PartnerType, 0, NULL, COUNT(1), SUM(TestCount), SUM(MrpAmount), SUM(ContractAmount), SUM(MarginAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY PartnerType
    UNION ALL
    SELECT 'byDate', NULL, BillDay, 0, NULL, COUNT(1), SUM(TestCount), SUM(MrpAmount), SUM(ContractAmount), SUM(MarginAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY BillDay
    UNION ALL
    SELECT 'byPayMethod', NULL, PaymentMethod, 0, NULL, COUNT(1), SUM(TestCount), SUM(MrpAmount), SUM(ContractAmount), SUM(MarginAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY PaymentMethod
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT * FROM #R ORDER BY BillDate DESC, LabOrderId DESC;

    -- RS4 filter options: partners of the branch
    SELECT 'partner' AS FilterKey, 'F-' + CAST(f.Franchise_ID AS VARCHAR(10)) AS Value, f.Franchise_Name + ' (Franchise)' AS Text
    FROM dbo.LabFranchiseMaster f WHERE f.Parent_Branch_ID = @BranchId AND ISNULL(f.IsDeleted, 0) = 0
    UNION ALL
    SELECT 'partner', 'C-' + CAST(c.Corporate_ID AS VARCHAR(10)), c.Corporate_Name + ' (Corporate)'
    FROM dbo.CorporateMaster c WHERE c.Branch_ID = @BranchId
    UNION ALL
    -- payment modes for the payment method filter (Credit / Wallet / Spot are fixed options of the page)
    SELECT 'paymentMethod', 'M-' + CAST(pm.PaymentMethodId AS VARCHAR(10)), 'Spot · ' + pm.MethodName
    FROM dbo.PaymentMethodMaster pm WHERE ISNULL(pm.IsActive, 1) = 1
    ORDER BY FilterKey, Text;

    DROP TABLE #R;
END;
GO
