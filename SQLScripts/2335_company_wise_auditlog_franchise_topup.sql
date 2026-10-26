-- 2335 Company-wise Audit Logs and Franchise Top-Up
--   usp_FranchiseTopUp_Dashboard / usp_FranchiseTopUp_Receipt: optional @CompanyId - only that company's franchises.
--   AuditLogs: a row without a branch takes its user's company (it was saved as company 1 before the audit service set it).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
-- ── 3a. Screen data ─────────────────────────────────────────────────────────
-- RS1 KPIs · RS2 franchise wallets · RS3 top-ups of the period · RS4 top-ups by payment mode · RS5 day-wise trend
CREATE OR ALTER PROCEDURE dbo.usp_FranchiseTopUp_Dashboard
    @FromDate        DATE,
    @ToDate          DATE,
    @FranchiseId     INT = NULL,
    @PaymentMethodId INT = NULL,     -- 0 = mode not recorded
    @Search          NVARCHAR(100) = NULL,
    @CompanyId       INT = NULL       -- 2335: the user's company (NULL = every company)
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_WARNINGS ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @FromDt DATETIME2 = @FromDate, @ToDt DATETIME2 = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME2));
    DECLARE @Last30 DATETIME2 = DATEADD(DAY, -30, SYSDATETIME());

    -- every franchise with its wallet and use
    SELECT f.Franchise_ID, f.Franchise_Code, f.Franchise_Name, f.Mobile_No,
           CAST(ISNULL(f.IsActive, 0) AS BIT) AS IsActive, CAST(ISNULL(f.Status, 0) AS BIT) AS IsSuspended,
           ISNULL(c.Credit_Facility_Type, 1) AS CreditFacilityType,
           CAST(ISNULL(w.CurrentBalance, 0) AS DECIMAL(18,2)) AS WalletBalance,
           lt.LastTopUpOn, lt.LastTopUpAmount, lt.LastReceiptNo,
           CAST(ISNULL(p.TopUpAmount, 0) AS DECIMAL(18,2)) AS PeriodTopUp, ISNULL(p.TopUpCount, 0) AS PeriodTopUpCount,
           CAST(ISNULL(p.UsedAmount, 0) AS DECIMAL(18,2)) AS PeriodUsage,
           CAST(ISNULL(u.Used30, 0) AS DECIMAL(18,2)) AS UsedLast30Days
    INTO #f
    FROM dbo.LabFranchiseMaster f
    LEFT JOIN dbo.LabFranchiseCreditLimitMaster c ON c.Franchise_ID = f.Franchise_ID
    LEFT JOIN dbo.LabFranchiseWallet w ON w.Franchise_ID = f.Franchise_ID
    OUTER APPLY (SELECT TOP 1 t.CreatedDate AS LastTopUpOn, t.Amount AS LastTopUpAmount, t.ReceiptNo AS LastReceiptNo
                 FROM dbo.LabFranchiseWalletTransaction t
                 WHERE t.Franchise_ID = f.Franchise_ID AND t.ReferenceType = 'TOPUP' ORDER BY t.TransactionId DESC) lt
    OUTER APPLY (SELECT SUM(CASE WHEN t.ReferenceType = 'TOPUP' THEN t.Amount ELSE 0 END) AS TopUpAmount,
                        SUM(CASE WHEN t.ReferenceType = 'TOPUP' THEN 1 ELSE 0 END) AS TopUpCount,
                        SUM(CASE WHEN t.TransactionType = 'DEBIT' THEN t.Amount ELSE 0 END) AS UsedAmount
                 FROM dbo.LabFranchiseWalletTransaction t
                 WHERE t.Franchise_ID = f.Franchise_ID AND t.CreatedDate >= @FromDt AND t.CreatedDate < @ToDt) p
    OUTER APPLY (SELECT SUM(t.Amount) AS Used30 FROM dbo.LabFranchiseWalletTransaction t
                 WHERE t.Franchise_ID = f.Franchise_ID AND t.TransactionType = 'DEBIT' AND t.CreatedDate >= @Last30) u
    WHERE ISNULL(f.IsDeleted, 0) = 0 AND (@CompanyId IS NULL OR f.CompanyId = @CompanyId);

    -- top-ups of the period (filtered)
    SELECT t.TransactionId, t.ReceiptNo, t.CreatedDate, t.Franchise_ID, f.Franchise_Code, f.Franchise_Name,
           t.Amount, t.BalanceAfter, t.PaymentMethodId, pm.MethodName, t.TransactionRef,
           NULLIF(NULLIF(LTRIM(RTRIM(t.Narration)), N''), N'Wallet balance recharged/top-up') AS Narration,
           t.BranchId, b.BranchName, t.CreatedBy,
           COALESCE(NULLIF(LTRIM(RTRIM(us.FullName)), N''), NULLIF(LTRIM(RTRIM(CONCAT(us.FirstName, N' ', us.LastName))), N''), us.Username) AS CreatedByName
    INTO #t
    FROM dbo.LabFranchiseWalletTransaction t
    INNER JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = t.Franchise_ID
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = t.PaymentMethodId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = t.BranchId
    LEFT JOIN dbo.Users us ON us.Id = t.CreatedBy
    WHERE t.ReferenceType = 'TOPUP' AND t.CreatedDate >= @FromDt AND t.CreatedDate < @ToDt
      AND (@CompanyId IS NULL OR f.CompanyId = @CompanyId)
      AND (@FranchiseId IS NULL OR t.Franchise_ID = @FranchiseId)
      AND (@PaymentMethodId IS NULL OR ISNULL(t.PaymentMethodId, 0) = @PaymentMethodId)
      AND (@Search IS NULL OR t.ReceiptNo LIKE N'%' + @Search + N'%' OR t.TransactionRef LIKE N'%' + @Search + N'%'
           OR f.Franchise_Name LIKE N'%' + @Search + N'%' OR f.Franchise_Code LIKE N'%' + @Search + N'%' OR t.Narration LIKE N'%' + @Search + N'%');

    -- RS1
    SELECT COUNT(*) AS TopUpCount,
           CAST(ISNULL(SUM(Amount), 0) AS DECIMAL(18,2)) AS TopUpAmount,
           CAST(ISNULL(MAX(Amount), 0) AS DECIMAL(18,2)) AS HighestTopUp,
           COUNT(DISTINCT Franchise_ID) AS FranchisesToppedUp,
           (SELECT COUNT(*) FROM #f WHERE CreditFacilityType = 1 AND IsActive = 1) AS PrepaidFranchiseCount,
           (SELECT CAST(ISNULL(SUM(WalletBalance), 0) AS DECIMAL(18,2)) FROM #f WHERE CreditFacilityType = 1) AS TotalWalletBalance,
           (SELECT COUNT(*) FROM #f WHERE CreditFacilityType = 1 AND IsActive = 1
              AND (WalletBalance <= 0 OR (UsedLast30Days > 0 AND WalletBalance < UsedLast30Days / 30.0 * 7))) AS LowBalanceCount,
           (SELECT CAST(ISNULL(SUM(PeriodUsage), 0) AS DECIMAL(18,2)) FROM #f) AS PeriodUsage
    FROM #t;

    -- RS2
    SELECT *, CASE WHEN UsedLast30Days > 0 THEN CAST(WalletBalance / (UsedLast30Days / 30.0) AS DECIMAL(10,1)) END AS DaysOfCover
    FROM #f
    WHERE (@FranchiseId IS NULL OR Franchise_ID = @FranchiseId)
    ORDER BY CASE WHEN CreditFacilityType = 1 AND IsActive = 1 THEN 0 ELSE 1 END, Franchise_Name;

    -- RS3
    SELECT * FROM #t ORDER BY CreatedDate DESC, TransactionId DESC;

    -- RS4
    SELECT ISNULL(PaymentMethodId, 0) AS PaymentMethodId, ISNULL(MethodName, N'Not recorded') AS MethodName,
           COUNT(*) AS TopUpCount, CAST(SUM(Amount) AS DECIMAL(18,2)) AS Amount
    FROM #t GROUP BY ISNULL(PaymentMethodId, 0), ISNULL(MethodName, N'Not recorded') ORDER BY Amount DESC;

    -- RS5 (all franchises of the filter, top-ups vs wallet use per day)
    SELECT CAST(t.CreatedDate AS DATE) AS [Day],
           CAST(SUM(CASE WHEN t.ReferenceType = 'TOPUP' THEN t.Amount ELSE 0 END) AS DECIMAL(18,2)) AS TopUp,
           CAST(SUM(CASE WHEN t.TransactionType = 'DEBIT' THEN t.Amount ELSE 0 END) AS DECIMAL(18,2)) AS Used
    FROM dbo.LabFranchiseWalletTransaction t
    WHERE t.CreatedDate >= @FromDt AND t.CreatedDate < @ToDt AND (@FranchiseId IS NULL OR t.Franchise_ID = @FranchiseId)
      AND (@CompanyId IS NULL OR EXISTS (SELECT 1 FROM dbo.LabFranchiseMaster f WHERE f.Franchise_ID = t.Franchise_ID AND f.CompanyId = @CompanyId))
    GROUP BY CAST(t.CreatedDate AS DATE) ORDER BY [Day];

    DROP TABLE #f; DROP TABLE #t;
END;
GO

-- ── 3b. Receipt ─────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_FranchiseTopUp_Receipt
    @ReceiptNo NVARCHAR(50),
    @CompanyId INT = NULL   -- 2335: only a receipt of the user's company's franchise
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 t.TransactionId, t.ReceiptNo, t.CreatedDate, t.Amount, t.BalanceAfter,
           CAST(t.BalanceAfter - t.Amount AS DECIMAL(18,2)) AS BalanceBefore,
           t.PaymentMethodId, pm.MethodName, t.TransactionRef,
           NULLIF(NULLIF(LTRIM(RTRIM(t.Narration)), N''), N'Wallet balance recharged/top-up') AS Narration,
           t.BranchId, b.BranchName,
           f.Franchise_ID, f.Franchise_Code, f.Franchise_Name, f.Mobile_No, f.Email,
           COALESCE(NULLIF(LTRIM(RTRIM(us.FullName)), N''), NULLIF(LTRIM(RTRIM(CONCAT(us.FirstName, N' ', us.LastName))), N''), us.Username) AS CreatedByName
    FROM dbo.LabFranchiseWalletTransaction t
    INNER JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = t.Franchise_ID
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = t.PaymentMethodId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = t.BranchId
    LEFT JOIN dbo.Users us ON us.Id = t.CreatedBy
    WHERE t.ReceiptNo = @ReceiptNo AND t.ReferenceType = 'TOPUP' AND (@CompanyId IS NULL OR f.CompanyId = @CompanyId)
    ORDER BY t.TransactionId DESC;
END;
GO

UPDATE a SET CompanyId = u.CompanyId
  FROM dbo.AuditLogs a JOIN dbo.Users u ON u.Id = a.UserId
 WHERE a.BranchId IS NULL AND u.CompanyId IS NOT NULL AND a.CompanyId <> u.CompanyId;
GO
PRINT 'Script 2335 applied: company-wise Audit Logs and Franchise Top-Up.';
GO
