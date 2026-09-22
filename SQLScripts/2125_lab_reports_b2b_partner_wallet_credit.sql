-- ============================================================================
-- Migration: 2125_lab_reports_b2b_partner_wallet_credit.sql
-- Description:
--   Reports > LAB, B2B (LAB Reports Roadmap):
--     LR-07  B2B Partner Billing Register     dbo.usp_Api_LabReport_B2BPartnerBilling
--     LR-08  Franchise Wallet Statement       dbo.usp_Api_LabReport_FranchiseWallet
--     LR-09  B2B Outstanding & Credit Use     dbo.usp_Api_LabReport_B2BOutstanding
--   Same four result sets as 2124 (summary / groups / rows / options).
--
--   Visibility: branch only (dbo.usp_LabReport_CheckAccess). These are partner-account reports, so they are NOT
--   limited to the user's own records: every user of the branch sees all of the branch's partner business.
--   Branch of a partner: a franchise's Parent_Branch_ID, a corporate's Branch_ID; B2B bills by their billing branch.
--   Due on a B2B bill = contract total (B2BTotal) - paid, never below 0.
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
    WHERE ISNULL(lo.IsB2B, 0) = 1
      AND lo.BranchId = @BranchId
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@PartnerType IS NULL OR lo.AgentType = @PartnerType)
      AND (@Partner IS NULL OR lo.AgentType + '-' + CAST(lo.B2BAgentID AS VARCHAR(10)) = @Partner)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR f.Franchise_Name LIKE '%' + @Search + '%' OR corp.Corporate_Name LIKE '%' + @Search + '%');

    -- RS1 summary
    SELECT COUNT(1) AS BillCount, COUNT(DISTINCT PartnerKey) AS PartnerCount, ISNULL(SUM(TestCount), 0) AS TestCount,
           ISNULL(SUM(MrpAmount), 0) AS MrpAmount, ISNULL(SUM(ContractAmount), 0) AS ContractAmount, ISNULL(SUM(MarginAmount), 0) AS MarginAmount,
           CAST(CASE WHEN SUM(MrpAmount) > 0 THEN SUM(MarginAmount) * 100.0 / SUM(MrpAmount) ELSE 0 END AS DECIMAL(9, 2)) AS MarginPercent,
           ISNULL(SUM(PaidAmount), 0) AS PaidAmount, ISNULL(SUM(DueAmount), 0) AS DueAmount,
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
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT * FROM #R ORDER BY BillDate DESC, LabOrderId DESC;

    -- RS4 filter options: partners of the branch
    SELECT 'partner' AS FilterKey, 'F-' + CAST(f.Franchise_ID AS VARCHAR(10)) AS Value, f.Franchise_Name + ' (Franchise)' AS Text
    FROM dbo.LabFranchiseMaster f WHERE f.Parent_Branch_ID = @BranchId AND ISNULL(f.IsDeleted, 0) = 0
    UNION ALL
    SELECT 'partner', 'C-' + CAST(c.Corporate_ID AS VARCHAR(10)), c.Corporate_Name + ' (Corporate)'
    FROM dbo.CorporateMaster c WHERE c.Branch_ID = @BranchId
    ORDER BY Text;

    DROP TABLE #R;
END;
GO

-- ============================================================================
-- LR-08 Franchise Wallet Statement - every wallet transaction in the period, with opening and closing balance
-- per franchise (statement order: franchise, then date).
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_FranchiseWallet
    @BranchId        INT,
    @FromDate        DATE,
    @ToDate          DATE,
    @FranchiseId     INT           = NULL,
    @TransactionType VARCHAR(10)   = NULL,   -- CREDIT / DEBIT
    @Search          NVARCHAR(100) = NULL,
    @UserId          INT           = NULL,
    @IsAdmin         BIT           = 0,
    @IsSuperAdmin    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @TransactionType = NULLIF(UPPER(LTRIM(RTRIM(@TransactionType))), '');

    -- franchises of the branch, with their balance at the start and end of the period
    SELECT f.Franchise_ID, f.Franchise_Code, f.Franchise_Name,
           ISNULL((SELECT TOP 1 t.BalanceAfter FROM dbo.LabFranchiseWalletTransaction t
                    WHERE t.Franchise_ID = f.Franchise_ID AND t.CreatedDate < @From ORDER BY t.CreatedDate DESC, t.TransactionId DESC), 0) AS OpeningBalance,
           ISNULL((SELECT TOP 1 t.BalanceAfter FROM dbo.LabFranchiseWalletTransaction t
                    WHERE t.Franchise_ID = f.Franchise_ID AND t.CreatedDate < @To ORDER BY t.CreatedDate DESC, t.TransactionId DESC), 0) AS ClosingBalance,
           ISNULL(w.CurrentBalance, 0) AS CurrentBalance
    INTO #F
    FROM dbo.LabFranchiseMaster f
    LEFT JOIN dbo.LabFranchiseWallet w ON w.Franchise_ID = f.Franchise_ID
    WHERE f.Parent_Branch_ID = @BranchId AND ISNULL(f.IsDeleted, 0) = 0
      AND (@FranchiseId IS NULL OR f.Franchise_ID = @FranchiseId);

    SELECT t.TransactionId, t.CreatedDate AS TransactionDate,
           CONVERT(VARCHAR(10), CAST(t.CreatedDate AS DATE), 23) AS TransactionDay,
           f.Franchise_ID AS FranchiseId, f.Franchise_Code AS FranchiseCode, f.Franchise_Name AS FranchiseName,
           UPPER(t.TransactionType) AS TransactionType,
           CASE WHEN t.ReferenceType = 'TOPUP' THEN 'Wallet top-up' WHEN t.ReferenceType = 'LAB_BILL' THEN 'LAB bill' ELSE ISNULL(t.ReferenceType, '') END AS Reference,
           lo.BillNo, t.ReceiptNo,
           CAST(CASE WHEN UPPER(t.TransactionType) = 'CREDIT' THEN t.Amount ELSE 0 END AS DECIMAL(18, 2)) AS CreditAmount,
           CAST(CASE WHEN UPPER(t.TransactionType) = 'DEBIT'  THEN t.Amount ELSE 0 END AS DECIMAL(18, 2)) AS DebitAmount,
           CAST(t.BalanceAfter AS DECIMAL(18, 2)) AS BalanceAfter,
           NULLIF(LTRIM(RTRIM(t.Narration)), '') AS Narration,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS RecordedBy
    INTO #R
    FROM dbo.LabFranchiseWalletTransaction t
    INNER JOIN #F f ON f.Franchise_ID = t.Franchise_ID
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = t.ReferenceId AND t.ReferenceType = 'LAB_BILL'
    LEFT JOIN dbo.Users u ON u.Id = t.CreatedBy
    WHERE t.CreatedDate >= @From AND t.CreatedDate < @To
      AND (@TransactionType IS NULL OR UPPER(t.TransactionType) = @TransactionType)
      AND (@Search IS NULL OR t.ReceiptNo LIKE '%' + @Search + '%' OR lo.BillNo LIKE '%' + @Search + '%' OR t.Narration LIKE '%' + @Search + '%');

    -- RS1 summary
    SELECT (SELECT COUNT(1) FROM #F) AS FranchiseCount,
           (SELECT ISNULL(SUM(OpeningBalance), 0) FROM #F) AS OpeningBalance,
           ISNULL((SELECT SUM(CreditAmount) FROM #R), 0) AS CreditAmount,
           ISNULL((SELECT SUM(DebitAmount) FROM #R), 0) AS DebitAmount,
           (SELECT ISNULL(SUM(ClosingBalance), 0) FROM #F) AS ClosingBalance,
           (SELECT ISNULL(SUM(CurrentBalance), 0) FROM #F) AS CurrentBalance,
           (SELECT COUNT(1) FROM #R) AS TransactionCount,
           (SELECT COUNT(1) FROM #R WHERE TransactionType = 'CREDIT') AS TopUpCount;

    -- RS2 groups
    SELECT 'byFranchise' AS GroupKey, f.Franchise_ID AS GroupId, f.Franchise_Name AS GroupName, 0 AS SortOrder,
           f.OpeningBalance, ISNULL(SUM(r.CreditAmount), 0) AS CreditAmount, ISNULL(SUM(r.DebitAmount), 0) AS DebitAmount,
           f.ClosingBalance, COUNT(r.TransactionId) AS TransactionCount
    FROM #F f LEFT JOIN #R r ON r.FranchiseId = f.Franchise_ID
    GROUP BY f.Franchise_ID, f.Franchise_Name, f.OpeningBalance, f.ClosingBalance
    UNION ALL
    SELECT 'byType', NULL, CASE TransactionType WHEN 'CREDIT' THEN 'Top-up (credit)' ELSE 'Bill deduction (debit)' END, 0,
           NULL, SUM(CreditAmount), SUM(DebitAmount), NULL, COUNT(1)
    FROM #R GROUP BY TransactionType
    UNION ALL
    SELECT 'byDate', NULL, TransactionDay, 0, NULL, SUM(CreditAmount), SUM(DebitAmount), NULL, COUNT(1)
    FROM #R GROUP BY TransactionDay
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows (statement order)
    SELECT *, CASE TransactionType WHEN 'CREDIT' THEN 'Top-up (credit)' ELSE 'Bill deduction (debit)' END AS TypeLabel
    FROM #R ORDER BY FranchiseName, TransactionDate, TransactionId;

    -- RS4 filter options
    SELECT 'franchiseId' AS FilterKey, CAST(Franchise_ID AS VARCHAR(10)) AS Value, Franchise_Name AS Text FROM #F ORDER BY Franchise_Name;

    DROP TABLE #R; DROP TABLE #F;
END;
GO

-- ============================================================================
-- LR-09 B2B Outstanding & Credit Use - every partner of the branch with what it owes (open B2B bills, bill date
-- in the period), its credit limit and days, ageing, and the last invoice / settlement. Detail: each open bill.
-- Overdue = bill older than the partner's credit days.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_B2BOutstanding
    @BranchId     INT,
    @FromDate     DATE,
    @ToDate       DATE,
    @PartnerType  CHAR(1)       = NULL,
    @AgeBucket    VARCHAR(10)   = NULL,   -- 0-30 / 31-60 / 61-90 / 90+
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
    SET @AgeBucket = NULLIF(LTRIM(RTRIM(@AgeBucket)), '');

    -- partners of the branch with their credit terms
    SELECT 'F-' + CAST(f.Franchise_ID AS VARCHAR(10)) AS PartnerKey, 'F' AS AgentType, f.Franchise_ID AS AgentId,
           'Franchise' AS PartnerType, f.Franchise_Code AS PartnerCode, f.Franchise_Name AS PartnerName,
           CAST(ISNULL(cl.Credit_Limit, 0)
                + CASE WHEN ISNULL(cl.Temporary_Limit_Increase, 0) > 0 AND (cl.Temp_Limit_Valid_Till IS NULL OR cl.Temp_Limit_Valid_Till >= CAST(GETDATE() AS DATE))
                       THEN cl.Temporary_Limit_Increase ELSE 0 END AS DECIMAL(18, 2)) AS CreditLimit,
           ISNULL(cl.Credit_Days, 0) AS CreditDays,
           CAST(w.CurrentBalance AS DECIMAL(18, 2)) AS WalletBalance
    INTO #P
    FROM dbo.LabFranchiseMaster f
    LEFT JOIN dbo.LabFranchiseCreditLimitMaster cl ON cl.Franchise_ID = f.Franchise_ID
    LEFT JOIN dbo.LabFranchiseWallet w ON w.Franchise_ID = f.Franchise_ID
    WHERE f.Parent_Branch_ID = @BranchId AND ISNULL(f.IsDeleted, 0) = 0 AND ISNULL(f.IsActive, 1) = 1
    UNION ALL
    SELECT 'C-' + CAST(c.Corporate_ID AS VARCHAR(10)), 'C', c.Corporate_ID, 'Corporate', c.Corporate_Code, c.Corporate_Name,
           CAST(ISNULL(c.Credit_Limit, 0) AS DECIMAL(18, 2)), ISNULL(c.Credit_Days, 0), NULL
    FROM dbo.CorporateMaster c
    WHERE c.Branch_ID = @BranchId AND ISNULL(c.Status, 1) = 1;

    DELETE FROM #P WHERE @PartnerType IS NOT NULL AND AgentType <> @PartnerType;

    -- open bills (contract total - paid > 0)
    SELECT lo.LabOrderId, lo.BillNo, lo.OrderDate AS BillDate,
           p.PartnerKey, p.PartnerType, p.PartnerName, p.CreditDays,
           pt.PatientCode,
           LTRIM(RTRIM(ISNULL(pt.Salutation, '') + ' ' + ISNULL(pt.FirstName, '') + ' ' + ISNULL(pt.LastName, ''))) AS PatientName,
           DATEDIFF(DAY, lo.OrderDate, GETDATE()) AS AgeDays,
           CASE WHEN DATEDIFF(DAY, lo.OrderDate, GETDATE()) <= 30 THEN '0-30'
                WHEN DATEDIFF(DAY, lo.OrderDate, GETDATE()) <= 60 THEN '31-60'
                WHEN DATEDIFF(DAY, lo.OrderDate, GETDATE()) <= 90 THEN '61-90' ELSE '90+' END AS AgeBucket,
           CAST(ISNULL(lo.B2BTotal, lo.TotalAmount) AS DECIMAL(18, 2)) AS ContractAmount,
           CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
           CAST(ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS DueAmount,
           CAST(CASE WHEN p.CreditDays > 0 AND DATEDIFF(DAY, lo.OrderDate, GETDATE()) > p.CreditDays THEN 1 ELSE 0 END AS BIT) AS IsOverdue,
           inv.InvoiceNo, inv.InvoiceDueDate
    INTO #R
    FROM dbo.LabOrder lo
    INNER JOIN #P p ON p.AgentType = lo.AgentType AND p.AgentId = lo.B2BAgentID
    INNER JOIN dbo.PatientMaster pt ON pt.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    OUTER APPLY (SELECT TOP 1 i.InvoiceNo, i.DueDate AS InvoiceDueDate FROM dbo.B2BInvoiceItem ii JOIN dbo.B2BInvoice i ON i.InvoiceId = ii.InvoiceId
                  WHERE ii.LabOrderId = lo.LabOrderId ORDER BY i.InvoiceId DESC) inv
    WHERE ISNULL(lo.IsB2B, 0) = 1 AND lo.IsActive = 1
      AND lo.BranchId = @BranchId
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) > 0
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR p.PartnerName LIKE '%' + @Search + '%'
           OR pt.PatientCode LIKE '%' + @Search + '%' OR pt.FirstName LIKE '%' + @Search + '%' OR pt.LastName LIKE '%' + @Search + '%');

    IF @AgeBucket IS NOT NULL DELETE FROM #R WHERE AgeBucket <> @AgeBucket;

    -- per partner: outstanding against its credit limit
    SELECT p.PartnerKey, p.PartnerType, p.PartnerName, p.CreditLimit, p.CreditDays, p.WalletBalance,
           COUNT(r.LabOrderId) AS OpenBills,
           ISNULL(SUM(r.DueAmount), 0) AS DueAmount,
           ISNULL(SUM(CASE WHEN r.IsOverdue = 1 THEN r.DueAmount END), 0) AS OverdueAmount,
           ISNULL(MAX(r.AgeDays), 0) AS OldestDays,
           CAST(CASE WHEN p.CreditLimit > 0 THEN ISNULL(SUM(r.DueAmount), 0) * 100.0 / p.CreditLimit END AS DECIMAL(9, 1)) AS CreditUsedPercent,
           (SELECT MAX(i.InvoiceDate) FROM dbo.B2BInvoice i WHERE i.PartnerType = p.AgentType AND i.PartnerId = p.AgentId) AS LastInvoiceDate,
           (SELECT MAX(pd.PaymentDate) FROM dbo.LabOrder lo2
              JOIN dbo.PaymentHeader ph2 ON ph2.ModuleCode = 'LAB' AND ph2.ModuleRefId = lo2.LabOrderId AND ph2.IsActive = 1
              JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = ph2.PaymentHeaderId AND pd.IsActive = 1
             WHERE lo2.IsB2B = 1 AND lo2.AgentType = p.AgentType AND lo2.B2BAgentID = p.AgentId) AS LastSettlementDate
    INTO #PS
    FROM #P p LEFT JOIN #R r ON r.PartnerKey = p.PartnerKey
    GROUP BY p.PartnerKey, p.AgentType, p.AgentId, p.PartnerType, p.PartnerName, p.CreditLimit, p.CreditDays, p.WalletBalance;

    -- RS1 summary
    SELECT (SELECT COUNT(1) FROM #PS) AS PartnerCount,
           (SELECT COUNT(1) FROM #PS WHERE DueAmount > 0) AS PartnersWithDue,
           (SELECT ISNULL(SUM(DueAmount), 0) FROM #PS) AS DueAmount,
           (SELECT ISNULL(SUM(OverdueAmount), 0) FROM #PS) AS OverdueAmount,
           (SELECT COUNT(1) FROM #PS WHERE CreditLimit > 0 AND DueAmount > CreditLimit) AS OverLimitCount,
           (SELECT COUNT(1) FROM #PS WHERE CreditLimit > 0 AND DueAmount >= CreditLimit * 0.8) AS NearLimitCount,
           (SELECT ISNULL(SUM(CreditLimit), 0) FROM #PS) AS CreditLimit,
           (SELECT ISNULL(SUM(WalletBalance), 0) FROM #PS) AS WalletBalance,
           (SELECT COUNT(1) FROM #R) AS OpenBills;

    -- RS2 groups
    SELECT 'byPartner' AS GroupKey, NULL AS GroupId, PartnerName AS GroupName, 0 AS SortOrder, PartnerType AS Detail,
           OpenBills, DueAmount, OverdueAmount, CreditLimit, CreditUsedPercent, CreditDays, OldestDays, WalletBalance, LastInvoiceDate, LastSettlementDate
    FROM #PS
    UNION ALL
    SELECT 'byAgeBucket', NULL, AgeBucket, CASE AgeBucket WHEN '0-30' THEN 1 WHEN '31-60' THEN 2 WHEN '61-90' THEN 3 ELSE 4 END, NULL,
           COUNT(1), SUM(DueAmount), SUM(CASE WHEN IsOverdue = 1 THEN DueAmount ELSE 0 END), NULL, NULL, NULL, MAX(AgeDays), NULL, NULL, NULL
    FROM #R GROUP BY AgeBucket
    UNION ALL
    SELECT 'byPartnerType', NULL, PartnerType, 0, NULL,
           COUNT(1), SUM(DueAmount), SUM(CASE WHEN IsOverdue = 1 THEN DueAmount ELSE 0 END), NULL, NULL, NULL, MAX(AgeDays), NULL, NULL, NULL
    FROM #R GROUP BY PartnerType
    ORDER BY GroupKey, SortOrder, DueAmount DESC;

    -- RS3 rows (open bills, oldest first)
    SELECT * FROM #R ORDER BY AgeDays DESC, DueAmount DESC;

    -- RS4 filter options: none needed beyond the fixed lists
    SELECT CAST(NULL AS VARCHAR(20)) AS FilterKey, CAST(NULL AS VARCHAR(20)) AS Value, CAST(NULL AS NVARCHAR(200)) AS Text WHERE 1 = 0;

    DROP TABLE #R; DROP TABLE #PS; DROP TABLE #P;
END;
GO

PRINT 'LAB B2B reports LR-07, LR-08, LR-09 ready.';
GO
