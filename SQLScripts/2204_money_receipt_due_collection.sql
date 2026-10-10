-- =====================================================================================================================
-- 2204  Money Receipt for due collections (OPD and LAB)
--
-- A Money Receipt (A5) is printed for a payment collected against a bill that was already saved with a balance due,
-- i.e. the PaymentHeader existed before this receipt. The first payment at billing keeps its existing bill print.
-- One receipt = all PaymentDetail rows saved by one Collect Payment (same ReceiptNo, see usp_Receipt_GetNextNo).
--
--   usp_MoneyReceipt_Get @ReceiptNo, @BranchId (NULL = any branch, Super Admin)
--     RS1 receipt + bill position at the time of the receipt, RS2 payment modes
--
-- Endpoint MoneyReceipt/Print is mapped to the VIEW control of the pages that collect a due (no grants are seeded).
-- Safe to re-run.
-- =====================================================================================================================
SET ANSI_NULLS ON;
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
        CAST(CASE WHEN @BranchId IS NULL OR ph.BranchId = @BranchId THEN 1 ELSE 0 END AS BIT) AS BranchAllowed
    FROM dbo.PaymentHeader ph
    LEFT JOIN dbo.LabOrder lo           ON ph.ModuleCode = 'LAB' AND lo.LabOrderId = ph.ModuleRefId
    LEFT JOIN dbo.PatientOPDService os  ON ph.ModuleCode = 'OPD' AND os.OPDServiceId = ph.ModuleRefId
    LEFT JOIN dbo.PatientMaster p       ON p.PatientId = COALESCE(lo.PatientId, os.PatientId, ph.PatientId)
    LEFT JOIN dbo.Branchmaster b        ON b.BranchID = ph.BranchId
    LEFT JOIN dbo.Users u               ON u.Id = @ReceivedBy
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

-- ── MoneyReceipt/Print: VIEW of every page that collects a due ──
DECLARE @page INT, @ctl INT, @code NVARCHAR(150);
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID, Page_Code FROM dbo.PageMaster
    WHERE Page_Code IN (N'OPD.DASHBOARD', N'OPD.SERVICEBOOKING', N'OPD.PATIENTREGISTRATION',
                        N'LAB.LABORDERBOOKING.B2CORDERLIST', N'LAB.LABORDERBOOKING.B2CBOOKING',
                        N'LAB.LABORDERBOOKING.B2BBOOKING', N'LAB.LABORDERBOOKING.B2BREGISTRATION');
OPEN pg; FETCH NEXT FROM pg INTO @page, @code;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = (SELECT TOP 1 Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
    IF @ctl IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'MoneyReceipt', @Action = N'Print', @Route = N'MoneyReceipt/Print', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page, @code;
END
CLOSE pg; DEALLOCATE pg;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
