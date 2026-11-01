-- ============================================================================================================
-- Migration: 2367_pharmacy_bill_reader.sql
-- Pharmacy > Purchase Order / GRN: "Read bill" - the supplier's bill (PDF or photo) is read on the server (EMR.Api: PdfPig text,
-- Tesseract OCR, ML.NET column and item matching) and fills the form for the user to check.
--   PhBillItemAlias: what a supplier prints for an item -> the Item Master item, learnt when the user saves a form filled from a bill.
--   usp_Api_PhBill_Catalog: items, suppliers and learnt names the reader matches against.
--   usp_Api_PhBill_Learn: remember the user's confirmed matches.   usp_Api_PhBill_ItemInfo: the form's item details for matched items.
-- Run after 2366. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.PhBillItemAlias') IS NULL
CREATE TABLE dbo.PhBillItemAlias (
    AliasId    INT IDENTITY PRIMARY KEY,
    CompanyId  INT NOT NULL,
    SupplierId INT NOT NULL DEFAULT 0,          -- 0 = any supplier
    BillText   NVARCHAR(200) NOT NULL,          -- normalised (upper case, single spaces)
    ItemId     INT NOT NULL,
    Hits       INT NOT NULL DEFAULT 1,
    LastUsed   DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT UQ_PhBillItemAlias UNIQUE (CompanyId, SupplierId, BillText)
);
GO

-- 1 items, 2 suppliers, 3 learnt names
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhBill_Catalog @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT i.ItemId, i.ItemCode, i.ItemName, i.Strength, i.PackSize, g.GenericName, m.ManufacturerName, i.Barcode, h.GstPercent, i.ConversionQty
      FROM dbo.PhItem i JOIN dbo.PhHsn h ON h.HsnId = i.HsnId
      LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
     WHERE i.CompanyId = @CompanyId AND i.IsActive = 1;
    SELECT SupplierId, SupplierName, Gstin, DrugLicenceNo, Phone FROM dbo.PhSupplier WHERE CompanyId = @CompanyId AND IsActive = 1;
    SELECT SupplierId, BillText, ItemId, Hits FROM dbo.PhBillItemAlias WHERE CompanyId = @CompanyId;
END
GO

-- @Pairs: [{ "BillText", "ItemId" }] confirmed by the user; remembered for the supplier and for any supplier
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhBill_Learn @CompanyId INT, @SupplierId INT = NULL, @Pairs NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @P TABLE (BillText NVARCHAR(200), ItemId INT);
    INSERT @P SELECT DISTINCT UPPER(LTRIM(RTRIM(LEFT(JSON_VALUE(value, '$.BillText'), 200)))), JSON_VALUE(value, '$.ItemId') FROM OPENJSON(@Pairs);
    DELETE p FROM @P p WHERE ISNULL(p.BillText, N'') = N'' OR NOT EXISTS (SELECT 1 FROM dbo.PhItem i WHERE i.ItemId = p.ItemId AND i.CompanyId = @CompanyId);
    DECLARE @S TABLE (SupplierId INT);
    INSERT @S VALUES (0);
    IF ISNULL(@SupplierId, 0) > 0 AND EXISTS (SELECT 1 FROM dbo.PhSupplier WHERE SupplierId = @SupplierId AND CompanyId = @CompanyId) INSERT @S VALUES (@SupplierId);
    MERGE dbo.PhBillItemAlias AS t
    USING (SELECT s.SupplierId, p.BillText, p.ItemId FROM @P p CROSS JOIN @S s) AS x
       ON t.CompanyId = @CompanyId AND t.SupplierId = x.SupplierId AND t.BillText = x.BillText
    WHEN MATCHED THEN UPDATE SET ItemId = x.ItemId, Hits = CASE WHEN t.ItemId = x.ItemId THEN t.Hits + 1 ELSE 1 END, LastUsed = GETDATE()
    WHEN NOT MATCHED THEN INSERT (CompanyId, SupplierId, BillText, ItemId) VALUES (@CompanyId, x.SupplierId, x.BillText, x.ItemId);
    SELECT @@ROWCOUNT AS Saved;
END
GO

-- the form's item details (as the item picker gives them) for the matched items. @Ids: "1,2,3"
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhBill_ItemInfo @CompanyId INT, @BranchId INT, @Ids NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f WHERE f.ItemId IN (SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(@Ids, ','));
END
GO

-- ── Read bill / learn: allowed with the page's SAVE control (Purchase Order, GRN) ─────────────────────────
DECLARE @pg INT, @ctl INT, @c NVARCHAR(60), @code NVARCHAR(60);
DECLARE k CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.Page_ID, pc.Control_ID, p.Controller FROM dbo.PageMaster p JOIN dbo.PageControlMaster pc ON pc.Page_ID = p.Page_ID AND pc.Control_Code = 'SAVE'
     WHERE p.Page_Code IN (N'PHARMACY.PURCHASEORDER', N'PHARMACY.GRN');
OPEN k; FETCH NEXT FROM k INTO @pg, @ctl, @c;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pg, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = @c, @Action = N'ReadBill', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pg, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = @c, @Action = N'LearnBill', @Source = 'SEED';
    FETCH NEXT FROM k INTO @pg, @ctl, @c;
END
CLOSE k; DEALLOCATE k;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2367 applied: pharmacy bill reader (learnt item names, catalogue).';
GO
