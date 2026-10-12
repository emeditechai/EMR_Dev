-- ============================================================================
-- Migration: 2253_daily_collection_register.sql
-- Description: Reports > LAB > "B2C Collection Register" becomes the "Daily Collection Register":
--   * it also lists money received on B2B bills paid directly (cash / card / UPI / bank on the bill) - not a franchise
--     wallet deduction (WALLET-DEBIT-...) and not a settlement of partner credit (B2B Multi-Bill Settlement);
--   * new filter Billing type: all / B2C / B2B (@BillingType); each receipt carries BillingType and the partner name;
--   * summary adds the B2C / B2B split. The page keeps its URL and permission (REPORTS.LABB2CCOLLECTIONREGISTER).
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_B2CCollectionRegister
    @BranchId        INT,
    @FromDate        DATE,
    @ToDate          DATE,
    @PaymentMethodId INT           = NULL,
    @CollectedBy     INT           = NULL,
    @Search          NVARCHAR(100) = NULL,
    @UserId          INT           = NULL,
    @IsAdmin         BIT           = 0,
    @IsSuperAdmin    BIT           = 0,
    @BillingType     VARCHAR(5)    = NULL     -- 2255: B2C | B2B | NULL = all
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@BranchId, 0) <= 0
        THROW 50010, 'A branch is required for this report.', 1;
    IF ISNULL(@IsSuperAdmin, 0) = 0
    BEGIN
        IF ISNULL(@UserId, 0) <= 0
            THROW 50010, 'The signed-in user could not be identified.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.UserBranches ub
                        WHERE ub.UserId = @UserId AND ub.BranchID = @BranchId AND ISNULL(ub.IsActive, 1) = 1)
            THROW 50011, 'You do not have access to this branch''s collection register.', 1;
    END
    -- a non-administrator sees only the money receipts they collected
    IF ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0
        SET @CollectedBy = @UserId;

    IF @ToDate < @FromDate
    BEGIN
        DECLARE @Swap DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @Swap;
    END

    DECLARE @From DATETIME = CAST(@FromDate AS DATETIME);
    DECLARE @To   DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));   -- exclusive upper bound
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');

    SELECT
        pd.PaymentDetailId,
        pd.ReceiptNo,
        pd.PaymentDate                                   AS ReceiptDate,
        pd.PaidAmount,
        pd.PaymentMethodId,
        ISNULL(pm.MethodName, 'Other')                   AS PaymentMode,
        NULLIF(LTRIM(RTRIM(COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''),
               NULLIF(pd.ChequeNo, ''), CASE WHEN ISNULL(pd.CardLast4, '') <> '' THEN 'XXXX ' + pd.CardLast4 END))), '') AS PaymentReference,
        NULLIF(LTRIM(RTRIM(pd.BankName)), '')            AS BankName,
        lo.LabOrderId,
        lo.BillNo,
        lo.TokenNo,
        lo.OrderDate                                     AS BillDate,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        ISNULL(ph.NetAmount, lo.TotalAmount)             AS BillNetAmount,
        ISNULL(ph.TotalPaid, 0)                          AS BillTotalPaid,
        ISNULL(ph.BalanceDue, 0)                         AS BillBalanceDue,
        ISNULL(ph.PaymentStatus, 'U')                    AS PaymentStatus,
        CAST(lo.IsActive AS BIT)                         AS IsBillActive,
        pd.CreatedBy                                     AS CollectedById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CollectedBy,
        -- 2255: B2B bills paid directly at the counter are part of the day's collection
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE lo.AgentType WHEN 'F' THEN fr.Franchise_Name WHEN 'C' THEN co.Corporate_Name END END AS PartnerName
    INTO #R
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'LAB'
    INNER JOIN dbo.LabOrder lo      ON lo.LabOrderId = ph.ModuleRefId
    INNER JOIN dbo.PatientMaster p  ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    LEFT  JOIN dbo.Users u          ON u.Id = pd.CreatedBy
    LEFT  JOIN dbo.LabFranchiseMaster fr ON lo.AgentType = 'F' AND fr.Franchise_ID = lo.B2BAgentID
    LEFT  JOIN dbo.CorporateMaster co    ON lo.AgentType = 'C' AND co.Corporate_ID = lo.B2BAgentID
    WHERE pd.IsActive = 1
      AND ph.IsActive = 1
      -- 2255: B2C receipts, and B2B receipts paid directly on the bill. Not a partner's franchise-wallet deduction and not
      -- a settlement of partner credit (B2B Multi-Bill Settlement: its ledger entry names the receipt)
      AND (ISNULL(lo.IsB2B, 0) = 0
           OR (ISNULL(pd.TransactionRef, '') NOT LIKE 'WALLET-DEBIT-%'
               AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction lt
                               WHERE lt.ReferenceType = 'B2B_SETTLEMENT' AND lt.Narration LIKE '%Receipt: ' + pd.ReceiptNo + ')%')))
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND lo.BranchId = @BranchId
      AND pd.PaidAmount > 0
      AND pd.PaymentDate >= @From AND pd.PaymentDate < @To
      AND (@PaymentMethodId IS NULL OR pd.PaymentMethodId = @PaymentMethodId)
      AND (@CollectedBy IS NULL OR pd.CreatedBy = @CollectedBy)
      AND (@Search IS NULL
           OR pd.ReceiptNo  LIKE '%' + @Search + '%'
           OR lo.BillNo     LIKE '%' + @Search + '%'
           OR lo.TokenNo    LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%'
           OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName   LIKE '%' + @Search + '%'
           OR p.LastName    LIKE '%' + @Search + '%'
           OR fr.Franchise_Name LIKE '%' + @Search + '%'
           OR co.Corporate_Name LIKE '%' + @Search + '%');

    -- RS1: summary
    SELECT
        COUNT(1)                                        AS ReceiptCount,
        ISNULL(SUM(PaidAmount), 0)                      AS TotalCollection,
        COUNT(DISTINCT LabOrderId)                      AS BillCount,
        COUNT(DISTINCT PatientCode)                     AS PatientCount,
        CAST(CASE WHEN COUNT(1) > 0 THEN SUM(PaidAmount) / COUNT(1) ELSE 0 END AS DECIMAL(18, 2)) AS AvgPerReceipt,
        ISNULL(MAX(PaidAmount), 0)                      AS HighestReceipt,
        ISNULL(SUM(CASE WHEN IsBillActive = 0 THEN PaidAmount END), 0) AS CancelledBillCollection,
        SUM(CASE WHEN IsBillActive = 0 THEN 1 ELSE 0 END)              AS CancelledBillReceipts,
        ISNULL(SUM(CASE WHEN BillingType = 'B2C' THEN PaidAmount END), 0) AS B2CCollection,
        ISNULL(SUM(CASE WHEN BillingType = 'B2B' THEN PaidAmount END), 0) AS B2BCollection,
        SUM(CASE WHEN BillingType = 'B2C' THEN 1 ELSE 0 END)              AS B2CReceipts,
        SUM(CASE WHEN BillingType = 'B2B' THEN 1 ELSE 0 END)              AS B2BReceipts
    FROM #R;

    -- RS2: by payment mode
    SELECT PaymentMethodId, PaymentMode, COUNT(1) AS ReceiptCount, SUM(PaidAmount) AS Amount
    FROM #R GROUP BY PaymentMethodId, PaymentMode ORDER BY SUM(PaidAmount) DESC;

    -- RS3: by day
    SELECT CAST(ReceiptDate AS DATE) AS CollectionDate, COUNT(1) AS ReceiptCount, SUM(PaidAmount) AS Amount
    FROM #R GROUP BY CAST(ReceiptDate AS DATE) ORDER BY CollectionDate;

    -- RS4: by collector
    SELECT CollectedById, CollectedBy, COUNT(1) AS ReceiptCount, SUM(PaidAmount) AS Amount
    FROM #R GROUP BY CollectedById, CollectedBy ORDER BY SUM(PaidAmount) DESC;

    -- RS5: receipts
    SELECT * FROM #R ORDER BY ReceiptDate DESC, PaymentDetailId DESC;

    -- RS6: payment methods (filter list)
    SELECT PaymentMethodId, MethodName FROM dbo.PaymentMethodMaster WHERE IsActive = 1 ORDER BY DisplayOrder, MethodName;

    DROP TABLE #R;
END;
GO

UPDATE dbo.PageMaster SET Title = N'Daily Collection Register' WHERE Page_Code = 'REPORTS.LABB2CCOLLECTIONREGISTER';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2255 applied: Daily Collection Register (B2C + direct B2B receipts, billing type filter).';
GO
