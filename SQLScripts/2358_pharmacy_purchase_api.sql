-- ============================================================================================================
-- Migration: 2358_pharmacy_purchase_api.sql
-- Pharmacy > Purchase through EMR.Api (API + stored procedures, like LAB / OPD): indent, purchase order, GRN,
-- purchase return, supplier payments, purchase register. Replaces the SQL that EMR.Web/Services/
-- PharmacyPurchaseService.cs ran directly; the checks and amounts worked out in EMR.Web stay there.
--   Saves take their lines as JSON and run in one transaction each, as before.
--   Saves / actions answer one row: Id (or DocNo) and Error (NULL when done); posting keeps 2344 / 2347.
-- No table changes. Run after 2357. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── item details used on purchase documents (stock, reorder level, pending PO, last purchase) ────────────
CREATE OR ALTER FUNCTION dbo.fn_PhTxnItemInfo (@CompanyId INT, @BranchId INT)
RETURNS TABLE
AS
RETURN
    SELECT i.ItemId, i.ItemCode, i.ItemName, df.ShortName AS FormShort, i.Strength, i.PackSize, g.GenericName, m.ManufacturerName, i.ScheduleCode,
           pu.UomCode AS PurchaseUom, su.UomCode AS SaleUom, i.ConversionQty, h.GstPercent,
           ISNULL((SELECT SUM(s.QtyOnHand) FROM dbo.PhStock s WHERE s.BranchId = @BranchId AND s.ItemId = i.ItemId), 0) AS Stock,
           ISNULL(ib.ReorderLevel, i.ReorderLevel) AS ReorderLevel, ISNULL(ib.MaxQty, i.MaxQty) AS MaxQty,
           ISNULL((SELECT SUM(pd.Qty - pd.ReceivedQty) FROM dbo.PhPurchaseOrderDtl pd JOIN dbo.PhPurchaseOrder po ON po.PoId = pd.PoId
                   WHERE po.BranchId = @BranchId AND po.Status IN ('APPROVED','PARTIAL') AND pd.ItemId = i.ItemId AND pd.Qty > pd.ReceivedQty), 0) AS PendingPoQty,
           lg.Rate AS LastRate, lg.Mrp AS LastMrp, lg.SupplierName AS LastSupplier,
           i.IsActive, ISNULL(ib.IsStocked, 1) AS IsStocked, i.Barcode
      FROM dbo.PhItem i
      JOIN dbo.PhHsn h ON h.HsnId = i.HsnId
      JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId
      LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
      LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
      LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
      OUTER APPLY (SELECT TOP 1 d.Rate, d.Mrp, s.SupplierName FROM dbo.PhGrnDtl d JOIN dbo.PhGrn gr ON gr.GrnId = d.GrnId JOIN dbo.PhSupplier s ON s.SupplierId = gr.SupplierId
                   WHERE d.ItemId = i.ItemId AND gr.Status = 'POSTED' AND gr.CompanyId = @CompanyId ORDER BY gr.PostedDate DESC) lg
     WHERE i.CompanyId = @CompanyId;
GO

-- ── lookups and settings ─────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_ItemSearch @CompanyId INT, @BranchId INT, @Q NVARCHAR(200), @Take INT = 15
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @like NVARCHAR(210) = N'%' + @Q + N'%', @starts NVARCHAR(210) = @Q + N'%';
    SELECT TOP (@Take) f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f
     WHERE f.IsActive = 1 AND f.IsStocked = 1 AND (f.ItemName LIKE @like OR f.GenericName LIKE @like OR f.ItemCode = @Q OR f.Barcode = @Q)
     ORDER BY CASE WHEN f.Barcode = @Q OR f.ItemCode = @Q THEN 0 WHEN f.ItemName LIKE @starts THEN 1 ELSE 2 END, f.ItemName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_ReorderSuggest @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f
     WHERE f.IsActive = 1 AND f.IsStocked = 1 AND f.ReorderLevel > 0 AND f.Stock / f.ConversionQty + f.PendingPoQty <= f.ReorderLevel
     ORDER BY f.ItemName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_Suppliers @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(SupplierId AS VARCHAR(10)) AS Value, SupplierName + N' (' + SupplierCode + N')' AS Text
      FROM dbo.PhSupplier WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY SupplierName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_Reasons @CompanyId INT, @Type VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(ReasonId AS VARCHAR(10)) AS Value, ReasonName AS Text
      FROM dbo.PhReason WHERE CompanyId = @CompanyId AND ReasonType = @Type AND IsActive = 1 ORDER BY SortOrder, ReasonName;
END
GO

-- Hospital Settings > MED of the branch: GRN not required, minimum shelf life on a GRN
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_Settings @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ISNULL((SELECT TOP 1 PharmacyGrnNotRequired FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0) AS GrnNotRequired,
           ISNULL((SELECT TOP 1 PharmacyMinShelfLifeGrnDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 90) AS MinShelfLifeGrnDays;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Ph_BranchHeader @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 ISNULL(NULLIF(h.PharmacyName, ''), h.HotelName) AS Name, h.Address, ISNULL(NULLIF(h.PharmacyContactNo, ''), h.ContactNumber1) AS Phone,
           NULLIF(ISNULL(NULLIF(h.PharmacyGstin, ''), h.GSTCode), '') AS Gstin, h.PharmacyDrugLicence20B AS Licence20B, h.PharmacyDrugLicence21B AS Licence21B,
           h.PharmacistName + ISNULL(N' (Reg. ' + h.PharmacistRegNo + N')', N'') AS Pharmacist, h.LogoPath
      FROM dbo.HospitalSettings h WHERE h.BranchId = @BranchId ORDER BY h.IsActive DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_SupplierInfo @CompanyId INT, @BranchId INT, @SupplierId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.SupplierId, s.SupplierName, s.Gstin, s.Email, s.CreditDays, s.DrugLicenceValidTo,
           CAST(CASE
                WHEN LEN(s.Gstin) >= 2 AND LEN(bg.Gstin) >= 2 THEN CASE WHEN LEFT(s.Gstin, 2) <> LEFT(bg.Gstin, 2) THEN 1 ELSE 0 END
                WHEN st.StateName IS NOT NULL AND b.State IS NOT NULL THEN CASE WHEN st.StateName <> b.State THEN 1 ELSE 0 END
                ELSE 0 END AS BIT) AS IsInterState
      FROM dbo.PhSupplier s
      LEFT JOIN dbo.StateMaster st ON st.StateId = s.StateId
      CROSS JOIN (SELECT State FROM dbo.BranchMaster WHERE BranchID = @BranchId) b
      OUTER APPLY (SELECT TOP 1 NULLIF(ISNULL(NULLIF(PharmacyGstin, ''), GSTCode), '') AS Gstin FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC) bg
     WHERE s.SupplierId = @SupplierId AND s.CompanyId = @CompanyId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_OpenPos @CompanyId INT, @BranchId INT, @SupplierId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(PoId AS VARCHAR(10)) AS Value, PoNo + N' · ' + CONVERT(VARCHAR(11), PoDate, 106) + N' · ₹' + CONVERT(VARCHAR(20), NetAmount) AS Text
      FROM dbo.PhPurchaseOrder WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND SupplierId = @SupplierId AND Status IN ('APPROVED', 'PARTIAL') ORDER BY PoDate;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_RateHistory @CompanyId INT, @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 8 g.GrnDate, g.GrnNo, s.SupplierName, d.BatchNo, d.Qty, d.FreeQty, d.Rate, d.DiscPercent, d.GstPercent, d.Mrp
      FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId
     WHERE g.CompanyId = @CompanyId AND d.ItemId = @ItemId AND g.Status = 'POSTED' ORDER BY g.PostedDate DESC;
END
GO

-- ── document lists, counts, one document ─────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_StatusCounts @Kind VARCHAR(10), @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Kind = 'indent'  SELECT Status, COUNT(*) AS Cnt FROM dbo.PhPurchaseIndent  WHERE CompanyId = @CompanyId AND BranchId = @BranchId GROUP BY Status;
    IF @Kind = 'po'      SELECT Status, COUNT(*) AS Cnt FROM dbo.PhPurchaseOrder   WHERE CompanyId = @CompanyId AND BranchId = @BranchId GROUP BY Status;
    IF @Kind = 'grn'     SELECT Status, COUNT(*) AS Cnt FROM dbo.PhGrn             WHERE CompanyId = @CompanyId AND BranchId = @BranchId GROUP BY Status;
    IF @Kind = 'return'  SELECT Status, COUNT(*) AS Cnt FROM dbo.PhPurchaseReturn  WHERE CompanyId = @CompanyId AND BranchId = @BranchId GROUP BY Status;
    IF @Kind = 'payment' SELECT Status, COUNT(*) AS Cnt FROM dbo.PhSupplierPayment WHERE CompanyId = @CompanyId AND BranchId = @BranchId GROUP BY Status;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_List
    @Kind VARCHAR(10), @CompanyId INT, @BranchId INT, @Status VARCHAR(10) = NULL, @Search NVARCHAR(200) = NULL, @From DATE = NULL, @To DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(210) = N'%' + @Search + N'%';
    IF @Kind = 'indent'
        SELECT TOP 500 * FROM (
            SELECT d.IndentId Id, d.IndentNo DocNo, d.IndentDate DocDate, u.Name Party, d.Priority Ref, d.Status,
                   (SELECT COUNT(*) FROM dbo.PhPurchaseIndentDtl x WHERE x.IndentId = d.IndentId) Lines, 0 Amount, d.Remarks Extra
              FROM dbo.PhPurchaseIndent d OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) Name FROM dbo.Users WHERE Id = d.CreatedBy) u
             WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId) x
         WHERE (@Status IS NULL OR x.Status = @Status) AND (@From IS NULL OR x.DocDate >= @From) AND (@To IS NULL OR x.DocDate <= @To)
           AND (@Search IS NULL OR x.DocNo LIKE @like OR x.Party LIKE @like OR x.Ref LIKE @like) ORDER BY x.DocDate DESC, x.Id DESC;
    ELSE IF @Kind = 'po'
        SELECT TOP 500 * FROM (
            SELECT d.PoId Id, d.PoNo DocNo, d.PoDate DocDate, s.SupplierName Party, i.IndentNo Ref, d.Status,
                   (SELECT COUNT(*) FROM dbo.PhPurchaseOrderDtl x WHERE x.PoId = d.PoId) Lines, d.NetAmount Amount, CONVERT(VARCHAR(11), d.ExpectedDate, 106) Extra
              FROM dbo.PhPurchaseOrder d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhPurchaseIndent i ON i.IndentId = d.IndentId
             WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId) x
         WHERE (@Status IS NULL OR x.Status = @Status) AND (@From IS NULL OR x.DocDate >= @From) AND (@To IS NULL OR x.DocDate <= @To)
           AND (@Search IS NULL OR x.DocNo LIKE @like OR x.Party LIKE @like OR x.Ref LIKE @like) ORDER BY x.DocDate DESC, x.Id DESC;
    ELSE IF @Kind = 'grn'
        SELECT TOP 500 * FROM (
            SELECT d.GrnId Id, d.GrnNo DocNo, d.GrnDate DocDate, s.SupplierName Party, d.InvoiceNo Ref, d.Status,
                   (SELECT COUNT(*) FROM dbo.PhGrnDtl x WHERE x.GrnId = d.GrnId) Lines, d.NetAmount Amount, p.PoNo Extra, d.DueDate,
                   d.NetAmount - ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment sp ON sp.PaymentId = a.PaymentId WHERE a.GrnId = d.GrnId AND sp.Status = 'POSTED'), 0) Balance
              FROM dbo.PhGrn d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhPurchaseOrder p ON p.PoId = d.PoId
             WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId) x
         WHERE (@Status IS NULL OR x.Status = @Status) AND (@From IS NULL OR x.DocDate >= @From) AND (@To IS NULL OR x.DocDate <= @To)
           AND (@Search IS NULL OR x.DocNo LIKE @like OR x.Party LIKE @like OR x.Ref LIKE @like) ORDER BY x.DocDate DESC, x.Id DESC;
    ELSE IF @Kind = 'return'
        SELECT TOP 500 * FROM (
            SELECT d.ReturnId Id, d.ReturnNo DocNo, d.ReturnDate DocDate, s.SupplierName Party, r.ReasonName Ref, d.Status,
                   (SELECT COUNT(*) FROM dbo.PhPurchaseReturnDtl x WHERE x.ReturnId = d.ReturnId) Lines, d.NetAmount Amount, d.Remarks Extra
              FROM dbo.PhPurchaseReturn d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhReason r ON r.ReasonId = d.ReasonId
             WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId) x
         WHERE (@Status IS NULL OR x.Status = @Status) AND (@From IS NULL OR x.DocDate >= @From) AND (@To IS NULL OR x.DocDate <= @To)
           AND (@Search IS NULL OR x.DocNo LIKE @like OR x.Party LIKE @like OR x.Ref LIKE @like) ORDER BY x.DocDate DESC, x.Id DESC;
    ELSE IF @Kind = 'payment'
        SELECT TOP 500 * FROM (
            SELECT d.PaymentId Id, d.PaymentNo DocNo, d.PaymentDate DocDate, s.SupplierName Party, d.PaymentMode + ISNULL(N' · ' + d.ReferenceNo, N'') Ref, d.Status,
                   (SELECT COUNT(*) FROM dbo.PhSupplierPaymentAlloc x WHERE x.PaymentId = d.PaymentId) Lines, d.Amount, d.Remarks Extra
              FROM dbo.PhSupplierPayment d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId
             WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId) x
         WHERE (@Status IS NULL OR x.Status = @Status) AND (@From IS NULL OR x.DocDate >= @From) AND (@To IS NULL OR x.DocDate <= @To)
           AND (@Search IS NULL OR x.DocNo LIKE @like OR x.Party LIKE @like OR x.Ref LIKE @like) ORDER BY x.DocDate DESC, x.Id DESC;
    ELSE THROW 55300, 'Unknown purchase document.', 1;
END
GO

-- one document: 1 header (no row = not found), 2 lines, 3 item details of the lines
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_Get @Kind VARCHAR(10), @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Kind = 'indent'
    BEGIN
        SELECT d.IndentId Id, d.IndentNo DocNo, d.IndentDate DocDate, d.Status, d.Priority, d.Remarks, d.ActionRemarks,
               cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.ApprovedDate
          FROM dbo.PhPurchaseIndent d
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.CreatedBy) cb
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.ApprovedBy) ab
         WHERE d.IndentId = @Id AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId;
        SELECT x.IndentDtlId LineId, x.ItemId, x.Qty, x.Remarks, x.StockAtIndent Stock FROM dbo.PhPurchaseIndentDtl x
          JOIN dbo.PhPurchaseIndent d ON d.IndentId = x.IndentId AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId
         WHERE x.IndentId = @Id ORDER BY x.IndentDtlId;
        SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f WHERE f.ItemId IN (SELECT ItemId FROM dbo.PhPurchaseIndentDtl WHERE IndentId = @Id);
    END
    ELSE IF @Kind = 'po'
    BEGIN
        SELECT d.PoId Id, d.PoNo DocNo, d.PoDate DocDate, d.Status, d.SupplierId, s.SupplierName, d.IndentId RefId, i.IndentNo RefNo,
               d.ExpectedDate, d.IsInterState, d.IsDirect, d.InvoiceNo, d.InvoiceDate, ISNULL(d.InvoiceAmount, 0) InvoiceAmount, d.OtherCharges, d.Terms, d.Remarks,
               d.TaxableAmount, d.GstAmount, d.NetAmount, d.EmailedTo, d.EmailedDate, cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.ApprovedDate
          FROM dbo.PhPurchaseOrder d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhPurchaseIndent i ON i.IndentId = d.IndentId
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.CreatedBy) cb
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.ApprovedBy) ab
         WHERE d.PoId = @Id AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId;
        SELECT x.PoDtlId LineId, x.ItemId, x.Qty, x.FreeQty, x.Rate, x.DiscPercent, x.GstPercent, x.TaxableAmount, x.GstAmount, x.ReceivedQty, x.Qty - x.ReceivedQty PendingQty,
               x.BatchNo, x.ExpiryDate, ISNULL(x.Mrp, 0) Mrp
          FROM dbo.PhPurchaseOrderDtl x JOIN dbo.PhPurchaseOrder d ON d.PoId = x.PoId AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId
         WHERE x.PoId = @Id ORDER BY x.PoDtlId;
        SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f WHERE f.ItemId IN (SELECT ItemId FROM dbo.PhPurchaseOrderDtl WHERE PoId = @Id);
    END
    ELSE IF @Kind = 'grn'
    BEGIN
        SELECT d.GrnId Id, d.GrnNo DocNo, d.GrnDate DocDate, d.Status, d.SupplierId, s.SupplierName, d.PoId RefId, po.PoNo RefNo,
               d.InvoiceNo, d.InvoiceDate, d.InvoiceAmount, d.IsInterState, d.OtherCharges, d.Remarks, d.TaxableAmount, d.CgstAmount + d.SgstAmount + d.IgstAmount GstAmount,
               d.DiscountAmount, d.RoundOff, d.NetAmount, d.DueDate, d.AttachmentPath, d.AttachmentName, cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.PostedDate ApprovedDate
          FROM dbo.PhGrn d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhPurchaseOrder po ON po.PoId = d.PoId
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.CreatedBy) cb
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.PostedBy) ab
         WHERE d.GrnId = @Id AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId;
        SELECT x.GrnDtlId LineId, x.ItemId, x.PoDtlId, x.BatchNo, x.MfgDate, x.ExpiryDate, x.Mrp, x.Qty, x.FreeQty, x.Rate, x.DiscPercent, x.GstPercent, x.TaxableAmount, x.GstAmount,
               ISNULL(pd.Qty - pd.ReceivedQty, 0) PendingQty
          FROM dbo.PhGrnDtl x JOIN dbo.PhGrn d ON d.GrnId = x.GrnId AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId
          LEFT JOIN dbo.PhPurchaseOrderDtl pd ON pd.PoDtlId = x.PoDtlId
         WHERE x.GrnId = @Id ORDER BY x.GrnDtlId;
        SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f WHERE f.ItemId IN (SELECT ItemId FROM dbo.PhGrnDtl WHERE GrnId = @Id);
    END
    ELSE IF @Kind = 'return'
    BEGIN
        SELECT d.ReturnId Id, d.ReturnNo DocNo, d.ReturnDate DocDate, d.Status, d.SupplierId, s.SupplierName, d.ReasonId, d.IsInterState,
               d.Remarks, d.TaxableAmount, d.GstAmount, d.RoundOff, d.NetAmount, cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.PostedDate ApprovedDate
          FROM dbo.PhPurchaseReturn d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.CreatedBy) cb
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.PostedBy) ab
         WHERE d.ReturnId = @Id AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId;
        SELECT x.ReturnDtlId LineId, x.ItemId, x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.Qty, x.Rate, x.GstPercent, x.TaxableAmount, x.GstAmount,
               ISNULL((SELECT QtyOnHand FROM dbo.PhStock st WHERE st.BranchId = @BranchId AND st.BatchId = x.BatchId), 0) Stock
          FROM dbo.PhPurchaseReturnDtl x JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
          JOIN dbo.PhPurchaseReturn d ON d.ReturnId = x.ReturnId AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId
         WHERE x.ReturnId = @Id ORDER BY x.ReturnDtlId;
        SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f WHERE f.ItemId IN (SELECT ItemId FROM dbo.PhPurchaseReturnDtl WHERE ReturnId = @Id);
    END
    ELSE IF @Kind = 'payment'
    BEGIN
        SELECT d.PaymentId Id, d.PaymentNo DocNo, d.PaymentDate DocDate, d.Status, d.SupplierId, s.SupplierName,
               d.PaymentMode Priority, d.ReferenceNo InvoiceNo, d.Remarks, d.Amount NetAmount, cb.N CreatedByName, d.CreatedDate
          FROM dbo.PhSupplierPayment d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.CreatedBy) cb
         WHERE d.PaymentId = @Id AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId;
        SELECT a.AllocId LineId, 0 ItemId, g.GrnNo ItemName, g.InvoiceNo ItemCode, g.InvoiceDate ExpiryDate, g.NetAmount Mrp, a.Amount TaxableAmount
          FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhGrn g ON g.GrnId = a.GrnId
          JOIN dbo.PhSupplierPayment d ON d.PaymentId = a.PaymentId AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId
         WHERE a.PaymentId = @Id ORDER BY a.AllocId;
        SELECT TOP 0 f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f;
    END
    ELSE THROW 55300, 'Unknown purchase document.', 1;
END
GO

-- ── purchase indent ──────────────────────────────────────────────────────────────────────────────────────
-- @Lines: [{ "ItemId", "Qty", "Remarks" }]
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhIndent_Save
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @DocDate DATE, @Priority VARCHAR(10), @Remarks NVARCHAR(300) = NULL, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @Priority = CASE WHEN @Priority = 'URGENT' THEN 'URGENT' ELSE 'NORMAL' END;
    BEGIN TRAN;
    IF @Id > 0
    BEGIN
        IF ISNULL((SELECT Status FROM dbo.PhPurchaseIndent WITH (UPDLOCK) WHERE IndentId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'DRAFT'
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a draft indent can be changed.' AS Error; RETURN; END;
        UPDATE dbo.PhPurchaseIndent SET IndentDate = @DocDate, Priority = @Priority, Remarks = @Remarks, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE IndentId = @Id;
        DELETE dbo.PhPurchaseIndentDtl WHERE IndentId = @Id;
    END
    ELSE
    BEGIN
        INSERT dbo.PhPurchaseIndent (CompanyId, BranchId, IndentDate, Priority, Remarks, CreatedBy) VALUES (@CompanyId, @BranchId, @DocDate, @Priority, @Remarks, @UserId);
        SET @Id = CAST(SCOPE_IDENTITY() AS INT);
    END
    INSERT dbo.PhPurchaseIndentDtl (IndentId, ItemId, Qty, StockAtIndent, Remarks)
    SELECT @Id, i.ItemId, l.Qty, ISNULL((SELECT SUM(QtyOnHand) FROM dbo.PhStock WHERE BranchId = @BranchId AND ItemId = i.ItemId), 0), l.Remarks
      FROM OPENJSON(@Lines) WITH (ItemId INT, Qty DECIMAL(12,2), Remarks NVARCHAR(200)) l
      JOIN dbo.PhItem i ON i.ItemId = l.ItemId AND i.CompanyId = @CompanyId AND i.IsActive = 1;
    COMMIT;
    SELECT @Id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhIndent_Action
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @Action VARCHAR(10), @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @status VARCHAR(10), @date DATE, @no NVARCHAR(40);
    BEGIN TRAN;
    SELECT @status = Status, @date = IndentDate FROM dbo.PhPurchaseIndent WITH (UPDLOCK) WHERE IndentId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId;
    IF @status IS NULL BEGIN ROLLBACK; SELECT N'Indent not found.' AS Error; RETURN; END;
    IF @Action = 'submit'
    BEGIN
        IF @status <> 'DRAFT' BEGIN ROLLBACK; SELECT N'Only a draft can be submitted.' AS Error; RETURN; END;
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'PIND', @DocDate = @date, @DocNo = @no OUTPUT;
        UPDATE dbo.PhPurchaseIndent SET Status = 'SUBMITTED', IndentNo = @no, SubmittedBy = @UserId, SubmittedDate = GETDATE() WHERE IndentId = @Id;
    END
    ELSE IF @Action IN ('approve', 'reject')
    BEGIN
        IF @status <> 'SUBMITTED' BEGIN ROLLBACK; SELECT N'Only a submitted indent can be approved or rejected.' AS Error; RETURN; END;
        IF @Action = 'reject' AND NULLIF(LTRIM(RTRIM(@Remarks)), N'') IS NULL BEGIN ROLLBACK; SELECT N'Give the reason for rejecting.' AS Error; RETURN; END;
        UPDATE dbo.PhPurchaseIndent SET Status = CASE WHEN @Action = 'approve' THEN 'APPROVED' ELSE 'REJECTED' END, ActionRemarks = @Remarks,
               ApprovedBy = @UserId, ApprovedDate = GETDATE() WHERE IndentId = @Id;
    END
    ELSE IF @Action = 'cancel'
    BEGIN
        IF @status NOT IN ('DRAFT', 'SUBMITTED', 'APPROVED') BEGIN ROLLBACK; SELECT N'This indent cannot be cancelled.' AS Error; RETURN; END;
        UPDATE dbo.PhPurchaseIndent SET Status = 'CANCELLED', ActionRemarks = ISNULL(@Remarks, ActionRemarks), ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE IndentId = @Id;
    END
    ELSE BEGIN ROLLBACK; SELECT N'Unknown action.' AS Error; RETURN; END;
    COMMIT;
    SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
END
GO

-- ── purchase order ───────────────────────────────────────────────────────────────────────────────────────
-- lines of an approved indent for a new order: 1 lines, 2 item details
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPo_IndentLines @CompanyId INT, @BranchId INT, @IndentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT x.ItemId, x.Qty, h.GstPercent,
           ISNULL((SELECT TOP 1 d.Rate FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId WHERE d.ItemId = x.ItemId AND g.Status = 'POSTED' ORDER BY g.PostedDate DESC), 0) Rate
      FROM dbo.PhPurchaseIndentDtl x JOIN dbo.PhPurchaseIndent i ON i.IndentId = x.IndentId JOIN dbo.PhItem it ON it.ItemId = x.ItemId JOIN dbo.PhHsn h ON h.HsnId = it.HsnId
     WHERE x.IndentId = @IndentId AND i.CompanyId = @CompanyId AND i.BranchId = @BranchId AND i.Status = 'APPROVED';
    SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f WHERE f.ItemId IN (SELECT ItemId FROM dbo.PhPurchaseIndentDtl WHERE IndentId = @IndentId);
END
GO

-- whether an order takes the supplier's bill (GRN not required): a draft keeps the mode it was started in
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPo_Mode @Id INT, @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF ISNULL(@Id, 0) = 0
        SELECT CAST(ISNULL((SELECT TOP 1 PharmacyGrnNotRequired FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0) AS BIT) AS IsDirect;
    ELSE
        SELECT CAST(ISNULL((SELECT IsDirect FROM dbo.PhPurchaseOrder WHERE PoId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), 0) AS BIT) AS IsDirect;
END
GO

-- amounts and lines worked out in EMR.Web. @Lines: [{ ItemId, Qty, FreeQty, Rate, DiscPercent, GstPercent, TaxableAmount, GstAmount, BatchNo, ExpiryDate, Mrp }]
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPo_Save
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @DocDate DATE, @SupplierId INT, @IndentId INT = NULL, @ExpectedDate DATE = NULL,
    @IsInterState BIT, @Terms NVARCHAR(500) = NULL, @Remarks NVARCHAR(300) = NULL, @Taxable DECIMAL(14,2), @Gst DECIMAL(14,2), @Net DECIMAL(14,2),
    @IsDirect BIT, @InvoiceNo NVARCHAR(40) = NULL, @InvoiceDate DATE = NULL, @InvoiceAmount DECIMAL(14,2) = NULL, @OtherCharges DECIMAL(14,2) = 0, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    IF @IsDirect = 1 AND EXISTS (SELECT 1 FROM dbo.PhGrn WHERE CompanyId = @CompanyId AND SupplierId = @SupplierId AND InvoiceNo = @InvoiceNo AND Status <> 'CANCELLED')
    BEGIN ROLLBACK; SELECT 0 AS Id, N'Bill ' + @InvoiceNo + N' of this supplier is already entered.' AS Error; RETURN; END;
    IF @Id > 0
    BEGIN
        IF ISNULL((SELECT Status FROM dbo.PhPurchaseOrder WITH (UPDLOCK) WHERE PoId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'DRAFT'
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a draft order can be changed.' AS Error; RETURN; END;
        UPDATE dbo.PhPurchaseOrder SET PoDate = @DocDate, SupplierId = @SupplierId, ExpectedDate = @ExpectedDate, IsInterState = @IsInterState, Terms = @Terms, Remarks = @Remarks,
               TaxableAmount = @Taxable, GstAmount = @Gst, NetAmount = @Net, InvoiceNo = @InvoiceNo, InvoiceDate = @InvoiceDate, InvoiceAmount = @InvoiceAmount, OtherCharges = @OtherCharges,
               ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE PoId = @Id;
        DELETE dbo.PhPurchaseOrderDtl WHERE PoId = @Id;
    END
    ELSE
    BEGIN
        IF @IndentId IS NOT NULL AND ISNULL((SELECT Status FROM dbo.PhPurchaseIndent WHERE IndentId = @IndentId AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'APPROVED'
        BEGIN ROLLBACK; SELECT 0 AS Id, N'The indent is not approved (or already ordered).' AS Error; RETURN; END;
        INSERT dbo.PhPurchaseOrder (CompanyId, BranchId, PoDate, SupplierId, IndentId, ExpectedDate, IsInterState, Terms, Remarks, TaxableAmount, GstAmount, NetAmount,
               IsDirect, InvoiceNo, InvoiceDate, InvoiceAmount, OtherCharges, CreatedBy)
        VALUES (@CompanyId, @BranchId, @DocDate, @SupplierId, @IndentId, @ExpectedDate, @IsInterState, @Terms, @Remarks, @Taxable, @Gst, @Net,
               @IsDirect, @InvoiceNo, @InvoiceDate, @InvoiceAmount, @OtherCharges, @UserId);
        SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        IF @IndentId IS NOT NULL UPDATE dbo.PhPurchaseIndent SET Status = 'ORDERED' WHERE IndentId = @IndentId;
    END
    INSERT dbo.PhPurchaseOrderDtl (PoId, ItemId, Qty, FreeQty, Rate, DiscPercent, GstPercent, TaxableAmount, GstAmount, BatchNo, ExpiryDate, Mrp)
    SELECT @Id, i.ItemId, l.Qty, l.FreeQty, l.Rate, l.DiscPercent, l.GstPercent, l.TaxableAmount, l.GstAmount, l.BatchNo, l.ExpiryDate, l.Mrp
      FROM OPENJSON(@Lines) WITH (ItemId INT, Qty DECIMAL(12,2), FreeQty DECIMAL(12,2), Rate DECIMAL(12,4), DiscPercent DECIMAL(5,2), GstPercent DECIMAL(5,2),
                                  TaxableAmount DECIMAL(14,2), GstAmount DECIMAL(14,2), BatchNo NVARCHAR(30), ExpiryDate DATE, Mrp DECIMAL(12,2)) l
      JOIN dbo.PhItem i ON i.ItemId = l.ItemId AND i.CompanyId = @CompanyId;
    COMMIT;
    SELECT @Id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPo_Action @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @Action VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @status VARCHAR(10), @date DATE, @indent INT, @no NVARCHAR(40);
    BEGIN TRAN;
    SELECT @status = Status, @date = PoDate, @indent = IndentId FROM dbo.PhPurchaseOrder WITH (UPDLOCK) WHERE PoId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId;
    IF @status IS NULL BEGIN ROLLBACK; SELECT N'Order not found.' AS Error; RETURN; END;
    IF @Action = 'approve'
    BEGIN
        IF @status <> 'DRAFT' BEGIN ROLLBACK; SELECT N'Only a draft order can be approved.' AS Error; RETURN; END;
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'PO', @DocDate = @date, @DocNo = @no OUTPUT;
        UPDATE dbo.PhPurchaseOrder SET Status = 'APPROVED', PoNo = @no, ApprovedBy = @UserId, ApprovedDate = GETDATE() WHERE PoId = @Id;
    END
    ELSE IF @Action = 'cancel'
    BEGIN
        IF @status NOT IN ('DRAFT', 'APPROVED') BEGIN ROLLBACK; SELECT N'Only a draft or approved order with nothing received can be cancelled.' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM dbo.PhGrn WHERE PoId = @Id AND Status <> 'CANCELLED') BEGIN ROLLBACK; SELECT N'A GRN is already entered against this order.' AS Error; RETURN; END;
        UPDATE dbo.PhPurchaseOrder SET Status = 'CANCELLED', ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE PoId = @Id;
        IF @indent IS NOT NULL UPDATE dbo.PhPurchaseIndent SET Status = 'APPROVED' WHERE IndentId = @indent AND Status = 'ORDERED';
    END
    ELSE IF @Action = 'close'
    BEGIN
        IF @status <> 'PARTIAL' BEGIN ROLLBACK; SELECT N'Only a part-received order can be short-closed.' AS Error; RETURN; END;
        UPDATE dbo.PhPurchaseOrder SET Status = 'CLOSED', ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE PoId = @Id;
    END
    ELSE BEGIN ROLLBACK; SELECT N'Unknown action.' AS Error; RETURN; END;
    COMMIT;
    SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
END
GO

-- GRN not required: posting the order's GRN failed, so the order goes back to draft (its number is not reused)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPo_UndoDirectApprove @PoId INT, @GrnId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    IF @GrnId > 0 AND EXISTS (SELECT 1 FROM dbo.PhGrn WHERE GrnId = @GrnId AND Status = 'DRAFT')
    BEGIN DELETE dbo.PhGrnDtl WHERE GrnId = @GrnId; DELETE dbo.PhGrn WHERE GrnId = @GrnId; END
    UPDATE dbo.PhPurchaseOrder SET Status = 'DRAFT', PoNo = NULL, ApprovedBy = NULL, ApprovedDate = NULL WHERE PoId = @PoId AND Status = 'APPROVED';
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPo_MarkEmailed @PoId INT, @Email NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PhPurchaseOrder SET EmailedTo = @Email, EmailedDate = GETDATE() WHERE PoId = @PoId;
END
GO

-- ── GRN ──────────────────────────────────────────────────────────────────────────────────────────────────
-- pending lines of an open order for a new GRN: 1 lines, 2 item details
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhGrn_PoLines @CompanyId INT, @BranchId INT, @PoId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT x.PoDtlId, x.ItemId, x.Qty - x.ReceivedQty Qty, x.Qty - x.ReceivedQty PendingQty,
           CASE WHEN x.ReceivedQty = 0 THEN x.FreeQty ELSE 0 END FreeQty, x.Rate, x.DiscPercent, x.GstPercent,
           ISNULL((SELECT TOP 1 d.Mrp FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId WHERE d.ItemId = x.ItemId AND g.Status = 'POSTED' ORDER BY g.PostedDate DESC), 0) Mrp
      FROM dbo.PhPurchaseOrderDtl x JOIN dbo.PhPurchaseOrder p ON p.PoId = x.PoId
     WHERE x.PoId = @PoId AND p.CompanyId = @CompanyId AND p.BranchId = @BranchId AND p.Status IN ('APPROVED', 'PARTIAL') AND x.Qty > x.ReceivedQty
     ORDER BY x.PoDtlId;
    SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f WHERE f.ItemId IN (SELECT ItemId FROM dbo.PhPurchaseOrderDtl WHERE PoId = @PoId);
END
GO

-- lines priced and checked in EMR.Web; the order's pending quantities are checked here, in the transaction.
-- @Lines: [{ PoDtlId, ItemId, BatchNo, MfgDate, ExpiryDate, Mrp, Qty, FreeQty, Rate, DiscPercent, GstPercent, TaxableAmount, GstAmount }]
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhGrn_Save
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @DocDate DATE, @SupplierId INT, @PoId INT = NULL, @InvoiceNo NVARCHAR(40), @InvoiceDate DATE,
    @InvoiceAmount DECIMAL(14,2), @IsInterState BIT, @OtherCharges DECIMAL(14,2) = 0, @Remarks NVARCHAR(300) = NULL, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @L TABLE (PoDtlId INT, ItemId INT, BatchNo NVARCHAR(30), MfgDate DATE, ExpiryDate DATE, Mrp DECIMAL(12,2), Qty DECIMAL(12,2), FreeQty DECIMAL(12,2),
                      Rate DECIMAL(12,4), DiscPercent DECIMAL(5,2), GstPercent DECIMAL(5,2), TaxableAmount DECIMAL(14,2), GstAmount DECIMAL(14,2));
    INSERT @L SELECT * FROM OPENJSON(@Lines) WITH (PoDtlId INT, ItemId INT, BatchNo NVARCHAR(30), MfgDate DATE, ExpiryDate DATE, Mrp DECIMAL(12,2), Qty DECIMAL(12,2),
                                                   FreeQty DECIMAL(12,2), Rate DECIMAL(12,4), DiscPercent DECIMAL(5,2), GstPercent DECIMAL(5,2), TaxableAmount DECIMAL(14,2), GstAmount DECIMAL(14,2));
    BEGIN TRAN;
    IF EXISTS (SELECT 1 FROM dbo.PhGrn WHERE CompanyId = @CompanyId AND SupplierId = @SupplierId AND InvoiceNo = @InvoiceNo AND Status <> 'CANCELLED' AND GrnId <> ISNULL(@Id, 0))
    BEGIN ROLLBACK; SELECT 0 AS Id, N'Invoice ' + @InvoiceNo + N' of this supplier is already entered.' AS Error; RETURN; END;
    IF @PoId IS NOT NULL
    BEGIN
        DECLARE @P TABLE (PoDtlId INT PRIMARY KEY, Pending DECIMAL(12,2));
        INSERT @P SELECT x.PoDtlId, x.Qty - x.ReceivedQty FROM dbo.PhPurchaseOrderDtl x JOIN dbo.PhPurchaseOrder p ON p.PoId = x.PoId
                   WHERE x.PoId = @PoId AND p.SupplierId = @SupplierId AND p.Status IN ('APPROVED', 'PARTIAL');
        IF NOT EXISTS (SELECT 1 FROM @P) BEGIN ROLLBACK; SELECT 0 AS Id, N'The purchase order is not open for this supplier.' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM (SELECT PoDtlId, SUM(Qty) Q FROM @L WHERE PoDtlId IS NOT NULL GROUP BY PoDtlId) g LEFT JOIN @P p ON p.PoDtlId = g.PoDtlId
                    WHERE p.PoDtlId IS NULL OR g.Q > p.Pending)
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Received quantity is more than the quantity pending on the order.' AS Error; RETURN; END;
    END
    ELSE UPDATE @L SET PoDtlId = NULL;

    DECLARE @taxable DECIMAL(14,2) = (SELECT ISNULL(SUM(TaxableAmount), 0) FROM @L), @gst DECIMAL(14,2) = (SELECT ISNULL(SUM(GstAmount), 0) FROM @L);
    DECLARE @gross DECIMAL(14,2) = (SELECT ROUND(ISNULL(SUM(Qty * Rate), 0), 2) FROM @L);
    DECLARE @cgst DECIMAL(14,2) = CASE WHEN @IsInterState = 1 THEN 0 ELSE ROUND(@gst / 2, 2) END;
    DECLARE @sgst DECIMAL(14,2) = CASE WHEN @IsInterState = 1 THEN 0 ELSE @gst - ROUND(@gst / 2, 2) END;
    DECLARE @igst DECIMAL(14,2) = CASE WHEN @IsInterState = 1 THEN @gst ELSE 0 END;
    DECLARE @exact DECIMAL(14,2) = @taxable + @gst + @OtherCharges;
    DECLARE @net DECIMAL(14,2) = ROUND(@exact, 0);
    IF @Id > 0
    BEGIN
        IF ISNULL((SELECT Status FROM dbo.PhGrn WITH (UPDLOCK) WHERE GrnId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'DRAFT'
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a draft GRN can be changed.' AS Error; RETURN; END;
        UPDATE dbo.PhGrn SET GrnDate = @DocDate, SupplierId = @SupplierId, PoId = @PoId, InvoiceNo = @InvoiceNo, InvoiceDate = @InvoiceDate, InvoiceAmount = @InvoiceAmount,
               IsInterState = @IsInterState, OtherCharges = @OtherCharges, Remarks = @Remarks, GrossAmount = @gross, DiscountAmount = @gross - @taxable, TaxableAmount = @taxable,
               CgstAmount = @cgst, SgstAmount = @sgst, IgstAmount = @igst, RoundOff = @net - @exact, NetAmount = @net, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE GrnId = @Id;
        DELETE dbo.PhGrnDtl WHERE GrnId = @Id;
    END
    ELSE
    BEGIN
        INSERT dbo.PhGrn (CompanyId, BranchId, GrnDate, SupplierId, PoId, InvoiceNo, InvoiceDate, InvoiceAmount, IsInterState, OtherCharges, Remarks,
               GrossAmount, DiscountAmount, TaxableAmount, CgstAmount, SgstAmount, IgstAmount, RoundOff, NetAmount, CreatedBy)
        VALUES (@CompanyId, @BranchId, @DocDate, @SupplierId, @PoId, @InvoiceNo, @InvoiceDate, @InvoiceAmount, @IsInterState, @OtherCharges, @Remarks,
               @gross, @gross - @taxable, @taxable, @cgst, @sgst, @igst, @net - @exact, @net, @UserId);
        SET @Id = CAST(SCOPE_IDENTITY() AS INT);
    END
    INSERT dbo.PhGrnDtl (GrnId, PoDtlId, ItemId, BatchNo, MfgDate, ExpiryDate, Mrp, Qty, FreeQty, Rate, DiscPercent, GstPercent, TaxableAmount, GstAmount)
    SELECT @Id, l.PoDtlId, i.ItemId, l.BatchNo, l.MfgDate, l.ExpiryDate, l.Mrp, l.Qty, l.FreeQty, l.Rate, l.DiscPercent, l.GstPercent, l.TaxableAmount, l.GstAmount
      FROM @L l JOIN dbo.PhItem i ON i.ItemId = l.ItemId AND i.CompanyId = @CompanyId;
    COMMIT;
    SELECT @Id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
END
GO

-- MRP of the last posted purchase of each item on the GRN (for the "MRP differs" warning)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhGrn_LastMrps @CompanyId INT, @BranchId INT, @GrnId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT x.ItemId,
           (SELECT TOP 1 d.Mrp FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId
             WHERE d.ItemId = x.ItemId AND g.Status = 'POSTED' AND g.CompanyId = @CompanyId ORDER BY g.PostedDate DESC) AS LastMrp
      FROM dbo.PhGrnDtl x JOIN dbo.PhGrn h ON h.GrnId = x.GrnId AND h.CompanyId = @CompanyId AND h.BranchId = @BranchId
     WHERE x.GrnId = @GrnId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhGrn_Attach @CompanyId INT, @BranchId INT, @GrnId INT, @Path NVARCHAR(300), @Name NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PhGrn SET AttachmentPath = @Path, AttachmentName = @Name
     WHERE GrnId = @GrnId AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status <> 'CANCELLED';
    SELECT CASE WHEN @@ROWCOUNT = 0 THEN N'GRN not found.' END AS Error;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_DeleteDraft @Kind VARCHAR(10), @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    IF @Kind = 'grn'
    BEGIN
        IF ISNULL((SELECT Status FROM dbo.PhGrn WITH (UPDLOCK) WHERE GrnId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'DRAFT'
        BEGIN ROLLBACK; SELECT N'Only a draft can be deleted.' AS Error; RETURN; END;
        DELETE dbo.PhGrnDtl WHERE GrnId = @Id; DELETE dbo.PhGrn WHERE GrnId = @Id;
    END
    ELSE IF @Kind = 'return'
    BEGIN
        IF ISNULL((SELECT Status FROM dbo.PhPurchaseReturn WITH (UPDLOCK) WHERE ReturnId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'DRAFT'
        BEGIN ROLLBACK; SELECT N'Only a draft can be deleted.' AS Error; RETURN; END;
        DELETE dbo.PhPurchaseReturnDtl WHERE ReturnId = @Id; DELETE dbo.PhPurchaseReturn WHERE ReturnId = @Id;
    END
    ELSE BEGIN ROLLBACK; THROW 55300, 'Unknown purchase document.', 1; END;
    COMMIT;
    SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
END
GO

-- the document belongs to the company and branch (posting itself stays in usp_PhGrn_Post / usp_PhPurchaseReturn_Post)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_Belongs @Kind VARCHAR(10), @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(CASE
        WHEN @Kind = 'grn'    AND EXISTS (SELECT 1 FROM dbo.PhGrn            WHERE GrnId    = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId) THEN 1
        WHEN @Kind = 'return' AND EXISTS (SELECT 1 FROM dbo.PhPurchaseReturn WHERE ReturnId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId) THEN 1
        ELSE 0 END AS BIT) AS Belongs;
END
GO
DROP PROCEDURE IF EXISTS dbo.usp_Api_PhGrn_Post;
GO

-- ── purchase return ──────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPurRet_BatchSearch @CompanyId INT, @BranchId INT, @Q NVARCHAR(200), @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @like NVARCHAR(210) = N'%' + @Q + N'%';
    SELECT TOP 25 b.BatchId, b.ItemId, i.ItemName, df.ShortName FormShort, b.BatchNo, b.ExpiryDate, b.Mrp,
           b.PurchaseRate / i.ConversionQty RatePerUnit, b.GstPercent, s.QtyOnHand Stock, su.UomCode SaleUom, i.ConversionQty, sp.SupplierName
      FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId LEFT JOIN dbo.PhSupplier sp ON sp.SupplierId = b.SupplierId
      LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId
     WHERE s.BranchId = @BranchId AND b.CompanyId = @CompanyId AND s.QtyOnHand > 0
       AND (i.ItemName LIKE @like OR b.BatchNo LIKE @like OR g.GenericName LIKE @like OR i.ItemCode = @Q OR i.Barcode = @Q)
     ORDER BY CASE WHEN b.SupplierId = @SupplierId THEN 0 ELSE 1 END, b.ExpiryDate;
END
GO

-- rate and GST always from the batch; quantity checked against stock now (and again when posted). @Lines: [{ BatchId, Qty }]
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPurRet_Save
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @DocDate DATE, @SupplierId INT, @ReasonId INT, @IsInterState BIT, @Remarks NVARCHAR(300) = NULL, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @L TABLE (BatchId INT PRIMARY KEY, Qty DECIMAL(14,3), ItemId INT, Rate DECIMAL(12,4), GstPercent DECIMAL(5,2), Stock DECIMAL(14,3), TaxableAmount DECIMAL(14,2), GstAmount DECIMAL(14,2));
    BEGIN TRAN;
    INSERT @L (BatchId, Qty, ItemId, Rate, GstPercent, Stock)
    SELECT l.BatchId, l.Qty, b.ItemId, ROUND(b.PurchaseRate / i.ConversionQty, 4), b.GstPercent, ISNULL(s.QtyOnHand, 0)
      FROM OPENJSON(@Lines) WITH (BatchId INT, Qty DECIMAL(14,3)) l
      LEFT JOIN dbo.PhBatch b ON b.BatchId = l.BatchId AND b.CompanyId = @CompanyId
      LEFT JOIN dbo.PhItem i ON i.ItemId = b.ItemId
      LEFT JOIN dbo.PhStock s ON s.BatchId = b.BatchId AND s.BranchId = @BranchId;
    IF EXISTS (SELECT 1 FROM @L WHERE ItemId IS NULL) BEGIN ROLLBACK; SELECT 0 AS Id, N'A batch was not found.' AS Error; RETURN; END;
    DECLARE @over NVARCHAR(200) = (SELECT TOP 1 N'Return quantity of a batch (' + FORMAT(Qty, '0.##') + N') is more than its stock (' + FORMAT(Stock, '0.##') + N').' FROM @L WHERE Qty > Stock);
    IF @over IS NOT NULL BEGIN ROLLBACK; SELECT 0 AS Id, @over AS Error; RETURN; END;
    UPDATE @L SET TaxableAmount = ROUND(Qty * Rate, 2);
    UPDATE @L SET GstAmount = ROUND(TaxableAmount * GstPercent / 100, 2);
    DECLARE @taxable DECIMAL(14,2) = (SELECT SUM(TaxableAmount) FROM @L), @gst DECIMAL(14,2) = (SELECT SUM(GstAmount) FROM @L);
    DECLARE @net DECIMAL(14,2) = ROUND(@taxable + @gst, 0);
    IF @Id > 0
    BEGIN
        IF ISNULL((SELECT Status FROM dbo.PhPurchaseReturn WITH (UPDLOCK) WHERE ReturnId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'DRAFT'
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a draft return can be changed.' AS Error; RETURN; END;
        UPDATE dbo.PhPurchaseReturn SET ReturnDate = @DocDate, SupplierId = @SupplierId, ReasonId = @ReasonId, IsInterState = @IsInterState, Remarks = @Remarks,
               TaxableAmount = @taxable, GstAmount = @gst, RoundOff = @net - @taxable - @gst, NetAmount = @net, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE ReturnId = @Id;
        DELETE dbo.PhPurchaseReturnDtl WHERE ReturnId = @Id;
    END
    ELSE
    BEGIN
        INSERT dbo.PhPurchaseReturn (CompanyId, BranchId, ReturnDate, SupplierId, ReasonId, IsInterState, Remarks, TaxableAmount, GstAmount, RoundOff, NetAmount, CreatedBy)
        VALUES (@CompanyId, @BranchId, @DocDate, @SupplierId, @ReasonId, @IsInterState, @Remarks, @taxable, @gst, @net - @taxable - @gst, @net, @UserId);
        SET @Id = CAST(SCOPE_IDENTITY() AS INT);
    END
    INSERT dbo.PhPurchaseReturnDtl (ReturnId, BatchId, ItemId, Qty, Rate, GstPercent, TaxableAmount, GstAmount)
    SELECT @Id, BatchId, ItemId, Qty, Rate, GstPercent, TaxableAmount, GstAmount FROM @L;
    COMMIT;
    SELECT @Id AS Id, CAST(NULL AS NVARCHAR(500)) AS Error;
END
GO

DROP PROCEDURE IF EXISTS dbo.usp_Api_PhPurRet_Post;
GO

-- ── supplier payments ────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupPay_Balances @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    WITH g AS (
        SELECT gr.SupplierId, gr.NetAmount, gr.DueDate,
               gr.NetAmount - ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment p ON p.PaymentId = a.PaymentId WHERE a.GrnId = gr.GrnId AND p.Status = 'POSTED'), 0) Bal
          FROM dbo.PhGrn gr WHERE gr.CompanyId = @CompanyId AND gr.BranchId = @BranchId AND gr.Status = 'POSTED')
    SELECT s.SupplierId, s.SupplierName,
           ISNULL((SELECT SUM(NetAmount) FROM g WHERE g.SupplierId = s.SupplierId), 0) Purchases,
           ISNULL((SELECT SUM(NetAmount) FROM dbo.PhPurchaseReturn r WHERE r.SupplierId = s.SupplierId AND r.BranchId = @BranchId AND r.Status = 'POSTED'), 0) Returns,
           ISNULL((SELECT SUM(Amount) FROM dbo.PhSupplierPayment p WHERE p.SupplierId = s.SupplierId AND p.BranchId = @BranchId AND p.Status = 'POSTED'), 0) Paid,
           ISNULL((SELECT SUM(Bal) FROM g WHERE g.SupplierId = s.SupplierId AND g.DueDate < CAST(GETDATE() AS DATE) AND g.Bal > 0), 0) Overdue,
           (SELECT COUNT(*) FROM g WHERE g.SupplierId = s.SupplierId AND g.Bal > 0) OpenBills
      FROM dbo.PhSupplier s
     WHERE s.CompanyId = @CompanyId AND EXISTS (SELECT 1 FROM g WHERE g.SupplierId = s.SupplierId)
     ORDER BY s.SupplierName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupPay_Payables @CompanyId INT, @BranchId INT, @SupplierId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM (
        SELECT gr.GrnId, gr.GrnNo, gr.InvoiceNo, gr.InvoiceDate, gr.DueDate, gr.NetAmount,
               ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment p ON p.PaymentId = a.PaymentId WHERE a.GrnId = gr.GrnId AND p.Status = 'POSTED'), 0) Paid
          FROM dbo.PhGrn gr WHERE gr.CompanyId = @CompanyId AND gr.BranchId = @BranchId AND gr.SupplierId = @SupplierId AND gr.Status = 'POSTED') x
     WHERE x.NetAmount - x.Paid > 0
     ORDER BY ISNULL(x.DueDate, x.InvoiceDate), x.GrnId;
END
GO

-- checked in EMR.Web (mode, reference, date, amounts > 0); balances checked here. @Alloc: [{ GrnId, Amount }]
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupPay_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @SupplierId INT, @Date DATE, @Mode VARCHAR(10), @Reference NVARCHAR(50) = NULL, @Remarks NVARCHAR(300) = NULL, @Alloc NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
    DECLARE @A TABLE (GrnId INT PRIMARY KEY, Amount DECIMAL(14,2), Bal DECIMAL(14,2));
    DECLARE @no NVARCHAR(40), @id INT;
    BEGIN TRY
        BEGIN TRAN;
        INSERT @A (GrnId, Amount, Bal)
        SELECT a.GrnId, a.Amount, b.Bal
          FROM OPENJSON(@Alloc) WITH (GrnId INT, Amount DECIMAL(14,2)) a
          OUTER APPLY (SELECT gr.NetAmount - ISNULL((SELECT SUM(x.Amount) FROM dbo.PhSupplierPaymentAlloc x JOIN dbo.PhSupplierPayment p ON p.PaymentId = x.PaymentId
                                                     WHERE x.GrnId = gr.GrnId AND p.Status = 'POSTED'), 0) AS Bal
                         FROM dbo.PhGrn gr WITH (UPDLOCK)
                        WHERE gr.GrnId = a.GrnId AND gr.CompanyId = @CompanyId AND gr.BranchId = @BranchId AND gr.SupplierId = @SupplierId AND gr.Status = 'POSTED') b;
        IF EXISTS (SELECT 1 FROM @A WHERE Bal IS NULL OR Amount > Bal)
        BEGIN ROLLBACK; SELECT 0 AS Id, N'An amount is more than the bill''s balance.' AS Error; RETURN; END;
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'SPAY', @DocDate = @Date, @DocNo = @no OUTPUT;
        INSERT dbo.PhSupplierPayment (CompanyId, BranchId, PaymentNo, PaymentDate, SupplierId, PaymentMode, ReferenceNo, Amount, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @no, @Date, @SupplierId, @Mode, NULLIF(LTRIM(RTRIM(@Reference)), N''), (SELECT SUM(Amount) FROM @A), @Remarks, @UserId);
        SET @id = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.PhSupplierPaymentAlloc (PaymentId, GrnId, Amount) SELECT @id, GrnId, Amount FROM @A;
        EXEC dbo.usp_Ph_PostLedger @Kind = 'SPAY', @RefId = @id, @UserId = @UserId;   -- Payment voucher (2347)
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
        EXEC dbo.usp_Ph_PostLedger @Kind = 'SPAYX', @RefId = @Id, @UserId = @UserId;   -- reverses the Payment voucher
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

-- ── purchase register: 1 documents, 2 GST summary ────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_Register @CompanyId INT, @BranchId INT, @From DATE, @To DATE, @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 'Purchase' DocType, g.GrnId Id, g.GrnNo DocNo, g.GrnDate DocDate, s.SupplierName, s.Gstin, g.InvoiceNo, g.InvoiceDate,
           g.TaxableAmount Taxable, g.CgstAmount Cgst, g.SgstAmount Sgst, g.IgstAmount Igst, g.OtherCharges Other, g.RoundOff, g.NetAmount Net
      FROM dbo.PhGrn g JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId
     WHERE g.CompanyId = @CompanyId AND g.BranchId = @BranchId AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @From AND @To AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId)
    UNION ALL
    SELECT 'Debit note', r.ReturnId, r.ReturnNo, r.ReturnDate, s.SupplierName, s.Gstin, NULL, NULL,
           -r.TaxableAmount, CASE WHEN r.IsInterState = 1 THEN 0 ELSE -ROUND(r.GstAmount / 2, 2) END, CASE WHEN r.IsInterState = 1 THEN 0 ELSE -(r.GstAmount - ROUND(r.GstAmount / 2, 2)) END,
           CASE WHEN r.IsInterState = 1 THEN -r.GstAmount ELSE 0 END, 0, -r.RoundOff, -r.NetAmount
      FROM dbo.PhPurchaseReturn r JOIN dbo.PhSupplier s ON s.SupplierId = r.SupplierId
     WHERE r.CompanyId = @CompanyId AND r.BranchId = @BranchId AND r.Status = 'POSTED' AND r.ReturnDate BETWEEN @From AND @To AND (@SupplierId IS NULL OR r.SupplierId = @SupplierId)
     ORDER BY DocDate, DocNo;

    SELECT GstPercent, SUM(Taxable) Taxable, SUM(Gst) Gst FROM (
        SELECT d.GstPercent, d.TaxableAmount Taxable, d.GstAmount Gst FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId
         WHERE g.CompanyId = @CompanyId AND g.BranchId = @BranchId AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @From AND @To AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId)
        UNION ALL
        SELECT d.GstPercent, -d.TaxableAmount, -d.GstAmount FROM dbo.PhPurchaseReturnDtl d JOIN dbo.PhPurchaseReturn r ON r.ReturnId = d.ReturnId
         WHERE r.CompanyId = @CompanyId AND r.BranchId = @BranchId AND r.Status = 'POSTED' AND r.ReturnDate BETWEEN @From AND @To AND (@SupplierId IS NULL OR r.SupplierId = @SupplierId)) x
     GROUP BY GstPercent ORDER BY GstPercent;
END
GO

PRINT 'Script 2358 applied: pharmacy purchase - API stored procedures.';
GO
