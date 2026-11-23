-- ============================================================================================================
-- 2405  Pharmacy: stock audit and stock analysis (after 2404). Settings in Hospital Settings > MED (2402).
--   Physical stock verification (PHARMACY.STOCKCOUNT):
--     * Blind Stock Count: the system quantity stays hidden from the count form until the count is submitted.
--     * Recount above X %: on submit, lines whose count differs from the frozen stock by more than X % (or any
--       count against a zero stock) are marked for recount; the first count is kept (FirstCountQty), the line is
--       cleared, and submit is refused until it is counted again (who / when kept). Approval shows both counts.
--     * Cycle count plan: racks with stock, when each was last verified, and which are due (every N days).
--   Item Master: VED class (Vital / Essential / Desirable).
--   Reports > Pharmacy: I15 ABC-VED Analysis (value class x criticality matrix), I16 Slow & Dead Stock
--   (value tied up, last sale, days since, near-expiry share).
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF COL_LENGTH('dbo.PhStockCountDtl', 'FirstCountQty') IS NULL
    ALTER TABLE dbo.PhStockCountDtl ADD FirstCountQty DECIMAL(14,3) NULL, RecountRequired BIT NOT NULL CONSTRAINT DF_PhStockCountDtl_Recount DEFAULT (0),
        RecountedBy INT NULL, RecountedDate DATETIME NULL, CountedBy INT NULL, CountedDate DATETIME NULL;
GO
IF COL_LENGTH('dbo.PhItem', 'VedClass') IS NULL
    ALTER TABLE dbo.PhItem ADD VedClass CHAR(1) NULL CONSTRAINT CK_PhItem_VedClass CHECK (VedClass IN ('V', 'E', 'D'));
GO

-- one verification: 1 header (+ blind / recount settings), 2 lines (+ first count and recount)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_GetCount @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhStockCount WHERE StockCountId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId) SET @Id = -1;
    SELECT c.StockCountId Id, c.StoreId, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = c.StoreId) StoreName, 'COUNT' Kind, c.CountNo DocNo, c.FrozenAt DocDate, c.FrozenAt, c.Scope, c.Status, c.Remarks, c.ActionRemarks, c.AdjustmentId,
           c.CreatedBy, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.CreatedBy) CreatedByName, c.CreatedDate,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.ApprovedBy) ApprovedByName, c.ApprovedDate,
           ISNULL(hs.PharmacyCountBlind, 0) BlindCount, ISNULL(hs.PharmacyCountRecountPercent, 0) RecountPercent
      FROM dbo.PhStockCount c
      OUTER APPLY (SELECT TOP 1 PharmacyCountBlind, PharmacyCountRecountPercent FROM dbo.HospitalSettings WHERE BranchId = c.BranchId ORDER BY IsActive DESC) hs
     WHERE c.StockCountId = @Id;
    SELECT x.StockCountDtlId LineId, x.ItemId, i.ItemName, i.ItemCode, df.ShortName FormShort, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
           x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.RackNo, x.SystemQty, x.CountedQty, x.UnitCost, x.Remarks, x.FirstCountQty, x.RecountRequired, x.RecountedDate,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = x.RecountedBy) RecountedByName, ISNULL(s.QtyOnHand, 0) Stock
      FROM dbo.PhStockCountDtl x JOIN dbo.PhItem i ON i.ItemId = x.ItemId JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
      LEFT JOIN dbo.PhStoreStock s ON s.BatchId = x.BatchId AND s.StoreId = (SELECT ISNULL(k.StoreId, dbo.fn_PhDefaultStore(k.BranchId, 'RECEIVE')) FROM dbo.PhStockCount k WHERE k.StockCountId = @Id)
     WHERE x.StockCountId = @Id ORDER BY ISNULL(x.RackNo, 'zzz'), i.ItemName, b.ExpiryDate;
END
GO

-- @Counts: [{ "LineId", "Qty" (null = not counted) }]; records who counted and stamps a recount
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_SaveCounts @CompanyId INT, @BranchId INT, @Id INT, @Counts NVARCHAR(MAX), @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    IF ISNULL((SELECT Status FROM dbo.PhStockCount WITH (UPDLOCK) WHERE StockCountId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'COUNTING'
    BEGIN ROLLBACK; SELECT N'Counts can be entered only while the verification is open.' AS Error; RETURN; END;
    UPDATE d SET CountedQty = j.Qty,
                 CountedBy = CASE WHEN ISNULL(d.CountedQty, -1) <> ISNULL(j.Qty, -1) THEN @UserId ELSE d.CountedBy END,
                 CountedDate = CASE WHEN ISNULL(d.CountedQty, -1) <> ISNULL(j.Qty, -1) THEN GETDATE() ELSE d.CountedDate END,
                 -- a line marked for recount is recounted when a quantity is entered again
                 RecountedBy = CASE WHEN d.RecountRequired = 1 AND d.RecountedDate IS NULL AND j.Qty IS NOT NULL THEN @UserId ELSE d.RecountedBy END,
                 RecountedDate = CASE WHEN d.RecountRequired = 1 AND d.RecountedDate IS NULL AND j.Qty IS NOT NULL THEN GETDATE() ELSE d.RecountedDate END
      FROM dbo.PhStockCountDtl d JOIN OPENJSON(@Counts) WITH (LineId INT, Qty DECIMAL(14,3)) j ON j.LineId = d.StockCountDtlId
     WHERE d.StockCountId = @Id;
    COMMIT;
    SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_CountAction @CompanyId INT, @BranchId INT, @UserId INT, @Id INT, @Action VARCHAR(10), @Remarks NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @maker INT, @no NVARCHAR(40), @uncounted INT, @store INT = (SELECT StoreId FROM dbo.PhStockCount WHERE StockCountId = @Id);
        SELECT @status = Status, @maker = CreatedBy, @no = CountNo,
               @uncounted = (SELECT COUNT(*) FROM dbo.PhStockCountDtl d WHERE d.StockCountId = c.StockCountId AND d.CountedQty IS NULL)
          FROM dbo.PhStockCount c WITH (UPDLOCK) WHERE StockCountId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL BEGIN ROLLBACK; SELECT N'Not found.' AS Error; RETURN; END;
        IF @Action = 'submit'
        BEGIN
            IF @status <> 'COUNTING' BEGIN ROLLBACK; SELECT N'Only an open verification can be submitted.' AS Error; RETURN; END;
            IF @uncounted > 0 BEGIN ROLLBACK; SELECT CAST(@uncounted AS NVARCHAR(10)) + N' batch(es) are not counted yet. Enter a count for every line (0 if none found).' AS Error; RETURN; END;
            -- Hospital Settings > MED > Recount if Variance Above (%): big differences are counted a second time first
            DECLARE @pct DECIMAL(5,2) = ISNULL((SELECT TOP 1 PharmacyCountRecountPercent FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0);
            IF @pct > 0
            BEGIN
                UPDATE dbo.PhStockCountDtl SET RecountRequired = 1, FirstCountQty = CountedQty, CountedQty = NULL
                 WHERE StockCountId = @Id AND RecountedDate IS NULL AND RecountRequired = 0 AND CountedQty IS NOT NULL
                   AND ((SystemQty = 0 AND CountedQty <> 0) OR (SystemQty <> 0 AND ABS(CountedQty - SystemQty) * 100 / SystemQty > @pct));
                DECLARE @flagged INT = @@ROWCOUNT;
                IF @flagged > 0
                BEGIN
                    COMMIT;
                    SELECT CAST(@flagged AS NVARCHAR(10)) + N' batch(es) differ from the stock by more than ' + FORMAT(@pct, '0.##') +
                           N'%. They are marked RECOUNT and cleared: count them again, save, and submit.' AS Error;
                    RETURN;
                END
            END
            UPDATE dbo.PhStockCount SET Status = 'SUBMITTED', SubmittedBy = @UserId, SubmittedDate = GETDATE() WHERE StockCountId = @Id;
        END
        ELSE IF @Action = 'approve'
        BEGIN
            IF @status <> 'SUBMITTED' BEGIN ROLLBACK; SELECT N'Only a submitted verification can be approved.' AS Error; RETURN; END;
            IF @maker = @UserId BEGIN ROLLBACK; SELECT N'You started this verification; another user must approve it.' AS Error; RETURN; END;
            -- the difference found is applied to today's stock (sales after the freeze are kept)
            DECLARE @D TABLE (Rn INT IDENTITY PRIMARY KEY, BatchId INT, ItemId INT, Diff DECIMAL(14,3), Cost DECIMAL(12,4));
            INSERT @D (BatchId, ItemId, Diff, Cost) SELECT BatchId, ItemId, CountedQty - SystemQty, UnitCost FROM dbo.PhStockCountDtl
             WHERE StockCountId = @Id AND CountedQty IS NOT NULL AND CountedQty <> SystemQty ORDER BY StockCountDtlId;
            DECLARE @adjId INT = NULL;
            IF EXISTS (SELECT 1 FROM @D)
            BEGIN
                DECLARE @reason INT = (SELECT TOP 1 ReasonId FROM dbo.PhReason WHERE CompanyId = @CompanyId AND ReasonType = 'ADJUSTMENT' AND ReasonName LIKE '%count%' ORDER BY SortOrder);
                INSERT dbo.PhAdjustment (CompanyId, BranchId, StoreId, Kind, DocNo, DocDate, ReasonId, Status, Remarks, StockCountId, CreatedBy, SubmittedBy, SubmittedDate)
                VALUES (@CompanyId, @BranchId, @store, 'PHYSICAL', @no, CAST(GETDATE() AS DATE), @reason, 'SUBMITTED', N'Physical stock verification ' + @no, @Id, @maker, @maker, GETDATE());
                SET @adjId = CAST(SCOPE_IDENTITY() AS INT);
                INSERT dbo.PhAdjustmentDtl (AdjustmentId, BatchId, ItemId, QtyChange, UnitCost) SELECT @adjId, BatchId, ItemId, Diff, Cost FROM @D ORDER BY Rn;
                DECLARE @rn INT = (SELECT MIN(Rn) FROM @D), @b INT, @q DECIMAL(14,3);
                WHILE @rn IS NOT NULL
                BEGIN
                    SELECT @b = BatchId, @q = Diff FROM @D WHERE Rn = @rn;
                    EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @q, @DocType = 'PCNT', @DocId = @Id, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0,
                         @StoreId = @store;
                    SET @rn = (SELECT MIN(Rn) FROM @D WHERE Rn > @rn);
                END
                UPDATE dbo.PhAdjustment SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedDate = GETDATE(),
                       PlusValue = ISNULL((SELECT ROUND(SUM(CAST(Diff AS DECIMAL(38,18)) * Cost), 2) FROM @D WHERE Diff > 0), 0),
                       MinusValue = ISNULL((SELECT ROUND(-SUM(CAST(Diff AS DECIMAL(38,18)) * Cost), 2) FROM @D WHERE Diff < 0), 0)
                 WHERE AdjustmentId = @adjId;
                EXEC dbo.usp_Ph_PostInventoryLedger @Kind = 'ADJ', @RefId = @adjId, @UserId = @UserId;
            END
            UPDATE dbo.PhStockCount SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedDate = GETDATE(), ActionRemarks = @Remarks, AdjustmentId = @adjId WHERE StockCountId = @Id;
        END
        ELSE IF @Action = 'reject'
        BEGIN
            IF @status <> 'SUBMITTED' BEGIN ROLLBACK; SELECT N'Only a submitted verification can be sent back.' AS Error; RETURN; END;
            IF LTRIM(RTRIM(ISNULL(@Remarks, N''))) = N'' BEGIN ROLLBACK; SELECT N'Say what is to be recounted.' AS Error; RETURN; END;
            UPDATE dbo.PhStockCount SET Status = 'COUNTING', ActionRemarks = @Remarks WHERE StockCountId = @Id;
        END
        ELSE IF @Action = 'cancel'
        BEGIN
            IF @status NOT IN ('COUNTING', 'SUBMITTED') BEGIN ROLLBACK; SELECT N'Only an open verification can be cancelled.' AS Error; RETURN; END;
            UPDATE dbo.PhStockCount SET Status = 'CANCELLED', ActionRemarks = @Remarks WHERE StockCountId = @Id;
        END
        ELSE BEGIN ROLLBACK; SELECT N'Unknown action.' AS Error; RETURN; END;
        COMMIT;
        SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- Cycle count plan: each rack with stock, its last approved verification, and whether it is due
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_CycleCountPlan @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @every INT = ISNULL((SELECT TOP 1 PharmacyCycleCountDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
    ;WITH racks AS (
        SELECT ISNULL(NULLIF(LTRIM(RTRIM(ib.RackNo)), N''), N'(no rack)') AS RackNo, COUNT(DISTINCT s.BatchId) AS Batches, COUNT(DISTINCT s.ItemId) AS Items,
               CAST(SUM(s.QtyOnHand * b.LandedCost) AS DECIMAL(14,2)) AS StockValue
          FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = s.ItemId
          LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = s.ItemId AND ib.BranchId = s.BranchId
         WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND i.CompanyId = @CompanyId
         GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(ib.RackNo)), N''), N'(no rack)')
    ), last AS (
        SELECT ISNULL(NULLIF(LTRIM(RTRIM(d.RackNo)), N''), N'(no rack)') AS RackNo, MAX(c.ApprovedDate) AS LastCounted,
               MAX(CASE WHEN c.Status IN ('COUNTING', 'SUBMITTED') THEN c.CountNo END) AS OpenCount
          FROM dbo.PhStockCountDtl d JOIN dbo.PhStockCount c ON c.StockCountId = d.StockCountId
         WHERE c.BranchId = @BranchId AND c.CompanyId = @CompanyId AND c.Status IN ('APPROVED', 'COUNTING', 'SUBMITTED')
         GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(d.RackNo)), N''), N'(no rack)')
    )
    SELECT r.RackNo, r.Items, r.Batches, r.StockValue, l.LastCounted, l.OpenCount,
           DATEDIFF(DAY, l.LastCounted, GETDATE()) AS DaysSince, @every AS EveryDays,
           CAST(CASE WHEN l.OpenCount IS NULL AND (l.LastCounted IS NULL OR DATEDIFF(DAY, l.LastCounted, GETDATE()) >= @every) THEN 1 ELSE 0 END AS BIT) AS IsDue
      FROM racks r LEFT JOIN last l ON l.RackNo = r.RackNo
     ORDER BY CASE WHEN l.OpenCount IS NULL AND (l.LastCounted IS NULL OR DATEDIFF(DAY, l.LastCounted, GETDATE()) >= @every) THEN 0 ELSE 1 END,
              l.LastCounted, r.StockValue DESC;
END
GO

-- saves the item (+ VED class, SQLScripts/2405) and its rack / levels for the branch
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhItem_Save
    @ItemId INT, @CompanyId INT, @BranchId INT, @UserId INT,
    @ItemCode NVARCHAR(20) = NULL,
    @ItemName NVARCHAR(200) = NULL,
    @GenericId INT = NULL,
    @ManufacturerId INT = NULL,
    @CategoryId INT = NULL,
    @DosageFormId INT = NULL,
    @Strength NVARCHAR(60) = NULL,
    @PackSize NVARCHAR(60) = NULL,
    @ScheduleCode VARCHAR(10) = NULL,
    @HsnId INT = NULL,
    @PurchaseUomId INT = NULL,
    @SaleUomId INT = NULL,
    @ConversionQty INT = NULL,
    @AllowLooseSale BIT = NULL,
    @IsColdChain BIT = NULL,
    @IsHighAlert BIT = NULL,
    @IsLasa BIT = NULL,
    @IsReturnable BIT = NULL,
    @IsDiscountAllowed BIT = NULL,
    @PrescriptionRequired BIT = NULL,
    @Barcode NVARCHAR(50) = NULL,
    @ReorderLevel DECIMAL(12,2) = NULL,
    @MinQty DECIMAL(12,2) = NULL,
    @MaxQty DECIMAL(12,2) = NULL,
    @LeadDays INT = NULL,
    @Remarks NVARCHAR(300) = NULL,
    @IsActive BIT = NULL,
    @RackNo NVARCHAR(30) = NULL, @BranchReorderLevel DECIMAL(12,2) = NULL, @BranchMinQty DECIMAL(12,2) = NULL,
    @BranchMaxQty DECIMAL(12,2) = NULL, @IsStocked BIT = 1, @VedClass CHAR(1) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @dup VARCHAR(30) = (SELECT TOP 1 ItemCode FROM dbo.PhItem WHERE CompanyId = @CompanyId AND ItemId <> ISNULL(@ItemId, 0)
            AND ItemName = @ItemName AND ISNULL(ManufacturerId, 0) = ISNULL(@ManufacturerId, 0) AND ISNULL(DosageFormId, 0) = ISNULL(@DosageFormId, 0));
        IF @dup IS NOT NULL BEGIN ROLLBACK; SELECT 0 AS Id, N'The same item of this manufacturer and form already exists (' + @dup + N').' AS Error; RETURN; END

        IF @ItemCode IS NULL
            SELECT @ItemCode = 'PH' + RIGHT('00000' + CAST(ISNULL(MAX(ItemId), 0) + 1 AS VARCHAR(10)), 5) FROM dbo.PhItem WITH (UPDLOCK, HOLDLOCK);

        IF ISNULL(@ItemId, 0) = 0
        BEGIN
            INSERT dbo.PhItem (CompanyId, ItemCode, ItemName, GenericId, ManufacturerId, CategoryId, DosageFormId, Strength, PackSize, ScheduleCode, HsnId, PurchaseUomId, SaleUomId, ConversionQty, AllowLooseSale, IsColdChain, IsHighAlert, IsLasa, IsReturnable, IsDiscountAllowed, PrescriptionRequired, Barcode, ReorderLevel, MinQty, MaxQty, LeadDays, Remarks, IsActive, CreatedBy, VedClass)
            VALUES (@CompanyId, @ItemCode, @ItemName, @GenericId, @ManufacturerId, @CategoryId, @DosageFormId, @Strength, @PackSize, @ScheduleCode, @HsnId, @PurchaseUomId, @SaleUomId, @ConversionQty, @AllowLooseSale, @IsColdChain, @IsHighAlert, @IsLasa, @IsReturnable, @IsDiscountAllowed, @PrescriptionRequired, @Barcode, @ReorderLevel, @MinQty, @MaxQty, @LeadDays, @Remarks, @IsActive, @UserId, NULLIF(@VedClass, ''));
            SET @ItemId = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhItem SET ItemCode = @ItemCode, ItemName = @ItemName, GenericId = @GenericId, ManufacturerId = @ManufacturerId, CategoryId = @CategoryId, DosageFormId = @DosageFormId, Strength = @Strength, PackSize = @PackSize, ScheduleCode = @ScheduleCode, HsnId = @HsnId, PurchaseUomId = @PurchaseUomId, SaleUomId = @SaleUomId, ConversionQty = @ConversionQty, AllowLooseSale = @AllowLooseSale, IsColdChain = @IsColdChain, IsHighAlert = @IsHighAlert, IsLasa = @IsLasa, IsReturnable = @IsReturnable, IsDiscountAllowed = @IsDiscountAllowed, PrescriptionRequired = @PrescriptionRequired, Barcode = @Barcode, ReorderLevel = @ReorderLevel, MinQty = @MinQty, MaxQty = @MaxQty, LeadDays = @LeadDays, Remarks = @Remarks, IsActive = @IsActive, VedClass = NULLIF(@VedClass, ''), ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE ItemId = @ItemId AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Item not found.' AS Error; RETURN; END
        END

        MERGE dbo.PhItemBranch AS t USING (SELECT @ItemId AS ItemId, @BranchId AS BranchId) AS s ON t.ItemId = s.ItemId AND t.BranchId = s.BranchId
        WHEN MATCHED THEN UPDATE SET RackNo = @RackNo, ReorderLevel = @BranchReorderLevel, MinQty = @BranchMinQty, MaxQty = @BranchMaxQty, IsStocked = @IsStocked, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHEN NOT MATCHED THEN INSERT (ItemId, BranchId, RackNo, ReorderLevel, MinQty, MaxQty, IsStocked, ModifiedBy, ModifiedDate)
             VALUES (@ItemId, @BranchId, @RackNo, @BranchReorderLevel, @BranchMinQty, @BranchMaxQty, @IsStocked, @UserId, GETDATE());
        COMMIT;
        SELECT @ItemId AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601)
        BEGIN
            SELECT 0 AS Id, CASE WHEN ERROR_MESSAGE() LIKE N'%Barcode%' THEN N'Another item already has this barcode.' ELSE N'Another item already has this item code.' END AS Error;
            RETURN;
        END;
        THROW;
    END CATCH
END
GO

-- ── I15 ABC-VED Analysis: consumption value class (ABC, Hospital Settings > MED thresholds) x VED criticality ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_AbcVed
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    DECLARE @a DECIMAL(5,2) = 70, @b DECIMAL(5,2) = 90;
    SELECT TOP 1 @a = PharmacyAbcAPercent, @b = PharmacyAbcBPercent FROM dbo.HospitalSettings WHERE BranchId = ISNULL(@BranchId, BranchId) ORDER BY IsActive DESC;
    SELECT i.ItemId, i.ItemCode, i.ItemName, ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, su.UomCode AS SaleUom, i.VedClass,
           CAST(ISNULL(u.Qty, 0) AS DECIMAL(14,3)) AS QtyConsumed, CAST(ISNULL(u.Value, 0) AS DECIMAL(14,2)) AS ConsumptionValue,
           CAST(ISNULL(st.Qty, 0) AS DECIMAL(14,3)) AS Stock, CAST(ISNULL(st.Value, 0) AS DECIMAL(14,2)) AS StockValue
      INTO #G
      FROM dbo.PhItem i JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
      -- consumption = sales and IPD issues, net of their returns, at batch cost
      OUTER APPLY (SELECT SUM(l.QtyOut - l.QtyIn) AS Qty, SUM((l.QtyOut - l.QtyIn) * l.UnitCost) AS Value
                     FROM dbo.PhStockLedger l WHERE l.ItemId = i.ItemId AND l.DocType IN ('SALE', 'SRET', 'IPDI', 'IPDR')
                      AND l.TxnDate >= @From AND l.TxnDate < @end AND (@BranchId IS NULL OR l.BranchId = @BranchId)) u
      OUTER APPLY (SELECT SUM(s.QtyOnHand) AS Qty, SUM(s.QtyOnHand * b.LandedCost) AS Value FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.ItemId = i.ItemId AND s.QtyOnHand > 0 AND (@BranchId IS NULL OR s.BranchId = @BranchId)) st
     WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 AND (ISNULL(u.Qty, 0) <> 0 OR ISNULL(st.Qty, 0) > 0)
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search);
    DECLARE @total DECIMAL(18,2) = NULLIF((SELECT SUM(CASE WHEN ConsumptionValue > 0 THEN ConsumptionValue ELSE 0 END) FROM #G), 0);
    SELECT *, CAST(CASE WHEN ConsumptionValue > 0 THEN ConsumptionValue * 100 / @total ELSE 0 END AS DECIMAL(8,2)) AS SharePct,
           CAST(SUM(CASE WHEN ConsumptionValue > 0 THEN ConsumptionValue ELSE 0 END) OVER (ORDER BY ConsumptionValue DESC, ItemName ROWS UNBOUNDED PRECEDING) * 100 / @total AS DECIMAL(8,2)) AS CumPct
      INTO #C FROM #G;
    SELECT *, CASE WHEN ConsumptionValue <= 0 OR @total IS NULL THEN 'C' WHEN CumPct - SharePct < @a THEN 'A' WHEN CumPct - SharePct < @b THEN 'B' ELSE 'C' END AS Abc
      INTO #A FROM #C;
    SELECT ROW_NUMBER() OVER (ORDER BY ConsumptionValue DESC, ItemName) AS Rn, *,
           ISNULL(VedClass, '-') AS Ved,
           CASE ISNULL(VedClass, '') WHEN 'V' THEN N'Vital' WHEN 'E' THEN N'Essential' WHEN 'D' THEN N'Desirable' ELSE N'Not set' END AS VedName,
           Abc + ISNULL(VedClass, '?') AS Matrix,
           CASE WHEN VedClass IS NULL THEN N'Set VED in Item Master'
                WHEN Abc = 'A' OR VedClass = 'V' THEN N'I - tight control, never out of stock'
                WHEN Abc = 'C' AND VedClass = 'D' THEN N'III - minimal stock, order as needed'
                ELSE N'II - normal control' END AS ControlCategory
      INTO #R FROM #A
     WHERE @Option IS NULL OR @Option = '' OR (@Option IN ('A', 'B', 'C') AND Abc = @Option) OR (@Option IN ('V', 'E', 'D') AND VedClass = @Option)
        OR (@Option = 'CAT1' AND VedClass IS NOT NULL AND (Abc = 'A' OR VedClass = 'V')) OR (@Option = 'NOVED' AND VedClass IS NULL);

    SELECT (SELECT COUNT(*) FROM #A WHERE Abc = 'A') AS ClassA, (SELECT COUNT(*) FROM #A WHERE Abc = 'B') AS ClassB, (SELECT COUNT(*) FROM #A WHERE Abc = 'C') AS ClassC,
           (SELECT COUNT(*) FROM #A WHERE VedClass = 'V') AS Vital, (SELECT COUNT(*) FROM #A WHERE VedClass IS NULL) AS NoVed,
           ISNULL((SELECT SUM(ConsumptionValue) FROM #A WHERE Abc = 'A'), 0) AS AValue;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(ConsumptionValue) AS ConsumptionValue, SUM(StockValue) AS StockValue, SUM(QtyConsumed) AS QtyConsumed FROM #R;
END
GO

-- ── I16 Slow & Dead Stock: stock that has not sold for a while, the money it holds, and how close it is to expiry ──
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_DeadStock
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @slow INT = 60, @dead INT = 180, @near INT = 90;
    SELECT TOP 1 @slow = PharmacySlowMovingDays, @dead = PharmacyDeadStockDays, @near = PharmacyNearExpiryAlertDays
      FROM dbo.HospitalSettings WHERE BranchId = ISNULL(@BranchId, BranchId) ORDER BY IsActive DESC;
    SELECT i.ItemId, i.ItemCode, i.ItemName, ISNULL(pc.CategoryName + N' › ', N'') + c.CategoryName AS CategoryName, m.ManufacturerName, su.UomCode AS SaleUom, i.VedClass,
           st.Qty AS Stock, CAST(st.Value AS DECIMAL(14,2)) AS StockValue, CAST(st.NearValue AS DECIMAL(14,2)) AS NearExpiryValue, st.NearestExpiry,
           ls.LastSale, lr.LastReceipt,
           DATEDIFF(DAY, ISNULL(ls.LastSale, lr.LastReceipt), @today) AS DaysIdle
      INTO #G
      FROM dbo.PhItem i JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
      LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
      CROSS APPLY (SELECT SUM(s.QtyOnHand) AS Qty, SUM(s.QtyOnHand * b.LandedCost) AS Value,
                          SUM(CASE WHEN b.ExpiryDate <= DATEADD(DAY, @near, @today) THEN s.QtyOnHand * b.LandedCost ELSE 0 END) AS NearValue, MIN(b.ExpiryDate) AS NearestExpiry
                     FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.ItemId = i.ItemId AND s.QtyOnHand > 0 AND (@BranchId IS NULL OR s.BranchId = @BranchId)) st
      OUTER APPLY (SELECT MAX(l.TxnDate) AS LastSale FROM dbo.PhStockLedger l WHERE l.ItemId = i.ItemId AND l.DocType IN ('SALE', 'IPDI') AND (@BranchId IS NULL OR l.BranchId = @BranchId)) ls
      OUTER APPLY (SELECT MAX(l.TxnDate) AS LastReceipt FROM dbo.PhStockLedger l WHERE l.ItemId = i.ItemId AND l.QtyIn > 0 AND (@BranchId IS NULL OR l.BranchId = @BranchId)) lr
     WHERE i.CompanyId = @CompanyId AND st.Qty > 0
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search);
    SELECT ROW_NUMBER() OVER (ORDER BY StockValue DESC, ItemName) AS Rn, *,
           CASE WHEN DaysIdle >= @dead THEN 'DEAD' WHEN DaysIdle >= @slow THEN 'SLOW' ELSE 'MOVING' END AS Status,
           CASE WHEN DaysIdle >= @dead THEN N'Dead' WHEN DaysIdle >= @slow THEN N'Slow' ELSE N'Moving' END AS StatusName,
           CASE WHEN DaysIdle < @slow THEN N''
                WHEN NearestExpiry <= DATEADD(DAY, @near, @today) THEN N'Return to supplier / write off before expiry'
                WHEN DaysIdle >= @dead THEN N'Return or transfer to a branch that sells it; stop reordering'
                ELSE N'Reduce reorder level; push with doctors / substitute' END AS Suggestion
      INTO #R FROM #G
     WHERE (@Option IS NULL OR @Option = '' AND DaysIdle >= @slow) OR (@Option = 'SLOW' AND DaysIdle >= @slow AND DaysIdle < @dead) OR (@Option = 'DEAD' AND DaysIdle >= @dead)
        OR @Option = 'ALL';

    SELECT (SELECT COUNT(*) FROM #G WHERE DaysIdle >= @slow AND DaysIdle < @dead) AS SlowItems, ISNULL((SELECT SUM(StockValue) FROM #G WHERE DaysIdle >= @slow AND DaysIdle < @dead), 0) AS SlowValue,
           (SELECT COUNT(*) FROM #G WHERE DaysIdle >= @dead) AS DeadItems, ISNULL((SELECT SUM(StockValue) FROM #G WHERE DaysIdle >= @dead), 0) AS DeadValue,
           ISNULL((SELECT SUM(StockValue) FROM #G), 0) AS TotalValue;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(StockValue) AS StockValue, SUM(NearExpiryValue) AS NearExpiryValue FROM #R;
END
GO

-- pages: Reports > Pharmacy I15 / I16; cycle count plan on Physical Stock Verification
DECLARE @co INT, @ph INT, @page INT, @view INT, @exp INT, @code NVARCHAR(100), @title NVARCHAR(150), @act NVARCHAR(100), @sort INT, @icon NVARCHAR(100);
DECLARE @P TABLE (Code NVARCHAR(100), Title NVARCHAR(150), Act NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT @P VALUES (N'REPORTS.PHARMACY.ABCVED', N'ABC-VED Analysis', N'AbcVed', 445, N'bi bi-grid-3x3 me-2'),
                 (N'REPORTS.PHARMACY.DEADSTOCK', N'Slow & Dead Stock', N'DeadStock', 450, N'bi bi-hourglass-bottom me-2');
DECLARE co CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.PHARMACY';
OPEN co; FETCH NEXT FROM co INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @ph = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.PHARMACY' AND CompanyId = @co;
    DECLARE p CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Act, Sort, Icon FROM @P;
    OPEN p; FETCH NEXT FROM p INTO @code, @title, @act, @sort, @icon;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @ph, @Page_Code = @code, @Title = @title, @Controller = N'PhReports', @Action = @act,
             @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        SET @exp = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EXPORT', @Title = N'Export to Excel / PDF', @Sort_Order = 20, @Control_ID = @exp OUTPUT;
        DECLARE @a2 NVARCHAR(100) = @act + N'Data', @a3 NVARCHAR(100) = @act + N'Export';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @act, @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @a2, @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @exp, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @a3, @Source = 'SEED';
        FETCH NEXT FROM p INTO @code, @title, @act, @sort, @icon;
    END
    CLOSE p; DEALLOCATE p;

    SET @page = NULL; SET @view = NULL;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = 'PHARMACY.STOCKCOUNT' AND CompanyId = @co;
    SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhStockCounts', @Action = N'CyclePlan', @Source = 'SEED';
    FETCH NEXT FROM co INTO @co;
END
CLOSE co; DEALLOCATE co;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2405 applied: Pharmacy stock audit (blind, recount, cycle plan), VED class, ABC-VED and Slow & Dead Stock reports.';
GO
