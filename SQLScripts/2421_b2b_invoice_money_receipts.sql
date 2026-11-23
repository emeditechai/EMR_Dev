-- ============================================================================================================
-- 2421  B2B Invoices > Actions > Money Receipts: the receipts that paid an invoice's bills (a settlement receipt can pay
--       bills of several invoices; the amount here is the part applied to this invoice). Endpoint on the page's DETAILS
--       control. No table changes. Re-runnable.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetInvoiceReceipts @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pd.ReceiptNo,
           MIN(COALESCE(pd.PaymentDate, pd.CreatedDate)) AS ReceiptDate,
           MAX(ISNULL(pm.MethodName, 'Cash')) AS PaymentMethod,
           MAX(pd.TransactionRef) AS TransactionRef, MAX(pd.BankName) AS BankName, MAX(pd.ChequeNo) AS ChequeNo,
           CAST(SUM(pd.PaidAmount) AS DECIMAL(14,2)) AS AmountForInvoice,
           COUNT(DISTINCT ph.ModuleRefId) AS Bills,
           (SELECT CAST(SUM(x.PaidAmount) AS DECIMAL(14,2)) FROM dbo.PaymentDetail x WHERE x.ReceiptNo = pd.ReceiptNo AND x.IsActive = 1) AS ReceiptTotal,
           MAX(u.FullName) AS ReceivedBy
      FROM dbo.B2BInvoiceItem bii
      JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = bii.LabOrderId AND ph.IsActive = 1
      JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1 AND NULLIF(pd.ReceiptNo, '') IS NOT NULL
      LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
      LEFT JOIN dbo.Users u ON u.Id = pd.CreatedBy
     WHERE bii.InvoiceId = @InvoiceId
     GROUP BY pd.ReceiptNo
     ORDER BY MIN(COALESCE(pd.PaymentDate, pd.CreatedDate)) DESC, pd.ReceiptNo DESC;
END
GO
DECLARE @co INT, @page INT, @ctl INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT p.CompanyId FROM dbo.PageMaster p WHERE p.Page_Code = 'LAB.LABORDERBOOKING.B2BINVOICES';
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @page = NULL; SET @ctl = NULL;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = 'LAB.LABORDERBOOKING.B2BINVOICES' AND CompanyId = @co;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'DETAILS';
    IF @ctl IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'LabOrderBooking', @Action = N'B2BInvoiceReceipts', @Source = 'SEED';
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2421 applied: B2B invoice money receipts.';
GO
