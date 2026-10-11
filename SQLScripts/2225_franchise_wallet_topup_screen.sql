-- ============================================================================
-- Migration: 2225_franchise_wallet_topup_screen.sql
-- Description: Utility > Franchise Top-Up - the franchise wallet top-up moves from the B2B Lab booking screen to a
--   screen of its own (dashboard + list), under the page / control authorization:
--     UTILITY.FRANCHISETOPUP   VIEW    open the screen, dashboard, top-up list, a franchise's wallet statement
--                              TOPUP   top up a franchise wallet
--                              PRINT   print a top-up receipt
--                              EXPORT  export the top-up list to Excel
--   1. LabFranchiseWalletTransaction: PaymentMethodId, TransactionRef, BranchId (nullable; older rows stay NULL
--      = "not recorded"). No existing column changes.
--   2. usp_B2B_FranchiseWallet_TopUp: refuses a top-up unless the franchise is active and its Credit Facility Type
--      is Prepaid (Wallet); payment mode must be an active PaymentMethodMaster row; reference required when the
--      mode needs one; a reference already used on another top-up is refused; amount 1 .. 99,99,999.99; when the
--      screen sends the balance it showed, a wallet that changed meanwhile is refused (double-click guard). Saves the
--      payment mode, reference and branch. Wallet balance, receipt number and ledger posting work as before.
--   3. usp_FranchiseTopUp_Dashboard / usp_FranchiseTopUp_Receipt: data of the screen and of the receipt.
--   4. The page in the Utility menu with its controls and endpoints; the B2B booking screen's
--      LabOrderBooking/FranchiseWalletTopUp endpoint is switched off (the action is removed).
--   No role or user grant is seeded: who may open / top up is set in Settings > Security > Role Permissions.
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Columns ──────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.LabFranchiseWalletTransaction', 'PaymentMethodId') IS NULL
    ALTER TABLE dbo.LabFranchiseWalletTransaction ADD PaymentMethodId INT NULL;
IF COL_LENGTH('dbo.LabFranchiseWalletTransaction', 'TransactionRef') IS NULL
    ALTER TABLE dbo.LabFranchiseWalletTransaction ADD TransactionRef NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LabFranchiseWalletTransaction', 'BranchId') IS NULL
    ALTER TABLE dbo.LabFranchiseWalletTransaction ADD BranchId INT NULL;
GO

-- ── 2. Top-up ───────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_B2B_FranchiseWallet_TopUp
    @FranchiseId      INT,
    @Amount           DECIMAL(18,2),
    @PaymentMethodId  INT,
    @TransactionRef   NVARCHAR(100) = NULL,
    @BranchId         INT = 1,
    @UserId           INT = 1,
    @Narration        NVARCHAR(500) = NULL,
    @ReceiptNo        NVARCHAR(50) OUTPUT,
    @NewBalance       DECIMAL(18,2) OUTPUT,
    @ExpectedBalance  DECIMAL(18,2) = NULL     -- double-payment guard: the balance the screen showed (NULL = not checked)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @TransactionRef = NULLIF(LTRIM(RTRIM(@TransactionRef)), N'');
    SET @Narration      = NULLIF(LTRIM(RTRIM(@Narration)), N'');

    IF @Amount IS NULL OR @Amount <= 0
        THROW 50002, 'Top-up amount must be greater than zero.', 1;
    IF @Amount > 9999999.99
        THROW 50002, 'Top-up amount cannot be more than Rs 99,99,999.99 in one receipt.', 1;
    IF @Amount <> ROUND(@Amount, 2)
        THROW 50002, 'Top-up amount can have at most two decimals.', 1;

    -- franchise: active, not deleted, Credit Facility Type = Prepaid (Wallet) (a franchise without a credit row is
    -- Prepaid, as at B2B billing - usp_B2B_GetPartnerCreditStatus)
    DECLARE @Name NVARCHAR(200), @Active BIT, @Deleted BIT, @Facility INT, @Msg NVARCHAR(400);
    SELECT @Name = f.Franchise_Name, @Active = f.IsActive, @Deleted = f.IsDeleted, @Facility = ISNULL(c.Credit_Facility_Type, 1)
    FROM dbo.LabFranchiseMaster f
    LEFT JOIN dbo.LabFranchiseCreditLimitMaster c ON c.Franchise_ID = f.Franchise_ID
    WHERE f.Franchise_ID = @FranchiseId;

    IF @Name IS NULL OR ISNULL(@Deleted, 0) = 1
        THROW 50003, 'Franchise not found.', 1;
    IF ISNULL(@Active, 0) = 0
    BEGIN
        SET @Msg = @Name + N' is inactive. Activate it in Franchise Master before a top-up.';
        THROW 50003, @Msg, 1;
    END
    IF @Facility <> 1
    BEGIN
        SET @Msg = N'Top-up is allowed only for a franchise whose Credit Facility Type is Prepaid (Wallet). ' + @Name + N' is '
                 + CASE @Facility WHEN 2 THEN N'Postpaid (Credit)' WHEN 3 THEN N'Hybrid' ELSE N'not Prepaid (Wallet)' END + N'.';
        THROW 50004, @Msg, 1;
    END

    -- payment mode
    DECLARE @MethodName NVARCHAR(100), @NeedsRef BIT;
    SELECT @MethodName = MethodName,
           @NeedsRef = CASE WHEN ISNULL(RequiresRef, 0) = 1 OR ISNULL(RequiresChequeNo, 0) = 1 OR ISNULL(RequiresUPIRef, 0) = 1 THEN 1 ELSE 0 END
    FROM dbo.PaymentMethodMaster WHERE PaymentMethodId = @PaymentMethodId AND IsActive = 1;
    IF @MethodName IS NULL
        THROW 50005, 'Select a valid payment mode.', 1;
    IF @NeedsRef = 1 AND @TransactionRef IS NULL
    BEGIN
        SET @Msg = N'Enter the reference / UTR / cheque number for a ' + @MethodName + N' top-up.';
        THROW 50006, @Msg, 1;
    END

    -- the same bank / UPI / cheque reference cannot be recorded twice
    IF @TransactionRef IS NOT NULL
    BEGIN
        DECLARE @UsedOn NVARCHAR(50);
        SELECT TOP 1 @UsedOn = ReceiptNo FROM dbo.LabFranchiseWalletTransaction
        WHERE ReferenceType = 'TOPUP' AND TransactionRef = @TransactionRef ORDER BY TransactionId DESC;
        IF @UsedOn IS NOT NULL
        BEGIN
            SET @Msg = N'Reference ' + @TransactionRef + N' is already recorded on top-up receipt ' + @UsedOn + N'.';
            THROW 50007, @Msg, 1;
        END
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Ensure wallet exists
        IF NOT EXISTS (SELECT 1 FROM dbo.LabFranchiseWallet WITH (UPDLOCK, HOLDLOCK) WHERE Franchise_ID = @FranchiseId)
        BEGIN
            INSERT INTO dbo.LabFranchiseWallet (Franchise_ID, CurrentBalance, LastUpdatedDate)
            VALUES (@FranchiseId, 0.00, GETDATE());
        END

        -- Double-payment guard: the wallet (row locked) must still hold what the screen showed; otherwise another
        -- top-up or a bill deduction was saved meanwhile (second click, retried request, another counter)
        IF @ExpectedBalance IS NOT NULL
        BEGIN
            DECLARE @NowBalance DECIMAL(18,2) = (SELECT CurrentBalance FROM dbo.LabFranchiseWallet WITH (UPDLOCK, HOLDLOCK) WHERE Franchise_ID = @FranchiseId);
            IF ABS(ISNULL(@NowBalance, 0) - @ExpectedBalance) >= 0.01
            BEGIN
                SET @Msg = N'The wallet balance of ' + @Name + N' changed while the screen was open (now Rs ' + CONVERT(NVARCHAR(30), ISNULL(@NowBalance, 0))
                         + N', the screen showed Rs ' + CONVERT(NVARCHAR(30), @ExpectedBalance) + N'). Nothing was saved. Reload the screen and check before topping up again.';
                THROW 50008, @Msg, 1;
            END
        END

        -- Update balance
        UPDATE dbo.LabFranchiseWallet
        SET CurrentBalance = CurrentBalance + @Amount,
            LastUpdatedDate = GETDATE()
        WHERE Franchise_ID = @FranchiseId;

        SELECT @NewBalance = CurrentBalance FROM dbo.LabFranchiseWallet WHERE Franchise_ID = @FranchiseId;

        -- Receipt number: <Branch Code><FY><8-digit serial>, e.g. HO262700000001 (shared generator, script 2193)
        EXEC dbo.usp_Receipt_GetNextNo @BranchId = @BranchId, @ReceiptNo = @ReceiptNo OUTPUT;

        -- Record transaction (with the payment mode, reference and branch - 2225)
        INSERT INTO dbo.LabFranchiseWalletTransaction
            (Franchise_ID, TransactionType, Amount, BalanceAfter, ReferenceType, ReferenceId, ReceiptNo, Narration, CreatedBy, CreatedDate,
             PaymentMethodId, TransactionRef, BranchId)
        VALUES
            (@FranchiseId, 'CREDIT', @Amount, @NewBalance, 'TOPUP', NULL, @ReceiptNo, ISNULL(@Narration, 'Wallet balance recharged/top-up'), @UserId, GETDATE(),
             @PaymentMethodId, @TransactionRef, @BranchId);

        -- Ledger: Dr Bank Account (or Cash), Cr Franchise Wallet (Advance Deposit) - unchanged
        DECLARE @VoucherTypeId INT = (SELECT TOP 1 VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
        DECLARE @DebitLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Bank Account');
        IF @DebitLedgerId IS NULL SET @DebitLedgerId = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Cash Account');
        DECLARE @CreditLedgerId INT = (SELECT TOP 1 LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Franchise Wallet (Advance)');
        DECLARE @NewTxId BIGINT;
        DECLARE @TxDate DATETIME = GETDATE();

        DECLARE @TopUpNarration NVARCHAR(500) = 'Franchise Wallet Top-Up #' + CAST(@FranchiseId AS NVARCHAR(20)) + ' (Receipt: ' + @ReceiptNo + ')';

        IF @DebitLedgerId IS NOT NULL AND @CreditLedgerId IS NOT NULL AND @VoucherTypeId IS NOT NULL
        BEGIN
            EXEC dbo.usp_Ledger_PostEntry
                @VoucherTypeId   = @VoucherTypeId,
                @TransactionDate = @TxDate,
                @ReferenceType   = 'B2B_WALLET_TOPUP',
                @ReferenceId     = @FranchiseId,
                @BranchId        = @BranchId,
                @CompanyId       = 1,
                @TotalAmount     = @Amount,
                @Narration       = @TopUpNarration,
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

-- ── 3a. Screen data ─────────────────────────────────────────────────────────
-- RS1 KPIs · RS2 franchise wallets · RS3 top-ups of the period · RS4 top-ups by payment mode · RS5 day-wise trend
CREATE OR ALTER PROCEDURE dbo.usp_FranchiseTopUp_Dashboard
    @FromDate        DATE,
    @ToDate          DATE,
    @FranchiseId     INT = NULL,
    @PaymentMethodId INT = NULL,     -- 0 = mode not recorded
    @Search          NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_WARNINGS ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @FromDt DATETIME2 = @FromDate, @ToDt DATETIME2 = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME2));
    DECLARE @Last30 DATETIME2 = DATEADD(DAY, -30, SYSDATETIME());

    -- every franchise with its wallet and use
    SELECT f.Franchise_ID, f.Franchise_Code, f.Franchise_Name, f.Mobile_No,
           CAST(ISNULL(f.IsActive, 0) AS BIT) AS IsActive, CAST(ISNULL(f.Status, 0) AS BIT) AS IsSuspended,
           ISNULL(c.Credit_Facility_Type, 1) AS CreditFacilityType,
           CAST(ISNULL(w.CurrentBalance, 0) AS DECIMAL(18,2)) AS WalletBalance,
           lt.LastTopUpOn, lt.LastTopUpAmount, lt.LastReceiptNo,
           CAST(ISNULL(p.TopUpAmount, 0) AS DECIMAL(18,2)) AS PeriodTopUp, ISNULL(p.TopUpCount, 0) AS PeriodTopUpCount,
           CAST(ISNULL(p.UsedAmount, 0) AS DECIMAL(18,2)) AS PeriodUsage,
           CAST(ISNULL(u.Used30, 0) AS DECIMAL(18,2)) AS UsedLast30Days
    INTO #f
    FROM dbo.LabFranchiseMaster f
    LEFT JOIN dbo.LabFranchiseCreditLimitMaster c ON c.Franchise_ID = f.Franchise_ID
    LEFT JOIN dbo.LabFranchiseWallet w ON w.Franchise_ID = f.Franchise_ID
    OUTER APPLY (SELECT TOP 1 t.CreatedDate AS LastTopUpOn, t.Amount AS LastTopUpAmount, t.ReceiptNo AS LastReceiptNo
                 FROM dbo.LabFranchiseWalletTransaction t
                 WHERE t.Franchise_ID = f.Franchise_ID AND t.ReferenceType = 'TOPUP' ORDER BY t.TransactionId DESC) lt
    OUTER APPLY (SELECT SUM(CASE WHEN t.ReferenceType = 'TOPUP' THEN t.Amount ELSE 0 END) AS TopUpAmount,
                        SUM(CASE WHEN t.ReferenceType = 'TOPUP' THEN 1 ELSE 0 END) AS TopUpCount,
                        SUM(CASE WHEN t.TransactionType = 'DEBIT' THEN t.Amount ELSE 0 END) AS UsedAmount
                 FROM dbo.LabFranchiseWalletTransaction t
                 WHERE t.Franchise_ID = f.Franchise_ID AND t.CreatedDate >= @FromDt AND t.CreatedDate < @ToDt) p
    OUTER APPLY (SELECT SUM(t.Amount) AS Used30 FROM dbo.LabFranchiseWalletTransaction t
                 WHERE t.Franchise_ID = f.Franchise_ID AND t.TransactionType = 'DEBIT' AND t.CreatedDate >= @Last30) u
    WHERE ISNULL(f.IsDeleted, 0) = 0;

    -- top-ups of the period (filtered)
    SELECT t.TransactionId, t.ReceiptNo, t.CreatedDate, t.Franchise_ID, f.Franchise_Code, f.Franchise_Name,
           t.Amount, t.BalanceAfter, t.PaymentMethodId, pm.MethodName, t.TransactionRef,
           NULLIF(NULLIF(LTRIM(RTRIM(t.Narration)), N''), N'Wallet balance recharged/top-up') AS Narration,
           t.BranchId, b.BranchName, t.CreatedBy,
           COALESCE(NULLIF(LTRIM(RTRIM(us.FullName)), N''), NULLIF(LTRIM(RTRIM(CONCAT(us.FirstName, N' ', us.LastName))), N''), us.Username) AS CreatedByName
    INTO #t
    FROM dbo.LabFranchiseWalletTransaction t
    INNER JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = t.Franchise_ID
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = t.PaymentMethodId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = t.BranchId
    LEFT JOIN dbo.Users us ON us.Id = t.CreatedBy
    WHERE t.ReferenceType = 'TOPUP' AND t.CreatedDate >= @FromDt AND t.CreatedDate < @ToDt
      AND (@FranchiseId IS NULL OR t.Franchise_ID = @FranchiseId)
      AND (@PaymentMethodId IS NULL OR ISNULL(t.PaymentMethodId, 0) = @PaymentMethodId)
      AND (@Search IS NULL OR t.ReceiptNo LIKE N'%' + @Search + N'%' OR t.TransactionRef LIKE N'%' + @Search + N'%'
           OR f.Franchise_Name LIKE N'%' + @Search + N'%' OR f.Franchise_Code LIKE N'%' + @Search + N'%' OR t.Narration LIKE N'%' + @Search + N'%');

    -- RS1
    SELECT COUNT(*) AS TopUpCount,
           CAST(ISNULL(SUM(Amount), 0) AS DECIMAL(18,2)) AS TopUpAmount,
           CAST(ISNULL(MAX(Amount), 0) AS DECIMAL(18,2)) AS HighestTopUp,
           COUNT(DISTINCT Franchise_ID) AS FranchisesToppedUp,
           (SELECT COUNT(*) FROM #f WHERE CreditFacilityType = 1 AND IsActive = 1) AS PrepaidFranchiseCount,
           (SELECT CAST(ISNULL(SUM(WalletBalance), 0) AS DECIMAL(18,2)) FROM #f WHERE CreditFacilityType = 1) AS TotalWalletBalance,
           (SELECT COUNT(*) FROM #f WHERE CreditFacilityType = 1 AND IsActive = 1
              AND (WalletBalance <= 0 OR (UsedLast30Days > 0 AND WalletBalance < UsedLast30Days / 30.0 * 7))) AS LowBalanceCount,
           (SELECT CAST(ISNULL(SUM(PeriodUsage), 0) AS DECIMAL(18,2)) FROM #f) AS PeriodUsage
    FROM #t;

    -- RS2
    SELECT *, CASE WHEN UsedLast30Days > 0 THEN CAST(WalletBalance / (UsedLast30Days / 30.0) AS DECIMAL(10,1)) END AS DaysOfCover
    FROM #f
    WHERE (@FranchiseId IS NULL OR Franchise_ID = @FranchiseId)
    ORDER BY CASE WHEN CreditFacilityType = 1 AND IsActive = 1 THEN 0 ELSE 1 END, Franchise_Name;

    -- RS3
    SELECT * FROM #t ORDER BY CreatedDate DESC, TransactionId DESC;

    -- RS4
    SELECT ISNULL(PaymentMethodId, 0) AS PaymentMethodId, ISNULL(MethodName, N'Not recorded') AS MethodName,
           COUNT(*) AS TopUpCount, CAST(SUM(Amount) AS DECIMAL(18,2)) AS Amount
    FROM #t GROUP BY ISNULL(PaymentMethodId, 0), ISNULL(MethodName, N'Not recorded') ORDER BY Amount DESC;

    -- RS5 (all franchises of the filter, top-ups vs wallet use per day)
    SELECT CAST(t.CreatedDate AS DATE) AS [Day],
           CAST(SUM(CASE WHEN t.ReferenceType = 'TOPUP' THEN t.Amount ELSE 0 END) AS DECIMAL(18,2)) AS TopUp,
           CAST(SUM(CASE WHEN t.TransactionType = 'DEBIT' THEN t.Amount ELSE 0 END) AS DECIMAL(18,2)) AS Used
    FROM dbo.LabFranchiseWalletTransaction t
    WHERE t.CreatedDate >= @FromDt AND t.CreatedDate < @ToDt AND (@FranchiseId IS NULL OR t.Franchise_ID = @FranchiseId)
    GROUP BY CAST(t.CreatedDate AS DATE) ORDER BY [Day];

    DROP TABLE #f; DROP TABLE #t;
END;
GO

-- ── 3b. Receipt ─────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_FranchiseTopUp_Receipt
    @ReceiptNo NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 t.TransactionId, t.ReceiptNo, t.CreatedDate, t.Amount, t.BalanceAfter,
           CAST(t.BalanceAfter - t.Amount AS DECIMAL(18,2)) AS BalanceBefore,
           t.PaymentMethodId, pm.MethodName, t.TransactionRef,
           NULLIF(NULLIF(LTRIM(RTRIM(t.Narration)), N''), N'Wallet balance recharged/top-up') AS Narration,
           t.BranchId, b.BranchName,
           f.Franchise_ID, f.Franchise_Code, f.Franchise_Name, f.Mobile_No, f.Email,
           COALESCE(NULLIF(LTRIM(RTRIM(us.FullName)), N''), NULLIF(LTRIM(RTRIM(CONCAT(us.FirstName, N' ', us.LastName))), N''), us.Username) AS CreatedByName
    FROM dbo.LabFranchiseWalletTransaction t
    INNER JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = t.Franchise_ID
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = t.PaymentMethodId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = t.BranchId
    LEFT JOIN dbo.Users us ON us.Id = t.CreatedBy
    WHERE t.ReceiptNo = @ReceiptNo AND t.ReferenceType = 'TOPUP'
    ORDER BY t.TransactionId DESC;
END;
GO

-- ── 4. Page, controls, endpoints ────────────────────────────────────────────
DECLARE @co INT, @menu INT, @page INT, @view INT, @topup INT, @print INT, @export INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'UTILITY' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'UTILITY.FRANCHISETOPUP',
             @Title = N'Franchise Top-Up', @Controller = N'FranchiseTopUp', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 50,
             @Icon = N'bi bi-wallet2 me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;

        SET @view = NULL;
        SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'TOPUP',  @Title = N'Top up franchise wallet', @Sort_Order = 20, @Control_ID = @topup OUTPUT;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'PRINT',  @Title = N'Print top-up receipt',    @Sort_Order = 30, @Control_ID = @print OUTPUT;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EXPORT', @Title = N'Export to Excel',         @Sort_Order = 40, @Control_ID = @export OUTPUT;

        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view,   @App = 'WEB', @Http_Method = 'GET',  @Controller = N'FranchiseTopUp', @Action = N'Index',     @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view,   @App = 'WEB', @Http_Method = 'GET',  @Controller = N'FranchiseTopUp', @Action = N'Dashboard', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view,   @App = 'WEB', @Http_Method = 'GET',  @Controller = N'FranchiseTopUp', @Action = N'Statement', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @topup,  @App = 'WEB', @Http_Method = 'POST', @Controller = N'FranchiseTopUp', @Action = N'TopUp',     @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @print,  @App = 'WEB', @Http_Method = 'GET',  @Controller = N'FranchiseTopUp', @Action = N'Receipt',   @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @export, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'FranchiseTopUp', @Action = N'Export',    @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

-- the B2B Lab booking screen no longer tops up a wallet
UPDATE dbo.PageEndpointMap SET IsActive = 0
WHERE App = 'WEB' AND Controller = N'LabOrderBooking' AND Action = N'FranchiseWalletTopUp';

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2225 applied: Utility > Franchise Top-Up (page, controls, endpoints, procedures, wallet transaction columns).';
GO
