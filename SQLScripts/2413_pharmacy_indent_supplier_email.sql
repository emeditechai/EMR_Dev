-- ============================================================================================================
-- 2413  Pharmacy purchase indent per supplier, e-mailed on approval, approved through the Approval Matrix (after 2412).
--   * PhPurchaseIndent.SupplierId: the indent is raised on a supplier (required on save); EmailedTo / EmailedDate.
--   * PhSupplier.ReceiveIndentEmail (Supplier master toggle "Receive Indent E-mail"): Yes = when an indent of this
--     supplier is APPROVED, its PDF goes to the supplier's e-mail (EMR.Web, branch SMTP). A "Send to supplier"
--     button re-sends it. A failed e-mail never undoes the approval.
--   * Approval Matrix module PHARMACY.PURCHASEINDENT: the approvers named there (by branch) approve / reject and are
--     told on submit; with no matrix the page's APPROVE control decides (as for stock adjustments / counts).
--   * Indent > purchase order: the order starts on the indent's supplier.
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF COL_LENGTH('dbo.PhSupplier', 'ReceiveIndentEmail') IS NULL
    ALTER TABLE dbo.PhSupplier ADD ReceiveIndentEmail BIT NOT NULL CONSTRAINT DF_PhSupplier_RcvIndentMail DEFAULT (0);
GO
IF COL_LENGTH('dbo.PhPurchaseIndent', 'SupplierId') IS NULL
    ALTER TABLE dbo.PhPurchaseIndent ADD SupplierId INT NULL CONSTRAINT FK_PhPurchaseIndent_Supplier REFERENCES dbo.PhSupplier (SupplierId),
        EmailedTo NVARCHAR(150) NULL, EmailedDate DATETIME NULL;
GO
MERGE dbo.ApprovalModule AS t
USING (VALUES ('PHARMACY.PURCHASEINDENT', N'Pharmacy Purchase Indent', 100)) s (Code, Name, Sort)
ON t.Module_Code = s.Code
WHEN NOT MATCHED THEN INSERT (Module_Code, Module_Name, Sort_Order, IsActive) VALUES (s.Code, s.Name, s.Sort, 1);
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupplier_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SupplierId, SupplierCode, SupplierName, ContactPerson, Phone, Email, Address, City, StateId, Pincode, Gstin, Pan, CreditDays, DrugLicenceNo, DrugLicenceValidTo, BankName, BankAccountNo, BankIfsc, Remarks, ReceiveIndentEmail, IsActive FROM dbo.PhSupplier
     WHERE CompanyId = @CompanyId
     ORDER BY SupplierName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupplier_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @SupplierCode NVARCHAR(20) = NULL,
    @SupplierName NVARCHAR(150) = NULL,
    @ContactPerson NVARCHAR(100) = NULL,
    @Phone NVARCHAR(30) = NULL,
    @Email NVARCHAR(150) = NULL,
    @Address NVARCHAR(300) = NULL,
    @City NVARCHAR(80) = NULL,
    @StateId INT = NULL,
    @Pincode NVARCHAR(10) = NULL,
    @Gstin VARCHAR(15) = NULL,
    @Pan VARCHAR(10) = NULL,
    @CreditDays INT = NULL,
    @DrugLicenceNo NVARCHAR(100) = NULL,
    @DrugLicenceValidTo DATE = NULL,
    @BankName NVARCHAR(100) = NULL,
    @BankAccountNo NVARCHAR(30) = NULL,
    @BankIfsc NVARCHAR(15) = NULL,
    @Remarks NVARCHAR(300) = NULL,
    @ReceiveIndentEmail BIT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF NULLIF(LTRIM(RTRIM(@SupplierCode)), N'') IS NULL
            SELECT @SupplierCode = 'SUP' + RIGHT('0000' + CAST(ISNULL(MAX(SupplierId), 0) + 1 AS VARCHAR(10)), 4) FROM dbo.PhSupplier WITH (UPDLOCK, HOLDLOCK);
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhSupplier (CompanyId, SupplierCode, SupplierName, ContactPerson, Phone, Email, Address, City, StateId, Pincode, Gstin, Pan, CreditDays, DrugLicenceNo, DrugLicenceValidTo, BankName, BankAccountNo, BankIfsc, Remarks, IsActive, CreatedBy, ReceiveIndentEmail)
            VALUES (@CompanyId, @SupplierCode, @SupplierName, @ContactPerson, @Phone, @Email, @Address, @City, @StateId, @Pincode, @Gstin, @Pan, @CreditDays, @DrugLicenceNo, @DrugLicenceValidTo, @BankName, @BankAccountNo, @BankIfsc, @Remarks, @IsActive, @UserId, ISNULL(@ReceiveIndentEmail, 0));
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhSupplier SET SupplierCode = @SupplierCode, SupplierName = @SupplierName, ContactPerson = @ContactPerson, Phone = @Phone, Email = @Email, Address = @Address, City = @City, StateId = @StateId, Pincode = @Pincode, Gstin = @Gstin, Pan = @Pan, CreditDays = @CreditDays, DrugLicenceNo = @DrugLicenceNo, DrugLicenceValidTo = @DrugLicenceValidTo, BankName = @BankName, BankAccountNo = @BankAccountNo, BankIfsc = @BankIfsc, Remarks = @Remarks, ReceiveIndentEmail = ISNULL(@ReceiveIndentEmail, ReceiveIndentEmail), IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE SupplierId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This supplier already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhIndent_Save
    @Id INT, @CompanyId INT, @BranchId INT, @UserId INT, @DocDate DATE, @Priority VARCHAR(10), @Remarks NVARCHAR(300) = NULL, @Lines NVARCHAR(MAX), @SupplierId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @Priority = CASE WHEN @Priority = 'URGENT' THEN 'URGENT' ELSE 'NORMAL' END;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhSupplier WHERE SupplierId = @SupplierId AND CompanyId = @CompanyId AND IsActive = 1)
    BEGIN SELECT 0 AS Id, N'Pick the supplier the indent is for.' AS Error; RETURN; END;
    BEGIN TRAN;
    IF @Id > 0
    BEGIN
        IF ISNULL((SELECT Status FROM dbo.PhPurchaseIndent WITH (UPDLOCK) WHERE IndentId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId), '') <> 'DRAFT'
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a draft indent can be changed.' AS Error; RETURN; END;
        UPDATE dbo.PhPurchaseIndent SET IndentDate = @DocDate, Priority = @Priority, Remarks = @Remarks, SupplierId = @SupplierId, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE IndentId = @Id;
        DELETE dbo.PhPurchaseIndentDtl WHERE IndentId = @Id;
    END
    ELSE
    BEGIN
        INSERT dbo.PhPurchaseIndent (CompanyId, BranchId, IndentDate, Priority, Remarks, CreatedBy, SupplierId) VALUES (@CompanyId, @BranchId, @DocDate, @Priority, @Remarks, @UserId, @SupplierId);
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

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_Get @Kind VARCHAR(10), @CompanyId INT, @BranchId INT, @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Kind = 'indent'
    BEGIN
        SELECT d.IndentId Id, d.IndentNo DocNo, d.IndentDate DocDate, d.Status, d.Priority, d.Remarks, d.ActionRemarks,
               d.SupplierId, (SELECT SupplierName FROM dbo.PhSupplier WHERE SupplierId = d.SupplierId) SupplierName, d.EmailedTo, d.EmailedDate, d.CreatedBy,
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
        SELECT d.GrnId Id, d.GrnNo DocNo, d.GrnDate DocDate, d.Status, d.StoreId, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = d.StoreId) StoreName, d.SupplierId, s.SupplierName, d.PoId RefId, po.PoNo RefNo,
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
        SELECT d.ReturnId Id, d.ReturnNo DocNo, d.ReturnDate DocDate, d.Status, d.StoreId, (SELECT StoreName FROM dbo.PhStore WHERE StoreId = d.StoreId) StoreName, d.SupplierId, s.SupplierName, d.ReasonId, d.IsInterState,
               d.Remarks, d.TaxableAmount, d.GstAmount, d.RoundOff, d.NetAmount, cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.PostedDate ApprovedDate
          FROM dbo.PhPurchaseReturn d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.CreatedBy) cb
          OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = d.PostedBy) ab
         WHERE d.ReturnId = @Id AND d.CompanyId = @CompanyId AND d.BranchId = @BranchId;
        SELECT x.ReturnDtlId LineId, x.ItemId, x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.Qty, x.Rate, x.GstPercent, x.TaxableAmount, x.GstAmount,
               ISNULL((SELECT QtyOnHand FROM dbo.PhStoreStock st WHERE st.BatchId = x.BatchId AND st.StoreId = (SELECT ISNULL(r.StoreId, dbo.fn_PhDefaultStore(r.BranchId, 'RECEIVE')) FROM dbo.PhPurchaseReturn r WHERE r.ReturnId = @Id)), 0) Stock
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

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_List
    @Kind VARCHAR(10), @CompanyId INT, @BranchId INT, @Status VARCHAR(10) = NULL, @Search NVARCHAR(200) = NULL, @From DATE = NULL, @To DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(210) = N'%' + @Search + N'%';
    IF @Kind = 'indent'
        SELECT TOP 500 * FROM (
            SELECT d.IndentId Id, d.IndentNo DocNo, d.IndentDate DocDate, ISNULL((SELECT SupplierName FROM dbo.PhSupplier WHERE SupplierId = d.SupplierId), u.Name) Party, d.Priority Ref, d.Status,
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

-- supplier details on purchase documents: + Receive Indent E-mail
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_SupplierInfo @CompanyId INT, @BranchId INT, @SupplierId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.SupplierId, s.SupplierName, s.Gstin, s.Email, s.ReceiveIndentEmail, s.CreditDays, s.DrugLicenceValidTo,
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

-- indent mailed to the supplier
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhIndent_MarkEmailed @IndentId INT, @Email NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PhPurchaseIndent SET EmailedTo = @Email, EmailedDate = GETDATE() WHERE IndentId = @IndentId;
END
GO

-- endpoints: indent supplier info / e-mail; Supplier master unchanged pages
DECLARE @co INT, @page INT, @view INT, @ctl INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @page = NULL; SET @view = NULL;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = 'PHARMACY.PURCHASEINDENT' AND CompanyId = @co;
    SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhPurchaseIndents', @Action = N'SupplierInfo', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhPurchaseIndents', @Action = N'Pdf', @Source = 'SEED';
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EMAIL', @Title = N'E-mail the indent to the supplier', @Sort_Order = 70, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhPurchaseIndents', @Action = N'Email', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2413 applied: purchase indent per supplier, e-mailed on approval, Approval Matrix.';
GO
