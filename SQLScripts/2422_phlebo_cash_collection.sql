-- 2422: Phlebotomist app - Cash Collection screen (Dashboard > Cash held).
--   Lists the payments the phlebotomist took at the door between two dates (today by default), with totals by mode,
--   and the cash held now (PhleboCashLedger: + collected, - deposited). Read only.

CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_CashCollection
    @UserId   INT,
    @FromDate DATE = NULL,
    @ToDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @FromDate = ISNULL(@FromDate, CAST(GETDATE() AS DATE));
    SET @ToDate = ISNULL(@ToDate, @FromDate);
    IF @ToDate < @FromDate BEGIN RAISERROR('The To date cannot be before the From date.', 16, 1); RETURN; END
    IF DATEDIFF(DAY, @FromDate, @ToDate) > 92 BEGIN RAISERROR('Choose a range of 3 months or less.', 16, 1); RETURN; END

    DECLARE @Rows TABLE (PaymentDetailId INT, PaidAt DATETIME, MethodCode VARCHAR(10), Amount DECIMAL(12, 2), ReceiptNo NVARCHAR(50),
                         Reference NVARCHAR(100), LabOrderId INT, BillNo NVARCHAR(50), PatientName NVARCHAR(200), PatientCode NVARCHAR(50));

    INSERT @Rows
    SELECT d.PaymentDetailId, d.PaymentDate, m.MethodCode, d.PaidAmount, d.ReceiptNo, COALESCE(d.UPIRefNo, d.TransactionRef),
           o.LabOrderId, o.BillNo, LTRIM(RTRIM(CONCAT(p.Salutation, N' ', p.FirstName, N' ', p.LastName))), p.PatientCode
      FROM dbo.PaymentDetail d
      JOIN dbo.PaymentMethodMaster m ON m.PaymentMethodId = d.PaymentMethodId
      JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = d.PaymentHeaderId AND ph.ModuleCode = 'LAB'
      JOIN dbo.LabOrder o ON o.LabOrderId = ph.ModuleRefId
      LEFT JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
     WHERE d.CreatedBy = @UserId AND d.Notes = N'Phlebotomist app' AND d.IsActive = 1
       AND d.PaymentDate >= @FromDate AND d.PaymentDate < DATEADD(DAY, 1, @ToDate);

    -- totals for the range, and the cash still with the phlebotomist today
    SELECT @FromDate AS FromDate, @ToDate AS ToDate,
           ISNULL(SUM(Amount), 0) AS Total,
           ISNULL(SUM(CASE WHEN MethodCode = 'CASH' THEN Amount END), 0) AS Cash,
           ISNULL(SUM(CASE WHEN MethodCode = 'UPI' THEN Amount END), 0) AS Upi,
           ISNULL(SUM(CASE WHEN MethodCode = 'CARD' THEN Amount END), 0) AS Card,
           COUNT(*) AS Payments,
           ISNULL((SELECT SUM(Amount) FROM dbo.PhleboCashLedger WHERE UserId = @UserId AND EntryType <> 'COLLECT'
                    AND CreatedDate >= @FromDate AND CreatedDate < DATEADD(DAY, 1, @ToDate)), 0) * -1 AS Deposited,
           ISNULL((SELECT SUM(Amount) FROM dbo.PhleboCashLedger WHERE UserId = @UserId), 0) AS CashHeld
      FROM @Rows;

    SELECT PaymentDetailId, PaidAt, MethodCode, Amount, ReceiptNo, Reference, LabOrderId, BillNo, PatientName, PatientCode
      FROM @Rows ORDER BY PaidAt DESC;
END
GO
