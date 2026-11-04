using System.Globalization;
using System.Text.Json;
using ClosedXML.Excel;
using EMR.Web.ApiClients;

namespace EMR.Web.Services;

/// <summary>One row of an Item Master import as checked / imported by usp_Api_PhItem_Import (SQLScripts/2411).</summary>
public class PhItemImportRow
{
    public int RowNo { get; set; }
    public string? ItemName { get; set; }
    public string? Manufacturer { get; set; }
    public string? Schedule { get; set; }
    public string Status { get; set; } = "";     // NEW | ADDED | SKIP | ERROR
    public string? Message { get; set; }
}

public class PhItemImportTotals
{
    public int Total { get; set; }
    public int ToAdd { get; set; }
    public int Added { get; set; }
    public int Skipped { get; set; }
    public int Errors { get; set; }
}

/// <summary>
/// Master > Pharmacy > Item / Drug Master > Import (SQLScripts/2411): the Excel template, reading an .xlsx / .csv file
/// (or the standard starter list in App_Data/pharmacy-standard-items.csv) and checking / importing it through EMR.Api.
/// </summary>
public class PharmacyItemImport(PharmacyApiClient api, IWebHostEnvironment env)
{
    // column, what to type, example, required
    public static readonly (string Col, string Help, string Example, bool Required)[] Columns =
    [
        ("ItemName", "Brand as on the pack", "Dolo 650", true),
        ("GenericName", "Molecule(s) with strength", "Paracetamol 650 mg", false),
        ("Manufacturer", "Company", "Micro Labs Ltd", false),
        ("DosageForm", "TAB, CAP, SYP, SUSP, INJ, INF, OINT, CRM, GEL, DRP, INH, RESP, PWD, LOT, SPR, SUPP, SURG", "TAB", false),
        ("Strength", "As printed", "650 mg", false),
        ("PackSize", "As printed", "Strip of 15 tablets", false),
        ("Category", "Main › Sub (or Main > Sub); created if new", "Drugs / Medicines > Analgesics & Antipyretics", true),
        ("Schedule", "G, H, H1, X, NDPS or OTC", "H", true),
        ("HsnCode", "4 / 6 / 8 digits", "3004", true),
        ("GstPercent", "Needed only for a new HSN: 0, 5, 12, 18, 28", "5", false),
        ("PurchaseUnit", "Pack bought (STRIP, BOX, BTL, VIAL ...)", "STRIP", true),
        ("SaleUnit", "Smallest unit sold (TAB, CAP, BTL, NOS ...)", "TAB", true),
        ("ConversionQty", "Sale units in one purchase unit", "15", true),
        ("RxRequired", "Y / N (H1, X, NDPS are always Y)", "Y", false),
        ("LooseSale", "Y / N - cut strips sold", "Y", false),
        ("ColdChain", "Y / N", "N", false),
        ("HighAlert", "Y / N", "N", false),
        ("Lasa", "Y / N - look-alike / sound-alike", "N", false),
        ("Returnable", "Y / N", "Y", false),
        ("DiscountAllowed", "Y / N", "Y", false),
        ("VedClass", "V, E or D", "E", false),
        ("Barcode", "EAN / GTIN", "", false),
        ("ReorderLevel", "In purchase units", "10", false),
        ("MinQty", "In purchase units", "", false),
        ("MaxQty", "In purchase units", "", false),
        ("LeadDays", "Supplier lead time", "2", false),
        ("Remarks", "", "", false)
    ];
    private static readonly HashSet<string> Flags = ["RxRequired", "LooseSale", "ColdChain", "HighAlert", "Lasa", "Returnable", "DiscountAllowed"];
    private static readonly HashSet<string> Ints = ["ConversionQty", "LeadDays"];
    private static readonly HashSet<string> Decimals = ["GstPercent", "ReorderLevel", "MinQty", "MaxQty"];
    public const int MaxRows = 5000;

    public byte[] Template()
    {
        using var wb = new XLWorkbook();
        var ws = wb.AddWorksheet("Items");
        for (var i = 0; i < Columns.Length; i++)
        {
            var c = ws.Cell(1, i + 1);
            c.Value = Columns[i].Col + (Columns[i].Required ? " *" : "");
            c.Style.Font.Bold = true;
            c.Style.Fill.BackgroundColor = Columns[i].Required ? XLColor.FromHtml("#ede9fe") : XLColor.FromHtml("#f1f5f9");
            c.CreateComment().AddText(Columns[i].Help);
            ws.Cell(2, i + 1).Value = Columns[i].Example;
        }
        ws.SheetView.FreezeRows(1);
        ws.Columns().AdjustToContents(8, 40);
        var help = wb.AddWorksheet("How to fill");
        help.Cell(1, 1).Value = "Column"; help.Cell(1, 2).Value = "Required"; help.Cell(1, 3).Value = "What to type";
        help.Row(1).Style.Font.Bold = true;
        for (var i = 0; i < Columns.Length; i++)
        {
            help.Cell(i + 2, 1).Value = Columns[i].Col; help.Cell(i + 2, 2).Value = Columns[i].Required ? "Yes" : "";
            help.Cell(i + 2, 3).Value = Columns[i].Help;
        }
        help.Cell(Columns.Length + 3, 1).Value = "Row 2 of the Items sheet is an example - replace it. An item already in the Item Master (same name, manufacturer and form) is skipped. A missing generic, manufacturer, category, HSN, unit or form is created.";
        help.Columns().AdjustToContents(8, 90);
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    /// <summary>Rows of an .xlsx (first sheet) or .csv file: header row 1 (a trailing " *" is ignored), blank rows skipped.</summary>
    public (List<Dictionary<string, object?>> Rows, string? Error) Read(Stream file, string fileName)
    {
        List<string[]> grid;
        try
        {
            grid = fileName.EndsWith(".csv", StringComparison.OrdinalIgnoreCase) ? ReadCsv(file) : ReadXlsx(file);
        }
        catch (Exception) { return ([], "The file could not be read. Use the Excel template (.xlsx) or a .csv with the same columns."); }
        if (grid.Count < 2) return ([], "The file has no rows under the header.");
        var head = grid[0].Select(h => h.Replace("*", "").Trim()).ToArray();
        var known = Columns.Select(c => c.Col).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var idx = head.Select((h, i) => (h, i)).Where(x => known.Contains(x.h)).ToDictionary(x => Columns.First(c => c.Col.Equals(x.h, StringComparison.OrdinalIgnoreCase)).Col, x => x.i);
        var missing = Columns.Where(c => c.Required && !idx.ContainsKey(c.Col)).Select(c => c.Col).ToList();
        if (missing.Count > 0) return ([], "Columns missing in the header: " + string.Join(", ", missing) + ". Download the template.");
        var rows = new List<Dictionary<string, object?>>();
        for (var r = 1; r < grid.Count; r++)
        {
            var cells = grid[r];
            if (cells.All(string.IsNullOrWhiteSpace)) continue;
            var d = new Dictionary<string, object?> { ["RowNo"] = r + 1 };
            foreach (var (col, i) in idx)
            {
                var v = i < cells.Length ? cells[i]?.Trim() : null;
                if (string.IsNullOrEmpty(v)) { d[col] = null; continue; }
                d[col] = Flags.Contains(col) ? v.ToUpperInvariant() is "Y" or "YES" or "1" or "TRUE"
                       : Ints.Contains(col) ? (int.TryParse(v, NumberStyles.Any, CultureInfo.InvariantCulture, out var n) ? n : -1)
                       : Decimals.Contains(col) ? (decimal.TryParse(v, NumberStyles.Any, CultureInfo.InvariantCulture, out var m) ? m : -1m)
                       : v;
            }
            rows.Add(d);
            if (rows.Count > MaxRows) return ([], $"Up to {MaxRows} rows at a time; split the file.");
        }
        return rows.Count == 0 ? ([], "The file has no rows under the header.") : (rows, null);
    }

    public (List<Dictionary<string, object?>> Rows, string? Error) ReadStandardList()
    {
        var path = Path.Combine(env.ContentRootPath, "App_Data", "pharmacy-standard-items.csv");
        if (!File.Exists(path)) return ([], "The standard list is not installed on this server (App_Data/pharmacy-standard-items.csv).");
        using var fs = File.OpenRead(path);
        return Read(fs, path);
    }

    public async Task<(List<PhItemImportRow> Rows, PhItemImportTotals Totals)> RunAsync(int companyId, int userId, List<Dictionary<string, object?>> rows, bool commit)
    {
        var sets = await api.PostAsync<List<List<JsonElement>>>("api/pharmacy/masters/items/import",
            new { companyId, userId, Rows = JsonSerializer.Serialize(rows), commit });
        var list = sets.Count > 0 ? sets[0].Select(e => e.Deserialize<PhItemImportRow>(PharmacyApiClient.Json)!).ToList() : [];
        var totals = sets.Count > 1 && sets[1].Count > 0 ? sets[1][0].Deserialize<PhItemImportTotals>(PharmacyApiClient.Json)! : new PhItemImportTotals();
        return (list, totals);
    }

    private static List<string[]> ReadXlsx(Stream s)
    {
        using var wb = new XLWorkbook(s);
        var ws = wb.Worksheets.First();
        var used = ws.RangeUsed();
        if (used == null) return [];
        var lastCol = used.LastColumn().ColumnNumber();
        return used.Rows().Select(r => Enumerable.Range(1, lastCol).Select(c => r.Cell(c).GetFormattedString()).ToArray()).ToList();
    }

    private static List<string[]> ReadCsv(Stream s)
    {
        using var sr = new StreamReader(s);
        var rows = new List<string[]>();
        var text = sr.ReadToEnd();
        var row = new List<string>(); var cell = new System.Text.StringBuilder(); var quoted = false;
        for (var i = 0; i < text.Length; i++)
        {
            var ch = text[i];
            if (quoted)
            {
                if (ch == '"' && i + 1 < text.Length && text[i + 1] == '"') { cell.Append('"'); i++; }
                else if (ch == '"') quoted = false;
                else cell.Append(ch);
            }
            else if (ch == '"') quoted = true;
            else if (ch == ',') { row.Add(cell.ToString()); cell.Clear(); }
            else if (ch == '\n' || ch == '\r')
            {
                if (ch == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                row.Add(cell.ToString()); cell.Clear(); rows.Add([.. row]); row.Clear();
            }
            else cell.Append(ch);
        }
        if (cell.Length > 0 || row.Count > 0) { row.Add(cell.ToString()); rows.Add([.. row]); }
        return rows;
    }
}
