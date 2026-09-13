-- ============================================================================
-- Script: 2059_b2b_invoice_detail_modern_line_items.sql
-- Description: Updates dbo.usp_B2B_GetInvoiceDetail to return 3 result sets:
--              1. Header (B2B Invoice details, partner info, amounts)
--              2. Orders (Order-level summaries)
--              3. Test Line Items (Individual investigations/profiles with B2B rate,
--                 ordered by OrderDate, LabOrderId, LabOrderItemId for date-wise grouping)
-- ============================================================================

USE Dev_EMR;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetInvoiceDetail
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- ── Result Set 1: Invoice Header ──────────────────────────────────────────
    SELECT 
        inv.InvoiceId,
        inv.InvoiceNo,
        inv.PartnerType,
        inv.PartnerId,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Franchise_Name 
            WHEN 'C' THEN corp.Corporate_Name 
            ELSE 'Unknown' 
        END AS PartnerName,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Franchise_Code 
            WHEN 'C' THEN corp.Corporate_Code 
            ELSE '' 
        END AS PartnerCode,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Mobile_No 
            WHEN 'C' THEN corp.Contact_No 
            ELSE '' 
        END AS PartnerPhone,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Email 
            WHEN 'C' THEN corp.Email 
            ELSE '' 
        END AS PartnerEmail,
        CASE inv.PartnerType 
            WHEN 'F' THEN '' 
            WHEN 'C' THEN corp.Address 
            ELSE '' 
        END AS PartnerAddress,
        inv.BranchId,
        b.BranchName,
        b.BranchCode,
        inv.BillingCycle,
        inv.InvoiceDate,
        inv.DueDate,
        inv.TotalAmount,
        inv.DiscountAmount,
        inv.TaxAmount,
        inv.NetAmount,
        CASE WHEN inv.PaidAmount > inv.NetAmount THEN inv.NetAmount ELSE inv.PaidAmount END AS PaidAmount,
        CASE WHEN inv.BalanceAmount < 0 THEN 0.00 ELSE inv.BalanceAmount END AS BalanceAmount,
        inv.Status,
        inv.Notes,
        inv.CreatedDate,
        u.FullName AS CreatedByName
    FROM dbo.B2BInvoice inv
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = inv.PartnerId AND inv.PartnerType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = inv.PartnerId AND inv.PartnerType = 'C'
    LEFT JOIN dbo.Branchmaster b ON b.BranchId = inv.BranchId
    LEFT JOIN dbo.UserMaster u ON u.Id = inv.CreatedBy
    WHERE inv.InvoiceId = @InvoiceId;

    -- ── Result Set 2: Order-level Items ───────────────────────────────────────
    SELECT 
        bii.InvoiceItemId,
        bii.InvoiceId,
        bii.LabOrderId,
        bii.BillNo,
        bii.OrderDate,
        bii.PatientName,
        p.PatientCode,
        p.PhoneNumber AS PatientPhone,
        bii.B2BTotal,
        bii.Amount,
        STUFF((
            SELECT ', ' + CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Profile') ELSE ISNULL(sm.Test_Name, 'Test') END
            FROM dbo.LabOrderItem si
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster sm ON sm.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
            WHERE si.LabOrderId = bii.LabOrderId AND si.IsActive = 1
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS TestNames
    FROM dbo.B2BInvoiceItem bii
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bii.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    WHERE bii.InvoiceId = @InvoiceId
    ORDER BY bii.OrderDate ASC, bii.LabOrderId ASC;

    -- ── Result Set 3: Test-level Line Items with B2B Rates ───────────────────
    SELECT 
        loi.LabOrderItemId,
        loi.LabOrderId,
        bii.InvoiceId,
        bii.BillNo,
        bii.OrderDate,
        bii.PatientName,
        p.PatientCode,
        loi.InvestigationId,
        ISNULL(loi.Type, 'I') AS ItemType,
        CASE WHEN loi.Type = 'P' THEN pkg.Profile_Code ELSE lim.Test_Code END AS TestCode,
        CASE WHEN loi.Type = 'P' THEN pkg.Profile_Name ELSE lim.Test_Name END AS TestName,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE ISNULL(dm.DeptName, 'Pathology') END AS DepartmentName,
        loi.Price AS MrpRate,
        ISNULL(NULLIF(loi.B2BRate, 0.00), loi.Price) AS B2BRate
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.B2BInvoiceItem bii ON bii.LabOrderId = loi.LabOrderId
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bii.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    WHERE bii.InvoiceId = @InvoiceId AND loi.IsActive = 1
    ORDER BY bii.OrderDate ASC, bii.LabOrderId ASC, loi.LabOrderItemId ASC;
END;
GO
