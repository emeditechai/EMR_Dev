-- ============================================================================
-- Migration: 2056_b2b_invoice_and_settlement_payable_cap_validation.sql
-- Description: Enforce strict payable-amount capping on B2B Invoices & Settlements.
--              Paid amount can NEVER exceed invoice NetAmount or bill B2BTotal.
--              Balance amount can NEVER be negative.
-- ============================================================================

-- ── 1. Fix usp_B2B_GetOutstandingBillsForSettlement ──────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetOutstandingBillsForSettlement
    @AgentType VARCHAR(10), -- 'F' or 'C'
    @AgentId   INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Return all unpaid/partially paid B2B LabOrders where remaining B2B balance > 0
    SELECT 
        lo.LabOrderId,
        lo.BillNo,
        lo.OrderDate,
        ISNULL(lo.DueDate, DATEADD(DAY, 30, lo.OrderDate)) AS DueDate,
        ISNULL(lo.B2BTotal, lo.TotalAmount) AS BillAmount,
        CASE 
            WHEN ISNULL(ph.TotalPaid, 0.00) >= ISNULL(lo.B2BTotal, lo.TotalAmount) 
                THEN ISNULL(lo.B2BTotal, lo.TotalAmount)
            ELSE ISNULL(ph.TotalPaid, 0.00)
        END AS PaidAmount,
        CASE 
            WHEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) <= 0 
                THEN 0.00 
            ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) 
        END AS BalanceDue,
        CASE 
            WHEN ISNULL(ph.TotalPaid, 0.00) >= ISNULL(lo.B2BTotal, lo.TotalAmount) THEN 'P'
            WHEN ISNULL(ph.TotalPaid, 0.00) > 0 THEN 'R'
            ELSE 'U'
        END AS PaymentStatus,
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber AS PatientPhone,
        bii.InvoiceId,
        bi.InvoiceNo,
        CASE WHEN ISNULL(lo.DueDate, DATEADD(DAY, 30, lo.OrderDate)) < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END AS IsOverdue,
        DATEDIFF(DAY, ISNULL(lo.DueDate, DATEADD(DAY, 30, lo.OrderDate)), CAST(GETDATE() AS DATE)) AS OverdueDays,
        STUFF((
            SELECT ', ' + CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Profile') ELSE ISNULL(sm.Test_Name, 'Test') END
            FROM dbo.LabOrderItem si
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster sm ON sm.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
            WHERE si.LabOrderId = lo.LabOrderId AND si.IsActive = 1
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS TestNames
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.B2BInvoiceItem bii ON bii.LabOrderId = lo.LabOrderId
    LEFT JOIN dbo.B2BInvoice bi ON bi.InvoiceId = bii.InvoiceId AND bi.Status <> 'C'
    WHERE lo.IsB2B = 1
      AND lo.AgentType = @AgentType
      AND lo.B2BAgentID = @AgentId
      AND lo.IsActive = 1
      AND (ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0.00)) > 0.00
    ORDER BY lo.OrderDate ASC;
END;
GO

-- ── 2. Fix usp_B2B_SettleBillsPayment ─────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_B2B_SettleBillsPayment
    @AgentType        VARCHAR(10), -- 'F' or 'C'
    @AgentId          INT,
    @BranchId         INT,
    @PaymentMethodId  INT,
    @PaidAmount       DECIMAL(18,2),
    @TransactionRef   NVARCHAR(100) = NULL,
    @BankName         NVARCHAR(100) = NULL,
    @ChequeNo         NVARCHAR(50) = NULL,
    @ChequeDate       DATETIME2 = NULL,
    @PaymentDate      DATETIME2 = NULL,
    @SelectedBillsJson NVARCHAR(MAX), -- JSON array: [{"LabOrderId": 1, "PayAmount": 150.00}, ...]
    @Notes            NVARCHAR(500) = NULL,
    @UserId           INT = 1,
    @BatchReceiptNo   NVARCHAR(50) OUTPUT,
    @SettledBillCount INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @PaymentDate IS NULL SET @PaymentDate = GETDATE();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Generate Batch Receipt Number
        DECLARE @BranchCode NVARCHAR(10) = 'HO';
        SELECT @BranchCode = ISNULL(BranchCode, 'HO') FROM dbo.Branchmaster WHERE BranchId = @BranchId;

        DECLARE @DatePart VARCHAR(8) = FORMAT(GETDATE(), 'ddMMyyyy');
        DECLARE @FinancialYear VARCHAR(10);
        DECLARE @Today DATE = CAST(GETDATE() AS DATE);
        DECLARE @Year INT = YEAR(@Today);
        DECLARE @Month INT = MONTH(@Today);
        IF @Month >= 4
            SET @FinancialYear = CAST(@Year AS VARCHAR(4)) + '-' + CAST((@Year + 1) AS VARCHAR(4));
        ELSE
            SET @FinancialYear = CAST((@Year - 1) AS VARCHAR(4)) + '-' + CAST(@Year AS VARCHAR(4));

        DECLARE @NextSeq INT;
        UPDATE dbo.ReceiptSequence
        SET LastSeq = LastSeq + 1, @NextSeq = LastSeq + 1
        WHERE BranchId = @BranchId AND FinancialYear = @FinancialYear;

        IF @NextSeq IS NULL
        BEGIN
            SET @NextSeq = 1;
            INSERT INTO dbo.ReceiptSequence (BranchId, FinancialYear, LastSeq)
            VALUES (@BranchId, @FinancialYear, @NextSeq);
        END

        SET @BatchReceiptNo = @BranchCode + @DatePart + RIGHT('000000' + CAST(@NextSeq AS VARCHAR(10)), 6);

        -- Parse JSON array of bills
        DECLARE @BillsTable TABLE (LabOrderId INT, PayAmount DECIMAL(18,2));
        INSERT INTO @BillsTable (LabOrderId, PayAmount)
        SELECT 
            CAST(JSON_VALUE(value, '$.LabOrderId') AS INT),
            CAST(JSON_VALUE(value, '$.PayAmount') AS DECIMAL(18,2))
        FROM OPENJSON(@SelectedBillsJson);

        SET @SettledBillCount = (SELECT COUNT(1) FROM @BillsTable WHERE PayAmount > 0);

        -- 2. Process each bill
        DECLARE @CurOrderId INT, @CurPayAmt DECIMAL(18,2);
        DECLARE bill_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT LabOrderId, PayAmount FROM @BillsTable WHERE PayAmount > 0;

        OPEN bill_cursor;
        FETCH NEXT FROM bill_cursor INTO @CurOrderId, @CurPayAmt;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @PhId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = 'LAB' AND ModuleRefId = @CurOrderId AND IsActive = 1);
            DECLARE @OrderBillTotal DECIMAL(18,2) = (SELECT TOP 1 ISNULL(B2BTotal, TotalAmount) FROM dbo.LabOrder WHERE LabOrderId = @CurOrderId);
            DECLARE @PatientId INT = (SELECT TOP 1 PatientId FROM dbo.LabOrder WHERE LabOrderId = @CurOrderId);
            DECLARE @PaidSoFar DECIMAL(18,2) = (SELECT TOP 1 ISNULL(TotalPaid, 0.00) FROM dbo.PaymentHeader WHERE PaymentHeaderId = @PhId);
            DECLARE @RemainingB2BDue DECIMAL(18,2) = CASE WHEN @OrderBillTotal - @PaidSoFar <= 0 THEN 0.00 ELSE @OrderBillTotal - @PaidSoFar END;

            -- Validation / Capping: A bill payment can never exceed its remaining B2B payable amount
            IF @CurPayAmt > @RemainingB2BDue
                SET @CurPayAmt = @RemainingB2BDue;

            IF @CurPayAmt > 0
            BEGIN
                IF @PhId IS NULL
                BEGIN
                    INSERT INTO dbo.PaymentHeader
                        (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive)
                    VALUES
                        ('LAB', @CurOrderId, @BranchId, @PatientId, @OrderBillTotal, @OrderBillTotal, @CurPayAmt, 
                         CASE WHEN @OrderBillTotal - @CurPayAmt <= 0 THEN 0.00 ELSE @OrderBillTotal - @CurPayAmt END, 
                         CASE WHEN @CurPayAmt >= @OrderBillTotal THEN 'P' ELSE 'R' END, @Notes, GETDATE(), @UserId, 1);
                    SET @PhId = SCOPE_IDENTITY();
                END
                ELSE
                BEGIN
                    UPDATE dbo.PaymentHeader
                    SET TotalPaid = TotalPaid + @CurPayAmt,
                        BalanceDue = CASE WHEN @OrderBillTotal - (TotalPaid + @CurPayAmt) <= 0 THEN 0.00 ELSE @OrderBillTotal - (TotalPaid + @CurPayAmt) END,
                        PaymentStatus = CASE WHEN (TotalPaid + @CurPayAmt) >= @OrderBillTotal THEN 'P' ELSE 'R' END,
                        LastModifiedDate = GETDATE(),
                        LastModifiedBy = @UserId
                    WHERE PaymentHeaderId = @PhId;
                END

                -- Insert PaymentDetail
                INSERT INTO dbo.PaymentDetail
                    (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, BankName, ChequeNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo)
                VALUES
                    (@PhId, @PaymentMethodId, @CurPayAmt, @TransactionRef, @BankName, @ChequeNo, @PaymentDate, @Notes, GETDATE(), @UserId, 1, @BatchReceiptNo);

                -- Assign Token if bill is fully paid
                DECLARE @CurBal DECIMAL(18,2) = (SELECT BalanceDue FROM dbo.PaymentHeader WHERE PaymentHeaderId = @PhId);
                IF @CurBal <= 0
                BEGIN
                    DECLARE @AssignedToken NVARCHAR(20);
                    EXEC dbo.usp_LAB_AssignTokenOnPayment @LabOrderId = @CurOrderId, @TokenNo = @AssignedToken OUTPUT;
                END
            END

            FETCH NEXT FROM bill_cursor INTO @CurOrderId, @CurPayAmt;
        END

        CLOSE bill_cursor;
        DEALLOCATE bill_cursor;

        -- 3. Update any affected B2B Invoices (Strictly Capped to NetAmount)
        UPDATE bi
        SET PaidAmount = CASE 
                WHEN ISNULL(c.CappedPaid, 0) >= bi.NetAmount THEN bi.NetAmount 
                ELSE ISNULL(c.CappedPaid, 0) 
            END,
            BalanceAmount = CASE 
                WHEN bi.NetAmount - ISNULL(c.CappedPaid, 0) <= 0 THEN 0.00 
                ELSE bi.NetAmount - ISNULL(c.CappedPaid, 0) 
            END,
            Status = CASE 
                WHEN bi.NetAmount - ISNULL(c.CappedPaid, 0) <= 0 THEN 'P'
                WHEN ISNULL(c.CappedPaid, 0) > 0 THEN 'R'
                ELSE 'U'
            END
        FROM dbo.B2BInvoice bi
        OUTER APPLY (
            SELECT SUM(
                CASE 
                    WHEN ISNULL(ph.TotalPaid, 0) >= bii.Amount THEN bii.Amount 
                    ELSE ISNULL(ph.TotalPaid, 0) 
                END
            ) AS CappedPaid
            FROM dbo.B2BInvoiceItem bii
            LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = bii.LabOrderId AND ph.IsActive = 1
            WHERE bii.InvoiceId = bi.InvoiceId
        ) c
        WHERE bi.InvoiceId IN (
            SELECT DISTINCT bii.InvoiceId 
            FROM dbo.B2BInvoiceItem bii
            INNER JOIN @BillsTable bt ON bt.LabOrderId = bii.LabOrderId
        );

        -- 4. Post Consolidated Ledger Entry
        -- Dr: Bank Account / Cash Account
        -- Cr: Franchise Receivable / Corporate Receivable
        DECLARE @VoucherTypeId INT = (SELECT TOP 1 VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
        IF @VoucherTypeId IS NULL
        BEGIN
            INSERT INTO Acc_VoucherType (VoucherTypeName, Prefix, IsActive) VALUES ('Receipt', 'RCT', 1);
            SET @VoucherTypeId = SCOPE_IDENTITY();
        END

        DECLARE @DebitLedgerName NVARCHAR(100) = 'Bank Account';
        IF EXISTS (SELECT 1 FROM PaymentMethodMaster WHERE PaymentMethodId = @PaymentMethodId AND (MethodCode = 'CASH' OR MethodName = 'Cash'))
            SET @DebitLedgerName = 'Cash Account';

        DECLARE @DebitLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = @DebitLedgerName);
        IF @DebitLedgerId IS NULL
        BEGIN
            DECLARE @AssetGrp INT = (SELECT TOP 1 LedgerGroupId FROM Acc_LedgerGroup WHERE GroupName = 'Current Assets' OR GroupType = 'Asset');
            INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
            VALUES (@DebitLedgerName, @AssetGrp, 0, 'Dr', 1, GETDATE());
            SET @DebitLedgerId = SCOPE_IDENTITY();
        END

        DECLARE @CreditLedgerName NVARCHAR(100) = CASE WHEN @AgentType = 'C' THEN 'Corporate Receivable' ELSE 'Franchise Receivable' END;
        DECLARE @CreditLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = @CreditLedgerName);

        DECLARE @PartnerTitle NVARCHAR(100) = CASE 
            WHEN @AgentType = 'F' THEN (SELECT Franchise_Name FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @AgentId)
            WHEN @AgentType = 'C' THEN (SELECT Corporate_Name FROM dbo.CorporateMaster WHERE Corporate_ID = @AgentId)
            ELSE 'B2B Partner'
        END;

        DECLARE @SettleNarration NVARCHAR(500) = 'B2B settlement payment for ' + @PartnerTitle + ' (' + CAST(@SettledBillCount AS NVARCHAR(10)) + ' bills, Receipt: ' + @BatchReceiptNo + ')';
        DECLARE @NewTxId BIGINT;
        IF @DebitLedgerId IS NOT NULL AND @CreditLedgerId IS NOT NULL AND @VoucherTypeId IS NOT NULL
        BEGIN
            EXEC dbo.usp_Ledger_PostEntry
                @VoucherTypeId   = @VoucherTypeId,
                @TransactionDate = @PaymentDate,
                @ReferenceType   = 'B2B_SETTLEMENT',
                @ReferenceId     = @AgentId,
                @BranchId        = @BranchId,
                @CompanyId       = 1,
                @TotalAmount     = @PaidAmount,
                @Narration       = @SettleNarration,
                @DebitLedgerId   = @DebitLedgerId,
                @CreditLedgerId  = @CreditLedgerId,
                @CreatedBy       = @UserId,
                @NewTransactionId = @NewTxId OUTPUT;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── 3. Fix usp_B2B_GenerateInvoice ───────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GenerateInvoice
    @AgentType        VARCHAR(10), -- 'F' or 'C'
    @AgentId          INT,
    @BranchId         INT,
    @SelectedOrderIds NVARCHAR(MAX), -- comma-separated list of LabOrderIds
    @BillingCycle     NVARCHAR(50) = 'On-Demand',
    @Notes            NVARCHAR(MAX) = NULL,
    @UserId           INT = 1,
    @InvoiceId        INT OUTPUT,
    @InvoiceNo        NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Determine Credit Days
        DECLARE @CreditDays INT = 0;
        IF @AgentType = 'F'
        BEGIN
            SELECT @CreditDays = ISNULL(c.Credit_Days, 0)
            FROM dbo.LabFranchiseCreditLimitMaster c
            WHERE c.Franchise_ID = @AgentId;
        END
        ELSE IF @AgentType = 'C'
        BEGIN
            SELECT @CreditDays = ISNULL(c.Credit_Days, 0), @BillingCycle = ISNULL(@BillingCycle, c.BillingCycle)
            FROM dbo.CorporateMaster c
            WHERE c.Corporate_ID = @AgentId;
        END

        IF @CreditDays <= 0 SET @CreditDays = 30;

        -- 2. Generate Invoice Number: B2B-INV-YYYYMM-XXXXX
        DECLARE @YearMonth NVARCHAR(6) = FORMAT(GETDATE(), 'yyyyMM');
        DECLARE @NextNum INT;
        SELECT @NextNum = ISNULL(MAX(InvoiceId), 0) + 1 FROM dbo.B2BInvoice;
        SET @InvoiceNo = 'B2B-INV-' + @YearMonth + '-' + RIGHT('00000' + CAST(@NextNum AS VARCHAR(10)), 5);

        -- 3. Calculate Totals from selected orders
        DECLARE @TotalAmount DECIMAL(18,2) = 0.00;
        DECLARE @DueDate DATETIME2 = DATEADD(DAY, @CreditDays, GETDATE());

        DECLARE @OrderList TABLE (LabOrderId INT);
        INSERT INTO @OrderList (LabOrderId)
        SELECT CAST(value AS INT) 
        FROM STRING_SPLIT(@SelectedOrderIds, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

        SELECT @TotalAmount = ISNULL(SUM(ISNULL(lo.B2BTotal, lo.TotalAmount)), 0.00)
        FROM dbo.LabOrder lo
        INNER JOIN @OrderList ol ON ol.LabOrderId = lo.LabOrderId
        WHERE lo.IsB2B = 1 AND lo.IsActive = 1;

        IF @TotalAmount <= 0
        BEGIN
            THROW 50003, 'No valid orders found or total amount is zero.', 1;
        END

        -- Calculate any existing payments recorded on selected orders (capped at B2B rate)
        DECLARE @InitialPaidAmount DECIMAL(18,2) = 0.00;
        SELECT @InitialPaidAmount = ISNULL(SUM(
            CASE 
                WHEN ISNULL(ph.TotalPaid, 0) >= ISNULL(lo.B2BTotal, lo.TotalAmount) THEN ISNULL(lo.B2BTotal, lo.TotalAmount)
                ELSE ISNULL(ph.TotalPaid, 0)
            END
        ), 0.00)
        FROM dbo.LabOrder lo
        INNER JOIN @OrderList ol ON ol.LabOrderId = lo.LabOrderId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        WHERE lo.IsB2B = 1 AND lo.IsActive = 1;

        IF @InitialPaidAmount > @TotalAmount SET @InitialPaidAmount = @TotalAmount;
        DECLARE @InitialBalance DECIMAL(18,2) = CASE WHEN @TotalAmount - @InitialPaidAmount <= 0 THEN 0.00 ELSE @TotalAmount - @InitialPaidAmount END;
        DECLARE @InitialStatus VARCHAR(10) = CASE WHEN @InitialBalance <= 0 THEN 'P' WHEN @InitialPaidAmount > 0 THEN 'R' ELSE 'U' END;

        -- 4. Insert Invoice Header
        INSERT INTO dbo.B2BInvoice
            (InvoiceNo, PartnerType, PartnerId, BranchId, BillingCycle, InvoiceDate, DueDate, TotalAmount, DiscountAmount, TaxAmount, NetAmount, PaidAmount, BalanceAmount, Status, Notes, CreatedBy, CreatedDate)
        VALUES
            (@InvoiceNo, @AgentType, @AgentId, @BranchId, @BillingCycle, GETDATE(), @DueDate, @TotalAmount, 0.00, 0.00, @TotalAmount, @InitialPaidAmount, @InitialBalance, @InitialStatus, @Notes, @UserId, GETDATE());

        SET @InvoiceId = SCOPE_IDENTITY();

        -- 5. Insert Invoice Items
        INSERT INTO dbo.B2BInvoiceItem
            (InvoiceId, LabOrderId, BillNo, OrderDate, PatientName, B2BTotal, Amount)
        SELECT 
            @InvoiceId,
            lo.LabOrderId,
            lo.BillNo,
            lo.OrderDate,
            LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName, ''))),
            ISNULL(lo.B2BTotal, lo.TotalAmount),
            ISNULL(lo.B2BTotal, lo.TotalAmount)
        FROM dbo.LabOrder lo
        INNER JOIN @OrderList ol ON ol.LabOrderId = lo.LabOrderId
        INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
        WHERE lo.IsB2B = 1 AND lo.IsActive = 1;

        -- Update DueDate on LabOrders
        UPDATE lo
        SET DueDate = @DueDate
        FROM dbo.LabOrder lo
        INNER JOIN @OrderList ol ON ol.LabOrderId = lo.LabOrderId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── 4. Fix usp_B2B_GetInvoiceList ─────────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetInvoiceList
    @AgentType    VARCHAR(10) = NULL,
    @AgentId      INT = NULL,
    @Status       VARCHAR(10) = NULL,
    @FromDate     DATETIME2 = NULL,
    @ToDate       DATETIME2 = NULL,
    @Search       NVARCHAR(100) = NULL,
    @PageNumber   INT = 1,
    @PageSize     INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    ;WITH FilteredInvoices AS (
        SELECT 
            inv.InvoiceId,
            inv.InvoiceNo,
            inv.PartnerType,
            inv.PartnerId,
            CASE inv.PartnerType 
                WHEN 'F' THEN f.Franchise_Name 
                WHEN 'C' THEN corp.Corporate_Name 
                ELSE 'Unknown' 
            END AS PartnerName,
            CASE inv.PartnerType 
                WHEN 'F' THEN f.Franchise_Code 
                WHEN 'C' THEN corp.Corporate_Code 
                ELSE '' 
            END AS PartnerCode,
            inv.BranchId,
            inv.BillingCycle,
            inv.InvoiceDate,
            inv.DueDate,
            inv.TotalAmount,
            inv.NetAmount,
            CASE WHEN inv.PaidAmount > inv.NetAmount THEN inv.NetAmount ELSE inv.PaidAmount END AS PaidAmount,
            CASE WHEN inv.BalanceAmount < 0 THEN 0.00 ELSE inv.BalanceAmount END AS BalanceAmount,
            inv.Status,
            CASE inv.Status 
                WHEN 'P' THEN 'Paid' 
                WHEN 'R' THEN 'Partially Paid' 
                WHEN 'U' THEN 'Unpaid' 
                WHEN 'C' THEN 'Cancelled' 
                ELSE 'Unpaid' 
            END AS StatusName,
            (SELECT COUNT(1) FROM dbo.B2BInvoiceItem WHERE InvoiceId = inv.InvoiceId) AS OrderCount
        FROM dbo.B2BInvoice inv
        LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = inv.PartnerId AND inv.PartnerType = 'F'
        LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = inv.PartnerId AND inv.PartnerType = 'C'
        WHERE (@AgentType IS NULL OR inv.PartnerType = @AgentType)
          AND (@AgentId IS NULL OR inv.PartnerId = @AgentId)
          AND (@Status IS NULL OR inv.Status = @Status)
          AND (@FromDate IS NULL OR inv.InvoiceDate >= @FromDate)
          AND (@ToDate IS NULL OR inv.InvoiceDate <= @ToDate)
          AND (@Search IS NULL OR inv.InvoiceNo LIKE '%' + @Search + '%' 
                               OR f.Franchise_Name LIKE '%' + @Search + '%' 
                               OR corp.Corporate_Name LIKE '%' + @Search + '%')
    )
    SELECT *, (SELECT COUNT(1) FROM FilteredInvoices) AS TotalCount
    FROM FilteredInvoices
    ORDER BY InvoiceDate DESC, InvoiceId DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- ── 5. Fix usp_B2B_GetInvoiceDetail ───────────────────────────────────────────
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetInvoiceDetail
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Header
    SELECT 
        inv.InvoiceId,
        inv.InvoiceNo,
        inv.PartnerType,
        inv.PartnerId,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Franchise_Name 
            WHEN 'C' THEN corp.Corporate_Name 
            ELSE 'Unknown' 
        END AS PartnerName,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Franchise_Code 
            WHEN 'C' THEN corp.Corporate_Code 
            ELSE '' 
        END AS PartnerCode,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Mobile_No 
            WHEN 'C' THEN corp.Contact_No 
            ELSE '' 
        END AS PartnerPhone,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Email 
            WHEN 'C' THEN corp.Email 
            ELSE '' 
        END AS PartnerEmail,
        CASE inv.PartnerType 
            WHEN 'F' THEN '' 
            WHEN 'C' THEN corp.Address 
            ELSE '' 
        END AS PartnerAddress,
        inv.BranchId,
        b.BranchName,
        b.BranchCode,
        inv.BillingCycle,
        inv.InvoiceDate,
        inv.DueDate,
        inv.TotalAmount,
        inv.DiscountAmount,
        inv.TaxAmount,
        inv.NetAmount,
        CASE WHEN inv.PaidAmount > inv.NetAmount THEN inv.NetAmount ELSE inv.PaidAmount END AS PaidAmount,
        CASE WHEN inv.BalanceAmount < 0 THEN 0.00 ELSE inv.BalanceAmount END AS BalanceAmount,
        inv.Status,
        inv.Notes,
        inv.CreatedDate,
        u.FullName AS CreatedByName
    FROM dbo.B2BInvoice inv
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = inv.PartnerId AND inv.PartnerType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = inv.PartnerId AND inv.PartnerType = 'C'
    LEFT JOIN dbo.Branchmaster b ON b.BranchId = inv.BranchId
    LEFT JOIN dbo.UserMaster u ON u.Id = inv.CreatedBy
    WHERE inv.InvoiceId = @InvoiceId;

    -- Line items
    SELECT 
        bii.InvoiceItemId,
        bii.InvoiceId,
        bii.LabOrderId,
        bii.BillNo,
        bii.OrderDate,
        bii.PatientName,
        p.PatientCode,
        p.PhoneNumber AS PatientPhone,
        bii.B2BTotal,
        bii.Amount,
        STUFF((
            SELECT ', ' + CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Profile') ELSE ISNULL(sm.Test_Name, 'Test') END
            FROM dbo.LabOrderItem si
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster sm ON sm.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
            WHERE si.LabOrderId = bii.LabOrderId AND si.IsActive = 1
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS TestNames
    FROM dbo.B2BInvoiceItem bii
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bii.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    WHERE bii.InvoiceId = @InvoiceId
    ORDER BY bii.OrderDate ASC;
END;
GO

-- ── 6. Backfill & Correct Existing Data ───────────────────────────────────────
-- Recalculate all B2BInvoices so PaidAmount is capped at NetAmount and BalanceAmount is never negative
UPDATE bi
SET PaidAmount = CASE 
        WHEN ISNULL(c.CappedPaid, 0) >= bi.NetAmount THEN bi.NetAmount 
        ELSE ISNULL(c.CappedPaid, 0) 
    END,
    BalanceAmount = CASE 
        WHEN bi.NetAmount - ISNULL(c.CappedPaid, 0) <= 0 THEN 0.00 
        ELSE bi.NetAmount - ISNULL(c.CappedPaid, 0) 
    END,
    Status = CASE 
        WHEN bi.NetAmount - ISNULL(c.CappedPaid, 0) <= 0 THEN 'P'
        WHEN ISNULL(c.CappedPaid, 0) > 0 THEN 'R'
        ELSE 'U'
    END
FROM dbo.B2BInvoice bi
OUTER APPLY (
    SELECT SUM(
        CASE 
            WHEN ISNULL(ph.TotalPaid, 0) >= bii.Amount THEN bii.Amount 
            ELSE ISNULL(ph.TotalPaid, 0) 
        END
    ) AS CappedPaid
    FROM dbo.B2BInvoiceItem bii
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = bii.LabOrderId AND ph.IsActive = 1
    WHERE bii.InvoiceId = bi.InvoiceId
) c;

-- Fix PaymentHeader BalanceDue for B2B orders to be based on B2BTotal
UPDATE ph
SET ph.BalanceDue = CASE 
        WHEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ph.TotalPaid <= 0 THEN 0.00 
        ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) - ph.TotalPaid 
    END,
    ph.PaymentStatus = CASE 
        WHEN ph.TotalPaid >= ISNULL(lo.B2BTotal, lo.TotalAmount) THEN 'P' 
        WHEN ph.TotalPaid > 0 THEN 'R' 
        ELSE 'U' 
    END
FROM dbo.PaymentHeader ph
INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = ph.ModuleRefId AND ph.ModuleCode = 'LAB'
WHERE lo.IsB2B = 1;
GO
