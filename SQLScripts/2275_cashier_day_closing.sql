-- ============================================================================================================
-- Migration: 2275_cashier_day_closing.sql
-- Cashier Day Closing, one screen per module: OPD > OPD Day Closing (+ OPD Day Closing Verification) and
-- LAB > LAB Day Closing (+ LAB Day Closing Verification). A user closes the cash of a module once per day at a branch:
-- the module's money receipts and refunds paid, plus the petty cash floats the user gave out of / took back into the till.
--   Petty cash is common to the two modules: a float movement goes into the first closing (OPD or LAB) that takes it and
--   never appears in the other one (CashClosingPetty links each float to one closing).
--   Flow: the cashier sees the expected cash (opening float + cash receipts - cash refunds - given to petty cash
--   + returned from petty cash), counts the till by denomination, hands the cash over (to a person or a bank deposit)
--   and keeps a float for the next day; a verifier verifies it or sends it back. Who may verify comes from the permissions:
--   the Super Admin, or a user with the Manager or Finance role (no other role verifies) AND the VERIFY control of OPD.DAYCLOSINGVERIFY /
--   LAB.DAYCLOSINGVERIFY granted to their role or to them (Settings > Security > Role / User Permissions, per branch). A user verifies their own closing only
--   when Hospital Settings > DayClosingAllowSelfVerify is Yes for the branch (default No: a second person checks the cash).
--   On verification a difference is posted: a shortage is recoverable from the cashier (Dr Staff Cash Shortage
--   Recoverable, Cr Cash Account), an excess is income (Dr Cash Account, Cr Cash Excess at Counter).
--   One closing per user, module, branch and day; cash taken after the closing goes into a second closing of the same
--   day (a closing covers the module's transactions entered up to the moment it was submitted).
--   UPI / card / cheque / NEFT receipts are listed for information (they settle through the bank, not the till).
--   Hospital Settings (per branch): DayClosingBlockBilling - No (default): the cashier is warned at the next login;
--   Yes: OPD / LAB payments are refused until the earlier days of that module are closed. DayClosingStartDate: days
--   before it are never pending (set to the day this script runs, so past history is not flagged).
--   Pages (no role or user grant is seeded - set them in Settings > Security > Role Permissions):
--     OPD.DAYCLOSING / LAB.DAYCLOSING              VIEW, CREATE (submit a closing), PRINT (hand-over slip)
--     OPD.DAYCLOSINGVERIFY / LAB.DAYCLOSINGVERIFY  VIEW, VERIFY (verify / send back)
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Hospital Settings parameters ───────────────────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.HospitalSettings', 'DayClosingBlockBilling') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD DayClosingBlockBilling BIT NOT NULL CONSTRAINT DF_HospitalSettings_DayClosingBlockBilling DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'DayClosingAllowSelfVerify') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD DayClosingAllowSelfVerify BIT NOT NULL CONSTRAINT DF_HospitalSettings_DayClosingAllowSelfVerify DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'DayClosingStartDate') IS NULL
BEGIN
    ALTER TABLE dbo.HospitalSettings ADD DayClosingStartDate DATE NULL;
    EXEC (N'UPDATE dbo.HospitalSettings SET DayClosingStartDate = CAST(GETDATE() AS DATE) WHERE DayClosingStartDate IS NULL;');
END
GO

-- ── 2. Tables ─────────────────────────────────────────────────────────────────────────────────────────────────
-- the first draft of this script had no Module column: rebuilt while it holds no closing
IF OBJECT_ID('dbo.CashClosing', 'U') IS NOT NULL AND COL_LENGTH('dbo.CashClosing', 'Module') IS NULL
BEGIN
    IF EXISTS (SELECT 1 FROM dbo.CashClosing) THROW 54000, 'CashClosing already holds closings without a module; not changed.', 1;
    IF OBJECT_ID('dbo.CashClosingLine', 'U') IS NOT NULL DROP TABLE dbo.CashClosingLine;
    DROP TABLE dbo.CashClosing;
END
GO
IF OBJECT_ID('dbo.CashClosing', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CashClosing
    (
        CashClosingId    INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_CashClosing PRIMARY KEY,
        CompanyId        INT            NULL,
        BranchId         INT            NOT NULL,
        UserId           INT            NOT NULL,                 -- the cashier
        Module           VARCHAR(10)    NOT NULL,                 -- OPD / LAB
        BusinessDate     DATE           NOT NULL,
        SeqNo            TINYINT        NOT NULL,                 -- 1, then 2... for cash taken after a closing
        ClosingNo        NVARCHAR(40)   NOT NULL,
        WindowFrom       DATETIME       NULL,                     -- covers transactions entered after this (the earlier closing of the day)
        CutoffAt         DATETIME       NOT NULL,                 -- ... and up to this moment
        OpeningFloat     DECIMAL(18, 2) NOT NULL CONSTRAINT DF_CashClosing_Opening DEFAULT (0),
        CashReceipts     DECIMAL(18, 2) NOT NULL CONSTRAINT DF_CashClosing_Receipts DEFAULT (0),
        CashRefunds      DECIMAL(18, 2) NOT NULL CONSTRAINT DF_CashClosing_Refunds DEFAULT (0),
        PettyOut         DECIMAL(18, 2) NOT NULL CONSTRAINT DF_CashClosing_PettyOut DEFAULT (0),
        PettyIn          DECIMAL(18, 2) NOT NULL CONSTRAINT DF_CashClosing_PettyIn DEFAULT (0),
        ExpectedCash     DECIMAL(18, 2) NOT NULL,
        NonCashTotal     DECIMAL(18, 2) NOT NULL CONSTRAINT DF_CashClosing_NonCash DEFAULT (0),
        CountedCash      DECIMAL(18, 2) NOT NULL,
        Difference       DECIMAL(18, 2) NOT NULL,                 -- counted - expected: minus = short, plus = excess
        DenominationJson NVARCHAR(1000) NULL,
        HandoverMode     VARCHAR(10)    NOT NULL CONSTRAINT DF_CashClosing_HandoverMode DEFAULT ('PERSON'),   -- PERSON / BANK
        HandedToUserId   INT            NULL,
        HandedAmount     DECIMAL(18, 2) NOT NULL CONSTRAINT DF_CashClosing_Handed DEFAULT (0),
        RetainedFloat    DECIMAL(18, 2) NOT NULL CONSTRAINT DF_CashClosing_Retained DEFAULT (0),
        BankReference    NVARCHAR(100)  NULL,
        Remarks          NVARCHAR(500)  NULL,
        Status           CHAR(1)        NOT NULL CONSTRAINT DF_CashClosing_Status DEFAULT ('S'),   -- S submitted, B sent back, V verified
        SubmittedOn      DATETIME       NOT NULL CONSTRAINT DF_CashClosing_Submitted DEFAULT (GETDATE()),
        VerifiedBy       INT            NULL,
        VerifiedOn       DATETIME       NULL,
        VerifyRemarks    NVARCHAR(500)  NULL,
        TransactionId    BIGINT         NULL,                     -- the shortage / excess journal
        CreatedBy        INT            NULL,
        CreatedDate      DATETIME       NOT NULL CONSTRAINT DF_CashClosing_Created DEFAULT (GETDATE()),
        ModifiedDate     DATETIME       NULL,
        CONSTRAINT CK_CashClosing_Status CHECK (Status IN ('S', 'B', 'V')),
        CONSTRAINT CK_CashClosing_Handover CHECK (HandoverMode IN ('PERSON', 'BANK')),
        CONSTRAINT CK_CashClosing_Module CHECK (Module IN ('OPD', 'LAB')),
        CONSTRAINT UX_CashClosing_Day UNIQUE (BranchId, UserId, Module, BusinessDate, SeqNo)
    );
    CREATE INDEX IX_CashClosing_Board ON dbo.CashClosing (BranchId, Module, BusinessDate, Status);
END
GO

IF OBJECT_ID('dbo.CashClosingLine', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CashClosingLine
    (
        CashClosingLineId INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_CashClosingLine PRIMARY KEY,
        CashClosingId     INT            NOT NULL CONSTRAINT FK_CashClosingLine_Closing REFERENCES dbo.CashClosing (CashClosingId),
        Kind              VARCHAR(10)    NOT NULL,                -- RECEIPT / REFUND / PETTYOUT / PETTYIN
        Module            VARCHAR(10)    NOT NULL,                -- OPD / LAB / PETTY / ...
        ModeName          NVARCHAR(100)  NOT NULL,
        IsCash            BIT            NOT NULL,
        Cnt               INT            NOT NULL,
        Amount            DECIMAL(18, 2) NOT NULL
    );
    CREATE INDEX IX_CashClosingLine_Closing ON dbo.CashClosingLine (CashClosingId);
END
GO

-- petty cash is common to OPD and LAB: each float movement belongs to the one closing that took it
IF OBJECT_ID('dbo.CashClosingPetty', 'U') IS NULL
    CREATE TABLE dbo.CashClosingPetty
    (
        CashClosingId INT NOT NULL CONSTRAINT FK_CashClosingPetty_Closing REFERENCES dbo.CashClosing (CashClosingId),
        FloatId       INT NOT NULL CONSTRAINT PK_CashClosingPetty PRIMARY KEY
    );
GO

-- ── 3. Ledgers for the difference ─────────────────────────────────────────────────────────────────────────────
DECLARE @l TABLE (LedgerName NVARCHAR(100), GroupName NVARCHAR(100), LedgerType VARCHAR(10), BalType NVARCHAR(2), Code NVARCHAR(30));
INSERT INTO @l VALUES
    (N'Staff Cash Shortage Recoverable', N'Loans and Advances', 'PARTY',  'Dr', N'CASH_SHORT_RECOV'),
    (N'Cash Excess at Counter',          N'Indirect Income',    'INCOME', 'Cr', N'CASH_EXCESS');
INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem)
SELECT l.LedgerName, g.LedgerGroupId, 0, l.BalType, 1, GETDATE(), l.Code, l.LedgerType, 1
FROM @l l JOIN dbo.Acc_LedgerGroup g ON g.GroupName = l.GroupName
WHERE NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster x WHERE x.LedgerCode = l.Code OR x.LedgerName = l.LedgerName);
GO

-- ── 4. A user's cash-desk transactions at a branch, by business date ──────────────────────────────────────────
-- @Module OPD / LAB (NULL = both): the module's money receipts (not a franchise wallet deduction: no money at the
-- counter) and refunds paid; and always the petty cash floats against a CASH ledger (common to both modules) with the
-- closing that took each one (PettyClosingId, NULL = not closed yet). CreatedAt (when it was entered) decides which
-- closing of the day covers a receipt or a refund.
CREATE OR ALTER FUNCTION dbo.fn_CashClosing_Txns (@UserId INT, @BranchId INT, @Module VARCHAR(10), @FromDate DATE, @ToDate DATE)
RETURNS TABLE
AS RETURN
(
    SELECT ph.BranchId, CAST(COALESCE(pd.PaymentDate, pd.CreatedDate) AS DATE) AS BusinessDate,
           'RECEIPT' AS Kind, CAST(ph.ModuleCode AS VARCHAR(10)) AS Module, pd.PaymentDetailId AS RefId, CAST(pd.ReceiptNo AS NVARCHAR(60)) AS RefNo,
           CAST(COALESCE(pos.OPDBillNo, lo.BillNo) AS NVARCHAR(60)) AS BillNo,
           CAST(LTRIM(RTRIM(ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, ''))) AS NVARCHAR(250)) AS PartyName,
           CAST(ISNULL(pm.MethodName, 'Unknown') AS NVARCHAR(100)) AS ModeName,
           CAST(CASE WHEN pm.MethodCode = 'CASH' THEN 1 ELSE 0 END AS BIT) AS IsCash,
           CAST(pd.PaidAmount AS DECIMAL(18, 2)) AS Amount,
           COALESCE(pd.PaymentDate, pd.CreatedDate) AS TxnAt, pd.CreatedDate AS CreatedAt, CAST(NULL AS INT) AS PettyClosingId
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.IsActive = 1
    LEFT  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    LEFT  JOIN dbo.PatientMaster p ON p.PatientId = ph.PatientId
    LEFT  JOIN dbo.PatientOPDService pos ON ph.ModuleCode = 'OPD' AND pos.OPDServiceId = COALESCE(ph.OPDServiceId, ph.ModuleRefId)
    LEFT  JOIN dbo.LabOrder lo ON ph.ModuleCode = 'LAB' AND lo.LabOrderId = ph.ModuleRefId
    WHERE pd.IsActive = 1 AND pd.CreatedBy = @UserId AND pd.PaidAmount > 0
      AND ph.ModuleCode IN ('OPD', 'LAB') AND (@Module IS NULL OR ph.ModuleCode = @Module)
      AND (@BranchId IS NULL OR ph.BranchId = @BranchId)
      AND ISNULL(pd.TransactionRef, '') NOT LIKE 'WALLET-DEBIT-%'
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @FromDate
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME))

    UNION ALL

    SELECT COALESCE(ph.BranchId, pos.BranchId, lo.BranchId), CAST(r.RefundDate AS DATE),
           'REFUND', CAST(r.ModuleCode AS VARCHAR(10)), r.RefundId, CAST(bc.CancellationNo AS NVARCHAR(60)),
           CAST(COALESCE(pos.OPDBillNo, lo.BillNo) AS NVARCHAR(60)),
           CAST(LTRIM(RTRIM(ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, ''))) AS NVARCHAR(250)),
           CAST(ISNULL(NULLIF(LTRIM(RTRIM(r.RefundMode)), ''), 'Not recorded') AS NVARCHAR(100)),
           CAST(CASE WHEN r.RefundMode LIKE '%cash%' THEN 1 ELSE 0 END AS BIT),
           CAST(r.RefundAmount AS DECIMAL(18, 2)), r.RefundDate, r.CreatedDate, NULL
    FROM dbo.BillRefund r
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = r.ModuleCode AND ph.ModuleRefId = r.ModuleRefId AND ph.IsActive = 1
    LEFT  JOIN dbo.PatientOPDService pos ON r.ModuleCode = 'OPD' AND pos.OPDServiceId = r.ModuleRefId
    LEFT  JOIN dbo.LabOrder lo ON r.ModuleCode = 'LAB' AND lo.LabOrderId = r.ModuleRefId
    LEFT  JOIN dbo.PatientMaster p ON p.PatientId = COALESCE(ph.PatientId, pos.PatientId, lo.PatientId)
    LEFT  JOIN dbo.BillCancellation bc ON bc.CancellationId = r.CancellationId
    WHERE r.IsActive = 1 AND ISNULL(r.Status, 'P') = 'P' AND r.CreatedBy = @UserId AND ISNULL(r.RefundAmount, 0) > 0
      AND r.ModuleCode IN ('OPD', 'LAB') AND (@Module IS NULL OR r.ModuleCode = @Module)
      AND (@BranchId IS NULL OR COALESCE(ph.BranchId, pos.BranchId, lo.BranchId) = @BranchId)
      AND r.RefundDate >= @FromDate AND r.RefundDate < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME))

    UNION ALL

    SELECT c.BranchId, f.TxnDate,
           CASE WHEN f.Kind = 'RETURN' THEN 'PETTYIN' ELSE 'PETTYOUT' END, 'PETTY', f.FloatId, CAST(f.VoucherNo AS NVARCHAR(60)), NULL,
           CAST(c.CounterName AS NVARCHAR(250)),
           CAST(CASE f.Kind WHEN 'ISSUE' THEN N'Float issued' WHEN 'REPLENISH' THEN N'Float replenished' ELSE N'Float returned' END AS NVARCHAR(100)),
           CAST(1 AS BIT), CAST(f.Amount AS DECIMAL(18, 2)),
           CASE WHEN CAST(f.CreatedDate AS DATE) = f.TxnDate THEN f.CreatedDate ELSE CAST(f.TxnDate AS DATETIME) END, f.CreatedDate,
           cp.CashClosingId
    FROM dbo.Acc_PettyCashFloat f
    INNER JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = f.CounterId
    INNER JOIN dbo.Acc_LedgerMaster src ON src.LedgerId = f.SourceLedgerId AND src.LedgerType = 'CASH'
    LEFT  JOIN dbo.CashClosingPetty cp ON cp.FloatId = f.FloatId
    WHERE f.CreatedBy = @UserId AND (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND f.TxnDate >= @FromDate AND f.TxnDate <= @ToDate
);
GO

-- ── 5. Days a user still has to close (earlier than today) ────────────────────────────────────────────────────
-- Per module: cash receipts / refunds entered after the last closing of that module and day (or no closing at all),
-- or a closing sent back. Module PETTY: petty cash floats no closing has taken yet (close them in OPD or LAB).
-- Days before the branch's DayClosingStartDate never count; 45 days back at most.
CREATE OR ALTER PROCEDURE dbo.usp_CashClosing_Pending
    @UserId   INT,
    @BranchId INT = NULL,          -- NULL = every branch of the user
    @Module   VARCHAR(10) = NULL   -- OPD / LAB: that module and petty cash; NULL = everything
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @from DATE = DATEADD(DAY, -45, @today), @to DATE = DATEADD(DAY, -1, @today);

    SELECT t.BranchId, t.BusinessDate, t.Module, t.Kind, t.IsCash, t.Amount, t.CreatedAt, t.PettyClosingId
    INTO #T
    FROM dbo.fn_CashClosing_Txns(@UserId, @BranchId, @Module, @from, @to) t
    WHERE t.IsCash = 1;

    SELECT t.BranchId, t.BusinessDate, t.Module, COUNT(1) AS OpenTxns,
           SUM(CASE WHEN t.Kind IN ('RECEIPT', 'PETTYIN') THEN t.Amount ELSE -t.Amount END) AS OpenCash,
           CAST(MAX(CASE WHEN cut.LastCutoff IS NULL THEN 0 ELSE 1 END) AS BIT) AS HasClosing
    INTO #D
    FROM #T t
    OUTER APPLY (SELECT MAX(cc.CutoffAt) AS LastCutoff FROM dbo.CashClosing cc
                 WHERE t.Module <> 'PETTY' AND cc.UserId = @UserId AND cc.BranchId = t.BranchId AND cc.Module = t.Module AND cc.BusinessDate = t.BusinessDate) cut
    WHERE (t.Module = 'PETTY' AND t.PettyClosingId IS NULL)
       OR (t.Module <> 'PETTY' AND t.CreatedAt > ISNULL(cut.LastCutoff, '19000101'))
    GROUP BY t.BranchId, t.BusinessDate, t.Module;

    INSERT INTO #D (BranchId, BusinessDate, Module, OpenTxns, OpenCash, HasClosing)
    SELECT cc.BranchId, cc.BusinessDate, cc.Module, 0, 0, 1 FROM dbo.CashClosing cc
    WHERE cc.UserId = @UserId AND cc.Status = 'B' AND cc.BusinessDate < @today
      AND (@BranchId IS NULL OR cc.BranchId = @BranchId) AND (@Module IS NULL OR cc.Module = @Module)
      AND NOT EXISTS (SELECT 1 FROM #D d WHERE d.BranchId = cc.BranchId AND d.BusinessDate = cc.BusinessDate AND d.Module = cc.Module);

    SELECT d.BranchId, b.BranchName, d.Module, d.BusinessDate,
           CASE WHEN EXISTS (SELECT 1 FROM dbo.CashClosing x WHERE x.UserId = @UserId AND x.BranchId = d.BranchId AND x.Module = d.Module
                                                              AND x.BusinessDate = d.BusinessDate AND x.Status = 'B') THEN 'SENT_BACK'
                WHEN d.Module = 'PETTY' THEN 'PETTY_OPEN'
                WHEN d.HasClosing = 0 THEN 'NOT_CLOSED' ELSE 'LATE_CASH' END AS Reason,
           d.OpenTxns, d.OpenCash
    FROM #D d
    INNER JOIN dbo.Branchmaster b ON b.BranchID = d.BranchId
    OUTER APPLY (SELECT TOP 1 COALESCE(hs.DayClosingStartDate, CAST(hs.CreatedDate AS DATE)) AS StartDate
                 FROM dbo.HospitalSettings hs WHERE hs.BranchId = d.BranchId ORDER BY hs.IsActive DESC, hs.Id DESC) st
    WHERE d.BusinessDate >= ISNULL(st.StartDate, @today)
    ORDER BY d.BusinessDate, b.BranchName, d.Module;

    DROP TABLE #T; DROP TABLE #D;
END;
GO

-- ── 6. The window of a closing and what it covers ────────────────────────────────────────────────────────────
-- Fills #W (created by the caller) with the transactions of the closing: for @CashClosingId its own window and its
-- own petty floats; otherwise the next closing of the day - the module's receipts / refunds entered after the last
-- closing of the module and day, and every petty float of the day no closing has taken yet - up to @Upto.
CREATE OR ALTER PROCEDURE dbo.usp_CashClosing_Window
    @BranchId      INT,
    @UserId        INT,
    @Module        VARCHAR(10),
    @BusinessDate  DATE,
    @CashClosingId INT = NULL,
    @After         DATETIME = NULL,
    @Upto          DATETIME,
    @IncludePetty  BIT = 1             -- 0: the petty floats are left for the other module's closing
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO #W (Kind, Module, RefId, RefNo, BillNo, PartyName, ModeName, IsCash, Amount, TxnAt, CreatedAt)
    SELECT t.Kind, t.Module, t.RefId, t.RefNo, t.BillNo, t.PartyName, t.ModeName, t.IsCash, t.Amount, t.TxnAt, t.CreatedAt
    FROM dbo.fn_CashClosing_Txns(@UserId, @BranchId, @Module, @BusinessDate, @BusinessDate) t
    WHERE (t.Module <> 'PETTY' AND t.CreatedAt > ISNULL(@After, '19000101') AND t.CreatedAt <= @Upto)
       OR (t.Module = 'PETTY' AND ((@CashClosingId IS NULL AND ISNULL(@IncludePetty, 1) = 1 AND t.PettyClosingId IS NULL AND t.CreatedAt <= @Upto)
                                   OR (@CashClosingId IS NOT NULL AND t.PettyClosingId = @CashClosingId)));
END;
GO

-- ── 7. What a closing would cover: the figures, the lines, the transactions ─────────────────────────────────
-- @CashClosingId given (or a closing of the day sent back): that closing. Otherwise the next closing of the day.
CREATE OR ALTER PROCEDURE dbo.usp_CashClosing_Summary
    @BranchId      INT,
    @UserId        INT,
    @Module        VARCHAR(10),
    @BusinessDate  DATE,
    @CashClosingId INT = NULL,
    @IncludePetty  BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @Module NOT IN ('OPD', 'LAB') THROW 54030, 'Unknown module.', 1;
    DECLARE @seq TINYINT, @after DATETIME, @upto DATETIME = GETDATE(), @opening DECIMAL(18, 2), @sentBack INT, @status CHAR(1);

    IF @CashClosingId IS NULL
        SELECT TOP 1 @sentBack = CashClosingId FROM dbo.CashClosing
        WHERE BranchId = @BranchId AND UserId = @UserId AND Module = @Module AND BusinessDate = @BusinessDate AND Status = 'B' ORDER BY SeqNo;
    SET @CashClosingId = COALESCE(@CashClosingId, @sentBack);

    IF @CashClosingId IS NOT NULL
        SELECT @seq = SeqNo, @after = WindowFrom, @upto = CutoffAt, @status = Status, @BusinessDate = BusinessDate
        FROM dbo.CashClosing WHERE CashClosingId = @CashClosingId AND BranchId = @BranchId AND UserId = @UserId AND Module = @Module;
    IF @CashClosingId IS NOT NULL AND @seq IS NULL SET @CashClosingId = NULL;
    IF @CashClosingId IS NULL
        SELECT @seq = ISNULL(MAX(SeqNo), 0) + 1, @after = MAX(CutoffAt)
        FROM dbo.CashClosing WHERE BranchId = @BranchId AND UserId = @UserId AND Module = @Module AND BusinessDate = @BusinessDate;

    -- opening float: kept back at the user's previous closing of the module at this branch
    SELECT TOP 1 @opening = RetainedFloat FROM dbo.CashClosing
    WHERE BranchId = @BranchId AND UserId = @UserId AND Module = @Module
      AND (BusinessDate < @BusinessDate OR (BusinessDate = @BusinessDate AND SeqNo < @seq))
    ORDER BY BusinessDate DESC, SeqNo DESC;
    SET @opening = ISNULL(@opening, 0);

    CREATE TABLE #W (Kind VARCHAR(10), Module VARCHAR(10), RefId INT, RefNo NVARCHAR(60), BillNo NVARCHAR(60), PartyName NVARCHAR(250),
                     ModeName NVARCHAR(100), IsCash BIT, Amount DECIMAL(18, 2), TxnAt DATETIME, CreatedAt DATETIME);
    EXEC dbo.usp_CashClosing_Window @BranchId, @UserId, @Module, @BusinessDate, @CashClosingId, @after, @upto, @IncludePetty;

    -- petty floats of the day no closing has taken yet (shown so the cashier can include them or leave them)
    DECLARE @pettyOpen INT = (SELECT COUNT(1) FROM dbo.fn_CashClosing_Txns(@UserId, @BranchId, @Module, @BusinessDate, @BusinessDate) t
                              WHERE t.Module = 'PETTY' AND t.PettyClosingId IS NULL AND t.CreatedAt <= @upto);

    DECLARE @rc DECIMAL(18, 2), @rf DECIMAL(18, 2), @po DECIMAL(18, 2), @pi DECIMAL(18, 2), @nc DECIMAL(18, 2);
    SELECT @rc = ISNULL(SUM(CASE WHEN Kind = 'RECEIPT' AND IsCash = 1 THEN Amount END), 0),
           @rf = ISNULL(SUM(CASE WHEN Kind = 'REFUND' AND IsCash = 1 THEN Amount END), 0),
           @po = ISNULL(SUM(CASE WHEN Kind = 'PETTYOUT' THEN Amount END), 0),
           @pi = ISNULL(SUM(CASE WHEN Kind = 'PETTYIN' THEN Amount END), 0),
           @nc = ISNULL(SUM(CASE WHEN Kind = 'RECEIPT' AND IsCash = 0 THEN Amount END), 0)
    FROM #W;

    -- RS1 header
    SELECT @BranchId AS BranchId, b.BranchName, @UserId AS UserId, @Module AS Module,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UserName,
           @BusinessDate AS BusinessDate, @seq AS SeqNo, @CashClosingId AS CashClosingId, @status AS Status,
           @after AS WindowFrom, @upto AS WindowTo,
           @opening AS OpeningFloat, @rc AS CashReceipts, @rf AS CashRefunds, @po AS PettyOut, @pi AS PettyIn,
           @opening + @rc - @rf - @po + @pi AS ExpectedCash, @nc AS NonCashTotal,
           (SELECT COUNT(1) FROM #W) AS TxnCount, (SELECT COUNT(1) FROM #W WHERE IsCash = 1) AS CashTxnCount,
           @pettyOpen AS PettyOpenCount, CAST(ISNULL(@IncludePetty, 1) AS BIT) AS IncludePetty,
           CAST(ISNULL((SELECT TOP 1 hs.DayClosingBlockBilling FROM dbo.HospitalSettings hs WHERE hs.BranchId = @BranchId ORDER BY hs.IsActive DESC, hs.Id DESC), 0) AS BIT) AS BlockBilling
    FROM dbo.Branchmaster b CROSS JOIN dbo.Users u
    WHERE b.BranchID = @BranchId AND u.Id = @UserId;

    -- RS2 lines: kind x module x mode
    SELECT Kind, Module, ModeName, IsCash, COUNT(1) AS Cnt, SUM(Amount) AS Amount
    FROM #W GROUP BY Kind, Module, ModeName, IsCash
    ORDER BY CASE Kind WHEN 'RECEIPT' THEN 1 WHEN 'REFUND' THEN 2 WHEN 'PETTYOUT' THEN 3 ELSE 4 END, IsCash DESC, Module, ModeName;

    -- RS3 the transactions
    SELECT Kind, Module, RefNo, BillNo, PartyName, ModeName, IsCash, Amount, TxnAt, CreatedAt FROM #W ORDER BY TxnAt, CreatedAt;

    -- RS4 the user's closings of the module and day
    SELECT cc.CashClosingId, cc.ClosingNo, cc.SeqNo, cc.CutoffAt, cc.ExpectedCash, cc.CountedCash, cc.Difference, cc.HandedAmount,
           cc.RetainedFloat, cc.Status, cc.VerifyRemarks, ISNULL(NULLIF(LTRIM(RTRIM(v.FullName)), ''), v.Username) AS VerifiedByName, cc.VerifiedOn
    FROM dbo.CashClosing cc LEFT JOIN dbo.Users v ON v.Id = cc.VerifiedBy
    WHERE cc.BranchId = @BranchId AND cc.UserId = @UserId AND cc.Module = @Module AND cc.BusinessDate = @BusinessDate
    ORDER BY cc.SeqNo;

    DROP TABLE #W;
END;
GO

-- ── 8. Submit (new, or a closing sent back) ───────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_CashClosing_Submit
    @BranchId         INT,
    @UserId           INT,
    @Module           VARCHAR(10),
    @BusinessDate     DATE,
    @CashClosingId    INT = NULL,          -- resubmit a closing sent back
    @CountedCash      DECIMAL(18, 2),
    @DenominationJson NVARCHAR(1000) = NULL,
    @HandoverMode     VARCHAR(10) = 'PERSON',
    @HandedToUserId   INT = NULL,
    @HandedAmount     DECIMAL(18, 2) = 0,
    @RetainedFloat    DECIMAL(18, 2) = 0,
    @BankReference    NVARCHAR(100) = NULL,
    @Remarks          NVARCHAR(500) = NULL,
    @IncludePetty     BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @msg NVARCHAR(400);

    IF @Module NOT IN ('OPD', 'LAB') THROW 54030, 'Unknown module.', 1;
    IF @BusinessDate IS NULL OR @BusinessDate > @today THROW 54001, 'The closing date cannot be in the future.', 1;
    IF ISNULL(@CountedCash, -1) < 0 THROW 54002, 'Enter the cash counted.', 1;
    IF ISNULL(@HandedAmount, -1) < 0 OR ISNULL(@RetainedFloat, -1) < 0 THROW 54003, 'The amounts cannot be negative.', 1;
    IF @HandedAmount + @RetainedFloat <> @CountedCash
    BEGIN
        SET @msg = CONCAT('Handed over (', FORMAT(@HandedAmount, 'N2'), ') + float kept (', FORMAT(@RetainedFloat, 'N2'),
                          ') must equal the cash counted (', FORMAT(@CountedCash, 'N2'), ').');
        THROW 54004, @msg, 1;
    END
    SET @HandoverMode = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@HandoverMode)), ''), 'PERSON'));
    IF @HandoverMode NOT IN ('PERSON', 'BANK') THROW 54005, 'Choose how the cash is handed over.', 1;
    IF @HandedAmount > 0 AND @HandoverMode = 'PERSON'
    BEGIN
        IF @HandedToUserId IS NULL THROW 54006, 'Select the person receiving the cash.', 1;
        IF @HandedToUserId = @UserId THROW 54007, 'The cash cannot be handed over to yourself.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @HandedToUserId AND IsActive = 1) THROW 54008, 'The person receiving the cash is not an active user.', 1;
    END
    IF @HandoverMode = 'BANK' SET @HandedToUserId = NULL;
    IF @HandedAmount > 0 AND @HandoverMode = 'BANK' AND NULLIF(LTRIM(RTRIM(@BankReference)), '') IS NULL
        THROW 54009, 'Enter the bank deposit reference (slip number).', 1;

    -- earlier days of the module first: the opening float of a day is what was kept back the day before
    IF @CashClosingId IS NULL
    BEGIN
        CREATE TABLE #P (BranchId INT, BranchName NVARCHAR(200), Module VARCHAR(10), BusinessDate DATE, Reason VARCHAR(20), OpenTxns INT, OpenCash DECIMAL(18, 2));
        INSERT INTO #P EXEC dbo.usp_CashClosing_Pending @UserId = @UserId, @BranchId = @BranchId, @Module = @Module;
        DECLARE @first DATE = (SELECT MIN(BusinessDate) FROM #P WHERE BusinessDate < @BusinessDate AND Module = @Module);
        IF @first IS NOT NULL
        BEGIN
            SET @msg = CONCAT('Close ', @Module, ' cash of ', FORMAT(@first, 'dd-MMM-yyyy'), ' first: earlier days are closed in order.');
            THROW 54010, @msg, 1;
        END
    END

    DECLARE @co INT = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId);
    DECLARE @seq TINYINT, @after DATETIME, @upto DATETIME = GETDATE(), @opening DECIMAL(18, 2), @id INT = @CashClosingId, @no NVARCHAR(40);
    CREATE TABLE #W (Kind VARCHAR(10), Module VARCHAR(10), RefId INT, RefNo NVARCHAR(60), BillNo NVARCHAR(60), PartyName NVARCHAR(250),
                     ModeName NVARCHAR(100), IsCash BIT, Amount DECIMAL(18, 2), TxnAt DATETIME, CreatedAt DATETIME);

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @id IS NOT NULL
        BEGIN
            SELECT @seq = SeqNo, @after = WindowFrom, @upto = CutoffAt, @BusinessDate = BusinessDate
            FROM dbo.CashClosing WITH (UPDLOCK, HOLDLOCK)
            WHERE CashClosingId = @id AND BranchId = @BranchId AND UserId = @UserId AND Module = @Module AND Status = 'B';
            IF @seq IS NULL THROW 54011, 'This closing cannot be changed: only a closing sent back can be submitted again.', 1;
        END
        ELSE
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.CashClosing WITH (UPDLOCK, HOLDLOCK)
                       WHERE BranchId = @BranchId AND UserId = @UserId AND Module = @Module AND BusinessDate = @BusinessDate AND Status = 'B')
                THROW 54012, 'A closing of this day was sent back: correct and submit that one first.', 1;
            SELECT @seq = ISNULL(MAX(SeqNo), 0) + 1, @after = MAX(CutoffAt)
            FROM dbo.CashClosing WITH (UPDLOCK, HOLDLOCK)
            WHERE BranchId = @BranchId AND UserId = @UserId AND Module = @Module AND BusinessDate = @BusinessDate;
        END

        SELECT TOP 1 @opening = RetainedFloat FROM dbo.CashClosing
        WHERE BranchId = @BranchId AND UserId = @UserId AND Module = @Module
          AND (BusinessDate < @BusinessDate OR (BusinessDate = @BusinessDate AND SeqNo < @seq))
        ORDER BY BusinessDate DESC, SeqNo DESC;
        SET @opening = ISNULL(@opening, 0);

        EXEC dbo.usp_CashClosing_Window @BranchId, @UserId, @Module, @BusinessDate, @id, @after, @upto, @IncludePetty;

        DECLARE @rc DECIMAL(18, 2), @rf DECIMAL(18, 2), @po DECIMAL(18, 2), @pi DECIMAL(18, 2), @nc DECIMAL(18, 2), @n INT;
        SELECT @rc = ISNULL(SUM(CASE WHEN Kind = 'RECEIPT' AND IsCash = 1 THEN Amount END), 0),
               @rf = ISNULL(SUM(CASE WHEN Kind = 'REFUND' AND IsCash = 1 THEN Amount END), 0),
               @po = ISNULL(SUM(CASE WHEN Kind = 'PETTYOUT' THEN Amount END), 0),
               @pi = ISNULL(SUM(CASE WHEN Kind = 'PETTYIN' THEN Amount END), 0),
               @nc = ISNULL(SUM(CASE WHEN Kind = 'RECEIPT' AND IsCash = 0 THEN Amount END), 0),
               @n = COUNT(1)
        FROM #W;
        IF @id IS NULL AND @n = 0
            THROW 54013, 'Nothing to close: no transaction since your last closing of this day.', 1;

        DECLARE @expected DECIMAL(18, 2) = @opening + @rc - @rf - @po + @pi;
        DECLARE @diff DECIMAL(18, 2) = @CountedCash - @expected;
        IF @diff <> 0 AND NULLIF(LTRIM(RTRIM(@Remarks)), '') IS NULL
            THROW 54014, 'The cash counted differs from the expected cash: enter a remark explaining the difference.', 1;

        IF @id IS NULL
        BEGIN
            SET @no = CONCAT('DC/', @Module, '/', ISNULL((SELECT NULLIF(BranchCode, '') FROM dbo.Branchmaster WHERE BranchID = @BranchId), CAST(@BranchId AS NVARCHAR(10))),
                             '/', FORMAT(@BusinessDate, 'yyyyMMdd'), '/', @UserId, '-', @seq);
            INSERT INTO dbo.CashClosing (CompanyId, BranchId, UserId, Module, BusinessDate, SeqNo, ClosingNo, WindowFrom, CutoffAt, OpeningFloat, CashReceipts, CashRefunds,
                                         PettyOut, PettyIn, ExpectedCash, NonCashTotal, CountedCash, Difference, DenominationJson, HandoverMode, HandedToUserId,
                                         HandedAmount, RetainedFloat, BankReference, Remarks, Status, SubmittedOn, CreatedBy)
            VALUES (@co, @BranchId, @UserId, @Module, @BusinessDate, @seq, @no, @after, @upto, @opening, @rc, @rf, @po, @pi, @expected, @nc, @CountedCash, @diff,
                    @DenominationJson, @HandoverMode, @HandedToUserId, @HandedAmount, @RetainedFloat, NULLIF(LTRIM(RTRIM(@BankReference)), ''),
                    NULLIF(LTRIM(RTRIM(@Remarks)), ''), 'S', GETDATE(), @UserId);
            SET @id = SCOPE_IDENTITY();
            -- the petty floats now belong to this closing: they no longer show in the other module
            INSERT INTO dbo.CashClosingPetty (CashClosingId, FloatId)
            SELECT @id, w.RefId FROM #W w WHERE w.Module = 'PETTY' AND NOT EXISTS (SELECT 1 FROM dbo.CashClosingPetty x WHERE x.FloatId = w.RefId);
        END
        ELSE
        BEGIN
            UPDATE dbo.CashClosing
            SET OpeningFloat = @opening, CashReceipts = @rc, CashRefunds = @rf, PettyOut = @po, PettyIn = @pi, ExpectedCash = @expected, NonCashTotal = @nc,
                CountedCash = @CountedCash, Difference = @diff, DenominationJson = @DenominationJson, HandoverMode = @HandoverMode, HandedToUserId = @HandedToUserId,
                HandedAmount = @HandedAmount, RetainedFloat = @RetainedFloat, BankReference = NULLIF(LTRIM(RTRIM(@BankReference)), ''),
                Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''), Status = 'S', SubmittedOn = GETDATE(), ModifiedDate = GETDATE()
            WHERE CashClosingId = @id;
            DELETE FROM dbo.CashClosingLine WHERE CashClosingId = @id;
        END

        INSERT INTO dbo.CashClosingLine (CashClosingId, Kind, Module, ModeName, IsCash, Cnt, Amount)
        SELECT @id, Kind, ISNULL(Module, ''), ModeName, IsCash, COUNT(1), SUM(Amount) FROM #W GROUP BY Kind, Module, ModeName, IsCash;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    DROP TABLE #W;
    SELECT CashClosingId, ClosingNo, ExpectedCash, CountedCash, Difference FROM dbo.CashClosing WHERE CashClosingId = @id;
END;
GO

-- ── 9. Who may verify: the VERIFY control of the module's verification page, as the permissions decide it ──────
-- The Manager or Finance role first, then the permission as usp_Auth_GetEffectivePermissions resolves it (user rows
-- before role rows, control before page before menu, per branch). Used for the verify check and for whom to notify.
CREATE OR ALTER PROCEDURE dbo.usp_CashClosing_CanVerify
    @UserId   INT,
    @BranchId INT,
    @Module   VARCHAR(10),
    @Allowed  BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Allowed = 0;
    IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId AND IsActive = 1) RETURN;
    -- the Super Admin (Users.IsSuperAdmin) always verifies
    IF EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId AND IsSuperAdmin = 1) BEGIN SET @Allowed = 1; RETURN; END
    -- only the Manager and Finance roles verify cash (for this branch, or for every branch); no other role, whatever its permissions
    IF NOT EXISTS (SELECT 1 FROM dbo.Userroles ur INNER JOIN dbo.Roles r ON r.Id = ur.RoleId
                   WHERE ur.UserId = @UserId AND ur.IsActive = 1 AND (ur.Branch_ID IS NULL OR ur.Branch_ID = @BranchId)
                     AND r.Name IN ('Manager', 'Finance')) RETURN;
    CREATE TABLE #EP (Page_Code NVARCHAR(150), Page_ID INT, Control_Code VARCHAR(30), Control_ID INT, Permission CHAR(1), Decided_At_Scope INT, Decided_By VARCHAR(10));
    INSERT INTO #EP EXEC dbo.usp_Auth_GetEffectivePermissions @UserId = @UserId, @BranchId = @BranchId;
    IF EXISTS (SELECT 1 FROM #EP WHERE Page_Code = @Module + '.DAYCLOSINGVERIFY' AND Control_Code = 'VERIFY' AND Permission = 'A')
        SET @Allowed = 1;
    DROP TABLE #EP;
END;
GO

-- The users who may verify the module's closings at the branch (notified when a closing is submitted).
CREATE OR ALTER PROCEDURE dbo.usp_CashClosing_Verifiers
    @BranchId INT,
    @Module   VARCHAR(10) = 'OPD'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @V TABLE (UserId INT);
    DECLARE @uid INT, @ok BIT;
    DECLARE uc CURSOR LOCAL FAST_FORWARD FOR
        SELECT u.Id FROM dbo.Users u
        WHERE u.IsActive = 1
          AND (u.IsSuperAdmin = 1 OR EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ISNULL(ub.IsActive, 1) = 1));
    OPEN uc; FETCH NEXT FROM uc INTO @uid;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_CashClosing_CanVerify @UserId = @uid, @BranchId = @BranchId, @Module = @Module, @Allowed = @ok OUTPUT;
        IF @ok = 1 INSERT INTO @V VALUES (@uid);
        FETCH NEXT FROM uc INTO @uid;
    END
    CLOSE uc; DEALLOCATE uc;

    SELECT u.Id AS UserId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UserName, u.Username AS LoginName
    FROM @V v INNER JOIN dbo.Users u ON u.Id = v.UserId
    ORDER BY UserName;
END;
GO

-- ── 10. Verify / send back ────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_CashClosing_Verify
    @CashClosingId INT,
    @Action        CHAR(1),            -- V verify, B send back
    @Remarks       NVARCHAR(500) = NULL,
    @UserId        INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @br INT, @co INT, @cashier INT, @status CHAR(1), @diff DECIMAL(18, 2), @date DATE, @no NVARCHAR(40), @cashierName NVARCHAR(200), @module VARCHAR(10);
    SELECT @br = cc.BranchId, @co = ISNULL(cc.CompanyId, b.CompanyId), @cashier = cc.UserId, @status = cc.Status, @diff = cc.Difference, @module = cc.Module,
           @date = cc.BusinessDate, @no = cc.ClosingNo, @cashierName = ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)
    FROM dbo.CashClosing cc
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = cc.BranchId
    LEFT JOIN dbo.Users u ON u.Id = cc.UserId
    WHERE cc.CashClosingId = @CashClosingId;

    IF @br IS NULL THROW 54020, 'Day closing not found.', 1;
    IF @Action NOT IN ('V', 'B') THROW 54021, 'Choose verify or send back.', 1;
    IF @status <> 'S' THROW 54022, 'Only a submitted closing can be verified or sent back.', 1;
    IF @cashier = @UserId AND ISNULL((SELECT TOP 1 hs.DayClosingAllowSelfVerify FROM dbo.HospitalSettings hs WHERE hs.BranchId = @br
                                      ORDER BY hs.IsActive DESC, hs.Id DESC), 0) = 0
        THROW 54023, 'You cannot verify your own day closing (Hospital Settings > Allow Verifying Own Day Closing is No).', 1;
    DECLARE @canVerify BIT;
    EXEC dbo.usp_CashClosing_CanVerify @UserId = @UserId, @BranchId = @br, @Module = @module, @Allowed = @canVerify OUTPUT;
    IF ISNULL(@canVerify, 0) = 0
        THROW 54024, 'A day closing is verified by the Super Admin or a Manager / Finance user with the Verify permission of the verification page for this branch.', 1;
    IF @Action = 'B' AND NULLIF(LTRIM(RTRIM(@Remarks)), '') IS NULL THROW 54025, 'Enter why the closing is sent back.', 1;

    DECLARE @tx BIGINT, @vno NVARCHAR(50);
    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE dbo.CashClosing SET Status = @Action, VerifiedBy = @UserId, VerifiedOn = GETDATE(), VerifyRemarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''), ModifiedDate = GETDATE()
        WHERE CashClosingId = @CashClosingId AND Status = 'S';
        IF @@ROWCOUNT = 0 THROW 54022, 'Only a submitted closing can be verified or sent back.', 1;

        IF @Action = 'V' AND @diff <> 0
        BEGIN
            DECLARE @cash INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerType = 'CASH' AND IsActive = 1 ORDER BY IsSystem DESC, LedgerId);
            DECLARE @other INT = (SELECT LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = CASE WHEN @diff < 0 THEN N'CASH_SHORT_RECOV' ELSE N'CASH_EXCESS' END);
            IF @cash IS NULL OR @other IS NULL THROW 54026, 'Ledger Cash Account / Staff Cash Shortage Recoverable / Cash Excess at Counter is missing.', 1;
            DECLARE @abs DECIMAL(18, 2) = ABS(@diff);
            DECLARE @lines NVARCHAR(MAX) = CASE WHEN @diff < 0
                THEN CONCAT('[{"LedgerId":', @other, ',"Dr":', @abs, ',"Cr":0},{"LedgerId":', @cash, ',"Dr":0,"Cr":', @abs, '}]')
                ELSE CONCAT('[{"LedgerId":', @cash, ',"Dr":', @abs, ',"Cr":0},{"LedgerId":', @other, ',"Dr":0,"Cr":', @abs, '}]') END;
            DECLARE @narr NVARCHAR(500) = CONCAT(CASE WHEN @diff < 0 THEN 'Cash shortage recoverable from ' ELSE 'Cash excess at the counter of ' END,
                                                 @cashierName, ' - ', @module, ' day closing ', @no, ' of ', FORMAT(@date, 'dd-MMM-yyyy'));
            DECLARE @when DATETIME = DATEADD(SECOND, -1, DATEADD(DAY, 1, CAST(@date AS DATETIME)));
            EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'JRN', @TransactionDate = @when, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'CASH_CLOSE',
                 @ReferenceId = @CashClosingId, @Narration = @narr, @PayeeName = @cashierName, @LinesJson = @lines, @UserId = @UserId,
                 @TransactionId = @tx OUTPUT, @VoucherNo = @vno OUTPUT;
            UPDATE dbo.CashClosing SET TransactionId = @tx WHERE CashClosingId = @CashClosingId;
        END
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT @CashClosingId AS CashClosingId, @cashier AS CashierId, @no AS ClosingNo, @vno AS VoucherNo;
END;
GO

-- ── 11. Lists ─────────────────────────────────────────────────────────────────────────────────────────────────
-- The verification board of a branch, module and date: every closing, and the users with cash not closed yet.
CREATE OR ALTER PROCEDURE dbo.usp_CashClosing_Board
    @BranchId     INT,
    @Module       VARCHAR(10),
    @BusinessDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    -- RS1 closings
    SELECT cc.CashClosingId, cc.ClosingNo, cc.Module, cc.UserId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UserName, cc.SeqNo, cc.CutoffAt,
           cc.OpeningFloat, cc.CashReceipts, cc.CashRefunds, cc.PettyOut, cc.PettyIn, cc.ExpectedCash, cc.NonCashTotal, cc.CountedCash, cc.Difference,
           cc.HandoverMode, ISNULL(NULLIF(LTRIM(RTRIM(h.FullName)), ''), h.Username) AS HandedToName, cc.HandedAmount, cc.RetainedFloat, cc.BankReference,
           cc.Remarks, cc.Status, cc.SubmittedOn, ISNULL(NULLIF(LTRIM(RTRIM(v.FullName)), ''), v.Username) AS VerifiedByName, cc.VerifiedOn, cc.VerifyRemarks,
           lt.VoucherNo
    FROM dbo.CashClosing cc
    LEFT JOIN dbo.Users u ON u.Id = cc.UserId
    LEFT JOIN dbo.Users h ON h.Id = cc.HandedToUserId
    LEFT JOIN dbo.Users v ON v.Id = cc.VerifiedBy
    LEFT JOIN dbo.Acc_LedgerTransaction lt ON lt.TransactionId = cc.TransactionId
    WHERE cc.BranchId = @BranchId AND cc.Module = @Module AND cc.BusinessDate = @BusinessDate
    ORDER BY UserName, cc.SeqNo;

    -- RS2 cash not closed yet: per user who handled the module's cash at the branch that day (petty floats not taken
    -- by any closing count too)
    SELECT x.UserId INTO #U FROM (
        SELECT pd.CreatedBy AS UserId FROM dbo.PaymentDetail pd INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.IsActive = 1
        WHERE pd.IsActive = 1 AND ph.BranchId = @BranchId AND ph.ModuleCode = @Module AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @BusinessDate
          AND COALESCE(pd.PaymentDate, pd.CreatedDate) < DATEADD(DAY, 1, CAST(@BusinessDate AS DATETIME))
        UNION SELECT r.CreatedBy FROM dbo.BillRefund r WHERE r.IsActive = 1 AND r.ModuleCode = @Module
              AND r.RefundDate >= @BusinessDate AND r.RefundDate < DATEADD(DAY, 1, CAST(@BusinessDate AS DATETIME))
        UNION SELECT f.CreatedBy FROM dbo.Acc_PettyCashFloat f INNER JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = f.CounterId
              WHERE c.BranchId = @BranchId AND f.TxnDate = @BusinessDate) x
    WHERE x.UserId IS NOT NULL;

    SELECT u.Id AS UserId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UserName,
           COUNT(1) AS OpenTxns,
           SUM(CASE WHEN t.Kind IN ('RECEIPT', 'PETTYIN') THEN t.Amount ELSE -t.Amount END) AS OpenCash,
           MAX(cut.LastCutoff) AS LastCutoff
    FROM #U x
    INNER JOIN dbo.Users u ON u.Id = x.UserId
    OUTER APPLY (SELECT MAX(cc.CutoffAt) AS LastCutoff FROM dbo.CashClosing cc
                 WHERE cc.UserId = x.UserId AND cc.BranchId = @BranchId AND cc.Module = @Module AND cc.BusinessDate = @BusinessDate) cut
    CROSS APPLY dbo.fn_CashClosing_Txns(x.UserId, @BranchId, @Module, @BusinessDate, @BusinessDate) t
    WHERE t.IsCash = 1
      AND ((t.Module = 'PETTY' AND t.PettyClosingId IS NULL) OR (t.Module <> 'PETTY' AND t.CreatedAt > ISNULL(cut.LastCutoff, '19000101')))
    GROUP BY u.Id, u.FullName, u.Username
    ORDER BY UserName;

    DROP TABLE #U;
END;
GO

-- One closing with its lines (detail, print).
CREATE OR ALTER PROCEDURE dbo.usp_CashClosing_Get
    @CashClosingId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT cc.*, b.BranchName, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UserName,
           ISNULL(NULLIF(LTRIM(RTRIM(h.FullName)), ''), h.Username) AS HandedToName,
           ISNULL(NULLIF(LTRIM(RTRIM(v.FullName)), ''), v.Username) AS VerifiedByName, lt.VoucherNo
    FROM dbo.CashClosing cc
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = cc.BranchId
    LEFT JOIN dbo.Users u ON u.Id = cc.UserId
    LEFT JOIN dbo.Users h ON h.Id = cc.HandedToUserId
    LEFT JOIN dbo.Users v ON v.Id = cc.VerifiedBy
    LEFT JOIN dbo.Acc_LedgerTransaction lt ON lt.TransactionId = cc.TransactionId
    WHERE cc.CashClosingId = @CashClosingId;

    SELECT Kind, Module, ModeName, IsCash, Cnt, Amount FROM dbo.CashClosingLine WHERE CashClosingId = @CashClosingId
    ORDER BY CASE Kind WHEN 'RECEIPT' THEN 1 WHEN 'REFUND' THEN 2 WHEN 'PETTYOUT' THEN 3 ELSE 4 END, IsCash DESC, Module, ModeName;
END;
GO

-- A user's own closings of a module (history).
CREATE OR ALTER PROCEDURE dbo.usp_CashClosing_MyList
    @BranchId INT,
    @UserId   INT,
    @Module   VARCHAR(10),
    @Days     INT = 31
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 100 cc.CashClosingId, cc.ClosingNo, cc.Module, cc.BusinessDate, cc.SeqNo, cc.ExpectedCash, cc.CountedCash, cc.Difference, cc.HandedAmount,
           cc.RetainedFloat, cc.Status, cc.SubmittedOn, cc.VerifyRemarks, ISNULL(NULLIF(LTRIM(RTRIM(v.FullName)), ''), v.Username) AS VerifiedByName
    FROM dbo.CashClosing cc LEFT JOIN dbo.Users v ON v.Id = cc.VerifiedBy
    WHERE cc.BranchId = @BranchId AND cc.UserId = @UserId AND cc.Module = @Module
      AND cc.BusinessDate >= DATEADD(DAY, -ISNULL(@Days, 31), CAST(GETDATE() AS DATE))
    ORDER BY cc.BusinessDate DESC, cc.SeqNo DESC;
END;
GO

-- ── 12. A notification to a list of users (generic; the bell of 2263) ───────────────────────────────────────
-- One row per recipient and @EventKey (the same event is never notified twice). Returns the rows created with each
-- recipient's unread count, for the live push.
CREATE OR ALTER PROCEDURE dbo.usp_Notification_CreateMany
    @RecipientsJson NVARCHAR(MAX),          -- [1,2,3]
    @Category       VARCHAR(30),
    @Severity       VARCHAR(10) = 'INFO',
    @Title          NVARCHAR(200),
    @Message        NVARCHAR(1000),
    @Link           NVARCHAR(500) = NULL,
    @RefModule      VARCHAR(20) = NULL,
    @RefId          BIGINT = NULL,
    @EventKey       VARCHAR(120) = NULL,
    @BranchId       INT = NULL,
    @ActorUserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Severity NOT IN ('INFO', 'WARNING', 'CRITICAL') SET @Severity = 'INFO';
    DECLARE @Out TABLE (NotificationId BIGINT, UserId INT, Category VARCHAR(30), Severity VARCHAR(10), Title NVARCHAR(200),
                        Message NVARCHAR(1000), Link NVARCHAR(500), RefModule VARCHAR(20), RefId BIGINT, CreatedOn DATETIME2(0));

    INSERT INTO dbo.UserNotification (CompanyId, BranchId, UserId, Category, Severity, Title, Message, Link, RefModule, RefId, EventKey, CreatedBy)
    OUTPUT inserted.NotificationId, inserted.UserId, inserted.Category, inserted.Severity, inserted.Title, inserted.Message,
           inserted.Link, inserted.RefModule, inserted.RefId, inserted.CreatedOn INTO @Out
    SELECT u.CompanyId, @BranchId, u.Id, @Category, @Severity, @Title, @Message, @Link, @RefModule, @RefId, @EventKey, @ActorUserId
    FROM (SELECT DISTINCT TRY_CAST([value] AS INT) AS Id FROM OPENJSON(@RecipientsJson)) r
    INNER JOIN dbo.Users u ON u.Id = r.Id AND u.IsActive = 1
    WHERE (@EventKey IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.UserNotification n WHERE n.UserId = u.Id AND n.EventKey = @EventKey));

    SELECT o.*, (SELECT COUNT(1) FROM dbo.UserNotification n WHERE n.UserId = o.UserId AND n.IsDismissed = 0 AND n.IsRead = 0) AS UnreadCount
    FROM @Out o;
END;
GO

-- ── 13. Pages, controls, endpoints (no grant) ─────────────────────────────────────────────────────────────────
-- the first draft put one shared page under Utility > Accounts: removed (it was never granted)
DECLARE @old TABLE (Page_ID INT);
INSERT INTO @old SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code IN (N'UTILITY.ACCOUNTS.DAYCLOSING', N'UTILITY.ACCOUNTS.DAYCLOSINGVERIFY');
IF EXISTS (SELECT 1 FROM @old)
BEGIN
    DELETE FROM dbo.RolePermission WHERE Page_ID IN (SELECT Page_ID FROM @old);
    DELETE FROM dbo.UserPermission WHERE Page_ID IN (SELECT Page_ID FROM @old);
    DELETE FROM dbo.PageEndpointMap WHERE Page_ID IN (SELECT Page_ID FROM @old);
    DELETE FROM dbo.PageControlMaster WHERE Page_ID IN (SELECT Page_ID FROM @old);
    DELETE FROM dbo.PageMaster WHERE Page_ID IN (SELECT Page_ID FROM @old);
END
GO

DECLARE @Pages TABLE (Menu NVARCHAR(50), Code NVARCHAR(150), Title NVARCHAR(150), Controller NVARCHAR(100), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
    (N'OPD', N'OPD.DAYCLOSING',       N'OPD Day Closing',              N'OpdDayClosing', N'Index',  130, N'bi bi-cash-coin me-2'),
    (N'OPD', N'OPD.DAYCLOSINGVERIFY', N'OPD Day Closing Verification', N'OpdDayClosing', N'Verify', 131, N'bi bi-clipboard-check me-2'),
    (N'LAB', N'LAB.DAYCLOSING',       N'LAB Day Closing',              N'LabDayClosing', N'Index',  120, N'bi bi-cash-coin me-2'),
    (N'LAB', N'LAB.DAYCLOSINGVERIFY', N'LAB Day Closing Verification', N'LabDayClosing', N'Verify', 121, N'bi bi-clipboard-check me-2');

DECLARE @Controls TABLE (PageCode NVARCHAR(150), Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES
    (N'OPD.DAYCLOSING', 'CREATE', N'Submit a day closing', 20),  (N'OPD.DAYCLOSING', 'PRINT', N'Print the hand-over slip', 30),
    (N'OPD.DAYCLOSINGVERIFY', 'VERIFY', N'Verify / send back', 20),
    (N'LAB.DAYCLOSING', 'CREATE', N'Submit a day closing', 20),  (N'LAB.DAYCLOSING', 'PRINT', N'Print the hand-over slip', 30),
    (N'LAB.DAYCLOSINGVERIFY', 'VERIFY', N'Verify / send back', 20);

DECLARE @Endpoints TABLE (PageCode NVARCHAR(150), Method VARCHAR(10), Action NVARCHAR(100), Code VARCHAR(30));
INSERT INTO @Endpoints VALUES
    (N'DAYCLOSING', 'GET', N'Index', 'VIEW'),      (N'DAYCLOSING', 'GET', N'Summary', 'VIEW'),   (N'DAYCLOSING', 'GET', N'Receivers', 'VIEW'),
    (N'DAYCLOSING', 'POST', N'Submit', 'CREATE'),  (N'DAYCLOSING', 'GET', N'Slip', 'PRINT'),
    (N'DAYCLOSINGVERIFY', 'GET', N'Verify', 'VIEW'), (N'DAYCLOSINGVERIFY', 'GET', N'Board', 'VIEW'), (N'DAYCLOSINGVERIFY', 'GET', N'Detail', 'VIEW'),
    (N'DAYCLOSINGVERIFY', 'GET', N'VerifySlip', 'VIEW'), (N'DAYCLOSINGVERIFY', 'POST', N'VerifyAction', 'VERIFY');

DECLARE @co INT, @menu INT, @page INT, @ctl INT;
DECLARE @mc NVARCHAR(50), @pc NVARCHAR(150), @title NVARCHAR(150), @controller NVARCHAR(100), @action NVARCHAR(100), @sort INT, @icon NVARCHAR(100), @code VARCHAR(30), @method VARCHAR(10);

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE p1 CURSOR LOCAL FAST_FORWARD FOR SELECT Menu, Code, Title, Controller, Action, Sort, Icon FROM @Pages;
    OPEN p1; FETCH NEXT FROM p1 INTO @mc, @pc, @title, @controller, @action, @sort, @icon;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @menu = NULL;
        SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = @mc AND CompanyId = @co;
        IF @menu IS NOT NULL
        BEGIN
            SET @page = NULL;
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @pc, @Title = @title, @Controller = @controller, @Action = @action,
                 @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;

            DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls WHERE PageCode = @pc;
            OPEN c1; FETCH NEXT FROM c1 INTO @code, @title, @sort;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @code, @Title = @title, @Sort_Order = @sort, @Control_ID = @ctl OUTPUT;
                FETCH NEXT FROM c1 INTO @code, @title, @sort;
            END
            CLOSE c1; DEALLOCATE c1;

            DECLARE e1 CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Action, Code FROM @Endpoints WHERE PageCode = SUBSTRING(@pc, 5, 150);
            OPEN e1; FETCH NEXT FROM e1 INTO @method, @action, @code;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @ctl = NULL;
                SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @code;
                EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @method,
                     @Controller = @controller, @Action = @action, @Source = 'SEED';
                FETCH NEXT FROM e1 INTO @method, @action, @code;
            END
            CLOSE e1; DEALLOCATE e1;
        END
        FETCH NEXT FROM p1 INTO @mc, @pc, @title, @controller, @action, @sort, @icon;
    END
    CLOSE p1; DEALLOCATE p1;
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2275 applied: Cashier Day Closing (OPD and LAB) - tables, settings, ledgers, procedures, pages.';
GO
