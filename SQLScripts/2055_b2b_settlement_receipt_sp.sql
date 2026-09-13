-- ============================================================================
-- Migration: 2055_b2b_settlement_receipt_sp.sql
-- Description: Stored procedure to retrieve B2B multi-bill settlement receipt details
-- ============================================================================

CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetSettlementReceipt
(
    @ReceiptNo NVARCHAR(50)
)
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    -- RS1: Receipt Header & Partner Information
    SELECT TOP 1
        pd.ReceiptNo,
        pd.PaymentDate,
        pd.CreatedDate,
        SUM(pd.PaidAmount) OVER() AS TotalAmount,
        COUNT(pd.PaymentDetailId) OVER() AS SettledBillCount,
        ISNULL(pm.MethodName, 'Cash') AS PaymentMethod,
        pd.TransactionRef,
        pd.BankName,
        pd.ChequeNo,
        pd.Notes,
        u.FullName AS CreatedByName,
        lo.AgentType,
        lo.B2BAgentID AS AgentId,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Franchise_Name
            WHEN lo.AgentType = 'C' THEN corp.Corporate_Name
            ELSE 'B2B Partner'
        END AS PartnerName,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Franchise_Code
            WHEN lo.AgentType = 'C' THEN corp.Corporate_Code
            ELSE '—'
        END AS PartnerCode,
        CASE 
            WHEN lo.AgentType = 'F' THEN 
                CASE WHEN f.Franchise_Type = 1 THEN 'Franchise Partner (Prepaid Wallet)' ELSE 'Franchise Partner (Postpaid Credit)' END
            WHEN lo.AgentType = 'C' THEN ISNULL(corp.Corporate_Type, 'Corporate Partner')
            ELSE 'B2B Client'
        END AS PartnerType,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Mobile_No
            WHEN lo.AgentType = 'C' THEN corp.Contact_No
            ELSE NULL
        END AS PartnerPhone,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Email
            WHEN lo.AgentType = 'C' THEN corp.Email
            ELSE NULL
        END AS PartnerEmail,
        CASE 
            WHEN lo.AgentType = 'C' THEN corp.Address
            ELSE NULL
        END AS PartnerAddress,
        lo.BranchId,
        b.BranchName,
        CASE 
            WHEN pm.MethodCode = 'CASH' OR pm.MethodName = 'Cash' THEN 'Cash Account'
            ELSE 'Bank Account'
        END AS DebitLedgerName,
        CASE 
            WHEN lo.AgentType = 'C' THEN 'Corporate Receivable'
            ELSE 'Franchise Receivable'
        END AS CreditLedgerName
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = ph.ModuleRefId
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    LEFT JOIN dbo.Users u ON u.Id = pd.CreatedBy
    LEFT JOIN dbo.BranchMaster b ON b.BranchID = lo.BranchId
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE pd.ReceiptNo = @ReceiptNo AND pd.IsActive = 1;

    -- RS2: Settled Bills Breakdown
    SELECT 
        lo.LabOrderId,
        lo.BillNo,
        lo.TokenNo,
        lo.OrderDate,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.Gender,
        DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
            CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END AS Age,
        ISNULL(lo.B2BTotal, lo.TotalAmount) AS B2BTotal,
        pd.PaidAmount AS SettledAmount,
        ph.TotalPaid,
        ph.BalanceDue,
        ph.PaymentStatus,
        tests.TestNames
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = ph.ModuleRefId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    OUTER APPLY (
        SELECT STRING_AGG(CASE WHEN loi.Type = 'P' THEN pkg.Profile_Name ELSE lim.Test_Name END, ', ') AS TestNames
        FROM dbo.LabOrderItem loi
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
        WHERE loi.LabOrderId = lo.LabOrderId AND loi.IsActive = 1
    ) tests
    WHERE pd.ReceiptNo = @ReceiptNo AND pd.IsActive = 1
    ORDER BY lo.OrderDate ASC, lo.LabOrderId ASC;
END;
GO
