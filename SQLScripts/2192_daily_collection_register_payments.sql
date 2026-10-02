-- ============================================================================
-- Migration: 2192_daily_collection_register_payments.sql
-- Description: Reports > OPD > Daily Collection is a collection register built on payments only.
--   usp_Api_Report_DailyCollectionRegister returns one row per receipt (PaymentDetail) taken in the period, with
--   the bill it was taken against, and one row per refund paid out in the period (BillRefund, EntryType = 'REFUND').
--   * The period is the receipt's own date (PaymentDate, else CreatedDate) - not the bill date - and To Date is
--     included in full (it was compared as midnight, so that day's receipts were left out).
--   * A bill paid in parts is one row per receipt: bill amounts are no longer repeated / added up per receipt.
--   * Bills without any receipt are not in the register (they were, as Unpaid rows).
--   * LAB receipts carry the lab bill number (was empty); the column names match the report (Base / Discount /
--     GST / Pay Mode / Collected By were 0.00 / null because the names differed).
--   * @ModuleCode: 'OPD' | 'LAB' | NULL = all. Reports > OPD > Daily Collection always asks for 'OPD' (LAB has its own register).
--   Run after 2191.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_DailyCollectionRegister
    @CompanyId  INT = NULL,
    @BranchId   INT,
    @FromDate   DATETIME,
    @ToDate     DATETIME,
    @IsDetailed BIT = 0,            -- kept for existing callers: both views are built from the same receipt rows
    @ModuleCode VARCHAR(10) = NULL  -- 'OPD' | 'LAB' | NULL = all
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @From DATE = CAST(@FromDate AS DATE), @ToExcl DATE = DATEADD(DAY, 1, CAST(@ToDate AS DATE));

    -- receipts taken in the period
    SELECT
        'RECEIPT'                                              AS EntryType,
        pd.PaymentDetailId                                     AS EntryId,
        ph.PaymentHeaderId,
        COALESCE(pd.PaymentDate, pd.CreatedDate)               AS PaymentDate,
        pd.ReceiptNo,
        ph.ModuleCode,
        ph.ModuleRefId,
        COALESCE(pos.OPDBillNo, lo.BillNo, '')                 AS BillNo,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        CASE WHEN ph.ModuleCode = 'OPD' THEN ISNULL(d.NamePrefix + ' ', '') + d.FullName END AS DoctorName,
        ISNULL(ph.SubTotal, 0)                                 AS BillAmount,
        ISNULL(ph.LineDiscountTotal, 0)                        AS DiscountAmount,   -- holds the header discount too
        ISNULL(ph.TotalCgstAmount, 0) + ISNULL(ph.TotalSgstAmount, 0) + ISNULL(ph.TotalIgstAmount, 0) AS GstAmount,
        ISNULL(ph.NetAmount, 0)                                AS NetAmount,
        ISNULL(ph.BalanceDue, 0)                               AS BalanceDue,
        ph.PaymentStatus,
        ISNULL(pd.PaidAmount, 0)                               AS Amount,
        ISNULL(pm.MethodName, 'Unknown')                       AS PaymentMode,
        NULLIF(LTRIM(RTRIM(COALESCE(NULLIF(pd.TransactionRef, ''), NULLIF(pd.UPIRefNo, ''), NULLIF(pd.ChequeNo, ''),
                                    CASE WHEN pd.CardLast4 IS NOT NULL THEN 'Card ••' + pd.CardLast4 END))), '') AS Reference,
        COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username, 'System') AS CollectedBy
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.IsActive = 1
    INNER JOIN dbo.PatientMaster p ON p.PatientId = ph.PatientId
    LEFT  JOIN dbo.PatientOPDService pos ON ph.ModuleCode = 'OPD' AND pos.OPDServiceId = COALESCE(ph.OPDServiceId, ph.ModuleRefId)
    LEFT  JOIN dbo.DoctorMaster d ON d.DoctorId = pos.ConsultingDoctorId
    LEFT  JOIN dbo.LabOrder lo ON ph.ModuleCode = 'LAB' AND lo.LabOrderId = ph.ModuleRefId
    LEFT  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    LEFT  JOIN dbo.Users u ON u.Id = pd.CreatedBy
    WHERE pd.IsActive = 1
      AND ph.BranchId = @BranchId
      AND (@CompanyId IS NULL OR ph.CompanyId = @CompanyId)
      AND (@ModuleCode IS NULL OR ph.ModuleCode = @ModuleCode)
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @From
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) <  @ToExcl

    UNION ALL

    -- refunds paid out in the period (money going back - reported apart, never mixed into the receipts)
    SELECT
        'REFUND', r.RefundId, ph.PaymentHeaderId, r.RefundDate, NULL, r.ModuleCode, r.ModuleRefId,
        COALESCE(pos.OPDBillNo, lo.BillNo, ''),
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, ''))),
        p.PhoneNumber, NULL,
        ISNULL(ph.SubTotal, 0), ISNULL(ph.LineDiscountTotal, 0),
        ISNULL(ph.TotalCgstAmount, 0) + ISNULL(ph.TotalSgstAmount, 0) + ISNULL(ph.TotalIgstAmount, 0),
        ISNULL(ph.NetAmount, 0), ISNULL(ph.BalanceDue, 0), ph.PaymentStatus,
        ISNULL(r.RefundAmount, 0),
        ISNULL(NULLIF(LTRIM(RTRIM(r.RefundMode)), ''), 'Unknown'),
        NULLIF(LTRIM(RTRIM(r.TransactionRef)), ''),
        COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username, 'System')
    FROM dbo.BillRefund r
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = r.ModuleCode AND ph.ModuleRefId = r.ModuleRefId AND ph.IsActive = 1
    LEFT  JOIN dbo.PatientOPDService pos ON r.ModuleCode = 'OPD' AND pos.OPDServiceId = r.ModuleRefId
    LEFT  JOIN dbo.LabOrder lo ON r.ModuleCode = 'LAB' AND lo.LabOrderId = r.ModuleRefId
    LEFT  JOIN dbo.PatientMaster p ON p.PatientId = COALESCE(ph.PatientId, pos.PatientId, lo.PatientId)
    LEFT  JOIN dbo.Users u ON u.Id = r.CreatedBy
    WHERE r.IsActive = 1
      AND ISNULL(r.Status, 'P') = 'P'
      AND COALESCE(ph.BranchId, pos.BranchId, lo.BranchId) = @BranchId
      AND (@CompanyId IS NULL OR ph.CompanyId IS NULL OR ph.CompanyId = @CompanyId)
      AND (@ModuleCode IS NULL OR r.ModuleCode = @ModuleCode)
      AND r.RefundDate >= @From
      AND r.RefundDate <  @ToExcl

    ORDER BY PaymentDate, EntryId;
END
GO
