-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2437  IPD Phase 4 · Pharmacy integration (Pharmacy Phase C): medicines and consumables issued to an admitted patient
--   IPD Patient screen > Medicine Indent / Consumables tabs: the pharmacy issues batches from a selling store against
--   the IP number; nothing is paid at the counter, the amount goes to the IP bill (IpdCharge head PHARMACY / CONSUMABLE).
--   Stock      usp_PhStock_Move (the only stock writer), doc types IPI (issue) / IPR (return), FEFO batches, no expired /
--              blocked batch, never negative
--   Price      fn_PhSaleUnitPrice with the payer's price type (Price Rule master: IPD_CASH / IPD_CORPORATE / IPD_INSURANCE),
--              never above MRP; GST inclusive; Hospital Settings > MED "IPD GST exempt" (default yes) bills it without GST
--   Return     unused quantity back to the same store before the final bill: the charge is re-posted for what is kept
--   Accounts   JRN at cost: issue Dr Pharmacy Cost of Goods Sold · Cr Pharmacy Inventory; return the reverse. Revenue is
--              the IPD final bill (IPD Revenue).
--   usp_Api_IpdPh_Items, _Issue, _Return, _List. Needs 2343-2364 (pharmacy) and 2434. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.IpdPhIssue', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdPhIssue
    (
        IssueId      INT IDENTITY(1,1) CONSTRAINT PK_IpdPhIssue PRIMARY KEY,
        CompanyId    INT            NOT NULL,
        BranchId     INT            NOT NULL,
        AdmissionId  INT            NOT NULL CONSTRAINT FK_IpdPhIssue_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        Kind         VARCHAR(10)    NOT NULL,   -- ISSUE RETURN
        IssueNo      NVARCHAR(40)   NOT NULL,
        IssueAt      DATETIME       NOT NULL,
        StoreId      INT            NOT NULL,
        Head         VARCHAR(20)    NOT NULL,   -- PHARMACY CONSUMABLE
        DoctorId     INT            NULL,
        PriceType    VARCHAR(20)    NOT NULL,
        Total        DECIMAL(18,2)  NOT NULL,
        CostTotal    DECIMAL(18,2)  NOT NULL,
        Remarks      NVARCHAR(300)  NULL,
        LedgerTxnId  BIGINT         NULL,
        CreatedBy    INT            NULL,
        CreatedDate  DATETIME       NOT NULL CONSTRAINT DF_IpdPhIssue_Created DEFAULT (GETDATE()),
        CONSTRAINT CK_IpdPhIssue_Kind CHECK (Kind IN ('ISSUE', 'RETURN')),
        CONSTRAINT CK_IpdPhIssue_Head CHECK (Head IN ('PHARMACY', 'CONSUMABLE'))
    );
    CREATE INDEX IX_IpdPhIssue_Adm ON dbo.IpdPhIssue (AdmissionId, IssueAt);
END
GO
IF OBJECT_ID('dbo.IpdPhIssueLine', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdPhIssueLine
    (
        LineId       INT IDENTITY(1,1) CONSTRAINT PK_IpdPhIssueLine PRIMARY KEY,
        IssueId      INT            NOT NULL CONSTRAINT FK_IpdPhIssueLine_Issue REFERENCES dbo.IpdPhIssue (IssueId),
        ItemId       INT            NOT NULL,
        BatchId      INT            NOT NULL,
        Qty          DECIMAL(14,3)  NOT NULL,      -- sale units
        UnitPrice    DECIMAL(12,4)  NOT NULL,      -- GST inclusive
        GstPercent   DECIMAL(5,2)   NOT NULL,
        Amount       DECIMAL(18,2)  NOT NULL,
        UnitCost     DECIMAL(12,4)  NOT NULL,
        IssueLineId  INT            NULL,          -- RETURN: the issue line given back
        ReturnedQty  DECIMAL(14,3)  NOT NULL CONSTRAINT DF_IpdPhIssueLine_Ret DEFAULT (0),   -- ISSUE: given back so far
        ChargeId     BIGINT         NULL,          -- ISSUE: the IP bill charge for what is kept
        CONSTRAINT CK_IpdPhIssueLine_Qty CHECK (Qty > 0)
    );
    CREATE INDEX IX_IpdPhIssueLine_Issue ON dbo.IpdPhIssueLine (IssueId);
END
GO

-- Schedule register (H1 / X / NDPS): IPD issues are entered too (no sale: the IPD issue instead)
IF COL_LENGTH('dbo.PhScheduleRegister', 'IpdIssueId') IS NULL
BEGIN
    ALTER TABLE dbo.PhScheduleRegister ALTER COLUMN SaleId INT NULL;
    ALTER TABLE dbo.PhScheduleRegister ALTER COLUMN SaleDtlId INT NULL;
    ALTER TABLE dbo.PhScheduleRegister ADD IpdIssueId INT NULL, IpdIssueLineId INT NULL;
END
GO
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_PhSale_ScheduleRegister'));
IF @def NOT LIKE '%IpdPhIssue%'
BEGIN
    IF @def NOT LIKE '%JOIN dbo.PhSale s ON s.SaleId = r.SaleId%' THROW 51320, 'usp_Api_PhSale_ScheduleRegister has changed: add the IPD issues by hand.', 1;
    SET @def = REPLACE(@def, 'JOIN dbo.PhSale s ON s.SaleId = r.SaleId', 'LEFT JOIN dbo.PhSale s ON s.SaleId = r.SaleId LEFT JOIN dbo.IpdPhIssue ipi ON ipi.IssueId = r.IpdIssueId');
    SET @def = REPLACE(@def, 'SELECT r.EntryDate, s.SaleNo,', 'SELECT r.EntryDate, COALESCE(s.SaleNo, ipi.IssueNo) AS SaleNo,');
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
GO

-- register entries of an IPD issue / return (items whose schedule needs the register)
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PhRegister @IssueId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.PhScheduleRegister (CompanyId, BranchId, SaleId, SaleDtlId, IpdIssueId, IpdIssueLineId, EntryDate, ScheduleCode, ItemId, BatchId, Qty,
                                   PatientName, PatientAddress, PrescriberName, PrescriberRegNo, RxNo, DispensedBy)
    SELECT s.CompanyId, s.BranchId, NULL, NULL, s.IssueId, l.LineId, s.IssueAt, i.ScheduleCode, l.ItemId, l.BatchId, CASE WHEN s.Kind = 'RETURN' THEN -l.Qty ELSE l.Qty END,
           LEFT(LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName))) + N' (IP ' + a.IpNo + N')', 200), LEFT(ISNULL(p.Address, N'In-patient'), 300),
           LEFT(ISNULL(d.FullName, N'—'), 150), d.MedicalLicenseNo, LEFT(a.IpNo, 50), @UserId
    FROM dbo.IpdPhIssue s
    JOIN dbo.IpdPhIssueLine l ON l.IssueId = s.IssueId
    JOIN dbo.PhItem i ON i.ItemId = l.ItemId
    JOIN dbo.PhDrugSchedule sc ON sc.ScheduleCode = i.ScheduleCode AND sc.RegisterRequired = 1
    JOIN dbo.IpdAdmission a ON a.AdmissionId = s.AdmissionId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = COALESCE(s.DoctorId, (SELECT x.DoctorId FROM dbo.IpdPhIssue x JOIN dbo.IpdPhIssueLine xl ON xl.IssueId = x.IssueId WHERE xl.LineId = l.IssueLineId), a.ConsultantDoctorId)
    WHERE s.IssueId = @IssueId;
END;
GO

-- price type of the Price Rule master for an admission's payer
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PhPriceType (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT CAST(CASE a.PayerType WHEN 'CORPORATE' THEN 'IPD_CORPORATE' WHEN 'INSURANCE' THEN 'IPD_INSURANCE' WHEN 'SCHEME' THEN 'IPD_INSURANCE' ELSE 'IPD_CASH' END AS VARCHAR(20)) AS PriceType
    FROM dbo.IpdAdmission a WHERE a.AdmissionId = @AdmissionId
);
GO

-- ── items with stock in the selling store (search as you type) ────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPh_Items @CompanyId INT, @BranchId INT, @Q NVARCHAR(100) = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0 SET @StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL');
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Q + N'%';
    DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
    SELECT TOP (30) i.ItemId, i.ItemCode, i.ItemName, i.PackSize, i.ScheduleCode, i.IsHighAlert, i.IsLasa, i.IsColdChain,
           SUM(s.QtyOnHand) AS Stock, MIN(b.ExpiryDate) AS NearestExpiry, @StoreId AS StoreId
    FROM dbo.PhItem i
    JOIN dbo.PhStoreStock s ON s.ItemId = i.ItemId AND s.StoreId = @StoreId AND s.QtyOnHand > 0
    JOIN dbo.PhBatch b ON b.BatchId = s.BatchId AND b.IsBlocked = 0 AND b.ExpiryDate > DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE))
    WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 AND (@Q IS NULL OR i.ItemName LIKE @like OR i.ItemCode LIKE @like OR i.Barcode = @Q)
    GROUP BY i.ItemId, i.ItemCode, i.ItemName, i.PackSize, i.ScheduleCode, i.IsHighAlert, i.IsLasa, i.IsColdChain
    ORDER BY CASE WHEN i.ItemName LIKE @Q + N'%' THEN 0 ELSE 1 END, i.ItemName;
    -- the selling stores of the branch
    SELECT StoreId, StoreName, CAST(CASE WHEN StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL') THEN 1 ELSE 0 END AS BIT) AS IsDefault
    FROM dbo.PhStore WHERE BranchId = @BranchId AND dbo.fn_PhStoreOk(@BranchId, StoreId, 'SELL') = 1 ORDER BY StoreName;
END;
GO

-- ── issue: stock out (FEFO batches chosen on screen), IP bill charges, ledger at cost ─────────────────────────
-- @Lines JSON [{ItemId, BatchId, Qty}]
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPh_Issue
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Lines NVARCHAR(MAX), @Head VARCHAR(20) = 'PHARMACY',
    @StoreId INT = NULL, @DoctorId INT = NULL, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @open BIT, @status VARCHAR(20), @bill INT, @ip NVARCHAR(40);
        SELECT @open = IsOpen, @status = Status, @bill = BillId, @ip = IpNo FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 55101, 'The admission was not found in this branch.', 1;
        IF @open = 0 OR @bill IS NOT NULL OR @status NOT IN ('ADMITTED', 'DISCHARGE_ADVISED') THROW 55102, 'Medicines can be issued only to an admitted patient before the final bill.', 1;
        SET @Head = ISNULL(NULLIF(UPPER(@Head), ''), 'PHARMACY');
        IF @Head NOT IN ('PHARMACY', 'CONSUMABLE') THROW 55103, 'Choose medicine or consumable.', 1;
        IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0 SET @StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL');
        IF @StoreId IS NULL THROW 55104, 'This branch has no selling pharmacy store (Master > Pharmacy Master > Store / Godown).', 1;
        DECLARE @pt VARCHAR(20) = (SELECT PriceType FROM dbo.fn_Ipd_PhPriceType(@AdmissionId));
        DECLARE @exempt BIT = ISNULL((SELECT TOP 1 PharmacyIpdGstExempt FROM dbo.HospitalSettings WHERE BranchID = @BranchId ORDER BY IsActive DESC), 1);
        DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);

        DECLARE @L TABLE (Seq INT IDENTITY(1,1), ItemId INT, BatchId INT, Qty DECIMAL(14,3), UnitPrice DECIMAL(12,4), Gst DECIMAL(5,2), Cost DECIMAL(12,4),
                          ItemName NVARCHAR(250), ItemCode NVARCHAR(50), BatchNo NVARCHAR(50), Expiry DATE, Blocked BIT, LineId INT NULL);
        IF ISJSON(@Lines) = 1
            INSERT @L (ItemId, BatchId, Qty) SELECT j.ItemId, j.BatchId, j.Qty FROM OPENJSON(@Lines) WITH (ItemId INT, BatchId INT, Qty DECIMAL(14,3)) j;
        IF NOT EXISTS (SELECT 1 FROM @L) THROW 55105, 'Add at least one item.', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE ISNULL(Qty, 0) <= 0) THROW 55106, 'Every quantity must be more than zero.', 1;
        IF EXISTS (SELECT BatchId FROM @L GROUP BY BatchId HAVING COUNT(*) > 1) THROW 55107, 'The same batch is added twice: change the quantity instead.', 1;
        UPDATE l SET ItemName = i.ItemName, ItemCode = i.ItemCode, BatchNo = b.BatchNo, Expiry = b.ExpiryDate, Blocked = b.IsBlocked, Gst = b.GstPercent, Cost = b.LandedCost,   -- per sale unit, as the pharmacy sale takes it
               UnitPrice = pr.UnitPrice
        FROM @L l JOIN dbo.PhBatch b ON b.BatchId = l.BatchId AND b.ItemId = l.ItemId
        JOIN dbo.PhItem i ON i.ItemId = b.ItemId AND i.CompanyId = @CompanyId
        OUTER APPLY dbo.fn_PhSaleUnitPrice(@CompanyId, l.ItemId, l.BatchId, @pt) pr;
        IF EXISTS (SELECT 1 FROM @L WHERE ItemName IS NULL) THROW 55108, 'An item or batch was not found.', 1;
        SET @msg = (SELECT TOP 1 ItemName + N' batch ' + BatchNo FROM @L WHERE Blocked = 1 OR Expiry <= DATEADD(DAY, @shelf, CAST(@now AS DATE)));
        IF @msg IS NOT NULL BEGIN SET @msg = @msg + N' is blocked, expired or too near expiry: choose another batch.'; THROW 55109, @msg, 1; END
        IF EXISTS (SELECT 1 FROM @L WHERE ISNULL(UnitPrice, 0) <= 0) THROW 55110, 'An item has no price (batch MRP): it cannot be issued.', 1;
        IF @DoctorId IS NULL AND EXISTS (SELECT 1 FROM @L l JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.PhDrugSchedule sc ON sc.ScheduleCode = i.ScheduleCode AND sc.RegisterRequired = 1)
            THROW 55111, 'A scheduled drug (register) is issued: choose the prescribing doctor.', 1;

        DECLARE @no NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'IPI', @DocDate = @now, @DocNo = @no OUTPUT;
        INSERT dbo.IpdPhIssue (CompanyId, BranchId, AdmissionId, Kind, IssueNo, IssueAt, StoreId, Head, DoctorId, PriceType, Total, CostTotal, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @AdmissionId, 'ISSUE', @no, @now, @StoreId, @Head, @DoctorId, @pt, 0, 0, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
        DECLARE @issue INT = CAST(SCOPE_IDENTITY() AS INT);

        DECLARE @s INT = 1, @n INT = (SELECT COUNT(*) FROM @L), @item INT, @batch INT, @qty DECIMAL(14,3), @price DECIMAL(12,4), @g DECIMAL(5,2), @cost DECIMAL(12,4),
                @name NVARCHAR(250), @code NVARCHAR(50), @line INT, @amt DECIMAL(18,2), @rate DECIMAL(18,2), @gp DECIMAL(5,2), @cid BIGINT, @negQty DECIMAL(14,3);
        WHILE @s <= @n
        BEGIN
            SELECT @item = ItemId, @batch = BatchId, @qty = Qty, @price = UnitPrice, @g = Gst, @cost = Cost, @name = LEFT(ItemName + N' (' + BatchNo + N')', 250), @code = ItemCode
            FROM @L WHERE Seq = @s;
            SET @amt = ROUND(@qty * @price, 2);
            INSERT dbo.IpdPhIssueLine (IssueId, ItemId, BatchId, Qty, UnitPrice, GstPercent, Amount, UnitCost)
            VALUES (@issue, @item, @batch, @qty, @price, CASE WHEN @exempt = 1 THEN 0 ELSE @g END, @amt, ISNULL(@cost, 0));
            SET @line = CAST(SCOPE_IDENTITY() AS INT);
            SET @negQty = -@qty;
            EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @batch, @Qty = @negQty, @DocType = 'IPI', @DocId = @issue, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0, @StoreId = @StoreId;
            -- the IP bill: GST exempt = the price as it is; otherwise the price is split into taxable + GST
            SET @gp = CASE WHEN @exempt = 1 THEN 0 ELSE @g END;
            SET @rate = ROUND(@price / (1 + @gp / 100), 2);
            EXEC dbo.usp_Ipd_PostCharge @AdmissionId = @AdmissionId, @UserId = @UserId, @Head = @Head, @ItemCode = @code, @ItemName = @name, @SourceModule = 'PHR',
                 @SourceId = @line, @SourceNo = @no, @DoctorId = @DoctorId, @ChargeAt = @now, @Qty = @qty, @Rate = @rate, @Discount = 0, @GstPercent = @gp,
                 @MasterRate = @rate, @RefKind = 'PHR', @RefId = @issue, @ChargeId = @cid OUTPUT;
            UPDATE dbo.IpdPhIssueLine SET ChargeId = @cid WHERE LineId = @line;
            SET @s += 1;
        END
        DECLARE @total DECIMAL(18,2) = (SELECT SUM(Amount) FROM dbo.IpdPhIssueLine WHERE IssueId = @issue),
                @costTotal DECIMAL(18,2) = (SELECT ROUND(SUM(Qty * UnitCost), 2) FROM dbo.IpdPhIssueLine WHERE IssueId = @issue);
        UPDATE dbo.IpdPhIssue SET Total = @total, CostTotal = @costTotal WHERE IssueId = @issue;
        EXEC dbo.usp_Ipd_PostPharmacyLedger @IssueId = @issue, @UserId = @UserId;
        EXEC dbo.usp_Ipd_PhRegister @IssueId = @issue, @UserId = @UserId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT @AdmissionId, 'PH_ISSUE', LEFT(CONCAT(CASE WHEN @Head = 'CONSUMABLE' THEN N'Consumables issued ' ELSE N'Medicines issued ' END, @no, N' (₹', FORMAT(@total, 'N2', 'en-IN'), N'): ',
               STRING_AGG(CAST(CONCAT(ItemName, N' x ', FORMAT(Qty, '0.###')) AS NVARCHAR(MAX)), N', ')), 1000), @UserId FROM @L;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @issue AS IssueId, @no AS IssueNo, @total AS Total;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── ledger at cost: issue Dr COGS · Cr Inventory, return the reverse ────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostPharmacyLedger @IssueId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Inventory'),
            @cogs INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Pharmacy Cost of Goods Sold');
    IF @inv IS NULL OR @cogs IS NULL RETURN;   -- pharmacy ledgers not set up: stock only
    DECLARE @co INT, @br INT, @kind VARCHAR(10), @no NVARCHAR(40), @cost DECIMAL(18,2), @at DATETIME, @ip NVARCHAR(40), @party NVARCHAR(250);
    SELECT @co = s.CompanyId, @br = s.BranchId, @kind = s.Kind, @no = s.IssueNo, @cost = s.CostTotal, @at = s.IssueAt, @ip = a.IpNo,
           @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName)))
    FROM dbo.IpdPhIssue s JOIN dbo.IpdAdmission a ON a.AdmissionId = s.AdmissionId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId WHERE s.IssueId = @IssueId;
    IF ISNULL(@cost, 0) <= 0 RETURN;
    DECLARE @narr NVARCHAR(400) = CONCAT(CASE WHEN @kind = 'ISSUE' THEN N'IPD pharmacy issue ' ELSE N'IPD pharmacy return ' END, @no, N' - ', @ip, N' - ', @party, N' (at cost)');
    DECLARE @lines NVARCHAR(MAX) = CASE WHEN @kind = 'ISSUE'
        THEN (SELECT * FROM (VALUES (@cogs, @cost, 0, N'Cost of medicines issued to IPD'), (@inv, 0, @cost, N'Stock out at cost')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH)
        ELSE (SELECT * FROM (VALUES (@inv, @cost, 0, N'Stock back at cost'), (@cogs, 0, @cost, N'Medicines returned from IPD')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH) END;
    DECLARE @rt NVARCHAR(30) = CASE WHEN @kind = 'ISSUE' THEN 'IPD_PH_ISSUE' ELSE 'IPD_PH_RETURN' END, @tid BIGINT, @vno NVARCHAR(50);
    EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'JRN', @TransactionDate = @at, @CompanyId = @co, @BranchId = @br, @ReferenceType = @rt, @ReferenceId = @IssueId,
         @Narration = @narr, @PayeeName = @party, @PaymentMode = NULL, @InstrumentNo = NULL, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
         @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    UPDATE dbo.IpdPhIssue SET LedgerTxnId = @tid WHERE IssueId = @IssueId;
END;
GO

-- ── return of unused quantity (before the final bill) ─────────────────────────────────────────────────────────
-- @Lines JSON [{LineId, Qty}] (issue lines)
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPh_Return @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Lines NVARCHAR(MAX), @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 55121, 'Enter the reason for the return.', 1;
        DECLARE @open BIT, @status VARCHAR(20), @bill INT;
        SELECT @open = IsOpen, @status = Status, @bill = BillId FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 55122, 'The admission was not found in this branch.', 1;
        IF @open = 0 OR @bill IS NOT NULL THROW 55123, 'The final bill is made: cancel the bill to take a return.', 1;
        DECLARE @R TABLE (Seq INT IDENTITY(1,1), LineId INT, Qty DECIMAL(14,3), IssueId INT, Head VARCHAR(20), StoreId INT, ItemId INT, BatchId INT, UnitPrice DECIMAL(12,4),
                          Gst DECIMAL(5,2), Cost DECIMAL(12,4), Issued DECIMAL(14,3), Returned DECIMAL(14,3), ChargeId BIGINT, IsReturnable BIT, Name NVARCHAR(250), Code NVARCHAR(50), IssueNo NVARCHAR(40), DoctorId INT);
        IF ISJSON(@Lines) = 1
            INSERT @R (LineId, Qty) SELECT j.LineId, j.Qty FROM OPENJSON(@Lines) WITH (LineId INT, Qty DECIMAL(14,3)) j WHERE ISNULL(j.Qty, 0) > 0;
        IF NOT EXISTS (SELECT 1 FROM @R) THROW 55124, 'Enter the quantity to return.', 1;
        UPDATE r SET IssueId = l.IssueId, Head = s.Head, StoreId = s.StoreId, ItemId = l.ItemId, BatchId = l.BatchId, UnitPrice = l.UnitPrice, Gst = l.GstPercent, Cost = l.UnitCost,
               Issued = l.Qty, Returned = l.ReturnedQty, ChargeId = l.ChargeId, IsReturnable = i.IsReturnable, Name = LEFT(i.ItemName + N' (' + b.BatchNo + N')', 250), Code = i.ItemCode,
               IssueNo = s.IssueNo, DoctorId = s.DoctorId
        FROM @R r JOIN dbo.IpdPhIssueLine l WITH (UPDLOCK) ON l.LineId = r.LineId
        JOIN dbo.IpdPhIssue s ON s.IssueId = l.IssueId AND s.Kind = 'ISSUE' AND s.AdmissionId = @AdmissionId
        JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.PhBatch b ON b.BatchId = l.BatchId;
        IF EXISTS (SELECT 1 FROM @R WHERE IssueId IS NULL) THROW 55125, 'An issue line was not found on this admission.', 1;
        SET @msg = (SELECT TOP 1 Name FROM @R WHERE IsReturnable = 0);
        IF @msg IS NOT NULL BEGIN SET @msg = @msg + N' is not returnable (Pharmacy Item Master).'; THROW 55126, @msg, 1; END
        SET @msg = (SELECT TOP 1 CONCAT(Name, N': at most ', FORMAT(Issued - Returned, '0.###'), N' can be returned') FROM @R WHERE Qty > Issued - Returned);
        IF @msg IS NOT NULL THROW 55127, @msg, 1;

        DECLARE @no NVARCHAR(40), @store INT = (SELECT TOP 1 StoreId FROM @R), @head VARCHAR(20) = (SELECT TOP 1 Head FROM @R);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'IPR', @DocDate = @now, @DocNo = @no OUTPUT;
        INSERT dbo.IpdPhIssue (CompanyId, BranchId, AdmissionId, Kind, IssueNo, IssueAt, StoreId, Head, DoctorId, PriceType, Total, CostTotal, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @AdmissionId, 'RETURN', @no, @now, @store, @head, NULL, (SELECT PriceType FROM dbo.fn_Ipd_PhPriceType(@AdmissionId)), 0, 0, LTRIM(RTRIM(@Reason)), @UserId);
        DECLARE @ret INT = CAST(SCOPE_IDENTITY() AS INT);
        DECLARE @s INT = 1, @n INT = (SELECT COUNT(*) FROM @R), @line INT, @qty DECIMAL(14,3), @batch INT, @st INT, @cid BIGINT, @keep DECIMAL(14,3), @price DECIMAL(12,4),
                @gp DECIMAL(5,2), @rate DECIMAL(18,2), @name NVARCHAR(250), @code NVARCHAR(50), @h VARCHAR(20), @issueNo NVARCHAR(40), @doc INT, @issueId INT, @newCid BIGINT;
        WHILE @s <= @n
        BEGIN
            SELECT @line = LineId, @qty = Qty, @batch = BatchId, @st = StoreId, @cid = ChargeId, @keep = Issued - Returned - Qty, @price = UnitPrice, @gp = Gst, @name = Name, @code = Code,
                   @h = Head, @issueNo = IssueNo, @doc = DoctorId, @issueId = IssueId FROM @R WHERE Seq = @s;
            INSERT dbo.IpdPhIssueLine (IssueId, ItemId, BatchId, Qty, UnitPrice, GstPercent, Amount, UnitCost, IssueLineId)
            SELECT @ret, ItemId, BatchId, Qty, UnitPrice, Gst, ROUND(Qty * UnitPrice, 2), Cost, LineId FROM @R WHERE Seq = @s;
            EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @batch, @Qty = @qty, @DocType = 'IPR', @DocId = @ret, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0, @StoreId = @st;
            UPDATE dbo.IpdPhIssueLine SET ReturnedQty = ReturnedQty + @qty WHERE LineId = @line;
            -- the IP bill: the charge of the issue line is replaced by one for the quantity kept
            UPDATE dbo.IpdCharge SET Status = 'CANCELLED', CancelReason = LEFT(CONCAT(N'Return ', @no, N': ', LTRIM(RTRIM(@Reason))), 300), CancelledBy = @UserId, CancelledAt = @now
            WHERE ChargeId = @cid AND Status = 'POSTED';
            SET @newCid = NULL;
            IF @keep > 0
            BEGIN
                SET @rate = ROUND(@price / (1 + @gp / 100), 2);
                EXEC dbo.usp_Ipd_PostCharge @AdmissionId = @AdmissionId, @UserId = @UserId, @Head = @h, @ItemCode = @code, @ItemName = @name, @SourceModule = 'PHR',
                     @SourceId = @line, @SourceNo = @issueNo, @DoctorId = @doc, @ChargeAt = @now, @Qty = @keep, @Rate = @rate, @Discount = 0, @GstPercent = @gp,
                     @MasterRate = @rate, @RefKind = 'PHR', @RefId = @issueId, @ChargeId = @newCid OUTPUT;
            END
            UPDATE dbo.IpdPhIssueLine SET ChargeId = @newCid WHERE LineId = @line;
            SET @s += 1;
        END
        UPDATE dbo.IpdPhIssue SET Total = (SELECT SUM(Amount) FROM dbo.IpdPhIssueLine WHERE IssueId = @ret),
                                  CostTotal = (SELECT ROUND(SUM(Qty * UnitCost), 2) FROM dbo.IpdPhIssueLine WHERE IssueId = @ret) WHERE IssueId = @ret;
        EXEC dbo.usp_Ipd_PostPharmacyLedger @IssueId = @ret, @UserId = @UserId;
        EXEC dbo.usp_Ipd_PhRegister @IssueId = @ret, @UserId = @UserId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT @AdmissionId, 'PH_RETURN', LEFT(CONCAT(N'Pharmacy return ', @no, N': ', STRING_AGG(CAST(CONCAT(Name, N' x ', FORMAT(Qty, '0.###')) AS NVARCHAR(MAX)), N', '), N' - ', LTRIM(RTRIM(@Reason))), 1000), @UserId FROM @R;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @ret AS IssueId, @no AS IssueNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── issued items of an admission (line by line, with what was given back) ────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPh_List @CompanyId INT, @AdmissionId INT, @Head VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Head = NULLIF(@Head, '');
    SELECT s.IssueId, s.IssueNo, s.IssueAt, s.Head, st.StoreName, d.FullName AS DoctorName, u.FullName AS IssuedBy, s.Remarks,
           l.LineId, l.ItemId, i.ItemName, i.ItemCode, i.ScheduleCode, b.BatchNo, b.ExpiryDate, l.Qty, l.ReturnedQty, l.Qty - l.ReturnedQty AS KeptQty,
           l.UnitPrice, l.GstPercent, l.Amount, CAST(ROUND((l.Qty - l.ReturnedQty) * l.UnitPrice, 2) AS DECIMAL(18,2)) AS KeptAmount, i.IsReturnable,
           CAST(CASE WHEN a.BillId IS NULL AND a.IsOpen = 1 AND l.Qty - l.ReturnedQty > 0 AND i.IsReturnable = 1 THEN 1 ELSE 0 END AS BIT) AS CanReturn
    FROM dbo.IpdPhIssue s
    JOIN dbo.IpdAdmission a ON a.AdmissionId = s.AdmissionId AND a.CompanyId = @CompanyId
    JOIN dbo.IpdPhIssueLine l ON l.IssueId = s.IssueId
    JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.PhBatch b ON b.BatchId = l.BatchId
    LEFT JOIN dbo.PhStore st ON st.StoreId = s.StoreId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.DoctorId
    LEFT JOIN dbo.Users u ON u.Id = s.CreatedBy
    WHERE s.AdmissionId = @AdmissionId AND s.Kind = 'ISSUE' AND (@Head IS NULL OR s.Head = @Head)
    ORDER BY s.IssueAt DESC, s.IssueId DESC, l.LineId;
    -- returns
    SELECT s.IssueNo, s.IssueAt, s.Head, s.Remarks, u.FullName AS ReturnedBy, i.ItemName, b.BatchNo, l.Qty, l.Amount, src.IssueNo AS FromIssueNo
    FROM dbo.IpdPhIssue s
    JOIN dbo.IpdPhIssueLine l ON l.IssueId = s.IssueId
    JOIN dbo.IpdPhIssueLine ol ON ol.LineId = l.IssueLineId JOIN dbo.IpdPhIssue src ON src.IssueId = ol.IssueId
    JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.PhBatch b ON b.BatchId = l.BatchId
    LEFT JOIN dbo.Users u ON u.Id = s.CreatedBy
    WHERE s.AdmissionId = @AdmissionId AND s.Kind = 'RETURN' AND (@Head IS NULL OR s.Head = @Head)
    ORDER BY s.IssueAt DESC;
END;
GO

-- ── IPD Patient screen controls ──────────────────────────────────────────────────────────────────────────────
SET NOCOUNT ON;
DECLARE @pp INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT' AND CompanyId = 1), @pv INT, @ctl INT, @a NVARCHAR(60);
SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'VIEW';
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'PhItems,PhBatches,PhIssues', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdPharmacy', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
CLOSE v; DEALLOCATE v;
SET @ctl = NULL;
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @pp, @Control_Code = 'PH_ISSUE', @Title = N'Issue medicines / consumables (charged to the IP bill)', @Sort_Order = 88, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdPharmacy', @Action = N'Issue', @Source = 'SEED';
SET @ctl = NULL;
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @pp, @Control_Code = 'PH_RETURN', @Title = N'Take back unused medicines / consumables', @Sort_Order = 89, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdPharmacy', @Action = N'Return', @Source = 'SEED';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2437 IPD pharmacy issue - done.';
GO
