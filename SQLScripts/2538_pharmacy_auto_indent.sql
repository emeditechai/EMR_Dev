-- ============================================================================================================
-- Migration: 2538_pharmacy_auto_indent.sql
-- Pharmacy auto indent (Pharmacy > Purchase > Auto Reorder, tab "Auto Indent Rules"):
--   * PhAutoIndentRule: per branch and item - the supplier the indent goes to, how much to ask for (QtyMode MAX =
--     up to the Max level, FIXED = a fixed quantity) and on / off. The reorder level and Max level stay where they
--     always were (PhItemBranch, else the item master), so reports, indents and suggestions keep one set of levels.
--   * Raised right after stock goes out: EMR.Web PharmacyAutoIndentWorker checks every minute the items that moved
--     in the stock ledger since its last check (PhAutoIndentState watermark) - the sale / issue itself is never
--     touched or slowed down. "Run now" checks every rule of the branch.
--   * An item is due when  stock + on order (approved / part / draft POs) + open indents (draft / submitted / approved,
--     not yet ordered) <= reorder level. Quantity: MAX = Max level - that total; FIXED = the rule's quantity; whole
--     packs. Due items of one supplier go into that supplier's open auto indent of the day (still SUBMITTED), else a
--     new indent: SUBMITTED for approval (Approval Matrix PHARMACY.PURCHASEINDENT; matrix approvers are notified);
--     once approved, the existing flow e-mails it to the supplier and turns it into a PO.
--   * Hospital Settings > MED: PharmacyAutoIndentEnabled (per branch, default off).
--   * PhAutoIndentLog: runs that raised something, manual runs and failures (shown on the page).
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyAutoIndentEnabled') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyAutoIndentEnabled BIT NOT NULL CONSTRAINT DF_HS_PhAutoIndentEnabled DEFAULT (0);
GO
IF COL_LENGTH('dbo.PhPurchaseIndent', 'IsAuto') IS NULL
    ALTER TABLE dbo.PhPurchaseIndent ADD IsAuto BIT NOT NULL CONSTRAINT DF_PhPurchaseIndent_IsAuto DEFAULT (0);
GO

IF OBJECT_ID('dbo.PhAutoIndentRule', 'U') IS NULL
CREATE TABLE dbo.PhAutoIndentRule (
    RuleId         INT IDENTITY(1,1) CONSTRAINT PK_PhAutoIndentRule PRIMARY KEY,
    CompanyId      INT NOT NULL,
    BranchId       INT NOT NULL,
    ItemId         INT NOT NULL CONSTRAINT FK_PhAutoIndentRule_Item REFERENCES dbo.PhItem (ItemId),
    SupplierId     INT NOT NULL CONSTRAINT FK_PhAutoIndentRule_Supplier REFERENCES dbo.PhSupplier (SupplierId),
    QtyMode        VARCHAR(5) NOT NULL CONSTRAINT DF_PhAutoIndentRule_Mode DEFAULT ('MAX'),   -- MAX | FIXED
    FixedQty       DECIMAL(12,2) NULL,                                                         -- packs, FIXED only
    IsActive       BIT NOT NULL CONSTRAINT DF_PhAutoIndentRule_Active DEFAULT (1),
    LastIndentId   INT NULL,
    LastIndentDate DATETIME NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_PhAutoIndentRule_Created DEFAULT (GETDATE()),
    ModifiedBy INT NULL, ModifiedDate DATETIME NOT NULL CONSTRAINT DF_PhAutoIndentRule_Modified DEFAULT (GETDATE()),
    CONSTRAINT UQ_PhAutoIndentRule_BranchItem UNIQUE (BranchId, ItemId),
    CONSTRAINT CK_PhAutoIndentRule_Mode CHECK (QtyMode IN ('MAX', 'FIXED') AND (QtyMode = 'MAX' OR FixedQty > 0))
);
GO
IF OBJECT_ID('dbo.PhAutoIndentState', 'U') IS NULL
CREATE TABLE dbo.PhAutoIndentState (
    BranchId     INT NOT NULL CONSTRAINT PK_PhAutoIndentState PRIMARY KEY,
    LastLedgerId BIGINT NOT NULL CONSTRAINT DF_PhAutoIndentState_Ledger DEFAULT (0),   -- stock ledger rows up to here are checked
    LastRunAt    DATETIME NULL
);
GO
IF OBJECT_ID('dbo.PhAutoIndentLog', 'U') IS NULL
CREATE TABLE dbo.PhAutoIndentLog (
    LogId          INT IDENTITY(1,1) CONSTRAINT PK_PhAutoIndentLog PRIMARY KEY,
    CompanyId      INT NOT NULL,
    BranchId       INT NOT NULL,
    RunAt          DATETIME NOT NULL CONSTRAINT DF_PhAutoIndentLog_RunAt DEFAULT (GETDATE()),
    RunType        VARCHAR(10) NOT NULL,          -- AUTO | MANUAL
    ItemsChecked   INT NOT NULL CONSTRAINT DF_PhAutoIndentLog_Checked DEFAULT (0),
    LinesRaised    INT NOT NULL CONSTRAINT DF_PhAutoIndentLog_Lines DEFAULT (0),
    IndentsNew     INT NOT NULL CONSTRAINT DF_PhAutoIndentLog_New DEFAULT (0),
    IndentsAdded   INT NOT NULL CONSTRAINT DF_PhAutoIndentLog_Added DEFAULT (0),
    Message        NVARCHAR(1000) NULL,
    IsError        BIT NOT NULL CONSTRAINT DF_PhAutoIndentLog_Err DEFAULT (0),
    UserId         INT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhAutoIndentLog_Branch' AND object_id = OBJECT_ID('dbo.PhAutoIndentLog'))
    CREATE INDEX IX_PhAutoIndentLog_Branch ON dbo.PhAutoIndentLog (BranchId, RunAt DESC);
GO

-- ── the auto indent picture of every stocked item of a branch (levels in purchase packs) ───────────────────────
CREATE OR ALTER FUNCTION dbo.fn_PhAutoIndentCalc (@CompanyId INT, @BranchId INT)
RETURNS TABLE
AS
RETURN
    SELECT b.*,
           CAST(b.StockPacks + b.OnOrder + b.OpenIndent AS DECIMAL(14,2)) AS Available,
           CAST(CASE WHEN b.RuleId IS NOT NULL AND b.RuleActive = 1 AND b.SupplierActive = 1
                          AND b.StockPacks + b.OnOrder + b.OpenIndent <= b.ReorderLevel
                          AND (b.ReorderLevel > 0 OR b.QtyMode = 'FIXED')
                     THEN 1 ELSE 0 END AS BIT) AS IsDue,
           CAST(CASE WHEN b.RuleId IS NULL OR b.RuleActive = 0 OR b.SupplierActive = 0
                          OR b.StockPacks + b.OnOrder + b.OpenIndent > b.ReorderLevel
                          OR (b.ReorderLevel <= 0 AND b.QtyMode <> 'FIXED') THEN 0
                     WHEN b.QtyMode = 'FIXED' THEN CEILING(ISNULL(b.FixedQty, 0))
                     WHEN b.MaxQty > b.StockPacks + b.OnOrder + b.OpenIndent THEN CEILING(b.MaxQty - (b.StockPacks + b.OnOrder + b.OpenIndent))
                     ELSE 0 END AS DECIMAL(12,2)) AS NextQty
      FROM (
        SELECT f.ItemId, f.ItemCode, f.ItemName, f.FormShort, f.Strength, f.PackSize, f.GenericName, f.ManufacturerName, f.PurchaseUom,
               f.ConversionQty, f.Stock AS StockUnits, i.CategoryId, c.ParentCategoryId, i.LeadDays,
               CAST(ISNULL(f.Stock / NULLIF(f.ConversionQty, 0), 0) AS DECIMAL(14,2)) AS StockPacks,
               CAST(f.PendingPoQty + ISNULL((SELECT SUM(pd.Qty - pd.ReceivedQty) FROM dbo.PhPurchaseOrderDtl pd
                                               JOIN dbo.PhPurchaseOrder po ON po.PoId = pd.PoId
                                              WHERE po.BranchId = @BranchId AND po.Status = 'DRAFT' AND pd.ItemId = f.ItemId AND pd.Qty > pd.ReceivedQty), 0)
                    AS DECIMAL(14,2)) AS OnOrder,
               CAST(ISNULL((SELECT SUM(d.Qty) FROM dbo.PhPurchaseIndentDtl d
                              JOIN dbo.PhPurchaseIndent pi ON pi.IndentId = d.IndentId
                             WHERE pi.BranchId = @BranchId AND pi.Status IN ('DRAFT', 'SUBMITTED', 'APPROVED') AND d.ItemId = f.ItemId
                               AND NOT EXISTS (SELECT 1 FROM dbo.PhPurchaseOrder o WHERE o.IndentId = pi.IndentId AND o.Status <> 'CANCELLED')), 0)
                    AS DECIMAL(14,2)) AS OpenIndent,
               CAST(ISNULL(f.ReorderLevel, 0) AS DECIMAL(12,2)) AS ReorderLevel, CAST(ISNULL(f.MaxQty, 0) AS DECIMAL(12,2)) AS MaxQty,
               f.LastRate,
               r.RuleId, r.SupplierId, sp.SupplierName, ISNULL(sp.IsActive, 0) AS SupplierActive, r.QtyMode, r.FixedQty,
               ISNULL(r.IsActive, 0) AS RuleActive, r.LastIndentId, r.LastIndentDate, r.ModifiedDate AS RuleModified
          FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f
          JOIN dbo.PhItem i ON i.ItemId = f.ItemId
          JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
          LEFT JOIN dbo.PhAutoIndentRule r ON r.BranchId = @BranchId AND r.ItemId = f.ItemId AND r.CompanyId = @CompanyId
          LEFT JOIN dbo.PhSupplier sp ON sp.SupplierId = r.SupplierId
         WHERE f.IsActive = 1 AND f.IsStocked = 1
      ) b;
GO

-- ── the page: settings + rows (filter RULES = items with a rule, DUE = due now, NORULE = no rule yet, ALL) ──────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhAutoIndent_List
    @CompanyId INT, @BranchId INT, @SupplierId INT = NULL, @CategoryId INT = NULL, @Filter VARCHAR(10) = 'RULES', @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @on BIT, @days INT, @safety INT, @cover INT;
    SELECT TOP 1 @on = PharmacyAutoIndentEnabled, @days = PharmacyReorderSalesDays, @safety = PharmacyReorderSafetyDays, @cover = PharmacyReorderCoverDays
      FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC, Id DESC;
    SET @days = CASE WHEN ISNULL(@days, 0) < 1 THEN 30 ELSE @days END;
    SET @safety = ISNULL(@safety, 3); SET @cover = ISNULL(@cover, 15);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');

    SELECT * INTO #calc FROM dbo.fn_PhAutoIndentCalc(@CompanyId, @BranchId);

    -- 1: settings and counts
    SELECT ISNULL(@on, 0) AS Enabled, @days AS SalesDays, @safety AS SafetyDays, @cover AS CoverDays,
           (SELECT LastRunAt FROM dbo.PhAutoIndentState WHERE BranchId = @BranchId) AS LastCheckAt,
           (SELECT COUNT(*) FROM #calc WHERE RuleId IS NOT NULL) AS Rules,
           (SELECT COUNT(*) FROM #calc WHERE RuleActive = 1) AS ActiveRules,
           (SELECT COUNT(*) FROM #calc WHERE IsDue = 1 AND NextQty > 0) AS DueNow,
           (SELECT COUNT(*) FROM dbo.PhPurchaseIndent WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND IsAuto = 1 AND Status = 'SUBMITTED') AS AwaitingApproval;

    DECLARE @from DATETIME = DATEADD(DAY, -@days, CAST(GETDATE() AS DATE));
    ;WITH sold AS (
        SELECT l.ItemId, SUM(CASE WHEN l.DocType = 'SALE' THEN l.QtyOut WHEN l.DocType = 'SRET' THEN -l.QtyIn ELSE 0 END) AS SoldUnits
          FROM dbo.PhStockLedger l
         WHERE l.BranchId = @BranchId AND l.TxnDate >= @from AND l.DocType IN ('SALE', 'SRET')
         GROUP BY l.ItemId
    )
    -- 2: the items
    SELECT c.ItemId, c.ItemCode, c.ItemName, c.FormShort, c.Strength, c.PackSize, c.GenericName, c.PurchaseUom, c.LeadDays,
           c.StockPacks, c.OnOrder, c.OpenIndent, c.Available, c.ReorderLevel, c.MaxQty,
           c.RuleId, c.SupplierId, c.SupplierName, c.QtyMode, c.FixedQty, c.RuleActive, c.IsDue, c.NextQty,
           c.LastIndentDate, li.IndentNo AS LastIndentNo,
           ls.SupplierId AS LastSupplierId, ls.SupplierName AS LastSupplierName,
           -- sales-based levels ("Suggest from sales"): reorder at lead + safety days, up to lead + safety + cover days
           CAST(a.AvgDaily AS DECIMAL(14,3)) AS AvgDaily,
           CAST(CASE WHEN a.AvgDaily > 0 THEN CEILING(a.AvgDaily * (c.LeadDays + @safety)) END AS DECIMAL(12,2)) AS SuggReorderLevel,
           CAST(CASE WHEN a.AvgDaily > 0 THEN CEILING(a.AvgDaily * (c.LeadDays + @safety + @cover)) END AS DECIMAL(12,2)) AS SuggMaxQty
      FROM #calc c
      LEFT JOIN sold s ON s.ItemId = c.ItemId
      CROSS APPLY (SELECT CASE WHEN ISNULL(s.SoldUnits, 0) > 0 AND c.ConversionQty > 0 THEN s.SoldUnits / c.ConversionQty / @days ELSE 0 END AS AvgDaily) a
      LEFT JOIN dbo.PhPurchaseIndent li ON li.IndentId = c.LastIndentId
      OUTER APPLY (SELECT TOP 1 gr.SupplierId, sp.SupplierName
                     FROM dbo.PhGrnDtl d JOIN dbo.PhGrn gr ON gr.GrnId = d.GrnId JOIN dbo.PhSupplier sp ON sp.SupplierId = gr.SupplierId
                    WHERE d.ItemId = c.ItemId AND gr.Status = 'POSTED' AND gr.CompanyId = @CompanyId AND sp.IsActive = 1
                    ORDER BY gr.PostedDate DESC, gr.GrnId DESC) ls
     WHERE (@CategoryId IS NULL OR c.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@SupplierId IS NULL OR c.SupplierId = @SupplierId OR (c.RuleId IS NULL AND ls.SupplierId = @SupplierId))
       AND (@Search IS NULL OR c.ItemName LIKE N'%' + @Search + N'%' OR c.ItemCode LIKE N'%' + @Search + N'%' OR c.GenericName LIKE N'%' + @Search + N'%')
       AND (@Filter = 'ALL'
         OR (@Filter = 'RULES' AND c.RuleId IS NOT NULL)
         OR (@Filter = 'DUE' AND c.IsDue = 1 AND c.NextQty > 0)
         OR (@Filter = 'NORULE' AND c.RuleId IS NULL))
     ORDER BY CASE WHEN c.IsDue = 1 AND c.NextQty > 0 THEN 0 ELSE 1 END, c.SupplierName, c.ItemName;
END
GO

-- ── save rules (all or nothing). @Rules: [{ItemId, SupplierId, ReorderLevel, MaxQty, QtyMode, FixedQty, IsActive, Remove}] ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhAutoIndent_SaveRules
    @CompanyId INT, @BranchId INT, @UserId INT, @Rules NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF ISJSON(@Rules) <> 1 BEGIN SELECT 0 AS ItemId, N'The rules could not be read.' AS Error; RETURN; END;

    SELECT j.ItemId, j.SupplierId, CAST(ISNULL(j.ReorderLevel, 0) AS DECIMAL(12,2)) AS ReorderLevel, CAST(ISNULL(j.MaxQty, 0) AS DECIMAL(12,2)) AS MaxQty,
           CASE WHEN j.QtyMode = 'FIXED' THEN 'FIXED' ELSE 'MAX' END AS QtyMode, CAST(j.FixedQty AS DECIMAL(12,2)) AS FixedQty,
           ISNULL(j.IsActive, 1) AS IsActive, ISNULL(j.Remove, 0) AS Remove, i.ItemName
      INTO #r
      FROM OPENJSON(@Rules) WITH (ItemId INT, SupplierId INT, ReorderLevel DECIMAL(12,2), MaxQty DECIMAL(12,2), QtyMode VARCHAR(5),
                                  FixedQty DECIMAL(12,2), IsActive BIT, Remove BIT) j
      LEFT JOIN dbo.PhItem i ON i.ItemId = j.ItemId AND i.CompanyId = @CompanyId;

    -- 1: problems (nothing is saved when there is one)
    SELECT ItemId, Error FROM (
        SELECT r.ItemId, CASE
                 WHEN r.ItemName IS NULL THEN N'Item ' + CAST(r.ItemId AS NVARCHAR(12)) + N' not found.'
                 WHEN r.Remove = 1 THEN NULL
                 WHEN NOT EXISTS (SELECT 1 FROM dbo.PhSupplier s WHERE s.SupplierId = r.SupplierId AND s.CompanyId = @CompanyId AND s.IsActive = 1)
                      THEN r.ItemName + N': pick the supplier.'
                 WHEN r.ReorderLevel < 0 OR r.MaxQty < 0 THEN r.ItemName + N': levels cannot be negative.'
                 WHEN r.QtyMode = 'MAX' AND r.ReorderLevel <= 0 THEN r.ItemName + N': set the reorder level (above 0).'
                 WHEN r.QtyMode = 'MAX' AND r.MaxQty <= r.ReorderLevel THEN r.ItemName + N': Max level must be above the reorder level.'
                 WHEN r.QtyMode = 'FIXED' AND ISNULL(r.FixedQty, 0) <= 0 THEN r.ItemName + N': enter the fixed indent quantity.'
                 WHEN r.FixedQty > 1000000 OR r.MaxQty > 1000000 OR r.ReorderLevel > 1000000 THEN r.ItemName + N': quantity too large.'
               END AS Error
          FROM #r r) x
     WHERE x.Error IS NOT NULL;
    IF @@ROWCOUNT > 0 RETURN;

    BEGIN TRAN;
    -- the levels live on the item's branch record (as everywhere else in the pharmacy)
    MERGE dbo.PhItemBranch AS t
    USING (SELECT ItemId, ReorderLevel, MaxQty FROM #r WHERE Remove = 0) s ON t.ItemId = s.ItemId AND t.BranchId = @BranchId
    WHEN MATCHED THEN UPDATE SET ReorderLevel = s.ReorderLevel, MaxQty = s.MaxQty, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHEN NOT MATCHED THEN INSERT (ItemId, BranchId, ReorderLevel, MaxQty, ModifiedBy, ModifiedDate) VALUES (s.ItemId, @BranchId, s.ReorderLevel, s.MaxQty, @UserId, GETDATE());

    MERGE dbo.PhAutoIndentRule AS t
    USING (SELECT ItemId, SupplierId, QtyMode, CASE WHEN QtyMode = 'FIXED' THEN FixedQty END AS FixedQty, IsActive FROM #r WHERE Remove = 0) s
       ON t.BranchId = @BranchId AND t.ItemId = s.ItemId
    WHEN MATCHED THEN UPDATE SET SupplierId = s.SupplierId, QtyMode = s.QtyMode, FixedQty = s.FixedQty, IsActive = s.IsActive,
                                 CompanyId = @CompanyId, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHEN NOT MATCHED THEN INSERT (CompanyId, BranchId, ItemId, SupplierId, QtyMode, FixedQty, IsActive, CreatedBy, ModifiedBy)
                          VALUES (@CompanyId, @BranchId, s.ItemId, s.SupplierId, s.QtyMode, s.FixedQty, s.IsActive, @UserId, @UserId);

    DELETE t FROM dbo.PhAutoIndentRule t JOIN #r r ON r.ItemId = t.ItemId AND r.Remove = 1 WHERE t.BranchId = @BranchId;
    COMMIT;
END
GO

-- ── raise the indents. @RunType AUTO = items that moved in the stock ledger since the last check (and rules changed
--    since then); MANUAL = every rule of the branch. 1: summary, 2: indents raised / added to ──────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhAutoIndent_Run
    @CompanyId INT, @BranchId INT, @UserId INT = NULL, @RunType VARCHAR(10) = 'AUTO'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @RunType = CASE WHEN @RunType = 'MANUAL' THEN 'MANUAL' ELSE 'AUTO' END;
    DECLARE @on BIT = (SELECT TOP 1 PharmacyAutoIndentEnabled FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC, Id DESC);
    CREATE TABLE #out (IndentId INT, IndentNo NVARCHAR(40), SupplierId INT, SupplierName NVARCHAR(150), Lines INT, IsNew BIT);

    IF ISNULL(@on, 0) = 0
    BEGIN
        SELECT N'Auto indent is off for this branch (Hospital Settings > MED).' AS Message, 0 AS ItemsChecked, 0 AS LinesRaised, 0 AS IndentsNew, 0 AS IndentsAdded, CAST(1 AS BIT) AS IsError;
        SELECT * FROM #out; RETURN;
    END;

    DECLARE @wm BIGINT, @lastRun DATETIME, @maxL BIGINT;
    SELECT @wm = LastLedgerId, @lastRun = LastRunAt FROM dbo.PhAutoIndentState WHERE BranchId = @BranchId;
    IF @wm IS NULL
    BEGIN
        -- first check of the branch: everything is looked at once
        INSERT dbo.PhAutoIndentState (BranchId, LastLedgerId, LastRunAt) VALUES (@BranchId, 0, NULL);
        SET @wm = 0;
    END;
    SET @maxL = ISNULL((SELECT MAX(LedgerId) FROM dbo.PhStockLedger WHERE BranchId = @BranchId), 0);

    -- quick exit for the every-minute check: nothing moved and no rule changed
    IF @RunType = 'AUTO' AND @lastRun IS NOT NULL AND @maxL <= @wm
       AND NOT EXISTS (SELECT 1 FROM dbo.PhAutoIndentRule WHERE BranchId = @BranchId AND ModifiedDate > @lastRun)
    BEGIN
        UPDATE dbo.PhAutoIndentState SET LastRunAt = GETDATE() WHERE BranchId = @BranchId;
        SELECT N'Nothing moved.' AS Message, 0 AS ItemsChecked, 0 AS LinesRaised, 0 AS IndentsNew, 0 AS IndentsAdded, CAST(0 AS BIT) AS IsError;
        SELECT * FROM #out; RETURN;
    END;

    DECLARE @checked INT = 0, @lines INT = 0, @new INT = 0, @added INT = 0, @today DATE = CAST(GETDATE() AS DATE);
    BEGIN TRY
        BEGIN TRAN;
        -- one run per branch at a time (the worker and "Run now")
        DECLARE @lock INT, @res NVARCHAR(100) = CONCAT(N'PhAutoIndent_', @BranchId);
        EXEC @lock = sp_getapplock @Resource = @res, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
        IF @lock < 0 THROW 51500, 'Another auto indent check is running. Try again in a moment.', 1;

        SELECT r.ItemId INTO #cand
          FROM dbo.PhAutoIndentRule r
         WHERE r.BranchId = @BranchId AND r.CompanyId = @CompanyId AND r.IsActive = 1
           AND (@RunType = 'MANUAL' OR @lastRun IS NULL OR r.ModifiedDate > @lastRun
                OR EXISTS (SELECT 1 FROM dbo.PhStockLedger l WHERE l.BranchId = @BranchId AND l.ItemId = r.ItemId AND l.LedgerId > @wm));
        SET @checked = @@ROWCOUNT;

        SELECT c.ItemId, c.SupplierId, c.SupplierName, c.NextQty, c.StockUnits, c.StockPacks, c.Available, c.ReorderLevel
          INTO #due
          FROM dbo.fn_PhAutoIndentCalc(@CompanyId, @BranchId) c
          JOIN #cand k ON k.ItemId = c.ItemId
         WHERE c.IsDue = 1 AND c.NextQty > 0;

        DECLARE @sup INT, @supName NVARCHAR(150), @ind INT, @no NVARCHAR(40), @isNew BIT, @n INT;
        DECLARE sc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT SupplierId, SupplierName FROM #due;
        OPEN sc; FETCH NEXT FROM sc INTO @sup, @supName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ind = NULL; SET @isNew = 0; SET @no = NULL;
            -- the supplier's auto indent of today, still waiting for approval: add to it
            SELECT TOP 1 @ind = IndentId, @no = IndentNo FROM dbo.PhPurchaseIndent WITH (UPDLOCK)
             WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND SupplierId = @sup AND IsAuto = 1 AND Status = 'SUBMITTED' AND IndentDate = @today
             ORDER BY IndentId DESC;
            IF @ind IS NULL
            BEGIN
                EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'PIND', @DocDate = @today, @DocNo = @no OUTPUT;
                INSERT dbo.PhPurchaseIndent (CompanyId, BranchId, IndentNo, IndentDate, Priority, Status, Remarks, CreatedBy, SubmittedBy, SubmittedDate, SupplierId, IsAuto)
                VALUES (@CompanyId, @BranchId, @no, @today, 'NORMAL', 'SUBMITTED',
                        N'Auto indent: raised by the system when stock fell to the reorder level (Auto Reorder > Auto Indent Rules).',
                        @UserId, @UserId, GETDATE(), @sup, 1);
                SET @ind = CAST(SCOPE_IDENTITY() AS INT); SET @isNew = 1;
            END;

            INSERT dbo.PhPurchaseIndentDtl (IndentId, ItemId, Qty, StockAtIndent, Remarks)
            SELECT @ind, d.ItemId, d.NextQty, d.StockUnits,
                   LEFT(N'Auto: stock ' + FORMAT(d.StockPacks, '0.##') + N', with orders / indents ' + FORMAT(d.Available, '0.##')
                        + N' at or below reorder level ' + FORMAT(d.ReorderLevel, '0.##'), 200)
              FROM #due d
             WHERE d.SupplierId = @sup
               AND NOT EXISTS (SELECT 1 FROM dbo.PhPurchaseIndentDtl x WHERE x.IndentId = @ind AND x.ItemId = d.ItemId);
            SET @n = @@ROWCOUNT;

            IF @n > 0
            BEGIN
                UPDATE r SET LastIndentId = @ind, LastIndentDate = GETDATE()
                  FROM dbo.PhAutoIndentRule r JOIN #due d ON d.ItemId = r.ItemId AND d.SupplierId = @sup
                 WHERE r.BranchId = @BranchId;
                INSERT #out VALUES (@ind, @no, @sup, @supName, @n, @isNew);
                SET @lines += @n;
                IF @isNew = 1 SET @new += 1; ELSE SET @added += 1;
            END
            FETCH NEXT FROM sc INTO @sup, @supName;
        END
        CLOSE sc; DEALLOCATE sc;

        UPDATE dbo.PhAutoIndentState SET LastLedgerId = CASE WHEN @maxL > LastLedgerId THEN @maxL ELSE LastLedgerId END, LastRunAt = GETDATE()
         WHERE BranchId = @BranchId;

        IF @lines > 0 OR @RunType = 'MANUAL'
            INSERT dbo.PhAutoIndentLog (CompanyId, BranchId, RunType, ItemsChecked, LinesRaised, IndentsNew, IndentsAdded, Message, UserId)
            VALUES (@CompanyId, @BranchId, @RunType, @checked, @lines, @new, @added,
                    CASE WHEN @lines = 0 THEN N'Nothing due.'
                         ELSE (SELECT STRING_AGG(CONCAT(o.IndentNo, N' ', o.SupplierName, N' (', o.Lines, N' item', CASE WHEN o.Lines > 1 THEN N's' END,
                                                        CASE WHEN o.IsNew = 1 THEN N', new' ELSE N', added' END, N')'), N'; ') FROM #out o) END,
                    @UserId);
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @err NVARCHAR(1000) = ERROR_MESSAGE();
        INSERT dbo.PhAutoIndentLog (CompanyId, BranchId, RunType, ItemsChecked, Message, IsError, UserId)
        VALUES (@CompanyId, @BranchId, @RunType, @checked, LEFT(N'Failed: ' + @err, 1000), 1, @UserId);
        SELECT N'Auto indent failed: ' + @err AS Message, @checked AS ItemsChecked, 0 AS LinesRaised, 0 AS IndentsNew, 0 AS IndentsAdded, CAST(1 AS BIT) AS IsError;
        SELECT * FROM #out WHERE 1 = 0; RETURN;
    END CATCH;

    SELECT CASE WHEN @lines = 0 THEN N'Nothing due: every item with a rule is above its reorder level or already on order / indent.'
                ELSE CONCAT(@lines, N' item(s) indented: ', @new, N' new indent(s), ', @added, N' added to today''s open indent(s).') END AS Message,
           @checked AS ItemsChecked, @lines AS LinesRaised, @new AS IndentsNew, @added AS IndentsAdded, CAST(0 AS BIT) AS IsError;
    SELECT * FROM #out;
END
GO

-- ── branches the worker checks ─────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhAutoIndent_Branches
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT hs.BranchId, b.CompanyId
      FROM dbo.HospitalSettings hs
      JOIN dbo.BranchMaster b ON b.BranchID = hs.BranchId
     WHERE hs.PharmacyAutoIndentEnabled = 1 AND hs.IsActive = 1 AND ISNULL(b.IsActive, 1) = 1
       AND EXISTS (SELECT 1 FROM dbo.PhAutoIndentRule r WHERE r.BranchId = hs.BranchId AND r.IsActive = 1);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhAutoIndent_Log
    @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 50 l.LogId, l.RunAt, l.RunType, l.ItemsChecked, l.LinesRaised, l.IndentsNew, l.IndentsAdded, l.Message, l.IsError,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS RunBy
      FROM dbo.PhAutoIndentLog l
      LEFT JOIN dbo.Users u ON u.Id = l.UserId
     WHERE l.BranchId = @BranchId AND l.CompanyId = @CompanyId
     ORDER BY l.RunAt DESC, l.LogId DESC;
END
GO

-- ── page controls: the Auto Reorder page gets "Auto indent rules" (save / run now); no role is granted anything ──
DECLARE @page INT, @view INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'PHARMACY.AUTOREORDER';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'AUTOINDENT', @Title = N'Auto indent rules (save, run now)', @Sort_Order = 30, @Control_ID = @ctl OUTPUT;
    IF @view IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhAutoReorder', @Action = N'RulesData', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhAutoReorder', @Action = N'RunLog', @Source = 'SEED';
    END
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhAutoReorder', @Action = N'SaveRules', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhAutoReorder', @Action = N'RunNow', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT 'Script 2538 applied: pharmacy auto indent (rules, run, log, setting).';
GO
