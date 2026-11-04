-- ============================================================================================================
-- Migration: 2400_pharmacy_debit_note_adjustment.sql
-- Pharmacy > Supplier Payments, standard debit-note flow: a purchase return (debit note) stays OPEN until it is set off
-- against the supplier's bills. On the payment screen each open bill can take "Pay now" (cash / bank) and
-- "Adjust debit note"; the adjusted amount is taken from the supplier's open debit notes, oldest first.
-- A payment may be adjustment only (no cash: mode ADJUST, no payment voucher - the debit note voucher already
-- credited the supplier's ledger when the return was posted).
--   PhDebitNoteAdjust          : which debit note covered how much of which GRN, through which payment
--   usp_Api_PhSupPay_Balances  : + Adjusted, UnadjustedDn (open debit notes); bill balance / open bills / overdue net of
--                                adjustments. Balance = purchases - returns - paid as before (negative = debit balance:
--                                the supplier owes the branch - shown as such on the page)
--   usp_Api_PhSupPay_Payables  : + Adjusted per bill (bill balance = net - paid - adjusted)
--   usp_Api_PhSupPay_DebitNotes: the supplier's open debit notes (net, adjusted, available)
--   usp_Api_PhSupPay_Save      : + @Adjust [{ GrnId, Amount }]; cash may be 0 when something is adjusted
--   usp_Api_PhSupPay_Cancel    : a cancelled payment releases its adjustments too
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.PhDebitNoteAdjust', 'U') IS NULL
CREATE TABLE dbo.PhDebitNoteAdjust
(
    AdjustId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PhDebitNoteAdjust PRIMARY KEY,
    CompanyId   INT            NOT NULL,
    BranchId    INT            NOT NULL,
    PaymentId   INT            NOT NULL,
    ReturnId    INT            NOT NULL,
    GrnId       INT            NOT NULL,
    Amount      DECIMAL(14, 2) NOT NULL,
    Status      VARCHAR(10)    NOT NULL CONSTRAINT DF_PhDebitNoteAdjust_Status DEFAULT ('POSTED'),
    CreatedBy   INT            NULL,
    CreatedDate DATETIME       NOT NULL CONSTRAINT DF_PhDebitNoteAdjust_Created DEFAULT (GETDATE())
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhDebitNoteAdjust_Grn')
    CREATE INDEX IX_PhDebitNoteAdjust_Grn ON dbo.PhDebitNoteAdjust (GrnId, Status) INCLUDE (Amount);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhDebitNoteAdjust_Return')
    CREATE INDEX IX_PhDebitNoteAdjust_Return ON dbo.PhDebitNoteAdjust (ReturnId, Status) INCLUDE (Amount);
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupPay_Balances @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    WITH g AS (
        SELECT gr.SupplierId, gr.NetAmount, gr.DueDate,
               gr.NetAmount
               - ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment p ON p.PaymentId = a.PaymentId WHERE a.GrnId = gr.GrnId AND p.Status = 'POSTED'), 0)
               - ISNULL((SELECT SUM(d.Amount) FROM dbo.PhDebitNoteAdjust d WHERE d.GrnId = gr.GrnId AND d.Status = 'POSTED'), 0) Bal
          FROM dbo.PhGrn gr WHERE gr.CompanyId = @CompanyId AND gr.BranchId = @BranchId AND gr.Status = 'POSTED'),
    dn AS (
        SELECT r.SupplierId, r.NetAmount - ISNULL((SELECT SUM(d.Amount) FROM dbo.PhDebitNoteAdjust d WHERE d.ReturnId = r.ReturnId AND d.Status = 'POSTED'), 0) Open_
          FROM dbo.PhPurchaseReturn r WHERE r.CompanyId = @CompanyId AND r.BranchId = @BranchId AND r.Status = 'POSTED')
    SELECT s.SupplierId, s.SupplierName,
           ISNULL((SELECT SUM(NetAmount) FROM g WHERE g.SupplierId = s.SupplierId), 0) Purchases,
           ISNULL((SELECT SUM(NetAmount) FROM dbo.PhPurchaseReturn r WHERE r.SupplierId = s.SupplierId AND r.BranchId = @BranchId AND r.Status = 'POSTED'), 0) Returns,
           ISNULL((SELECT SUM(Amount) FROM dbo.PhSupplierPayment p WHERE p.SupplierId = s.SupplierId AND p.BranchId = @BranchId AND p.Status = 'POSTED'), 0) Paid,
           ISNULL((SELECT SUM(d.Amount) FROM dbo.PhDebitNoteAdjust d JOIN dbo.PhPurchaseReturn r ON r.ReturnId = d.ReturnId
                    WHERE r.SupplierId = s.SupplierId AND d.BranchId = @BranchId AND d.Status = 'POSTED'), 0) Adjusted,
           ISNULL((SELECT SUM(Open_) FROM dn WHERE dn.SupplierId = s.SupplierId AND dn.Open_ > 0), 0) UnadjustedDn,
           ISNULL((SELECT SUM(Bal) FROM g WHERE g.SupplierId = s.SupplierId AND g.DueDate < CAST(GETDATE() AS DATE) AND g.Bal > 0), 0) Overdue,
           ISNULL((SELECT SUM(Bal) FROM g WHERE g.SupplierId = s.SupplierId AND g.Bal > 0), 0) BillsDue,
           (SELECT COUNT(*) FROM g WHERE g.SupplierId = s.SupplierId AND g.Bal > 0) OpenBills
      FROM dbo.PhSupplier s
     WHERE s.CompanyId = @CompanyId AND (EXISTS (SELECT 1 FROM g WHERE g.SupplierId = s.SupplierId) OR EXISTS (SELECT 1 FROM dn WHERE dn.SupplierId = s.SupplierId))
     ORDER BY s.SupplierName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupPay_Payables @CompanyId INT, @BranchId INT, @SupplierId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM (
        SELECT gr.GrnId, gr.GrnNo, gr.InvoiceNo, gr.InvoiceDate, gr.DueDate, gr.NetAmount,
               ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment p ON p.PaymentId = a.PaymentId WHERE a.GrnId = gr.GrnId AND p.Status = 'POSTED'), 0) Paid,
               ISNULL((SELECT SUM(d.Amount) FROM dbo.PhDebitNoteAdjust d WHERE d.GrnId = gr.GrnId AND d.Status = 'POSTED'), 0) Adjusted
          FROM dbo.PhGrn gr WHERE gr.CompanyId = @CompanyId AND gr.BranchId = @BranchId AND gr.SupplierId = @SupplierId AND gr.Status = 'POSTED') x
     WHERE x.NetAmount - x.Paid - x.Adjusted > 0
     ORDER BY ISNULL(x.DueDate, x.InvoiceDate), x.GrnId;
END
GO

-- the supplier's open debit notes, oldest first
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupPay_DebitNotes @CompanyId INT, @BranchId INT, @SupplierId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM (
        SELECT r.ReturnId, r.ReturnNo, r.ReturnDate, r.NetAmount,
               ISNULL((SELECT SUM(d.Amount) FROM dbo.PhDebitNoteAdjust d WHERE d.ReturnId = r.ReturnId AND d.Status = 'POSTED'), 0) Adjusted
          FROM dbo.PhPurchaseReturn r
         WHERE r.CompanyId = @CompanyId AND r.BranchId = @BranchId AND r.SupplierId = @SupplierId AND r.Status = 'POSTED') x
     WHERE x.NetAmount - x.Adjusted > 0
     ORDER BY x.ReturnDate, x.ReturnId;
END
GO

-- checked in EMR.Web (mode, reference, date, amounts >= 0); balances checked here.
-- @Alloc: cash paid per bill [{ GrnId, Amount }]; @Adjust: debit note set off per bill [{ GrnId, Amount }] (2400)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupPay_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @SupplierId INT, @Date DATE, @Mode VARCHAR(10), @Reference NVARCHAR(50) = NULL, @Remarks NVARCHAR(300) = NULL,
    @Alloc NVARCHAR(MAX), @Adjust NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
    DECLARE @A TABLE (GrnId INT PRIMARY KEY, Cash DECIMAL(14,2), Adj DECIMAL(14,2), Bal DECIMAL(14,2));
    DECLARE @no NVARCHAR(40), @id INT, @cash DECIMAL(14,2), @adj DECIMAL(14,2), @avail DECIMAL(14,2);
    BEGIN TRY
        BEGIN TRAN;
        ;WITH c AS (SELECT GrnId, SUM(Amount) Amount FROM OPENJSON(ISNULL(@Alloc, '[]')) WITH (GrnId INT, Amount DECIMAL(14,2)) WHERE Amount > 0 GROUP BY GrnId),
              j AS (SELECT GrnId, SUM(Amount) Amount FROM OPENJSON(ISNULL(@Adjust, '[]')) WITH (GrnId INT, Amount DECIMAL(14,2)) WHERE Amount > 0 GROUP BY GrnId),
              k AS (SELECT GrnId FROM c UNION SELECT GrnId FROM j)
        INSERT @A (GrnId, Cash, Adj, Bal)
        SELECT k.GrnId, ISNULL(c.Amount, 0), ISNULL(j.Amount, 0), b.Bal
          FROM k LEFT JOIN c ON c.GrnId = k.GrnId LEFT JOIN j ON j.GrnId = k.GrnId
          OUTER APPLY (SELECT gr.NetAmount
                              - ISNULL((SELECT SUM(x.Amount) FROM dbo.PhSupplierPaymentAlloc x JOIN dbo.PhSupplierPayment p ON p.PaymentId = x.PaymentId
                                         WHERE x.GrnId = gr.GrnId AND p.Status = 'POSTED'), 0)
                              - ISNULL((SELECT SUM(d.Amount) FROM dbo.PhDebitNoteAdjust d WHERE d.GrnId = gr.GrnId AND d.Status = 'POSTED'), 0) AS Bal
                         FROM dbo.PhGrn gr WITH (UPDLOCK)
                        WHERE gr.GrnId = k.GrnId AND gr.CompanyId = @CompanyId AND gr.BranchId = @BranchId AND gr.SupplierId = @SupplierId AND gr.Status = 'POSTED') b;

        IF NOT EXISTS (SELECT 1 FROM @A)
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Enter the amount paid or adjusted against at least one bill.' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM @A WHERE Bal IS NULL OR Cash + Adj > Bal)
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Paid + adjusted is more than a bill''s balance.' AS Error; RETURN; END;

        SELECT @cash = SUM(Cash), @adj = SUM(Adj) FROM @A;
        -- the supplier's open debit notes, locked, oldest first
        DECLARE @DN TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ReturnId INT, Avail DECIMAL(14,2));
        INSERT @DN (ReturnId, Avail)
        SELECT r.ReturnId, r.NetAmount - ISNULL((SELECT SUM(d.Amount) FROM dbo.PhDebitNoteAdjust d WHERE d.ReturnId = r.ReturnId AND d.Status = 'POSTED'), 0)
          FROM dbo.PhPurchaseReturn r WITH (UPDLOCK)
         WHERE r.CompanyId = @CompanyId AND r.BranchId = @BranchId AND r.SupplierId = @SupplierId AND r.Status = 'POSTED'
         ORDER BY r.ReturnDate, r.ReturnId;
        DELETE FROM @DN WHERE Avail <= 0;
        SELECT @avail = ISNULL(SUM(Avail), 0) FROM @DN;
        IF @adj > @avail
        BEGIN
            ROLLBACK;
            SELECT 0 AS Id, N'Only ' + FORMAT(@avail, 'N2') + N' of debit notes is open for this supplier; adjust no more than that.' AS Error;
            RETURN;
        END;

        IF @cash = 0 SET @Mode = 'ADJUST';
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'SPAY', @DocDate = @Date, @DocNo = @no OUTPUT;
        INSERT dbo.PhSupplierPayment (CompanyId, BranchId, PaymentNo, PaymentDate, SupplierId, PaymentMode, ReferenceNo, Amount, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @no, @Date, @SupplierId, @Mode, NULLIF(LTRIM(RTRIM(@Reference)), N''), @cash,
                NULLIF(LTRIM(RTRIM(CONCAT(@Remarks, CASE WHEN @adj > 0 THEN CONCAT(CASE WHEN NULLIF(LTRIM(RTRIM(@Remarks)), N'') IS NULL THEN N'' ELSE N' · ' END,
                       N'Debit notes adjusted ', FORMAT(@adj, 'N2')) END))), N''), @UserId);
        SET @id = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.PhSupplierPaymentAlloc (PaymentId, GrnId, Amount) SELECT @id, GrnId, Cash FROM @A WHERE Cash > 0;

        -- debit notes set off bill by bill: each bill's adjustment takes the oldest open debit notes first
        DECLARE @g INT, @need DECIMAL(14,2), @seq INT, @take DECIMAL(14,2);
        DECLARE ac CURSOR LOCAL FAST_FORWARD FOR SELECT GrnId, Adj FROM @A WHERE Adj > 0 ORDER BY GrnId;
        OPEN ac; FETCH NEXT FROM ac INTO @g, @need;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            WHILE @need > 0
            BEGIN
                SELECT TOP 1 @seq = Seq, @take = CASE WHEN Avail < @need THEN Avail ELSE @need END FROM @DN WHERE Avail > 0 ORDER BY Seq;
                INSERT dbo.PhDebitNoteAdjust (CompanyId, BranchId, PaymentId, ReturnId, GrnId, Amount, CreatedBy)
                SELECT @CompanyId, @BranchId, @id, ReturnId, @g, @take, @UserId FROM @DN WHERE Seq = @seq;
                UPDATE @DN SET Avail = Avail - @take WHERE Seq = @seq;
                SET @need -= @take;
            END
            FETCH NEXT FROM ac INTO @g, @need;
        END
        CLOSE ac; DEALLOCATE ac;

        IF @cash > 0 EXEC dbo.usp_Ph_PostLedger @Kind = 'SPAY', @RefId = @id, @UserId = @UserId;   -- Payment voucher (2347): the cash part only
        COMMIT;
        SELECT @id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 53999 SELECT 0 AS Id, N'Not saved - accounts: ' + ERROR_MESSAGE() AS Error;
        ELSE THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupPay_Cancel @CompanyId INT, @BranchId INT, @Id INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        UPDATE dbo.PhSupplierPayment SET Status = 'CANCELLED' WHERE PaymentId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status = 'POSTED';
        IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT N'Payment not found or already cancelled.' AS Error; RETURN; END;
        UPDATE dbo.PhDebitNoteAdjust SET Status = 'CANCELLED' WHERE PaymentId = @Id AND Status = 'POSTED';   -- 2400: the debit notes are open again
        EXEC dbo.usp_Ph_PostLedger @Kind = 'SPAYX', @RefId = @Id, @UserId = @UserId;   -- reverses the Payment voucher (none for adjustment only)
        COMMIT;
        SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 53999 SELECT N'Not cancelled - accounts: ' + ERROR_MESSAGE() AS Error;
        ELSE THROW;
    END CATCH
END
GO

PRINT 'Script 2400 applied: debit notes adjusted against supplier bills at payment.';
GO
