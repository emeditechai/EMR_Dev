-- ============================================================================================================
-- Migration: 2370_pharmacy_reports_gst.sql
-- Reports > Pharmacy, GST & tax reports (G1-G6 of the Pharmacy Reports plan), in the government's formats.
--   G1 GSTR-1 summary (B2B, B2C small, credit notes; with the GSTR-1 Excel in the GSTN offline-tool layout)
--   G2 HSN-wise summary of outward supplies (GSTR-1 Table 12, B2B and B2C, UQC codes)   G3 Credit note register (sale returns)
--   G4 Purchase GST (input tax) register in the GSTR-2B layout, with reconciliation against the downloaded GSTR-2B Excel
--   G5 GSTR-3B working (Tables 3.1 and 4, net tax)   G6 Rate-wise sales & purchase summary
--   Branch GSTIN = Hospital Settings > Pharmacy GSTIN, else the company's GSTIN. Place of supply = the branch's state (counter sales);
--   B2B = a bill to a pharmacy customer with a GSTIN. Pharmacy sales are within the state (CGST + SGST); purchases are IGST when inter-state.
--   PhUom.UqcCode: the GST Unique Quantity Code of each unit (official list), filled for the standard units.
-- Run after 2369. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.PhUom', 'UqcCode') IS NULL ALTER TABLE dbo.PhUom ADD UqcCode VARCHAR(5) NULL;
GO
UPDATE dbo.PhUom SET UqcCode = CASE UPPER(UomCode)
        WHEN 'TAB' THEN 'TBS' WHEN 'CAP' THEN 'NOS' WHEN 'STRIP' THEN 'PAC' WHEN 'BOX' THEN 'BOX' WHEN 'BTL' THEN 'BTL' WHEN 'VIAL' THEN 'NOS'
        WHEN 'AMP' THEN 'NOS' WHEN 'TUBE' THEN 'TUB' WHEN 'SACHET' THEN 'PAC' WHEN 'NOS' THEN 'NOS' WHEN 'PAIR' THEN 'PRS' WHEN 'PKT' THEN 'PAC'
        WHEN 'ROLL' THEN 'ROL' WHEN 'ML' THEN 'MLT' WHEN 'GM' THEN 'GMS' WHEN 'KG' THEN 'KGS' WHEN 'LTR' THEN 'LTR' WHEN 'SET' THEN 'SET' WHEN 'PCS' THEN 'PCS'
        ELSE 'OTH' END
 WHERE UqcCode IS NULL;
GO

-- unit master: the UQC code is chosen on the Unit of Measure page
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhUom_GetList @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT UomId, UomCode, UomName, UqcCode, SortOrder, IsActive FROM dbo.PhUom WHERE CompanyId = @CompanyId ORDER BY SortOrder, UomCode;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhUom_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @UomCode NVARCHAR(10) = NULL, @UomName NVARCHAR(50) = NULL, @SortOrder INT = NULL, @UqcCode VARCHAR(5) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhUom (CompanyId, UomCode, UomName, SortOrder, IsActive, CreatedBy, UqcCode) VALUES (@CompanyId, @UomCode, @UomName, @SortOrder, @IsActive, @UserId, ISNULL(@UqcCode, 'OTH'));
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhUom SET UomCode = @UomCode, UomName = @UomName, SortOrder = @SortOrder, UqcCode = ISNULL(@UqcCode, UqcCode), IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE UomId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This unit already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- "19-West Bengal": the GST state code and name, from a GSTIN or a state name
CREATE OR ALTER FUNCTION dbo.fn_GstState (@GstinOrState NVARCHAR(100))
RETURNS NVARCHAR(60)
AS
BEGIN
    DECLARE @v NVARCHAR(100) = LTRIM(RTRIM(ISNULL(@GstinOrState, N''))), @code CHAR(2);
    DECLARE @S TABLE (Code CHAR(2), Name NVARCHAR(50));
    INSERT @S VALUES ('01',N'Jammu and Kashmir'),('02',N'Himachal Pradesh'),('03',N'Punjab'),('04',N'Chandigarh'),('05',N'Uttarakhand'),('06',N'Haryana'),('07',N'Delhi'),
        ('08',N'Rajasthan'),('09',N'Uttar Pradesh'),('10',N'Bihar'),('11',N'Sikkim'),('12',N'Arunachal Pradesh'),('13',N'Nagaland'),('14',N'Manipur'),('15',N'Mizoram'),
        ('16',N'Tripura'),('17',N'Meghalaya'),('18',N'Assam'),('19',N'West Bengal'),('20',N'Jharkhand'),('21',N'Odisha'),('22',N'Chhattisgarh'),('23',N'Madhya Pradesh'),
        ('24',N'Gujarat'),('26',N'Dadra and Nagar Haveli and Daman and Diu'),('27',N'Maharashtra'),('29',N'Karnataka'),('30',N'Goa'),('31',N'Lakshadweep'),('32',N'Kerala'),
        ('33',N'Tamil Nadu'),('34',N'Puducherry'),('35',N'Andaman and Nicobar Islands'),('36',N'Telangana'),('37',N'Andhra Pradesh'),('38',N'Ladakh'),('97',N'Other Territory');
    IF @v LIKE '[0-9][0-9]%' SET @code = LEFT(@v, 2);
    ELSE SELECT TOP 1 @code = Code FROM @S WHERE Name = @v OR REPLACE(Name, N' and ', N' & ') = @v OR (@v = N'Orissa' AND Code = '21') OR (@v = N'Pondicherry' AND Code = '34');
    RETURN (SELECT TOP 1 Code + N'-' + Name FROM @S WHERE Code = @code);
END
GO

-- the branch's GSTIN and place of supply
CREATE OR ALTER FUNCTION dbo.fn_PhBranchGst (@BranchId INT)
RETURNS TABLE
AS
RETURN
    SELECT b.BranchID AS BranchId, b.BranchName, b.BranchCode, x.Gstin,
           ISNULL(dbo.fn_GstState(x.Gstin), dbo.fn_GstState(b.State)) AS PlaceOfSupply
      FROM dbo.BranchMaster b
     CROSS APPLY (SELECT COALESCE(NULLIF((SELECT TOP 1 h.PharmacyGstin FROM dbo.HospitalSettings h WHERE h.BranchId = b.BranchID ORDER BY h.IsActive DESC), N''),
                                  (SELECT TOP 1 c.GSTIN FROM dbo.CompanyMaster c WHERE c.CompanyId = b.CompanyId)) AS Gstin) x
     WHERE b.BranchID = @BranchId;
GO

-- outward supply lines of a period (sales +, sale returns -), each with its GST split - the base of G1, G2, G5, G6
CREATE OR ALTER FUNCTION dbo.fn_PhGstOutward (@CompanyId INT, @BranchId INT, @From DATE, @To DATE)
RETURNS TABLE
AS
RETURN
    SELECT 'INV' AS DocKind, s.SaleId AS DocId, s.SaleNo AS DocNo, CAST(s.SaleDate AS DATE) AS DocDate, s.SaleId, s.SaleNo, CAST(s.SaleDate AS DATE) AS SaleDate,
           s.BranchId, NULLIF(LTRIM(RTRIM(c.Gstin)), N'') AS CustomerGstin, ISNULL(c.CustomerName, s.CustomerName) AS CustomerName,
           d.ItemId, i.ItemName, h.HsnCode, h.Description AS HsnDescription, ISNULL(u.UqcCode, 'OTH') AS Uqc, d.Qty AS Qty, d.GstPercent AS Rate,
           d.TaxableAmount AS Taxable, ROUND(d.GstAmount / 2, 2) AS Cgst, d.GstAmount - ROUND(d.GstAmount / 2, 2) AS Sgst, CAST(0 AS DECIMAL(18,2)) AS Igst,
           s.NetAmount AS DocValue
      FROM dbo.PhSale s JOIN dbo.PhSaleDtl d ON d.SaleId = s.SaleId JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhHsn h ON h.HsnId = i.HsnId
      JOIN dbo.PhUom u ON u.UomId = i.SaleUomId LEFT JOIN dbo.PhCustomer c ON c.CustomerId = s.CustomerId
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED'
       AND s.SaleDate >= @From AND s.SaleDate < DATEADD(DAY, 1, CAST(@To AS DATETIME))
    UNION ALL
    SELECT 'CN', r.ReturnId, r.ReturnNo, CAST(r.ReturnDate AS DATE), s.SaleId, s.SaleNo, CAST(s.SaleDate AS DATE),
           r.BranchId, NULLIF(LTRIM(RTRIM(c.Gstin)), N''), ISNULL(c.CustomerName, s.CustomerName),
           rd.ItemId, i.ItemName, h.HsnCode, h.Description, ISNULL(u.UqcCode, 'OTH'), -rd.Qty, sd.GstPercent,
           -rd.TaxableAmount, -ROUND(rd.GstAmount / 2, 2), -(rd.GstAmount - ROUND(rd.GstAmount / 2, 2)), 0, r.NetAmount
      FROM dbo.PhSaleReturn r JOIN dbo.PhSaleReturnDtl rd ON rd.ReturnId = r.ReturnId JOIN dbo.PhSaleDtl sd ON sd.SaleDtlId = rd.SaleDtlId
      JOIN dbo.PhSale s ON s.SaleId = r.SaleId JOIN dbo.PhItem i ON i.ItemId = rd.ItemId JOIN dbo.PhHsn h ON h.HsnId = i.HsnId
      JOIN dbo.PhUom u ON u.UomId = i.SaleUomId LEFT JOIN dbo.PhCustomer c ON c.CustomerId = s.CustomerId
     WHERE r.CompanyId = @CompanyId AND (@BranchId IS NULL OR r.BranchId = @BranchId) AND ISNULL(r.Status, 'POSTED') = 'POSTED'
       AND r.ReturnDate >= @From AND r.ReturnDate < DATEADD(DAY, 1, CAST(@To AS DATETIME));
GO

-- inward supplies (purchases +, debit notes -) by document and rate - the base of G4, G5, G6
CREATE OR ALTER FUNCTION dbo.fn_PhGstInward (@CompanyId INT, @BranchId INT, @From DATE, @To DATE)
RETURNS TABLE
AS
RETURN
    SELECT 'INV' AS DocKind, g.GrnId AS DocId, g.GrnNo AS BookNo, g.SupplierId, s.SupplierName, NULLIF(LTRIM(RTRIM(s.Gstin)), N'') AS SupplierGstin,
           g.InvoiceNo AS DocNo, g.InvoiceDate AS DocDate, g.GrnDate AS BookDate, g.NetAmount AS DocValue, g.IsInterState, g.BranchId,
           d.GstPercent AS Rate, SUM(d.TaxableAmount) AS Taxable,
           SUM(CASE WHEN g.IsInterState = 1 THEN d.GstAmount ELSE 0 END) AS Igst,
           SUM(CASE WHEN g.IsInterState = 1 THEN 0 ELSE ROUND(d.GstAmount / 2, 2) END) AS Cgst,
           SUM(CASE WHEN g.IsInterState = 1 THEN 0 ELSE d.GstAmount - ROUND(d.GstAmount / 2, 2) END) AS Sgst
      FROM dbo.PhGrn g JOIN dbo.PhGrnDtl d ON d.GrnId = g.GrnId JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId
     WHERE g.CompanyId = @CompanyId AND (@BranchId IS NULL OR g.BranchId = @BranchId) AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @From AND @To
     GROUP BY g.GrnId, g.GrnNo, g.SupplierId, s.SupplierName, s.Gstin, g.InvoiceNo, g.InvoiceDate, g.GrnDate, g.NetAmount, g.IsInterState, g.BranchId, d.GstPercent
    UNION ALL
    SELECT 'DN', r.ReturnId, r.ReturnNo, r.SupplierId, s.SupplierName, NULLIF(LTRIM(RTRIM(s.Gstin)), N''), r.ReturnNo, r.ReturnDate, r.ReturnDate, -r.NetAmount,
           r.IsInterState, r.BranchId, d.GstPercent, -SUM(d.TaxableAmount),
           -SUM(CASE WHEN r.IsInterState = 1 THEN d.GstAmount ELSE 0 END),
           -SUM(CASE WHEN r.IsInterState = 1 THEN 0 ELSE ROUND(d.GstAmount / 2, 2) END),
           -SUM(CASE WHEN r.IsInterState = 1 THEN 0 ELSE d.GstAmount - ROUND(d.GstAmount / 2, 2) END)
      FROM dbo.PhPurchaseReturn r JOIN dbo.PhPurchaseReturnDtl d ON d.ReturnId = r.ReturnId JOIN dbo.PhSupplier s ON s.SupplierId = r.SupplierId
     WHERE r.CompanyId = @CompanyId AND (@BranchId IS NULL OR r.BranchId = @BranchId) AND r.Status = 'POSTED' AND r.ReturnDate BETWEEN @From AND @To
     GROUP BY r.ReturnId, r.ReturnNo, r.SupplierId, s.SupplierName, s.Gstin, r.ReturnDate, r.NetAmount, r.IsInterState, r.BranchId, d.GstPercent;
GO

-- ── G1 GSTR-1 summary: B2B invoices, B2C (small) and credit notes, rate-wise ─────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_Gstr1Summary
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT o.*, ISNULL(bg.PlaceOfSupply, N'') AS Pos,
           CASE WHEN o.CustomerGstin IS NOT NULL THEN CASE o.DocKind WHEN 'INV' THEN 'B2B' ELSE 'CDNR' END ELSE 'B2CS' END AS Section
      INTO #O FROM dbo.fn_PhGstOutward(@CompanyId, @BranchId, @From, @To) o OUTER APPLY dbo.fn_PhBranchGst(o.BranchId) bg;
    SELECT ROW_NUMBER() OVER (ORDER BY CASE Section WHEN 'B2B' THEN 1 WHEN 'B2CS' THEN 2 ELSE 3 END, Pos, Rate) AS Rn,
           CASE Section WHEN 'B2B' THEN N'4A - B2B invoices' WHEN 'B2CS' THEN N'7 - B2C (others), net of credit notes' ELSE N'9B - Credit notes (registered)' END AS SectionName,
           Section, Pos AS PlaceOfSupply, Rate, COUNT(DISTINCT CASE WHEN DocKind = 'INV' THEN DocId END) AS Invoices, COUNT(DISTINCT CASE WHEN DocKind = 'CN' THEN DocId END) AS CreditNotes,
           SUM(Taxable) AS Taxable, SUM(Igst) AS Igst, SUM(Cgst) AS Cgst, SUM(Sgst) AS Sgst, CAST(0 AS DECIMAL(18,2)) AS Cess, SUM(Taxable + Igst + Cgst + Sgst) AS Total
      INTO #R FROM #O GROUP BY Section, Pos, Rate;

    SELECT ISNULL(SUM(Taxable), 0) AS Taxable, ISNULL(SUM(Cgst + Sgst + Igst), 0) AS Tax,
           (SELECT COUNT(DISTINCT DocId) FROM #O WHERE DocKind = 'INV') AS Invoices, (SELECT COUNT(DISTINCT DocId) FROM #O WHERE DocKind = 'CN') AS CreditNotes,
           ISNULL(SUM(CASE WHEN Section = 'B2B' THEN Taxable END), 0) AS B2bTaxable,
           (SELECT TOP 1 Gstin FROM dbo.fn_PhBranchGst(ISNULL(@BranchId, (SELECT TOP 1 BranchID FROM dbo.BranchMaster WHERE CompanyId = @CompanyId AND IsHOBranch = 1)))) AS Gstin
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Invoices) AS Invoices, SUM(CreditNotes) AS CreditNotes, SUM(Taxable) AS Taxable, SUM(Igst) AS Igst, SUM(Cgst) AS Cgst, SUM(Sgst) AS Sgst,
           SUM(Cess) AS Cess, SUM(Total) AS Total
      FROM #R;
END
GO

-- ── G2 HSN-wise summary of outward supplies (GSTR-1 Table 12), net of credit notes; @Option B2B / B2C ─────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_HsnSummary
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ROW_NUMBER() OVER (ORDER BY o.HsnCode, o.Rate, o.Uqc) AS Rn, o.HsnCode AS Hsn, MAX(o.HsnDescription) AS Description, o.Uqc, SUM(o.Qty) AS TotalQuantity,
           SUM(o.Taxable + o.Igst + o.Cgst + o.Sgst) AS TotalValue, o.Rate, SUM(o.Taxable) AS Taxable, SUM(o.Igst) AS Igst, SUM(o.Cgst) AS Cgst, SUM(o.Sgst) AS Sgst,
           CAST(0 AS DECIMAL(18,2)) AS Cess
      INTO #R
      FROM dbo.fn_PhGstOutward(@CompanyId, @BranchId, @From, @To) o
     WHERE @Option IS NULL OR (@Option = 'B2B' AND o.CustomerGstin IS NOT NULL) OR (@Option = 'B2C' AND o.CustomerGstin IS NULL)
     GROUP BY o.HsnCode, o.Rate, o.Uqc;

    SELECT COUNT(DISTINCT Hsn) AS HsnCodes, ISNULL(SUM(Taxable), 0) AS Taxable, ISNULL(SUM(Cgst + Sgst + Igst), 0) AS Tax, ISNULL(SUM(TotalValue), 0) AS TotalValue FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(TotalValue) AS TotalValue, SUM(Taxable) AS Taxable, SUM(Igst) AS Igst, SUM(Cgst) AS Cgst, SUM(Sgst) AS Sgst, SUM(Cess) AS Cess FROM #R;
END
GO

-- ── G3 Credit note register (sale returns), note by note and rate ────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_CreditNotes
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT ROW_NUMBER() OVER (ORDER BY o.DocDate, o.DocId, o.Rate) AS Rn, br.BranchCode, o.DocId AS ReturnId, o.DocNo AS NoteNo, o.DocDate AS NoteDate, 'C' AS NoteType,
           o.SaleId, o.SaleNo AS OriginalBill, o.SaleDate AS OriginalDate, o.CustomerName, o.CustomerGstin,
           CASE WHEN o.CustomerGstin IS NULL THEN N'B2C (in B2CS)' ELSE N'CDNR' END AS Gstr1Section, o.Rate,
           -SUM(o.Taxable) AS Taxable, -SUM(o.Cgst) AS Cgst, -SUM(o.Sgst) AS Sgst, -SUM(o.Igst) AS Igst, -SUM(o.Taxable + o.Cgst + o.Sgst + o.Igst) AS NoteValue
      INTO #R
      FROM dbo.fn_PhGstOutward(@CompanyId, @BranchId, @From, @To) o JOIN dbo.BranchMaster br ON br.BranchID = o.BranchId
     WHERE o.DocKind = 'CN' AND (@Search IS NULL OR o.DocNo LIKE @like OR o.SaleNo LIKE @like OR o.CustomerName LIKE @like)
       AND (@Option IS NULL OR (@Option = 'B2B' AND o.CustomerGstin IS NOT NULL) OR (@Option = 'B2C' AND o.CustomerGstin IS NULL))
     GROUP BY br.BranchCode, o.DocId, o.DocNo, o.DocDate, o.SaleId, o.SaleNo, o.SaleDate, o.CustomerName, o.CustomerGstin, o.Rate;

    SELECT COUNT(DISTINCT ReturnId) AS Notes, ISNULL(SUM(Taxable), 0) AS Taxable, ISNULL(SUM(Cgst + Sgst + Igst), 0) AS Tax, ISNULL(SUM(NoteValue), 0) AS NoteValue,
           COUNT(DISTINCT CASE WHEN CustomerGstin IS NOT NULL THEN ReturnId END) AS Registered
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Taxable) AS Taxable, SUM(Cgst) AS Cgst, SUM(Sgst) AS Sgst, SUM(Igst) AS Igst, SUM(NoteValue) AS NoteValue FROM #R;
END
GO

-- ── G4 Purchase GST (input tax) register, GSTR-2B layout: one row per supplier invoice and rate ────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_PurchaseItc
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT ROW_NUMBER() OVER (ORDER BY x.BookDate, x.DocKind DESC, x.DocId, x.Rate) AS Rn, x.DocId, x.DocKind,
           CASE x.DocKind WHEN 'INV' THEN N'Invoice' ELSE N'Debit note' END AS DocType, x.SupplierGstin, x.SupplierName, x.DocNo AS InvoiceNo,
           CASE x.DocKind WHEN 'INV' THEN N'Regular' ELSE N'Debit note (purchase return)' END AS InvoiceType, x.DocDate AS InvoiceDate, x.DocValue AS InvoiceValue,
           ISNULL(dbo.fn_GstState(x.SupplierGstin), N'') AS PlaceOfSupply, 'N' AS ReverseCharge, x.Rate, x.Taxable, x.Igst, x.Cgst, x.Sgst, CAST(0 AS DECIMAL(18,2)) AS Cess,
           x.BookNo AS GrnNo, x.BookDate AS GrnDate,
           CASE WHEN x.SupplierGstin IS NULL THEN N'No GSTIN: no ITC' ELSE N'' END AS Remark
      INTO #R
      FROM dbo.fn_PhGstInward(@CompanyId, @BranchId, @From, @To) x
     WHERE (@SupplierId IS NULL OR x.SupplierId = @SupplierId) AND (@Option IS NULL OR (@Option = 'INV' AND x.DocKind = 'INV') OR (@Option = 'DN' AND x.DocKind = 'DN'))
       AND (@Search IS NULL OR x.DocNo LIKE @like OR x.SupplierName LIKE @like OR x.SupplierGstin LIKE @like OR x.BookNo LIKE @like);

    SELECT COUNT(DISTINCT CASE WHEN DocKind = 'INV' THEN DocId END) AS Invoices, ISNULL(SUM(Taxable), 0) AS Taxable,
           ISNULL(SUM(CASE WHEN SupplierGstin IS NOT NULL THEN Igst + Cgst + Sgst END), 0) AS Itc, ISNULL(SUM(Igst), 0) AS Igst, ISNULL(SUM(Cgst + Sgst), 0) AS CgstSgst,
           COUNT(DISTINCT CASE WHEN SupplierGstin IS NULL THEN DocId END) AS NoGstin
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Taxable) AS Taxable, SUM(Igst) AS Igst, SUM(Cgst) AS Cgst, SUM(Sgst) AS Sgst, SUM(Cess) AS Cess FROM #R;
END
GO

-- ── G5 GSTR-3B working: Table 3.1 (outward), Table 4 (ITC), net tax ───────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_Gstr3b
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @oT DECIMAL(18,2), @oI DECIMAL(18,2), @oC DECIMAL(18,2), @oS DECIMAL(18,2), @nil DECIMAL(18,2);
    SELECT @oT = ISNULL(SUM(CASE WHEN Rate > 0 THEN Taxable END), 0), @oI = ISNULL(SUM(Igst), 0), @oC = ISNULL(SUM(Cgst), 0), @oS = ISNULL(SUM(Sgst), 0),
           @nil = ISNULL(SUM(CASE WHEN Rate = 0 THEN Taxable END), 0)
      FROM dbo.fn_PhGstOutward(@CompanyId, @BranchId, @From, @To);
    DECLARE @iI DECIMAL(18,2), @iC DECIMAL(18,2), @iS DECIMAL(18,2), @dI DECIMAL(18,2), @dC DECIMAL(18,2), @dS DECIMAL(18,2);
    SELECT @iI = ISNULL(SUM(CASE WHEN DocKind = 'INV' THEN Igst END), 0), @iC = ISNULL(SUM(CASE WHEN DocKind = 'INV' THEN Cgst END), 0), @iS = ISNULL(SUM(CASE WHEN DocKind = 'INV' THEN Sgst END), 0),
           @dI = ISNULL(-SUM(CASE WHEN DocKind = 'DN' THEN Igst END), 0), @dC = ISNULL(-SUM(CASE WHEN DocKind = 'DN' THEN Cgst END), 0), @dS = ISNULL(-SUM(CASE WHEN DocKind = 'DN' THEN Sgst END), 0)
      FROM dbo.fn_PhGstInward(@CompanyId, @BranchId, @From, @To) WHERE SupplierGstin IS NOT NULL;
    DECLARE @R TABLE (Rn INT IDENTITY, Tbl NVARCHAR(10), Nature NVARCHAR(200), Taxable DECIMAL(18,2), Igst DECIMAL(18,2), Cgst DECIMAL(18,2), Sgst DECIMAL(18,2), Cess DECIMAL(18,2), Kind VARCHAR(10));
    INSERT @R (Tbl, Nature, Taxable, Igst, Cgst, Sgst, Cess, Kind) VALUES
        (N'3.1 (a)', N'Outward taxable supplies (other than zero rated, nil rated and exempted)', @oT, @oI, @oC, @oS, 0, 'OUT'),
        (N'3.1 (b)', N'Outward taxable supplies (zero rated)', 0, 0, 0, 0, 0, 'OUT'),
        (N'3.1 (c)', N'Other outward supplies (nil rated, exempted)', @nil, NULL, NULL, NULL, NULL, 'OUT'),
        (N'3.1 (d)', N'Inward supplies (liable to reverse charge)', 0, 0, 0, 0, 0, 'OUT'),
        (N'3.1 (e)', N'Non-GST outward supplies', 0, NULL, NULL, NULL, NULL, 'OUT'),
        (N'4 (A)(5)', N'ITC available - all other ITC', NULL, @iI, @iC, @iS, 0, 'ITC'),
        (N'4 (B)(2)', N'ITC reversed - others (debit notes / purchase returns)', NULL, @dI, @dC, @dS, 0, 'REV'),
        (N'4 (C)', N'Net ITC available (A - B)', NULL, @iI - @dI, @iC - @dC, @iS - @dS, 0, 'NET'),
        (N'6.1', N'Tax payable before set-off (3.1 (a) tax)', NULL, @oI, @oC, @oS, 0, 'PAY'),
        (N'6.1', N'Net tax after ITC (payable; minus = credit carried forward)', NULL, @oI - (@iI - @dI), @oC - (@iC - @dC), @oS - (@iS - @dS), 0, 'BAL');

    SELECT @oT AS OutwardTaxable, @oI + @oC + @oS AS OutputTax, (@iI - @dI) + (@iC - @dC) + (@iS - @dS) AS NetItc,
           (@oI + @oC + @oS) - ((@iI - @dI) + (@iC - @dC) + (@iS - @dS)) AS NetTax;
    SELECT Rn, Tbl, Nature, Taxable, Igst, Cgst, Sgst, Cess, Kind FROM @R ORDER BY Rn;
    SELECT COUNT(*) AS TotalRows FROM @R;
END
GO

-- ── G6 Rate-wise sales & purchase summary ────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_GstRateSummary
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Rate, SUM(CASE WHEN DocKind = 'INV' THEN Taxable END) AS ST, SUM(CASE WHEN DocKind = 'INV' THEN Cgst + Sgst + Igst END) AS SX,
           -SUM(CASE WHEN DocKind = 'CN' THEN Taxable END) AS RT, -SUM(CASE WHEN DocKind = 'CN' THEN Cgst + Sgst + Igst END) AS RX
      INTO #O FROM dbo.fn_PhGstOutward(@CompanyId, @BranchId, @From, @To) GROUP BY Rate;
    SELECT Rate, SUM(CASE WHEN DocKind = 'INV' THEN Taxable END) AS PT, SUM(CASE WHEN DocKind = 'INV' THEN Igst + Cgst + Sgst END) AS PX,
           -SUM(CASE WHEN DocKind = 'DN' THEN Taxable END) AS DT, -SUM(CASE WHEN DocKind = 'DN' THEN Igst + Cgst + Sgst END) AS DX
      INTO #I FROM dbo.fn_PhGstInward(@CompanyId, @BranchId, @From, @To) GROUP BY Rate;
    SELECT ROW_NUMBER() OVER (ORDER BY r.Rate) AS Rn, r.Rate,
           ISNULL(o.ST, 0) AS SalesTaxable, ISNULL(o.SX, 0) AS SalesTax, ISNULL(o.RT, 0) AS ReturnsTaxable, ISNULL(o.RX, 0) AS ReturnsTax,
           ISNULL(o.ST, 0) - ISNULL(o.RT, 0) AS NetSalesTaxable, ISNULL(o.SX, 0) - ISNULL(o.RX, 0) AS OutputTax,
           ISNULL(i.PT, 0) AS PurchaseTaxable, ISNULL(i.PX, 0) AS PurchaseTax, ISNULL(i.DT, 0) AS DebitNotesTaxable,
           ISNULL(i.PT, 0) - ISNULL(i.DT, 0) AS NetPurchaseTaxable, ISNULL(i.PX, 0) - ISNULL(i.DX, 0) AS InputTax,
           (ISNULL(o.SX, 0) - ISNULL(o.RX, 0)) - (ISNULL(i.PX, 0) - ISNULL(i.DX, 0)) AS NetTax
      INTO #R
      FROM (SELECT v AS Rate FROM (VALUES (0.0), (5.0), (12.0), (18.0), (28.0)) t (v) UNION SELECT Rate FROM #O UNION SELECT Rate FROM #I) r
      LEFT JOIN #O o ON o.Rate = r.Rate LEFT JOIN #I i ON i.Rate = r.Rate;

    SELECT ISNULL(SUM(NetSalesTaxable), 0) AS SalesTaxable, ISNULL(SUM(OutputTax), 0) AS OutputTax, ISNULL(SUM(NetPurchaseTaxable), 0) AS PurchaseTaxable,
           ISNULL(SUM(InputTax), 0) AS InputTax, ISNULL(SUM(NetTax), 0) AS NetTax
      FROM #R;
    SELECT * FROM #R ORDER BY Rn;
    SELECT COUNT(*) AS TotalRows, SUM(SalesTaxable) AS SalesTaxable, SUM(SalesTax) AS SalesTax, SUM(ReturnsTaxable) AS ReturnsTaxable, SUM(ReturnsTax) AS ReturnsTax,
           SUM(NetSalesTaxable) AS NetSalesTaxable, SUM(OutputTax) AS OutputTax, SUM(PurchaseTaxable) AS PurchaseTaxable, SUM(PurchaseTax) AS PurchaseTax,
           SUM(DebitNotesTaxable) AS DebitNotesTaxable, SUM(NetPurchaseTaxable) AS NetPurchaseTaxable, SUM(InputTax) AS InputTax, SUM(NetTax) AS NetTax
      FROM #R;
END
GO

-- ── GSTR-1 data for the offline-tool Excel: 1 header, 2 b2b, 3 b2cs, 4 cdnr, 5 hsn(b2b), 6 hsn(b2c), 7 docs ─────────
CREATE OR ALTER PROCEDURE dbo.usp_PhGst_Gstr1 @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE
AS
BEGIN
    SET NOCOUNT ON;
    SELECT o.*, ISNULL(bg.PlaceOfSupply, N'') AS Pos INTO #O FROM dbo.fn_PhGstOutward(@CompanyId, @BranchId, @From, @To) o OUTER APPLY dbo.fn_PhBranchGst(o.BranchId) bg;
    DECLARE @hb INT = ISNULL(@BranchId, (SELECT TOP 1 BranchID FROM dbo.BranchMaster WHERE CompanyId = @CompanyId ORDER BY IsHOBranch DESC, BranchID));
    SELECT bg.Gstin, bg.BranchName, bg.PlaceOfSupply, @From AS FromDate, @To AS ToDate, FORMAT(@To, 'MMyyyy') AS ReturnPeriod,
           CASE WHEN @BranchId IS NULL THEN N'All branches' ELSE bg.BranchName END AS Scope
      FROM dbo.fn_PhBranchGst(@hb) bg;
    -- b2b: invoice x rate
    SELECT CustomerGstin AS Gstin, MAX(CustomerName) AS ReceiverName, DocNo AS InvoiceNo, DocDate AS InvoiceDate, MAX(DocValue) AS InvoiceValue, Pos AS PlaceOfSupply,
           Rate, SUM(Taxable) AS Taxable
      FROM #O WHERE DocKind = 'INV' AND CustomerGstin IS NOT NULL GROUP BY CustomerGstin, DocNo, DocDate, Pos, Rate ORDER BY DocDate, DocNo, Rate;
    -- b2cs: place of supply x rate, net of credit notes to unregistered customers
    SELECT 'OE' AS Type, Pos AS PlaceOfSupply, Rate, SUM(Taxable) AS Taxable FROM #O WHERE CustomerGstin IS NULL GROUP BY Pos, Rate HAVING SUM(Taxable) <> 0 ORDER BY Pos, Rate;
    -- cdnr: credit note x rate (to registered customers)
    SELECT CustomerGstin AS Gstin, MAX(CustomerName) AS ReceiverName, DocNo AS NoteNo, DocDate AS NoteDate, 'C' AS NoteType, Pos AS PlaceOfSupply,
           MAX(DocValue) AS NoteValue, Rate, -SUM(Taxable) AS Taxable
      FROM #O WHERE DocKind = 'CN' AND CustomerGstin IS NOT NULL GROUP BY CustomerGstin, DocNo, DocDate, Pos, Rate ORDER BY DocDate, DocNo, Rate;
    -- hsn: B2B and B2C (net of credit notes)
    SELECT HsnCode AS Hsn, MAX(HsnDescription) AS Description, Uqc, SUM(Qty) AS Qty, SUM(Taxable + Igst + Cgst + Sgst) AS TotalValue, Rate, SUM(Taxable) AS Taxable,
           SUM(Igst) AS Igst, SUM(Cgst) AS Cgst, SUM(Sgst) AS Sgst
      FROM #O WHERE CustomerGstin IS NOT NULL GROUP BY HsnCode, Uqc, Rate ORDER BY HsnCode, Rate;
    SELECT HsnCode AS Hsn, MAX(HsnDescription) AS Description, Uqc, SUM(Qty) AS Qty, SUM(Taxable + Igst + Cgst + Sgst) AS TotalValue, Rate, SUM(Taxable) AS Taxable,
           SUM(Igst) AS Igst, SUM(Cgst) AS Cgst, SUM(Sgst) AS Sgst
      FROM #O WHERE CustomerGstin IS NULL GROUP BY HsnCode, Uqc, Rate ORDER BY HsnCode, Rate;
    -- docs: number ranges per series (bills incl. cancelled; credit notes)
    SELECT N'Invoices for outward supply' AS Nature, MIN(SaleNo) AS FromNo, MAX(SaleNo) AS ToNo, COUNT(*) AS Total, SUM(CASE WHEN Status = 'CANCELLED' THEN 1 ELSE 0 END) AS Cancelled
      FROM dbo.PhSale WHERE CompanyId = @CompanyId AND (@BranchId IS NULL OR BranchId = @BranchId) AND Status IN ('POSTED', 'CANCELLED') AND SaleNo IS NOT NULL
       AND SaleDate >= @From AND SaleDate < DATEADD(DAY, 1, CAST(@To AS DATETIME))
     GROUP BY BranchId, LEFT(SaleNo, LEN(SaleNo) - CHARINDEX('/', REVERSE(SaleNo)))
    UNION ALL
    SELECT N'Credit Note', MIN(ReturnNo), MAX(ReturnNo), COUNT(*), 0
      FROM dbo.PhSaleReturn WHERE CompanyId = @CompanyId AND (@BranchId IS NULL OR BranchId = @BranchId) AND ReturnNo IS NOT NULL
       AND ReturnDate >= @From AND ReturnDate < DATEADD(DAY, 1, CAST(@To AS DATETIME))
     GROUP BY BranchId, LEFT(ReturnNo, LEN(ReturnNo) - CHARINDEX('/', REVERSE(ReturnNo)))
    HAVING COUNT(*) > 0;
END
GO

-- purchase invoices as the books show them, for the GSTR-2B reconciliation (one row per supplier invoice)
CREATE OR ALTER PROCEDURE dbo.usp_PhGst_PurchaseBook @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SupplierGstin AS Gstin, MAX(SupplierName) AS SupplierName, DocNo AS InvoiceNo, DocDate AS InvoiceDate, MAX(DocValue) AS InvoiceValue,
           SUM(Taxable) AS Taxable, SUM(Igst) AS Igst, SUM(Cgst) AS Cgst, SUM(Sgst) AS Sgst, MAX(BookNo) AS GrnNo, MAX(DocId) AS GrnId
      FROM dbo.fn_PhGstInward(@CompanyId, @BranchId, @From, @To)
     WHERE DocKind = 'INV'
     GROUP BY SupplierGstin, DocNo, DocDate
     ORDER BY DocDate, DocNo;
END
GO

-- ── menu: pages under Reports > Pharmacy, after the expiry reports ───────────────────────────────────────
DECLARE @Pages TABLE (Code NVARCHAR(100), Title NVARCHAR(150), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100), Extra NVARCHAR(200));
INSERT @Pages VALUES
 (N'REPORTS.PHARMACY.GSTR1',       N'GSTR-1 Summary (B2B / B2C / CDN)',           N'Gstr1Summary',    610, N'bi bi-file-earmark-spreadsheet me-2', N'Gstr1Excel'),
 (N'REPORTS.PHARMACY.HSNSUMMARY',  N'HSN-wise Summary (GSTR-1 Table 12)',         N'HsnSummary',      620, N'bi bi-upc me-2', NULL),
 (N'REPORTS.PHARMACY.CREDITNOTES', N'Credit Note Register (Sale Returns)',         N'CreditNotes',     630, N'bi bi-receipt-cutoff me-2', NULL),
 (N'REPORTS.PHARMACY.PURCHASEITC', N'Purchase GST (ITC) Register & GSTR-2B Match', N'PurchaseItc',     640, N'bi bi-journal-check me-2', N'Gstr2bReconcile'),
 (N'REPORTS.PHARMACY.GSTR3B',      N'GSTR-3B Working',                            N'Gstr3b',          650, N'bi bi-calculator me-2', NULL),
 (N'REPORTS.PHARMACY.GSTRATE',     N'Rate-wise Sales & Purchase Summary',         N'GstRateSummary',  660, N'bi bi-percent me-2', NULL);

DECLARE @co INT, @reports INT, @ph INT, @page INT, @view INT, @exp INT, @pc NVARCHAR(100), @title NVARCHAR(150), @action NVARCHAR(100), @sort INT, @icon NVARCHAR(100), @extra NVARCHAR(200);
DECLARE co CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS';
OPEN co; FETCH NEXT FROM co INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @reports = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS' AND CompanyId = @co;
    SET @ph = NULL;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @reports, @Menu_Type = 'MENU', @Menu_Code = N'REPORTS.PHARMACY', @Title = N'Pharmacy',
         @Icon = N'bi bi-capsule-pill me-2', @Sort_Order = 25, @UserId = NULL, @Menu_ID = @ph OUTPUT;
    DECLARE p CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Action, Sort, Icon, Extra FROM @Pages;
    OPEN p; FETCH NEXT FROM p INTO @pc, @title, @action, @sort, @icon, @extra;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @ph, @Page_Code = @pc, @Title = @title, @Controller = N'PhReports', @Action = @action,
             @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        SET @exp = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EXPORT', @Title = N'Export to Excel / PDF', @Sort_Order = 20, @Control_ID = @exp OUTPUT;
        DECLARE @a1 NVARCHAR(100) = @action, @a2 NVARCHAR(100) = @action + N'Data', @a3 NVARCHAR(100) = @action + N'Export';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @a1, @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @a2, @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @exp, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @a3, @Source = 'SEED';
        -- GSTR-1 Excel (GET) and the GSTR-2B reconciliation (POST, a file) belong to the page's EXPORT control
        DECLARE @verb VARCHAR(10) = CASE WHEN @extra = N'Gstr2bReconcile' THEN 'POST' ELSE 'GET' END;
        IF @extra IS NOT NULL
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @exp, @App = 'WEB', @Http_Method = @verb, @Controller = N'PhReports', @Action = @extra, @Source = 'SEED';
        FETCH NEXT FROM p INTO @pc, @title, @action, @sort, @icon, @extra;
    END
    CLOSE p; DEALLOCATE p;
    FETCH NEXT FROM co INTO @co;
END
CLOSE co; DEALLOCATE co;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2370 applied: Reports > Pharmacy, GST & tax reports (G1-G6), GSTR-1 data, GSTR-2B book, UQC on units.';
GO
