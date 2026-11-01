-- ============================================================================================================
-- Migration: 2360_pharmacy_inventory_api.sql
-- Pharmacy > Inventory through EMR.Api (API + stored procedures, like LAB / OPD): stock enquiry and ledger, branch indent
-- & transfer, stock adjustment / write-off, physical stock verification, batch correction, maker-checker look-ups and
-- the dashboard. Replaces the SQL that EMR.Web/Services/PharmacyInventoryService.cs ran directly. Checks that need no
-- data stay in EMR.Web; everything that reads or locks data runs here, each save in one transaction as before, with the
-- same messages. Stock still moves only through usp_PhStock_Move; books by usp_Ph_PostInventoryLedger (2349).
-- No table changes. Run after 2359. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── stock enquiry ────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_PhStockRows (@CompanyId INT, @BranchId INT)
RETURNS TABLE
AS
RETURN
    SELECT b.BatchId, i.ItemId, i.ItemCode, i.ItemName, df.ShortName FormShort, g.GenericName, m.ManufacturerName, c.CategoryName, i.ScheduleCode, ib.RackNo,
           b.BatchNo, b.ExpiryDate, b.Mrp, b.LandedCost, b.GstPercent, ISNULL(s.QtyOnHand, 0) Stock, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty, b.IsBlocked, sp.SupplierName,
           s.BatchId AS StockBatchId, s.QtyOnHand, i.Barcode, i.CategoryId, c.ParentCategoryId
      FROM dbo.PhBatch b JOIN dbo.PhItem i ON i.ItemId = b.ItemId
      LEFT JOIN dbo.PhStock s ON s.BatchId = b.BatchId AND s.BranchId = @BranchId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
      LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
      LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId LEFT JOIN dbo.PhSupplier sp ON sp.SupplierId = b.SupplierId
      LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
     WHERE b.CompanyId = @CompanyId;
GO

-- @Filter: in-stock (default) | expired | near (90 days) | zero | all
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Stock @CompanyId INT, @BranchId INT, @Search NVARCHAR(200) = NULL, @CategoryId INT = NULL, @Filter VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(210) = N'%' + @Search + N'%', @today DATE = CAST(GETDATE() AS DATE);
    SELECT BatchId, ItemId, ItemCode, ItemName, FormShort, GenericName, ManufacturerName, CategoryName, ScheduleCode, RackNo, BatchNo, ExpiryDate, Mrp, LandedCost, GstPercent,
           Stock, SaleUom, PurchaseUom, ConversionQty, IsBlocked, SupplierName
      FROM dbo.fn_PhStockRows(@CompanyId, @BranchId) x
     WHERE (   (@Filter = 'expired' AND x.QtyOnHand > 0 AND x.ExpiryDate <= @today)
            OR (@Filter = 'near'    AND x.QtyOnHand > 0 AND x.ExpiryDate > @today AND x.ExpiryDate <= DATEADD(DAY, 90, @today))
            OR (@Filter = 'zero'    AND ISNULL(x.QtyOnHand, 0) = 0 AND x.StockBatchId IS NOT NULL)
            OR (@Filter = 'all'     AND x.StockBatchId IS NOT NULL)
            OR (ISNULL(@Filter, '') NOT IN ('expired', 'near', 'zero', 'all') AND x.QtyOnHand > 0))
       AND (@Search IS NULL OR x.ItemName LIKE @like OR x.ItemCode = @Search OR x.BatchNo LIKE @like OR x.GenericName LIKE @like OR x.Barcode = @Search)
       AND (@CategoryId IS NULL OR x.CategoryId = @CategoryId OR x.ParentCategoryId = @CategoryId)
     ORDER BY x.ItemName, x.ExpiryDate;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Ledger @CompanyId INT, @BranchId INT, @ItemId INT, @BatchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 500 l.TxnDate, l.DocType, l.DocNo, b.BatchNo, l.QtyIn, l.QtyOut, l.BalanceAfter, l.UnitCost,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = l.CreatedBy) UserName
      FROM dbo.PhStockLedger l JOIN dbo.PhBatch b ON b.BatchId = l.BatchId
     WHERE l.BranchId = @BranchId AND l.ItemId = @ItemId AND b.CompanyId = @CompanyId AND (@BatchId IS NULL OR l.BatchId = @BatchId)
     ORDER BY l.LedgerId DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_BatchSearch @CompanyId INT, @BranchId INT, @Q NVARCHAR(200), @ExpiredOnly BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @like NVARCHAR(210) = N'%' + @Q + N'%';
    SELECT TOP 30 BatchId, ItemId, ItemCode, ItemName, FormShort, GenericName, ManufacturerName, CategoryName, ScheduleCode, RackNo, BatchNo, ExpiryDate, Mrp, LandedCost, GstPercent,
           Stock, SaleUom, PurchaseUom, ConversionQty, IsBlocked, SupplierName
      FROM dbo.fn_PhStockRows(@CompanyId, @BranchId) x
     WHERE x.QtyOnHand > 0 AND (x.ItemName LIKE @like OR x.ItemCode = @Q OR x.BatchNo LIKE @like OR x.Barcode = @Q)
       AND (@ExpiredOnly = 0 OR x.ExpiryDate <= DATEADD(DAY, 90, CAST(GETDATE() AS DATE)))
     ORDER BY x.ItemName, x.ExpiryDate;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_OtherBranches @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(b.BranchID AS VARCHAR(10)) Value, b.BranchName + N' (' + b.BranchCode + N')' Text FROM dbo.Branchmaster b
     WHERE b.CompanyId = @CompanyId AND b.IsActive = 1 AND b.BranchID <> @BranchId
       AND EXISTS (SELECT 1 FROM dbo.HospitalSettings h WHERE h.BranchId = b.BranchID AND h.PharmacyEnabled = 1) ORDER BY b.BranchName;
END
GO

-- ── branch indent & transfer ─────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Transfers @CompanyId INT, @BranchId INT, @Dir VARCHAR(5), @Status VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 500 t.TransferId Id, COALESCE(t.TransferNo, t.RequestNo) DocNo, COALESCE(t.DispatchDate, t.RequestDate, t.CreatedDate) DocDate, t.Status,
           CASE WHEN t.ToBranchId = @BranchId THEN fb.BranchName ELSE tb.BranchName END Party, t.RequestNo Ref,
           (SELECT COUNT(DISTINCT d.ItemId) FROM dbo.PhTransferDtl d WHERE d.TransferId = t.TransferId) Lines, t.CostValue Value,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = t.CreatedBy) CreatedByName, CASE WHEN t.ToBranchId = @BranchId THEN 'IN' ELSE 'OUT' END Direction
      FROM dbo.PhTransfer t JOIN dbo.Branchmaster fb ON fb.BranchID = t.FromBranchId JOIN dbo.Branchmaster tb ON tb.BranchID = t.ToBranchId
     WHERE t.CompanyId = @CompanyId AND ((@Dir IN ('ALL', 'IN') AND t.ToBranchId = @BranchId) OR (@Dir IN ('ALL', 'OUT') AND t.FromBranchId = @BranchId AND t.Status <> 'DRAFT'))
       AND (@Status IS NULL OR t.Status = @Status)
     ORDER BY t.TransferId DESC;
END
GO

-- one transfer: 1 header (no row = not found), 2 lines
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_GetTransfer @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from INT = (SELECT FromBranchId FROM dbo.PhTransfer t
                          WHERE t.TransferId = @Id AND t.CompanyId = @CompanyId AND (t.ToBranchId = @BranchId OR (t.FromBranchId = @BranchId AND t.Status <> 'DRAFT')));
    IF @from IS NULL SET @Id = -1;
    SELECT t.TransferId Id, 'TRANSFER' Kind, t.RequestNo DocNo, ISNULL(t.RequestDate, t.CreatedDate) DocDate, t.Status, t.Remarks, t.FromBranchId, t.ToBranchId,
           fb.BranchName FromBranch, tb.BranchName ToBranch, t.TransferNo, t.DispatchDate, t.ReceiveDate, t.Priority, t.IsOtherGstin, t.DispatchRemarks, t.ReceiveRemarks, t.CostValue, t.VarianceValue,
           t.CreatedBy, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = t.CreatedBy) CreatedByName, t.CreatedDate
      FROM dbo.PhTransfer t JOIN dbo.Branchmaster fb ON fb.BranchID = t.FromBranchId JOIN dbo.Branchmaster tb ON tb.BranchID = t.ToBranchId
     WHERE t.TransferId = @Id;
    SELECT x.TransferDtlId LineId, x.ItemId, i.ItemName, i.ItemCode, df.ShortName FormShort, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
           x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.RequestQty Qty, x.DispatchQty, x.ReceivedQty, x.UnitCost, x.VarianceReason Remarks,
           ISNULL((SELECT SUM(QtyOnHand) FROM dbo.PhStock s WHERE s.BranchId = @from AND s.ItemId = x.ItemId), 0) Stock
      FROM dbo.PhTransferDtl x JOIN dbo.PhItem i ON i.ItemId = x.ItemId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
      LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId LEFT JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
     WHERE x.TransferId = @Id ORDER BY i.ItemName, b.ExpiryDate;
END
GO

-- @Lines: [{ "ItemId", "Qty" }] (checked in EMR.Web). Answers Id, Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_SaveTransferRequest
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @FromBranchId INT, @Priority VARCHAR(10), @Remarks NVARCHAR(4000) = NULL, @Submit BIT, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @Priority = CASE WHEN @Priority = 'URGENT' THEN 'URGENT' ELSE 'NORMAL' END;
    BEGIN TRY
        BEGIN TRAN;
        IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @FromBranchId AND CompanyId = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId))
        BEGIN ROLLBACK; SELECT 0 AS Id, N'That branch is not of this company.' AS Error; RETURN; END;
        DECLARE @otherGstin BIT = (SELECT CAST(CASE WHEN ISNULL(NULLIF(a.G, ''), '#') <> ISNULL(NULLIF(b.G, ''), '#') THEN 1 ELSE 0 END AS BIT) FROM
            (SELECT TOP 1 ISNULL(NULLIF(PharmacyGstin, ''), GSTCode) G FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC) a CROSS JOIN
            (SELECT TOP 1 ISNULL(NULLIF(PharmacyGstin, ''), GSTCode) G FROM dbo.HospitalSettings WHERE BranchId = @FromBranchId ORDER BY IsActive DESC) b);
        SET @otherGstin = ISNULL(@otherGstin, 0);
        IF @Id > 0
        BEGIN
            IF ISNULL((SELECT Status FROM dbo.PhTransfer WITH (UPDLOCK) WHERE TransferId = @Id AND ToBranchId = @BranchId), '') <> 'DRAFT'
            BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a draft indent can be changed.' AS Error; RETURN; END;
            UPDATE dbo.PhTransfer SET FromBranchId = @FromBranchId, Priority = @Priority, Remarks = @Remarks, IsOtherGstin = @otherGstin WHERE TransferId = @Id;
            DELETE dbo.PhTransferDtl WHERE TransferId = @Id;
        END
        ELSE
        BEGIN
            INSERT dbo.PhTransfer (CompanyId, ToBranchId, FromBranchId, Priority, Remarks, IsOtherGstin, CreatedBy) VALUES (@CompanyId, @BranchId, @FromBranchId, @Priority, @Remarks, @otherGstin, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        INSERT dbo.PhTransferDtl (TransferId, ItemId, RequestQty)
        SELECT @Id, i.ItemId, l.Qty FROM OPENJSON(@Lines) WITH (ItemId INT, Qty DECIMAL(14,3)) l JOIN dbo.PhItem i ON i.ItemId = l.ItemId AND i.CompanyId = @CompanyId;
        IF @Submit = 1
        BEGIN
            DECLARE @no NVARCHAR(40);
            DECLARE @tdy DATE = CAST(GETDATE() AS DATE);
            EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'BIND', @DocDate = @tdy, @DocNo = @no OUTPUT;
            UPDATE dbo.PhTransfer SET Status = 'REQUESTED', RequestNo = @no, RequestDate = GETDATE() WHERE TransferId = @Id;
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

-- @Lines: [{ "BatchId", "DispatchQty" }] (above zero, from EMR.Web). Answers Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Dispatch @CompanyId INT, @BranchId INT, @UserId INT, @Id INT, @Remarks NVARCHAR(4000) = NULL, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @L TABLE (Seq INT PRIMARY KEY, BatchId INT, DispatchQty DECIMAL(18,6), ItemId INT, UnitCost DECIMAL(12,4), Exp DATE, Blocked BIT);
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @from INT;
        SELECT @status = Status, @from = FromBranchId FROM dbo.PhTransfer WITH (UPDLOCK) WHERE TransferId = @Id AND CompanyId = @CompanyId;
        IF ISNULL(@status, '') <> 'REQUESTED' OR @from <> @BranchId
        BEGIN ROLLBACK; SELECT N'Only an indent asked of this branch, not yet sent, can be dispatched.' AS Error; RETURN; END;
        DECLARE @Req TABLE (ItemId INT PRIMARY KEY, Qty DECIMAL(18,6));
        INSERT @Req SELECT ItemId, SUM(RequestQty) FROM dbo.PhTransferDtl WHERE TransferId = @Id GROUP BY ItemId;
        INSERT @L (Seq, BatchId, DispatchQty, ItemId, UnitCost, Exp, Blocked)
        SELECT CAST(j.[key] AS INT), JSON_VALUE(j.value, '$.BatchId'), JSON_VALUE(j.value, '$.DispatchQty'), b.ItemId, b.LandedCost, b.ExpiryDate, b.IsBlocked
          FROM OPENJSON(@Lines) j LEFT JOIN dbo.PhBatch b ON b.BatchId = JSON_VALUE(j.value, '$.BatchId') AND b.CompanyId = @CompanyId;
        -- per line in order: batch of an item on the indent, then not expired / blocked
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @L), @bad1 BIT, @bad2 BIT;
        WHILE @seq IS NOT NULL
        BEGIN
            SELECT @bad1 = CASE WHEN l.ItemId IS NULL OR r.ItemId IS NULL THEN 1 ELSE 0 END,
                   @bad2 = CASE WHEN l.Blocked = 1 OR l.Exp <= CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END
              FROM @L l LEFT JOIN @Req r ON r.ItemId = l.ItemId WHERE l.Seq = @seq;
            IF @bad1 = 1 BEGIN ROLLBACK; SELECT N'A batch is not of an item on this indent.' AS Error; RETURN; END;
            IF @bad2 = 1 BEGIN ROLLBACK; SELECT N'An expired or blocked batch cannot be sent.' AS Error; RETURN; END;
            SET @seq = (SELECT MIN(Seq) FROM @L WHERE Seq > @seq);
        END
        IF EXISTS (SELECT 1 FROM (SELECT ItemId, SUM(DispatchQty) Q FROM @L GROUP BY ItemId) g JOIN @Req r ON r.ItemId = g.ItemId WHERE g.Q > r.Qty)
        BEGIN ROLLBACK; SELECT N'More is being sent than was asked for.' AS Error; RETURN; END;
        DECLARE @no NVARCHAR(40);
        DECLARE @tdy DATE = CAST(GETDATE() AS DATE);
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'TRF', @DocDate = @tdy, @DocNo = @no OUTPUT;
        -- the request lines stay (one per item); the batches sent are added
        DELETE dbo.PhTransferDtl WHERE TransferId = @Id AND RequestQty = 0;
        DECLARE @b INT, @q DECIMAL(14,3), @mq DECIMAL(14,3);
        SET @seq = (SELECT MIN(Seq) FROM @L);
        WHILE @seq IS NOT NULL
        BEGIN
            INSERT dbo.PhTransferDtl (TransferId, ItemId, RequestQty, BatchId, DispatchQty, UnitCost) SELECT @Id, ItemId, 0, BatchId, DispatchQty, UnitCost FROM @L WHERE Seq = @seq;
            SELECT @b = BatchId, @q = DispatchQty FROM @L WHERE Seq = @seq;
            SET @mq = -@q;
            EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @mq, @DocType = 'TRFO', @DocId = @Id, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0;
            SET @seq = (SELECT MIN(Seq) FROM @L WHERE Seq > @seq);
        END
        UPDATE dbo.PhTransfer SET Status = 'DISPATCHED', TransferNo = @no, DispatchDate = GETDATE(), DispatchedBy = @UserId, DispatchRemarks = @Remarks,
               CostValue = (SELECT ROUND(SUM(CAST(DispatchQty AS DECIMAL(38,18)) * UnitCost), 2) FROM @L)
         WHERE TransferId = @Id;
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

-- @Received: [{ "LineId", "Qty", "Reason" }] - lines not given are taken as received in full. Answers Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Receive @CompanyId INT, @BranchId INT, @UserId INT, @Id INT, @Remarks NVARCHAR(4000) = NULL, @Received NVARCHAR(MAX) = N'[]'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @R TABLE (LineId INT PRIMARY KEY, Qty DECIMAL(18,6), HasQty BIT, Reason NVARCHAR(4000));
    INSERT @R SELECT JSON_VALUE(value, '$.LineId'), JSON_VALUE(value, '$.Qty'), CASE WHEN JSON_VALUE(value, '$.Qty') IS NULL THEN 0 ELSE 1 END,
                     NULLIF(LTRIM(RTRIM(JSON_VALUE(value, '$.Reason'))), N'')
                FROM OPENJSON(ISNULL(@Received, N'[]'));
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @to INT, @no NVARCHAR(40);
        SELECT @status = Status, @to = ToBranchId, @no = TransferNo FROM dbo.PhTransfer WITH (UPDLOCK) WHERE TransferId = @Id AND CompanyId = @CompanyId;
        IF ISNULL(@status, '') <> 'DISPATCHED' OR @to <> @BranchId BEGIN ROLLBACK; SELECT N'Only a transfer sent to this branch can be received.' AS Error; RETURN; END;
        DECLARE @S TABLE (Rn INT IDENTITY PRIMARY KEY, DtlId INT, BatchId INT, Qty DECIMAL(14,3), Cost DECIMAL(12,4));
        INSERT @S (DtlId, BatchId, Qty, Cost) SELECT TransferDtlId, BatchId, DispatchQty, UnitCost FROM dbo.PhTransferDtl WHERE TransferId = @Id AND DispatchQty > 0 ORDER BY TransferDtlId;
        DECLARE @rn INT = (SELECT MIN(Rn) FROM @S), @dtl INT, @b INT, @sent DECIMAL(14,3), @cost DECIMAL(12,4), @got DECIMAL(18,6), @why NVARCHAR(4000), @variance DECIMAL(38,8) = 0;
        WHILE @rn IS NOT NULL
        BEGIN
            SELECT @dtl = DtlId, @b = BatchId, @sent = Qty, @cost = Cost FROM @S WHERE Rn = @rn;
            SELECT @got = @sent, @why = NULL;
            SELECT @got = CASE WHEN HasQty = 1 THEN Qty ELSE @sent END, @why = Reason FROM @R WHERE LineId = @dtl;
            IF @got < 0 OR @got > @sent BEGIN ROLLBACK; SELECT N'Received quantity cannot be more than what was sent.' AS Error; RETURN; END;
            IF @got < @sent AND @why IS NULL BEGIN ROLLBACK; SELECT N'Give the reason for every quantity received short (broken, missing ...).' AS Error; RETURN; END;
            UPDATE dbo.PhTransferDtl SET ReceivedQty = @got, VarianceReason = @why WHERE TransferDtlId = @dtl;
            IF @got > 0 EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @got, @DocType = 'TRFI', @DocId = @Id, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0;
            SET @variance = @variance + (@sent - @got) * @cost;
            SET @rn = (SELECT MIN(Rn) FROM @S WHERE Rn > @rn);
        END
        UPDATE dbo.PhTransfer SET Status = 'RECEIVED', ReceiveDate = GETDATE(), ReceivedBy = @UserId, ReceiveRemarks = @Remarks, VarianceValue = ROUND(@variance, 2) WHERE TransferId = @Id;
        EXEC dbo.usp_Ph_PostInventoryLedger @Kind = 'TRFLOSS', @RefId = @Id, @UserId = @UserId;
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

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_CancelTransfer @CompanyId INT, @BranchId INT, @UserId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PhTransfer SET Status = 'CANCELLED', CancelledBy = @UserId, CancelledDate = GETDATE()
     WHERE TransferId = @Id AND CompanyId = @CompanyId AND Status IN ('DRAFT', 'REQUESTED') AND (ToBranchId = @BranchId OR FromBranchId = @BranchId);
    SELECT CASE WHEN @@ROWCOUNT = 0 THEN N'Only an indent not yet sent can be cancelled.' END AS Error;
END
GO

-- ── adjustment / write-off ───────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Adjustments @CompanyId INT, @BranchId INT, @Kind VARCHAR(10), @Status VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 500 a.AdjustmentId Id, a.DocNo, a.DocDate, a.Status, r.ReasonName Party, a.Remarks Ref,
           (SELECT COUNT(*) FROM dbo.PhAdjustmentDtl d WHERE d.AdjustmentId = a.AdjustmentId) Lines,
           ISNULL((SELECT SUM(d.QtyChange * d.UnitCost) FROM dbo.PhAdjustmentDtl d WHERE d.AdjustmentId = a.AdjustmentId), 0) Value,
           a.CreatedBy, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = a.CreatedBy) CreatedByName
      FROM dbo.PhAdjustment a LEFT JOIN dbo.PhReason r ON r.ReasonId = a.ReasonId
     WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId AND a.Kind = @Kind AND (@Status IS NULL OR a.Status = @Status) ORDER BY a.AdjustmentId DESC;
END
GO

-- one adjustment: 1 header (no row = not found), 2 lines
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_GetAdjustment @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhAdjustment WHERE AdjustmentId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId) SET @Id = -1;
    SELECT a.AdjustmentId Id, a.Kind, a.DocNo, a.DocDate, a.Status, a.ReasonId, r.ReasonName, a.Remarks, a.ActionRemarks, a.DisposalMethod, a.DisposalAgency,
           a.DisposalDate, a.Witness1, a.Witness2, a.CertificateNo, a.PlusValue, a.MinusValue, a.CreatedBy,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = a.CreatedBy) CreatedByName, a.CreatedDate,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = a.ApprovedBy) ApprovedByName, a.ApprovedDate
      FROM dbo.PhAdjustment a LEFT JOIN dbo.PhReason r ON r.ReasonId = a.ReasonId WHERE a.AdjustmentId = @Id;
    SELECT x.AdjustmentDtlId LineId, x.ItemId, i.ItemName, i.ItemCode, df.ShortName FormShort, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
           x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.QtyChange Qty, x.UnitCost, x.Remarks, ISNULL(s.QtyOnHand, 0) Stock
      FROM dbo.PhAdjustmentDtl x JOIN dbo.PhItem i ON i.ItemId = x.ItemId JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
      LEFT JOIN dbo.PhStock s ON s.BatchId = x.BatchId AND s.BranchId = @BranchId WHERE x.AdjustmentId = @Id ORDER BY x.AdjustmentDtlId;
END
GO

-- @Lines: [{ "BatchId", "Qty" (change, - out), "Remarks" }] (write-off already made negative in EMR.Web). Answers Id, Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_SaveAdjustment
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @Kind VARCHAR(10), @DocDate DATE, @ReasonId INT, @Remarks NVARCHAR(4000) = NULL, @DisposalMethod NVARCHAR(4000) = NULL,
    @DisposalAgency NVARCHAR(4000) = NULL, @DisposalDate DATE = NULL, @Witness1 NVARCHAR(4000) = NULL, @Witness2 NVARCHAR(4000) = NULL, @CertificateNo NVARCHAR(4000) = NULL, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @L TABLE (Seq INT PRIMARY KEY, BatchId INT, Qty DECIMAL(18,6), Remarks NVARCHAR(4000), ItemId INT, Cost DECIMAL(12,4), Stock DECIMAL(14,3));
    BEGIN TRY
        BEGIN TRAN;
        INSERT @L (Seq, BatchId, Qty, Remarks, ItemId, Cost, Stock)
        SELECT CAST(j.[key] AS INT), JSON_VALUE(j.value, '$.BatchId'), JSON_VALUE(j.value, '$.Qty'), JSON_VALUE(j.value, '$.Remarks'), b.ItemId, b.LandedCost, ISNULL(s.QtyOnHand, 0)
          FROM OPENJSON(@Lines) j
          LEFT JOIN dbo.PhBatch b ON b.BatchId = JSON_VALUE(j.value, '$.BatchId') AND b.CompanyId = @CompanyId
          LEFT JOIN dbo.PhStock s ON s.BatchId = b.BatchId AND s.BranchId = @BranchId;
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @L), @item INT, @qty DECIMAL(18,6), @stock DECIMAL(14,3);
        WHILE @seq IS NOT NULL
        BEGIN
            SELECT @item = ItemId, @qty = Qty, @stock = Stock FROM @L WHERE Seq = @seq;
            IF @item IS NULL BEGIN ROLLBACK; SELECT 0 AS Id, N'A batch was not found.' AS Error; RETURN; END;
            IF @qty < 0 AND -@qty > @stock
            BEGIN ROLLBACK; SELECT 0 AS Id, N'A batch has only ' + FORMAT(@stock, '0.##') + N' in stock; it cannot go below zero.' AS Error; RETURN; END;
            SET @seq = (SELECT MIN(Seq) FROM @L WHERE Seq > @seq);
        END
        IF @Id > 0
        BEGIN
            IF ISNULL((SELECT Status FROM dbo.PhAdjustment WITH (UPDLOCK) WHERE AdjustmentId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId AND Kind = @Kind), '') <> 'DRAFT'
            BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a draft can be changed.' AS Error; RETURN; END;
            UPDATE dbo.PhAdjustment SET DocDate = @DocDate, ReasonId = @ReasonId, Remarks = @Remarks, DisposalMethod = @DisposalMethod, DisposalAgency = @DisposalAgency, DisposalDate = @DisposalDate,
                   Witness1 = @Witness1, Witness2 = @Witness2, CertificateNo = @CertificateNo, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE AdjustmentId = @Id;
            DELETE dbo.PhAdjustmentDtl WHERE AdjustmentId = @Id;
        END
        ELSE
        BEGIN
            INSERT dbo.PhAdjustment (CompanyId, BranchId, Kind, DocDate, ReasonId, Remarks, DisposalMethod, DisposalAgency, DisposalDate, Witness1, Witness2, CertificateNo, CreatedBy)
            VALUES (@CompanyId, @BranchId, @Kind, @DocDate, @ReasonId, @Remarks, @DisposalMethod, @DisposalAgency, @DisposalDate, @Witness1, @Witness2, @CertificateNo, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        INSERT dbo.PhAdjustmentDtl (AdjustmentId, BatchId, ItemId, QtyChange, UnitCost, Remarks) SELECT @Id, BatchId, ItemId, Qty, Cost, Remarks FROM @L ORDER BY Seq;
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_AdjustmentAction @CompanyId INT, @BranchId INT, @UserId INT, @Id INT, @Action VARCHAR(10), @Remarks NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @kind VARCHAR(10), @maker INT, @method NVARCHAR(100), @ddate DATE, @w1 NVARCHAR(100), @no NVARCHAR(40);
        SELECT @status = Status, @kind = Kind, @maker = CreatedBy, @method = DisposalMethod, @ddate = DisposalDate, @w1 = Witness1
          FROM dbo.PhAdjustment WITH (UPDLOCK) WHERE AdjustmentId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL BEGIN ROLLBACK; SELECT N'Not found.' AS Error; RETURN; END;
        IF @Action = 'submit'
        BEGIN
            IF @status <> 'DRAFT' BEGIN ROLLBACK; SELECT N'Only a draft can be submitted.' AS Error; RETURN; END;
            IF @kind = 'WRITEOFF' AND (LTRIM(RTRIM(ISNULL(@method, N''))) = N'' OR @ddate IS NULL OR LTRIM(RTRIM(ISNULL(@w1, N''))) = N'')
            BEGIN ROLLBACK; SELECT N'Enter how and when the stock is destroyed and at least one witness before submitting.' AS Error; RETURN; END;
            DECLARE @dt VARCHAR(10) = CASE WHEN @kind = 'WRITEOFF' THEN 'WOF' ELSE 'ADJ' END;
            DECLARE @tdy DATE = CAST(GETDATE() AS DATE);
            EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = @dt, @DocDate = @tdy, @DocNo = @no OUTPUT;
            UPDATE dbo.PhAdjustment SET Status = 'SUBMITTED', DocNo = @no, SubmittedBy = @UserId, SubmittedDate = GETDATE() WHERE AdjustmentId = @Id;
        END
        ELSE IF @Action = 'approve'
        BEGIN
            IF @status <> 'SUBMITTED' BEGIN ROLLBACK; SELECT N'Only a submitted document can be approved.' AS Error; RETURN; END;
            IF @maker = @UserId BEGIN ROLLBACK; SELECT N'You made this document; another user must approve it.' AS Error; RETURN; END;
            SET @no = (SELECT DocNo FROM dbo.PhAdjustment WHERE AdjustmentId = @Id);
            DECLARE @mt VARCHAR(10) = CASE WHEN @kind = 'WRITEOFF' THEN 'WOF' ELSE 'ADJ' END;
            DECLARE @A TABLE (Rn INT IDENTITY PRIMARY KEY, BatchId INT, Qty DECIMAL(14,3), Cost DECIMAL(12,4));
            INSERT @A (BatchId, Qty, Cost) SELECT BatchId, QtyChange, UnitCost FROM dbo.PhAdjustmentDtl WHERE AdjustmentId = @Id ORDER BY AdjustmentDtlId;
            DECLARE @rn INT = (SELECT MIN(Rn) FROM @A), @b INT, @q DECIMAL(14,3);
            WHILE @rn IS NOT NULL
            BEGIN
                SELECT @b = BatchId, @q = Qty FROM @A WHERE Rn = @rn;
                EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @q, @DocType = @mt, @DocId = @Id, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0;
                SET @rn = (SELECT MIN(Rn) FROM @A WHERE Rn > @rn);
            END
            UPDATE dbo.PhAdjustment SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedDate = GETDATE(), ActionRemarks = @Remarks,
                   PlusValue = ISNULL((SELECT ROUND(SUM(CAST(Qty AS DECIMAL(38,18)) * Cost), 2) FROM @A WHERE Qty > 0), 0),
                   MinusValue = ISNULL((SELECT ROUND(-SUM(CAST(Qty AS DECIMAL(38,18)) * Cost), 2) FROM @A WHERE Qty < 0), 0)
             WHERE AdjustmentId = @Id;
            EXEC dbo.usp_Ph_PostInventoryLedger @Kind = 'ADJ', @RefId = @Id, @UserId = @UserId;
        END
        ELSE IF @Action = 'reject'
        BEGIN
            IF @status <> 'SUBMITTED' BEGIN ROLLBACK; SELECT N'Only a submitted document can be rejected.' AS Error; RETURN; END;
            IF @maker = @UserId BEGIN ROLLBACK; SELECT N'You made this document; another user must decide on it.' AS Error; RETURN; END;
            IF LTRIM(RTRIM(ISNULL(@Remarks, N''))) = N'' BEGIN ROLLBACK; SELECT N'Give the reason for rejecting.' AS Error; RETURN; END;
            UPDATE dbo.PhAdjustment SET Status = 'REJECTED', ApprovedBy = @UserId, ApprovedDate = GETDATE(), ActionRemarks = @Remarks WHERE AdjustmentId = @Id;
        END
        ELSE IF @Action = 'cancel'
        BEGIN
            IF @status NOT IN ('DRAFT', 'SUBMITTED') BEGIN ROLLBACK; SELECT N'Only a draft or submitted document can be cancelled.' AS Error; RETURN; END;
            UPDATE dbo.PhAdjustment SET Status = 'CANCELLED', ActionRemarks = ISNULL(@Remarks, ActionRemarks), ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE AdjustmentId = @Id;
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

-- ── physical stock verification ──────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Counts @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 200 c.StockCountId Id, c.CountNo DocNo, c.FrozenAt DocDate, c.Status, c.Scope Party, c.Remarks Ref,
           (SELECT COUNT(*) FROM dbo.PhStockCountDtl d WHERE d.StockCountId = c.StockCountId) Lines,
           ISNULL((SELECT SUM((d.CountedQty - d.SystemQty) * d.UnitCost) FROM dbo.PhStockCountDtl d WHERE d.StockCountId = c.StockCountId AND d.CountedQty IS NOT NULL), 0) Value,
           c.CreatedBy, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.CreatedBy) CreatedByName
      FROM dbo.PhStockCount c WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId ORDER BY c.StockCountId DESC;
END
GO

-- one verification: 1 header (no row = not found), 2 lines
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_GetCount @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhStockCount WHERE StockCountId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId) SET @Id = -1;
    SELECT c.StockCountId Id, 'COUNT' Kind, c.CountNo DocNo, c.FrozenAt DocDate, c.FrozenAt, c.Scope, c.Status, c.Remarks, c.ActionRemarks, c.AdjustmentId,
           c.CreatedBy, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.CreatedBy) CreatedByName, c.CreatedDate,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.ApprovedBy) ApprovedByName, c.ApprovedDate
      FROM dbo.PhStockCount c WHERE c.StockCountId = @Id;
    SELECT x.StockCountDtlId LineId, x.ItemId, i.ItemName, i.ItemCode, df.ShortName FormShort, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
           x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.RackNo, x.SystemQty, x.CountedQty, x.UnitCost, x.Remarks, ISNULL(s.QtyOnHand, 0) Stock
      FROM dbo.PhStockCountDtl x JOIN dbo.PhItem i ON i.ItemId = x.ItemId JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
      LEFT JOIN dbo.PhStock s ON s.BatchId = x.BatchId AND s.BranchId = @BranchId
     WHERE x.StockCountId = @Id ORDER BY ISNULL(x.RackNo, 'zzz'), i.ItemName, b.ExpiryDate;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_CreateCount
    @CompanyId INT, @BranchId INT, @UserId INT, @RackPrefix NVARCHAR(30) = NULL, @CategoryId INT = NULL, @IncludeZero BIT = 0, @Remarks NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF EXISTS (SELECT 1 FROM dbo.PhStockCount WHERE BranchId = @BranchId AND Status IN ('COUNTING', 'SUBMITTED'))
        BEGIN ROLLBACK; SELECT 0 AS Id, N'A verification of this branch is still open; finish or cancel it first.' AS Error; RETURN; END;
        SET @RackPrefix = UPPER(NULLIF(LTRIM(RTRIM(@RackPrefix)), N''));
        DECLARE @scope NVARCHAR(400) = CONCAT_WS(N' · ',
            CASE WHEN @RackPrefix IS NOT NULL THEN N'racks ' + @RackPrefix + N'*' END,
            CASE WHEN @CategoryId IS NOT NULL THEN N'category ' + ISNULL((SELECT CategoryName FROM dbo.PhCategory WHERE CategoryId = @CategoryId), N'') END,
            CASE WHEN @IncludeZero = 1 THEN N'including zero stock' END);
        DECLARE @no NVARCHAR(40), @id INT;
        DECLARE @tdy DATE = CAST(GETDATE() AS DATE);
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'PCNT', @DocDate = @tdy, @DocNo = @no OUTPUT;
        INSERT dbo.PhStockCount (CompanyId, BranchId, CountNo, FrozenAt, Scope, Status, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @no, GETDATE(), CASE WHEN LEN(@scope) = 0 THEN N'All stock' ELSE @scope END, 'COUNTING', @Remarks, @UserId);
        SET @id = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.PhStockCountDtl (StockCountId, BatchId, ItemId, RackNo, SystemQty, UnitCost)
        SELECT @id, s.BatchId, s.ItemId, ib.RackNo, s.QtyOnHand, b.LandedCost
          FROM dbo.PhStock s WITH (HOLDLOCK) JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = s.ItemId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
          LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = s.ItemId AND ib.BranchId = s.BranchId
         WHERE s.BranchId = @BranchId AND b.CompanyId = @CompanyId AND (@IncludeZero = 1 OR s.QtyOnHand <> 0)
           AND (@RackPrefix IS NULL OR ib.RackNo LIKE @RackPrefix + '%') AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId);
        IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Nothing in stock matches; widen the selection.' AS Error; RETURN; END;
        COMMIT;
        SELECT @id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

-- @Counts: [{ "LineId", "Qty" (null = not counted) }] (not negative, checked in EMR.Web). Answers Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_SaveCounts @CompanyId INT, @BranchId INT, @Id INT, @Counts NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    IF ISNULL((SELECT Status FROM dbo.PhStockCount WITH (UPDLOCK) WHERE StockCountId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'COUNTING'
    BEGIN ROLLBACK; SELECT N'Counts can be entered only while the verification is open.' AS Error; RETURN; END;
    UPDATE d SET CountedQty = j.Qty
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
        DECLARE @status VARCHAR(10), @maker INT, @no NVARCHAR(40), @uncounted INT;
        SELECT @status = Status, @maker = CreatedBy, @no = CountNo,
               @uncounted = (SELECT COUNT(*) FROM dbo.PhStockCountDtl d WHERE d.StockCountId = c.StockCountId AND d.CountedQty IS NULL)
          FROM dbo.PhStockCount c WITH (UPDLOCK) WHERE StockCountId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL BEGIN ROLLBACK; SELECT N'Not found.' AS Error; RETURN; END;
        IF @Action = 'submit'
        BEGIN
            IF @status <> 'COUNTING' BEGIN ROLLBACK; SELECT N'Only an open verification can be submitted.' AS Error; RETURN; END;
            IF @uncounted > 0 BEGIN ROLLBACK; SELECT CAST(@uncounted AS NVARCHAR(10)) + N' batch(es) are not counted yet. Enter a count for every line (0 if none found).' AS Error; RETURN; END;
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
                INSERT dbo.PhAdjustment (CompanyId, BranchId, Kind, DocNo, DocDate, ReasonId, Status, Remarks, StockCountId, CreatedBy, SubmittedBy, SubmittedDate)
                VALUES (@CompanyId, @BranchId, 'PHYSICAL', @no, CAST(GETDATE() AS DATE), @reason, 'SUBMITTED', N'Physical stock verification ' + @no, @Id, @maker, @maker, GETDATE());
                SET @adjId = CAST(SCOPE_IDENTITY() AS INT);
                INSERT dbo.PhAdjustmentDtl (AdjustmentId, BatchId, ItemId, QtyChange, UnitCost) SELECT @adjId, BatchId, ItemId, Diff, Cost FROM @D ORDER BY Rn;
                DECLARE @rn INT = (SELECT MIN(Rn) FROM @D), @b INT, @q DECIMAL(14,3);
                WHILE @rn IS NOT NULL
                BEGIN
                    SELECT @b = BatchId, @q = Diff FROM @D WHERE Rn = @rn;
                    EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @q, @DocType = 'PCNT', @DocId = @Id, @DocNo = @no, @UserId = @UserId, @AllowNegative = 0;
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

-- ── batch correction ─────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Corrections @CompanyId INT, @BranchId INT, @Status VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 300 c.CorrectionId, c.DocNo, c.CreatedDate, i.ItemName, c.OldBatchNo, c.NewBatchNo, c.OldExpiry, c.NewExpiry, c.OldMrp, c.NewMrp, c.Reason, c.Status,
           c.ActionRemarks, c.CreatedBy, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.CreatedBy) CreatedByName,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = c.ApprovedBy) ApprovedByName
      FROM dbo.PhBatchCorrection c JOIN dbo.PhBatch b ON b.BatchId = c.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId
     WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId AND (@Status IS NULL OR c.Status = @Status) ORDER BY c.CorrectionId DESC;
END
GO

-- new values checked and the expiry set to month end in EMR.Web. Answers Id, Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_SaveCorrection
    @CompanyId INT, @BranchId INT, @UserId INT, @BatchId INT, @NewBatchNo NVARCHAR(30), @NewExpiry DATE, @NewMrp DECIMAL(12,2), @Reason NVARCHAR(4000)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @item INT, @bno NVARCHAR(30), @exp DATE, @mrp DECIMAL(12,2), @rate DECIMAL(12,4), @gst DECIMAL(5,2);
        SELECT @item = ItemId, @bno = BatchNo, @exp = ExpiryDate, @mrp = Mrp, @rate = PurchaseRate, @gst = GstPercent FROM dbo.PhBatch WHERE BatchId = @BatchId AND CompanyId = @CompanyId;
        IF @bno IS NULL BEGIN ROLLBACK; SELECT 0 AS Id, N'Batch not found.' AS Error; RETURN; END;
        IF @bno = @NewBatchNo AND @exp = @NewExpiry AND @mrp = @NewMrp BEGIN ROLLBACK; SELECT 0 AS Id, N'Nothing is changed.' AS Error; RETURN; END;
        DECLARE @costGst DECIMAL(38,18) = CAST(@rate AS DECIMAL(38,18)) * (1 + CAST(@gst AS DECIMAL(38,18)) / 100);
        IF @NewMrp < @costGst BEGIN ROLLBACK; SELECT 0 AS Id, N'The new MRP is below the purchase cost with GST (₹' + FORMAT(@costGst, '0.00') + N').' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM dbo.PhBatchCorrection WHERE BatchId = @BatchId AND Status = 'SUBMITTED')
        BEGIN ROLLBACK; SELECT 0 AS Id, N'A correction of this batch is already waiting for approval.' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM dbo.PhBatch WHERE ItemId = @item AND BatchNo = @NewBatchNo AND Mrp = @NewMrp AND BatchId <> @BatchId)
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Another batch of this item already has that batch number and MRP.' AS Error; RETURN; END;
        DECLARE @no NVARCHAR(40), @id INT;
        DECLARE @tdy DATE = CAST(GETDATE() AS DATE);
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'BCOR', @DocDate = @tdy, @DocNo = @no OUTPUT;
        INSERT dbo.PhBatchCorrection (CompanyId, BranchId, DocNo, BatchId, OldBatchNo, NewBatchNo, OldExpiry, NewExpiry, OldMrp, NewMrp, Reason, CreatedBy)
        VALUES (@CompanyId, @BranchId, @no, @BatchId, @bno, @NewBatchNo, @exp, @NewExpiry, @mrp, @NewMrp, LTRIM(RTRIM(@Reason)), @UserId);
        SET @id = CAST(SCOPE_IDENTITY() AS INT);
        COMMIT;
        SELECT @id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_CorrectionAction @CompanyId INT, @BranchId INT, @UserId INT, @Id INT, @Action VARCHAR(10), @Remarks NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DECLARE @status VARCHAR(10), @maker INT, @batch INT, @nb NVARCHAR(30), @ne DATE, @nm DECIMAL(12,2), @ob NVARCHAR(30), @oe DATE, @om DECIMAL(12,2);
    SELECT @status = Status, @maker = CreatedBy, @batch = BatchId, @nb = NewBatchNo, @ne = NewExpiry, @nm = NewMrp, @ob = OldBatchNo, @oe = OldExpiry, @om = OldMrp
      FROM dbo.PhBatchCorrection WITH (UPDLOCK) WHERE CorrectionId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId;
    IF ISNULL(@status, '') <> 'SUBMITTED' BEGIN ROLLBACK; SELECT N'Only a correction waiting for approval can be decided.' AS Error; RETURN; END;
    IF @maker = @UserId BEGIN ROLLBACK; SELECT N'You asked for this correction; another user must decide on it.' AS Error; RETURN; END;
    IF @Action = 'reject'
    BEGIN
        IF LTRIM(RTRIM(ISNULL(@Remarks, N''))) = N'' BEGIN ROLLBACK; SELECT N'Give the reason for rejecting.' AS Error; RETURN; END;
        UPDATE dbo.PhBatchCorrection SET Status = 'REJECTED', ApprovedBy = @UserId, ApprovedDate = GETDATE(), ActionRemarks = @Remarks WHERE CorrectionId = @Id;
    END
    ELSE IF @Action = 'approve'
    BEGIN
        -- the batch must still be as it was when the correction was asked
        UPDATE dbo.PhBatch SET BatchNo = @nb, ExpiryDate = @ne, Mrp = @nm WHERE BatchId = @batch AND BatchNo = @ob AND ExpiryDate = @oe AND Mrp = @om;
        IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT N'The batch was changed since this correction was asked; ask again.' AS Error; RETURN; END;
        UPDATE dbo.PhBatchCorrection SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedDate = GETDATE(), ActionRemarks = @Remarks WHERE CorrectionId = @Id;
    END
    ELSE BEGIN ROLLBACK; SELECT N'Unknown action.' AS Error; RETURN; END;
    COMMIT;
    SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
END
GO

-- ── approvals ────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Maker @Table VARCHAR(10), @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ISNULL(CASE @Table
        WHEN 'adj'   THEN (SELECT CreatedBy FROM dbo.PhAdjustment WHERE AdjustmentId = @Id)
        WHEN 'count' THEN (SELECT CreatedBy FROM dbo.PhStockCount WHERE StockCountId = @Id)
        WHEN 'corr'  THEN (SELECT CreatedBy FROM dbo.PhBatchCorrection WHERE CorrectionId = @Id) END, 0) AS Maker;
END
GO

-- approvers named in the Approval Matrix for this module (branch-wise matrix first, else company-wise); none = no matrix
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_MatrixApprovers @CompanyId INT, @ModuleCode VARCHAR(50), @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.UserId FROM dbo.ApprovalMatrixApprover a WHERE a.Matrix_ID = (
        SELECT TOP 1 m.Matrix_ID FROM dbo.ApprovalMatrix m JOIN dbo.ApprovalModule am ON am.Module_Code = m.Module_Code AND am.IsActive = 1
         WHERE m.CompanyId = @CompanyId AND m.Module_Code = @ModuleCode AND m.IsActive = 1 AND (m.Scope = 'C' OR m.Branch_ID = @BranchId)
           AND EXISTS (SELECT 1 FROM dbo.ApprovalMatrixApprover x WHERE x.Matrix_ID = m.Matrix_ID)
         ORDER BY CASE m.Scope WHEN 'B' THEN 0 ELSE 1 END);
END
GO

-- ── dashboard: 1 figures, 2 to reorder, 3 below reorder / out of stock / supplier due, 4 top items, 5 last 7 days (near expiry: usp_Api_PhInv_Stock 'near') ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhInv_Dashboard @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @month DATE = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1);
    SELECT
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= @today), 0) SalesToday,
      (SELECT COUNT(*) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= @today) BillsToday,
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSaleReturn WHERE BranchId = @BranchId AND ReturnDate >= @today), 0) ReturnsToday,
      ISNULL((SELECT SUM(CASE WHEN pm.MethodCode = 'CASH' THEN pd.PaidAmount END) FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
              WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.BranchId = @BranchId AND pd.IsActive = 1 AND pd.CreatedDate >= @today), 0) CashToday,
      ISNULL((SELECT SUM(CASE WHEN pm.MethodCode <> 'CASH' THEN pd.PaidAmount END) FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
              WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.BranchId = @BranchId AND pd.IsActive = 1 AND pd.CreatedDate >= @today), 0) NonCashToday,
      ISNULL((SELECT SUM(NetAmount - PaidAmount) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= @today AND NetAmount > PaidAmount), 0) CreditToday,
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= @month), 0) SalesMonth,
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhGrn WHERE BranchId = @BranchId AND Status = 'POSTED' AND GrnDate >= @today), 0) PurchasesToday,
      ISNULL((SELECT SUM(NetAmount) FROM dbo.PhGrn WHERE BranchId = @BranchId AND Status = 'POSTED' AND GrnDate >= @month), 0) PurchasesMonth,
      ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0), 0) StockValue,
      ISNULL((SELECT SUM(s.QtyOnHand * b.Mrp / i.ConversionQty) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0), 0) StockMrpValue,
      (SELECT COUNT(DISTINCT ItemId) FROM dbo.PhStock WHERE BranchId = @BranchId AND QtyOnHand > 0) ItemsInStock,
      (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate <= @today) Expired,
      ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate <= @today), 0) ExpiredValue,
      (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > @today AND b.ExpiryDate <= DATEADD(DAY, 30, @today)) Exp30,
      ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > @today AND b.ExpiryDate <= DATEADD(DAY, 30, @today)), 0) Exp30Value,
      (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 30, @today) AND b.ExpiryDate <= DATEADD(DAY, 60, @today)) Exp60,
      ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 30, @today) AND b.ExpiryDate <= DATEADD(DAY, 60, @today)), 0) Exp60Value,
      (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 60, @today) AND b.ExpiryDate <= DATEADD(DAY, 90, @today)) Exp90,
      ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 60, @today) AND b.ExpiryDate <= DATEADD(DAY, 90, @today)), 0) Exp90Value,
      ISNULL((SELECT SUM(BalanceDue) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'POSTED' AND BalanceDue > 0), 0) CreditDue,
      (SELECT COUNT(*) FROM dbo.PhPurchaseIndent WHERE BranchId = @BranchId AND Status = 'SUBMITTED') PendIndents,
      (SELECT COUNT(*) FROM dbo.PhPurchaseOrder WHERE BranchId = @BranchId AND Status IN ('DRAFT', 'APPROVED', 'PARTIAL')) PendPos,
      (SELECT COUNT(*) FROM dbo.PhGrn WHERE BranchId = @BranchId AND Status = 'DRAFT') DraftGrns,
      (SELECT COUNT(*) FROM dbo.PhSale WHERE BranchId = @BranchId AND Status = 'HOLD') HeldBills,
      (SELECT COUNT(*) FROM dbo.PhTransfer WHERE FromBranchId = @BranchId AND Status = 'REQUESTED') ToDispatch,
      (SELECT COUNT(*) FROM dbo.PhTransfer WHERE ToBranchId = @BranchId AND Status = 'DISPATCHED') ToReceive,
      (SELECT COUNT(*) FROM dbo.PhAdjustment WHERE BranchId = @BranchId AND Kind = 'ADJUST' AND Status = 'SUBMITTED') PendAdjust,
      (SELECT COUNT(*) FROM dbo.PhAdjustment WHERE BranchId = @BranchId AND Kind = 'WRITEOFF' AND Status = 'SUBMITTED') PendWriteOff,
      (SELECT COUNT(*) FROM dbo.PhStockCount WHERE BranchId = @BranchId AND Status IN ('COUNTING', 'SUBMITTED')) PendCounts,
      (SELECT COUNT(*) FROM dbo.PhBatchCorrection WHERE BranchId = @BranchId AND Status = 'SUBMITTED') PendCorrections;

    SELECT TOP 15 i.ItemName, ISNULL(st.Qty, 0) / i.ConversionQty AS Stock, ISNULL(ib.ReorderLevel, i.ReorderLevel) AS Reorder, pu.UomCode AS Uom
      FROM dbo.PhItem i JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
      OUTER APPLY (SELECT SUM(QtyOnHand) Qty FROM dbo.PhStock s WHERE s.BranchId = @BranchId AND s.ItemId = i.ItemId) st
     WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 AND ISNULL(ib.IsStocked, 1) = 1 AND ISNULL(ib.ReorderLevel, i.ReorderLevel) > 0
       AND ISNULL(st.Qty, 0) / i.ConversionQty <= ISNULL(ib.ReorderLevel, i.ReorderLevel)
     ORDER BY ISNULL(st.Qty, 0) / i.ConversionQty / NULLIF(ISNULL(ib.ReorderLevel, i.ReorderLevel), 0);

    SELECT
      (SELECT COUNT(*) FROM dbo.PhItem i LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
        WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 AND ISNULL(ib.IsStocked, 1) = 1 AND ISNULL(ib.ReorderLevel, i.ReorderLevel) > 0
          AND ISNULL((SELECT SUM(QtyOnHand) FROM dbo.PhStock s WHERE s.BranchId = @BranchId AND s.ItemId = i.ItemId), 0) / i.ConversionQty <= ISNULL(ib.ReorderLevel, i.ReorderLevel)) AS BelowReorder,
      (SELECT COUNT(*) FROM dbo.PhItem i WHERE i.CompanyId = @CompanyId AND i.IsActive = 1
          AND ISNULL((SELECT SUM(QtyOnHand) FROM dbo.PhStock s WHERE s.BranchId = @BranchId AND s.ItemId = i.ItemId), 0) <= 0
          AND EXISTS (SELECT 1 FROM dbo.PhStockLedger l WHERE l.BranchId = @BranchId AND l.ItemId = i.ItemId)) AS OutOfStock,
      (SELECT ISNULL(SUM(g.NetAmount), 0) - ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment sp ON sp.PaymentId = a.PaymentId WHERE sp.BranchId = @BranchId AND sp.Status = 'POSTED'), 0)
         FROM dbo.PhGrn g WHERE g.BranchId = @BranchId AND g.Status = 'POSTED') AS SupplierDue;

    SELECT TOP 10 i.ItemName, SUM(x.Qty - x.ReturnedQty) AS Qty, SUM(x.Amount * (x.Qty - x.ReturnedQty) / x.Qty) AS Value
      FROM dbo.PhSaleDtl x JOIN dbo.PhSale s ON s.SaleId = x.SaleId JOIN dbo.PhItem i ON i.ItemId = x.ItemId
     WHERE s.BranchId = @BranchId AND s.Status = 'POSTED' AND s.SaleDate >= DATEADD(DAY, -30, GETDATE()) GROUP BY i.ItemName ORDER BY 3 DESC;

    SELECT CAST(SaleDate AS DATE) AS Day, SUM(NetAmount) AS Value FROM dbo.PhSale
     WHERE BranchId = @BranchId AND Status = 'POSTED' AND SaleDate >= DATEADD(DAY, -6, CAST(GETDATE() AS DATE))
     GROUP BY CAST(SaleDate AS DATE) ORDER BY 1;

END
GO

PRINT 'Script 2360 applied: pharmacy inventory - API stored procedures.';
GO
