-- 2571: IPD flow-gap fixes - billing and money (2026-11-28). Needs 2570. Run after 2541 / 2479 (it REPLACES
-- usp_Ipd_PostAdvance, usp_Api_IpdAdvance_Add, usp_Api_IpdAdvance_Refund, usp_Api_IpdBill_Finalise, usp_Api_IpdBill_Preview,
-- usp_Api_IpdBill_Get, fn_Ipd_SettleCalc, fn_Ipd_PreAuthAuthorised, fn_Ipd_PayerShare): re-run 2571 (and 2575) after any of
-- 2423 / 2434 / 2479 / 2541. Safe to re-run.
--   A1  a credit-discharged (or TPA-disallowed) balance can be collected after the discharge; IPD > Credit Dues
--   A3  the final bill refuses work done but not charged (fn_Ipd_FinalBillBlockers; 2575 adds MLC)
--   A4  the final bill comes after the discharge advice (Hospital Settings IpdFinalBillNeedsAdvice, default on)
--   A5  interim bill print (usp_Api_IpdBill_Interim)
--   A6  supplementary bill / credit note after the discharge (IpdBillAdjustment), refunds after the discharge
--   A7  discount above IpdDiscountLimitPercent (default 10 %) needs IPD Patient > High discount (DISCOUNT_HIGH)
--   A8  pre-auth alert (fn_Ipd_PreAuthAlert, used by the banner in 2575)
--   A9  room-rent eligibility: proportionate deduction moved to non-payable (fn_Ipd_PropDeduction)
--   C8  reopen a gate pass (usp_Api_IpdDischarge_Reopen)
-- Errors 59600-59699.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── supplementary bills / credit notes of an admission (ACTIVE only) ─────────────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PostBillAdj (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT CAST(ISNULL(SUM(CASE WHEN Kind = 'SUPP' THEN Net END), 0) AS DECIMAL(18,2)) AS SuppNet,
           CAST(ISNULL(SUM(CASE WHEN Kind = 'CRED' THEN Net END), 0) AS DECIMAL(18,2)) AS CreditNet,
           CAST(ISNULL(SUM(CASE WHEN Kind = 'SUPP' THEN Net ELSE -Net END), 0) AS DECIMAL(18,2)) AS AdjNet
    FROM dbo.IpdBillAdjustment WHERE AdmissionId = @AdmissionId AND Status = 'ACTIVE'
);
GO

-- the settlement figures: the bill's patient share + supplementary bills - credit notes - everything credited
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
          CROSS APPLY (SELECT CAST(ISNULL((SELECT b.Net - b.PayerShare + b.PayerToPatient FROM dbo.IpdBill b WHERE b.BillId = a.BillId), 0)
                                   + (SELECT AdjNet FROM dbo.fn_Ipd_PostBillAdj(a.AdmissionId))
                                   - (SELECT NetAdvance FROM dbo.fn_Ipd_Money(a.AdmissionId)) AS DECIMAL(18,2)) AS Due) d
          WHERE a.AdmissionId = @AdmissionId AND a.BillId IS NOT NULL) x
);
GO

-- ── A9: room-rent eligibility (IRDAI proportionate deduction) ────────────────────────────────────────────────
-- Room rent of a day = the Bed & Nursing lines of that day (room, bed, nursing, RMO, attendant, isolation); ICU rent = the ICU
-- lines of the day. Above the approved limit per day the excess is not payable, and the associated charges (doctor visits,
-- procedures, OT, other services) are paid in the same proportion as the room rent. Medicines, consumables, implants, LAB and
-- radiology are never cut. 0 when the approval has no limit.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PropDeduction (@AdmissionId INT, @AsOf DATETIME, @RoomLimit DECIMAL(18,2), @IcuLimit DECIMAL(18,2))
RETURNS TABLE
AS RETURN
(
    WITH l AS (SELECT Head, DayNo, Net, IsPackageItem FROM dbo.fn_Ipd_BillLines(@AdmissionId, @AsOf)
               WHERE (ISNULL(@RoomLimit, 0) > 0 OR ISNULL(@IcuLimit, 0) > 0) AND ISNULL(IsPackageItem, 0) = 0),
         rd AS (SELECT Head, DayNo, SUM(Net) AS Rent FROM l WHERE Head IN ('BED', 'ICU') AND DayNo IS NOT NULL GROUP BY Head, DayNo),
         rs AS (SELECT CAST(ISNULL(SUM(CASE WHEN Head = 'BED' THEN Rent END), 0) AS DECIMAL(18,2)) AS RoomTotal,
                       CAST(ISNULL(SUM(CASE WHEN Head = 'BED' AND ISNULL(@RoomLimit, 0) > 0 AND Rent > @RoomLimit THEN Rent - @RoomLimit END), 0) AS DECIMAL(18,2)) AS RoomExcess,
                       CAST(ISNULL(SUM(CASE WHEN Head = 'ICU' THEN Rent END), 0) AS DECIMAL(18,2)) AS IcuTotal,
                       CAST(ISNULL(SUM(CASE WHEN Head = 'ICU' AND ISNULL(@IcuLimit, 0) > 0 AND Rent > @IcuLimit THEN Rent - @IcuLimit END), 0) AS DECIMAL(18,2)) AS IcuExcess
                FROM rd),
         asc1 AS (SELECT CAST(ISNULL(SUM(Net), 0) AS DECIMAL(18,2)) AS Associated FROM l WHERE Head IN ('DOCTOR', 'PROCEDURE', 'OT', 'SERVICE'))
    SELECT rs.RoomTotal, rs.RoomExcess, rs.IcuTotal, rs.IcuExcess, a.Associated,
           CAST(CASE WHEN rs.RoomTotal + rs.IcuTotal > 0 THEN 1 - (rs.RoomExcess + rs.IcuExcess) / (rs.RoomTotal + rs.IcuTotal) ELSE 1 END AS DECIMAL(9,6)) AS Ratio,
           CAST(ROUND(a.Associated * CASE WHEN rs.RoomTotal + rs.IcuTotal > 0 THEN (rs.RoomExcess + rs.IcuExcess) / (rs.RoomTotal + rs.IcuTotal) ELSE 0 END, 2) AS DECIMAL(18,2)) AS AssociatedCut,
           CAST(rs.RoomExcess + rs.IcuExcess
                + ROUND(a.Associated * CASE WHEN rs.RoomTotal + rs.IcuTotal > 0 THEN (rs.RoomExcess + rs.IcuExcess) / (rs.RoomTotal + rs.IcuTotal) ELSE 0 END, 2) AS DECIMAL(18,2)) AS Deduction
    FROM rs CROSS JOIN asc1 a
);
GO

-- the authorised amount of an admission's live pre-auth (+ 2571 room-rent limits)
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PreAuthAuthorised (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT TOP 1 pa.PreAuthId, pa.InsuranceTpaId, pa.PreAuthNo, pa.Status,
           CAST(CASE WHEN pa.Status = 'FINAL_APPROVED' THEN ISNULL(pa.FinalApprovedAmount, 0) ELSE pa.ApprovedAmount END AS DECIMAL(18,2)) AS Authorised,
           pa.CoPayPercent, pa.Deductible, pa.NonPayable, pa.RoomRentLimit, pa.IcuRentLimit
    FROM dbo.IpdPreAuth pa
    WHERE pa.AdmissionId = @AdmissionId AND pa.IsLive = 1
      AND pa.Status IN ('APPROVED', 'ENHANCE_REQUESTED', 'FINAL_REQUESTED', 'FINAL_APPROVED', 'QUERY')
      AND (pa.ApprovedAmount > 0 OR ISNULL(pa.FinalApprovedAmount, 0) > 0)
    ORDER BY pa.PreAuthId DESC
);
GO

-- what the payer pays of an admission (always one row) - 2571: the live split also takes the proportionate deduction
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PayerShare (@AdmissionId INT, @Net DECIMAL(18,2))
RETURNS TABLE
AS RETURN
(
    SELECT CAST(ISNULL(CASE WHEN bl.BillId IS NOT NULL THEN bl.PayerShare - bl.PayerToPatient
                            WHEN a.PayerType = 'INSURANCE' AND a.BillId IS NULL THEN sp.PayerShare END, 0) AS DECIMAL(18,2)) AS PayerShare,
           pa.Authorised AS ApprovedAmount
    FROM (SELECT 1 AS One) o
    LEFT JOIN dbo.IpdAdmission a ON a.AdmissionId = @AdmissionId
    LEFT JOIN dbo.IpdBill bl ON bl.BillId = a.BillId AND bl.Status = 'FINAL'
    OUTER APPLY (SELECT TOP 1 Authorised, CoPayPercent, Deductible, NonPayable, RoomRentLimit, IcuRentLimit FROM dbo.fn_Ipd_PreAuthAuthorised(@AdmissionId)) pa
    OUTER APPLY (SELECT d.Deduction FROM dbo.fn_Ipd_PropDeduction(@AdmissionId, GETDATE(), pa.RoomRentLimit, pa.IcuRentLimit) d
                 WHERE a.BillId IS NULL AND (ISNULL(pa.RoomRentLimit, 0) > 0 OR ISNULL(pa.IcuRentLimit, 0) > 0)) pd
    OUTER APPLY dbo.fn_Ipd_PayerSplit(@Net, pa.Authorised, pa.CoPayPercent, pa.Deductible, ISNULL(pa.NonPayable, 0) + ISNULL(pd.Deduction, 0)) sp
);
GO

-- ── A8: the running bill near / over the approved amount (insurance, before the final bill) ─────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PreAuthAlert (@AdmissionId INT, @Net DECIMAL(18,2))
RETURNS TABLE
AS RETURN
(
    SELECT CAST(CASE WHEN a.PayerType = 'INSURANCE' AND a.BillId IS NULL AND a.IsOpen = 1 AND ISNULL(pa.Authorised, 0) > 0
                      AND ISNULL(@Net, 0) >= pa.Authorised * gs.PreAuthAlertPercent / 100.0 THEN 1 ELSE 0 END AS BIT) AS PreAuthAlert,
           CAST(CASE WHEN ISNULL(pa.Authorised, 0) > 0 THEN ROUND(ISNULL(@Net, 0) * 100.0 / pa.Authorised, 0) END AS INT) AS PreAuthUsedPercent,
           pa.Authorised AS PreAuthApproved, gs.PreAuthAlertPercent,
           CAST(CASE WHEN ISNULL(pa.Authorised, 0) > 0 AND ISNULL(@Net, 0) > pa.Authorised THEN ISNULL(@Net, 0) - pa.Authorised ELSE 0 END AS DECIMAL(18,2)) AS PreAuthOverBy
    FROM dbo.IpdAdmission a
    CROSS APPLY dbo.fn_Ipd_GapSettings(a.BranchId) gs
    OUTER APPLY (SELECT TOP 1 Authorised FROM dbo.fn_Ipd_PreAuthAuthorised(@AdmissionId)) pa
    WHERE a.AdmissionId = @AdmissionId
);
GO

-- ── A3: work done but not charged - the final bill waits for it (2575 adds the MLC rule) ─────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_FinalBillBlockers (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT 10 AS Sort, 'OT' AS Kind, CAST(CONCAT(N'Surgery ', o.BookingNo, N' is completed but its OT charges are not posted: post them on the OT tab.') AS NVARCHAR(400)) AS Message
    FROM dbo.IpdOtBooking o
    WHERE o.AdmissionId = @AdmissionId AND o.Status = 'COMPLETED'
      AND NOT EXISTS (SELECT 1 FROM dbo.IpdCharge c WHERE c.RefKind = 'OTB' AND c.RefId = o.OtBookingId AND c.Status = 'POSTED')
    UNION ALL
    SELECT 20, 'OT', CAST(CONCAT(N'Surgery ', o.BookingNo, N' is scheduled or in progress: complete or cancel it first.') AS NVARCHAR(400))
    FROM dbo.IpdOtBooking o WHERE o.AdmissionId = @AdmissionId AND o.Status IN ('SCHEDULED', 'IN_OT')
    UNION ALL
    SELECT 30, 'INDENT', CAST(CONCAT(N'Medicine indent ', i.IndentNo, N' is still open: issue or cancel it on the Medicines tab.') AS NVARCHAR(400))
    FROM dbo.IpdPhIndent i WHERE i.AdmissionId = @AdmissionId AND i.Status IN ('PENDING', 'PARTIAL')
    UNION ALL
    SELECT 40, 'DEVICE', CAST(CONCAT(N'ICU device ', d.HeadName, N' is still running: stop it on the ICU tab (device days are billed up to the stop).') AS NVARCHAR(400))
    FROM dbo.IpdIcuDevice d WHERE d.AdmissionId = @AdmissionId AND d.Status = 'ACTIVE' AND d.StopAt IS NULL
    UNION ALL
    SELECT 50, 'ORDER', CAST(CONCAT(N'"', o.ServiceName, N'" is ordered and not marked done: mark it done (it is charged then) or cancel it on the Clinical tab.') AS NVARCHAR(400))
    FROM dbo.IpdOrder o WHERE o.AdmissionId = @AdmissionId AND o.OrderType = 'SERVICE' AND o.Status = 'ACTIVE' AND o.DoneAt IS NULL
);
GO

-- ── receipts (2479) + 2571: after the discharge against the final bill (A1), discount limit (A7) ─────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostAdvance
    @AdmissionId INT, @UserId INT, @Payments NVARCHAR(MAX), @Remarks NVARCHAR(300) = NULL,
    @AdvanceId INT OUTPUT, @ReceiptNo NVARCHAR(50) OUTPUT,
    @DiscType CHAR(1) = NULL, @DiscValue DECIMAL(18,2) = 0, @DiscReason NVARCHAR(300) = NULL, @RoundOff BIT = 0, @CanDiscount BIT = 0,
    @AdjustAmount DECIMAL(18,2) = NULL OUTPUT, @CanDiscountHigh BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @AdjustAmount = 0;
    SET @DiscType = NULLIF(UPPER(LTRIM(RTRIM(@DiscType))), '');
    SET @DiscValue = ISNULL(@DiscValue, 0);
    IF @DiscValue = 0 SET @DiscType = NULL;
    IF @DiscType IS NOT NULL AND @DiscType NOT IN ('P', 'A') THROW 54112, 'Choose the discount as a percentage or an amount.', 1;
    IF @DiscValue < 0 THROW 54113, 'The discount cannot be negative.', 1;
    IF @DiscType = 'P' AND @DiscValue > 100 THROW 54114, 'The discount cannot be more than 100%.', 1;

    DECLARE @Pay TABLE (Seq INT IDENTITY(1,1), Method VARCHAR(20), Amount DECIMAL(18,4), Ref NVARCHAR(100), MethodId INT NULL);
    IF ISJSON(@Payments) = 1
        INSERT @Pay (Method, Amount, Ref)
        SELECT UPPER(LTRIM(RTRIM(j.Method))), j.Amount, NULLIF(LTRIM(RTRIM(j.Ref)), N'')
        FROM OPENJSON(@Payments) WITH (Method VARCHAR(20), Amount DECIMAL(18,4), Ref NVARCHAR(100)) j
        WHERE ISNULL(j.Amount, 0) <> 0;
    IF EXISTS (SELECT 1 FROM @Pay WHERE Amount < 0) THROW 54101, 'A payment amount cannot be negative.', 1;
    IF EXISTS (SELECT 1 FROM @Pay WHERE Amount <> ROUND(Amount, 2)) THROW 54102, 'A payment amount can have at most two decimals.', 1;
    UPDATE p SET MethodId = pm.PaymentMethodId FROM @Pay p JOIN dbo.PaymentMethodMaster pm ON UPPER(pm.MethodCode) = p.Method AND pm.IsActive = 1 AND UPPER(pm.MethodCode) <> 'POINTS';
    IF EXISTS (SELECT 1 FROM @Pay WHERE MethodId IS NULL) THROW 54103, 'Choose a valid payment mode for every amount entered.', 1;
    IF EXISTS (SELECT 1 FROM @Pay WHERE Method <> 'CASH' AND Ref IS NULL) THROW 54111, 'Enter the reference (UPI / card / NEFT / cheque no.) of every non-cash payment.', 1;
    DECLARE @total DECIMAL(18,2) = (SELECT ISNULL(SUM(Amount), 0) FROM @Pay);
    DECLARE @dupRef NVARCHAR(100) = (SELECT TOP 1 Ref FROM @Pay WHERE Ref IS NOT NULL GROUP BY Ref HAVING COUNT(*) > 1);
    IF @dupRef IS NOT NULL BEGIN DECLARE @m1 NVARCHAR(300) = N'Reference ' + @dupRef + N' is entered on more than one payment line.'; THROW 54105, @m1, 1; END;
    DECLARE @usedRef NVARCHAR(100), @usedRcpt NVARCHAR(50);
    SELECT TOP 1 @usedRef = p.Ref, @usedRcpt = pd.ReceiptNo
    FROM @Pay p JOIN dbo.PaymentDetail pd ON pd.IsActive = 1 AND p.Method <> 'CASH' AND p.Ref IS NOT NULL AND (pd.UPIRefNo = p.Ref OR pd.TransactionRef = p.Ref OR pd.ChequeNo = p.Ref);
    IF @usedRef IS NOT NULL
    BEGIN
        DECLARE @m2 NVARCHAR(400) = N'Reference ' + @usedRef + N' is already recorded on receipt ' + ISNULL(@usedRcpt, N'(no receipt no.)') + N'. The same UPI / bank transaction cannot be collected twice.';
        THROW 54106, @m2, 1;
    END;

    DECLARE @co INT, @br INT, @patient INT, @ip NVARCHAR(40), @open BIT, @status VARCHAR(20), @billId INT;
    SELECT @co = CompanyId, @br = BranchId, @patient = PatientId, @ip = IpNo, @open = IsOpen, @status = Status, @billId = BillId
    FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId;
    IF @ip IS NULL THROW 54107, 'The admission was not found.', 1;
    -- 2571 (A1): a discharged patient's balance (credit discharge, TPA disallowance, supplementary bill) is collected against the final bill
    IF @open = 0 AND NOT (@status = 'DISCHARGED' AND @billId IS NOT NULL)
        THROW 54108, 'The admission is closed: money can be taken only while the patient is admitted, or against the final bill of a discharged patient.', 1;
    DECLARE @kind VARCHAR(10) = CASE WHEN @billId IS NOT NULL THEN 'SETTLE' ELSE 'ADVANCE' END;
    DECLARE @disc DECIMAL(18,2) = 0, @ro DECIMAL(18,2) = 0, @due DECIMAL(18,2) = 0, @payable DECIMAL(18,2) = 0;
    IF @kind = 'ADVANCE'
    BEGIN
        IF @DiscType IS NOT NULL OR ISNULL(@RoundOff, 0) = 1
            THROW 54115, 'Discount and round off are given when the final bill is settled. An advance is a deposit: give the discount of the stay on the final bill.', 1;
        IF @total <= 0 THROW 54104, 'Enter the amount.', 1;
    END
    ELSE
    BEGIN
        SELECT @due = Due, @disc = Disc, @ro = RoundOff, @payable = Payable FROM dbo.fn_Ipd_SettleCalc(@AdmissionId, @DiscType, @DiscValue, @RoundOff);
        IF @due <= 0 THROW 54109, 'The final bill is fully paid: nothing is due.', 1;
        IF @disc > 0 AND ISNULL(@CanDiscount, 0) = 0 THROW 54116, 'You are not allowed to give a discount (IPD Patient > Discount permission).', 1;
        IF @disc > 0 AND NULLIF(LTRIM(RTRIM(@DiscReason)), N'') IS NULL THROW 54117, 'Enter the reason for the discount.', 1;
        -- 2571 (A7): above the branch's limit a user with High discount gives it
        DECLARE @lim DECIMAL(5,2) = (SELECT DiscountLimitPercent FROM dbo.fn_Ipd_GapSettings(@br));
        IF @disc > 0 AND ISNULL(@CanDiscountHigh, 0) = 0 AND @disc > ROUND(@due * @lim / 100.0, 2)
        BEGIN
            DECLARE @m5 NVARCHAR(300) = CONCAT(N'A discount above ', FORMAT(@lim, '0.##'), N'%% of the balance (₹', FORMAT(ROUND(@due * @lim / 100.0, 2), 'N2', 'en-IN'),
                                               N') needs a user with IPD Patient > High discount.');
            THROW 59601, @m5, 1;
        END
        IF @total > @payable
        BEGIN
            DECLARE @m3 NVARCHAR(300) = CONCAT(N'Only ₹', FORMAT(@payable, 'N2', 'en-IN'), N' is payable on the final bill', CASE WHEN @disc + @ro > 0 THEN N' after the discount / round off' ELSE N'' END, N'.');
            THROW 54110, @m3, 1;
        END
        IF @ro > 0 AND @total <> @payable
        BEGIN
            DECLARE @m4 NVARCHAR(300) = CONCAT(N'Round off applies only when the balance is paid in full: collect ₹', FORMAT(@payable, 'N2', 'en-IN'), N', or untick round off.');
            THROW 54118, @m4, 1;
        END
        IF @total <= 0 AND @disc + @ro <= 0 THROW 54104, 'Enter the amount.', 1;
    END

    DECLARE @headerId INT = NULL, @label NVARCHAR(40) = CASE WHEN @kind = 'SETTLE' THEN N'IPD bill settlement ' ELSE N'IPD advance ' END;
    SET @AdvanceId = NULL;
    IF @total > 0
    BEGIN
        INSERT dbo.PaymentHeader (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, LineDiscountTotal, HeaderDiscountType, HeaderDiscountValue, HeaderDiscountAmount,
               NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive, TotalCgstAmount, TotalSgstAmount, TotalIgstAmount, CompanyId, RoundOffAmount)
        VALUES ('IPD', @AdmissionId, @br, @patient, @total, 0, NULL, 0, 0, @total, @total, 0, 'P', LEFT(@label + @ip + ISNULL(N' - ' + @Remarks, N''), 500),
                GETDATE(), @UserId, 1, 0, 0, 0, @co, 0);
        SET @headerId = CAST(SCOPE_IDENTITY() AS INT);
        EXEC dbo.usp_Receipt_GetNextNo @BranchId = @br, @ReceiptNo = @ReceiptNo OUTPUT;

        DECLARE @s INT = (SELECT MIN(Seq) FROM @Pay), @pd INT, @lk VARCHAR(10) = CASE WHEN @kind = 'SETTLE' THEN 'SETTLERCPT' ELSE 'ADVRCPT' END;
        WHILE @s IS NOT NULL
        BEGIN
            INSERT dbo.PaymentDetail (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, UPIRefNo, CardLast4, ChequeNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo, CompanyId)
            SELECT @headerId, p.MethodId, p.Amount, CASE WHEN p.Method NOT IN ('UPI', 'CHEQUE') THEN p.Ref END, CASE WHEN p.Method = 'UPI' THEN p.Ref END,
                   CASE WHEN p.Method = 'CARD' AND LEN(p.Ref) >= 4 THEN RIGHT(p.Ref, 4) END, CASE WHEN p.Method = 'CHEQUE' THEN p.Ref END,
                   GETDATE(), LEFT(@label + @ip, 300), GETDATE(), @UserId, 1, @ReceiptNo, @co
            FROM @Pay p WHERE p.Seq = @s;
            SET @pd = CAST(SCOPE_IDENTITY() AS INT);
            EXEC dbo.usp_Ipd_PostLedger @Kind = @lk, @RefId = @pd, @UserId = @UserId;
            SET @s = (SELECT MIN(Seq) FROM @Pay WHERE Seq > @s);
        END

        INSERT dbo.IpdAdvance (AdmissionId, Kind, Amount, DocNo, PaymentHeaderId, Remarks, CreatedBy, BillId)
        VALUES (@AdmissionId, @kind, @total, @ReceiptNo, @headerId, @Remarks, @UserId, CASE WHEN @kind = 'SETTLE' THEN @billId END);
        SET @AdvanceId = CAST(SCOPE_IDENTITY() AS INT);
    END
    ELSE
    BEGIN
        DECLARE @adjAt DATETIME = GETDATE();
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @br, @DocType = 'ADJ', @DocDate = @adjAt, @DocNo = @ReceiptNo OUTPUT;
    END

    IF @kind = 'SETTLE' AND @disc + @ro > 0
    BEGIN
        INSERT dbo.IpdAdvance (AdmissionId, Kind, Amount, DocNo, PaymentHeaderId, Mode, Remarks, CreatedBy, DiscType, DiscValue, DiscAmount, RoundOff, AdjustOfAdvanceId, BillId)
        VALUES (@AdmissionId, 'ADJUST', @disc + @ro, @ReceiptNo, NULL,
                LEFT(CONCAT(CASE WHEN @disc > 0 THEN CONCAT(N'Discount ', CASE WHEN @DiscType = 'P' THEN FORMAT(@DiscValue, '0.##') + N'% ' ELSE N'' END, N'₹', FORMAT(@disc, 'N2', 'en-IN')) ELSE N'' END,
                            CASE WHEN @disc > 0 AND @ro > 0 THEN N' + ' ELSE N'' END, CASE WHEN @ro > 0 THEN N'Round off ₹' + FORMAT(@ro, 'N2', 'en-IN') ELSE N'' END), 100),
                LEFT(NULLIF(LTRIM(RTRIM(@DiscReason)), N''), 300), @UserId, @DiscType, CASE WHEN @disc > 0 THEN @DiscValue END, @disc, @ro, @AdvanceId, @billId);
        DECLARE @adjId INT = CAST(SCOPE_IDENTITY() AS INT);
        EXEC dbo.usp_Ipd_PostSettleAdjustLedger @AdvanceId = @adjId, @UserId = @UserId;
        IF @AdvanceId IS NULL SET @AdvanceId = @adjId;
        SET @AdjustAmount = @disc + @ro;
    END

    INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
    VALUES (@AdmissionId, @kind, CONCAT(CASE WHEN @kind = 'SETTLE' THEN N'Bill payment ₹' ELSE N'Advance ₹' END, FORMAT(@total, 'N2', 'en-IN'), N' received, receipt ', @ReceiptNo,
            CASE WHEN @open = 0 THEN N' (after the discharge)' ELSE N'' END,
            CASE WHEN @disc > 0 THEN CONCAT(N'; discount ₹', FORMAT(@disc, 'N2', 'en-IN'), ISNULL(N' (' + NULLIF(LTRIM(RTRIM(@DiscReason)), N'') + N')', N'')) ELSE N'' END,
            CASE WHEN @ro > 0 THEN CONCAT(N'; round off ₹', FORMAT(@ro, 'N2', 'en-IN')) ELSE N'' END), @UserId);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvance_Add @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Payments NVARCHAR(MAX), @Remarks NVARCHAR(300) = NULL,
    @DiscType CHAR(1) = NULL, @DiscValue DECIMAL(18,2) = 0, @DiscReason NVARCHAR(300) = NULL, @RoundOff BIT = 0, @CanDiscount BIT = 0, @CanDiscountHigh BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId)
            THROW 54401, 'The admission was not found in this branch.', 1;
        DECLARE @advId INT, @rcpt NVARCHAR(50), @adj DECIMAL(18,2);
        EXEC dbo.usp_Ipd_PostAdvance @AdmissionId = @AdmissionId, @UserId = @UserId, @Payments = @Payments, @Remarks = @Remarks, @AdvanceId = @advId OUTPUT, @ReceiptNo = @rcpt OUTPUT,
             @DiscType = @DiscType, @DiscValue = @DiscValue, @DiscReason = @DiscReason, @RoundOff = @RoundOff, @CanDiscount = @CanDiscount, @AdjustAmount = @adj OUTPUT,
             @CanDiscountHigh = @CanDiscountHigh;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @advId AS AdvanceId, @rcpt AS ReceiptNo, @adj AS Adjusted;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── refund (2541) + 2571: after the discharge, what a credit note left over-paid (Dr Patient Receivable) ─────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvance_Refund
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Amount DECIMAL(18,2), @Method VARCHAR(20), @RefNo NVARCHAR(100) = NULL, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54501, 'Enter the reason for the refund.', 1;
        IF ISNULL(@Amount, 0) <= 0 THROW 54502, 'Enter the refund amount.', 1;
        IF @Amount <> ROUND(@Amount, 2) THROW 54503, 'The refund amount can have at most two decimals.', 1;
        DECLARE @modeName NVARCHAR(100) = (SELECT MethodName FROM dbo.PaymentMethodMaster WHERE UPPER(MethodCode) = UPPER(@Method) AND IsActive = 1 AND UPPER(MethodCode) NOT IN ('POINTS', 'WALLET'));
        IF @modeName IS NULL THROW 54504, 'Choose how the refund is paid (cash, UPI, NEFT, cheque or card).', 1;
        DECLARE @status VARCHAR(20), @open BIT, @billId INT;
        SELECT @status = Status, @open = IsOpen, @billId = BillId FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL THROW 54505, 'The admission was not found in this branch.', 1;
        DECLARE @net DECIMAL(18,2) = (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId));
        DECLARE @bill DECIMAL(18,2), @max DECIMAL(18,2), @post BIT = 0;
        IF @open = 0 AND @status = 'DISCHARGED' AND @billId IS NOT NULL
        BEGIN
            -- after the discharge: only what is over-paid on the final bill (e.g. after a credit note)
            SELECT @bill = -Due FROM dbo.fn_Ipd_SettleCalc(@AdmissionId, NULL, 0, 0);
            SELECT @max = CASE WHEN @bill > 0 THEN @bill ELSE 0 END, @post = 1;
            SET @bill = @net - @max;
        END
        ELSE
        BEGIN
            SET @bill = CASE WHEN @status = 'CANCELLED' THEN 0 ELSE (SELECT lt.Net - ps.PayerShare FROM dbo.fn_Ipd_LiveTotal(@AdmissionId, @now) lt CROSS APPLY dbo.fn_Ipd_PayerShare(@AdmissionId, lt.Net) ps) END;
            SET @max = CASE WHEN @open = 1 OR @status = 'CANCELLED' THEN @net - @bill ELSE 0 END;
        END
        IF @max < 0 SET @max = 0;
        IF @Amount > @max
        BEGIN
            SET @msg = CONCAT(N'Refundable now: ₹', FORMAT(@max, 'N2', 'en-IN'), N' (paid ₹', FORMAT(@net, 'N2', 'en-IN'), N' less the bill ₹', FORMAT(@bill, 'N2', 'en-IN'), N').');
            THROW 54506, @msg, 1;
        END;
        DECLARE @no NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'REF', @DocDate = @now, @DocNo = @no OUTPUT;
        INSERT dbo.IpdAdvance (AdmissionId, Kind, Amount, DocNo, Mode, RefNo, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'REFUND', @Amount, @no, @modeName, NULLIF(LTRIM(RTRIM(@RefNo)), N''), LTRIM(RTRIM(@Reason)), @UserId);
        DECLARE @advId INT = CAST(SCOPE_IDENTITY() AS INT);
        IF @post = 1 EXEC dbo.usp_Ipd_PostAdjLedger @Kind = 'POSTREFUND', @RefId = @advId, @UserId = @UserId;
        ELSE EXEC dbo.usp_Ipd_PostLedger @Kind = 'ADVREFUND', @RefId = @advId, @UserId = @UserId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'REFUND', CONCAT(N'Refund ₹', FORMAT(@Amount, 'N2', 'en-IN'), N' by ', @modeName, N', voucher ', @no, CASE WHEN @post = 1 THEN N' (after the discharge)' ELSE N'' END,
                N': ', LTRIM(RTRIM(@Reason))), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @advId AS AdvanceId, @no AS DocNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── ledger of the documents after the final bill ─────────────────────────────────────────────────────────────
--   SUPP        supplementary bill: Dr Patient Receivable / Cr IPD Revenue + GST Output   (SLS, IPD_SUPPBILL)
--   CRED        credit note:        Dr IPD Revenue + GST Output / Cr Patient Receivable   (CN,  IPD_CREDITNOTE)
--   POSTREFUND  refund after the discharge: Dr Patient Receivable / Cr cash or bank        (PMT, IPD_POSTREFUND)
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostAdjLedger @Kind VARCHAR(10), @RefId INT, @UserId INT = NULL, @TransactionId BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @recv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable'),
            @rev INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'IPD Revenue'),
            @gstL INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'GST Output Payable'),
            @cash INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Cash Account'),
            @bank INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Bank Account');
    IF @recv IS NULL OR @rev IS NULL OR @gstL IS NULL THROW 59690, 'A ledger is missing (Patient Receivable, IPD Revenue, GST Output Payable).', 1;
    DECLARE @co INT, @br INT, @date DATETIME, @gross DECIMAL(18,2), @gst DECIMAL(18,2), @net DECIMAL(18,2), @no NVARCHAR(50), @ip NVARCHAR(40), @party NVARCHAR(250),
            @narr NVARCHAR(400), @lines NVARCHAR(MAX), @tid BIGINT, @vno NVARCHAR(50), @mode VARCHAR(30), @ref NVARCHAR(100), @modeLedger INT, @billNo NVARCHAR(40);
    SET @TransactionId = NULL;
    IF @Kind IN ('SUPP', 'CRED')
    BEGIN
        SELECT @co = j.CompanyId, @br = j.BranchId, @date = j.DocAt, @gross = j.Gross, @gst = j.Gst, @net = j.Net, @no = j.DocNo, @ip = a.IpNo, @billNo = b.BillNo,
               @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName)))
        FROM dbo.IpdBillAdjustment j JOIN dbo.IpdAdmission a ON a.AdmissionId = j.AdmissionId JOIN dbo.IpdBill b ON b.BillId = j.BillId
        JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        WHERE j.AdjId = @RefId AND j.Kind = @Kind;
        IF @no IS NULL OR @net <= 0 RETURN;
        SET @narr = CONCAT(CASE WHEN @Kind = 'SUPP' THEN N'IPD supplementary bill ' ELSE N'IPD credit note ' END, @no, N' (bill ', @billNo, N') - ', @ip, N' - ', @party);
        SET @lines = CASE WHEN @Kind = 'SUPP'
            THEN (SELECT LedgerId, Dr, Cr, Narration FROM (VALUES (@recv, @net, CAST(0 AS DECIMAL(18,2)), N'Supplementary bill'), (@rev, 0, @gross, N'IPD charges'),
                                                                  (@gstL, 0, @gst, N'GST')) v (LedgerId, Dr, Cr, Narration) WHERE Dr > 0 OR Cr > 0 FOR JSON PATH)
            ELSE (SELECT LedgerId, Dr, Cr, Narration FROM (VALUES (@rev, @gross, CAST(0 AS DECIMAL(18,2)), N'IPD charges credited'), (@gstL, @gst, 0, N'GST reversed'),
                                                              (@recv, 0, @net, N'Credit note to the patient')) v (LedgerId, Dr, Cr, Narration) WHERE Dr > 0 OR Cr > 0 FOR JSON PATH) END;
        DECLARE @vt VARCHAR(5) = CASE WHEN @Kind = 'SUPP' THEN 'SLS' ELSE 'CN' END, @rt NVARCHAR(30) = CASE WHEN @Kind = 'SUPP' THEN 'IPD_SUPPBILL' ELSE 'IPD_CREDITNOTE' END;
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = @vt, @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = @rt, @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @PaymentMode = NULL, @InstrumentNo = NULL, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
        UPDATE dbo.IpdBillAdjustment SET LedgerTxnId = @tid WHERE AdjId = @RefId;
    END
    ELSE IF @Kind = 'POSTREFUND'
    BEGIN
        SELECT @co = a.CompanyId, @br = a.BranchId, @date = v.CreatedDate, @net = v.Amount, @mode = UPPER(ISNULL(pm.MethodCode, v.Mode)), @ref = v.RefNo,
               @no = v.DocNo, @ip = a.IpNo, @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName)))
        FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        LEFT JOIN dbo.PaymentMethodMaster pm ON pm.MethodName = v.Mode OR UPPER(pm.MethodCode) = UPPER(v.Mode)
        WHERE v.AdvanceId = @RefId AND v.Kind = 'REFUND' AND v.IsActive = 1;
        IF @net IS NULL OR @net <= 0 RETURN;
        SET @modeLedger = dbo.fn_Acc_ModeLedger(@br, @mode, CASE WHEN @mode = 'CASH' THEN @cash ELSE @bank END);
        SET @narr = CONCAT(N'IPD refund after discharge ', @no, N' - ', @ip, N' - ', @party, N' (', @mode, ISNULL(N' ' + @ref, N''), N')');
        SET @lines = (SELECT * FROM (VALUES (@recv, @net, 0, N'Over-paid on the bill refunded'), (@modeLedger, 0, @net, N'Paid back by ' + @mode)) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'PMT', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'IPD_POSTREFUND', @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @PaymentMode = @mode, @InstrumentNo = @ref, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    SET @TransactionId = @tid;
END;
GO

-- ── A6: supplementary bill / credit note (only after the discharge: before it the bill is cancelled and made again) ──
-- @Lines: [{head, itemName, qty, rate, gstPercent, billLineId}] (a credit note may give one amount line).
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBillAdj_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Kind CHAR(4), @Lines NVARCHAR(MAX), @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        SET @Kind = UPPER(@Kind); SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
        IF @Kind NOT IN ('SUPP', 'CRED') THROW 59610, 'Choose supplementary bill or credit note.', 1;
        IF @Reason IS NULL THROW 59611, 'Enter the reason.', 1;
        DECLARE @status VARCHAR(20), @billId INT, @ip NVARCHAR(40);
        SELECT @status = Status, @billId = BillId, @ip = IpNo FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL THROW 59612, 'The admission was not found in this branch.', 1;
        IF @status <> 'DISCHARGED' OR @billId IS NULL
            THROW 59613, 'A supplementary bill or credit note is made after the discharge. Before it, cancel the final bill and bill again.', 1;
        DECLARE @L TABLE (Seq INT IDENTITY(1,1), Head VARCHAR(20), ItemName NVARCHAR(250), Qty DECIMAL(18,3), Rate DECIMAL(18,2), GstPercent DECIMAL(5,2), BillLineId INT,
                          Gross DECIMAL(18,2), GstAmount DECIMAL(18,2), Net DECIMAL(18,2));
        IF ISJSON(@Lines) = 1
            INSERT @L (Head, ItemName, Qty, Rate, GstPercent, BillLineId)
            SELECT UPPER(NULLIF(LTRIM(RTRIM(j.head)), '')), NULLIF(LTRIM(RTRIM(j.itemName)), N''), ISNULL(j.qty, 1), j.rate, ISNULL(j.gstPercent, 0), j.billLineId
            FROM OPENJSON(@Lines) WITH (head VARCHAR(20), itemName NVARCHAR(250), qty DECIMAL(18,3), rate DECIMAL(18,2), gstPercent DECIMAL(5,2), billLineId INT) j;
        IF NOT EXISTS (SELECT 1 FROM @L) THROW 59614, 'Add at least one line.', 1;
        IF EXISTS (SELECT 1 FROM @L l WHERE l.Head IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.fn_Ipd_Heads() h WHERE h.Head = l.Head AND h.Head NOT IN ('ADJUST', 'PACKAGE')))
            THROW 59615, 'Choose the bill head of every line.', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE ItemName IS NULL) THROW 59616, 'Enter the particulars of every line.', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE Qty <= 0 OR ISNULL(Rate, 0) <= 0) THROW 59617, 'Every line needs a quantity and a rate above 0.', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE GstPercent < 0 OR GstPercent > 28) THROW 59618, 'GST % must be between 0 and 28.', 1;
        IF EXISTS (SELECT 1 FROM @L l WHERE l.BillLineId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdBillLine b WHERE b.BillLineId = l.BillLineId AND b.BillId = @billId))
            THROW 59619, 'A bill line chosen is not on this patient''s final bill.', 1;
        UPDATE @L SET Gross = ROUND(Qty * Rate, 2), GstAmount = ROUND(ROUND(Qty * Rate, 2) * GstPercent / 100.0, 2), Net = ROUND(Qty * Rate, 2) + ROUND(ROUND(Qty * Rate, 2) * GstPercent / 100.0, 2);
        DECLARE @g DECIMAL(18,2) = (SELECT SUM(Gross) FROM @L), @gst DECIMAL(18,2) = (SELECT SUM(GstAmount) FROM @L), @n DECIMAL(18,2) = (SELECT SUM(Net) FROM @L);
        IF @Kind = 'CRED'
        BEGIN
            -- a credit note cannot credit more than the patient was billed (bill share + supplementary bills - earlier credit notes)
            DECLARE @billed DECIMAL(18,2) = (SELECT b.Net - b.PayerShare + b.PayerToPatient FROM dbo.IpdBill b WHERE b.BillId = @billId) + (SELECT AdjNet FROM dbo.fn_Ipd_PostBillAdj(@AdmissionId));
            IF @n > @billed
            BEGIN
                SET @msg = CONCAT(N'The credit note cannot be more than the patient''s bill left to credit (₹', FORMAT(@billed, 'N2', 'en-IN'), N').');
                THROW 59620, @msg, 1;
            END
        END
        DECLARE @no NVARCHAR(40), @dt VARCHAR(10) = CASE WHEN @Kind = 'SUPP' THEN 'IPS' ELSE 'ICN' END;
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = @dt, @DocDate = @now, @DocNo = @no OUTPUT;
        INSERT dbo.IpdBillAdjustment (CompanyId, BranchId, AdmissionId, BillId, Kind, DocNo, DocAt, Gross, Gst, Net, Reason, CreatedBy)
        VALUES (@CompanyId, @BranchId, @AdmissionId, @billId, @Kind, @no, @now, @g, @gst, @n, @Reason, @UserId);
        DECLARE @id INT = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.IpdBillAdjustmentLine (AdjId, Head, ItemName, Qty, Rate, Gross, GstPercent, GstAmount, Net, BillLineId)
        SELECT @id, Head, ItemName, Qty, Rate, Gross, GstPercent, GstAmount, Net, BillLineId FROM @L ORDER BY Seq;
        EXEC dbo.usp_Ipd_PostAdjLedger @Kind = @Kind, @RefId = @id, @UserId = @UserId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, CASE WHEN @Kind = 'SUPP' THEN 'SUPP_BILL' ELSE 'CREDIT_NOTE' END,
                CONCAT(CASE WHEN @Kind = 'SUPP' THEN N'Supplementary bill ' ELSE N'Credit note ' END, @no, N' ₹', FORMAT(@n, 'N2', 'en-IN'), N': ', @Reason), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS AdjId, @no AS DocNo, @n AS Net,
               (SELECT Due FROM dbo.fn_Ipd_SettleCalc(@AdmissionId, NULL, 0, 0)) AS BalanceNow;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBillAdj_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @AdjId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
        IF @Reason IS NULL THROW 59621, 'Enter the reason for cancelling.', 1;
        DECLARE @adm INT, @st VARCHAR(10), @kind CHAR(4), @no NVARCHAR(40), @txn BIGINT, @net DECIMAL(18,2);
        SELECT @adm = AdmissionId, @st = Status, @kind = Kind, @no = DocNo, @txn = LedgerTxnId, @net = Net
        FROM dbo.IpdBillAdjustment WITH (UPDLOCK) WHERE AdjId = @AdjId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @adm IS NULL THROW 59622, 'The document was not found in this branch.', 1;
        IF @st <> 'ACTIVE' THROW 59623, 'The document is already cancelled.', 1;
        -- a supplementary bill already paid cannot go: the payment would be left over
        IF @kind = 'SUPP' AND (SELECT Due FROM dbo.fn_Ipd_SettleCalc(@adm, NULL, 0, 0)) < @net
            THROW 59624, 'Part of this supplementary bill is already paid: refund or give a credit note instead.', 1;
        DECLARE @r BIGINT, @why NVARCHAR(300) = CONCAT(@no, N' cancelled: ', @Reason);
        IF @txn IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE TransactionId = @txn AND Status <> 'C')
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @txn, @Reason = @why, @UserId = @UserId, @ReversalId = @r OUTPUT;
        UPDATE dbo.IpdBillAdjustment SET Status = 'CANCELLED', CancelTxnId = @r, CancelReason = @Reason, CancelledBy = @UserId, CancelledAt = @now WHERE AdjId = @AdjId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@adm, CASE WHEN @kind = 'SUPP' THEN 'SUPP_BILL_CANCEL' ELSE 'CREDIT_NOTE_CANCEL' END, @why, @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @AdjId AS AdjId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- documents after the bill of an admission (list), or one document with its lines (print)
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBillAdj_List @CompanyId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT j.AdjId, j.Kind, j.DocNo, j.DocAt, j.Gross, j.Gst, j.Net, j.Reason, j.Status, j.CancelReason, j.CancelledAt, u.FullName AS CreatedByName, b.BillNo
    FROM dbo.IpdBillAdjustment j JOIN dbo.IpdBill b ON b.BillId = j.BillId LEFT JOIN dbo.Users u ON u.Id = j.CreatedBy
    WHERE j.AdmissionId = @AdmissionId AND j.CompanyId = @CompanyId ORDER BY j.DocAt, j.AdjId;
    SELECT s.Due AS BalanceNow, adj.SuppNet, adj.CreditNet FROM dbo.fn_Ipd_SettleCalc(@AdmissionId, NULL, 0, 0) s CROSS APPLY dbo.fn_Ipd_PostBillAdj(@AdmissionId) adj;
    -- the final bill's lines (a credit note can point at one)
    SELECT l.BillLineId, l.Head, hd.HeadName, l.ItemName, l.ChargeAt, l.Qty, l.Rate, l.Net, l.GstPercent
    FROM dbo.IpdAdmission a JOIN dbo.IpdBillLine l ON l.BillId = a.BillId LEFT JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head
    WHERE a.AdmissionId = @AdmissionId AND a.CompanyId = @CompanyId AND l.Net > 0 ORDER BY hd.Sort, l.ChargeAt, l.BillLineId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBillAdj_Get @CompanyId INT, @AdjId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adm INT = (SELECT AdmissionId FROM dbo.IpdBillAdjustment WHERE AdjId = @AdjId AND CompanyId = @CompanyId);
    IF @adm IS NULL RETURN;
    SELECT j.*, b.BillNo, b.BillAt, u.FullName AS CreatedByName, uc.FullName AS CancelledByName, s.Due AS BalanceNow
    FROM dbo.IpdBillAdjustment j JOIN dbo.IpdBill b ON b.BillId = j.BillId LEFT JOIN dbo.Users u ON u.Id = j.CreatedBy LEFT JOIN dbo.Users uc ON uc.Id = j.CancelledBy
    CROSS APPLY dbo.fn_Ipd_SettleCalc(j.AdmissionId, NULL, 0, 0) s
    WHERE j.AdjId = @AdjId;
    SELECT h.* FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @adm) h;
    SELECT l.*, hd.HeadName FROM dbo.IpdBillAdjustmentLine l LEFT JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head WHERE l.AdjId = @AdjId ORDER BY l.LineId;
END;
GO

-- ── final bill (2541) + 2571: discharge advice first (A4), work not charged (A3), discount limit (A7), room rent (A9) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Finalise
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @UpTo DATETIME = NULL, @DiscountType CHAR(1) = NULL, @DiscountValue DECIMAL(18,2) = 0,
    @DiscountReason NVARCHAR(300) = NULL, @Remarks NVARCHAR(500) = NULL, @CanDiscount BIT = 0, @CanBackdate BIT = 0, @CanDiscountHigh BIT = 0
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
        IF @status = 'ADMITTED' AND (SELECT FinalBillNeedsAdvice FROM dbo.fn_Ipd_GapSettings(@BranchId)) = 1
            THROW 59602, 'Advise the discharge first (Discharge tab): the final bill is made after the discharge advice. For a bill during the stay, print an interim bill.', 1;
        SET @msg = (SELECT TOP 1 Message FROM dbo.fn_Ipd_FinalBillBlockers(@AdmissionId) ORDER BY Sort);
        IF @msg IS NOT NULL THROW 59603, @msg, 1;
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
        -- 2571 (A7): the discount limit of the branch (% of the bill after item discounts)
        DECLARE @lim DECIMAL(5,2) = (SELECT DiscountLimitPercent FROM dbo.fn_Ipd_GapSettings(@BranchId));
        IF ISNULL(@bd, 0) > 0 AND ISNULL(@CanDiscountHigh, 0) = 0 AND @bd > ROUND((@g - ISNULL(@id, 0)) * @lim / 100.0, 2)
        BEGIN
            SET @msg = CONCAT(N'A bill discount above ', FORMAT(@lim, '0.##'), N'%% (₹', FORMAT(ROUND((@g - ISNULL(@id, 0)) * @lim / 100.0, 2), 'N2', 'en-IN'),
                              N') needs a user with IPD Patient > High discount.');
            THROW 59604, @msg, 1;
        END
        DECLARE @held DECIMAL(18,2) = (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId));
        DECLARE @payerType VARCHAR(12) = (SELECT PayerType FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId), @paId INT = NULL, @tpa INT = NULL,
                @auth DECIMAL(18,2) = 0, @copct DECIMAL(5,2) = 0, @ded DECIMAL(18,2) = 0, @np DECIMAL(18,2) = 0, @payer DECIMAL(18,2) = 0, @copay DECIMAL(18,2) = 0,
                @rrl DECIMAL(18,2) = NULL, @irl DECIMAL(18,2) = NULL, @pdd DECIMAL(18,2) = 0;
        IF @payerType = 'INSURANCE'
        BEGIN
            DECLARE @waiting VARCHAR(20) = (SELECT TOP 1 Status FROM dbo.IpdPreAuth WHERE AdmissionId = @AdmissionId AND IsLive = 1
                                            AND Status IN ('REQUESTED', 'QUERY', 'ENHANCE_REQUESTED', 'FINAL_REQUESTED'));
            IF @waiting IS NOT NULL THROW 54963, 'The pre-authorisation waits for the TPA (request / query / enhancement / final authorisation): record the TPA''s answer on the Insurance / TPA tab before the final bill.', 1;
            SELECT TOP 1 @paId = PreAuthId, @tpa = InsuranceTpaId, @auth = Authorised, @copct = CoPayPercent, @ded = Deductible, @np = NonPayable, @rrl = RoomRentLimit, @irl = IcuRentLimit
            FROM dbo.fn_Ipd_PreAuthAuthorised(@AdmissionId);
            IF @paId IS NOT NULL
            BEGIN
                -- 2571 (A9): room rent above the approved limit and the associated charges in proportion are not payable by the insurer
                SET @pdd = ISNULL((SELECT Deduction FROM dbo.fn_Ipd_PropDeduction(@AdmissionId, @UpTo, @rrl, @irl)), 0);
                SET @np = ISNULL(@np, 0) + @pdd;
                SELECT @payer = PayerShare, @copay = CoPayAmount FROM dbo.fn_Ipd_PayerSplit(@net, @auth, @copct, @ded, @np);
            END
            ELSE SELECT @auth = 0, @copct = 0, @ded = 0, @np = 0;
            IF @tpa IS NULL SELECT TOP 1 @tpa = InsuranceTpaId FROM dbo.IpdAdmissionPayer WHERE AdmissionId = @AdmissionId AND PayerType = 'INSURANCE' ORDER BY Seq;
            IF @payer > 0 BEGIN DECLARE @tpaL INT; EXEC dbo.usp_Ipd_TpaLedger @InsuranceTpaId = @tpa, @LedgerId = @tpaL OUTPUT; END;
        END
        DECLARE @adj DECIMAL(18,2) = CASE WHEN @held < @net - @payer THEN @held ELSE @net - @payer END;
        IF @adj < 0 SET @adj = 0;
        DECLARE @no NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'IPB', @DocDate = @now, @DocNo = @no OUTPUT;
        INSERT dbo.IpdBill (CompanyId, BranchId, AdmissionId, BillNo, BillAt, BillUpToAt, Gross, ItemDiscount, BillDiscountType, BillDiscountValue, BillDiscount, DiscountReason,
               Taxable, Gst, RoundOff, Net, AdvanceAdjusted, PrevStatus, Status, Remarks, CreatedBy,
               InsuranceTpaId, PreAuthId, PayerAuthorised, CoPayPercent, CoPayAmount, Deductible, NonPayable, PayerShare, ProportionateDeduction)
        VALUES (@CompanyId, @BranchId, @AdmissionId, @no, @now, @UpTo, @g, @id, CASE WHEN @bd > 0 THEN @DiscountType END, CASE WHEN @bd > 0 THEN @DiscountValue ELSE 0 END, @bd,
                CASE WHEN @bd > 0 THEN LTRIM(RTRIM(@DiscountReason)) END, @tx, @gst, @ro, @net, @adj, @status, 'FINAL', NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId,
                @tpa, @paId, ISNULL(@auth, 0), ISNULL(@copct, 0), ISNULL(@copay, 0), ISNULL(@ded, 0), ISNULL(@np, 0), ISNULL(@payer, 0), ISNULL(@pdd, 0));
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
        IF @payer > 0 EXEC dbo.usp_Ipd_ClaimCreate @BillId = @billId, @UserId = @UserId, @ClaimId = @claimId OUTPUT;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'FINAL_BILL', @status, 'BILL_FINAL', CONCAT(N'Final bill ', @no, N' ₹', FORMAT(@net, 'N2', 'en-IN'),
                CASE WHEN @bd > 0 THEN CONCAT(N', discount ₹', FORMAT(@bd, 'N2', 'en-IN'), N' (', LTRIM(RTRIM(@DiscountReason)), N')') ELSE N'' END,
                N', advance adjusted ₹', FORMAT(@adj, 'N2', 'en-IN'),
                CASE WHEN @pdd > 0 THEN CONCAT(N', room-rent proportionate deduction ₹', FORMAT(@pdd, 'N2', 'en-IN')) ELSE N'' END,
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

-- ── bill preview (2541) + 2571: what still blocks the final bill, the discount limit, the room-rent deduction ─
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Preview @CompanyId INT, @AdmissionId INT, @UpTo DATETIME = NULL, @DiscountType CHAR(1) = NULL, @DiscountValue DECIMAL(18,2) = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @admAt DATETIME, @bill INT, @br INT, @status VARCHAR(20);
    SELECT @admAt = AdmissionAt, @bill = BillId, @br = BranchId, @status = Status FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND Status <> 'CANCELLED';
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
    DECLARE @payer DECIMAL(18,2) = 0, @coPay DECIMAL(18,2) = 0, @auth DECIMAL(18,2) = NULL, @payerName NVARCHAR(200) = NULL, @paStatus VARCHAR(20) = NULL, @pdd DECIMAL(18,2) = 0;
    IF @bill IS NOT NULL
        SELECT @payer = b.PayerShare - b.PayerToPatient, @coPay = b.CoPayAmount, @auth = CASE WHEN b.PayerAuthorised > 0 THEN b.PayerAuthorised END, @payerName = t.Name, @pdd = b.ProportionateDeduction
        FROM dbo.IpdBill b LEFT JOIN dbo.InsuranceTPAMaster t ON t.InsuranceTPA_ID = b.InsuranceTpaId WHERE b.BillId = @bill;
    ELSE
        SELECT @payer = sp.PayerShare, @coPay = sp.CoPayAmount, @auth = pa.Authorised, @payerName = t.Name, @pdd = ISNULL(pd.Deduction, 0),
               @paStatus = (SELECT TOP 1 x.Status FROM dbo.IpdPreAuth x WHERE x.AdmissionId = @AdmissionId AND x.IsLive = 1)
        FROM dbo.IpdAdmission a
        LEFT JOIN dbo.IpdAdmissionPayer py ON py.AdmissionId = a.AdmissionId AND py.Seq = 1 AND py.PayerType = 'INSURANCE'
        LEFT JOIN dbo.InsuranceTPAMaster t ON t.InsuranceTPA_ID = py.InsuranceTpaId
        OUTER APPLY (SELECT TOP 1 Authorised, CoPayPercent, Deductible, NonPayable, RoomRentLimit, IcuRentLimit FROM dbo.fn_Ipd_PreAuthAuthorised(@AdmissionId)) pa
        OUTER APPLY (SELECT d.Deduction FROM dbo.fn_Ipd_PropDeduction(@AdmissionId, @UpTo, pa.RoomRentLimit, pa.IcuRentLimit) d WHERE ISNULL(pa.RoomRentLimit, 0) > 0 OR ISNULL(pa.IcuRentLimit, 0) > 0) pd
        OUTER APPLY dbo.fn_Ipd_PayerSplit(ISNULL(@net, 0), pa.Authorised, pa.CoPayPercent, pa.Deductible, ISNULL(pa.NonPayable, 0) + ISNULL(pd.Deduction, 0)) sp
        WHERE a.AdmissionId = @AdmissionId AND a.PayerType = 'INSURANCE';
    SET @payer = ISNULL(@payer, 0); SET @coPay = ISNULL(@coPay, 0); SET @pdd = ISNULL(@pdd, 0);
    SET @adj = CASE WHEN @bill IS NOT NULL THEN (SELECT AdvanceAdjusted FROM dbo.IpdBill WHERE BillId = @bill) WHEN @held < ISNULL(@net, 0) - @payer THEN @held ELSE ISNULL(@net, 0) - @payer END;
    IF @adj < 0 SET @adj = 0;
    DECLARE @postAdj DECIMAL(18,2) = (SELECT AdjNet FROM dbo.fn_Ipd_PostBillAdj(@AdmissionId));
    DECLARE @gs TABLE (FinalBillNeedsAdvice BIT, DiscountLimitPercent DECIMAL(5,2));
    INSERT @gs SELECT FinalBillNeedsAdvice, DiscountLimitPercent FROM dbo.fn_Ipd_GapSettings(@br);
    -- 1 totals
    SELECT @UpTo AS UpTo, @bill AS BillId, (SELECT BillNo FROM dbo.IpdBill WHERE BillId = @bill) AS BillNo, (SELECT BillAt FROM dbo.IpdBill WHERE BillId = @bill) AS BillAt, (SELECT SettleTotal FROM dbo.fn_Ipd_Money(@AdmissionId)) AS SettleTotal, ISNULL(@g, 0) AS Gross, ISNULL(@id, 0) AS ItemDiscount, ISNULL(@bd, 0) AS BillDiscount, ISNULL(@tx, 0) AS Taxable, ISNULL(@gst, 0) AS Gst,
           ISNULL(@ro, 0) AS RoundOff, ISNULL(@net, 0) AS Net, @held AS AdvanceHeld, @adj AS AdvanceAdjusted, @payer AS PayerShare, CAST(ISNULL(@net, 0) - @payer AS DECIMAL(18,2)) AS PatientShare,
           @coPay AS CoPayAmount, @auth AS PayerAuthorised, @payerName AS PayerName, @paStatus AS PreAuthStatus, @pdd AS ProportionateDeduction, @postAdj AS PostBillAdjustments,
           CAST(CASE WHEN ISNULL(@net, 0) - @payer + @postAdj - @held > 0 THEN ISNULL(@net, 0) - @payer + @postAdj - @held ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN @held - (ISNULL(@net, 0) - @payer + @postAdj) > 0 THEN @held - (ISNULL(@net, 0) - @payer + @postAdj) ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           ISNULL(@nt, 0) AS NoTariff, @err AS Error,
           (SELECT COUNT(*) FROM #IpdBillCalc) AS Lines,
           (SELECT COUNT(*) FROM #IpdBillCalc WHERE IsPackageItem = 1) AS PackageLines,
           CAST(CASE WHEN @bill IS NULL AND @status = 'ADMITTED' AND (SELECT FinalBillNeedsAdvice FROM @gs) = 1 THEN 1 ELSE 0 END AS BIT) AS NeedsAdvice,
           (SELECT DiscountLimitPercent FROM @gs) AS DiscountLimitPercent;
    -- 2 heads
    SELECT hd.Head, hd.HeadName, hd.Sort, COUNT(l.Head) AS Lines, CAST(ISNULL(SUM(l.Gross), 0) AS DECIMAL(18,2)) AS Gross,
           CAST(ISNULL(SUM(l.ItemDiscount + l.BillDiscount), 0) AS DECIMAL(18,2)) AS Discount, CAST(ISNULL(SUM(l.GstAmount), 0) AS DECIMAL(18,2)) AS Gst,
           CAST(ISNULL(SUM(l.Net), 0) AS DECIMAL(18,2)) AS Net
    FROM dbo.fn_Ipd_Heads() hd LEFT JOIN #IpdBillCalc l ON l.Head = hd.Head
    WHERE hd.Head <> 'ADJUST'
    GROUP BY hd.Head, hd.HeadName, hd.Sort HAVING COUNT(l.Head) > 0 OR @bill IS NULL ORDER BY hd.Sort;
    -- 3 what blocks the final bill (none once it is made)
    SELECT b.Sort, b.Kind, b.Message FROM dbo.fn_Ipd_FinalBillBlockers(@AdmissionId) b WHERE @bill IS NULL ORDER BY b.Sort;
END;
GO

-- ── bill for print (2541) + 2571: balance with supplementary bills / credit notes, room-rent deduction ──────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Get @CompanyId INT, @BillId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adm INT = (SELECT AdmissionId FROM dbo.IpdBill WHERE BillId = @BillId AND CompanyId = @CompanyId);
    IF @adm IS NULL RETURN;
    DECLARE @pa DECIMAL(18,2) = (SELECT AdjNet FROM dbo.fn_Ipd_PostBillAdj(@adm));
    SELECT b.*, CAST((b.Net - b.PayerShare + b.PayerToPatient) AS DECIMAL(18,2)) AS PatientShare, CAST(b.PayerShare - b.PayerToPatient AS DECIMAL(18,2)) AS PayerShareNow,
           tpa.Name AS PayerName, pa.PreAuthNo, pa.TpaRefNo, cl.ClaimNo, u.FullName AS CreatedByName, uc.FullName AS CancelledByName, mo.NetAdvance AS AdvanceHeld, mo.AdvanceTotal, mo.RefundTotal, mo.SettleTotal,
           @pa AS PostBillAdjustments,
           CAST(CASE WHEN b.Status = 'FINAL' AND (b.Net - b.PayerShare + b.PayerToPatient) + @pa - mo.NetAdvance > 0 THEN (b.Net - b.PayerShare + b.PayerToPatient) + @pa - mo.NetAdvance ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN b.Status = 'FINAL' AND mo.NetAdvance - (b.Net - b.PayerShare + b.PayerToPatient) - @pa > 0 THEN mo.NetAdvance - (b.Net - b.PayerShare + b.PayerToPatient) - @pa ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           s.HotelName AS HospitalName, s.Address AS HospitalAddress, s.ContactNumber1 AS HospitalPhone, s.EmailAddress AS HospitalEmail, s.GSTCode AS HospitalGstin
    FROM dbo.IpdBill b
    LEFT JOIN dbo.Users u ON u.Id = b.CreatedBy LEFT JOIN dbo.Users uc ON uc.Id = b.CancelledBy
    LEFT JOIN dbo.HospitalSettings s ON s.BranchID = b.BranchId
    LEFT JOIN dbo.InsuranceTPAMaster tpa ON tpa.InsuranceTPA_ID = b.InsuranceTpaId
    LEFT JOIN dbo.IpdPreAuth pa ON pa.PreAuthId = b.PreAuthId
    LEFT JOIN dbo.IpdClaim cl ON cl.BillId = b.BillId AND cl.IsLive = 1
    CROSS APPLY dbo.fn_Ipd_Money(b.AdmissionId) mo
    WHERE b.BillId = @BillId;
    SELECT h.*, pbm.BeneficiaryId FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @adm) h
    LEFT JOIN dbo.PatientMaster pbm ON pbm.PatientId = h.PatientId;
    SELECT l.*, hd.HeadName, hd.Sort AS HeadSort FROM dbo.IpdBillLine l LEFT JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head
    WHERE l.BillId = @BillId ORDER BY hd.Sort, l.ChargeAt, l.DayNo, l.Sort, l.BillLineId;
    SELECT hd.Head, hd.HeadName, hd.Sort, COUNT(*) AS Lines, SUM(l.Gross) AS Gross, SUM(l.ItemDiscount + l.BillDiscount) AS Discount, SUM(l.GstAmount) AS Gst, SUM(l.Net) AS Net
    FROM dbo.IpdBillLine l JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head WHERE l.BillId = @BillId GROUP BY hd.Head, hd.HeadName, hd.Sort ORDER BY hd.Sort;
    SELECT v.AdvanceId, v.Kind, v.Amount, v.DocNo, v.Mode, v.CreatedDate,
           (SELECT STRING_AGG(pm.MethodName, ', ') FROM dbo.PaymentDetail pd JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
            WHERE pd.PaymentHeaderId = v.PaymentHeaderId AND pd.IsActive = 1) AS Modes
    FROM dbo.IpdAdvance v WHERE v.AdmissionId = @adm AND v.IsActive = 1 ORDER BY v.CreatedDate, v.AdvanceId;
    -- 6 supplementary bills / credit notes after it
    SELECT j.AdjId, j.Kind, j.DocNo, j.DocAt, j.Net, j.Reason, j.Status FROM dbo.IpdBillAdjustment j WHERE j.BillId = @BillId ORDER BY j.DocAt, j.AdjId;
END;
GO

-- ── A5: interim bill (the running bill as a document during the stay; no number, nothing is posted) ─────────
-- Same result sets as usp_Api_IpdBill_Get, so the bill print shows it (Status = INTERIM).
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Interim @CompanyId INT, @BranchId INT, @AdmissionId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE(), @bill INT, @status VARCHAR(20);
    SELECT @bill = BillId, @status = Status FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
    IF @status IS NULL OR @status = 'CANCELLED' OR @bill IS NOT NULL RETURN;
    CREATE TABLE #IpdBillCalc (LineKey NVARCHAR(40), Head VARCHAR(20), ChargeAt DATETIME, ItemCode NVARCHAR(50), ItemName NVARCHAR(250), Detail NVARCHAR(300), DoctorName NVARCHAR(150),
        Qty DECIMAL(18,3), Rate DECIMAL(18,2), Gross DECIMAL(18,2), ItemDiscount DECIMAL(18,2), BillDiscount DECIMAL(18,2), GstPercent DECIMAL(5,2), GstAmount DECIMAL(18,2),
        Net DECIMAL(18,2), SourceModule VARCHAR(10), SourceNo NVARCHAR(50), IsPackageItem BIT, NoTariff BIT, DayNo INT, Sort INT, ChargeId BIGINT);
    DECLARE @g DECIMAL(18,2), @id DECIMAL(18,2), @bd DECIMAL(18,2), @tx DECIMAL(18,2), @gst DECIMAL(18,2), @ro DECIMAL(18,2), @net DECIMAL(18,2), @nt BIT;
    EXEC dbo.usp_Ipd_BillCalc @AdmissionId = @AdmissionId, @UpTo = @now, @DiscountType = NULL, @DiscountValue = 0,
         @Gross = @g OUTPUT, @ItemDiscount = @id OUTPUT, @BillDiscount = @bd OUTPUT, @Taxable = @tx OUTPUT, @Gst = @gst OUTPUT, @RoundOff = @ro OUTPUT, @Net = @net OUTPUT, @NoTariff = @nt OUTPUT;
    DECLARE @payer DECIMAL(18,2) = (SELECT PayerShare FROM dbo.fn_Ipd_PayerShare(@AdmissionId, @net));
    DECLARE @held DECIMAL(18,2) = (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId));
    INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
    VALUES (@AdmissionId, 'INTERIM_BILL', CONCAT(N'Interim bill printed: ₹', FORMAT(@net, 'N2', 'en-IN'), N' up to ', FORMAT(@now, 'dd-MMM-yyyy HH:mm')), @UserId);
    SELECT CAST(NULL AS INT) AS BillId, a.AdmissionId, a.BranchId, N'INTERIM' AS BillNo, @now AS BillAt, @now AS BillUpToAt, 'INTERIM' AS Status,
           @g AS Gross, @id AS ItemDiscount, @bd AS BillDiscount, CAST(NULL AS NVARCHAR(300)) AS DiscountReason, @tx AS Taxable, @gst AS Gst, @ro AS RoundOff, @net AS Net,
           CAST(CASE WHEN @held < @net - @payer THEN @held ELSE @net - @payer END AS DECIMAL(18,2)) AS AdvanceAdjusted,
           @payer AS PayerShare, @payer AS PayerShareNow, CAST(0 AS DECIMAL(18,2)) AS PayerToPatient, CAST(@net - @payer AS DECIMAL(18,2)) AS PatientShare,
           CAST(0 AS DECIMAL(18,2)) AS PayerAuthorised, CAST(0 AS DECIMAL(18,2)) AS NonPayable, CAST(0 AS DECIMAL(18,2)) AS Deductible, CAST(0 AS DECIMAL(18,2)) AS CoPayAmount,
           CAST(0 AS DECIMAL(5,2)) AS CoPayPercent, CAST(0 AS DECIMAL(18,2)) AS ProportionateDeduction, CAST(0 AS DECIMAL(18,2)) AS PostBillAdjustments,
           CAST(NULL AS NVARCHAR(200)) AS PayerName, mo.NetAdvance AS AdvanceHeld, mo.AdvanceTotal, mo.RefundTotal, mo.SettleTotal,
           CAST(CASE WHEN @net - @payer - @held > 0 THEN @net - @payer - @held ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN @held - (@net - @payer) > 0 THEN @held - (@net - @payer) ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           u.FullName AS CreatedByName, s.HotelName AS HospitalName, s.Address AS HospitalAddress, s.ContactNumber1 AS HospitalPhone, s.EmailAddress AS HospitalEmail, s.GSTCode AS HospitalGstin
    FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_Money(a.AdmissionId) mo
    LEFT JOIN dbo.HospitalSettings s ON s.BranchID = a.BranchId LEFT JOIN dbo.Users u ON u.Id = @UserId
    WHERE a.AdmissionId = @AdmissionId;
    SELECT h.*, pbm.BeneficiaryId FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @AdmissionId) h LEFT JOIN dbo.PatientMaster pbm ON pbm.PatientId = h.PatientId;
    SELECT l.*, hd.HeadName, hd.Sort AS HeadSort FROM #IpdBillCalc l LEFT JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head ORDER BY hd.Sort, l.ChargeAt, l.DayNo, l.Sort;
    SELECT hd.Head, hd.HeadName, hd.Sort, COUNT(*) AS Lines, SUM(l.Gross) AS Gross, SUM(l.ItemDiscount + l.BillDiscount) AS Discount, SUM(l.GstAmount) AS Gst, SUM(l.Net) AS Net
    FROM #IpdBillCalc l JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head GROUP BY hd.Head, hd.HeadName, hd.Sort ORDER BY hd.Sort;
    SELECT v.AdvanceId, v.Kind, v.Amount, v.DocNo, v.Mode, v.CreatedDate,
           (SELECT STRING_AGG(pm.MethodName, ', ') FROM dbo.PaymentDetail pd JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
            WHERE pd.PaymentHeaderId = v.PaymentHeaderId AND pd.IsActive = 1) AS Modes
    FROM dbo.IpdAdvance v WHERE v.AdmissionId = @AdmissionId AND v.IsActive = 1 ORDER BY v.CreatedDate, v.AdvanceId;
END;
GO

-- ── A1: IPD > Credit Dues - discharged patients with a balance on the final bill ─────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdCreditDues_List @CompanyId INT, @BranchId INT, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @like NVARCHAR(110) = N'%' + NULLIF(LTRIM(RTRIM(@Search)), N'') + N'%';
    SELECT a.AdmissionId, a.IpNo, p.PatientCode, LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, p.PhoneNumber,
           a.PayerType, b.BillNo, b.BillAt, a.DischargeAt, d.IsCreditDischarge, d.CreditReason, d.CreditAmount, s.Due AS BalanceDue,
           CAST(b.PayerToPatient AS DECIMAL(18,2)) AS TpaMovedToPatient, adj.SuppNet, adj.CreditNet,
           DATEDIFF(DAY, a.DischargeAt, GETDATE()) AS DaysSinceDischarge,
           (SELECT MAX(v.CreatedDate) FROM dbo.IpdAdvance v WHERE v.AdmissionId = a.AdmissionId AND v.IsActive = 1 AND v.Kind = 'SETTLE') AS LastPaymentAt,
           dm.FullName AS ConsultantName
    FROM dbo.IpdAdmission a
    JOIN dbo.IpdBill b ON b.BillId = a.BillId AND b.Status = 'FINAL'
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    OUTER APPLY (SELECT TOP 1 x.IsCreditDischarge, x.CreditReason, x.CreditAmount FROM dbo.IpdDischarge x WHERE x.AdmissionId = a.AdmissionId AND x.Status = 'DISCHARGED' ORDER BY x.DischargeId DESC) d
    CROSS APPLY dbo.fn_Ipd_SettleCalc(a.AdmissionId, NULL, 0, 0) s
    CROSS APPLY dbo.fn_Ipd_PostBillAdj(a.AdmissionId) adj
    LEFT JOIN dbo.DoctorMaster dm ON dm.DoctorId = a.ConsultantDoctorId
    WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId AND a.Status = 'DISCHARGED' AND s.Due > 0.5
      AND (@like IS NULL OR a.IpNo LIKE @like OR p.PatientCode LIKE @like OR p.FirstName LIKE @like OR p.LastName LIKE @like OR p.PhoneNumber LIKE @like)
    ORDER BY a.DischargeAt;
END;
GO

-- ── C8: reopen a gate pass (patient did not leave, wrong patient, discharged by mistake) ────────────────────
-- Within Hospital Settings IpdReopenHours (24) of the gate pass, not for a death, while the bed is still free, before any
-- supplementary bill / credit note / payment after the discharge and before the OPD follow-up visit. The bill stays final:
-- cancel it on the Billing tab to change charges.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Reopen @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
        IF @Reason IS NULL THROW 59630, 'Enter the reason for reopening the discharge.', 1;
        DECLARE @status VARCHAR(20), @patient INT, @disAt DATETIME;
        SELECT @status = Status, @patient = PatientId, @disAt = DischargeAt FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL THROW 59631, 'The admission was not found in this branch.', 1;
        IF @status <> 'DISCHARGED' THROW 59632, 'Only a discharged patient can be reopened.', 1;
        DECLARE @did INT, @type VARCHAR(12), @gp NVARCHAR(40), @gpAt DATETIME;
        SELECT TOP 1 @did = DischargeId, @type = DischargeType, @gp = GatePassNo, @gpAt = GatePassAt FROM dbo.IpdDischarge WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND Status = 'DISCHARGED' ORDER BY DischargeId DESC;
        IF @did IS NULL THROW 59633, 'The gate pass was not found.', 1;
        IF @type = 'DEATH' THROW 59634, 'A death discharge cannot be reopened: void and correct the death record instead.', 1;
        DECLARE @hours INT = (SELECT ReopenHours FROM dbo.fn_Ipd_GapSettings(@BranchId));
        IF @gpAt < DATEADD(HOUR, -@hours, @now)
        BEGIN
            SET @msg = CONCAT(N'A gate pass can be reopened within ', @hours, N' hours (Hospital Settings > IPD). Admit the patient again instead.');
            THROW 59635, @msg, 1;
        END
        IF EXISTS (SELECT 1 FROM dbo.IpdBillAdjustment WHERE AdmissionId = @AdmissionId AND Status = 'ACTIVE')
            THROW 59636, 'A supplementary bill or credit note is made after the discharge: cancel it first.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdAdvance WHERE AdmissionId = @AdmissionId AND IsActive = 1 AND CreatedDate > @gpAt)
            THROW 59637, 'Money was received or refunded after the discharge: the discharge cannot be reopened.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdFollowUp WHERE AdmissionId = @AdmissionId AND Status = 'VISITED')
            THROW 59638, 'The patient already came for the OPD follow-up: admit the patient again instead.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE PatientId = @patient AND IsOpen = 1 AND AdmissionId <> @AdmissionId)
            THROW 59639, 'The patient has another open admission.', 1;
        DECLARE @mv INT, @bed INT, @bedNo NVARCHAR(40), @bedStatus NVARCHAR(30);
        SELECT TOP 1 @mv = m.MovementId, @bed = m.BedId FROM dbo.IpdBedMovement m WITH (UPDLOCK) WHERE m.AdmissionId = @AdmissionId AND m.EndType = 'DISCHARGE' ORDER BY m.MovementId DESC;
        SELECT @bedNo = BedNumber, @bedStatus = BedStatus FROM dbo.BedMaster WITH (UPDLOCK) WHERE BedId = @bed;
        IF @mv IS NULL OR EXISTS (SELECT 1 FROM dbo.IpdBedMovement WHERE BedId = @bed AND ToAt IS NULL)
           OR EXISTS (SELECT 1 FROM dbo.IpdBedReservation WHERE BedId = @bed AND Status = 'ACTIVE')
           OR @bedStatus NOT IN (N'Available', N'Cleaning')
        BEGIN
            SET @msg = CONCAT(N'Bed ', ISNULL(@bedNo, N''), N' is no longer free (', ISNULL(@bedStatus, N'?'), N'): admit the patient again instead.');
            THROW 59640, @msg, 1;
        END
        -- back in the bed, admission open again with its final bill
        UPDATE dbo.IpdBedMovement SET ToAt = NULL, EndType = NULL WHERE MovementId = @mv;
        UPDATE dbo.IpdBedCleaning SET IsOpen = 0, Status = 'CANCELLED', Remarks = LEFT(CONCAT(ISNULL(Remarks + N' · ', N''), N'discharge reopened'), 300)
        WHERE BedId = @bed AND IsOpen = 1 AND AdmissionId = @AdmissionId;
        EXEC dbo.usp_Ipd_SetBedStatus @BedId = @bed, @ToStatus = N'Occupied', @Reason = N'Discharge reopened', @AdmissionId = @AdmissionId, @UserId = @UserId, @RefType = 'REOPEN';
        UPDATE dbo.IpdDischarge SET Status = 'ADVISED', GatePassNo = NULL, GatePassAt = NULL, GatePassBy = NULL, IsCreditDischarge = 0, CreditAmount = NULL, CreditReason = NULL,
               ModifiedBy = @UserId, ModifiedDate = @now WHERE DischargeId = @did;
        UPDATE dbo.IpdAdmission SET Status = 'BILL_FINAL', IsOpen = 1, DischargeAt = NULL, CurrentBedId = @bed, ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @AdmissionId;
        INSERT dbo.IpdDischargeReopen (AdmissionId, DischargeId, GatePassNo, GatePassAt, Reason, ReopenedBy) VALUES (@AdmissionId, @did, @gp, @gpAt, @Reason, @UserId);
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'DISCHARGE_REOPEN', 'DISCHARGED', 'BILL_FINAL', CONCAT(N'Gate pass ', @gp, N' reopened: ', @Reason), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @AdmissionId AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

PRINT '2571 IPD flow-gap billing - done.';
GO
