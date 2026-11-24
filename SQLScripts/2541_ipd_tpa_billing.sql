-- ============================================================================================================
-- Migration: 2541_ipd_tpa_billing.sql (after 2539, 2540; run it LAST of the IPD billing scripts - it replaces objects
-- of 2423 / 2434 / 2479 / 2493 / 2534 with their live definitions plus the payer split; re-run 2541 after any of those)
-- IPD Phase 6: the insurance / TPA share of the bill.
--   * Final bill (usp_Api_IpdBill_Finalise): for an insurance admission with an approved pre-auth, PayerShare =
--     (net - non-payables - deductible) less co-pay, capped at the approved / final authorised amount; the advance is
--     adjusted against the patient's share only; a claim is made (usp_Ipd_ClaimCreate). Refused while the pre-auth
--     waits for the TPA. No approval -> the patient pays the bill (reimbursement), as before.
--   * Ledger (usp_Ipd_PostLedger BILL): Dr Patient Receivable (patient share) + Dr <TPA> receivable (payer share).
--   * Bill cancel: an unsubmitted claim is cancelled with the bill; a submitted / settled claim blocks it.
--   * Everything that shows "balance due / refund due" uses the patient's part (fn_Ipd_PayerShare): banner, live
--     estimate, bill preview / print / list, settlement, refund, dashboard, bed board, due list, admission list.
--   Cash / corporate / scheme admissions and existing bills are unchanged (payer share 0).
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── fn_Ipd_SettleCalc ──
-- the settlement figures (one place for the preview and the save)
CREATE OR ALTER FUNCTION dbo.fn_Ipd_SettleCalc (@AdmissionId INT, @DiscType CHAR(1), @DiscValue DECIMAL(18,2), @RoundOff BIT)
RETURNS TABLE
AS RETURN
(
    SELECT x.BillId, x.Due, x.Disc, CAST(x.Due - x.Disc AS DECIMAL(18,2)) AS AfterDisc,
           CAST(CASE WHEN ISNULL(@RoundOff, 0) = 1 THEN (x.Due - x.Disc) - FLOOR(x.Due - x.Disc) ELSE 0 END AS DECIMAL(18,2)) AS RoundOff,
           CAST((x.Due - x.Disc) - CASE WHEN ISNULL(@RoundOff, 0) = 1 THEN (x.Due - x.Disc) - FLOOR(x.Due - x.Disc) ELSE 0 END AS DECIMAL(18,2)) AS Payable
    FROM (SELECT a.BillId, d.Due,
                 CAST(CASE WHEN d.Due <= 0 THEN 0
                           WHEN @DiscType = 'P' THEN ROUND(d.Due * CASE WHEN @DiscValue > 100 THEN 100 WHEN @DiscValue < 0 THEN 0 ELSE ISNULL(@DiscValue, 0) END / 100.0, 2)
                           WHEN @DiscType = 'A' THEN CASE WHEN ISNULL(@DiscValue, 0) < 0 THEN 0 WHEN @DiscValue > d.Due THEN d.Due ELSE ISNULL(@DiscValue, 0) END
                           ELSE 0 END AS DECIMAL(18,2)) AS Disc
          FROM dbo.IpdAdmission a
          CROSS APPLY (SELECT CAST(ISNULL((SELECT b.Net - b.PayerShare + b.PayerToPatient FROM dbo.IpdBill b WHERE b.BillId = a.BillId), 0) - (SELECT NetAdvance FROM dbo.fn_Ipd_Money(a.AdmissionId)) AS DECIMAL(18,2)) AS Due) d
          WHERE a.AdmissionId = @AdmissionId AND a.BillId IS NOT NULL) x
);
GO

-- ── usp_Api_IpdBill_Get ──
-- A bill for print: bill, admission header, lines, heads, money.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Get @CompanyId INT, @BillId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adm INT = (SELECT AdmissionId FROM dbo.IpdBill WHERE BillId = @BillId AND CompanyId = @CompanyId);
    IF @adm IS NULL RETURN;
    SELECT b.*, CAST((b.Net - b.PayerShare + b.PayerToPatient) AS DECIMAL(18,2)) AS PatientShare, CAST(b.PayerShare - b.PayerToPatient AS DECIMAL(18,2)) AS PayerShareNow,
           tpa.Name AS PayerName, pa.PreAuthNo, pa.TpaRefNo, cl.ClaimNo, u.FullName AS CreatedByName, uc.FullName AS CancelledByName, mo.NetAdvance AS AdvanceHeld, mo.AdvanceTotal, mo.RefundTotal, mo.SettleTotal,
           CAST(CASE WHEN b.Status = 'FINAL' AND (b.Net - b.PayerShare + b.PayerToPatient) - mo.NetAdvance > 0 THEN (b.Net - b.PayerShare + b.PayerToPatient) - mo.NetAdvance ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN b.Status = 'FINAL' AND mo.NetAdvance - (b.Net - b.PayerShare + b.PayerToPatient) > 0 THEN mo.NetAdvance - (b.Net - b.PayerShare + b.PayerToPatient) ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           s.HotelName AS HospitalName, s.Address AS HospitalAddress, s.ContactNumber1 AS HospitalPhone, s.EmailAddress AS HospitalEmail, s.GSTCode AS HospitalGstin
    FROM dbo.IpdBill b
    LEFT JOIN dbo.Users u ON u.Id = b.CreatedBy LEFT JOIN dbo.Users uc ON uc.Id = b.CancelledBy
    LEFT JOIN dbo.HospitalSettings s ON s.BranchID = b.BranchId
    LEFT JOIN dbo.InsuranceTPAMaster tpa ON tpa.InsuranceTPA_ID = b.InsuranceTpaId   -- 2541
    LEFT JOIN dbo.IpdPreAuth pa ON pa.PreAuthId = b.PreAuthId
    LEFT JOIN dbo.IpdClaim cl ON cl.BillId = b.BillId AND cl.IsLive = 1
    CROSS APPLY dbo.fn_Ipd_Money(b.AdmissionId) mo
    WHERE b.BillId = @BillId;
    SELECT h.*, pbm.BeneficiaryId /* 2534 */ FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @adm) h
    LEFT JOIN dbo.PatientMaster pbm ON pbm.PatientId = h.PatientId;
    SELECT l.*, hd.HeadName, hd.Sort AS HeadSort FROM dbo.IpdBillLine l LEFT JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head
    WHERE l.BillId = @BillId ORDER BY hd.Sort, l.ChargeAt, l.DayNo, l.Sort, l.BillLineId;
    SELECT hd.Head, hd.HeadName, hd.Sort, COUNT(*) AS Lines, SUM(l.Gross) AS Gross, SUM(l.ItemDiscount + l.BillDiscount) AS Discount, SUM(l.GstAmount) AS Gst, SUM(l.Net) AS Net
    FROM dbo.IpdBillLine l JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head WHERE l.BillId = @BillId GROUP BY hd.Head, hd.HeadName, hd.Sort ORDER BY hd.Sort;
    SELECT v.AdvanceId, v.Kind, v.Amount, v.DocNo, v.Mode, v.CreatedDate,
           (SELECT STRING_AGG(pm.MethodName, ', ') FROM dbo.PaymentDetail pd JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
            WHERE pd.PaymentHeaderId = v.PaymentHeaderId AND pd.IsActive = 1) AS Modes
    FROM dbo.IpdAdvance v WHERE v.AdmissionId = @adm AND v.IsActive = 1 ORDER BY v.CreatedDate, v.AdvanceId;
END;
GO

-- ── usp_Api_IpdBill_List ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_List @CompanyId INT, @BranchId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @Status VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @FromDate = ISNULL(@FromDate, DATEADD(DAY, -30, CAST(GETDATE() AS DATE))); SET @ToDate = ISNULL(@ToDate, CAST(GETDATE() AS DATE));
    SET @Status = NULLIF(@Status, ''); SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT b.BillId, b.BillNo, b.BillAt, b.BillUpToAt, b.Status, b.Gross, b.ItemDiscount + b.BillDiscount AS Discount, b.Gst, b.RoundOff, b.Net, b.AdvanceAdjusted, b.PayerShare, CAST((b.Net - b.PayerShare + b.PayerToPatient) AS DECIMAL(18,2)) AS PatientShare,
           a.AdmissionId, a.IpNo, a.PayerType, a.Status AS AdmissionStatus, p.PatientCode, p.PhoneNumber,
           LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, d.FullName AS ConsultantDoctorName,
           CAST(CASE WHEN b.Status = 'FINAL' AND (b.Net - b.PayerShare + b.PayerToPatient) - mo.NetAdvance > 0 THEN (b.Net - b.PayerShare + b.PayerToPatient) - mo.NetAdvance ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN b.Status = 'FINAL' AND mo.NetAdvance - (b.Net - b.PayerShare + b.PayerToPatient) > 0 THEN mo.NetAdvance - (b.Net - b.PayerShare + b.PayerToPatient) ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           u.FullName AS CreatedByName, b.CancelReason
    FROM dbo.IpdBill b
    JOIN dbo.IpdAdmission a ON a.AdmissionId = b.AdmissionId
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
    LEFT JOIN dbo.Users u ON u.Id = b.CreatedBy
    CROSS APPLY dbo.fn_Ipd_Money(a.AdmissionId) mo
    WHERE b.CompanyId = @CompanyId AND b.BranchId = @BranchId AND b.BillAt >= @FromDate AND b.BillAt < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME))
      AND (@Status IS NULL OR b.Status = @Status)
      AND (@Search IS NULL OR b.BillNo LIKE @like OR a.IpNo LIKE @like OR p.PatientCode LIKE @like OR p.PhoneNumber LIKE @like OR CONCAT(p.FirstName, ' ', p.LastName) LIKE @like)
    ORDER BY b.BillAt DESC, b.BillId DESC;
END;
GO

-- ── usp_Api_IpdBill_Preview ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Preview @CompanyId INT, @AdmissionId INT, @UpTo DATETIME = NULL, @DiscountType CHAR(1) = NULL, @DiscountValue DECIMAL(18,2) = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @admAt DATETIME, @bill INT;
    SELECT @admAt = AdmissionAt, @bill = BillId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND Status <> 'CANCELLED';
    IF @admAt IS NULL RETURN;
    SET @UpTo = ISNULL(@UpTo, GETDATE());
    CREATE TABLE #IpdBillCalc (LineKey NVARCHAR(40), Head VARCHAR(20), ChargeAt DATETIME, ItemCode NVARCHAR(50), ItemName NVARCHAR(250), Detail NVARCHAR(300), DoctorName NVARCHAR(150),
        Qty DECIMAL(18,3), Rate DECIMAL(18,2), Gross DECIMAL(18,2), ItemDiscount DECIMAL(18,2), BillDiscount DECIMAL(18,2), GstPercent DECIMAL(5,2), GstAmount DECIMAL(18,2),
        Net DECIMAL(18,2), SourceModule VARCHAR(10), SourceNo NVARCHAR(50), IsPackageItem BIT, NoTariff BIT, DayNo INT, Sort INT, ChargeId BIGINT);
    DECLARE @g DECIMAL(18,2), @id DECIMAL(18,2), @bd DECIMAL(18,2), @tx DECIMAL(18,2), @gst DECIMAL(18,2), @ro DECIMAL(18,2), @net DECIMAL(18,2), @nt BIT, @err NVARCHAR(400);
    BEGIN TRY
        IF @bill IS NULL
            EXEC dbo.usp_Ipd_BillCalc @AdmissionId = @AdmissionId, @UpTo = @UpTo, @DiscountType = @DiscountType, @DiscountValue = @DiscountValue,
                 @Gross = @g OUTPUT, @ItemDiscount = @id OUTPUT, @BillDiscount = @bd OUTPUT, @Taxable = @tx OUTPUT, @Gst = @gst OUTPUT, @RoundOff = @ro OUTPUT, @Net = @net OUTPUT, @NoTariff = @nt OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    IF @bill IS NOT NULL
        INSERT #IpdBillCalc (LineKey, Head, ChargeAt, ItemCode, ItemName, Detail, DoctorName, Qty, Rate, Gross, ItemDiscount, BillDiscount, GstPercent, GstAmount, Net,
                             SourceModule, SourceNo, IsPackageItem, NoTariff, DayNo, Sort, ChargeId)
        SELECT LineKey, Head, ChargeAt, ItemCode, ItemName, Detail, DoctorName, Qty, Rate, Gross, ItemDiscount, BillDiscount, GstPercent, GstAmount, Net,
               SourceModule, SourceNo, IsPackageItem, 0, DayNo, Sort, ChargeId FROM dbo.IpdBillLine WHERE BillId = @bill;
    IF @bill IS NOT NULL
        SELECT @g = Gross, @id = ItemDiscount, @bd = BillDiscount, @tx = Taxable, @gst = Gst, @ro = RoundOff, @net = Net, @nt = 0, @UpTo = BillUpToAt FROM dbo.IpdBill WHERE BillId = @bill;
    DECLARE @held DECIMAL(18,2) = (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId)), @adj DECIMAL(18,2);
    -- 2541: the TPA / insurance share (the bill's, or the live pre-auth's split of this preview)
    DECLARE @payer DECIMAL(18,2) = 0, @coPay DECIMAL(18,2) = 0, @auth DECIMAL(18,2) = NULL, @payerName NVARCHAR(200) = NULL, @paStatus VARCHAR(20) = NULL;
    IF @bill IS NOT NULL
        SELECT @payer = b.PayerShare - b.PayerToPatient, @coPay = b.CoPayAmount, @auth = CASE WHEN b.PayerAuthorised > 0 THEN b.PayerAuthorised END, @payerName = t.Name
        FROM dbo.IpdBill b LEFT JOIN dbo.InsuranceTPAMaster t ON t.InsuranceTPA_ID = b.InsuranceTpaId WHERE b.BillId = @bill;
    ELSE
        SELECT @payer = sp.PayerShare, @coPay = sp.CoPayAmount, @auth = pa.Authorised, @payerName = t.Name,
               @paStatus = (SELECT TOP 1 x.Status FROM dbo.IpdPreAuth x WHERE x.AdmissionId = @AdmissionId AND x.IsLive = 1)
        FROM dbo.IpdAdmission a
        LEFT JOIN dbo.IpdAdmissionPayer py ON py.AdmissionId = a.AdmissionId AND py.Seq = 1 AND py.PayerType = 'INSURANCE'
        LEFT JOIN dbo.InsuranceTPAMaster t ON t.InsuranceTPA_ID = py.InsuranceTpaId
        OUTER APPLY (SELECT TOP 1 Authorised, CoPayPercent, Deductible, NonPayable FROM dbo.fn_Ipd_PreAuthAuthorised(@AdmissionId)) pa
        OUTER APPLY dbo.fn_Ipd_PayerSplit(ISNULL(@net, 0), pa.Authorised, pa.CoPayPercent, pa.Deductible, pa.NonPayable) sp
        WHERE a.AdmissionId = @AdmissionId AND a.PayerType = 'INSURANCE';
    SET @payer = ISNULL(@payer, 0); SET @coPay = ISNULL(@coPay, 0);
    SET @adj = CASE WHEN @bill IS NOT NULL THEN (SELECT AdvanceAdjusted FROM dbo.IpdBill WHERE BillId = @bill) WHEN @held < ISNULL(@net, 0) - @payer THEN @held ELSE ISNULL(@net, 0) - @payer END;
    IF @adj < 0 SET @adj = 0;
    -- 1 totals
    SELECT @UpTo AS UpTo, @bill AS BillId, (SELECT BillNo FROM dbo.IpdBill WHERE BillId = @bill) AS BillNo, (SELECT BillAt FROM dbo.IpdBill WHERE BillId = @bill) AS BillAt, (SELECT SettleTotal FROM dbo.fn_Ipd_Money(@AdmissionId)) AS SettleTotal, ISNULL(@g, 0) AS Gross, ISNULL(@id, 0) AS ItemDiscount, ISNULL(@bd, 0) AS BillDiscount, ISNULL(@tx, 0) AS Taxable, ISNULL(@gst, 0) AS Gst,
           ISNULL(@ro, 0) AS RoundOff, ISNULL(@net, 0) AS Net, @held AS AdvanceHeld, @adj AS AdvanceAdjusted, @payer AS PayerShare, CAST(ISNULL(@net, 0) - @payer AS DECIMAL(18,2)) AS PatientShare,
           @coPay AS CoPayAmount, @auth AS PayerAuthorised, @payerName AS PayerName, @paStatus AS PreAuthStatus,
           CAST(CASE WHEN ISNULL(@net, 0) - @payer - @held > 0 THEN ISNULL(@net, 0) - @payer - @held ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN @held - (ISNULL(@net, 0) - @payer) > 0 THEN @held - (ISNULL(@net, 0) - @payer) ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           ISNULL(@nt, 0) AS NoTariff, @err AS Error,
           (SELECT COUNT(*) FROM #IpdBillCalc) AS Lines,
           (SELECT COUNT(*) FROM #IpdBillCalc WHERE IsPackageItem = 1) AS PackageLines;
    -- 2 heads
    SELECT hd.Head, hd.HeadName, hd.Sort, COUNT(l.Head) AS Lines, CAST(ISNULL(SUM(l.Gross), 0) AS DECIMAL(18,2)) AS Gross,
           CAST(ISNULL(SUM(l.ItemDiscount + l.BillDiscount), 0) AS DECIMAL(18,2)) AS Discount, CAST(ISNULL(SUM(l.GstAmount), 0) AS DECIMAL(18,2)) AS Gst,
           CAST(ISNULL(SUM(l.Net), 0) AS DECIMAL(18,2)) AS Net
    FROM dbo.fn_Ipd_Heads() hd LEFT JOIN #IpdBillCalc l ON l.Head = hd.Head
    WHERE hd.Head <> 'ADJUST'
    GROUP BY hd.Head, hd.HeadName, hd.Sort HAVING COUNT(l.Head) > 0 OR @bill IS NULL ORDER BY hd.Sort;
END;
GO

-- ── usp_Api_IpdBill_Finalise ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Finalise
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @UpTo DATETIME = NULL, @DiscountType CHAR(1) = NULL, @DiscountValue DECIMAL(18,2) = 0,
    @DiscountReason NVARCHAR(300) = NULL, @Remarks NVARCHAR(500) = NULL, @CanDiscount BIT = 0, @CanBackdate BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(600), @now DATETIME = GETDATE();
    CREATE TABLE #IpdBillCalc (LineKey NVARCHAR(40), Head VARCHAR(20), ChargeAt DATETIME, ItemCode NVARCHAR(50), ItemName NVARCHAR(250), Detail NVARCHAR(300), DoctorName NVARCHAR(150),
        Qty DECIMAL(18,3), Rate DECIMAL(18,2), Gross DECIMAL(18,2), ItemDiscount DECIMAL(18,2), BillDiscount DECIMAL(18,2), GstPercent DECIMAL(5,2), GstAmount DECIMAL(18,2),
        Net DECIMAL(18,2), SourceModule VARCHAR(10), SourceNo NVARCHAR(50), IsPackageItem BIT, NoTariff BIT, DayNo INT, Sort INT, ChargeId BIGINT);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @open BIT, @status VARCHAR(20), @bill INT, @admAt DATETIME, @ip NVARCHAR(40);
        SELECT @open = IsOpen, @status = Status, @bill = BillId, @admAt = AdmissionAt, @ip = IpNo FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 54951, 'The admission was not found in this branch.', 1;
        IF @bill IS NOT NULL THROW 54952, 'The final bill is already made.', 1;
        IF @open = 0 OR @status NOT IN ('ADMITTED', 'DISCHARGE_ADVISED') THROW 54953, 'The final bill can be made only for an admitted patient.', 1;
        SET @UpTo = ISNULL(@UpTo, @now);
        IF @UpTo > DATEADD(MINUTE, 5, @now) THROW 54954, 'The bill time cannot be in the future.', 1;
        IF @UpTo < DATEADD(MINUTE, -30, @now) AND ISNULL(@CanBackdate, 0) = 0 THROW 54955, 'You are not allowed to bill up to an earlier time (more than 30 minutes back).', 1;
        IF @UpTo < @admAt THROW 54956, 'The bill time cannot be before the admission.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdCharge WHERE AdmissionId = @AdmissionId AND Status = 'POSTED' AND ChargeAt > @UpTo)
            THROW 54957, 'Some charges are dated after the bill time: bill up to a later time or cancel them.', 1;
        SET @DiscountType = NULLIF(UPPER(@DiscountType), '');
        IF ISNULL(@DiscountValue, 0) > 0 AND @DiscountType IS NULL THROW 54958, 'Choose % or amount for the discount.', 1;
        IF ISNULL(@DiscountValue, 0) > 0 AND ISNULL(@CanDiscount, 0) = 0 THROW 54959, 'You are not allowed to give a discount on the bill.', 1;
        IF ISNULL(@DiscountValue, 0) > 0 AND NULLIF(LTRIM(RTRIM(@DiscountReason)), N'') IS NULL THROW 54960, 'Enter the reason for the discount.', 1;
        DECLARE @g DECIMAL(18,2), @id DECIMAL(18,2), @bd DECIMAL(18,2), @tx DECIMAL(18,2), @gst DECIMAL(18,2), @ro DECIMAL(18,2), @net DECIMAL(18,2), @nt BIT;
        EXEC dbo.usp_Ipd_BillCalc @AdmissionId = @AdmissionId, @UpTo = @UpTo, @DiscountType = @DiscountType, @DiscountValue = @DiscountValue,
             @Gross = @g OUTPUT, @ItemDiscount = @id OUTPUT, @BillDiscount = @bd OUTPUT, @Taxable = @tx OUTPUT, @Gst = @gst OUTPUT, @RoundOff = @ro OUTPUT, @Net = @net OUTPUT, @NoTariff = @nt OUTPUT;
        IF @nt = 1 THROW 54961, 'A bed day has no tariff (Master > IPD > Bed / Room Tariff): add the rate before the final bill.', 1;
        IF NOT EXISTS (SELECT 1 FROM #IpdBillCalc) THROW 54962, 'There is nothing to bill.', 1;
        DECLARE @held DECIMAL(18,2) = (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId));
        -- 2541: insurance / TPA split (approved / final authorised amount, co-pay, deductible, non-payables)
        DECLARE @payerType VARCHAR(12) = (SELECT PayerType FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId), @paId INT = NULL, @tpa INT = NULL,
                @auth DECIMAL(18,2) = 0, @copct DECIMAL(5,2) = 0, @ded DECIMAL(18,2) = 0, @np DECIMAL(18,2) = 0, @payer DECIMAL(18,2) = 0, @copay DECIMAL(18,2) = 0;
        IF @payerType = 'INSURANCE'
        BEGIN
            DECLARE @waiting VARCHAR(20) = (SELECT TOP 1 Status FROM dbo.IpdPreAuth WHERE AdmissionId = @AdmissionId AND IsLive = 1
                                            AND Status IN ('REQUESTED', 'QUERY', 'ENHANCE_REQUESTED', 'FINAL_REQUESTED'));
            IF @waiting IS NOT NULL THROW 54963, 'The pre-authorisation waits for the TPA (request / query / enhancement / final authorisation): record the TPA''s answer on the Insurance / TPA tab before the final bill.', 1;
            SELECT TOP 1 @paId = PreAuthId, @tpa = InsuranceTpaId, @auth = Authorised, @copct = CoPayPercent, @ded = Deductible, @np = NonPayable
            FROM dbo.fn_Ipd_PreAuthAuthorised(@AdmissionId);
            IF @paId IS NOT NULL SELECT @payer = PayerShare, @copay = CoPayAmount FROM dbo.fn_Ipd_PayerSplit(@net, @auth, @copct, @ded, @np);
            ELSE SELECT @auth = 0, @copct = 0, @ded = 0, @np = 0;   -- no cashless approval: the patient pays the bill (reimbursement claim)
            IF @tpa IS NULL SELECT TOP 1 @tpa = InsuranceTpaId FROM dbo.IpdAdmissionPayer WHERE AdmissionId = @AdmissionId AND PayerType = 'INSURANCE' ORDER BY Seq;
            IF @payer > 0 BEGIN DECLARE @tpaL INT; EXEC dbo.usp_Ipd_TpaLedger @InsuranceTpaId = @tpa, @LedgerId = @tpaL OUTPUT; END;
        END
        DECLARE @adj DECIMAL(18,2) = CASE WHEN @held < @net - @payer THEN @held ELSE @net - @payer END;
        IF @adj < 0 SET @adj = 0;
        DECLARE @no NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'IPB', @DocDate = @now, @DocNo = @no OUTPUT;
        INSERT dbo.IpdBill (CompanyId, BranchId, AdmissionId, BillNo, BillAt, BillUpToAt, Gross, ItemDiscount, BillDiscountType, BillDiscountValue, BillDiscount, DiscountReason,
               Taxable, Gst, RoundOff, Net, AdvanceAdjusted, PrevStatus, Status, Remarks, CreatedBy,
               InsuranceTpaId, PreAuthId, PayerAuthorised, CoPayPercent, CoPayAmount, Deductible, NonPayable, PayerShare)
        VALUES (@CompanyId, @BranchId, @AdmissionId, @no, @now, @UpTo, @g, @id, CASE WHEN @bd > 0 THEN @DiscountType END, CASE WHEN @bd > 0 THEN @DiscountValue ELSE 0 END, @bd,
                CASE WHEN @bd > 0 THEN LTRIM(RTRIM(@DiscountReason)) END, @tx, @gst, @ro, @net, @adj, @status, 'FINAL', NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId,
                @tpa, @paId, ISNULL(@auth, 0), ISNULL(@copct, 0), ISNULL(@copay, 0), ISNULL(@ded, 0), ISNULL(@np, 0), ISNULL(@payer, 0));
        DECLARE @billId INT = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.IpdBillLine (BillId, LineKey, Head, ChargeAt, ItemCode, ItemName, Detail, DoctorName, Qty, Rate, Gross, ItemDiscount, BillDiscount, GstPercent, GstAmount, Net,
               SourceModule, SourceNo, IsPackageItem, DayNo, Sort, ChargeId)
        SELECT @billId, LineKey, Head, ChargeAt, ItemCode, ItemName, Detail, DoctorName, Qty, Rate, Gross, ItemDiscount, BillDiscount, GstPercent, GstAmount, Net,
               SourceModule, SourceNo, IsPackageItem, DayNo, Sort, ChargeId FROM #IpdBillCalc;
        UPDATE dbo.IpdAdmission SET BillId = @billId, BillUpToAt = @UpTo, Status = 'BILL_FINAL', ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @AdmissionId;
        DECLARE @t1 BIGINT, @t2 BIGINT;
        EXEC dbo.usp_Ipd_PostLedger @Kind = 'BILL', @RefId = @billId, @UserId = @UserId, @TransactionId = @t1 OUTPUT;
        EXEC dbo.usp_Ipd_PostLedger @Kind = 'BILLADJ', @RefId = @billId, @UserId = @UserId, @TransactionId = @t2 OUTPUT;
        UPDATE dbo.IpdBill SET SalesTxnId = @t1, AdjustTxnId = @t2 WHERE BillId = @billId;
        DECLARE @claimId INT = NULL;
        IF @payer > 0 EXEC dbo.usp_Ipd_ClaimCreate @BillId = @billId, @UserId = @UserId, @ClaimId = @claimId OUTPUT;   -- 2541
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'FINAL_BILL', @status, 'BILL_FINAL', CONCAT(N'Final bill ', @no, N' ₹', FORMAT(@net, 'N2', 'en-IN'),
                CASE WHEN @bd > 0 THEN CONCAT(N', discount ₹', FORMAT(@bd, 'N2', 'en-IN'), N' (', LTRIM(RTRIM(@DiscountReason)), N')') ELSE N'' END,
                N', advance adjusted ₹', FORMAT(@adj, 'N2', 'en-IN'),
                CASE WHEN @payer > 0 THEN CONCAT(N', TPA / insurance share ₹', FORMAT(@payer, 'N2', 'en-IN'), N', patient share ₹', FORMAT(@net - @payer, 'N2', 'en-IN')) ELSE N'' END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @billId AS BillId, @no AS BillNo, @net AS Net, @adj AS AdvanceAdjusted, @payer AS PayerShare, CAST(@net - @payer AS DECIMAL(18,2)) AS PatientShare,
               (SELECT ClaimNo FROM dbo.IpdClaim WHERE ClaimId = @claimId) AS ClaimNo,
               CAST(CASE WHEN @net - @payer - @held > 0 THEN @net - @payer - @held ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
               CAST(CASE WHEN @held - (@net - @payer) > 0 THEN @held - (@net - @payer) ELSE 0 END AS DECIMAL(18,2)) AS RefundDue;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── usp_Ipd_PostLedger ──
-- ── 4. ledger (replaces 2423): advance, refund, bill, adjustment, settlement ─────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostLedger
    @Kind   VARCHAR(10),   -- ADVRCPT / SETTLERCPT (RefId = PaymentDetailId) | ADVREFUND (RefId = AdvanceId)
                           -- BILL / BILLADJ / SETTLEMOVE (RefId = IpdBill.BillId; SETTLEMOVE needs @Amount)
    @RefId  INT,
    @UserId INT = NULL,
    @Amount DECIMAL(18,2) = NULL,
    @TransactionId BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'IPD Patient Advance'),
            @cash INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Cash Account'),
            @bank INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Bank Account'),
            @recv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable'),
            @rev INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'IPD Revenue'),
            @discL INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Discount Allowed'),
            @roL INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Round Off'),
            @gstL INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'GST Output Payable');
    IF @adv IS NULL THROW 54090, 'The ledger "IPD Patient Advance" is missing (run SQLScripts/2422).', 1;
    DECLARE @co INT, @br INT, @date DATETIME, @amt DECIMAL(18,2), @mode VARCHAR(30), @ref NVARCHAR(100), @no NVARCHAR(50), @ip NVARCHAR(40),
            @party NVARCHAR(250), @narr NVARCHAR(400), @lines NVARCHAR(MAX), @modeLedger INT, @tid BIGINT, @vno NVARCHAR(50);
    SET @TransactionId = NULL;
    IF @Kind IN ('ADVRCPT', 'SETTLERCPT')
    BEGIN
        SELECT @co = ph.CompanyId, @br = ph.BranchId, @date = COALESCE(pd.PaymentDate, pd.CreatedDate), @amt = pd.PaidAmount, @mode = UPPER(pm.MethodCode),
               @ref = COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''), pd.ChequeNo), @no = pd.ReceiptNo, @ip = a.IpNo,
               @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName)))
        FROM dbo.PaymentDetail pd
        JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND RTRIM(ph.ModuleCode) = 'IPD'
        JOIN dbo.IpdAdmission a ON a.AdmissionId = ph.ModuleRefId
        JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE pd.PaymentDetailId = @RefId AND pd.IsActive = 1;
        IF @amt IS NULL OR @amt <= 0 RETURN;
        IF @Kind = 'SETTLERCPT' AND @recv IS NULL THROW 54091, 'The ledger "Patient Receivable" is missing.', 1;
        SET @modeLedger = dbo.fn_Acc_ModeLedger(@br, @mode, CASE WHEN @mode = 'CASH' THEN @cash ELSE @bank END);
        SET @narr = CONCAT(CASE WHEN @Kind = 'ADVRCPT' THEN N'IPD advance receipt ' ELSE N'IPD bill settlement ' END, @no, N' - ', @ip, N' - ', @party, N' (', @mode, ISNULL(N' ' + @ref, N''), N')');
        SET @lines = (SELECT * FROM (VALUES (@modeLedger, @amt, 0, N'Received by ' + @mode),
                      (CASE WHEN @Kind = 'ADVRCPT' THEN @adv ELSE @recv END, 0, @amt, CASE WHEN @Kind = 'ADVRCPT' THEN N'Advance from patient' ELSE N'Bill amount received' END)) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        DECLARE @rt NVARCHAR(30) = CASE WHEN @Kind = 'ADVRCPT' THEN 'IPD_ADVANCE' ELSE 'IPD_SETTLE' END;
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'RCT', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = @rt, @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @PaymentMode = @mode, @InstrumentNo = @ref, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'ADVREFUND'
    BEGIN
        SELECT @co = a.CompanyId, @br = a.BranchId, @date = v.CreatedDate, @amt = v.Amount, @mode = UPPER(ISNULL(pm.MethodCode, v.Mode)), @ref = v.RefNo,
               @no = v.DocNo, @ip = a.IpNo, @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName)))
        FROM dbo.IpdAdvance v
        JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
        JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        LEFT JOIN dbo.PaymentMethodMaster pm ON pm.MethodName = v.Mode OR UPPER(pm.MethodCode) = UPPER(v.Mode)
        WHERE v.AdvanceId = @RefId AND v.Kind = 'REFUND' AND v.IsActive = 1;
        IF @amt IS NULL OR @amt <= 0 RETURN;
        SET @modeLedger = dbo.fn_Acc_ModeLedger(@br, @mode, CASE WHEN @mode = 'CASH' THEN @cash ELSE @bank END);
        SET @narr = CONCAT(N'IPD advance refund ', @no, N' - ', @ip, N' - ', @party, N' (', @mode, ISNULL(N' ' + @ref, N''), N')');
        SET @lines = (SELECT * FROM (VALUES (@adv, @amt, 0, N'Advance refunded'), (@modeLedger, 0, @amt, N'Paid back by ' + @mode)) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'PMT', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'IPD_ADVREFUND', @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @PaymentMode = @mode, @InstrumentNo = @ref, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind IN ('BILL', 'BILLADJ', 'SETTLEMOVE')
    BEGIN
        IF @recv IS NULL OR @rev IS NULL OR @discL IS NULL OR @roL IS NULL OR @gstL IS NULL
            THROW 54092, 'A ledger of the IPD bill is missing (Patient Receivable, IPD Revenue, Discount Allowed, Round Off, GST Output Payable).', 1;
        DECLARE @gross DECIMAL(18,2), @disc DECIMAL(18,2), @gst DECIMAL(18,2), @ro DECIMAL(18,2), @net DECIMAL(18,2), @adj DECIMAL(18,2),
                @payer DECIMAL(18,2), @tpaId INT, @tpaL INT;   -- 2541
        SELECT @co = b.CompanyId, @br = b.BranchId, @date = CASE WHEN @Kind = 'SETTLEMOVE' THEN GETDATE() ELSE b.BillAt END, @no = b.BillNo, @ip = a.IpNo,
               @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName))),
               @gross = b.Gross, @disc = b.ItemDiscount + b.BillDiscount, @gst = b.Gst, @ro = b.RoundOff, @net = b.Net, @adj = b.AdvanceAdjusted, @payer = b.PayerShare, @tpaId = b.InsuranceTpaId
        FROM dbo.IpdBill b JOIN dbo.IpdAdmission a ON a.AdmissionId = b.AdmissionId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        WHERE b.BillId = @RefId;
        IF @no IS NULL RETURN;
        IF @Kind = 'BILL'
        BEGIN
            IF @gross <= 0 AND @net <= 0 RETURN;
            IF ISNULL(@payer, 0) > 0 EXEC dbo.usp_Ipd_TpaLedger @InsuranceTpaId = @tpaId, @LedgerId = @tpaL OUTPUT;   -- 2541
            SET @narr = CONCAT(N'IPD final bill ', @no, N' - ', @ip, N' - ', @party);
            SET @lines = (SELECT LedgerId, Dr, Cr, Narration FROM (VALUES
                            (@recv, @net - ISNULL(@payer, 0), CAST(0 AS DECIMAL(18,2)), CASE WHEN ISNULL(@payer, 0) > 0 THEN N'Patient share of the bill' ELSE N'Bill amount' END),
                            (@tpaL, ISNULL(@payer, 0), 0, N'TPA / insurance share (claim)'),
                            (@discL, @disc, 0, N'Discount on the bill'),
                            (@rev, 0, @gross, N'IPD charges'),
                            (@gstL, 0, @gst, N'GST on the bill'),
                            (@roL, CASE WHEN @ro < 0 THEN -@ro ELSE 0 END, CASE WHEN @ro > 0 THEN @ro ELSE 0 END, N'Round off')) v (LedgerId, Dr, Cr, Narration)
                          WHERE Dr > 0 OR Cr > 0 FOR JSON PATH);
            EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'SLS', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'IPD_BILL', @ReferenceId = @RefId,
                 @Narration = @narr, @PayeeName = @party, @PaymentMode = NULL, @InstrumentNo = NULL, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
                 @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
        END
        ELSE
        BEGIN
            SET @amt = CASE WHEN @Kind = 'BILLADJ' THEN @adj ELSE @Amount END;
            IF ISNULL(@amt, 0) <= 0 RETURN;
            SET @narr = CASE WHEN @Kind = 'BILLADJ' THEN CONCAT(N'IPD advance adjusted against bill ', @no, N' - ', @ip, N' - ', @party)
                             ELSE CONCAT(N'IPD bill ', @no, N' cancelled: settlement received kept as advance - ', @ip, N' - ', @party) END;
            SET @lines = CASE WHEN @Kind = 'BILLADJ'
                              THEN (SELECT * FROM (VALUES (@adv, @amt, 0, N'Advance adjusted'), (@recv, 0, @amt, N'Against the bill')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH)
                              ELSE (SELECT * FROM (VALUES (@recv, @amt, 0, N'Bill cancelled'), (@adv, 0, @amt, N'Kept as advance')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH) END;
            DECLARE @rt2 NVARCHAR(30) = CASE WHEN @Kind = 'BILLADJ' THEN 'IPD_BILLADJ' ELSE 'IPD_SETTLEMOVE' END;
            EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'JRN', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = @rt2, @ReferenceId = @RefId,
                 @Narration = @narr, @PayeeName = @party, @PaymentMode = NULL, @InstrumentNo = NULL, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
                 @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
        END
    END
    SET @TransactionId = @tid;
END;
GO

-- ── usp_Api_IpdBill_Cancel ──
-- Reopens the bill: reversal vouchers, settlements received become advance, charges can be added again.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @BillId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54971, 'Enter the reason for cancelling the bill.', 1;
        DECLARE @adm INT, @st VARCHAR(10), @prev VARCHAR(20), @no NVARCHAR(40), @t1 BIGINT, @t2 BIGINT, @open BIT, @admStatus VARCHAR(20);
        SELECT @adm = b.AdmissionId, @st = b.Status, @prev = b.PrevStatus, @no = b.BillNo, @t1 = b.SalesTxnId, @t2 = b.AdjustTxnId, @open = a.IsOpen, @admStatus = a.Status
        FROM dbo.IpdBill b WITH (UPDLOCK) JOIN dbo.IpdAdmission a WITH (UPDLOCK) ON a.AdmissionId = b.AdmissionId
        WHERE b.BillId = @BillId AND b.CompanyId = @CompanyId AND b.BranchId = @BranchId;
        IF @adm IS NULL THROW 54972, 'The bill was not found in this branch.', 1;
        IF @st <> 'FINAL' THROW 54973, 'The bill is already cancelled.', 1;
        IF @open = 0 OR @admStatus <> 'BILL_FINAL' THROW 54974, 'The patient is discharged: the bill cannot be cancelled.', 1;
        -- 2541: the TPA claim of the bill
        IF EXISTS (SELECT 1 FROM dbo.IpdClaim WHERE BillId = @BillId AND IsLive = 1 AND Status <> 'OPEN')
            THROW 54975, 'The TPA claim of this bill is already submitted / settled: the bill cannot be cancelled.', 1;
        INSERT dbo.IpdClaimEvent (ClaimId, EventType, EventAt, Remarks, CreatedBy)
        SELECT ClaimId, 'CANCELLED', GETDATE(), CONCAT(N'Bill cancelled: ', LTRIM(RTRIM(@Reason))), @UserId FROM dbo.IpdClaim WHERE BillId = @BillId AND IsLive = 1;
        UPDATE dbo.IpdClaim SET Status = 'CANCELLED', IsLive = 0, CancelReason = LEFT(CONCAT(N'Bill cancelled: ', LTRIM(RTRIM(@Reason))), 300), ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE BillId = @BillId AND IsLive = 1;
        DECLARE @r BIGINT, @why NVARCHAR(300) = CONCAT(N'IPD bill ', @no, N' cancelled: ', LTRIM(RTRIM(@Reason)));
        IF @t1 IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE TransactionId = @t1 AND Status <> 'C')
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @t1, @Reason = @why, @UserId = @UserId, @ReversalId = @r OUTPUT;
        IF @t2 IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE TransactionId = @t2 AND Status <> 'C')
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @t2, @Reason = @why, @UserId = @UserId, @ReversalId = @r OUTPUT;
        -- settlement discount / round off (IPD_SETTLEADJ, SQLScripts/2479): journal cancelled, adjustment dropped
        DECLARE @adjTxn BIGINT, @adjId INT;
        DECLARE adjc CURSOR LOCAL FAST_FORWARD FOR SELECT AdvanceId, LedgerTxnId FROM dbo.IpdAdvance WHERE AdmissionId = @adm AND Kind = 'ADJUST' AND IsActive = 1;
        OPEN adjc; FETCH NEXT FROM adjc INTO @adjId, @adjTxn;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @adjTxn IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE TransactionId = @adjTxn AND Status <> 'C')
                EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @adjTxn, @Reason = @why, @UserId = @UserId, @ReversalId = @r OUTPUT;
            UPDATE dbo.IpdAdvance SET IsActive = 0, Remarks = LEFT(CONCAT(ISNULL(Remarks + N' · ', N''), N'dropped: bill ', @no, N' cancelled'), 300) WHERE AdvanceId = @adjId;
            FETCH NEXT FROM adjc INTO @adjId, @adjTxn;
        END
        CLOSE adjc; DEALLOCATE adjc;
        DECLARE @settled DECIMAL(18,2) = (SELECT ISNULL(SUM(Amount), 0) FROM dbo.IpdAdvance WHERE AdmissionId = @adm AND Kind = 'SETTLE' AND IsActive = 1);
        IF @settled > 0
        BEGIN
            EXEC dbo.usp_Ipd_PostLedger @Kind = 'SETTLEMOVE', @RefId = @BillId, @UserId = @UserId, @Amount = @settled;
            UPDATE dbo.IpdAdvance SET Kind = 'ADVANCE', Remarks = LEFT(CONCAT(ISNULL(Remarks + N' · ', N''), N'paid on cancelled bill ', @no), 300)
            WHERE AdmissionId = @adm AND Kind = 'SETTLE' AND IsActive = 1;
        END
        UPDATE dbo.IpdBill SET Status = 'CANCELLED', CancelReason = LTRIM(RTRIM(@Reason)), CancelledBy = @UserId, CancelledAt = @now WHERE BillId = @BillId;
        UPDATE dbo.IpdAdmission SET BillId = NULL, BillUpToAt = NULL, Status = @prev, ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @adm;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
        VALUES (@adm, 'BILL_CANCEL', 'BILL_FINAL', @prev, CONCAT(N'Bill ', @no, N' cancelled: ', LTRIM(RTRIM(@Reason)),
                CASE WHEN @settled > 0 THEN CONCAT(N' (₹', FORMAT(@settled, 'N2', 'en-IN'), N' received on it kept as advance)') ELSE N'' END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── usp_Api_IpdAdvance_Get ──
-- receipt / refund voucher / settlement note for print (2423) + the settlement figures
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvance_Get @CompanyId INT, @AdvanceId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adm INT = (SELECT v.AdmissionId FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId WHERE v.AdvanceId = @AdvanceId AND a.CompanyId = @CompanyId);
    IF @adm IS NULL RETURN;
    SELECT v.AdvanceId, v.Kind, v.Amount, v.DocNo, v.Mode, v.RefNo, v.Remarks, v.CreatedDate, u.FullName AS CreatedByName, mo.NetAdvance, mo.AdvanceTotal, mo.RefundTotal,
           mo.SettleTotal, mo.AdjustTotal, b.BillNo, b.Net AS BillNet,
           adj.DiscType, adj.DiscValue, ISNULL(adj.DiscAmount, 0) AS DiscAmount, ISNULL(adj.RoundOff, 0) AS RoundOff, adj.Remarks AS DiscReason,
           CAST(ISNULL(b.Net - b.PayerShare + b.PayerToPatient, 0) - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceAfter
    FROM dbo.IpdAdvance v
    LEFT JOIN dbo.Users u ON u.Id = v.CreatedBy
    CROSS APPLY dbo.fn_Ipd_Money(v.AdmissionId) mo
    OUTER APPLY (SELECT TOP 1 x.DiscType, x.DiscValue, x.DiscAmount, x.RoundOff, x.Remarks FROM dbo.IpdAdvance x
                 WHERE x.IsActive = 1 AND x.Kind = 'ADJUST' AND (x.AdvanceId = v.AdvanceId OR x.AdjustOfAdvanceId = v.AdvanceId)) adj
    LEFT JOIN dbo.IpdBill b ON b.BillId = v.BillId
    WHERE v.AdvanceId = @AdvanceId;
    SELECT h.* FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @adm) h;
    SELECT pm.MethodName, pd.PaidAmount, COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''), pd.ChequeNo) AS RefNo, pd.CardLast4
    FROM dbo.IpdAdvance v
    JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = v.PaymentHeaderId AND pd.IsActive = 1
    JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE v.AdvanceId = @AdvanceId ORDER BY pd.PaymentDetailId;
END;
GO

-- ── usp_Api_IpdAdvance_Preview ──
-- the figures for the Collect payment modal (worked out here, shown as they are)
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvance_Preview @CompanyId INT, @BranchId INT, @AdmissionId INT,
    @DiscType CHAR(1) = NULL, @DiscValue DECIMAL(18,2) = 0, @RoundOff BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @DiscType = NULLIF(UPPER(LTRIM(RTRIM(@DiscType))), '');
    DECLARE @billId INT, @billNo NVARCHAR(40), @billNet DECIMAL(18,2), @open BIT;
    SELECT @billId = a.BillId, @open = a.IsOpen, @billNo = b.BillNo, @billNet = b.Net
    FROM dbo.IpdAdmission a LEFT JOIN dbo.IpdBill b ON b.BillId = a.BillId
    WHERE a.AdmissionId = @AdmissionId AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId;
    IF @open IS NULL RETURN;
    IF @billId IS NULL
    BEGIN
        SELECT CAST('ADVANCE' AS VARCHAR(10)) AS Kind, CAST(NULL AS NVARCHAR(40)) AS BillNo, CAST(NULL AS DECIMAL(18,2)) AS BillNet, mo.NetAdvance AS Paid,
               CAST(lt.Net - ps.PayerShare - mo.NetAdvance AS DECIMAL(18,2)) AS Due, CAST(0 AS DECIMAL(18,2)) AS Discount, CAST(0 AS DECIMAL(18,2)) AS RoundOff,
               CAST(NULL AS DECIMAL(18,2)) AS Payable, lt.Net AS BillNow,
               CAST(CASE WHEN ISNULL(@DiscValue, 0) <> 0 OR ISNULL(@RoundOff, 0) = 1 THEN N'Discount and round off are given when the final bill is settled.' END AS NVARCHAR(200)) AS Note
        FROM dbo.fn_Ipd_Money(@AdmissionId) mo OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(@AdmissionId, GETDATE())) lt
        CROSS APPLY dbo.fn_Ipd_PayerShare(@AdmissionId, lt.Net) ps;   -- 2541
        RETURN;
    END
    SELECT CAST('SETTLE' AS VARCHAR(10)) AS Kind, @billNo AS BillNo, @billNet AS BillNet, mo.NetAdvance AS Paid, c.Due, c.Disc AS Discount, c.RoundOff, c.Payable, @billNet AS BillNow,
           CAST(CASE WHEN @DiscType = 'P' AND @DiscValue > 100 THEN N'The discount cannot be more than 100%.'
                     WHEN @DiscType = 'A' AND @DiscValue > c.Due THEN N'The discount is limited to the balance due.' END AS NVARCHAR(200)) AS Note
    FROM dbo.fn_Ipd_SettleCalc(@AdmissionId, @DiscType, @DiscValue, @RoundOff) c CROSS APPLY dbo.fn_Ipd_Money(@AdmissionId) mo;
END;
GO

-- ── usp_Api_IpdAdvance_Refund ──
-- Refund of advance while admitted: at most what is left after the bill so far (the rest is settled at discharge).
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvance_Refund
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Amount DECIMAL(18,2), @Method VARCHAR(20), @RefNo NVARCHAR(100) = NULL, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;   -- called inside another transaction: only this procedure's work is undone on a refusal
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54501, 'Enter the reason for the refund.', 1;
        IF ISNULL(@Amount, 0) <= 0 THROW 54502, 'Enter the refund amount.', 1;
        IF @Amount <> ROUND(@Amount, 2) THROW 54503, 'The refund amount can have at most two decimals.', 1;
        DECLARE @modeName NVARCHAR(100) = (SELECT MethodName FROM dbo.PaymentMethodMaster WHERE UPPER(MethodCode) = UPPER(@Method) AND IsActive = 1 AND UPPER(MethodCode) NOT IN ('POINTS', 'WALLET'));
        IF @modeName IS NULL THROW 54504, 'Choose how the refund is paid (cash, UPI, NEFT, cheque or card).', 1;
        DECLARE @status VARCHAR(20), @open BIT;
        SELECT @status = Status, @open = IsOpen FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL THROW 54505, 'The admission was not found in this branch.', 1;
        DECLARE @net DECIMAL(18,2) = (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId));
        DECLARE @bill DECIMAL(18,2) = CASE WHEN @status = 'CANCELLED' THEN 0 ELSE (SELECT lt.Net - ps.PayerShare FROM dbo.fn_Ipd_LiveTotal(@AdmissionId, @now) lt CROSS APPLY dbo.fn_Ipd_PayerShare(@AdmissionId, lt.Net) ps) END;
        DECLARE @max DECIMAL(18,2) = CASE WHEN @open = 1 OR @status = 'CANCELLED' THEN @net - @bill ELSE 0 END;
        IF @max < 0 SET @max = 0;
        IF @Amount > @max
        BEGIN
            SET @msg = CONCAT(N'Refundable now: ₹', FORMAT(@max, 'N2', 'en-IN'), N' (advance ₹', FORMAT(@net, 'N2', 'en-IN'), N' less the bill so far ₹', FORMAT(@bill, 'N2', 'en-IN'), N').');
            THROW 54506, @msg, 1;
        END;
        DECLARE @no NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'REF', @DocDate = @now, @DocNo = @no OUTPUT;
        INSERT dbo.IpdAdvance (AdmissionId, Kind, Amount, DocNo, Mode, RefNo, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'REFUND', @Amount, @no, @modeName, NULLIF(LTRIM(RTRIM(@RefNo)), N''), LTRIM(RTRIM(@Reason)), @UserId);
        DECLARE @advId INT = CAST(SCOPE_IDENTITY() AS INT);
        EXEC dbo.usp_Ipd_PostLedger @Kind = 'ADVREFUND', @RefId = @advId, @UserId = @UserId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'REFUND', CONCAT(N'Advance refund ₹', FORMAT(@Amount, 'N2', 'en-IN'), N' by ', @modeName, N', voucher ', @no, N': ', LTRIM(RTRIM(@Reason))), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @advId AS AdvanceId, @no AS DocNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── usp_Api_IpdAdmission_Get ──
-- ── one admission: banner and every block of the patient workspace ──────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_Get @CompanyId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    -- 1 header + live money
    SELECT h.*, lt.Net AS BillNow, lt.Days AS BedDays, lt.NoTariff, mo.AdvanceTotal, mo.RefundTotal, mo.NetAdvance,
           CAST(lt.Net - ps.PayerShare - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceDue, ps.PayerShare AS PayerShareNow, ps.ApprovedAmount AS PayerApproved,
           CAST(CASE WHEN h.IsOpen = 1 AND h.PayerType = 'CASH' AND (lt.Net > mo.NetAdvance OR (mo.NetAdvance > 0 AND lt.Net >= mo.NetAdvance * h.DepositAlertPercent / 100.0)) THEN 1 ELSE 0 END AS BIT) AS DepositAlert,
           DATEDIFF(DAY, h.AdmissionAt, ISNULL(h.DischargeAt, @now)) + 1 AS DayCount
    FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @AdmissionId) h
    CROSS APPLY dbo.fn_Ipd_LiveTotal(h.AdmissionId, @now) lt
    CROSS APPLY dbo.fn_Ipd_Money(h.AdmissionId) mo
    CROSS APPLY dbo.fn_Ipd_PayerShare(h.AdmissionId, lt.Net) ps;   -- 2541
    IF @@ROWCOUNT = 0 RETURN;
    -- 2 payers
    SELECT py.PayerId, py.Seq, py.PayerType, py.InsuranceTpaId, py.CorporateId, py.SchemeId, COALESCE(ins.Name, corp.Corporate_Name, sch.SchemeName) AS PayerName,
           py.PolicyNo, py.MemberId, py.CardHolderName, py.RelationToHolder, py.PolicyValidTo, py.EmployeeId, py.CardFilePath, py.Remarks
    FROM dbo.IpdAdmissionPayer py
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = py.InsuranceTpaId
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = py.CorporateId
    LEFT JOIN dbo.GovernmentSchemeMaster sch ON sch.Scheme_ID = py.SchemeId
    WHERE py.AdmissionId = @AdmissionId ORDER BY py.Seq;
    -- 3 attendants
    SELECT a.AttendantId, a.Name, a.Relation, a.Phone, a.Address, a.IdTypeId, it.IdentificationTypeName AS IdTypeName, a.IdNumber, a.IsPrimary, a.PassNo
    FROM dbo.IpdAttendant a LEFT JOIN dbo.IdentificationTypeMaster it ON it.IdentificationTypeId = a.IdTypeId
    WHERE a.AdmissionId = @AdmissionId ORDER BY a.IsPrimary DESC, a.AttendantId;
    -- 4 MLC
    SELECT m.* FROM dbo.IpdMlc m WHERE m.AdmissionId = @AdmissionId;
    -- 5 consents (text read separately for print)
    SELECT c.AdmissionConsentId, c.ConsentId, c.ConsentType, c.Language, c.Version, c.SignedByName, c.SignedByRelation, c.WitnessName, c.SignaturePath,
           c.WitnessSignaturePath, c.SignedAt, u.FullName AS CapturedByName
    FROM dbo.IpdAdmissionConsent c LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
    WHERE c.AdmissionId = @AdmissionId ORDER BY c.SignedAt;
    -- 6 bed movements
    SELECT m.MovementId, m.MoveType, m.EndType, m.FromAt, m.ToAt, m.BedId, b.BedNumber, r.RoomNumber, w.WardName, bc.CategoryName AS BedCategoryName, m.Reason,
           u.FullName AS CreatedByName
    FROM dbo.IpdBedMovement m
    JOIN dbo.BedMaster b ON b.BedId = m.BedId
    LEFT JOIN dbo.RoomMaster r ON r.RoomId = m.RoomId
    LEFT JOIN dbo.WardMaster w ON w.WardId = m.WardId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = m.BedCategoryId
    LEFT JOIN dbo.Users u ON u.Id = m.CreatedBy
    WHERE m.AdmissionId = @AdmissionId ORDER BY m.FromAt, m.MovementId;
    -- 7 advances and refunds (with the modes of each receipt)
    SELECT v.AdvanceId, v.Kind, v.Amount, v.DocNo, v.Mode, v.RefNo, v.Remarks, v.CreatedDate, u.FullName AS CreatedByName,
           CASE WHEN v.Kind IN ('ADVANCE', 'SETTLE') THEN
                STUFF((SELECT N', ' + pm.MethodName + N' ₹' + FORMAT(pd.PaidAmount, 'N2', 'en-IN')
                       FROM dbo.PaymentDetail pd JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
                       WHERE pd.PaymentHeaderId = v.PaymentHeaderId AND pd.IsActive = 1 FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
                ELSE v.Mode END AS Modes
    FROM dbo.IpdAdvance v LEFT JOIN dbo.Users u ON u.Id = v.CreatedBy
    WHERE v.AdmissionId = @AdmissionId AND v.IsActive = 1 ORDER BY v.CreatedDate, v.AdvanceId;
    -- 8 documents
    SELECT d.DocumentId, d.DocType, d.Title, d.FilePath, d.Remarks, d.CreatedDate, u.FullName AS CreatedByName
    FROM dbo.IpdDocument d LEFT JOIN dbo.Users u ON u.Id = d.CreatedBy
    WHERE d.AdmissionId = @AdmissionId AND d.IsActive = 1 ORDER BY d.CreatedDate DESC;
    -- 9 activity log
    SELECT l.LogId, l.Action, l.FromStatus, l.ToStatus, l.Remarks, l.CreatedDate, u.FullName AS CreatedByName
    FROM dbo.IpdStatusLog l LEFT JOIN dbo.Users u ON u.Id = l.CreatedBy
    WHERE l.AdmissionId = @AdmissionId ORDER BY l.LogId DESC;
END;
GO

-- ── usp_Api_IpdEstimate_Live ──
-- ── Current Billing Estimation (real time) ──────────────────────────────────────────────────────────────────
-- What the patient would pay if discharged at @AsOf (default now), and the estimate till the expected discharge.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdEstimate_Live @CompanyId INT, @AdmissionId INT, @AsOf DATETIME = NULL, @ProjectTo DATETIME = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    SET @AsOf = ISNULL(@AsOf, @now);
    DECLARE @payer VARCHAR(12), @expected DATETIME, @pct INT, @status VARCHAR(20), @disch DATETIME, @admAt DATETIME;
    SELECT @payer = a.PayerType, @expected = a.ExpectedDischargeAt, @pct = ISNULL(s.IpdDepositAlertPercent, 80), @status = a.Status, @disch = a.DischargeAt, @admAt = a.AdmissionAt
    FROM dbo.IpdAdmission a LEFT JOIN dbo.HospitalSettings s ON s.BranchID = a.BranchId WHERE a.AdmissionId = @AdmissionId AND a.CompanyId = @CompanyId;
    IF @payer IS NULL RETURN;
    IF @disch IS NOT NULL AND @AsOf > @disch SET @AsOf = @disch;
    SET @ProjectTo = CASE WHEN @disch IS NOT NULL THEN NULL WHEN @ProjectTo IS NOT NULL THEN @ProjectTo ELSE @expected END;
    IF @ProjectTo IS NOT NULL AND @ProjectTo <= @AsOf SET @ProjectTo = NULL;

    DECLARE @L TABLE (Head VARCHAR(20), Gross DECIMAL(18,2), Discount DECIMAL(18,2), GstAmount DECIMAL(18,2), Net DECIMAL(18,2), Status VARCHAR(10), NoTariff BIT, UsedFallback BIT, DayNo INT);
    IF @status <> 'CANCELLED'
        INSERT @L SELECT Head, Gross, Discount, GstAmount, Net, Status, NoTariff, UsedFallback, DayNo FROM dbo.fn_Ipd_BillLines(@AdmissionId, @AsOf);
    DECLARE @projected DECIMAL(18,2) = NULL, @projDays INT = NULL;
    IF @ProjectTo IS NOT NULL AND @status <> 'CANCELLED'
        SELECT @projected = Net, @projDays = Days FROM dbo.fn_Ipd_LiveTotal(@AdmissionId, @ProjectTo);

    -- 1 header
    SELECT h.*, @AsOf AS AsOf, @ProjectTo AS ProjectTo FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @AdmissionId) h;
    -- 2 heads (every head, in bill order)
    SELECT hd.Head, hd.HeadName, hd.Sort, COUNT(l.Head) AS Lines, CAST(ISNULL(SUM(l.Gross), 0) AS DECIMAL(18,2)) AS Gross,
           CAST(ISNULL(SUM(l.Discount), 0) AS DECIMAL(18,2)) AS Discount, CAST(ISNULL(SUM(l.GstAmount), 0) AS DECIMAL(18,2)) AS Gst,
           CAST(ISNULL(SUM(l.Net), 0) AS DECIMAL(18,2)) AS Net, CAST(ISNULL(SUM(CASE WHEN l.Status = 'ACCRUED' THEN l.Net END), 0) AS DECIMAL(18,2)) AS Accrued,
           CAST(ISNULL(SUM(CASE WHEN l.Status = 'POSTED' THEN l.Net END), 0) AS DECIMAL(18,2)) AS Posted,
           CAST(ISNULL(SUM(l.Net), 0) AS DECIMAL(18,2)) AS PatientShare, CAST(0 AS DECIMAL(18,2)) AS PayerShare
    FROM dbo.fn_Ipd_Heads() hd LEFT JOIN @L l ON l.Head = hd.Head
    GROUP BY hd.Head, hd.HeadName, hd.Sort ORDER BY hd.Sort;
    -- 3 totals
    DECLARE @gross DECIMAL(18,2), @disc DECIMAL(18,2), @gst DECIMAL(18,2), @net DECIMAL(18,2), @days INT;
    SELECT @gross = ISNULL(SUM(Gross), 0), @disc = ISNULL(SUM(Discount), 0), @gst = ISNULL(SUM(GstAmount), 0), @net = ISNULL(SUM(Net), 0), @days = ISNULL(MAX(DayNo), 0) FROM @L;
    SELECT @gross AS Gross, @disc AS Discount, @gst AS Gst, @net AS BillNow, @days AS BedDays,
           mo.AdvanceTotal, mo.RefundTotal, mo.NetAdvance, ISNULL(ps.ApprovedAmount, 0) AS ApprovedAmount,
           CAST(@net - ps.PayerShare AS DECIMAL(18,2)) AS PatientShare, ps.PayerShare AS PayerShare,
           CAST(CASE WHEN @net - ps.PayerShare - mo.NetAdvance > 0 THEN @net - ps.PayerShare - mo.NetAdvance ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN mo.NetAdvance - (@net - ps.PayerShare) > 0 THEN mo.NetAdvance - (@net - ps.PayerShare) ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           CAST(CASE WHEN @status IN ('ADMITTED', 'DISCHARGE_ADVISED') AND @payer = 'CASH'
                      AND (@net > mo.NetAdvance OR (mo.NetAdvance > 0 AND @net >= mo.NetAdvance * @pct / 100.0)) THEN 1 ELSE 0 END AS BIT) AS DepositAlert,
           @pct AS DepositAlertPercent,
           @projected AS ProjectedTotal, @projDays AS ProjectedDays,
           CAST(CASE WHEN @projected IS NULL THEN NULL ELSE @projected - @net END AS DECIMAL(18,2)) AS ProjectedExtra,
           CAST(CASE WHEN @projected IS NULL THEN NULL WHEN @projected - pp.PayerShare - mo.NetAdvance > 0 THEN @projected - pp.PayerShare - mo.NetAdvance ELSE 0 END AS DECIMAL(18,2)) AS ProjectedBalance,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM @L WHERE NoTariff = 1) THEN 1 ELSE 0 END AS BIT) AS NoTariff,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM @L WHERE UsedFallback = 1) THEN 1 ELSE 0 END AS BIT) AS UsedFallback
    FROM dbo.fn_Ipd_Money(@AdmissionId) mo
    CROSS APPLY dbo.fn_Ipd_PayerShare(@AdmissionId, @net) ps   -- 2541
    CROSS APPLY dbo.fn_Ipd_PayerShare(@AdmissionId, ISNULL(@projected, 0)) pp;
    -- 4 ordered, not yet charged (LAB orders, indents, OT bookings: filled as Phases 4 and 8 arrive)
    SELECT CAST(NULL AS VARCHAR(20)) AS Head, CAST(NULL AS NVARCHAR(250)) AS ItemName, CAST(NULL AS DATETIME) AS OrderedAt,
           CAST(NULL AS NVARCHAR(50)) AS OrderNo, CAST(NULL AS NVARCHAR(30)) AS OrderStatus, CAST(NULL AS DECIMAL(18,2)) AS EstimatedAmount
    WHERE 1 = 0;
END;
GO

-- ── usp_Api_Ipd_Dashboard ──
-- ── IPD dashboard ───────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_Ipd_Dashboard @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @now DATETIME = GETDATE();
    DECLARE @beds TABLE (BedId INT PRIMARY KEY, WardId INT, Occupied BIT, Available BIT);
    INSERT @beds
    SELECT b.BedId, b.WardId, CASE WHEN m.BedId IS NOT NULL THEN 1 ELSE 0 END,
           CASE WHEN m.BedId IS NULL AND b.BedStatus = 'Available' THEN 1 ELSE 0 END
    FROM dbo.BedMaster b JOIN dbo.WardMaster w ON w.WardId = b.WardId AND w.IsActive = 1
    LEFT JOIN (SELECT DISTINCT BedId FROM dbo.IpdBedMovement WHERE ToAt IS NULL) m ON m.BedId = b.BedId
    WHERE b.IsActive = 1 AND b.BranchId = @BranchId;
    -- 1 tiles
    SELECT (SELECT COUNT(*) FROM dbo.IpdAdmission WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND IsOpen = 1) AS InPatients,
           (SELECT COUNT(*) FROM dbo.IpdAdmission WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND Status <> 'CANCELLED' AND AdmissionAt >= @today) AS AdmittedToday,
           (SELECT COUNT(*) FROM dbo.IpdAdmission WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND Status = 'DISCHARGED' AND DischargeAt >= @today) AS DischargedToday,
           (SELECT COUNT(*) FROM dbo.IpdAdmission WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND Status = 'DISCHARGE_ADVISED') AS DischargeAdvised,
           (SELECT COUNT(*) FROM @beds) AS BedsTotal, (SELECT COUNT(*) FROM @beds WHERE Occupied = 1) AS BedsOccupied,
           (SELECT COUNT(*) FROM @beds WHERE Available = 1) AS BedsAvailable, (SELECT COUNT(*) FROM @beds WHERE Occupied = 0 AND Available = 0) AS BedsOther,
           (SELECT ISNULL(SUM(v.Amount), 0) FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
             WHERE a.BranchId = @BranchId AND v.IsActive = 1 AND v.Kind = 'ADVANCE' AND v.CreatedDate >= @today) AS AdvanceToday,
           (SELECT ISNULL(SUM(v.Amount), 0) FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
             WHERE a.BranchId = @BranchId AND v.IsActive = 1 AND v.Kind = 'REFUND' AND v.CreatedDate >= @today) AS RefundToday;
    -- 2 ward occupancy
    SELECT w.WardId, w.WardName, w.WardType, COUNT(b.BedId) AS Total, ISNULL(SUM(CAST(b.Occupied AS INT)), 0) AS Occupied,
           ISNULL(SUM(CAST(b.Available AS INT)), 0) AS Available, COUNT(b.BedId) - ISNULL(SUM(CAST(b.Occupied AS INT)), 0) - ISNULL(SUM(CAST(b.Available AS INT)), 0) AS Other
    FROM dbo.WardMaster w JOIN @beds b ON b.WardId = w.WardId
    GROUP BY w.WardId, w.WardName, w.WardType ORDER BY w.WardName;
    -- 3 patients in the hospital now
    SELECT TOP 300 a.AdmissionId, a.IpNo, a.AdmissionAt, a.PayerType, a.Status, p.PatientCode,
           LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, p.Gender,
           dbo.fn_Ipd_AgeText(p.DateOfBirth, @today) AS AgeText, b.BedNumber, r.RoomNumber, w.WardName, d.FullName AS ConsultantDoctorName,
           DATEDIFF(DAY, a.AdmissionAt, @now) + 1 AS DayCount, lt.Net AS BillNow, mo.NetAdvance, CAST(lt.Net - ps.PayerShare - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceDue
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
    LEFT JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
    CROSS APPLY dbo.fn_Ipd_LiveTotal(a.AdmissionId, @now) lt
    CROSS APPLY dbo.fn_Ipd_Money(a.AdmissionId) mo
    CROSS APPLY dbo.fn_Ipd_PayerShare(a.AdmissionId, lt.Net) ps   -- 2541
    WHERE a.BranchId = @BranchId AND a.CompanyId = @CompanyId AND a.IsOpen = 1
    ORDER BY w.WardName, b.BedNumber;
END;
GO

-- ── usp_Api_IpdBed_Board ──
-- ── the bed board ───────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_Board @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_Ipd_ExpireReservations @BranchId = @BranchId;
    DECLARE @now DATETIME = GETDATE();
    -- 1 every active bed with its occupant / reservation / cleaning job
    SELECT b.BedId, b.BedNumber, b.BedCategoryId, bc.CategoryName AS BedCategoryName, r.RoomId, r.RoomNumber, r.RoomType,
           w.WardId, w.WardName, w.WardType, w.Gender AS WardGender, dep.DeptName AS WardDepartment, f.FloorId, f.FloorName, bl.BuildingId, bl.BuildingName,
           CAST(ISNULL(b.IsICU, 0) AS BIT) AS IsIcu, CAST(CASE WHEN b.IsIsolation = 1 OR r.IsIsolation = 1 THEN 1 ELSE 0 END AS BIT) AS IsIsolation,
           CAST(ISNULL(b.IsVentilatorCapable, 0) AS BIT) AS IsVentilator,
           CASE WHEN occ.AdmissionId IS NOT NULL THEN N'Occupied' ELSE b.BedStatus END AS Status,
           lg.Reason AS StatusReason, lg.CreatedDate AS StatusSince,
           occ.AdmissionId, occ.IpNo, occ.PatientId, occ.PatientCode, occ.PatientName, occ.Gender, occ.AgeText, occ.AdmissionAt, occ.OccupiedSince,
           occ.ConsultantName, occ.PayerType, occ.ExpectedDischargeAt, occ.KnownAllergies, occ.IsMlc, occ.AdmStatus,
           CASE WHEN occ.AdmissionId IS NULL THEN NULL ELSE DATEDIFF(DAY, occ.AdmissionAt, @now) + 1 END AS DayCount,
           lt.Net AS BillNow, mo.NetAdvance, CAST(lt.Net - ISNULL(ps.PayerShare, 0) - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceDue,
           res.ReservationId, res.PatientName AS ResPatientName, res.Phone AS ResPhone, res.PatientId AS ResPatientId, res.ExpectedAdmitAt, res.ReservedUntil,
           cl.CleaningTaskId, cl.Status AS CleaningStatus, cl.CleaningType, cl.RequestedAt AS CleaningRequestedAt, cl.StartedAt AS CleaningStartedAt,
           cl.SlaMinutes, cu.FullName AS CleaningStaff, DATEDIFF(MINUTE, cl.RequestedAt, @now) AS CleaningMinutes
    FROM dbo.BedMaster b
    JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = w.DepartmentId
    LEFT JOIN dbo.FloorMaster f ON f.FloorId = r.FloorId
    LEFT JOIN dbo.BuildingMaster bl ON bl.BuildingId = b.BuildingId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = b.BedCategoryId
    OUTER APPLY (SELECT TOP 1 a.AdmissionId, a.IpNo, a.PatientId, p.PatientCode, a.AdmissionAt, m.FromAt AS OccupiedSince, a.PayerType, a.ExpectedDischargeAt, a.IsMlc, a.Status AS AdmStatus,
                        LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, p.Gender, p.KnownAllergies,
                        dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(@now AS DATE)) AS AgeText, d.FullName AS ConsultantName
                 FROM dbo.IpdBedMovement m JOIN dbo.IpdAdmission a ON a.AdmissionId = m.AdmissionId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
                 LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
                 WHERE m.BedId = b.BedId AND m.ToAt IS NULL) occ
    OUTER APPLY (SELECT TOP 1 Reason, CreatedDate FROM dbo.IpdBedStatusLog WHERE BedId = b.BedId ORDER BY LogId DESC) lg
    OUTER APPLY (SELECT TOP 1 * FROM dbo.IpdBedReservation x WHERE x.BedId = b.BedId AND x.Status = 'ACTIVE') res
    OUTER APPLY (SELECT TOP 1 * FROM dbo.IpdBedCleaning x WHERE x.BedId = b.BedId AND x.IsOpen = 1) cl
    LEFT JOIN dbo.Users cu ON cu.Id = cl.AssignedUserId
    OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(occ.AdmissionId, @now) WHERE occ.AdmissionId IS NOT NULL) lt
    OUTER APPLY (SELECT NetAdvance FROM dbo.fn_Ipd_Money(occ.AdmissionId) WHERE occ.AdmissionId IS NOT NULL) mo
    OUTER APPLY (SELECT PayerShare FROM dbo.fn_Ipd_PayerShare(occ.AdmissionId, lt.Net) WHERE occ.AdmissionId IS NOT NULL) ps   -- 2541
    WHERE b.IsActive = 1 AND b.BranchId = @BranchId AND w.IsActive = 1 AND r.IsActive = 1
    ORDER BY bl.BuildingName, f.FloorName, w.WardName, r.RoomNumber, b.BedNumber;
    -- 2 housekeeping staff of the branch (Master > Housekeeping > Staff)
    SELECT DISTINCT u.Id AS UserId, COALESCE(u.FullName, u.Username) AS Name
    FROM dbo.HKStaffMaster s JOIN dbo.Users u ON u.Id = s.Staff_ID AND u.IsActive = 1
    WHERE s.Branch_ID = @BranchId AND s.Status = 1 ORDER BY Name;
    -- 3 reservations of the last 7 days and the coming ones
    SELECT x.ReservationId, x.BedId, b.BedNumber, w.WardName, x.PatientId, x.PatientName, x.Phone, x.ExpectedAdmitAt, x.ReservedUntil, x.Status, x.Remarks,
           x.CloseReason, a.IpNo, d.FullName AS DoctorName, u.FullName AS CreatedByName, x.CreatedDate
    FROM dbo.IpdBedReservation x JOIN dbo.BedMaster b ON b.BedId = x.BedId JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.IpdAdmission a ON a.AdmissionId = x.AdmissionId LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = x.DoctorId LEFT JOIN dbo.Users u ON u.Id = x.CreatedBy
    WHERE x.BranchId = @BranchId AND (x.Status = 'ACTIVE' OR x.CreatedDate >= DATEADD(DAY, -7, @now))
    ORDER BY CASE WHEN x.Status = 'ACTIVE' THEN 0 ELSE 1 END, x.ExpectedAdmitAt DESC;
    -- 4 cleaning jobs: open ones and those finished today
    SELECT c.CleaningTaskId, c.BedId, b.BedNumber, w.WardName, r.RoomNumber, c.Reason, c.CleaningType, c.SlaMinutes, c.RequestedAt, c.StartedAt, c.CompletedAt, c.Status,
           u.FullName AS StaffName, cb.FullName AS CompletedByName, DATEDIFF(MINUTE, c.RequestedAt, ISNULL(c.CompletedAt, @now)) AS Minutes,
           CAST(CASE WHEN DATEDIFF(MINUTE, c.RequestedAt, ISNULL(c.CompletedAt, @now)) > c.SlaMinutes THEN 1 ELSE 0 END AS BIT) AS Overdue
    FROM dbo.IpdBedCleaning c JOIN dbo.BedMaster b ON b.BedId = c.BedId JOIN dbo.WardMaster w ON w.WardId = b.WardId JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    LEFT JOIN dbo.Users u ON u.Id = c.AssignedUserId LEFT JOIN dbo.Users cb ON cb.Id = c.CompletedBy
    WHERE c.BranchId = @BranchId AND (c.IsOpen = 1 OR c.CompletedAt >= CAST(@now AS DATE))
    ORDER BY c.IsOpen DESC, c.RequestedAt;
END;
GO

-- ── usp_Api_IpdEstimate_DueList ──
-- All admitted patients with their live bill, advance and balance.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdEstimate_DueList @CompanyId INT, @BranchId INT, @WardId INT = NULL, @PayerType VARCHAR(12) = NULL, @Search NVARCHAR(100) = NULL,
    @OnlyAlerts BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N''); SET @PayerType = NULLIF(UPPER(@PayerType), '');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    ;WITH x AS
    (
        SELECT a.AdmissionId, a.IpNo, a.AdmissionAt, a.PayerType, a.Status, p.PatientCode, p.PhoneNumber,
               LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, p.Gender,
               dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(@now AS DATE)) AS AgeText, b.BedNumber, w.WardId, w.WardName, d.FullName AS ConsultantDoctorName,
               COALESCE(ins.Name, corp.Corporate_Name, sch.SchemeName) AS PayerName,
               DATEDIFF(DAY, a.AdmissionAt, @now) + 1 AS DayCount, lt.Net AS BillNow, lt.Days AS BedDays, lt.NoTariff, mo.NetAdvance, ps.PayerShare,
               ISNULL(s.IpdDepositAlertPercent, 80) AS Pct
        FROM dbo.IpdAdmission a
        JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
        LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
        LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
        LEFT JOIN dbo.IpdAdmissionPayer py ON py.AdmissionId = a.AdmissionId AND py.Seq = 1
        LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = py.InsuranceTpaId
        LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = py.CorporateId
        LEFT JOIN dbo.GovernmentSchemeMaster sch ON sch.Scheme_ID = py.SchemeId
        LEFT JOIN dbo.HospitalSettings s ON s.BranchID = a.BranchId
        CROSS APPLY dbo.fn_Ipd_LiveTotal(a.AdmissionId, @now) lt
        CROSS APPLY dbo.fn_Ipd_Money(a.AdmissionId) mo
        CROSS APPLY dbo.fn_Ipd_PayerShare(a.AdmissionId, lt.Net) ps   -- 2541
        WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId AND a.IsOpen = 1
          AND (@WardId IS NULL OR b.WardId = @WardId) AND (@PayerType IS NULL OR a.PayerType = @PayerType)
          AND (@Search IS NULL OR a.IpNo LIKE @like OR p.PatientCode LIKE @like OR p.PhoneNumber LIKE @like OR b.BedNumber LIKE @like
               OR CONCAT(p.FirstName, ' ', p.LastName) LIKE @like)
    )
    SELECT x.AdmissionId, x.IpNo, x.AdmissionAt, x.PayerType, x.PayerName, x.Status, x.PatientCode, x.PhoneNumber, x.PatientName, x.Gender, x.AgeText,
           x.BedNumber, x.WardId, x.WardName, x.ConsultantDoctorName, x.DayCount, x.BedDays, x.BillNow, x.NetAdvance, x.NoTariff,
           CAST(x.BillNow - x.PayerShare - x.NetAdvance AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN x.PayerType = 'CASH' AND (x.BillNow > x.NetAdvance OR (x.NetAdvance > 0 AND x.BillNow >= x.NetAdvance * x.Pct / 100.0)) THEN 1 ELSE 0 END AS BIT) AS DepositAlert
    FROM x
    WHERE ISNULL(@OnlyAlerts, 0) = 0 OR (x.PayerType = 'CASH' AND (x.BillNow > x.NetAdvance OR (x.NetAdvance > 0 AND x.BillNow >= x.NetAdvance * x.Pct / 100.0)))
    ORDER BY x.BillNow - x.PayerShare - x.NetAdvance DESC, x.IpNo;
END;
GO

-- ── usp_Api_IpdAdmission_List ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_List
    @CompanyId INT, @BranchId INT, @Status VARCHAR(20) = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL, @Search NVARCHAR(100) = NULL,
    @WardId INT = NULL, @PayerType VARCHAR(12) = NULL, @Page INT = 1, @PageSize INT = 25,
    @ConsultantId INT = NULL, @DepartmentId INT = NULL, @Flag VARCHAR(20) = NULL, @Sort VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N''); SET @Page = CASE WHEN @Page < 1 THEN 1 ELSE @Page END;
    SET @PageSize = CASE WHEN @PageSize < 1 THEN 25 WHEN @PageSize > 2000 THEN 2000 ELSE @PageSize END;
    SET @Status = NULLIF(UPPER(@Status), ''); SET @PayerType = NULLIF(UPPER(@PayerType), '');
    SET @Flag = NULLIF(UPPER(@Flag), ''); SET @Sort = ISNULL(NULLIF(UPPER(@Sort), ''), 'ADMITTED_DESC');
    SET @ConsultantId = NULLIF(@ConsultantId, 0); SET @DepartmentId = NULLIF(@DepartmentId, 0); SET @WardId = NULLIF(@WardId, 0);
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @now DATETIME = GETDATE(), @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @pct DECIMAL(9,2) = ISNULL((SELECT TOP 1 IpdDepositAlertPercent FROM dbo.HospitalSettings WHERE BranchID = @BranchId ORDER BY IsActive DESC), 80);
    DECLARE @hasIndent BIT = CASE WHEN OBJECT_ID('dbo.IpdPhIndent', 'U') IS NOT NULL THEN 1 ELSE 0 END;

    CREATE TABLE #x (AdmissionId INT PRIMARY KEY, IpNo NVARCHAR(40), Status VARCHAR(20), IsOpen BIT, AdmissionAt DATETIME, AdmissionType VARCHAR(20), PayerType VARCHAR(12),
                     DischargeAt DATETIME, ExpectedDischargeAt DATETIME, PatientId INT, PatientCode NVARCHAR(50), PatientName NVARCHAR(300), Gender NVARCHAR(20), PhoneNumber NVARCHAR(30),
                     AgeText NVARCHAR(30), BedNumber NVARCHAR(50), WardName NVARCHAR(150), IsIcu BIT, ConsultantDoctorId INT, ConsultantDoctorName NVARCHAR(200),
                     DepartmentName NVARCHAR(150), TariffCategoryName NVARCHAR(150), PackageName NVARCHAR(250), IsMlc BIT, DayCount INT,
                     BillNow DECIMAL(18,2) NULL, NetAdvance DECIMAL(18,2) NULL, OpenIndents INT NULL, PayerShare DECIMAL(18,2) NULL);
    INSERT #x
    SELECT a.AdmissionId, a.IpNo, a.Status, a.IsOpen, a.AdmissionAt, a.AdmissionType, a.PayerType, a.DischargeAt, a.ExpectedDischargeAt, p.PatientId, p.PatientCode,
           LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))), p.Gender, p.PhoneNumber,
           dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(GETDATE() AS DATE)), b.BedNumber, w.WardName, CAST(ISNULL(b.IsICU, 0) AS BIT),
           a.ConsultantDoctorId, d.FullName, dep.DeptName, tc.Name, pk.Package_Name, CAST(ISNULL(a.IsMlc, 0) AS BIT),
           DATEDIFF(DAY, a.AdmissionAt, ISNULL(a.DischargeAt, @now)) + 1, NULL, NULL, NULL, NULL
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
    LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = a.DepartmentId
    LEFT JOIN dbo.TariffCategoryMaster tc ON tc.TariffCategoryId = a.TariffCategoryId
    LEFT JOIN dbo.HospitalPackageMaster pk ON pk.HospitalPackage_ID = a.PackageId
    WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId
      AND (@Status IS NULL OR (@Status = 'OPEN' AND a.IsOpen = 1) OR a.Status = @Status)
      AND (@FromDate IS NULL OR a.AdmissionAt >= @FromDate) AND (@ToDate IS NULL OR a.AdmissionAt < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)))
      AND (@WardId IS NULL OR b.WardId = @WardId) AND (@PayerType IS NULL OR a.PayerType = @PayerType)
      AND (@ConsultantId IS NULL OR a.ConsultantDoctorId = @ConsultantId) AND (@DepartmentId IS NULL OR a.DepartmentId = @DepartmentId)
      AND (@Flag IS NULL OR @Flag IN ('LOW_DEPOSIT', 'DUE', 'INDENT')
           OR (@Flag = 'ICU' AND ISNULL(b.IsICU, 0) = 1) OR (@Flag = 'MLC' AND ISNULL(a.IsMlc, 0) = 1) OR (@Flag = 'PACKAGE' AND a.PackageId IS NOT NULL)
           OR (@Flag = 'DISCHARGE_DUE' AND a.IsOpen = 1 AND a.ExpectedDischargeAt < DATEADD(DAY, 1, CAST(@today AS DATETIME))))
      AND (@Search IS NULL OR a.IpNo LIKE @like OR p.PatientCode LIKE @like OR p.PhoneNumber LIKE @like OR b.BedNumber LIKE @like OR w.WardName LIKE @like
           OR d.FullName LIKE @like OR CONCAT(p.FirstName, ' ', p.MiddleName, ' ', p.LastName) LIKE @like OR CONCAT(p.FirstName, ' ', p.LastName) LIKE @like);

    -- money for every row only when the sort / filter needs it (a branch's in-hospital list is small)
    DECLARE @allMoney BIT = CASE WHEN @Sort IN ('BALANCE_DESC', 'BILL_DESC') OR @Flag IN ('LOW_DEPOSIT', 'DUE') THEN 1 ELSE 0 END;
    IF @allMoney = 1
        UPDATE x SET BillNow = CASE WHEN x.Status = 'CANCELLED' THEN 0 ELSE lt.Net END, NetAdvance = mo.NetAdvance, PayerShare = ps.PayerShare
        FROM #x x OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(x.AdmissionId, @now)) lt CROSS APPLY dbo.fn_Ipd_Money(x.AdmissionId) mo
        CROSS APPLY dbo.fn_Ipd_PayerShare(x.AdmissionId, lt.Net) ps;
    IF @Flag = 'DUE' DELETE #x WHERE NOT (IsOpen = 1 AND ISNULL(BillNow, 0) - ISNULL(PayerShare, 0) - ISNULL(NetAdvance, 0) > 0);
    IF @Flag = 'LOW_DEPOSIT' DELETE #x WHERE NOT (IsOpen = 1 AND PayerType = 'CASH' AND (BillNow > NetAdvance OR (NetAdvance > 0 AND BillNow >= NetAdvance * @pct / 100.0)));
    IF @Flag = 'INDENT' AND @hasIndent = 1
        EXEC (N'DELETE x FROM #x x WHERE NOT EXISTS (SELECT 1 FROM dbo.IpdPhIndent i WHERE i.AdmissionId = x.AdmissionId AND i.Status IN (''PENDING'', ''PARTIAL''))');

    DECLARE @total INT = (SELECT COUNT(*) FROM #x);
    CREATE TABLE #pg (AdmissionId INT PRIMARY KEY, RowNo INT);
    INSERT #pg (AdmissionId, RowNo)
    SELECT AdmissionId, rn FROM (
        SELECT AdmissionId, ROW_NUMBER() OVER (ORDER BY
            CASE WHEN @Sort = 'BALANCE_DESC' THEN ISNULL(BillNow, 0) - ISNULL(PayerShare, 0) - ISNULL(NetAdvance, 0) END DESC,
            CASE WHEN @Sort = 'BILL_DESC' THEN BillNow END DESC,
            CASE WHEN @Sort = 'DAYS_DESC' THEN DayCount END DESC,
            CASE WHEN @Sort = 'NAME' THEN PatientName END ASC,
            CASE WHEN @Sort = 'BED' THEN ISNULL(WardName, N'~') END ASC, CASE WHEN @Sort = 'BED' THEN BedNumber END ASC,
            CASE WHEN @Sort = 'IPNO' THEN IpNo END DESC,
            CASE WHEN @Sort = 'ADMITTED_ASC' THEN AdmissionAt END ASC,
            AdmissionAt DESC, AdmissionId DESC) AS rn
        FROM #x) s
    WHERE rn > (@Page - 1) * @PageSize AND rn <= @Page * @PageSize;

    IF @allMoney = 0
        UPDATE x SET BillNow = CASE WHEN x.Status = 'CANCELLED' THEN NULL ELSE lt.Net END, NetAdvance = mo.NetAdvance, PayerShare = ps.PayerShare
        FROM #x x JOIN #pg g ON g.AdmissionId = x.AdmissionId
        OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(x.AdmissionId, @now)) lt CROSS APPLY dbo.fn_Ipd_Money(x.AdmissionId) mo
        CROSS APPLY dbo.fn_Ipd_PayerShare(x.AdmissionId, lt.Net) ps;
    IF @hasIndent = 1
        EXEC (N'UPDATE x SET OpenIndents = (SELECT COUNT(*) FROM dbo.IpdPhIndent i WHERE i.AdmissionId = x.AdmissionId AND i.Status IN (''PENDING'', ''PARTIAL''))
                FROM #x x JOIN #pg g ON g.AdmissionId = x.AdmissionId');

    SELECT x.AdmissionId, x.IpNo, x.Status, x.IsOpen, x.AdmissionAt, x.AdmissionType, x.PayerType, x.DischargeAt, x.ExpectedDischargeAt, x.PatientId, x.PatientCode,
           x.PatientName, x.Gender, x.PhoneNumber, x.AgeText, x.BedNumber, x.WardName, x.IsIcu, x.ConsultantDoctorId, x.ConsultantDoctorName, x.DepartmentName,
           x.TariffCategoryName, x.PackageName, x.IsMlc, x.DayCount, x.BillNow, x.NetAdvance,
           CAST(CASE WHEN x.Status = 'CANCELLED' THEN NULL ELSE ISNULL(x.BillNow, 0) - ISNULL(x.PayerShare, 0) - ISNULL(x.NetAdvance, 0) END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN ISNULL(x.BillNow, 0) > 0 THEN ROUND(ISNULL(x.NetAdvance, 0) * 100.0 / x.BillNow, 0) END AS INT) AS AdvanceCoverPct,
           CAST(CASE WHEN x.IsOpen = 1 AND x.PayerType = 'CASH' AND (x.BillNow > x.NetAdvance OR (x.NetAdvance > 0 AND x.BillNow >= x.NetAdvance * @pct / 100.0)) THEN 1 ELSE 0 END AS BIT) AS DepositAlert,
           CAST(CASE WHEN x.IsOpen = 1 AND x.ExpectedDischargeAt < CAST(@today AS DATETIME) THEN 1 ELSE 0 END AS BIT) AS DischargeOverdue,
           CAST(CASE WHEN x.IsOpen = 1 AND x.ExpectedDischargeAt >= CAST(@today AS DATETIME) AND x.ExpectedDischargeAt < DATEADD(DAY, 1, CAST(@today AS DATETIME)) THEN 1 ELSE 0 END AS BIT) AS DischargeToday,
           CAST(CASE WHEN CAST(x.AdmissionAt AS DATE) = @today THEN 1 ELSE 0 END AS BIT) AS AdmittedToday,
           ISNULL(x.OpenIndents, 0) AS OpenIndents
    FROM #x x JOIN #pg g ON g.AdmissionId = x.AdmissionId
    ORDER BY g.RowNo;

    SELECT @total AS Total;

    -- summary tiles (whole branch, not the filter)
    ;WITH o AS (SELECT a.AdmissionId, a.PayerType, a.Status, a.IsMlc, a.ExpectedDischargeAt, ISNULL(b.IsICU, 0) AS IsIcu, a.AdmissionAt
                FROM dbo.IpdAdmission a LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
                WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId AND a.IsOpen = 1),
          m AS (SELECT o.*, lt.Net AS BillNow, mo.NetAdvance, ps.PayerShare FROM o OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(o.AdmissionId, @now)) lt CROSS APPLY dbo.fn_Ipd_Money(o.AdmissionId) mo
                CROSS APPLY dbo.fn_Ipd_PayerShare(o.AdmissionId, lt.Net) ps)
    SELECT COUNT(*) AS InHospital,
           SUM(CASE WHEN CAST(AdmissionAt AS DATE) = @today THEN 1 ELSE 0 END) AS AdmittedToday,
           SUM(CASE WHEN Status = 'DISCHARGE_ADVISED' THEN 1 ELSE 0 END) AS DischargeAdvised,
           SUM(CASE WHEN IsIcu = 1 THEN 1 ELSE 0 END) AS InIcu,
           SUM(CASE WHEN ISNULL(IsMlc, 0) = 1 THEN 1 ELSE 0 END) AS Mlc,
           SUM(CASE WHEN PayerType = 'CASH' AND (BillNow > NetAdvance OR (NetAdvance > 0 AND BillNow >= NetAdvance * @pct / 100.0)) THEN 1 ELSE 0 END) AS DepositAlerts,
           CAST(SUM(CASE WHEN ISNULL(BillNow, 0) - ISNULL(PayerShare, 0) - ISNULL(NetAdvance, 0) > 0 THEN ISNULL(BillNow, 0) - ISNULL(PayerShare, 0) - ISNULL(NetAdvance, 0) ELSE 0 END) AS DECIMAL(18,2)) AS TotalDue,
           SUM(CASE WHEN ExpectedDischargeAt < DATEADD(DAY, 1, CAST(@today AS DATETIME)) THEN 1 ELSE 0 END) AS DischargeDue,
           (SELECT COUNT(*) FROM dbo.IpdAdmission d WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId AND d.DischargeAt >= @today AND d.DischargeAt < DATEADD(DAY, 1, CAST(@today AS DATETIME))) AS DischargedToday
    FROM m;

    -- filter lookups
    SELECT w.WardId AS Id, w.WardName AS Name FROM dbo.WardMaster w WHERE w.BranchId = @BranchId AND ISNULL(w.IsActive, 1) = 1 ORDER BY w.WardName;
    SELECT DISTINCT d.DoctorId AS Id, d.FullName AS Name FROM dbo.IpdAdmission a JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
     WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId ORDER BY d.FullName;
    SELECT DISTINCT dep.DeptId AS Id, dep.DeptName AS Name FROM dbo.IpdAdmission a JOIN dbo.DepartmentMaster dep ON dep.DeptId = a.DepartmentId
     WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId ORDER BY dep.DeptName;
END;
GO

PRINT 'Script 2541 applied: IPD payer split on the bill, claim, patient balances.';
GO
