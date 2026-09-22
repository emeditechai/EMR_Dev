-- ============================================================================
-- Migration: 2119_lab_b2c_collection_register.sql
-- Description:
--   Reports > LAB > B2C Collection Register - every money receipt collected against a B2C lab bill
--   (dbo.PaymentDetail = one money receipt) within a date range, for the current branch.
--   Collection only: the amount actually received on each receipt (refunds are not netted here).
--   A receipt collected on a bill that was later cancelled is still listed (the money was received),
--   flagged with the bill's status.
--
--   dbo.usp_Api_LabReport_B2CCollectionRegister
--     RS1  summary          totals for the filtered receipts
--     RS2  by payment mode  receipts / amount per payment method
--     RS3  by day           receipts / amount per collection date
--     RS4  by collector     receipts / amount per user who collected
--     RS5  receipts         one row per money receipt
--     RS6  payment methods  active methods (filter list)
--   Filters: date range on the receipt date (inclusive), payment method, collected-by user, free-text search.
--
--   Visibility (enforced here, not only on the page):
--     * Administrator (or super admin): every user's receipts of the branch.
--     * Any other user: only the receipts they collected themselves (@CollectedBy is forced to @UserId).
--     * Branch: only @BranchId's bills, and the user must be mapped to that branch (dbo.UserBranches);
--       super admin is exempt from the mapping check.
-- ============================================================================

USE [Dev_EMR];
GO
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
    @IsSuperAdmin    BIT           = 0
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
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CollectedBy
    INTO #R
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'LAB'
    INNER JOIN dbo.LabOrder lo      ON lo.LabOrderId = ph.ModuleRefId
    INNER JOIN dbo.PatientMaster p  ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    LEFT  JOIN dbo.Users u          ON u.Id = pd.CreatedBy
    WHERE pd.IsActive = 1
      AND ph.IsActive = 1
      AND ISNULL(lo.IsB2B, 0) = 0
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
           OR p.LastName    LIKE '%' + @Search + '%');

    -- RS1: summary
    SELECT
        COUNT(1)                                        AS ReceiptCount,
        ISNULL(SUM(PaidAmount), 0)                      AS TotalCollection,
        COUNT(DISTINCT LabOrderId)                      AS BillCount,
        COUNT(DISTINCT PatientCode)                     AS PatientCount,
        CAST(CASE WHEN COUNT(1) > 0 THEN SUM(PaidAmount) / COUNT(1) ELSE 0 END AS DECIMAL(18, 2)) AS AvgPerReceipt,
        ISNULL(MAX(PaidAmount), 0)                      AS HighestReceipt,
        ISNULL(SUM(CASE WHEN IsBillActive = 0 THEN PaidAmount END), 0) AS CancelledBillCollection,
        SUM(CASE WHEN IsBillActive = 0 THEN 1 ELSE 0 END)              AS CancelledBillReceipts
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

PRINT 'Created dbo.usp_Api_LabReport_B2CCollectionRegister.';
GO
