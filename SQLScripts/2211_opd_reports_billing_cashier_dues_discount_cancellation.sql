-- ============================================================================
-- Migration: 2211_opd_reports_billing_cashier_dues_discount_cancellation.sql
-- Description: the first Reports > OPD registers from the OPD Reports Roadmap (Bill & payment stage), on the same
--   register pattern as the LAB reports: one procedure per report returning Summary / Groups / Rows / Options, run
--   through api/reports/opd/run/{report}, page on _LabReportShell + lab-report.js.
--     OR-17 OPD Daily Billing Register        usp_Api_OpdReport_BillingRegister     by bill date
--     OR-19 OPD Cashier Day-end Closing       usp_Api_OpdReport_CashierClosing      by receipt / refund date
--     OR-20 OPD Outstanding Dues & Ageing     usp_Api_OpdReport_OutstandingDues     by bill date, due now
--     OR-21 OPD Discount Register             usp_Api_OpdReport_DiscountRegister    by bill date
--     OR-22 OPD Cancellation & Refund         usp_Api_OpdReport_CancellationRefund  by cancellation date
--   A bill is a PatientOPDService row (OPDBillNo); its money is PaymentHeader / PaymentDetail with ModuleCode 'OPD'.
--   Due = net - paid, never below 0 (the stored BalanceDue is not updated after a cancellation). Visibility as the LAB
--   reports: branch first (usp_LabReport_CheckAccess), Administrator / super admin see every user's data, everyone else
--   only their own. Pages are added to Reports > OPD with their VIEW endpoints; no grant is seeded. Read-only.
-- ============================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ============================================================================
-- OR-17 OPD Daily Billing Register - OPD bills raised in the period (bill date = when the bill was saved), with
-- consulting / registration / other services, discount, GST, net, paid, due and payment status.
-- Own data: bills the user created.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_BillingRegister
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @PaymentStatus VARCHAR(10)   = NULL,   -- PAID / PARTIAL / UNPAID / CANCELLED
    @DoctorId      INT           = NULL,
    @CreatedBy     INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 SET @CreatedBy = @UserId;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @PaymentStatus = NULLIF(UPPER(LTRIM(RTRIM(@PaymentStatus))), '');

    SELECT
        s.OPDServiceId, s.OPDBillNo AS BillNo, s.TokenNo, s.CreatedDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(s.CreatedDate AS DATE), 23) AS BillDay,
        s.VisitDate, s.AppointmentTime, ISNULL(s.Status, 'Registered') AS VisitStatus,
        CAST(CASE WHEN s.ScheduleId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsBooked,
        p.PatientId, p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        s.ConsultingDoctorId AS DoctorId,
        ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'No doctor') AS DoctorName,
        sp.SpecialityName AS Speciality,
        itm.ItemCount, itm.ItemNames,
        CAST(ISNULL(itm.ConsultingAmount, 0) AS DECIMAL(18, 2)) AS ConsultingAmount,
        CAST(ISNULL(itm.RegistrationAmount, 0) AS DECIMAL(18, 2)) AS RegistrationAmount,
        CAST(ISNULL(itm.ServiceAmount, 0) AS DECIMAL(18, 2)) AS ServiceAmount,
        CAST(ISNULL(s.TotalAmount, 0) AS DECIMAL(18, 2)) AS GrossAmount,
        CAST(CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DECIMAL(18, 2)) AS DiscountAmount,
        CAST(ISNULL(ph.TotalCgstAmount, 0) + ISNULL(ph.TotalSgstAmount, 0) + ISNULL(ph.TotalIgstAmount, 0) AS DECIMAL(18, 2)) AS TaxAmount,
        CAST(ISNULL(ph.NetAmount, s.TotalAmount) AS DECIMAL(18, 2)) AS NetAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        CAST(CASE WHEN s.IsActive = 0 OR ISNULL(ph.NetAmount, s.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0
                  ELSE ISNULL(ph.NetAmount, s.TotalAmount) - ISNULL(ph.TotalPaid, 0) END AS DECIMAL(18, 2)) AS DueAmount,
        CASE WHEN s.IsActive = 0 THEN 'CANCELLED'
             WHEN ph.PaymentStatus = 'P' OR (ph.PaymentHeaderId IS NOT NULL AND ISNULL(ph.TotalPaid, 0) >= ISNULL(ph.NetAmount, s.TotalAmount)) THEN 'PAID'
             WHEN ISNULL(ph.TotalPaid, 0) > 0 THEN 'PARTIAL'
             ELSE 'UNPAID' END AS PaymentStatus,
        CAST(CASE WHEN s.IsActive = 0 THEN 1 ELSE 0 END AS BIT) AS IsCancelled,
        CAST(ISNULL(canc.CancelledAmount, 0) AS DECIMAL(18, 2)) AS CancelledAmount,
        s.CreatedBy AS CreatedById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CreatedBy
    INTO #R
    FROM dbo.PatientOPDService s
    INNER JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    LEFT  JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    LEFT  JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    LEFT  JOIN dbo.Users u ON u.Id = s.CreatedBy
    OUTER APPLY (SELECT COUNT(1) AS ItemCount,
                        STRING_AGG(CAST(ISNULL(sm.ItemName, si.ServiceType) AS NVARCHAR(MAX)), ', ') AS ItemNames,
                        SUM(CASE WHEN si.ServiceType = 'Consulting' THEN si.ServiceCharges ELSE 0 END) AS ConsultingAmount,
                        SUM(CASE WHEN si.ServiceType <> 'Consulting' AND ISNULL(sm.IsRegistration, 0) = 1 THEN si.ServiceCharges ELSE 0 END) AS RegistrationAmount,
                        SUM(CASE WHEN si.ServiceType <> 'Consulting' AND ISNULL(sm.IsRegistration, 0) = 0 THEN si.ServiceCharges ELSE 0 END) AS ServiceAmount
                   FROM dbo.PatientOPDServiceItem si
                   LEFT JOIN dbo.ServiceMaster sm ON sm.ServiceId = si.ServiceId
                  WHERE si.OPDServiceId = s.OPDServiceId AND (si.IsActive = 1 OR s.IsActive = 0)) itm
    OUTER APPLY (SELECT SUM(bc.CancelledAmount) AS CancelledAmount FROM dbo.BillCancellation bc
                  WHERE bc.ModuleCode = 'OPD' AND bc.ModuleRefId = s.OPDServiceId AND bc.IsActive = 1) canc
    WHERE s.BranchId = @BranchId
      AND s.CreatedDate >= @From AND s.CreatedDate < @To
      AND (@DoctorId IS NULL OR s.ConsultingDoctorId = @DoctorId)
      AND (@CreatedBy IS NULL OR s.CreatedBy = @CreatedBy)
      AND (@Search IS NULL OR s.OPDBillNo LIKE '%' + @Search + '%' OR s.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%');

    IF @PaymentStatus IS NOT NULL DELETE FROM #R WHERE PaymentStatus <> @PaymentStatus;

    -- RS1 summary
    SELECT COUNT(1) AS BillCount,
           SUM(CASE WHEN IsCancelled = 0 THEN 1 ELSE 0 END) AS ActiveBills,
           SUM(CASE WHEN IsCancelled = 1 THEN 1 ELSE 0 END) AS CancelledBills,
           COUNT(DISTINCT PatientId) AS PatientCount,
           COUNT(DISTINCT DoctorId) AS DoctorCount,
           ISNULL(SUM(ItemCount), 0) AS ItemCount,
           ISNULL(SUM(ConsultingAmount), 0) AS ConsultingAmount, ISNULL(SUM(RegistrationAmount), 0) AS RegistrationAmount,
           ISNULL(SUM(ServiceAmount), 0) AS ServiceAmount,
           ISNULL(SUM(GrossAmount), 0) AS GrossAmount, ISNULL(SUM(DiscountAmount), 0) AS DiscountAmount, ISNULL(SUM(TaxAmount), 0) AS TaxAmount,
           ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount, ISNULL(SUM(DueAmount), 0) AS DueAmount,
           SUM(CASE WHEN DueAmount > 0 THEN 1 ELSE 0 END) AS DueBills
    FROM #R;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byDate' AS GroupKey, NULL AS GroupId, BillDay AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'byDoctor', DoctorId, DoctorName, 0, * FROM #R
        UNION ALL SELECT 'byPaymentStatus', NULL, PaymentStatus, CASE PaymentStatus WHEN 'PAID' THEN 1 WHEN 'PARTIAL' THEN 2 WHEN 'UNPAID' THEN 3 ELSE 4 END, * FROM #R
        UNION ALL SELECT 'byCreatedBy', CreatedById, CreatedBy, 0, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS BillCount, SUM(ConsultingAmount) AS ConsultingAmount, SUM(RegistrationAmount) AS RegistrationAmount,
           SUM(ServiceAmount) AS ServiceAmount, SUM(GrossAmount) AS GrossAmount, SUM(DiscountAmount) AS DiscountAmount,
           SUM(TaxAmount) AS TaxAmount, SUM(NetAmount) AS NetAmount, SUM(PaidAmount) AS PaidAmount, SUM(DueAmount) AS DueAmount
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey = 'byDate' THEN GroupName END DESC, SUM(NetAmount) DESC, GroupName;

    -- RS3 rows
    SELECT * FROM #R ORDER BY BillDate DESC, OPDServiceId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(CreatedById AS VARCHAR(20)) AS Value, CreatedBy AS Text FROM #R WHERE CreatedById IS NOT NULL
    UNION
    SELECT DISTINCT 'doctorId', CAST(DoctorId AS VARCHAR(20)), DoctorName FROM #R WHERE DoctorId IS NOT NULL;

    DROP TABLE #R;
END;
GO

-- ============================================================================
-- OR-19 OPD Cashier Day-end Closing - what each cashier collected for OPD bills, by payment mode, less OPD refunds
-- paid out. Money in: OPD money receipts taken at the branch, by receipt date. Refunds: OPD refunds, by refund date
-- and mode. Net cash to hand over = cash received - cash refunded. Own data: their own collections and refunds.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_CashierClosing
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
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @OwnOnly = 1 SET @CollectedBy = @UserId;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');

    CREATE TABLE #E (
        EntryType    VARCHAR(10),       -- RECEIPT / REFUND
        EntryOn      DATETIME,
        ReceiptNo    NVARCHAR(50),
        OPDServiceId INT NULL,
        BillNo       NVARCHAR(50) NULL,
        PartyName    NVARCHAR(250) NULL,
        PartyCode    NVARCHAR(50) NULL,
        DoctorName   NVARCHAR(250) NULL,
        MethodId     INT NULL,
        ModeName     NVARCHAR(100),
        Bucket       VARCHAR(10),       -- CASH / UPI / CARD / BANK / OTHER
        Reference    NVARCHAR(200) NULL,
        Received     DECIMAL(18, 2),
        Refunded     DECIMAL(18, 2),
        CashierId    INT NULL);

    -- OPD money receipts taken at the branch
    INSERT INTO #E
    SELECT 'RECEIPT', COALESCE(pd.PaymentDate, pd.CreatedDate), pd.ReceiptNo, s.OPDServiceId, s.OPDBillNo,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))), p.PatientCode,
           NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''),
           pd.PaymentMethodId, ISNULL(pm.MethodName, 'Unknown'),
           CASE WHEN pm.MethodCode = 'CASH' THEN 'CASH' WHEN pm.MethodCode = 'UPI' THEN 'UPI' WHEN pm.MethodCode = 'CARD' THEN 'CARD'
                WHEN pm.MethodCode IN ('NEFT', 'CHEQUE') THEN 'BANK' ELSE 'OTHER' END,
           NULLIF(LTRIM(RTRIM(COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.ChequeNo, ''),
                                       CASE WHEN NULLIF(pd.CardLast4, '') IS NOT NULL THEN 'Card xx' + pd.CardLast4 END, pd.TransactionRef, ''))), ''),
           pd.PaidAmount, 0, pd.CreatedBy
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'OPD' AND ph.IsActive = 1
    INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = ph.ModuleRefId
    LEFT  JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    LEFT  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE pd.IsActive = 1 AND ph.BranchId = @BranchId   -- the branch where the money was taken
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @From AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @To;

    -- OPD refunds paid out
    INSERT INTO #E
    SELECT 'REFUND', r.RefundDate, bc.CancellationNo, s.OPDServiceId, s.OPDBillNo,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))), p.PatientCode,
           NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''),
           NULL, ISNULL(NULLIF(r.RefundMode, ''), 'Not recorded'),
           CASE WHEN r.RefundMode LIKE '%cash%' THEN 'CASH' WHEN r.RefundMode LIKE '%upi%' THEN 'UPI' WHEN r.RefundMode LIKE '%card%' THEN 'CARD'
                WHEN r.RefundMode LIKE '%neft%' OR r.RefundMode LIKE '%rtgs%' OR r.RefundMode LIKE '%bank%' OR r.RefundMode LIKE '%cheque%' THEN 'BANK'
                ELSE 'OTHER' END,
           NULLIF(LTRIM(RTRIM(r.TransactionRef)), ''), 0, r.RefundAmount, r.CreatedBy
    FROM dbo.BillRefund r
    INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = r.ModuleRefId
    LEFT  JOIN dbo.BillCancellation bc ON bc.CancellationId = r.CancellationId
    LEFT  JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    WHERE r.ModuleCode = 'OPD' AND r.IsActive = 1 AND ISNULL(r.Status, 'P') = 'P' AND s.BranchId = @BranchId
      AND r.RefundDate >= @From AND r.RefundDate < @To;

    DELETE FROM #E
    WHERE (@CollectedBy IS NOT NULL AND ISNULL(CashierId, -1) <> @CollectedBy)
       OR (@PaymentMethodId IS NOT NULL AND ISNULL(MethodId, -1) <> @PaymentMethodId)
       OR (@Search IS NOT NULL AND NOT (ISNULL(ReceiptNo, '') LIKE '%' + @Search + '%' OR ISNULL(BillNo, '') LIKE '%' + @Search + '%'
                                       OR ISNULL(PartyName, '') LIKE '%' + @Search + '%' OR ISNULL(PartyCode, '') LIKE '%' + @Search + '%'
                                       OR ISNULL(Reference, '') LIKE '%' + @Search + '%'));

    SELECT e.*, CONVERT(VARCHAR(10), CAST(e.EntryOn AS DATE), 23) AS EntryDay,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'Not recorded')) AS Cashier
    INTO #R
    FROM #E e LEFT JOIN dbo.Users u ON u.Id = e.CashierId;
    ALTER TABLE #R ADD CashierDay NVARCHAR(300);
    UPDATE #R SET CashierDay = Cashier + N' · ' + FORMAT(CAST(EntryOn AS DATE), 'dd MMM yyyy');

    -- RS1 summary
    SELECT SUM(CASE WHEN EntryType = 'RECEIPT' THEN 1 ELSE 0 END) AS Receipts,
           ISNULL(SUM(Received), 0) AS TotalReceived,
           ISNULL(SUM(CASE WHEN Bucket = 'CASH' THEN Received END), 0) AS Cash,
           ISNULL(SUM(CASE WHEN Bucket = 'UPI' THEN Received END), 0) AS Upi,
           ISNULL(SUM(CASE WHEN Bucket = 'CARD' THEN Received END), 0) AS Card,
           ISNULL(SUM(CASE WHEN Bucket = 'BANK' THEN Received END), 0) AS Bank,
           ISNULL(SUM(CASE WHEN Bucket = 'OTHER' THEN Received END), 0) AS Other,
           ISNULL(SUM(Refunded), 0) AS Refunds,
           ISNULL(SUM(CASE WHEN Bucket = 'CASH' THEN Refunded END), 0) AS CashRefunds,
           SUM(CASE WHEN EntryType = 'REFUND' THEN 1 ELSE 0 END) AS RefundCount,
           ISNULL(SUM(CASE WHEN Bucket = 'CASH' THEN Received - Refunded END), 0) AS NetCash,
           ISNULL(SUM(Received - Refunded), 0) AS NetTotal,
           COUNT(DISTINCT CashierId) AS Cashiers,
           MIN(CASE WHEN EntryType = 'RECEIPT' THEN ReceiptNo END) AS FirstReceiptNo,
           MAX(CASE WHEN EntryType = 'RECEIPT' THEN ReceiptNo END) AS LastReceiptNo
    FROM #R;

    -- RS2 groups: per cashier (the hand-over), cashier x day, payment mode, day
    ;WITH g AS (
        SELECT 'byCashier' AS GroupKey, CashierId AS GroupId, Cashier AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'byCashierDay', CashierId, CashierDay, DATEDIFF(DAY, '2000-01-01', EntryOn), * FROM #R
        UNION ALL SELECT 'byMode', NULL, ModeName, CASE Bucket WHEN 'CASH' THEN 1 WHEN 'UPI' THEN 2 WHEN 'CARD' THEN 3 WHEN 'BANK' THEN 4 ELSE 5 END, * FROM #R
        UNION ALL SELECT 'byDate', NULL, EntryDay, 0, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           SUM(CASE WHEN EntryType = 'RECEIPT' THEN 1 ELSE 0 END) AS Receipts,
           ISNULL(SUM(CASE WHEN Bucket = 'CASH' THEN Received END), 0) AS Cash,
           ISNULL(SUM(CASE WHEN Bucket = 'UPI' THEN Received END), 0) AS Upi,
           ISNULL(SUM(CASE WHEN Bucket = 'CARD' THEN Received END), 0) AS Card,
           ISNULL(SUM(CASE WHEN Bucket = 'BANK' THEN Received END), 0) AS Bank,
           ISNULL(SUM(CASE WHEN Bucket = 'OTHER' THEN Received END), 0) AS Other,
           ISNULL(SUM(Received), 0) AS TotalReceived,
           ISNULL(SUM(Refunded), 0) AS Refunds,
           ISNULL(SUM(CASE WHEN Bucket = 'CASH' THEN Received - Refunded END), 0) AS NetCash,
           CASE WHEN MIN(CASE WHEN EntryType = 'RECEIPT' THEN ReceiptNo END) IS NULL THEN NULL
                WHEN MIN(CASE WHEN EntryType = 'RECEIPT' THEN ReceiptNo END) = MAX(CASE WHEN EntryType = 'RECEIPT' THEN ReceiptNo END)
                    THEN MIN(CASE WHEN EntryType = 'RECEIPT' THEN ReceiptNo END)
                ELSE MIN(CASE WHEN EntryType = 'RECEIPT' THEN ReceiptNo END) + N' – ' + MAX(CASE WHEN EntryType = 'RECEIPT' THEN ReceiptNo END) END AS ReceiptRange
    FROM g
    GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey = 'byDate' THEN GroupName END DESC, SUM(Received) DESC, GroupName;

    -- RS3 rows: in time order (the cashier's day as it happened)
    SELECT * FROM #R ORDER BY EntryOn, ReceiptNo;

    -- RS4 filter options
    SELECT 'paymentMethodId' AS FilterKey, CAST(PaymentMethodId AS VARCHAR(20)) AS Value, MethodName AS Text
    FROM dbo.PaymentMethodMaster WHERE IsActive = 1
    UNION
    SELECT DISTINCT 'collectedBy', CAST(CashierId AS VARCHAR(20)), Cashier FROM #R WHERE CashierId IS NOT NULL;

    DROP TABLE #R; DROP TABLE #E;
END;
GO

-- ============================================================================
-- OR-20 OPD Outstanding Dues & Ageing - active OPD bills that still have a balance (bill date in the period).
-- Age = days since the bill; buckets 0-2 / 3-7 / 8-30 / 30+ days. Shows whether the patient has already been seen
-- (the visit is Consulting / Completed). Own data: bills the user created.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_OutstandingDues
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @AgeBucket     VARCHAR(10)   = NULL,   -- 0-2 / 3-7 / 8-30 / 30+
    @DoctorId      INT           = NULL,
    @CreatedBy     INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 SET @CreatedBy = @UserId;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @AgeBucket = NULLIF(LTRIM(RTRIM(@AgeBucket)), '');

    SELECT
        s.OPDServiceId, s.OPDBillNo AS BillNo, s.TokenNo, s.CreatedDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(s.CreatedDate AS DATE), 23) AS BillDay,
        DATEDIFF(DAY, s.CreatedDate, GETDATE()) AS AgeDays,
        CASE WHEN DATEDIFF(DAY, s.CreatedDate, GETDATE()) <= 2 THEN '0-2'
             WHEN DATEDIFF(DAY, s.CreatedDate, GETDATE()) <= 7 THEN '3-7'
             WHEN DATEDIFF(DAY, s.CreatedDate, GETDATE()) <= 30 THEN '8-30'
             ELSE '30+' END AS AgeBucket,
        p.PatientId, p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        s.ConsultingDoctorId AS DoctorId,
        ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'No doctor') AS DoctorName,
        ISNULL(s.Status, 'Registered') AS VisitStatus,
        CAST(CASE WHEN s.Status IN ('Consulting', 'Completed') THEN 1 ELSE 0 END AS BIT) AS SeenByDoctor,
        CAST(CASE WHEN ph.PaymentHeaderId IS NULL THEN 1 ELSE 0 END AS BIT) AS PaymentNotStarted,
        CAST(ISNULL(ph.NetAmount, s.TotalAmount) AS DECIMAL(18, 2)) AS NetAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        CAST(ISNULL(ph.NetAmount, s.TotalAmount) - ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS DueAmount,
        pay.LastPaymentDate,
        s.CreatedBy AS CreatedById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CreatedBy
    INTO #R
    FROM dbo.PatientOPDService s
    INNER JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    LEFT  JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    LEFT  JOIN dbo.Users u ON u.Id = s.CreatedBy
    OUTER APPLY (SELECT MAX(COALESCE(pd.PaymentDate, pd.CreatedDate)) AS LastPaymentDate FROM dbo.PaymentDetail pd
                  WHERE pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1) pay
    WHERE s.BranchId = @BranchId
      AND s.IsActive = 1
      AND s.CreatedDate >= @From AND s.CreatedDate < @To
      AND ISNULL(ph.NetAmount, s.TotalAmount) - ISNULL(ph.TotalPaid, 0) > 0
      AND (@DoctorId IS NULL OR s.ConsultingDoctorId = @DoctorId)
      AND (@CreatedBy IS NULL OR s.CreatedBy = @CreatedBy)
      AND (@Search IS NULL OR s.OPDBillNo LIKE '%' + @Search + '%' OR s.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%');

    IF @AgeBucket IS NOT NULL DELETE FROM #R WHERE AgeBucket <> @AgeBucket;

    -- RS1 summary
    SELECT COUNT(1) AS BillCount, COUNT(DISTINCT PatientId) AS PatientCount,
           ISNULL(SUM(DueAmount), 0) AS DueAmount, ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount,
           ISNULL(SUM(CASE WHEN AgeBucket = '0-2'  THEN DueAmount END), 0) AS Due0to2,
           ISNULL(SUM(CASE WHEN AgeBucket = '3-7'  THEN DueAmount END), 0) AS Due3to7,
           ISNULL(SUM(CASE WHEN AgeBucket = '8-30' THEN DueAmount END), 0) AS Due8to30,
           ISNULL(SUM(CASE WHEN AgeBucket = '30+'  THEN DueAmount END), 0) AS Due30Plus,
           SUM(CASE WHEN SeenByDoctor = 1 THEN 1 ELSE 0 END) AS SeenWithDue,
           ISNULL(SUM(CASE WHEN SeenByDoctor = 1 THEN DueAmount END), 0) AS SeenWithDueAmount,
           SUM(CASE WHEN PaymentNotStarted = 1 THEN 1 ELSE 0 END) AS NotBilledForPayment,
           ISNULL(MAX(AgeDays), 0) AS OldestDays
    FROM #R;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byAgeBucket' AS GroupKey, NULL AS GroupId, AgeBucket AS GroupName,
               CASE AgeBucket WHEN '0-2' THEN 1 WHEN '3-7' THEN 2 WHEN '8-30' THEN 3 ELSE 4 END AS SortOrder, * FROM #R
        UNION ALL SELECT 'byPatient', PatientId, PatientName + ' (' + ISNULL(PatientCode, '') + ')', 0, * FROM #R
        UNION ALL SELECT 'byDoctor', DoctorId, DoctorName, 0, * FROM #R
        UNION ALL SELECT 'byCreatedBy', CreatedById, CreatedBy, 0, * FROM #R
        UNION ALL SELECT 'byDate', NULL, BillDay, 0, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS BillCount, SUM(NetAmount) AS NetAmount, SUM(PaidAmount) AS PaidAmount, SUM(DueAmount) AS DueAmount, MAX(AgeDays) AS OldestDays
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey = 'byDate' THEN GroupName END DESC, SUM(DueAmount) DESC, GroupName;

    -- RS3 rows (oldest first: that is what gets followed up)
    SELECT * FROM #R ORDER BY AgeDays DESC, DueAmount DESC;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(CreatedById AS VARCHAR(20)) AS Value, CreatedBy AS Text FROM #R WHERE CreatedById IS NOT NULL
    UNION
    SELECT DISTINCT 'doctorId', CAST(DoctorId AS VARCHAR(20)), DoctorName FROM #R WHERE DoctorId IS NOT NULL;

    DROP TABLE #R;
END;
GO

-- ============================================================================
-- OR-21 OPD Discount Register - OPD bills of the period (bill date) that carry a discount: how much, why, who
-- approved it and who entered it; bills without a recorded reason flagged. Own data: discounts the user entered.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_DiscountRegister
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @ReasonStatus  VARCHAR(10)   = NULL,   -- RECORDED / MISSING
    @ApprovedBy    INT           = NULL,
    @DoctorId      INT           = NULL,
    @EnteredBy     INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 SET @EnteredBy = @UserId;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @ReasonStatus = NULLIF(UPPER(LTRIM(RTRIM(@ReasonStatus))), '');

    SELECT
        s.OPDServiceId, s.OPDBillNo AS BillNo, s.TokenNo, s.CreatedDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(s.CreatedDate AS DATE), 23) AS BillDay,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        s.ConsultingDoctorId AS DoctorId,
        ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'No doctor') AS DoctorName,
        CAST(ISNULL(ph.SubTotal, s.TotalAmount) AS DECIMAL(18, 2)) AS GrossAmount,
        ph.HeaderDiscountType AS DiscountType, ph.HeaderDiscountValue AS DiscountValue,
        CAST(CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DECIMAL(18, 2)) AS DiscountAmount,
        CAST(ISNULL(ph.NetAmount, 0) AS DECIMAL(18, 2)) AS NetAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        CAST(CASE WHEN ISNULL(ph.NetAmount, 0) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0 ELSE ISNULL(ph.NetAmount, 0) - ISNULL(ph.TotalPaid, 0) END AS DECIMAL(18, 2)) AS DueAmount,
        CAST(s.IsActive AS BIT) AS IsBillActive,
        NULLIF(LTRIM(RTRIM(ph.DiscountReason)), '') AS DiscountReason,
        ph.DiscountApprovedBy AS ApprovedById,
        ISNULL(NULLIF(LTRIM(RTRIM(ua.FullName)), ''), ua.Username) AS ApprovedBy,
        ph.DiscountApprovedDate AS ApprovedDate,
        COALESCE(ph.DiscountEnteredBy, ph.CreatedBy) AS EnteredById,
        ISNULL(NULLIF(LTRIM(RTRIM(ue.FullName)), ''), ISNULL(ue.Username, 'System')) AS EnteredBy
    INTO #R
    FROM dbo.PaymentHeader ph
    INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = ph.ModuleRefId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    LEFT  JOIN dbo.Users ua ON ua.Id = ph.DiscountApprovedBy
    LEFT  JOIN dbo.Users ue ON ue.Id = COALESCE(ph.DiscountEnteredBy, ph.CreatedBy)
    WHERE ph.ModuleCode = 'OPD' AND ph.IsActive = 1
      AND s.BranchId = @BranchId
      AND s.CreatedDate >= @From AND s.CreatedDate < @To
      AND (ISNULL(ph.HeaderDiscountAmount, 0) > 0 OR ISNULL(ph.LineDiscountTotal, 0) > 0)
      AND (@ApprovedBy IS NULL OR ph.DiscountApprovedBy = @ApprovedBy)
      AND (@DoctorId IS NULL OR s.ConsultingDoctorId = @DoctorId)
      AND (@EnteredBy IS NULL OR COALESCE(ph.DiscountEnteredBy, ph.CreatedBy) = @EnteredBy)
      AND (@Search IS NULL OR s.OPDBillNo LIKE '%' + @Search + '%' OR s.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR ph.DiscountReason LIKE '%' + @Search + '%');

    ALTER TABLE #R ADD DiscountPercent DECIMAL(9, 2), ReasonGroup NVARCHAR(500);
    UPDATE #R SET DiscountPercent = CASE WHEN GrossAmount > 0 THEN DiscountAmount * 100.0 / GrossAmount ELSE 0 END,
                  ReasonGroup = ISNULL(DiscountReason, 'Not recorded');
    IF @ReasonStatus = 'RECORDED' DELETE FROM #R WHERE DiscountReason IS NULL;
    IF @ReasonStatus = 'MISSING' DELETE FROM #R WHERE DiscountReason IS NOT NULL;

    -- RS1 summary
    SELECT COUNT(1) AS BillCount,
           ISNULL(SUM(DiscountAmount), 0) AS TotalDiscount,
           ISNULL(SUM(GrossAmount), 0) AS GrossOfDiscountedBills,
           CAST(CASE WHEN SUM(GrossAmount) > 0 THEN SUM(DiscountAmount) * 100.0 / SUM(GrossAmount) ELSE 0 END AS DECIMAL(9, 2)) AS DiscountPercent,
           ISNULL(MAX(DiscountAmount), 0) AS HighestDiscount,
           ISNULL(MAX(DiscountPercent), 0) AS HighestPercent,
           SUM(CASE WHEN DiscountReason IS NULL THEN 1 ELSE 0 END) AS WithoutReasonCount,
           ISNULL(SUM(CASE WHEN DiscountReason IS NULL THEN DiscountAmount END), 0) AS WithoutReasonAmount,
           SUM(CASE WHEN ApprovedById IS NULL THEN 1 ELSE 0 END) AS WithoutApproverCount
    FROM #R;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byApprover' AS GroupKey, ApprovedById AS GroupId, ISNULL(ApprovedBy, 'Not recorded') AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'byReason', NULL, ReasonGroup, 0, * FROM #R
        UNION ALL SELECT 'byDoctor', DoctorId, DoctorName, 0, * FROM #R
        UNION ALL SELECT 'byEnteredBy', EnteredById, EnteredBy, 0, * FROM #R
        UNION ALL SELECT 'byDate', NULL, BillDay, 0, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS BillCount, SUM(GrossAmount) AS GrossAmount, SUM(DiscountAmount) AS DiscountAmount,
           CAST(CASE WHEN SUM(GrossAmount) > 0 THEN SUM(DiscountAmount) * 100.0 / SUM(GrossAmount) ELSE 0 END AS DECIMAL(9, 2)) AS DiscountPercent,
           MAX(DiscountAmount) AS HighestDiscount
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey = 'byDate' THEN GroupName END DESC, SUM(DiscountAmount) DESC, GroupName;

    -- RS3 rows: latest bill first
    SELECT * FROM #R ORDER BY BillDate DESC, OPDServiceId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'approvedBy' AS FilterKey, CAST(ApprovedById AS VARCHAR(20)) AS Value, ApprovedBy AS Text FROM #R WHERE ApprovedById IS NOT NULL
    UNION
    SELECT DISTINCT 'enteredBy', CAST(EnteredById AS VARCHAR(20)), EnteredBy FROM #R WHERE EnteredById IS NOT NULL
    UNION
    SELECT DISTINCT 'doctorId', CAST(DoctorId AS VARCHAR(20)), DoctorName FROM #R WHERE DoctorId IS NOT NULL;

    DROP TABLE #R;
END;
GO

-- ============================================================================
-- OR-22 OPD Cancellation & Refund Register - OPD cancellations in the period (cancellation date) with the refund
-- made against each. Pending refund = what was paid on the cancelled part and not yet refunded (the bill's paid
-- amount is reduced by its refunds, so they are added back first). Own data: cancellations the user made, or refunds
-- the user processed.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_CancellationRefund
    @BranchId         INT,
    @FromDate         DATE,
    @ToDate           DATE,
    @CancellationType CHAR(1)       = NULL,   -- F / P
    @RefundStatus     VARCHAR(10)   = NULL,   -- REFUNDED / PENDING / NOTDUE
    @CancelledBy      INT           = NULL,
    @Search           NVARCHAR(100) = NULL,
    @UserId           INT           = NULL,
    @IsAdmin          BIT           = 0,
    @IsSuperAdmin     BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @RefundStatus = NULLIF(UPPER(LTRIM(RTRIM(@RefundStatus))), '');
    SET @CancellationType = NULLIF(UPPER(LTRIM(RTRIM(@CancellationType))), '');

    SELECT
        bc.CancellationId, bc.CancellationNo, bc.CancellationDate,
        CONVERT(VARCHAR(10), CAST(bc.CancellationDate AS DATE), 23) AS CancellationDay,
        CASE bc.CancellationType WHEN 'F' THEN 'Full' ELSE 'Partial' END AS CancellationType,
        s.OPDServiceId, s.OPDBillNo AS BillNo, s.CreatedDate AS BillDate,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'No doctor') AS DoctorName,
        itm.ItemCount, itm.ItemNames,
        CAST(bc.CancelledAmount AS DECIMAL(18, 2)) AS CancelledAmount,
        CAST(ISNULL(bc.DiscountAdjusted, 0) AS DECIMAL(18, 2)) AS DiscountAdjusted,
        CAST(bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) AS DECIMAL(18, 2)) AS NetCancelled,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidOnBill,
        CAST(ISNULL(rf.RefundedAmount, 0) AS DECIMAL(18, 2)) AS RefundedAmount,
        rf.RefundModes, rf.LastRefundDate, rf.RefundedBy,
        CAST(CASE WHEN (CASE WHEN bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) < ISNULL(ph.TotalPaid, 0) + ISNULL(rf.RefundedAmount, 0)
                             THEN bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) ELSE ISNULL(ph.TotalPaid, 0) + ISNULL(rf.RefundedAmount, 0) END) - ISNULL(rf.RefundedAmount, 0) > 0
                  THEN (CASE WHEN bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) < ISNULL(ph.TotalPaid, 0) + ISNULL(rf.RefundedAmount, 0)
                             THEN bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) ELSE ISNULL(ph.TotalPaid, 0) + ISNULL(rf.RefundedAmount, 0) END) - ISNULL(rf.RefundedAmount, 0)
                  ELSE 0 END AS DECIMAL(18, 2)) AS PendingRefund,
        NULLIF(LTRIM(RTRIM(bc.Reason)), '') AS Reason,
        bc.CreatedBy AS CancelledById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CancelledBy,
        rf.RefundUserIds
    INTO #R
    FROM dbo.BillCancellation bc
    INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = bc.ModuleRefId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    LEFT  JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    LEFT  JOIN dbo.Users u ON u.Id = bc.CreatedBy
    OUTER APPLY (SELECT COUNT(1) AS ItemCount,
                        STRING_AGG(CAST(ISNULL(sm.ItemName, si.ServiceType) AS NVARCHAR(MAX)), ', ') AS ItemNames
                   FROM dbo.BillCancellationItem bci
                   INNER JOIN dbo.PatientOPDServiceItem si ON si.ItemId = bci.LineRefId
                   LEFT  JOIN dbo.ServiceMaster sm ON sm.ServiceId = si.ServiceId
                  WHERE bci.CancellationId = bc.CancellationId AND bci.IsActive = 1) itm
    OUTER APPLY (SELECT SUM(r.RefundAmount) AS RefundedAmount,
                        STRING_AGG(CAST(r.RefundMode AS NVARCHAR(MAX)), ', ') AS RefundModes,
                        MAX(r.RefundDate) AS LastRefundDate,
                        STRING_AGG(CAST(ISNULL(NULLIF(LTRIM(RTRIM(ru.FullName)), ''), ru.Username) AS NVARCHAR(MAX)), ', ') AS RefundedBy,
                        ',' + STRING_AGG(CAST(r.CreatedBy AS VARCHAR(MAX)), ',') + ',' AS RefundUserIds
                   FROM dbo.BillRefund r
                   LEFT JOIN dbo.Users ru ON ru.Id = r.CreatedBy
                  WHERE r.CancellationId = bc.CancellationId AND r.IsActive = 1) rf
    WHERE bc.ModuleCode = 'OPD'
      AND bc.IsActive = 1
      AND s.BranchId = @BranchId
      AND bc.CancellationDate >= @From AND bc.CancellationDate < @To
      AND (@CancellationType IS NULL OR bc.CancellationType = @CancellationType)
      AND (@CancelledBy IS NULL OR bc.CreatedBy = @CancelledBy)
      AND (@Search IS NULL OR bc.CancellationNo LIKE '%' + @Search + '%' OR s.OPDBillNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR bc.Reason LIKE '%' + @Search + '%');

    -- own data: cancellations they made, or refunds they processed
    IF @OwnOnly = 1
        DELETE FROM #R WHERE ISNULL(CancelledById, 0) <> @UserId
                         AND ISNULL(RefundUserIds, '') NOT LIKE '%,' + CAST(@UserId AS VARCHAR(20)) + ',%';
    IF @RefundStatus = 'REFUNDED' DELETE FROM #R WHERE NOT (RefundedAmount > 0 AND PendingRefund = 0);
    IF @RefundStatus = 'PENDING'  DELETE FROM #R WHERE PendingRefund <= 0;
    IF @RefundStatus = 'NOTDUE'   DELETE FROM #R WHERE NOT (RefundedAmount = 0 AND PendingRefund = 0);

    -- RS1 summary
    SELECT COUNT(1) AS CancellationCount,
           SUM(CASE WHEN CancellationType = 'Full' THEN 1 ELSE 0 END) AS FullCount,
           SUM(CASE WHEN CancellationType = 'Partial' THEN 1 ELSE 0 END) AS PartialCount,
           COUNT(DISTINCT OPDServiceId) AS BillCount,
           ISNULL(SUM(ItemCount), 0) AS ItemCount,
           ISNULL(SUM(CancelledAmount), 0) AS CancelledAmount, ISNULL(SUM(NetCancelled), 0) AS NetCancelled,
           ISNULL(SUM(RefundedAmount), 0) AS RefundedAmount, ISNULL(SUM(PendingRefund), 0) AS PendingRefund,
           SUM(CASE WHEN PendingRefund > 0 THEN 1 ELSE 0 END) AS PendingRefundCount
    FROM #R;

    -- RS2 groups
    SELECT 'byReason' AS GroupKey, NULL AS GroupId, ISNULL(Reason, 'Not recorded') AS GroupName, 0 AS SortOrder,
           COUNT(1) AS CancellationCount, SUM(ItemCount) AS ItemCount, SUM(NetCancelled) AS NetCancelled,
           SUM(RefundedAmount) AS RefundedAmount, SUM(PendingRefund) AS PendingRefund
    FROM #R GROUP BY Reason
    UNION ALL
    SELECT 'byCancelledBy', CancelledById, CancelledBy, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancelledById, CancelledBy
    UNION ALL
    SELECT 'byType', NULL, CancellationType, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancellationType
    UNION ALL
    SELECT 'byDoctor', NULL, DoctorName, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY DoctorName
    UNION ALL
    SELECT 'byDate', NULL, CancellationDay, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancellationDay
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT CancellationId, CancellationNo, CancellationDate, CancellationDay, CancellationType, OPDServiceId, BillNo, BillDate,
           PatientCode, PatientName, PhoneNumber, DoctorName, ItemCount, ItemNames, CancelledAmount, DiscountAdjusted, NetCancelled,
           PaidOnBill, RefundedAmount, RefundModes, LastRefundDate, RefundedBy, PendingRefund,
           ISNULL(Reason, 'Not recorded') AS Reason, CancelledById, CancelledBy
    FROM #R ORDER BY CancellationDate DESC, CancellationId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'cancelledBy' AS FilterKey, CAST(CancelledById AS VARCHAR(20)) AS Value, CancelledBy AS Text FROM #R WHERE CancelledById IS NOT NULL;

    DROP TABLE #R;
END;
GO

-- ── menu pages and endpoints (database navigation, Reports > OPD) ───────────────
DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Action NVARCHAR(150), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
    (N'REPORTS.OPDBILLINGREGISTER',    N'OPD Daily Billing Register',      N'OpdBillingRegister',    11, N'bi bi-receipt me-2'),
    (N'REPORTS.OPDCASHIERCLOSING',     N'OPD Cashier Day-end Closing',     N'OpdCashierClosing',     12, N'bi bi-cash-coin me-2'),
    (N'REPORTS.OPDOUTSTANDINGDUES',    N'OPD Outstanding Dues & Ageing',   N'OpdOutstandingDues',    13, N'bi bi-hourglass-split me-2'),
    (N'REPORTS.OPDDISCOUNTREGISTER',   N'OPD Discount Register',           N'OpdDiscountRegister',   14, N'bi bi-percent me-2'),
    (N'REPORTS.OPDCANCELLATIONREFUND', N'OPD Cancellation & Refund',       N'OpdCancellationRefund', 15, N'bi bi-x-octagon me-2');

DECLARE @co INT, @menu INT, @page INT, @view INT, @code NVARCHAR(150), @title NVARCHAR(150), @action NVARCHAR(150), @sort INT, @icon NVARCHAR(100);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.OPD' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Action, Sort, Icon FROM @Pages;
        OPEN pc; FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title,
                 @Controller = N'Reports', @Action = @action, @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon,
                 @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
            SET @view = NULL;
            SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = @action, @Source = 'SEED';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = N'GetOpdReportData', @Source = 'SEED';
            FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        END
        CLOSE pc; DEALLOCATE pc;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2211 applied: Reports > OPD > OR-17, OR-19, OR-20, OR-21, OR-22.';
GO
