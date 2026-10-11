-- ============================================================================
-- Migration: 2227_money_receipt_discount.sql
-- Description: Money Receipt (due collection, 2204) shows the bill's discount: gross amount, discount (% / fixed /
--   by department), round-off, net payable, reason and approver, and notes when the discount was given with this
--   receipt (e.g. 10% on the balance due at collection). The receipt amount and balance are unchanged.
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_MoneyReceipt_Get
    @ReceiptNo NVARCHAR(50),
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HeaderId INT, @FirstOn DATETIME, @Amount DECIMAL(18, 2), @ReceivedBy INT, @Bills INT;

    SELECT @HeaderId = MIN(pd.PaymentHeaderId), @FirstOn = MIN(pd.CreatedDate), @Amount = SUM(pd.PaidAmount),
           @ReceivedBy = MIN(pd.CreatedBy), @Bills = COUNT(DISTINCT pd.PaymentHeaderId)
    FROM dbo.PaymentDetail pd
    WHERE pd.ReceiptNo = @ReceiptNo AND pd.IsActive = 1;

    IF @HeaderId IS NULL
    BEGIN
        SELECT TOP 0 CAST(NULL AS NVARCHAR(50)) AS ReceiptNo;   -- not found
        RETURN;
    END;

    -- Paid on this bill before this receipt (other receipts only)
    DECLARE @PaidBefore DECIMAL(18, 2) =
        (SELECT ISNULL(SUM(pd.PaidAmount), 0) FROM dbo.PaymentDetail pd
         WHERE pd.PaymentHeaderId = @HeaderId AND pd.IsActive = 1
           AND ISNULL(pd.ReceiptNo, N'') <> @ReceiptNo AND pd.CreatedDate < @FirstOn);

    SELECT
        @ReceiptNo                                         AS ReceiptNo,
        @FirstOn                                           AS ReceiptOn,
        RTRIM(ph.ModuleCode)                               AS ModuleCode,
        ph.ModuleRefId,
        ph.BranchId,
        b.BranchName,
        COALESCE(lo.BillNo, os.OPDBillNo)                  AS BillNo,
        COALESCE(lo.OrderDate, os.VisitDate, ph.CreatedDate) AS BillDate,
        COALESCE(lo.TokenNo, os.TokenNo)                   AS TokenNo,
        p.PatientCode,
        LTRIM(RTRIM(REPLACE(ISNULL(p.FirstName, N'') + N' ' + ISNULL(p.MiddleName, N'') + N' ' + ISNULL(p.LastName, N''), N'  ', N' '))) AS PatientName,
        p.PhoneNumber                                      AS PatientPhone,
        p.Gender                                           AS PatientGender,
        ph.NetAmount,
        @PaidBefore                                        AS PaidBefore,
        @Amount                                            AS Amount,
        CASE WHEN ph.NetAmount - @PaidBefore - @Amount > 0 THEN ph.NetAmount - @PaidBefore - @Amount ELSE 0 END AS BalanceAfter,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS ReceivedByName,
        -- Due collection: the bill (PaymentHeader) was saved before this receipt. The first payment at billing is
        -- written within the same save, about a second after the header. A receipt spread over several bills is a
        -- B2B settlement, which has its own receipt (LabOrderBooking/PrintSettlementReceipt).
        CAST(CASE WHEN @Bills > 1 THEN 0 WHEN DATEDIFF(SECOND, ph.CreatedDate, @FirstOn) > 5 OR @PaidBefore > 0 THEN 1 ELSE 0 END AS BIT) AS IsDueCollection,
        @Bills                                             AS BillCount,
        -- the bill's discount (2227): gross, how much, how it was given, why and who approved it; and whether it was
        -- given with this receipt (the approval is saved in the same transaction as the receipt's payment rows)
        ph.SubTotal                                        AS GrossAmount,
        CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) >= ISNULL(ph.LineDiscountTotal, 0) THEN ISNULL(ph.HeaderDiscountAmount, 0) ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DiscountAmount,
        NULLIF(RTRIM(ph.HeaderDiscountType), '')          AS DiscountType,
        ph.HeaderDiscountValue                             AS DiscountValue,
        ISNULL(ph.RoundOffAmount, 0)                       AS RoundOffAmount,
        NULLIF(LTRIM(RTRIM(ph.DiscountReason)), N'')       AS DiscountReason,
        ISNULL(NULLIF(LTRIM(RTRIM(da.FullName)), N''), da.Username) AS DiscountApprovedByName,
        CAST(CASE WHEN ph.DiscountApprovedDate IS NOT NULL AND ABS(DATEDIFF(SECOND, ph.DiscountApprovedDate, @FirstOn)) <= 60 THEN 1 ELSE 0 END AS BIT) AS DiscountOnThisReceipt,
        CAST(CASE WHEN @BranchId IS NULL OR ph.BranchId = @BranchId THEN 1 ELSE 0 END AS BIT) AS BranchAllowed
    FROM dbo.PaymentHeader ph
    LEFT JOIN dbo.LabOrder lo           ON ph.ModuleCode = 'LAB' AND lo.LabOrderId = ph.ModuleRefId
    LEFT JOIN dbo.PatientOPDService os  ON ph.ModuleCode = 'OPD' AND os.OPDServiceId = ph.ModuleRefId
    LEFT JOIN dbo.PatientMaster p       ON p.PatientId = COALESCE(lo.PatientId, os.PatientId, ph.PatientId)
    LEFT JOIN dbo.Branchmaster b        ON b.BranchID = ph.BranchId
    LEFT JOIN dbo.Users u               ON u.Id = @ReceivedBy
    LEFT JOIN dbo.Users da              ON da.Id = ph.DiscountApprovedBy
    WHERE ph.PaymentHeaderId = @HeaderId;

    SELECT
        pm.MethodName,
        pm.MethodCode,
        pd.PaidAmount,
        NULLIF(LTRIM(RTRIM(pd.UPIRefNo)), N'')       AS UPIRefNo,
        NULLIF(LTRIM(RTRIM(pd.CardLast4)), '')       AS CardLast4,
        NULLIF(LTRIM(RTRIM(pd.ChequeNo)), N'')       AS ChequeNo,
        NULLIF(LTRIM(RTRIM(pd.BankName)), N'')       AS BankName,
        NULLIF(LTRIM(RTRIM(pd.TransactionRef)), N'') AS TransactionRef
    FROM dbo.PaymentDetail pd
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE pd.ReceiptNo = @ReceiptNo AND pd.IsActive = 1
    ORDER BY pd.PaymentDetailId;
END;
GO

PRINT 'Script 2227 applied: Money Receipt shows the bill discount.';
GO
