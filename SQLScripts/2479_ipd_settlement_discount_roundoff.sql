-- ============================================================================================================
-- Migration: 2479_ipd_settlement_discount_roundoff.sql   (application database)
-- IPD Patient > Collect payment: discount (percentage / amount) and round off when SETTLING the final bill.
--   Before the final bill the modal takes an ADVANCE (a refundable deposit): no discount / round off there - the
--   discount of the stay is given on the final bill. After the final bill (balance due):
--     discount   P = % of the balance due, A = amount; at most the balance; needs the DISCOUNT control (checked in the
--                web) and a reason
--     round off  the paise left after the discount are written off - only when the balance is paid in full
--     payable    = due - discount - round off; payments may be less (part payment) unless round off is asked
--   All worked out here (usp_Api_IpdAdvance_Preview for the screen, usp_Ipd_PostAdvance again on save).
--   Stored as IpdAdvance kind ADJUST (a credit like a settlement, so every balance - list, banner, bill, due list -
--   follows), linked to the receipt; no cash moves.
--   Ledger   receipt     RCT  Dr Cash / Bank · Cr Patient Receivable                 (as before, 2434)
--            adjustment  JRN  Dr Discount Allowed · Dr Round Off · Cr Patient Receivable
--            bill cancel the adjustment journal is cancelled and the adjustment dropped (receipts become advance, 2434)
--   Also: the payment mode of a bill payment (SETTLE) receipt is shown in the advances list.
--   Replaces usp_Ipd_PostAdvance, usp_Api_IpdAdvance_Add, usp_Api_IpdAdvance_Get; patches usp_Api_IpdBill_Cancel and the
--   advances list of usp_Api_IpdAdmission_Get. Needs 2434. Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_IpdAdvance_Kind' AND definition NOT LIKE '%ADJUST%')
BEGIN
    ALTER TABLE dbo.IpdAdvance DROP CONSTRAINT CK_IpdAdvance_Kind;
    ALTER TABLE dbo.IpdAdvance ADD CONSTRAINT CK_IpdAdvance_Kind CHECK (Kind IN ('ADVANCE', 'REFUND', 'SETTLE', 'ADJUST'));
END
GO
IF COL_LENGTH('dbo.IpdAdvance', 'DiscType') IS NULL
    ALTER TABLE dbo.IpdAdvance ADD DiscType CHAR(1) NULL, DiscValue DECIMAL(18,2) NULL, DiscAmount DECIMAL(18,2) NULL, RoundOff DECIMAL(18,2) NULL,
        AdjustOfAdvanceId INT NULL, BillId INT NULL, LedgerTxnId BIGINT NULL;
GO

-- the adjustment's description ("Discount 10% ₹2,280.00 + Round off ₹0.40") is kept in Mode
IF COL_LENGTH('dbo.IpdAdvance', 'Mode') < 200
    ALTER TABLE dbo.IpdAdvance ALTER COLUMN Mode NVARCHAR(100) NULL;
GO

-- money of an admission (2434) + AdjustTotal (discount / round off on settlement); NetAdvance = everything credited
CREATE OR ALTER FUNCTION dbo.fn_Ipd_Money (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT CAST(ISNULL(SUM(CASE WHEN Kind = 'ADVANCE' THEN Amount END), 0) AS DECIMAL(18,2)) AS AdvanceTotal,
           CAST(ISNULL(SUM(CASE WHEN Kind = 'REFUND' THEN Amount END), 0) AS DECIMAL(18,2)) AS RefundTotal,
           CAST(ISNULL(SUM(CASE WHEN Kind = 'REFUND' THEN -Amount ELSE Amount END), 0) AS DECIMAL(18,2)) AS NetAdvance,
           CAST(ISNULL(SUM(CASE WHEN Kind = 'SETTLE' THEN Amount END), 0) AS DECIMAL(18,2)) AS SettleTotal,
           CAST(ISNULL(SUM(CASE WHEN Kind = 'ADJUST' THEN Amount END), 0) AS DECIMAL(18,2)) AS AdjustTotal
    FROM dbo.IpdAdvance WHERE AdmissionId = @AdmissionId AND IsActive = 1
);
GO

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
          CROSS APPLY (SELECT CAST(ISNULL((SELECT b.Net FROM dbo.IpdBill b WHERE b.BillId = a.BillId), 0) - (SELECT NetAdvance FROM dbo.fn_Ipd_Money(a.AdmissionId)) AS DECIMAL(18,2)) AS Due) d
          WHERE a.AdmissionId = @AdmissionId AND a.BillId IS NOT NULL) x
);
GO

-- ledger of a settlement adjustment: JRN Dr Discount Allowed · Dr Round Off · Cr Patient Receivable
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostSettleAdjustLedger @AdvanceId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @recv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable'),
            @discL INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Discount Allowed'),
            @roL INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Round Off');
    IF @recv IS NULL OR @discL IS NULL OR @roL IS NULL THROW 54121, 'A ledger of the settlement is missing (Patient Receivable, Discount Allowed, Round Off).', 1;
    DECLARE @co INT, @br INT, @date DATETIME, @disc DECIMAL(18,2), @ro DECIMAL(18,2), @no NVARCHAR(50), @ip NVARCHAR(40), @party NVARCHAR(250), @billNo NVARCHAR(40), @why NVARCHAR(300);
    SELECT @co = a.CompanyId, @br = a.BranchId, @date = v.CreatedDate, @disc = ISNULL(v.DiscAmount, 0), @ro = ISNULL(v.RoundOff, 0), @no = v.DocNo, @ip = a.IpNo,
           @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName))), @billNo = b.BillNo, @why = v.Remarks
    FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.IpdBill b ON b.BillId = v.BillId
    WHERE v.AdvanceId = @AdvanceId AND v.Kind = 'ADJUST' AND v.IsActive = 1;
    IF ISNULL(@disc, 0) + ISNULL(@ro, 0) <= 0 RETURN;
    DECLARE @narr NVARCHAR(400) = CONCAT(N'IPD settlement ', @no, N' on bill ', @billNo, N' - ', @ip, N' - ', @party,
            CASE WHEN @disc > 0 THEN CONCAT(N' · discount ₹', FORMAT(@disc, 'N2', 'en-IN')) ELSE N'' END,
            CASE WHEN @ro > 0 THEN CONCAT(N' · round off ₹', FORMAT(@ro, 'N2', 'en-IN')) ELSE N'' END);
    DECLARE @lines NVARCHAR(MAX) = (SELECT LedgerId, Dr, Cr, Narration FROM (VALUES
            (@discL, @disc, CAST(0 AS DECIMAL(18,2)), LEFT(N'Discount on settlement' + ISNULL(N': ' + @why, N''), 200)),
            (@roL, @ro, 0, N'Round off on settlement'),
            (@recv, 0, @disc + @ro, N'Bill balance written off')) v (LedgerId, Dr, Cr, Narration) WHERE Dr > 0 OR Cr > 0 FOR JSON PATH);
    DECLARE @tid BIGINT, @vno NVARCHAR(50);
    EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'JRN', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'IPD_SETTLEADJ', @ReferenceId = @AdvanceId,
         @Narration = @narr, @PayeeName = @party, @PaymentMode = NULL, @InstrumentNo = NULL, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
         @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    UPDATE dbo.IpdAdvance SET LedgerTxnId = @tid WHERE AdvanceId = @AdvanceId;
END;
GO

-- ── receipts (2434) + discount / round off on settlement ────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostAdvance
    @AdmissionId INT, @UserId INT, @Payments NVARCHAR(MAX), @Remarks NVARCHAR(300) = NULL,
    @AdvanceId INT OUTPUT, @ReceiptNo NVARCHAR(50) OUTPUT,
    @DiscType CHAR(1) = NULL, @DiscValue DECIMAL(18,2) = 0, @DiscReason NVARCHAR(300) = NULL, @RoundOff BIT = 0, @CanDiscount BIT = 0,
    @AdjustAmount DECIMAL(18,2) = NULL OUTPUT
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
    IF @open = 0 THROW 54108, 'The admission is closed: money can be taken only while the patient is admitted.', 1;
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
        -- the whole balance is discounted / rounded off: a settlement note number instead of a receipt
        DECLARE @adjAt DATETIME = GETDATE();
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @br, @DocType = 'ADJ', @DocDate = @adjAt, @DocNo = @ReceiptNo OUTPUT;
    END

    -- discount / round off on the settlement: a credit on the admission + its journal
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
            CASE WHEN @disc > 0 THEN CONCAT(N'; discount ₹', FORMAT(@disc, 'N2', 'en-IN'), ISNULL(N' (' + NULLIF(LTRIM(RTRIM(@DiscReason)), N'') + N')', N'')) ELSE N'' END,
            CASE WHEN @ro > 0 THEN CONCAT(N'; round off ₹', FORMAT(@ro, 'N2', 'en-IN')) ELSE N'' END), @UserId);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvance_Add @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Payments NVARCHAR(MAX), @Remarks NVARCHAR(300) = NULL,
    @DiscType CHAR(1) = NULL, @DiscValue DECIMAL(18,2) = 0, @DiscReason NVARCHAR(300) = NULL, @RoundOff BIT = 0, @CanDiscount BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;   -- called inside another transaction: only this procedure's work is undone on a refusal
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId)
            THROW 54401, 'The admission was not found in this branch.', 1;
        DECLARE @advId INT, @rcpt NVARCHAR(50), @adj DECIMAL(18,2);
        EXEC dbo.usp_Ipd_PostAdvance @AdmissionId = @AdmissionId, @UserId = @UserId, @Payments = @Payments, @Remarks = @Remarks, @AdvanceId = @advId OUTPUT, @ReceiptNo = @rcpt OUTPUT,
             @DiscType = @DiscType, @DiscValue = @DiscValue, @DiscReason = @DiscReason, @RoundOff = @RoundOff, @CanDiscount = @CanDiscount, @AdjustAmount = @adj OUTPUT;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @advId AS AdvanceId, @rcpt AS ReceiptNo, @adj AS Adjusted;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

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
               CAST(lt.Net - mo.NetAdvance AS DECIMAL(18,2)) AS Due, CAST(0 AS DECIMAL(18,2)) AS Discount, CAST(0 AS DECIMAL(18,2)) AS RoundOff,
               CAST(NULL AS DECIMAL(18,2)) AS Payable, lt.Net AS BillNow,
               CAST(CASE WHEN ISNULL(@DiscValue, 0) <> 0 OR ISNULL(@RoundOff, 0) = 1 THEN N'Discount and round off are given when the final bill is settled.' END AS NVARCHAR(200)) AS Note
        FROM dbo.fn_Ipd_Money(@AdmissionId) mo OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(@AdmissionId, GETDATE())) lt;
        RETURN;
    END
    SELECT CAST('SETTLE' AS VARCHAR(10)) AS Kind, @billNo AS BillNo, @billNet AS BillNet, mo.NetAdvance AS Paid, c.Due, c.Disc AS Discount, c.RoundOff, c.Payable, @billNet AS BillNow,
           CAST(CASE WHEN @DiscType = 'P' AND @DiscValue > 100 THEN N'The discount cannot be more than 100%.'
                     WHEN @DiscType = 'A' AND @DiscValue > c.Due THEN N'The discount is limited to the balance due.' END AS NVARCHAR(200)) AS Note
    FROM dbo.fn_Ipd_SettleCalc(@AdmissionId, @DiscType, @DiscValue, @RoundOff) c CROSS APPLY dbo.fn_Ipd_Money(@AdmissionId) mo;
END;
GO

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
           CAST(ISNULL(b.Net, 0) - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceAfter
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

-- bill cancel (2434): the settlement adjustments are dropped and their journals cancelled first
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_IpdBill_Cancel'));
IF @def NOT LIKE '%IPD_SETTLEADJ%'
BEGIN
    DECLARE @mark NVARCHAR(200) = N'        DECLARE @settled DECIMAL(18,2) = (SELECT ISNULL(SUM(Amount), 0) FROM dbo.IpdAdvance WHERE AdmissionId = @adm AND Kind = ''SETTLE'' AND IsActive = 1);';
    IF CHARINDEX(@mark, @def) = 0 THROW 51479, 'usp_Api_IpdBill_Cancel has changed: add the settlement adjustment reversal by hand.', 1;
    SET @def = REPLACE(@def, @mark, N'        -- settlement discount / round off (IPD_SETTLEADJ, SQLScripts/2479): journal cancelled, adjustment dropped
        DECLARE @adjTxn BIGINT, @adjId INT;
        DECLARE adjc CURSOR LOCAL FAST_FORWARD FOR SELECT AdvanceId, LedgerTxnId FROM dbo.IpdAdvance WHERE AdmissionId = @adm AND Kind = ''ADJUST'' AND IsActive = 1;
        OPEN adjc; FETCH NEXT FROM adjc INTO @adjId, @adjTxn;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @adjTxn IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE TransactionId = @adjTxn AND Status <> ''C'')
                EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @adjTxn, @Reason = @why, @UserId = @UserId, @ReversalId = @r OUTPUT;
            UPDATE dbo.IpdAdvance SET IsActive = 0, Remarks = LEFT(CONCAT(ISNULL(Remarks + N'' · '', N''''), N''dropped: bill '', @no, N'' cancelled''), 300) WHERE AdvanceId = @adjId;
            FETCH NEXT FROM adjc INTO @adjId, @adjTxn;
        END
        CLOSE adjc; DEALLOCATE adjc;
' + @mark);
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
GO

-- advances list of the patient file: the payment mode of a bill payment receipt too (it showed "—")
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_IpdAdmission_Get'));
IF @def LIKE '%CASE WHEN v.Kind = ''ADVANCE'' THEN%'
BEGIN
    SET @def = REPLACE(@def, 'CASE WHEN v.Kind = ''ADVANCE'' THEN', 'CASE WHEN v.Kind IN (''ADVANCE'', ''SETTLE'') THEN');
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
GO

-- the modal's figures: the Advance control of IPD.PATIENT (as collecting itself). No role is granted.
DECLARE @pp INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT';
OPEN pc; FETCH NEXT FROM pc INTO @pp;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'ADVANCE');
    IF @ctl IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdAdmission', @Action = N'AdvancePreview', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @pp;
END
CLOSE pc; DEALLOCATE pc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2479 applied: IPD settlement discount / round off with ledger.';
GO
