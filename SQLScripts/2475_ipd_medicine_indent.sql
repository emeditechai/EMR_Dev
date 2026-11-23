-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2475  IPD Medicine Indent (application database)
--   Ward    IPD Patient > Medicines tab: the ward raises a medicine INDENT (request) from the Pharmacy Item Master.
--           An indent does NOT touch stock or the IP bill.
--   Pharmacy  Pharmacy > Sales > IPD Issue (PHARMACY.IPDISSUE): dashboard of indents (header + lines). Per line the
--           pharmacist ISSUES batches (FEFO, through usp_Api_IpdPh_Issue: stock out, IP bill charge, ledger, schedule register
--           - exactly as the direct issue of 2437) and/or marks the rest NOT ISSUED with a reason (no stock, not stocked, ...).
--   Ward    every issued line is RECEIVED or NOT RECEIVED (reason) by the ward; a not-issued / not-received line can be
--           RE-INDENTED (a new indent, linked to the old line). Pending lines can be cancelled by the ward.
--   Pharmacy  a line the ward did not receive can be TAKEN BACK to stock (the charge is cancelled, as a return).
--   Consumables keep the direct issue of 2437 (unchanged).
--   Indent line status : PENDING  PARTIAL  ISSUED  NOT_ISSUED  SHORT_CLOSED (part issued, rest not)  CANCELLED
--   Indent status      : PENDING  PARTIAL  COMPLETED  CANCELLED
--   Issue line receive : PENDING  RECEIVED  NOT_RECEIVED  TAKEN_BACK  (NULL = direct issue, no indent)
--   Units: the ward asks in the pack (STRIP) or the sale unit (TAB) like the POS (loose only when the item allows it);
--   quantities are stored, issued, billed in sale units.
--   Needs 2437. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.IpdPhIndent', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdPhIndent
    (
        IndentId     INT IDENTITY(1,1) CONSTRAINT PK_IpdPhIndent PRIMARY KEY,
        CompanyId    INT            NOT NULL,
        BranchId     INT            NOT NULL,
        AdmissionId  INT            NOT NULL CONSTRAINT FK_IpdPhIndent_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        IndentNo     NVARCHAR(40)   NOT NULL,
        IndentAt     DATETIME       NOT NULL,
        StoreId      INT            NOT NULL,
        DoctorId     INT            NULL,
        Priority     VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdPhIndent_Priority DEFAULT ('ROUTINE'),
        Status       VARCHAR(15)    NOT NULL CONSTRAINT DF_IpdPhIndent_Status DEFAULT ('PENDING'),
        Remarks      NVARCHAR(300)  NULL,
        CreatedBy    INT            NULL,
        CreatedDate  DATETIME       NOT NULL CONSTRAINT DF_IpdPhIndent_Created DEFAULT (GETDATE()),
        ModifiedDate DATETIME       NULL,
        CONSTRAINT CK_IpdPhIndent_Priority CHECK (Priority IN ('ROUTINE', 'URGENT', 'STAT')),
        CONSTRAINT CK_IpdPhIndent_Status CHECK (Status IN ('PENDING', 'PARTIAL', 'COMPLETED', 'CANCELLED'))
    );
    CREATE INDEX IX_IpdPhIndent_Adm ON dbo.IpdPhIndent (AdmissionId, IndentAt);
    CREATE INDEX IX_IpdPhIndent_Board ON dbo.IpdPhIndent (BranchId, Status, IndentAt);
END
GO
IF OBJECT_ID('dbo.IpdPhIndentLine', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdPhIndentLine
    (
        LineId          INT IDENTITY(1,1) CONSTRAINT PK_IpdPhIndentLine PRIMARY KEY,
        IndentId        INT            NOT NULL CONSTRAINT FK_IpdPhIndentLine_Indent REFERENCES dbo.IpdPhIndent (IndentId),
        ItemId          INT            NOT NULL,
        ReqQty          DECIMAL(14,3)  NOT NULL,
        IssuedQty       DECIMAL(14,3)  NOT NULL CONSTRAINT DF_IpdPhIndentLine_Iss DEFAULT (0),
        NotIssuedQty    DECIMAL(14,3)  NOT NULL CONSTRAINT DF_IpdPhIndentLine_Not DEFAULT (0),
        Status          VARCHAR(15)    NOT NULL CONSTRAINT DF_IpdPhIndentLine_Status DEFAULT ('PENDING'),
        Remarks         NVARCHAR(300)  NULL,          -- ward: dose / instruction
        NotIssueReason  VARCHAR(20)    NULL,
        NotIssueRemarks NVARCHAR(300)  NULL,
        NotIssuedBy     INT            NULL,
        NotIssuedAt     DATETIME       NULL,
        CancelReason    NVARCHAR(300)  NULL,
        CancelledBy     INT            NULL,
        CancelledAt     DATETIME       NULL,
        ReIndentOfLineId      INT      NULL,          -- re-indent of a not-issued indent line
        ReIndentOfIssueLineId INT      NULL,          -- re-indent of an issue line the ward did not receive
        CONSTRAINT CK_IpdPhIndentLine_Qty CHECK (ReqQty > 0 AND IssuedQty >= 0 AND NotIssuedQty >= 0 AND IssuedQty + NotIssuedQty <= ReqQty),
        CONSTRAINT CK_IpdPhIndentLine_Status CHECK (Status IN ('PENDING', 'PARTIAL', 'ISSUED', 'NOT_ISSUED', 'SHORT_CLOSED', 'CANCELLED'))
    );
    CREATE INDEX IX_IpdPhIndentLine_Indent ON dbo.IpdPhIndentLine (IndentId);
END
GO
-- the unit the ward asked in (as POS: P = pack / purchase unit e.g. STRIP, U = sale unit e.g. TAB); ReqQty is always in sale units
IF COL_LENGTH('dbo.IpdPhIndentLine', 'QtyMode') IS NULL
    ALTER TABLE dbo.IpdPhIndentLine ADD QtyMode CHAR(1) NULL, QtyIn DECIMAL(14,3) NULL;
GO
IF COL_LENGTH('dbo.IpdPhIssue', 'IndentId') IS NULL
    ALTER TABLE dbo.IpdPhIssue ADD IndentId INT NULL;
GO
IF COL_LENGTH('dbo.IpdPhIssueLine', 'IndentLineId') IS NULL
    ALTER TABLE dbo.IpdPhIssueLine ADD IndentLineId INT NULL, ReceiveStatus VARCHAR(15) NULL, ReceivedBy INT NULL, ReceivedAt DATETIME NULL,
        ReceiveRemarks NVARCHAR(300) NULL, ResolvedBy INT NULL, ResolvedAt DATETIME NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdPhIssueLine_IndentLine')
    CREATE INDEX IX_IpdPhIssueLine_IndentLine ON dbo.IpdPhIssueLine (IndentLineId) WHERE IndentLineId IS NOT NULL;
GO

-- not-issue reasons (fixed list; OTHER needs remarks)
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PhNotIssueReason (@Code VARCHAR(20))
RETURNS NVARCHAR(60)
AS
BEGIN
    RETURN CASE @Code WHEN 'NO_STOCK' THEN N'Out of stock' WHEN 'NOT_STOCKED' THEN N'Not stocked / not available' WHEN 'SUBSTITUTE' THEN N'Substitute needed (ask the doctor)'
                      WHEN 'DOCTOR_STOPPED' THEN N'Stopped by the doctor' WHEN 'DUPLICATE' THEN N'Duplicate request' WHEN 'WARD_CANCELLED' THEN N'Cancelled by the ward'
                      WHEN 'OTHER' THEN N'Other' END;
END;
GO

-- line and header status from the quantities
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PhIndentRefresh @IndentId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.IpdPhIndentLine SET Status = CASE WHEN IssuedQty >= ReqQty THEN 'ISSUED'
                                                 WHEN IssuedQty + NotIssuedQty >= ReqQty AND IssuedQty > 0 THEN 'SHORT_CLOSED'
                                                 WHEN IssuedQty + NotIssuedQty >= ReqQty THEN 'NOT_ISSUED'
                                                 WHEN IssuedQty > 0 OR NotIssuedQty > 0 THEN 'PARTIAL' ELSE 'PENDING' END
    WHERE IndentId = @IndentId AND Status <> 'CANCELLED';
    UPDATE h SET Status = CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.IpdPhIndentLine l WHERE l.IndentId = h.IndentId AND l.Status <> 'CANCELLED') THEN 'CANCELLED'
                               WHEN NOT EXISTS (SELECT 1 FROM dbo.IpdPhIndentLine l WHERE l.IndentId = h.IndentId AND l.Status IN ('PENDING', 'PARTIAL')) THEN 'COMPLETED'
                               WHEN EXISTS (SELECT 1 FROM dbo.IpdPhIndentLine l WHERE l.IndentId = h.IndentId AND (l.IssuedQty > 0 OR l.NotIssuedQty > 0 OR l.Status = 'CANCELLED')) THEN 'PARTIAL'
                               ELSE 'PENDING' END,
                 ModifiedDate = GETDATE()
    FROM dbo.IpdPhIndent h WHERE h.IndentId = @IndentId;
END;
GO

-- ── issue (2437) + optional indent link: @Lines [{ItemId, BatchId, Qty, IndentLineId}], @IndentId, @Ok (for a caller procedure) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPh_Issue
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Lines NVARCHAR(MAX), @Head VARCHAR(20) = 'PHARMACY',
    @StoreId INT = NULL, @DoctorId INT = NULL, @Remarks NVARCHAR(300) = NULL, @IndentId INT = NULL, @Ok BIT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    SET @Ok = 0;
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
                          ItemName NVARCHAR(250), ItemCode NVARCHAR(50), BatchNo NVARCHAR(50), Expiry DATE, Blocked BIT, LineId INT NULL, IndentLineId INT NULL);
        IF ISJSON(@Lines) = 1
            INSERT @L (ItemId, BatchId, Qty, IndentLineId) SELECT j.ItemId, j.BatchId, j.Qty, j.IndentLineId FROM OPENJSON(@Lines) WITH (ItemId INT, BatchId INT, Qty DECIMAL(14,3), IndentLineId INT) j;
        IF NOT EXISTS (SELECT 1 FROM @L) THROW 55105, 'Add at least one item.', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE ISNULL(Qty, 0) <= 0) THROW 55106, 'Every quantity must be more than zero.', 1;
        IF EXISTS (SELECT BatchId FROM @L GROUP BY BatchId, ISNULL(IndentLineId, 0) HAVING COUNT(*) > 1) THROW 55107, 'The same batch is added twice: change the quantity instead.', 1;
        -- indent: every line belongs to the indent (same item, still open) and nothing is issued above what is asked
        IF @IndentId IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM @L l LEFT JOIN dbo.IpdPhIndentLine il WITH (UPDLOCK) ON il.LineId = l.IndentLineId AND il.IndentId = @IndentId AND il.ItemId = l.ItemId
                       WHERE il.LineId IS NULL OR il.Status IN ('ISSUED', 'NOT_ISSUED', 'SHORT_CLOSED', 'CANCELLED'))
                THROW 55141, 'An indent line was not found, does not match the item, or is already closed.', 1;
            SET @msg = (SELECT TOP 1 CONCAT(i.ItemName, N': at most ', FORMAT(il.ReqQty - il.IssuedQty - il.NotIssuedQty, '0.###'), N' can be issued on this indent')
                        FROM (SELECT IndentLineId, SUM(Qty) AS Qty FROM @L GROUP BY IndentLineId) x JOIN dbo.IpdPhIndentLine il ON il.LineId = x.IndentLineId
                        JOIN dbo.PhItem i ON i.ItemId = il.ItemId WHERE x.Qty > il.ReqQty - il.IssuedQty - il.NotIssuedQty);
            IF @msg IS NOT NULL THROW 55142, @msg, 1;
        END
        ELSE UPDATE @L SET IndentLineId = NULL;
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
        INSERT dbo.IpdPhIssue (CompanyId, BranchId, AdmissionId, Kind, IssueNo, IssueAt, StoreId, Head, DoctorId, PriceType, Total, CostTotal, Remarks, CreatedBy, IndentId)
        VALUES (@CompanyId, @BranchId, @AdmissionId, 'ISSUE', @no, @now, @StoreId, @Head, @DoctorId, @pt, 0, 0, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId, @IndentId);
        DECLARE @issue INT = CAST(SCOPE_IDENTITY() AS INT);

        DECLARE @s INT = 1, @n INT = (SELECT COUNT(*) FROM @L), @item INT, @batch INT, @qty DECIMAL(14,3), @price DECIMAL(12,4), @g DECIMAL(5,2), @cost DECIMAL(12,4),
                @name NVARCHAR(250), @code NVARCHAR(50), @line INT, @amt DECIMAL(18,2), @rate DECIMAL(18,2), @gp DECIMAL(5,2), @cid BIGINT, @negQty DECIMAL(14,3), @il INT;
        WHILE @s <= @n
        BEGIN
            SELECT @item = ItemId, @batch = BatchId, @qty = Qty, @price = UnitPrice, @g = Gst, @cost = Cost, @name = LEFT(ItemName + N' (' + BatchNo + N')', 250), @code = ItemCode,
                   @il = IndentLineId
            FROM @L WHERE Seq = @s;
            SET @amt = ROUND(@qty * @price, 2);
            INSERT dbo.IpdPhIssueLine (IssueId, ItemId, BatchId, Qty, UnitPrice, GstPercent, Amount, UnitCost, IndentLineId, ReceiveStatus)
            VALUES (@issue, @item, @batch, @qty, @price, CASE WHEN @exempt = 1 THEN 0 ELSE @g END, @amt, ISNULL(@cost, 0), @il, CASE WHEN @il IS NOT NULL THEN 'PENDING' END);
            SET @line = CAST(SCOPE_IDENTITY() AS INT);
            IF @il IS NOT NULL UPDATE dbo.IpdPhIndentLine SET IssuedQty = IssuedQty + @qty WHERE LineId = @il;
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
        IF @IndentId IS NOT NULL EXEC dbo.usp_Ipd_PhIndentRefresh @IndentId = @IndentId;
        DECLARE @total DECIMAL(18,2) = (SELECT SUM(Amount) FROM dbo.IpdPhIssueLine WHERE IssueId = @issue),
                @costTotal DECIMAL(18,2) = (SELECT ROUND(SUM(Qty * UnitCost), 2) FROM dbo.IpdPhIssueLine WHERE IssueId = @issue);
        UPDATE dbo.IpdPhIssue SET Total = @total, CostTotal = @costTotal WHERE IssueId = @issue;
        EXEC dbo.usp_Ipd_PostPharmacyLedger @IssueId = @issue, @UserId = @UserId;
        EXEC dbo.usp_Ipd_PhRegister @IssueId = @issue, @UserId = @UserId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT @AdmissionId, 'PH_ISSUE', LEFT(CONCAT(CASE WHEN @Head = 'CONSUMABLE' THEN N'Consumables issued ' ELSE N'Medicines issued ' END, @no,
               CASE WHEN @IndentId IS NOT NULL THEN N' against indent ' + (SELECT IndentNo FROM dbo.IpdPhIndent WHERE IndentId = @IndentId) ELSE N'' END,
               N' (₹', FORMAT(@total, 'N2', 'en-IN'), N'): ',
               STRING_AGG(CAST(CONCAT(ItemName, N' x ', FORMAT(Qty, '0.###')) AS NVARCHAR(MAX)), N', ')), 1000), @UserId FROM @L;
        IF @tc = 0 COMMIT;
        SET @Ok = 1;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @issue AS IssueId, @no AS IssueNo, @total AS Total;
    END TRY
    BEGIN CATCH
        SET @Ok = 0;
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── return (2437) + @IgnoreReturnable (pharmacy taking back what the ward never received) + @Ok ─────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPh_Return @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Lines NVARCHAR(MAX), @Reason NVARCHAR(300),
    @IgnoreReturnable BIT = 0, @Ok BIT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    SET @Ok = 0;
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
        SET @msg = (SELECT TOP 1 Name FROM @R WHERE IsReturnable = 0 AND ISNULL(@IgnoreReturnable, 0) = 0);
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
        SET @Ok = 1;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @ret AS IssueId, @no AS IssueNo;
    END TRY
    BEGIN CATCH
        SET @Ok = 0;
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── issued items of an admission (2437) + indent / receive columns at the end ─────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPh_List @CompanyId INT, @AdmissionId INT, @Head VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Head = NULLIF(@Head, '');
    SELECT s.IssueId, s.IssueNo, s.IssueAt, s.Head, st.StoreName, d.FullName AS DoctorName, u.FullName AS IssuedBy, s.Remarks,
           l.LineId, l.ItemId, i.ItemName, i.ItemCode, i.ScheduleCode, b.BatchNo, b.ExpiryDate, l.Qty, l.ReturnedQty, l.Qty - l.ReturnedQty AS KeptQty,
           l.UnitPrice, l.GstPercent, l.Amount, CAST(ROUND((l.Qty - l.ReturnedQty) * l.UnitPrice, 2) AS DECIMAL(18,2)) AS KeptAmount, i.IsReturnable,
           CAST(CASE WHEN a.BillId IS NULL AND a.IsOpen = 1 AND l.Qty - l.ReturnedQty > 0 AND i.IsReturnable = 1 AND ISNULL(l.ReceiveStatus, '') NOT IN ('NOT_RECEIVED', 'TAKEN_BACK') THEN 1 ELSE 0 END AS BIT) AS CanReturn,
           ind.IndentNo, l.IndentLineId, l.ReceiveStatus, ur.FullName AS ReceivedBy, l.ReceivedAt, l.ReceiveRemarks,
           CAST(CASE WHEN l.ReceiveStatus IN ('PENDING', 'NOT_RECEIVED') AND a.IsOpen = 1 AND l.Qty - l.ReturnedQty > 0 THEN 1 ELSE 0 END AS BIT) AS CanReceive,
           CAST(CASE WHEN l.ReceiveStatus IN ('NOT_RECEIVED', 'TAKEN_BACK') AND a.IsOpen = 1 AND a.BillId IS NULL
                      AND NOT EXISTS (SELECT 1 FROM dbo.IpdPhIndentLine r WHERE r.ReIndentOfIssueLineId = l.LineId AND r.Status <> 'CANCELLED') THEN 1 ELSE 0 END AS BIT) AS CanReIndent,
           (SELECT UomCode FROM dbo.PhUom WHERE UomId = i.SaleUomId) AS SaleUom
    FROM dbo.IpdPhIssue s
    JOIN dbo.IpdAdmission a ON a.AdmissionId = s.AdmissionId AND a.CompanyId = @CompanyId
    JOIN dbo.IpdPhIssueLine l ON l.IssueId = s.IssueId
    JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.PhBatch b ON b.BatchId = l.BatchId
    LEFT JOIN dbo.PhStore st ON st.StoreId = s.StoreId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.DoctorId
    LEFT JOIN dbo.Users u ON u.Id = s.CreatedBy
    LEFT JOIN dbo.Users ur ON ur.Id = l.ReceivedBy
    LEFT JOIN dbo.IpdPhIndent ind ON ind.IndentId = s.IndentId
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

-- ── ward: items to indent (all active items of the Pharmacy Item Master; stock of the store shown, not required) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPhIndent_Items @CompanyId INT, @BranchId INT, @Q NVARCHAR(100) = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0 SET @StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL');
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Q + N'%';
    DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
    IF @Q IS NOT NULL
        SELECT TOP (30) i.ItemId, i.ItemCode, i.ItemName, i.PackSize, i.ScheduleCode, i.IsHighAlert, i.IsLasa, i.IsColdChain,
               ISNULL(st.Stock, 0) AS Stock, @StoreId AS StoreId, su.UomCode AS SaleUom, pu.UomCode AS PurchaseUom, i.ConversionQty, i.AllowLooseSale
        FROM dbo.PhItem i
        LEFT JOIN dbo.PhUom su ON su.UomId = i.SaleUomId LEFT JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
        OUTER APPLY (SELECT SUM(s.QtyOnHand) AS Stock FROM dbo.PhStoreStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId AND b.IsBlocked = 0
                     AND b.ExpiryDate > DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE)) WHERE s.ItemId = i.ItemId AND s.StoreId = @StoreId AND s.QtyOnHand > 0) st
        WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 AND (i.ItemName LIKE @like OR i.ItemCode LIKE @like OR i.Barcode = @Q)
        ORDER BY CASE WHEN i.ItemName LIKE @Q + N'%' THEN 0 ELSE 1 END, i.ItemName;
    ELSE
        SELECT TOP (0) CAST(NULL AS INT) AS ItemId;
    SELECT StoreId, StoreName, CAST(CASE WHEN StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL') THEN 1 ELSE 0 END AS BIT) AS IsDefault
    FROM dbo.PhStore WHERE BranchId = @BranchId AND dbo.fn_PhStoreOk(@BranchId, StoreId, 'SELL') = 1 ORDER BY StoreName;
END;
GO

-- ── ward: raise an indent (no stock, no bill) - also a re-indent of a not-issued / not-received line ──────────────
-- @Lines JSON [{ItemId, Qty, Remarks, ReIndentOfLineId, ReIndentOfIssueLineId}]
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPhIndent_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Lines NVARCHAR(MAX), @StoreId INT = NULL, @DoctorId INT = NULL,
    @Priority VARCHAR(10) = 'ROUTINE', @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @open BIT, @status VARCHAR(20), @bill INT;
        SELECT @open = IsOpen, @status = Status, @bill = BillId FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 55151, 'The admission was not found in this branch.', 1;
        IF @open = 0 OR @bill IS NOT NULL OR @status NOT IN ('ADMITTED', 'DISCHARGE_ADVISED') THROW 55152, 'An indent can be raised only for an admitted patient before the final bill.', 1;
        SET @Priority = ISNULL(NULLIF(UPPER(@Priority), ''), 'ROUTINE');
        IF @Priority NOT IN ('ROUTINE', 'URGENT', 'STAT') THROW 55153, 'Choose the priority: routine, urgent or stat.', 1;
        IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0 SET @StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL');
        IF @StoreId IS NULL THROW 55154, 'This branch has no selling pharmacy store (Master > Pharmacy Master > Store / Godown).', 1;

        -- Qty = quantity in the chosen unit (Mode P = pack, U = sale unit; no Mode = sale units)
        DECLARE @L TABLE (Seq INT IDENTITY(1,1), ItemId INT, QtyIn DECIMAL(14,3), Mode CHAR(1), Qty DECIMAL(14,3), Remarks NVARCHAR(300), ReLine INT, ReIssueLine INT, ItemName NVARCHAR(250),
                          Conv DECIMAL(14,3), Loose BIT);
        IF ISJSON(@Lines) = 1
            INSERT @L (ItemId, QtyIn, Mode, Remarks, ReLine, ReIssueLine)
            SELECT j.ItemId, j.Qty, UPPER(NULLIF(j.Mode, '')), NULLIF(LTRIM(RTRIM(j.Remarks)), N''), j.ReIndentOfLineId, j.ReIndentOfIssueLineId
            FROM OPENJSON(@Lines) WITH (ItemId INT, Qty DECIMAL(14,3), Mode VARCHAR(1), Remarks NVARCHAR(300), ReIndentOfLineId INT, ReIndentOfIssueLineId INT) j;
        IF NOT EXISTS (SELECT 1 FROM @L) THROW 55155, 'Add at least one medicine.', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE ISNULL(QtyIn, 0) <= 0) THROW 55156, 'Every quantity must be more than zero.', 1;
        IF EXISTS (SELECT ItemId FROM @L GROUP BY ItemId HAVING COUNT(*) > 1) THROW 55157, 'The same medicine is added twice: change the quantity instead.', 1;
        UPDATE l SET ItemName = i.ItemName, Conv = CASE WHEN ISNULL(i.ConversionQty, 0) > 1 THEN i.ConversionQty ELSE 1 END, Loose = ISNULL(i.AllowLooseSale, 0)
        FROM @L l JOIN dbo.PhItem i ON i.ItemId = l.ItemId AND i.CompanyId = @CompanyId AND i.IsActive = 1;
        IF EXISTS (SELECT 1 FROM @L WHERE ItemName IS NULL) THROW 55158, 'A medicine was not found or is inactive in the Pharmacy Item Master.', 1;
        UPDATE @L SET Mode = CASE WHEN Conv <= 1 THEN 'U' WHEN Mode IN ('P', 'U') THEN Mode ELSE 'U' END;
        SET @msg = (SELECT TOP 1 ItemName FROM @L WHERE Mode = 'U' AND Conv > 1 AND Loose = 0 AND QtyIn % Conv <> 0);
        IF @msg IS NOT NULL BEGIN SET @msg = @msg + N' is not sold loose (Pharmacy Item Master): ask in whole packs.'; THROW 55162, @msg, 1; END
        UPDATE @L SET Qty = CASE WHEN Mode = 'P' THEN QtyIn * Conv ELSE QtyIn END;
        -- re-indent: the source line is of this admission, for the same item, closed without (full) supply, and not re-indented already
        IF EXISTS (SELECT 1 FROM @L l LEFT JOIN dbo.IpdPhIndentLine o ON o.LineId = l.ReLine AND o.ItemId = l.ItemId AND o.Status IN ('NOT_ISSUED', 'SHORT_CLOSED')
                   LEFT JOIN dbo.IpdPhIndent oh ON oh.IndentId = o.IndentId AND oh.AdmissionId = @AdmissionId
                   WHERE l.ReLine IS NOT NULL AND oh.IndentId IS NULL)
            THROW 55159, 'Only a not-issued line of this patient can be re-indented.', 1;
        IF EXISTS (SELECT 1 FROM @L l LEFT JOIN dbo.IpdPhIssueLine o ON o.LineId = l.ReIssueLine AND o.ItemId = l.ItemId AND o.ReceiveStatus IN ('NOT_RECEIVED', 'TAKEN_BACK')
                   LEFT JOIN dbo.IpdPhIssue os ON os.IssueId = o.IssueId AND os.AdmissionId = @AdmissionId
                   WHERE l.ReIssueLine IS NOT NULL AND os.IssueId IS NULL)
            THROW 55160, 'Only an issued line the ward did not receive can be re-indented.', 1;
        IF EXISTS (SELECT 1 FROM @L l JOIN dbo.IpdPhIndentLine r WITH (UPDLOCK) ON r.Status <> 'CANCELLED'
                   AND ((l.ReLine IS NOT NULL AND r.ReIndentOfLineId = l.ReLine) OR (l.ReIssueLine IS NOT NULL AND r.ReIndentOfIssueLineId = l.ReIssueLine)))
            THROW 55161, 'This line is already re-indented.', 1;

        DECLARE @no NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'IND', @DocDate = @now, @DocNo = @no OUTPUT;
        INSERT dbo.IpdPhIndent (CompanyId, BranchId, AdmissionId, IndentNo, IndentAt, StoreId, DoctorId, Priority, Status, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @AdmissionId, @no, @now, @StoreId, @DoctorId, @Priority, 'PENDING', NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
        DECLARE @id INT = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.IpdPhIndentLine (IndentId, ItemId, ReqQty, QtyMode, QtyIn, Remarks, ReIndentOfLineId, ReIndentOfIssueLineId)
        SELECT @id, ItemId, Qty, Mode, QtyIn, Remarks, ReLine, ReIssueLine FROM @L ORDER BY Seq;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT @AdmissionId, 'PH_INDENT', LEFT(CONCAT(CASE WHEN MAX(ISNULL(ReLine, ReIssueLine)) IS NOT NULL THEN N'Medicine re-indent ' ELSE N'Medicine indent ' END, @no,
               CASE WHEN @Priority <> 'ROUTINE' THEN N' (' + @Priority + N')' ELSE N'' END, N': ',
               STRING_AGG(CAST(CONCAT(ItemName, N' x ', FORMAT(QtyIn, '0.###'), CASE WHEN Mode = 'P' THEN N' pack' ELSE N'' END) AS NVARCHAR(MAX)), N', ')), 1000), @UserId FROM @L;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS IndentId, @no AS IndentNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── ward: cancel what is still open on an indent (a whole indent, or one line) ──────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPhIndent_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @IndentId INT, @LineId INT = NULL, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
        IF @Reason IS NULL THROW 55171, 'Enter the reason for cancelling.', 1;
        DECLARE @no NVARCHAR(40);
        SELECT @no = IndentNo FROM dbo.IpdPhIndent WITH (UPDLOCK) WHERE IndentId = @IndentId AND AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @no IS NULL THROW 55172, 'The indent was not found on this admission.', 1;
        DECLARE @names NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(i.ItemName AS NVARCHAR(MAX)), N', ') FROM dbo.IpdPhIndentLine l JOIN dbo.PhItem i ON i.ItemId = l.ItemId
                                         WHERE l.IndentId = @IndentId AND (@LineId IS NULL OR l.LineId = @LineId) AND l.Status IN ('PENDING', 'PARTIAL'));
        IF @names IS NULL THROW 55173, 'Nothing is open on this indent: issued or closed lines cannot be cancelled.', 1;
        -- nothing issued yet: the line is cancelled; part issued: the rest is closed as not issued (cancelled by the ward)
        UPDATE dbo.IpdPhIndentLine SET Status = 'CANCELLED', CancelReason = @Reason, CancelledBy = @UserId, CancelledAt = @now
        WHERE IndentId = @IndentId AND (@LineId IS NULL OR LineId = @LineId) AND Status = 'PENDING' AND IssuedQty = 0 AND NotIssuedQty = 0;
        UPDATE dbo.IpdPhIndentLine SET NotIssuedQty = ReqQty - IssuedQty, NotIssueReason = 'WARD_CANCELLED', NotIssueRemarks = @Reason, NotIssuedBy = @UserId, NotIssuedAt = @now
        WHERE IndentId = @IndentId AND (@LineId IS NULL OR LineId = @LineId) AND Status IN ('PENDING', 'PARTIAL');
        EXEC dbo.usp_Ipd_PhIndentRefresh @IndentId = @IndentId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'PH_INDENT_CANCEL', LEFT(CONCAT(N'Indent ', @no, N' cancelled: ', @names, N' - ', @Reason), 1000), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @IndentId AS IndentId, @no AS IndentNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── ward: indents of an admission (one row per line) ──────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPhIndent_List @CompanyId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.IndentId, h.IndentNo, h.IndentAt, h.Priority, h.Status AS IndentStatus, h.Remarks AS IndentRemarks, st.StoreName, d.FullName AS DoctorName, u.FullName AS RaisedBy,
           l.LineId, l.ItemId, i.ItemName, i.ItemCode, i.ScheduleCode, l.ReqQty, l.IssuedQty, l.NotIssuedQty, l.ReqQty - l.IssuedQty - l.NotIssuedQty AS OpenQty,
           l.Status, l.Remarks, l.NotIssueReason, dbo.fn_Ipd_PhNotIssueReason(l.NotIssueReason) AS NotIssueReasonText, l.NotIssueRemarks, un.FullName AS NotIssuedBy, l.NotIssuedAt,
           l.CancelReason, l.CancelledAt, ro.IndentNo AS ReIndentOfNo,
           l.QtyMode, l.QtyIn, su.UomCode AS SaleUom, pu.UomCode AS PurchaseUom, i.ConversionQty, i.AllowLooseSale,
           CAST(CASE WHEN l.Status IN ('PENDING', 'PARTIAL') AND a.IsOpen = 1 THEN 1 ELSE 0 END AS BIT) AS CanCancel,
           CAST(CASE WHEN l.Status IN ('NOT_ISSUED', 'SHORT_CLOSED') AND a.IsOpen = 1 AND a.BillId IS NULL
                      AND NOT EXISTS (SELECT 1 FROM dbo.IpdPhIndentLine r WHERE r.ReIndentOfLineId = l.LineId AND r.Status <> 'CANCELLED') THEN 1 ELSE 0 END AS BIT) AS CanReIndent
    FROM dbo.IpdPhIndent h
    JOIN dbo.IpdAdmission a ON a.AdmissionId = h.AdmissionId AND a.CompanyId = @CompanyId
    JOIN dbo.IpdPhIndentLine l ON l.IndentId = h.IndentId
    JOIN dbo.PhItem i ON i.ItemId = l.ItemId
    LEFT JOIN dbo.PhStore st ON st.StoreId = h.StoreId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = h.DoctorId
    LEFT JOIN dbo.Users u ON u.Id = h.CreatedBy
    LEFT JOIN dbo.Users un ON un.Id = l.NotIssuedBy
    LEFT JOIN dbo.IpdPhIndentLine rl ON rl.LineId = l.ReIndentOfLineId LEFT JOIN dbo.IpdPhIndent ro ON ro.IndentId = rl.IndentId
    LEFT JOIN dbo.PhUom su ON su.UomId = i.SaleUomId LEFT JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
    WHERE h.AdmissionId = @AdmissionId
    ORDER BY h.IndentAt DESC, h.IndentId DESC, l.LineId;
END;
GO

-- ── ward: receive issued lines (RECEIVED, or NOT_RECEIVED with a reason) ─────────────────────────────────────────
-- @Lines JSON [{LineId, Received, Remarks}] (issue lines)
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPhIndent_Receive @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId)
            THROW 55181, 'The admission was not found in this branch.', 1;
        DECLARE @R TABLE (LineId INT, Received BIT, Remarks NVARCHAR(300), Ok BIT, Name NVARCHAR(250), Cur VARCHAR(15));
        IF ISJSON(@Lines) = 1
            INSERT @R (LineId, Received, Remarks) SELECT j.LineId, ISNULL(j.Received, 1), NULLIF(LTRIM(RTRIM(j.Remarks)), N'') FROM OPENJSON(@Lines) WITH (LineId INT, Received BIT, Remarks NVARCHAR(300)) j;
        IF NOT EXISTS (SELECT 1 FROM @R) THROW 55182, 'Choose the items received.', 1;
        UPDATE r SET Ok = 1, Name = i.ItemName, Cur = l.ReceiveStatus
        FROM @R r JOIN dbo.IpdPhIssueLine l WITH (UPDLOCK) ON l.LineId = r.LineId
        JOIN dbo.IpdPhIssue s ON s.IssueId = l.IssueId AND s.Kind = 'ISSUE' AND s.AdmissionId = @AdmissionId
        JOIN dbo.PhItem i ON i.ItemId = l.ItemId;
        IF EXISTS (SELECT 1 FROM @R WHERE Ok IS NULL) THROW 55183, 'An issued line was not found on this admission.', 1;
        IF EXISTS (SELECT 1 FROM @R WHERE ISNULL(Cur, '') NOT IN ('PENDING', 'NOT_RECEIVED') OR (Cur = 'NOT_RECEIVED' AND Received = 0))
            THROW 55184, 'Only an issued line still waiting to be received (or marked not received) can be updated.', 1;
        IF EXISTS (SELECT 1 FROM @R WHERE Received = 0 AND Remarks IS NULL) THROW 55185, 'Enter the reason for every item not received.', 1;
        UPDATE l SET ReceiveStatus = CASE WHEN r.Received = 1 THEN 'RECEIVED' ELSE 'NOT_RECEIVED' END, ReceivedBy = @UserId, ReceivedAt = @now, ReceiveRemarks = r.Remarks
        FROM dbo.IpdPhIssueLine l JOIN @R r ON r.LineId = l.LineId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT @AdmissionId, CASE WHEN Received = 1 THEN 'PH_RECEIVE' ELSE 'PH_NOT_RECEIVED' END,
               LEFT(CONCAT(CASE WHEN Received = 1 THEN N'Medicines received on the ward: ' ELSE N'Medicines NOT received on the ward: ' END,
               STRING_AGG(CAST(CONCAT(Name, CASE WHEN Remarks IS NOT NULL THEN N' (' + Remarks + N')' END) AS NVARCHAR(MAX)), N', ')), 1000), @UserId
        FROM @R GROUP BY Received;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, (SELECT COUNT(*) FROM @R) AS Lines;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── pharmacy: IPD Issue dashboard ───────────────────────────────────────────────────────────────────────────────
-- @Status OPEN (pending + partial, default) | PENDING | PARTIAL | COMPLETED | CANCELLED | NOT_RECEIVED | ALL
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPhIndent_Board @CompanyId INT, @BranchId INT, @Status VARCHAR(15) = 'OPEN', @StoreId INT = NULL, @Q NVARCHAR(100) = NULL,
    @From DATE = NULL, @To DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Status = ISNULL(NULLIF(UPPER(@Status), ''), 'OPEN');
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Q + N'%', @today DATE = CAST(GETDATE() AS DATE);
    -- tiles (whole branch, today's figures where it says so)
    SELECT SUM(CASE WHEN h.Status = 'PENDING' THEN 1 ELSE 0 END) AS Pending,
           SUM(CASE WHEN h.Status = 'PARTIAL' THEN 1 ELSE 0 END) AS Partial,
           SUM(CASE WHEN h.Status IN ('PENDING', 'PARTIAL') AND h.Priority IN ('URGENT', 'STAT') THEN 1 ELSE 0 END) AS UrgentOpen,
           SUM(CASE WHEN h.Status = 'COMPLETED' AND CAST(ISNULL(h.ModifiedDate, h.IndentAt) AS DATE) = @today THEN 1 ELSE 0 END) AS CompletedToday,
           (SELECT COUNT(*) FROM dbo.IpdPhIssueLine l JOIN dbo.IpdPhIssue s ON s.IssueId = l.IssueId WHERE s.BranchId = @BranchId AND l.ReceiveStatus = 'NOT_RECEIVED') AS NotReceived,
           (SELECT COUNT(*) FROM dbo.IpdPhIndentLine l JOIN dbo.IpdPhIndent x ON x.IndentId = l.IndentId
             WHERE x.BranchId = @BranchId AND l.Status IN ('NOT_ISSUED', 'SHORT_CLOSED') AND CAST(l.NotIssuedAt AS DATE) = @today) AS NotIssuedToday
    FROM dbo.IpdPhIndent h WHERE h.BranchId = @BranchId AND h.CompanyId = @CompanyId;

    SELECT TOP (300) h.IndentId, h.IndentNo, h.IndentAt, h.Priority, h.Status, h.Remarks, st.StoreName, d.FullName AS DoctorName, u.FullName AS RaisedBy,
           a.AdmissionId, a.IpNo, a.Status AS AdmissionStatus, a.IsOpen, CAST(CASE WHEN a.BillId IS NULL THEN 0 ELSE 1 END AS BIT) AS Billed,
           LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName))) AS PatientName, p.PatientCode, b.BedNumber, w.WardName,
           x.Lines, x.OpenLines, x.IssuedLines, x.NotIssuedLines, x.CancelledLines, ISNULL(nr.NotReceived, 0) AS NotReceived
    FROM dbo.IpdPhIndent h
    JOIN dbo.IpdAdmission a ON a.AdmissionId = h.AdmissionId
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.PhStore st ON st.StoreId = h.StoreId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = h.DoctorId
    LEFT JOIN dbo.Users u ON u.Id = h.CreatedBy
    CROSS APPLY (SELECT COUNT(*) AS Lines, SUM(CASE WHEN l.Status IN ('PENDING', 'PARTIAL') THEN 1 ELSE 0 END) AS OpenLines,
                        SUM(CASE WHEN l.Status = 'ISSUED' THEN 1 ELSE 0 END) AS IssuedLines, SUM(CASE WHEN l.Status IN ('NOT_ISSUED', 'SHORT_CLOSED') THEN 1 ELSE 0 END) AS NotIssuedLines,
                        SUM(CASE WHEN l.Status = 'CANCELLED' THEN 1 ELSE 0 END) AS CancelledLines
                 FROM dbo.IpdPhIndentLine l WHERE l.IndentId = h.IndentId) x
    OUTER APPLY (SELECT COUNT(*) AS NotReceived FROM dbo.IpdPhIssueLine l JOIN dbo.IpdPhIssue s ON s.IssueId = l.IssueId WHERE s.IndentId = h.IndentId AND l.ReceiveStatus = 'NOT_RECEIVED') nr
    WHERE h.CompanyId = @CompanyId AND h.BranchId = @BranchId
      AND (@StoreId IS NULL OR h.StoreId = @StoreId)
      AND (   (@Status = 'OPEN' AND h.Status IN ('PENDING', 'PARTIAL'))
           OR (@Status = 'NOT_RECEIVED' AND ISNULL(nr.NotReceived, 0) > 0)
           OR (@Status = 'ALL')
           OR (h.Status = @Status))
      AND (@From IS NULL OR CAST(h.IndentAt AS DATE) >= @From) AND (@To IS NULL OR CAST(h.IndentAt AS DATE) <= @To)
      AND (@Q IS NULL OR h.IndentNo LIKE @like OR a.IpNo LIKE @like OR p.PatientCode LIKE @like OR p.FirstName LIKE @like OR p.LastName LIKE @like
           OR CONCAT(p.FirstName, ' ', p.LastName) LIKE @like OR b.BedNumber LIKE @like OR w.WardName LIKE @like)
    ORDER BY CASE WHEN h.Status IN ('PENDING', 'PARTIAL') THEN 0 ELSE 1 END, CASE h.Priority WHEN 'STAT' THEN 0 WHEN 'URGENT' THEN 1 ELSE 2 END,
             CASE WHEN h.Status IN ('PENDING', 'PARTIAL') THEN h.IndentAt END ASC, h.IndentAt DESC;
END;
GO

-- ── pharmacy: one indent (header, lines with stock in the indent store, issues made against it) ─────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPhIndent_Get @CompanyId INT, @BranchId INT, @IndentId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @store INT = (SELECT StoreId FROM dbo.IpdPhIndent WHERE IndentId = @IndentId AND CompanyId = @CompanyId AND BranchId = @BranchId);
    DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
    SELECT h.IndentId, h.IndentNo, h.IndentAt, h.Priority, h.Status, h.Remarks, h.StoreId, st.StoreName, h.DoctorId, d.FullName AS DoctorName, u.FullName AS RaisedBy,
           a.AdmissionId, a.IpNo, a.Status AS AdmissionStatus, a.IsOpen, CAST(CASE WHEN a.BillId IS NULL THEN 0 ELSE 1 END AS BIT) AS Billed, a.PayerType,
           LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName))) AS PatientName, p.PatientCode, p.Gender, dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(GETDATE() AS DATE)) AS AgeText,
           b.BedNumber, w.WardName, dc.FullName AS ConsultantName,
           CAST(CASE WHEN a.IsOpen = 1 AND a.BillId IS NULL AND a.Status IN ('ADMITTED', 'DISCHARGE_ADVISED') THEN 1 ELSE 0 END AS BIT) AS CanIssue
    FROM dbo.IpdPhIndent h
    JOIN dbo.IpdAdmission a ON a.AdmissionId = h.AdmissionId
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.PhStore st ON st.StoreId = h.StoreId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = h.DoctorId
    LEFT JOIN dbo.DoctorMaster dc ON dc.DoctorId = a.ConsultantDoctorId
    LEFT JOIN dbo.Users u ON u.Id = h.CreatedBy
    WHERE h.IndentId = @IndentId AND h.CompanyId = @CompanyId AND h.BranchId = @BranchId;

    SELECT l.LineId, l.ItemId, i.ItemName, i.ItemCode, i.PackSize, i.ScheduleCode, i.IsHighAlert, i.IsLasa, i.IsColdChain,
           l.ReqQty, l.IssuedQty, l.NotIssuedQty, l.ReqQty - l.IssuedQty - l.NotIssuedQty AS OpenQty, l.Status, l.Remarks,
           l.NotIssueReason, dbo.fn_Ipd_PhNotIssueReason(l.NotIssueReason) AS NotIssueReasonText, l.NotIssueRemarks, un.FullName AS NotIssuedBy, l.NotIssuedAt,
           l.CancelReason, ISNULL(sk.Stock, 0) AS Stock, ro.IndentNo AS ReIndentOfNo,
           l.QtyMode, l.QtyIn, su.UomCode AS SaleUom, pu.UomCode AS PurchaseUom, i.ConversionQty
    FROM dbo.IpdPhIndentLine l
    JOIN dbo.PhItem i ON i.ItemId = l.ItemId
    LEFT JOIN dbo.PhUom su ON su.UomId = i.SaleUomId LEFT JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
    LEFT JOIN dbo.Users un ON un.Id = l.NotIssuedBy
    LEFT JOIN dbo.IpdPhIndentLine rl ON rl.LineId = l.ReIndentOfLineId LEFT JOIN dbo.IpdPhIndent ro ON ro.IndentId = rl.IndentId
    OUTER APPLY (SELECT SUM(s.QtyOnHand) AS Stock FROM dbo.PhStoreStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId AND b.IsBlocked = 0
                 AND b.ExpiryDate > DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE)) WHERE s.ItemId = l.ItemId AND s.StoreId = @store AND s.QtyOnHand > 0) sk
    WHERE l.IndentId = @IndentId AND @store IS NOT NULL
    ORDER BY l.LineId;

    SELECT s.IssueId, s.IssueNo, s.IssueAt, uu.FullName AS IssuedBy, l.LineId, l.IndentLineId, i.ItemName, bt.BatchNo, bt.ExpiryDate, l.Qty, l.ReturnedQty, l.UnitPrice,
           l.Amount, l.ReceiveStatus, ur.FullName AS ReceivedBy, l.ReceivedAt, l.ReceiveRemarks,
           CAST(CASE WHEN l.ReceiveStatus = 'NOT_RECEIVED' AND a.IsOpen = 1 AND a.BillId IS NULL AND l.Qty - l.ReturnedQty > 0 THEN 1 ELSE 0 END AS BIT) AS CanTakeBack
    FROM dbo.IpdPhIssue s
    JOIN dbo.IpdAdmission a ON a.AdmissionId = s.AdmissionId
    JOIN dbo.IpdPhIssueLine l ON l.IssueId = s.IssueId
    JOIN dbo.PhItem i ON i.ItemId = l.ItemId JOIN dbo.PhBatch bt ON bt.BatchId = l.BatchId
    LEFT JOIN dbo.Users uu ON uu.Id = s.CreatedBy LEFT JOIN dbo.Users ur ON ur.Id = l.ReceivedBy
    WHERE s.IndentId = @IndentId AND s.Kind = 'ISSUE' AND @store IS NOT NULL
    ORDER BY s.IssueAt, l.LineId;
END;
GO

-- ── pharmacy: issue and / or mark not issued, in one step ────────────────────────────────────────────────────────
-- @Issue    [{IndentLineId, BatchId, Qty}]  stock out from @StoreId (FEFO batches chosen on screen), charged to the IP bill
-- @NotIssue [{IndentLineId, Reason, Remarks}] the rest of the line (after this issue) is closed as not issued
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPhIndent_Process
    @CompanyId INT, @BranchId INT, @UserId INT, @IndentId INT, @Issue NVARCHAR(MAX) = NULL, @NotIssue NVARCHAR(MAX) = NULL, @StoreId INT = NULL, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ind_sp;
        DECLARE @adm INT, @no NVARCHAR(40), @hs VARCHAR(15), @doc INT, @store INT;
        SELECT @adm = AdmissionId, @no = IndentNo, @hs = Status, @doc = DoctorId, @store = StoreId FROM dbo.IpdPhIndent WITH (UPDLOCK)
        WHERE IndentId = @IndentId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @adm IS NULL THROW 55191, 'The indent was not found in this branch.', 1;
        IF @hs IN ('COMPLETED', 'CANCELLED') THROW 55192, 'The indent is already closed.', 1;

        DECLARE @I TABLE (IndentLineId INT, BatchId INT, Qty DECIMAL(14,3));
        DECLARE @N TABLE (IndentLineId INT, Reason VARCHAR(20), Remarks NVARCHAR(300));
        IF ISJSON(@Issue) = 1 INSERT @I SELECT j.IndentLineId, j.BatchId, j.Qty FROM OPENJSON(@Issue) WITH (IndentLineId INT, BatchId INT, Qty DECIMAL(14,3)) j WHERE ISNULL(j.Qty, 0) > 0;
        IF ISJSON(@NotIssue) = 1 INSERT @N SELECT j.IndentLineId, UPPER(j.Reason), NULLIF(LTRIM(RTRIM(j.Remarks)), N'') FROM OPENJSON(@NotIssue) WITH (IndentLineId INT, Reason VARCHAR(20), Remarks NVARCHAR(300)) j;
        IF NOT EXISTS (SELECT 1 FROM @I) AND NOT EXISTS (SELECT 1 FROM @N) THROW 55193, 'Enter a quantity to issue, or mark a line not issued.', 1;
        IF EXISTS (SELECT IndentLineId FROM @N GROUP BY IndentLineId HAVING COUNT(*) > 1) THROW 55194, 'A line is marked not issued twice.', 1;
        IF EXISTS (SELECT 1 FROM @N n LEFT JOIN dbo.IpdPhIndentLine l ON l.LineId = n.IndentLineId AND l.IndentId = @IndentId AND l.Status IN ('PENDING', 'PARTIAL') WHERE l.LineId IS NULL)
            THROW 55195, 'A line to mark not issued was not found or is already closed.', 1;
        IF EXISTS (SELECT 1 FROM @N WHERE Reason IS NULL OR Reason = 'WARD_CANCELLED' OR dbo.fn_Ipd_PhNotIssueReason(Reason) IS NULL) THROW 55196, 'Choose the reason for every line not issued.', 1;
        IF EXISTS (SELECT 1 FROM @N WHERE Reason = 'OTHER' AND Remarks IS NULL) THROW 55197, 'Write the reason when "Other" is chosen.', 1;
        -- a line fully issued now leaves nothing to mark not issued
        SET @msg = (SELECT TOP 1 i.ItemName FROM @N n JOIN dbo.IpdPhIndentLine l ON l.LineId = n.IndentLineId JOIN dbo.PhItem i ON i.ItemId = l.ItemId
                    WHERE l.ReqQty - l.IssuedQty - l.NotIssuedQty - ISNULL((SELECT SUM(Qty) FROM @I x WHERE x.IndentLineId = n.IndentLineId), 0) <= 0);
        IF @msg IS NOT NULL BEGIN SET @msg = @msg + N' is issued in full: nothing is left to mark not issued.'; THROW 55198, @msg, 1; END

        -- not issued (first: the issue below, when there is one, sends the response)
        UPDATE l SET NotIssuedQty = l.ReqQty - l.IssuedQty - l.NotIssuedQty - ISNULL((SELECT SUM(Qty) FROM @I x WHERE x.IndentLineId = l.LineId), 0),
                     NotIssueReason = n.Reason, NotIssueRemarks = n.Remarks, NotIssuedBy = @UserId, NotIssuedAt = @now
        FROM dbo.IpdPhIndentLine l JOIN @N n ON n.IndentLineId = l.LineId;
        IF EXISTS (SELECT 1 FROM @N)
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            SELECT @adm, 'PH_NOT_ISSUED', LEFT(CONCAT(N'Indent ', @no, N' - not issued by the pharmacy: ',
                   STRING_AGG(CAST(CONCAT(i.ItemName, N' (', dbo.fn_Ipd_PhNotIssueReason(n.Reason), CASE WHEN n.Remarks IS NOT NULL THEN N': ' + n.Remarks END, N')') AS NVARCHAR(MAX)), N', ')), 1000), @UserId
            FROM @N n JOIN dbo.IpdPhIndentLine l ON l.LineId = n.IndentLineId JOIN dbo.PhItem i ON i.ItemId = l.ItemId;

        IF EXISTS (SELECT 1 FROM @I)
        BEGIN
            DECLARE @lines NVARCHAR(MAX) = (SELECT l.ItemId, x.BatchId, x.Qty, x.IndentLineId FROM @I x JOIN dbo.IpdPhIndentLine l ON l.LineId = x.IndentLineId FOR JSON PATH);
            DECLARE @ok BIT, @rem NVARCHAR(300) = LEFT(CONCAT(N'Indent ', @no, CASE WHEN NULLIF(LTRIM(RTRIM(@Remarks)), N'') IS NOT NULL THEN N' - ' + LTRIM(RTRIM(@Remarks)) END), 300);
            SET @StoreId = ISNULL(@StoreId, @store);
            -- stock, bill, ledger, register and the indent quantities (2437 issue): its result row is the answer
            EXEC dbo.usp_Api_IpdPh_Issue @CompanyId = @CompanyId, @BranchId = @BranchId, @UserId = @UserId, @AdmissionId = @adm, @Lines = @lines, @Head = 'PHARMACY',
                 @StoreId = @StoreId, @DoctorId = @doc, @Remarks = @rem, @IndentId = @IndentId, @Ok = @ok OUTPUT;
            IF ISNULL(@ok, 0) = 0
            BEGIN
                IF @tc = 0 AND XACT_STATE() <> 0 ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ind_sp;
                RETURN;
            END
            IF @tc = 0 COMMIT;
            RETURN;
        END
        EXEC dbo.usp_Ipd_PhIndentRefresh @IndentId = @IndentId;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, CAST(NULL AS INT) AS IssueId, CAST(NULL AS NVARCHAR(40)) AS IssueNo, CAST(0 AS DECIMAL(18,2)) AS Total;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ind_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── pharmacy: take back a line the ward did not receive (stock back, charge cancelled) ───────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPhIndent_TakeBack @CompanyId INT, @BranchId INT, @UserId INT, @IssueLineId INT, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ind_sp;
        DECLARE @adm INT, @rs VARCHAR(15), @keep DECIMAL(14,3), @why NVARCHAR(300);
        SELECT @adm = s.AdmissionId, @rs = l.ReceiveStatus, @keep = l.Qty - l.ReturnedQty, @why = l.ReceiveRemarks
        FROM dbo.IpdPhIssueLine l WITH (UPDLOCK) JOIN dbo.IpdPhIssue s ON s.IssueId = l.IssueId AND s.Kind = 'ISSUE'
        WHERE l.LineId = @IssueLineId AND s.CompanyId = @CompanyId AND s.BranchId = @BranchId;
        IF @adm IS NULL THROW 55201, 'The issued line was not found in this branch.', 1;
        IF ISNULL(@rs, '') <> 'NOT_RECEIVED' THROW 55202, 'Only a line the ward marked not received can be taken back.', 1;
        IF @keep <= 0 THROW 55203, 'Nothing is left on this line to take back.', 1;
        UPDATE dbo.IpdPhIssueLine SET ReceiveStatus = 'TAKEN_BACK', ResolvedBy = @UserId, ResolvedAt = GETDATE() WHERE LineId = @IssueLineId;
        DECLARE @lines NVARCHAR(MAX) = (SELECT @IssueLineId AS LineId, @keep AS Qty FOR JSON PATH), @ok BIT,
                @reason NVARCHAR(300) = LEFT(CONCAT(N'Not received by the ward', CASE WHEN @why IS NOT NULL THEN N' (' + @why + N')' END,
                                                    CASE WHEN NULLIF(LTRIM(RTRIM(@Remarks)), N'') IS NOT NULL THEN N' - ' + LTRIM(RTRIM(@Remarks)) END), 300);
        EXEC dbo.usp_Api_IpdPh_Return @CompanyId = @CompanyId, @BranchId = @BranchId, @UserId = @UserId, @AdmissionId = @adm, @Lines = @lines, @Reason = @reason,
             @IgnoreReturnable = 1, @Ok = @ok OUTPUT;
        IF ISNULL(@ok, 0) = 0
        BEGIN
            IF @tc = 0 AND XACT_STATE() <> 0 ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ind_sp;
            RETURN;
        END
        IF @tc = 0 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ind_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── permissions ────────────────────────────────────────────────────────────────────────────────────────────────
-- IPD.PATIENT: PH_INDENT (raise / cancel / re-indent), PH_RECEIVE (receive / not received). No role is granted.
SET NOCOUNT ON;
DECLARE @pp INT, @pv INT, @ctl INT, @a NVARCHAR(60);
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT';
OPEN pc; FETCH NEXT FROM pc INTO @pp;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'VIEW';
    DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'IndentItems,Indents', ',');
    OPEN v; FETCH NEXT FROM v INTO @a;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdPharmacy', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
    CLOSE v; DEALLOCATE v;
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @pp, @Control_Code = 'PH_INDENT', @Title = N'Raise / cancel / re-indent a medicine indent', @Sort_Order = 87, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdPharmacy', @Action = N'IndentSave', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdPharmacy', @Action = N'IndentCancel', @Source = 'SEED';
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @pp, @Control_Code = 'PH_RECEIVE', @Title = N'Receive issued medicines on the ward (or mark not received)', @Sort_Order = 90, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdPharmacy', @Action = N'Receive', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @pp;
END
CLOSE pc; DEALLOCATE pc;
GO

-- Pharmacy > Sales > IPD Issue (PHARMACY.IPDISSUE): VIEW, ISSUE (issue / not issue), TAKE_BACK. No role is granted.
DECLARE @co INT, @menu INT, @page INT, @view INT, @ctl INT, @a NVARCHAR(40);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY.SALES';
OPEN c; FETCH NEXT FROM c INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY.SALES' AND CompanyId = @co;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'PHARMACY.IPDISSUE', @Title = N'IPD Issue (Medicine Indents)', @Controller = N'PhIpdIssue',
         @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 15, @Icon = N'bi bi-hospital me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT('Index,Board,Detail,Batches', ',');
    OPEN v; FETCH NEXT FROM v INTO @a;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhIpdIssue', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
    CLOSE v; DEALLOCATE v;
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'ISSUE', @Title = N'Issue medicines / mark not issued (stock out, IP bill)', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhIpdIssue', @Action = N'Process', @Source = 'SEED';
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'TAKE_BACK', @Title = N'Take back a line the ward did not receive (stock back, charge cancelled)', @Sort_Order = 30, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhIpdIssue', @Action = N'TakeBack', @Source = 'SEED';
    FETCH NEXT FROM c INTO @co;
END
CLOSE c; DEALLOCATE c;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2475 IPD medicine indent - done.';
GO
