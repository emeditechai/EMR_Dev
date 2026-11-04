-- ============================================================================================================
-- Migration: 2399_pharmacy_purchase_register_standard.sql
-- Pharmacy > Purchase > Purchase Register, to the usual GST purchase-register layout:
--   RS1 documents - posted GRNs and debit notes (purchase returns, minus): supplier, GSTIN, state, supply type
--       (intra / inter-state), supplier bill no / date (for a debit note: the GRN(s) and bill(s) its batches came from),
--       lines, qty / free qty, gross, discount, taxable, CGST / SGST / IGST, total GST, other charges, round off, net
--   RS2 GST rate-wise summary: purchases, returns and net taxable with CGST / SGST / IGST at each rate
--   RS3 supplier-wise summary: GSTIN, purchases, returns, net and input GST
--   Filters: period, supplier, document type (ALL / PURCHASE / RETURN), search (doc no, bill no, supplier, GSTIN).
-- usp_Api_PhPur_Register replaced (new optional parameters; same first two result sets' meaning). Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_Register
    @CompanyId INT, @BranchId INT, @From DATE, @To DATE, @SupplierId INT = NULL,
    @DocType VARCHAR(10) = NULL,          -- ALL / PURCHASE / RETURN
    @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @DocType = ISNULL(NULLIF(UPPER(LTRIM(RTRIM(@DocType))), ''), 'ALL');
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');

    CREATE TABLE #D (
        DocType VARCHAR(20), Id INT, DocNo NVARCHAR(50), DocDate DATE, SupplierId INT, SupplierName NVARCHAR(200), Gstin NVARCHAR(20),
        StateName NVARCHAR(100), IsInterState BIT, InvoiceNo NVARCHAR(200), InvoiceDate DATE, RefGrnNo NVARCHAR(400),
        Lines INT, Qty DECIMAL(18, 3), FreeQty DECIMAL(18, 3), Gross DECIMAL(18, 2), Discount DECIMAL(18, 2), Taxable DECIMAL(18, 2),
        Cgst DECIMAL(18, 2), Sgst DECIMAL(18, 2), Igst DECIMAL(18, 2), Gst DECIMAL(18, 2), Other DECIMAL(18, 2), RoundOff DECIMAL(18, 2), Net DECIMAL(18, 2));

    IF @DocType IN ('ALL', 'PURCHASE')
        INSERT #D
        SELECT 'Purchase', g.GrnId, g.GrnNo, g.GrnDate, s.SupplierId, s.SupplierName, NULLIF(LTRIM(RTRIM(s.Gstin)), ''), st.StateName,
               ISNULL(g.IsInterState, 0), g.InvoiceNo, g.InvoiceDate, NULL,
               ISNULL(l.Lines, 0), ISNULL(l.Qty, 0), ISNULL(l.FreeQty, 0), ISNULL(l.Gross, 0),
               ISNULL(l.Gross, 0) - g.TaxableAmount,                     -- discount = gross - taxable
               g.TaxableAmount, g.CgstAmount, g.SgstAmount, g.IgstAmount, g.CgstAmount + g.SgstAmount + g.IgstAmount,
               ISNULL(g.OtherCharges, 0), ISNULL(g.RoundOff, 0), g.NetAmount
          FROM dbo.PhGrn g
          JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId
          LEFT JOIN dbo.StateMaster st ON st.StateId = s.StateId
          OUTER APPLY (SELECT COUNT(*) AS Lines, SUM(d.Qty) AS Qty, SUM(ISNULL(d.FreeQty, 0)) AS FreeQty,
                              CAST(SUM(d.Qty * d.Rate) AS DECIMAL(18, 2)) AS Gross
                         FROM dbo.PhGrnDtl d WHERE d.GrnId = g.GrnId) l
         WHERE g.CompanyId = @CompanyId AND g.BranchId = @BranchId AND g.Status = 'POSTED'
           AND g.GrnDate BETWEEN @From AND @To AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId);

    IF @DocType IN ('ALL', 'RETURN')
        INSERT #D
        SELECT 'Debit note', r.ReturnId, r.ReturnNo, r.ReturnDate, s.SupplierId, s.SupplierName, NULLIF(LTRIM(RTRIM(s.Gstin)), ''), st.StateName,
               ISNULL(r.IsInterState, 0), src.Bills, src.BillDate, src.Grns,
               ISNULL(l.Lines, 0), -ISNULL(l.Qty, 0), 0, -r.TaxableAmount, 0, -r.TaxableAmount,
               CASE WHEN r.IsInterState = 1 THEN 0 ELSE -ROUND(r.GstAmount / 2, 2) END,
               CASE WHEN r.IsInterState = 1 THEN 0 ELSE -(r.GstAmount - ROUND(r.GstAmount / 2, 2)) END,
               CASE WHEN r.IsInterState = 1 THEN -r.GstAmount ELSE 0 END, -r.GstAmount,
               0, -ISNULL(r.RoundOff, 0), -r.NetAmount
          FROM dbo.PhPurchaseReturn r
          JOIN dbo.PhSupplier s ON s.SupplierId = r.SupplierId
          LEFT JOIN dbo.StateMaster st ON st.StateId = s.StateId
          OUTER APPLY (SELECT COUNT(*) AS Lines, SUM(d.Qty) AS Qty FROM dbo.PhPurchaseReturnDtl d WHERE d.ReturnId = r.ReturnId) l
          -- the purchase(s) the returned batches came from: GRN no, supplier bill no / date
          OUTER APPLY (SELECT STRING_AGG(CAST(x.GrnNo AS NVARCHAR(MAX)), ', ') AS Grns,
                              STRING_AGG(CAST(x.InvoiceNo AS NVARCHAR(MAX)), ', ') AS Bills, MIN(x.InvoiceDate) AS BillDate
                         FROM (SELECT DISTINCT g.GrnNo, g.InvoiceNo, g.InvoiceDate
                                 FROM dbo.PhPurchaseReturnDtl d
                                 JOIN dbo.PhGrnDtl gd ON gd.BatchId = d.BatchId
                                 JOIN dbo.PhGrn g ON g.GrnId = gd.GrnId AND g.Status = 'POSTED' AND g.SupplierId = r.SupplierId
                                WHERE d.ReturnId = r.ReturnId) x) src
         WHERE r.CompanyId = @CompanyId AND r.BranchId = @BranchId AND r.Status = 'POSTED'
           AND r.ReturnDate BETWEEN @From AND @To AND (@SupplierId IS NULL OR r.SupplierId = @SupplierId);

    IF @Search IS NOT NULL
        DELETE FROM #D WHERE NOT (DocNo LIKE '%' + @Search + '%' OR ISNULL(InvoiceNo, '') LIKE '%' + @Search + '%'
                                  OR SupplierName LIKE '%' + @Search + '%' OR ISNULL(Gstin, '') LIKE '%' + @Search + '%'
                                  OR ISNULL(RefGrnNo, '') LIKE '%' + @Search + '%');

    -- RS1 documents
    SELECT DocType, Id, DocNo, DocDate, SupplierName, Gstin, StateName,
           CASE WHEN IsInterState = 1 THEN 'Inter-state' ELSE 'Intra-state' END AS SupplyType,
           InvoiceNo, InvoiceDate, RefGrnNo, Lines, Qty, FreeQty, Gross, Discount, Taxable, Cgst, Sgst, Igst, Gst, Other, RoundOff, Net
      FROM #D ORDER BY DocDate, DocType DESC, DocNo;

    -- RS2 GST rate-wise summary (line level, the documents kept above)
    SELECT x.GstPercent,
           SUM(CASE WHEN x.Kind = 'P' THEN x.Taxable ELSE 0 END) AS PurchaseTaxable,
           SUM(CASE WHEN x.Kind = 'R' THEN x.Taxable ELSE 0 END) AS ReturnTaxable,
           SUM(x.Taxable) AS Taxable,
           SUM(CASE WHEN x.Inter = 0 THEN ROUND(x.Gst / 2, 2) ELSE 0 END) AS Cgst,
           SUM(CASE WHEN x.Inter = 0 THEN x.Gst - ROUND(x.Gst / 2, 2) ELSE 0 END) AS Sgst,
           SUM(CASE WHEN x.Inter = 1 THEN x.Gst ELSE 0 END) AS Igst,
           SUM(x.Gst) AS Gst
      FROM (SELECT 'P' AS Kind, d.GstPercent, d.TaxableAmount AS Taxable, d.GstAmount AS Gst, ISNULL(g.IsInterState, 0) AS Inter
              FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId
              JOIN #D k ON k.DocType = 'Purchase' AND k.Id = g.GrnId
            UNION ALL
            SELECT 'R', d.GstPercent, -d.TaxableAmount, -d.GstAmount, ISNULL(r.IsInterState, 0)
              FROM dbo.PhPurchaseReturnDtl d JOIN dbo.PhPurchaseReturn r ON r.ReturnId = d.ReturnId
              JOIN #D k ON k.DocType = 'Debit note' AND k.Id = r.ReturnId) x
     GROUP BY x.GstPercent ORDER BY x.GstPercent;

    -- RS3 supplier-wise summary
    SELECT SupplierName, MAX(Gstin) AS Gstin, MAX(StateName) AS StateName,
           SUM(CASE WHEN DocType = 'Purchase' THEN 1 ELSE 0 END) AS Purchases,
           SUM(CASE WHEN DocType = 'Purchase' THEN Net ELSE 0 END) AS PurchaseAmount,
           SUM(CASE WHEN DocType <> 'Purchase' THEN 1 ELSE 0 END) AS Returns,
           SUM(CASE WHEN DocType <> 'Purchase' THEN Net ELSE 0 END) AS ReturnAmount,
           SUM(Taxable) AS Taxable, SUM(Gst) AS Gst, SUM(Net) AS Net
      FROM #D GROUP BY SupplierId, SupplierName ORDER BY SUM(Net) DESC;

    DROP TABLE #D;
END
GO

PRINT 'Script 2399 applied: Purchase Register - standard GST layout.';
GO
