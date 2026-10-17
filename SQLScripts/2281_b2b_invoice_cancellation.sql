-- ============================================================================================================
-- Migration: 2281_b2b_invoice_cancellation.sql
-- LAB > B2B Invoices: cancel an invoice (Actions > Cancel), with a reason, under a permission of its own.
--   Rules: only an invoice with nothing received (status Unpaid, paid amount 0) can be cancelled - a part paid or paid
--   invoice must have its settlement reversed first. A franchise login can cancel only its own franchise's invoices.
--   Effect: the invoice is kept as a record with status C (Cancelled), who / when / why; its lines stay as history,
--   and its bills become un-invoiced again, so they can be put on a new invoice (the uninvoiced list, settlement and
--   credit checks already skip status C). No ledger entry: invoices are not posted (the bills are).
--   Consistency: settlement no longer recalculates a cancelled invoice; the B2B Outstanding and Partner Billing
--   reports and the B2B bill-cancellation check ignore cancelled invoices.
--   Permission: control CANCEL on page LAB.LABORDERBOOKING.B2BINVOICES (endpoint POST LabOrderBooking/CancelB2BInvoice).
--   No role or user grant is seeded - set it in Settings > Security > Role Permissions.
-- Safe to re-run. Run after 2280.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.B2BInvoice', 'CancelReason') IS NULL
    ALTER TABLE dbo.B2BInvoice ADD CancelledBy INT NULL, CancelledDate DATETIME NULL, CancelReason NVARCHAR(500) NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_B2B_CancelInvoice
    @InvoiceId   INT,
    @Reason      NVARCHAR(500),
    @UserId      INT,
    @FranchiseId INT = NULL          -- a franchise login: only its own franchise's invoices
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @no NVARCHAR(50), @status VARCHAR(10), @paid DECIMAL(18, 2), @type CHAR(1), @partner INT, @msg NVARCHAR(400);
    SELECT @no = InvoiceNo, @status = Status, @paid = ISNULL(PaidAmount, 0), @type = PartnerType, @partner = PartnerId
    FROM dbo.B2BInvoice WITH (UPDLOCK, HOLDLOCK) WHERE InvoiceId = @InvoiceId;

    IF @no IS NULL THROW 50290, 'Invoice not found.', 1;
    IF @FranchiseId IS NOT NULL AND NOT (@type = 'F' AND @partner = @FranchiseId)
        THROW 50291, 'You can only cancel your own franchise''s invoices.', 1;
    IF @status = 'C' THROW 50292, 'This invoice is already cancelled.', 1;
    IF @status <> 'U' OR @paid > 0
    BEGIN
        SET @msg = CONCAT('Invoice ', @no, ' has payments received (', FORMAT(@paid, 'N2'),
                          '). Only an unpaid invoice can be cancelled: reverse its settlement first.');
        THROW 50293, @msg, 1;
    END
    IF NULLIF(LTRIM(RTRIM(@Reason)), '') IS NULL THROW 50294, 'Enter the reason for cancelling the invoice.', 1;

    UPDATE dbo.B2BInvoice
    SET Status = 'C', CancelledBy = @UserId, CancelledDate = GETDATE(), CancelReason = LTRIM(RTRIM(@Reason)),
        ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE InvoiceId = @InvoiceId AND Status = 'U';
    IF @@ROWCOUNT = 0 THROW 50292, 'This invoice was changed by someone else; reload and try again.', 1;

    SELECT @InvoiceId AS InvoiceId, @no AS InvoiceNo,
           (SELECT COUNT(1) FROM dbo.B2BInvoiceItem WHERE InvoiceId = @InvoiceId) AS BillsReleased;
END;
GO

-- ── cancelled invoices ignored elsewhere ─────────────────────────────────────────────────────────────────────
DECLARE @fix TABLE (ProcName SYSNAME, FindText NVARCHAR(400), ReplaceText NVARCHAR(400));
INSERT INTO @fix VALUES
 (N'dbo.usp_B2B_SettleBillsPayment', N'WHERE bi.InvoiceId IN (', N'WHERE ISNULL(bi.Status, '''') <> ''C'' AND bi.InvoiceId IN ('),
 (N'dbo.usp_Api_LabReport_B2BOutstanding', N'WHERE ii.LabOrderId = lo.LabOrderId ORDER BY i.InvoiceId DESC) inv',
     N'WHERE ii.LabOrderId = lo.LabOrderId AND ISNULL(i.Status, '''') <> ''C'' ORDER BY i.InvoiceId DESC) inv'),
 (N'dbo.usp_Api_LabReport_B2BPartnerBilling', N'WHERE ii.LabOrderId = lo.LabOrderId ORDER BY i.InvoiceId DESC) inv',
     N'WHERE ii.LabOrderId = lo.LabOrderId AND ISNULL(i.Status, '''') <> ''C'' ORDER BY i.InvoiceId DESC) inv'),
 (N'dbo.usp_Bill_Cancel', N'WHERE ii.LabOrderId = @ModuleRefId ORDER BY i.InvoiceId DESC);',
     N'WHERE ii.LabOrderId = @ModuleRefId AND ISNULL(i.Status, '''') <> ''C'' ORDER BY i.InvoiceId DESC);'),
 (N'dbo.usp_Bill_GetDetailForCancellation', N'WHERE ii.LabOrderId = @ModuleRefId ORDER BY i.InvoiceId DESC);',
     N'WHERE ii.LabOrderId = @ModuleRefId AND ISNULL(i.Status, '''') <> ''C'' ORDER BY i.InvoiceId DESC);');
DECLARE @p SYSNAME, @f NVARCHAR(400), @r NVARCHAR(400), @def NVARCHAR(MAX), @c INT;
DECLARE fc CURSOR LOCAL FAST_FORWARD FOR SELECT ProcName, FindText, ReplaceText FROM @fix;
OPEN fc; FETCH NEXT FROM fc INTO @p, @f, @r;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @def = OBJECT_DEFINITION(OBJECT_ID(@p));
    IF @def IS NULL THROW 55310, 'A B2B procedure was not found; not changed.', 1;
    IF CHARINDEX(@r, @def) = 0                       -- not patched yet
    BEGIN
        IF CHARINDEX(@f, @def) = 0 THROW 55311, 'Anchor not found in a B2B procedure; not changed.', 1;
        SET @def = REPLACE(@def, @f, @r);
        SET @c = PATINDEX(N'%CREATE%PROCEDURE%', @def);
        SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
        IF @def IS NULL THROW 55312, 'A B2B procedure text could not be prepared; not changed.', 1;
        EXEC sys.sp_executesql @def;
    END
    FETCH NEXT FROM fc INTO @p, @f, @r;
END
CLOSE fc; DEALLOCATE fc;
GO

-- ── permission: control CANCEL on the B2B Invoices page, and its endpoint (no grant) ────────────────────────
DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABORDERBOOKING.B2BINVOICES';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'CANCEL', @Title = N'Cancel an invoice', @Sort_Order = 40, @Control_ID = @ctl OUTPUT;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'CANCEL';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabOrderBooking', @Action = N'CancelB2BInvoice', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2281 applied: B2B invoice cancellation.';
GO
