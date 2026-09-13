-- ============================================================================
-- Migration: 2057_b2b_multi_partner_invoice_generation.sql
-- Description: Support multi-franchise and multi-corporate batch invoice generation.
--              Updates usp_B2B_GetUninvoicedOrders to accept @AgentIds (multiple IDs or 'ALL')
--              and return partner details (AgentId, PartnerName, PartnerCode).
-- ============================================================================

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
    ORDER BY PartnerName ASC, lo.OrderDate ASC;
END;
GO
