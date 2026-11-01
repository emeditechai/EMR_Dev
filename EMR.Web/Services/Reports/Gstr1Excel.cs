using System.Globalization;
using System.Text.Json;
using ClosedXML.Excel;

namespace EMR.Web.Services.Reports;

/// <summary>
/// GSTR-1 as an Excel in the layout of the GSTN offline tool's import template (SQLScripts/2370): sheets b2b, b2cs, cdnr, cdnur,
/// hsn(b2b), hsn(b2c), docs - each with the template's summary block (rows 1-3), its column headings (row 4) and the data from row 5.
/// Dates are dd-MMM-yyyy, place of supply "19-West Bengal", UQC as the tool lists it ("TBS-TABLETS").
/// </summary>
public static class Gstr1Excel
{
    private static readonly CultureInfo In = CultureInfo.InvariantCulture;

    private static readonly Dictionary<string, string> Uqc = new(StringComparer.OrdinalIgnoreCase)
    {
        ["BAG"] = "BAGS", ["BOX"] = "BOX", ["BTL"] = "BOTTLES", ["CAN"] = "CANS", ["CTN"] = "CARTONS", ["DOZ"] = "DOZENS", ["GMS"] = "GRAMMES", ["KGS"] = "KILOGRAMS",
        ["LTR"] = "LITRES", ["MLT"] = "MILILITRE", ["MTR"] = "METERS", ["NOS"] = "NUMBERS", ["OTH"] = "OTHERS", ["PAC"] = "PACKS", ["PCS"] = "PIECES", ["PRS"] = "PAIRS",
        ["ROL"] = "ROLLS", ["SET"] = "SETS", ["TBS"] = "TABLETS", ["TUB"] = "TUBES", ["UNT"] = "UNITS"
    };

    private static string S(Dictionary<string, JsonElement> r, string k) => r.TryGetValue(k, out var v) && v.ValueKind != JsonValueKind.Null ? v.ToString() : "";
    private static decimal N(Dictionary<string, JsonElement> r, string k) => r.TryGetValue(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDecimal() : 0;
    private static string D(Dictionary<string, JsonElement> r, string k) => DateTime.TryParse(S(r, k), In, DateTimeStyles.None, out var d) ? d.ToString("dd-MMM-yyyy", In) : S(r, k);

    public static byte[] Build(List<List<Dictionary<string, JsonElement>>> sets)
    {
        var head = sets[0].FirstOrDefault() ?? new();
        List<Dictionary<string, JsonElement>> b2b = sets[1], b2cs = sets[2], cdnr = sets[3], hsnB = sets[4], hsnC = sets[5], docs = sets[6];
        using var wb = new XLWorkbook();

        Sheet(wb, "b2b", "Summary For B2B, SEZ, DE (4A, 4B, 6B, 6C)",
            ["No. of Recipients", "", "No. of Invoices", "", "Total Invoice Value", "", "", "", "", "", "", "Total Taxable Value", "Total Cess"],
            [b2b.Select(r => S(r, "Gstin")).Distinct().Count(), "", b2b.Select(r => S(r, "InvoiceNo")).Distinct().Count(), "",
             b2b.GroupBy(r => S(r, "InvoiceNo")).Sum(g => N(g.First(), "InvoiceValue")), "", "", "", "", "", "", b2b.Sum(r => N(r, "Taxable")), 0m],
            ["GSTIN/UIN of Recipient", "Receiver Name", "Invoice Number", "Invoice date", "Invoice Value", "Place Of Supply", "Reverse Charge", "Applicable % of Tax Rate",
             "Invoice Type", "E-Commerce GSTIN", "Rate", "Taxable Value", "Cess Amount"],
            b2b.Select(r => new object[] { S(r, "Gstin"), S(r, "ReceiverName"), S(r, "InvoiceNo"), D(r, "InvoiceDate"), N(r, "InvoiceValue"), S(r, "PlaceOfSupply"), "N", "",
                                           "Regular B2B", "", N(r, "Rate"), N(r, "Taxable"), 0m }));

        Sheet(wb, "b2cs", "Summary For B2CS(7)",
            ["", "", "", "", "Total Taxable Value", "Total Cess", ""],
            ["", "", "", "", b2cs.Sum(r => N(r, "Taxable")), 0m, ""],
            ["Type", "Place Of Supply", "Applicable % of Tax Rate", "Rate", "Taxable Value", "Cess Amount", "E-Commerce GSTIN"],
            b2cs.Select(r => new object[] { "OE", S(r, "PlaceOfSupply"), "", N(r, "Rate"), N(r, "Taxable"), 0m, "" }));

        Sheet(wb, "cdnr", "Summary For CDNR(9B)",
            ["No. of Recipients", "", "No. of Notes", "", "", "", "", "", "Total Note Value", "", "", "Total Taxable Value", "Total Cess"],
            [cdnr.Select(r => S(r, "Gstin")).Distinct().Count(), "", cdnr.Select(r => S(r, "NoteNo")).Distinct().Count(), "", "", "", "", "",
             cdnr.GroupBy(r => S(r, "NoteNo")).Sum(g => N(g.First(), "NoteValue")), "", "", cdnr.Sum(r => N(r, "Taxable")), 0m],
            ["GSTIN/UIN of Recipient", "Receiver Name", "Note Number", "Note Date", "Note Type", "Place Of Supply", "Reverse Charge", "Note Supply Type", "Note Value",
             "Applicable % of Tax Rate", "Rate", "Taxable Value", "Cess Amount"],
            cdnr.Select(r => new object[] { S(r, "Gstin"), S(r, "ReceiverName"), S(r, "NoteNo"), D(r, "NoteDate"), "C", S(r, "PlaceOfSupply"), "N", "Regular B2B",
                                            N(r, "NoteValue"), "", N(r, "Rate"), N(r, "Taxable"), 0m }));

        Sheet(wb, "cdnur", "Summary For CDNUR(9B)",
            ["", "No. of Notes/Vouchers", "", "", "", "Total Note Value", "", "", "Total Taxable Value", "Total Cess"],
            ["", 0, "", "", "", 0m, "", "", 0m, 0m],
            ["UR Type", "Note Number", "Note Date", "Note Type", "Place Of Supply", "Note Value", "Applicable % of Tax Rate", "Rate", "Taxable Value", "Cess Amount"], []);

        foreach (var (name, rows) in new[] { ("hsn(b2b)", hsnB), ("hsn(b2c)", hsnC) })
            Sheet(wb, name, "Summary For HSN(12)",
                ["No. of HSN", "", "", "", "Total Value", "", "Total Taxable Value", "Total Integrated Tax", "Total Central Tax", "Total State/UT Tax", "Total Cess"],
                [rows.Select(r => S(r, "Hsn")).Distinct().Count(), "", "", "", rows.Sum(r => N(r, "TotalValue")), "", rows.Sum(r => N(r, "Taxable")),
                 rows.Sum(r => N(r, "Igst")), rows.Sum(r => N(r, "Cgst")), rows.Sum(r => N(r, "Sgst")), 0m],
                ["HSN", "Description", "UQC", "Total Quantity", "Total Value", "Rate", "Taxable Value", "Integrated Tax Amount", "Central Tax Amount", "State/UT Tax Amount", "Cess Amount"],
                rows.Select(r => new object[] { S(r, "Hsn"), S(r, "Description"), UqcText(S(r, "Uqc")), N(r, "Qty"), N(r, "TotalValue"), N(r, "Rate"), N(r, "Taxable"),
                                                N(r, "Igst"), N(r, "Cgst"), N(r, "Sgst"), 0m }));

        Sheet(wb, "docs", "Summary of documents issued during the tax period (13)",
            ["", "", "", "Total Number", "Total Cancelled"],
            ["", "", "", docs.Sum(r => N(r, "Total")), docs.Sum(r => N(r, "Cancelled"))],
            ["Nature of Document", "Sr. No. From", "Sr. No. To", "Total Number", "Cancelled"],
            docs.Select(r => new object[] { S(r, "Nature"), S(r, "FromNo"), S(r, "ToNo"), N(r, "Total"), N(r, "Cancelled") }));

        // a note for the user, last, so the tool's sheets keep their place
        var info = wb.Worksheets.Add("about");
        info.Cell(1, 1).Value = $"GSTR-1 of {S(head, "BranchName")} · GSTIN {S(head, "Gstin")} · return period {S(head, "ReturnPeriod")} ({D(head, "FromDate")} to {D(head, "ToDate")}) · {S(head, "Scope")}";
        info.Cell(2, 1).Value = "Prepared from the pharmacy's posted bills and sale returns. Import the sheets into the GST offline tool (or copy them into its template), check, then file on the portal.";
        info.Cell(3, 1).Value = "Delete this sheet if your offline tool version does not accept extra sheets.";
        info.Column(1).Width = 140;

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    private static string UqcText(string code) => Uqc.TryGetValue(code, out var t) ? $"{code.ToUpperInvariant()}-{t}" : "OTH-OTHERS";

    private static void Sheet(XLWorkbook wb, string name, string title, object[] sumLabels, object[] sumValues, string[] headings, IEnumerable<object[]> rows)
    {
        var ws = wb.Worksheets.Add(name);
        ws.Cell(1, 1).Value = title;
        ws.Row(1).Style.Font.SetBold().Fill.SetBackgroundColor(XLColor.FromHtml("#1F4E78")).Font.SetFontColor(XLColor.White);
        for (var c = 0; c < sumLabels.Length; c++) ws.Cell(2, c + 1).Value = XLCellValue.FromObject(sumLabels[c]);
        for (var c = 0; c < sumValues.Length; c++) ws.Cell(3, c + 1).Value = XLCellValue.FromObject(sumValues[c]);
        ws.Row(2).Style.Font.SetBold().Fill.SetBackgroundColor(XLColor.FromHtml("#DDEBF7"));
        for (var c = 0; c < headings.Length; c++) ws.Cell(4, c + 1).Value = headings[c];
        ws.Range(4, 1, 4, headings.Length).Style.Font.SetBold().Fill.SetBackgroundColor(XLColor.FromHtml("#F4B183")).Alignment.SetWrapText(true);
        var r = 5;
        foreach (var row in rows)
        {
            for (var c = 0; c < row.Length; c++) ws.Cell(r, c + 1).Value = XLCellValue.FromObject(row[c]);
            r++;
        }
        for (var c = 1; c <= headings.Length; c++)
        {
            var h = headings[c - 1];
            if (h.Contains("Value") || h.Contains("Amount")) ws.Column(c).Style.NumberFormat.Format = "0.00";
            ws.Column(c).Width = Math.Max(14, Math.Min(42, h.Length + 4));
        }
        ws.SheetView.FreezeRows(4);
    }
}
