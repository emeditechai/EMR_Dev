using System.Data;
using System.Globalization;
using System.Text.RegularExpressions;
using ClosedXML.Excel;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>A purchase invoice in the GSTR-2B reconciliation: what the books and the downloaded GSTR-2B say.</summary>
public sealed class Gstr2bRow
{
    public string Status { get; set; } = "";          // MATCHED | MISMATCH | BOOKS_ONLY | GSTR2B_ONLY | NO_GSTIN
    public string? Gstin { get; set; }
    public string? Supplier { get; set; }
    public string InvoiceNo { get; set; } = "";
    public DateTime? InvoiceDate { get; set; }
    public decimal? BooksTaxable { get; set; }
    public decimal? BooksTax { get; set; }
    public decimal? TwoBTaxable { get; set; }
    public decimal? TwoBTax { get; set; }
    public decimal? DiffTaxable { get; set; }
    public decimal? DiffTax { get; set; }
    public string? GrnNo { get; set; }
    public int? GrnId { get; set; }
    public string? Note { get; set; }
}

public sealed class Gstr2bResult
{
    public int Matched { get; set; }
    public int Mismatch { get; set; }
    public int BooksOnly { get; set; }
    public int TwoBOnly { get; set; }
    public int NoGstin { get; set; }
    public decimal BooksTax { get; set; }
    public decimal TwoBTax { get; set; }
    public int TwoBRowsRead { get; set; }
    public List<Gstr2bRow> Rows { get; set; } = [];
}

/// <summary>Reports > Pharmacy GST (SQLScripts/2370): GSTR-1 data for the offline-tool Excel, and the GSTR-2B reconciliation.</summary>
[ApiController]
[Route("api/pharmacy/gst")]
[Produces("application/json")]
public class PharmacyGstController(IPharmacyProcService ph, IDbConnectionFactory db, ILogger<PharmacyGstController> logger) : ControllerBase
{
    [HttpGet("gstr1")]
    public async Task<IActionResult> Gstr1([FromQuery] int companyId, [FromQuery] int? branchId, [FromQuery] DateTime from, [FromQuery] DateTime to) =>
        Ok(ApiResponse<List<List<IDictionary<string, object?>>>>.Ok(
            await ph.SetsAsync("dbo.usp_PhGst_Gstr1", new { CompanyId = companyId, BranchId = branchId, From = from.Date, To = to.Date }, 7)));

    private sealed record BookRow(string? Gstin, string SupplierName, string InvoiceNo, DateTime InvoiceDate, decimal InvoiceValue, decimal Taxable, decimal Igst, decimal Cgst, decimal Sgst, string GrnNo, int GrnId);

    [HttpPost("gstr2b-reconcile")]
    [RequestSizeLimit(20 * 1024 * 1024)]
    public async Task<IActionResult> Reconcile([FromForm] int companyId, [FromForm] int? branchId, [FromForm] DateTime from, [FromForm] DateTime to, IFormFile? file)
    {
        if (file == null || file.Length == 0) return BadRequest(ApiResponse<object>.Fail("Choose the GSTR-2B Excel downloaded from the GST portal."));
        List<(string Gstin, string Name, string No, DateTime? Date, decimal Taxable, decimal Tax)> twoB;
        try
        {
            using var ms = new MemoryStream();
            await file.CopyToAsync(ms);
            ms.Position = 0;
            twoB = Read2B(ms);
        }
        catch (InvalidOperationException ex) { return BadRequest(ApiResponse<object>.Fail(ex.Message)); }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "GSTR-2B file could not be read: {File}", file.FileName);
            return BadRequest(ApiResponse<object>.Fail("The file is not a GSTR-2B Excel (.xlsx) downloaded from the GST portal."));
        }

        using var con = db.CreateConnection();
        var books = (await con.QueryAsync<BookRow>("dbo.usp_PhGst_PurchaseBook", new { CompanyId = companyId, BranchId = branchId, From = from.Date, To = to.Date },
                                                  commandType: CommandType.StoredProcedure)).ToList();
        var res = new Gstr2bResult { TwoBRowsRead = twoB.Count };
        var twoBByKey = twoB.GroupBy(x => Key(x.Gstin, x.No)).ToDictionary(g => g.Key, g => g.First());
        var used = new HashSet<string>();
        foreach (var b in books)
        {
            var bookTax = b.Igst + b.Cgst + b.Sgst;
            if (string.IsNullOrWhiteSpace(b.Gstin))
            {
                res.Rows.Add(new Gstr2bRow { Status = "NO_GSTIN", Supplier = b.SupplierName, InvoiceNo = b.InvoiceNo, InvoiceDate = b.InvoiceDate, BooksTaxable = b.Taxable,
                    BooksTax = bookTax, GrnNo = b.GrnNo, GrnId = b.GrnId, Note = "Supplier has no GSTIN in the Supplier Master" });
                continue;
            }
            var k = Key(b.Gstin, b.InvoiceNo);
            if (twoBByKey.TryGetValue(k, out var t))
            {
                used.Add(k);
                decimal dT = b.Taxable - t.Taxable, dX = bookTax - t.Tax;
                var ok = Math.Abs(dT) <= 1 && Math.Abs(dX) <= 1;
                res.Rows.Add(new Gstr2bRow { Status = ok ? "MATCHED" : "MISMATCH", Gstin = b.Gstin, Supplier = b.SupplierName, InvoiceNo = b.InvoiceNo, InvoiceDate = b.InvoiceDate,
                    BooksTaxable = b.Taxable, BooksTax = bookTax, TwoBTaxable = t.Taxable, TwoBTax = t.Tax, DiffTaxable = dT, DiffTax = dX, GrnNo = b.GrnNo, GrnId = b.GrnId,
                    Note = ok ? null : "Amounts differ: check the bill with the supplier" });
            }
            else
                res.Rows.Add(new Gstr2bRow { Status = "BOOKS_ONLY", Gstin = b.Gstin, Supplier = b.SupplierName, InvoiceNo = b.InvoiceNo, InvoiceDate = b.InvoiceDate,
                    BooksTaxable = b.Taxable, BooksTax = bookTax, GrnNo = b.GrnNo, GrnId = b.GrnId, Note = "Not in GSTR-2B: the supplier has not filed it yet (no ITC until filed)" });
        }
        // second pass: the same supplier and the same invoice digits, numbered differently ("98876" in the books, "RT/98876" on the portal)
        static string Digits(string? s) => System.Text.RegularExpressions.Regex.Replace(s ?? "", "[^0-9]", "").TrimStart('0');
        foreach (var row in res.Rows.Where(r => r.Status == "BOOKS_ONLY").ToList())
        {
            var d = Digits(row.InvoiceNo);
            if (d.Length < 3) continue;
            var hit = twoBByKey.Where(x => !used.Contains(x.Key) && x.Value.Gstin == row.Gstin)
                               .FirstOrDefault(x => { var e = Digits(x.Value.No); return e.Length >= 3 && (e == d || e.EndsWith(d) || d.EndsWith(e)); });
            if (hit.Key == null) continue;
            used.Add(hit.Key);
            var t = hit.Value;
            decimal dT = (row.BooksTaxable ?? 0) - t.Taxable, dX = (row.BooksTax ?? 0) - t.Tax;
            var ok = Math.Abs(dT) <= 1 && Math.Abs(dX) <= 1;
            row.Status = ok ? "MATCHED" : "MISMATCH"; row.TwoBTaxable = t.Taxable; row.TwoBTax = t.Tax; row.DiffTaxable = dT; row.DiffTax = dX;
            row.Note = $"Invoice number written differently on the portal: {t.No}" + (ok ? "" : "; amounts differ");
        }
        foreach (var (k, t) in twoBByKey.Where(x => !used.Contains(x.Key)))
            res.Rows.Add(new Gstr2bRow { Status = "GSTR2B_ONLY", Gstin = t.Gstin, Supplier = t.Name, InvoiceNo = t.No, InvoiceDate = t.Date, TwoBTaxable = t.Taxable, TwoBTax = t.Tax,
                Note = "In GSTR-2B but not in the books: GRN not entered, or a bill for another branch / purpose" });

        res.Matched = res.Rows.Count(r => r.Status == "MATCHED"); res.Mismatch = res.Rows.Count(r => r.Status == "MISMATCH");
        res.BooksOnly = res.Rows.Count(r => r.Status == "BOOKS_ONLY"); res.TwoBOnly = res.Rows.Count(r => r.Status == "GSTR2B_ONLY"); res.NoGstin = res.Rows.Count(r => r.Status == "NO_GSTIN");
        res.BooksTax = res.Rows.Sum(r => r.BooksTax ?? 0); res.TwoBTax = res.Rows.Sum(r => r.TwoBTax ?? 0);
        res.Rows = res.Rows.OrderBy(r => r.Status switch { "MISMATCH" => 0, "BOOKS_ONLY" => 1, "GSTR2B_ONLY" => 2, "NO_GSTIN" => 3, _ => 4 }).ThenBy(r => r.InvoiceDate).ToList();
        return Ok(ApiResponse<Gstr2bResult>.Ok(res));
    }

    /// <summary>Same invoice: same GSTIN and the same invoice number ignoring case, separators, prefix zeros.</summary>
    private static string Key(string? gstin, string? no) =>
        (gstin ?? "").Trim().ToUpperInvariant() + "|" + Regex.Replace((no ?? "").ToUpperInvariant(), "[^A-Z0-9]", "").TrimStart('0');

    /// <summary>The B2B sheet of the GSTR-2B Excel: the heading row is found by its text, columns by their names; rows of one invoice (one per rate) are added up.</summary>
    private static List<(string Gstin, string Name, string No, DateTime? Date, decimal Taxable, decimal Tax)> Read2B(Stream xlsx)
    {
        using var wb = new XLWorkbook(xlsx);
        var ws = wb.Worksheets.FirstOrDefault(w => w.Name.Trim().Equals("B2B", StringComparison.OrdinalIgnoreCase))
                 ?? throw new InvalidOperationException("The file has no \"B2B\" sheet. Upload the GSTR-2B Excel downloaded from the GST portal.");
        var used = ws.RangeUsed() ?? throw new InvalidOperationException("The B2B sheet is empty.");
        int lastRow = used.LastRow().RowNumber(), lastCol = used.LastColumn().ColumnNumber();
        int head = 0;
        for (var r = 1; r <= Math.Min(lastRow, 15) && head == 0; r++)
            for (var c = 1; c <= lastCol; c++)
                if (ws.Cell(r, c).GetString().Contains("GSTIN of supplier", StringComparison.OrdinalIgnoreCase)) { head = r; break; }
        if (head == 0) throw new InvalidOperationException("The B2B sheet has no \"GSTIN of supplier\" heading: is it the GSTR-2B Excel?");
        // headings are on two rows (e.g. "Invoice details" over "Invoice number")
        string H(int c) => (ws.Cell(head, c).GetString() + " " + ws.Cell(head + 1, c).GetString()).ToLowerInvariant();
        int Col(params string[] keys) { for (var c = 1; c <= lastCol; c++) { var h = H(c); if (keys.All(k => h.Contains(k))) return c; } return 0; }
        int cG = Col("gstin of supplier"), cN = Col("trade"), cNo = Col("invoice number"), cDt = Col("invoice date"), cTx = Col("taxable value"),
            cI = Col("integrated"), cC = Col("central"), cS = Col("state");
        if (cNo == 0) cNo = Col("invoice", "number");
        if (cG == 0 || cNo == 0 || cTx == 0) throw new InvalidOperationException("The B2B sheet's columns (GSTIN, invoice number, taxable value) were not found.");
        decimal D(int r, int c)
        {
            if (c == 0) return 0;
            var cell = ws.Cell(r, c);
            if (cell.TryGetValue<decimal>(out var v)) return v;
            return decimal.TryParse(cell.GetString().Replace(",", ""), NumberStyles.Number, CultureInfo.InvariantCulture, out var p) ? p : 0;
        }
        DateTime? Dt(int r)
        {
            if (cDt == 0) return null;
            var cell = ws.Cell(r, cDt);
            if (cell.DataType == XLDataType.DateTime) return cell.GetDateTime();
            var s = cell.GetString().Trim();
            foreach (var f in new[] { "dd-MM-yyyy", "dd/MM/yyyy", "dd-MMM-yyyy", "d-M-yyyy", "yyyy-MM-dd" })
                if (DateTime.TryParseExact(s, f, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)) return d;
            return null;
        }
        var rows = new List<(string, string, string, DateTime?, decimal, decimal)>();
        for (var r = head + 2; r <= lastRow; r++)
        {
            var g = ws.Cell(r, cG).GetString().Trim().ToUpperInvariant();
            if (!Regex.IsMatch(g, @"^\d{2}[A-Z0-9]{13}$")) continue;     // totals, blank and note rows
            rows.Add((g, cN > 0 ? ws.Cell(r, cN).GetString().Trim() : "", ws.Cell(r, cNo).GetString().Trim(), Dt(r), D(r, cTx), D(r, cI) + D(r, cC) + D(r, cS)));
        }
        return rows.GroupBy(x => (x.Item1, Key(x.Item1, x.Item3)))
                   .Select(g => (g.Key.Item1, g.First().Item2, g.First().Item3, g.First().Item4, g.Sum(x => x.Item5), g.Sum(x => x.Item6))).ToList();
    }
}
