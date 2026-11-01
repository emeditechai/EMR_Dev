using System.Globalization;
using System.Text.Json;
using ClosedXML.Excel;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Web.Services.Reports;

/// <summary>What the export prints above the data: branch, period, the filters in use and who produced it.</summary>
public sealed record BillingRegisterExportInfo(
    string BranchName, DateTime From, DateTime To, IReadOnlyList<string> Filters, string GeneratedBy, DateTime GeneratedAt, bool AllUsers);

/// <summary>
/// Reports > LAB > Daily Billing Register, server-side Excel and PDF (SQLScripts/2387).
/// Detail: bill by bill, each bill followed by its lines - tests / profiles / packages (cancelled ones marked) and misc
/// charges - with rate, discount, GST and net; totals at the end. Summary: the chosen grouping with its totals.
/// Works on the register procedure's rows as returned by the API (column names as in the procedure).
/// </summary>
public static class LabBillingRegisterExport
{
    private static readonly CultureInfo In = CultureInfo.GetCultureInfo("en-IN");
    private const string Brand = "#1d4ed8";

    public static string S(Dictionary<string, JsonElement> r, string k) =>
        r.TryGetValue(k, out var v) && v.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined) ? v.ToString() : "";
    public static decimal N(Dictionary<string, JsonElement> r, string k) =>
        r.TryGetValue(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDecimal() : 0;
    private static bool B(Dictionary<string, JsonElement> r, string k) =>
        r.TryGetValue(k, out var v) && (v.ValueKind == JsonValueKind.True || (v.ValueKind == JsonValueKind.Number && v.GetInt32() == 1));
    private static string DT(Dictionary<string, JsonElement> r, string k) =>
        DateTime.TryParse(S(r, k), CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d.ToString("dd MMM yyyy, hh:mm tt", CultureInfo.InvariantCulture) : S(r, k);
    private static string Money(decimal v) => "₹" + v.ToString("#,##0.00", In);
    private static string Period(BillingRegisterExportInfo i) =>
        i.From.Date == i.To.Date ? i.From.ToString("dd MMM yyyy") : $"{i.From:dd MMM yyyy} – {i.To:dd MMM yyyy}";
    private static string Status(Dictionary<string, JsonElement> r) => S(r, "PaymentStatus") switch
    {
        "PAID" => "Paid", "PARTIAL" => "Partial", "UNPAID" => "Unpaid", "CANCELLED" => "Cancelled", var x => x
    };
    private static string Billing(Dictionary<string, JsonElement> r) => S(r, "BillingType") + (S(r, "PartnerName") is { Length: > 0 } p ? " - " + p : "");
    private static string LineName(Dictionary<string, JsonElement> l) =>
        S(l, "TestName") + (S(l, "ItemType") is { Length: > 0 } t && t != "Test" ? $" [{t}]" : "") + (B(l, "IsCancelled") ? " (cancelled)" : "");

    private static readonly string[] BillHead =
        ["#", "Bill No", "Token", "Booking No", "Bill Date", "Patient", "Billing", "Tests", "Gross", "Discount", "Round Off", "Net", "Collected", "Due", "Status", "Referred By", "Billed By"];
    private static readonly string[] LineHead = ["", "Line", "Code", "Test / Item", "Type", "Department", "Rate", "Discount", "GST", "Net", "Status"];
    private static readonly (string Field, string Label)[] Totals =
        [("GrossAmount", "Gross"), ("DiscountAmount", "Discount"), ("RoundOffAmount", "Round Off"), ("NetAmount", "Net"), ("PaidAmount", "Collected"), ("DueAmount", "Due")];

    // ───────────────────────────── Excel ─────────────────────────────
    public static byte[] BuildExcel(List<Dictionary<string, JsonElement>> rows, List<Dictionary<string, JsonElement>> lines,
        List<Dictionary<string, JsonElement>> groups, string view, string? groupKey, string groupLabel, BillingRegisterExportInfo info)
    {
        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add(view == "summary" ? "Summary" : "Bills");
        var r = Header(ws, info, view == "summary" ? $"Summary by {groupLabel}" : "Detail with bill lines");

        if (view == "summary")
        {
            string[] head = [groupLabel, "Bills", "Tests", "Gross", "Discount", "Round Off", "Net", "Collected", "Due"];
            for (var c = 0; c < head.Length; c++) ws.Cell(r, c + 1).Value = head[c];
            StyleHead(ws.Range(r, 1, r, head.Length)); r++;
            var gs = groups.Where(g => S(g, "GroupKey") == groupKey).ToList();
            foreach (var g in gs)
            {
                ws.Cell(r, 1).Value = S(g, "GroupName");
                ws.Cell(r, 2).Value = N(g, "BillCount"); ws.Cell(r, 3).Value = N(g, "TestCount");
                for (var i = 0; i < Totals.Length; i++) ws.Cell(r, 4 + i).Value = N(g, Totals[i].Field);
                r++;
            }
            ws.Cell(r, 1).Value = "Total";
            ws.Cell(r, 2).Value = gs.Sum(g => N(g, "BillCount")); ws.Cell(r, 3).Value = gs.Sum(g => N(g, "TestCount"));
            for (var i = 0; i < Totals.Length; i++) ws.Cell(r, 4 + i).Value = gs.Sum(g => N(g, Totals[i].Field));
            ws.Range(r, 1, r, head.Length).Style.Font.SetBold().Fill.SetBackgroundColor(XLColor.FromHtml("#eef2ff"));
            ws.Range(1, 4, r, 9).Style.NumberFormat.Format = "#,##0.00";
            ws.Columns().AdjustToContents(8, 60);
        }
        else
        {
            var byBill = lines.GroupBy(l => S(l, "LabOrderId")).ToDictionary(g => g.Key, g => g.OrderBy(l => N(l, "LineSeq")).ToList());
            for (var c = 0; c < BillHead.Length; c++) ws.Cell(r, c + 1).Value = BillHead[c];
            StyleHead(ws.Range(r, 1, r, BillHead.Length)); r++;
            var no = 0;
            foreach (var b in rows)
            {
                object[] v = [++no, S(b, "BillNo"), S(b, "TokenNo"), S(b, "BookingNo"), DT(b, "BillDate"), $"{S(b, "PatientName")} ({S(b, "PatientCode")})", Billing(b),
                              N(b, "TestCount"), N(b, "GrossAmount"), N(b, "DiscountAmount"), N(b, "RoundOffAmount"), N(b, "NetAmount"), N(b, "PaidAmount"), N(b, "DueAmount"),
                              Status(b), S(b, "ReferralDoctor") is { Length: > 0 } d ? d : "Self", S(b, "CreatedBy")];
                for (var c = 0; c < v.Length; c++) ws.Cell(r, c + 1).Value = XLCellValue.FromObject(v[c]);
                var billRow = ws.Range(r, 1, r, BillHead.Length);
                billRow.Style.Font.SetBold().Fill.SetBackgroundColor(XLColor.FromHtml(B(b, "IsCancelled") ? "#fde8e8" : "#f1f5f9"));
                ws.Range(r, 9, r, 14).Style.NumberFormat.Format = "#,##0.00";
                r++;
                if (!byBill.TryGetValue(S(b, "LabOrderId"), out var ls) || ls.Count == 0) continue;
                for (var c = 1; c < LineHead.Length; c++) ws.Cell(r, c + 1).Value = LineHead[c];
                ws.Range(r, 2, r, LineHead.Length).Style.Font.SetItalic().Font.SetFontColor(XLColor.FromHtml("#64748b")).Font.SetFontSize(9);
                r++;
                foreach (var l in ls)
                {
                    object[] lv = ["", N(l, "LineSeq"), S(l, "TestCode"), LineName(l), S(l, "ItemType"), S(l, "Department"),
                                   N(l, "Rate"), N(l, "Discount"), N(l, "Gst"), N(l, "NetAmount"), B(l, "IsCancelled") ? "Cancelled" : "Active"];
                    for (var c = 1; c < lv.Length; c++) ws.Cell(r, c + 1).Value = XLCellValue.FromObject(lv[c]);
                    var lr = ws.Range(r, 2, r, LineHead.Length);
                    lr.Style.Font.SetFontSize(9);
                    if (B(l, "IsCancelled")) lr.Style.Font.SetFontColor(XLColor.FromHtml("#94a3b8")).Font.SetStrikethrough();
                    if (S(l, "LineKind") == "1") lr.Style.Fill.SetBackgroundColor(XLColor.FromHtml("#fffbeb"));
                    ws.Range(r, 7, r, 10).Style.NumberFormat.Format = "#,##0.00";
                    r++;
                }
                ws.Rows(r - ls.Count - 1, r - 1).Group();
            }
            // totals
            ws.Cell(r, 1).Value = $"Total ({rows.Count} bills)";
            ws.Cell(r, 8).Value = rows.Sum(b => N(b, "TestCount"));
            for (var i = 0; i < Totals.Length; i++) ws.Cell(r, 9 + i).Value = rows.Sum(b => N(b, Totals[i].Field));
            ws.Range(r, 1, r, BillHead.Length).Style.Font.SetBold().Fill.SetBackgroundColor(XLColor.FromHtml("#dbeafe"));
            ws.Range(r, 9, r, 14).Style.NumberFormat.Format = "#,##0.00";
            ws.Columns().AdjustToContents(6, 48);
            ws.Column(4).Width = Math.Max(ws.Column(4).Width, 34);
        }
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    private static int Header(IXLWorksheet ws, BillingRegisterExportInfo i, string what)
    {
        ws.Cell(1, 1).Value = "Daily Billing Register";
        ws.Cell(1, 1).Style.Font.SetBold().Font.SetFontSize(14).Font.SetFontColor(XLColor.FromHtml(Brand));
        ws.Cell(2, 1).Value = $"{(string.IsNullOrWhiteSpace(i.BranchName) ? "" : "Branch: " + i.BranchName + "   ·   ")}Period: {Period(i)}   ·   {what}";
        ws.Cell(3, 1).Value = (i.Filters.Count > 0 ? "Filters: " + string.Join("; ", i.Filters) + "   ·   " : "") +
                              $"{(i.AllUsers ? "All users of the branch" : "Own bills")}   ·   Generated by {i.GeneratedBy} on {i.GeneratedAt:dd MMM yyyy, hh:mm tt}";
        ws.Range(2, 1, 3, 1).Style.Font.SetFontColor(XLColor.FromHtml("#475569"));
        return 5;
    }

    private static void StyleHead(IXLRange r) =>
        r.Style.Font.SetBold().Font.SetFontColor(XLColor.White).Fill.SetBackgroundColor(XLColor.FromHtml(Brand)).Alignment.SetWrapText(true);

    // ───────────────────────────── PDF ─────────────────────────────
    public static byte[] BuildPdf(List<Dictionary<string, JsonElement>> rows, List<Dictionary<string, JsonElement>> lines,
        List<Dictionary<string, JsonElement>> groups, string view, string? groupKey, string groupLabel, BillingRegisterExportInfo info)
    {
        QuestPDF.Settings.License = LicenseType.Community;
        var byBill = lines.GroupBy(l => S(l, "LabOrderId")).ToDictionary(g => g.Key, g => g.OrderBy(l => N(l, "LineSeq")).ToList());
        return Document.Create(doc => doc.Page(page =>
        {
            page.Size(PageSizes.A4.Landscape()); page.Margin(22); page.DefaultTextStyle(t => t.FontSize(7.5f));
            page.Header().Column(c =>
            {
                c.Item().Text("Daily Billing Register").FontSize(13).Bold().FontColor(Brand);
                c.Item().Text($"{(string.IsNullOrWhiteSpace(info.BranchName) ? "" : "Branch: " + info.BranchName + "   ·   ")}Period: {Period(info)}   ·   " +
                              (view == "summary" ? $"Summary by {groupLabel}" : "Detail with bill lines")).FontColor("#475569");
                if (info.Filters.Count > 0) c.Item().Text("Filters: " + string.Join("; ", info.Filters)).FontColor("#475569");
                c.Item().PaddingVertical(4).LineHorizontal(1).LineColor(Brand);
            });
            page.Content().Element(e =>
            {
                if (view == "summary") SummaryTable(e, groups.Where(g => S(g, "GroupKey") == groupKey).ToList(), groupLabel);
                else DetailTable(e, rows, byBill);
            });
            page.Footer().Row(rw =>
            {
                rw.RelativeItem().Text($"Generated by {info.GeneratedBy} on {info.GeneratedAt:dd MMM yyyy, hh:mm tt}").FontColor("#64748b");
                rw.ConstantItem(80).AlignRight().Text(t => { t.Span("Page "); t.CurrentPageNumber(); t.Span(" of "); t.TotalPages(); });
            });
        })).GeneratePdf();
    }

    private static void SummaryTable(IContainer e, List<Dictionary<string, JsonElement>> gs, string label) => e.Table(t =>
    {
        t.ColumnsDefinition(cd => { cd.RelativeColumn(3); for (var i = 0; i < 8; i++) cd.RelativeColumn(1); });
        string[] head = [label, "Bills", "Tests", "Gross", "Discount", "Round Off", "Net", "Collected", "Due"];
        t.Header(h => { foreach (var x in head) h.Cell().Background(Brand).Padding(3).Text(x).FontColor(Colors.White).SemiBold(); });
        foreach (var g in gs)
        {
            t.Cell().Padding(3).Text(S(g, "GroupName"));
            t.Cell().Padding(3).AlignRight().Text(N(g, "BillCount").ToString("0"));
            t.Cell().Padding(3).AlignRight().Text(N(g, "TestCount").ToString("0"));
            foreach (var (f, _) in Totals) t.Cell().Padding(3).AlignRight().Text(Money(N(g, f)));
        }
        t.Cell().Background("#eef2ff").Padding(3).Text("Total").Bold();
        t.Cell().Background("#eef2ff").Padding(3).AlignRight().Text(gs.Sum(g => N(g, "BillCount")).ToString("0")).Bold();
        t.Cell().Background("#eef2ff").Padding(3).AlignRight().Text(gs.Sum(g => N(g, "TestCount")).ToString("0")).Bold();
        foreach (var (f, _) in Totals) t.Cell().Background("#eef2ff").Padding(3).AlignRight().Text(Money(gs.Sum(g => N(g, f)))).Bold();
    });

    private static void DetailTable(IContainer e, List<Dictionary<string, JsonElement>> rows, Dictionary<string, List<Dictionary<string, JsonElement>>> byBill) => e.Column(col =>
    {
        var no = 0;
        foreach (var b in rows)
        {
            var cancelled = B(b, "IsCancelled");
            col.Item().PaddingTop(5).Background(cancelled ? "#fde8e8" : "#f1f5f9").Padding(4).Row(rw =>
            {
                rw.RelativeItem(4).Column(c =>
                {
                    c.Item().Text(t =>
                    {
                        t.Span($"{++no}. {S(b, "BillNo")}").Bold();
                        t.Span($"   Token {S(b, "TokenNo")}").FontColor("#475569");
                        if (S(b, "BookingNo") is { Length: > 0 } bk) t.Span($"   Booking {bk}").FontColor(Brand);
                        t.Span($"   {DT(b, "BillDate")}").FontColor("#475569");
                    });
                    c.Item().Text($"{S(b, "PatientName")} ({S(b, "PatientCode")})  ·  {Billing(b)}  ·  Ref: {(S(b, "ReferralDoctor") is { Length: > 0 } d ? d : "Self")}  ·  Billed by {S(b, "CreatedBy")}");
                });
                rw.RelativeItem(5).AlignRight().Text(t =>
                {
                    t.Span($"Gross {Money(N(b, "GrossAmount"))}   Disc {Money(N(b, "DiscountAmount"))}   R/O {N(b, "RoundOffAmount"):+0.00;-0.00;0.00}   ");
                    t.Span($"Net {Money(N(b, "NetAmount"))}").Bold();
                    t.Span($"   Collected {Money(N(b, "PaidAmount"))}   Due {Money(N(b, "DueAmount"))}   {Status(b)}");
                });
            });
            if (!byBill.TryGetValue(S(b, "LabOrderId"), out var ls) || ls.Count == 0) continue;
            col.Item().PaddingLeft(14).Table(t =>
            {
                t.ColumnsDefinition(cd => { cd.ConstantColumn(18); cd.RelativeColumn(1.2f); cd.RelativeColumn(4); cd.RelativeColumn(1.3f); cd.RelativeColumn(1.5f);
                                            cd.RelativeColumn(1.1f); cd.RelativeColumn(1.1f); cd.RelativeColumn(1); cd.RelativeColumn(1.1f); cd.RelativeColumn(1); });
                t.Header(h => { foreach (var x in LineHead.Skip(1)) h.Cell().BorderBottom(0.5f).BorderColor("#cbd5e1").Padding(2).Text(x).FontColor("#64748b").SemiBold(); });
                foreach (var l in ls)
                {
                    var off = B(l, "IsCancelled");
                    var bg = S(l, "LineKind") == "1" ? "#fffbeb" : "#ffffff";
                    void Cell(string text, bool right = false)
                    {
                        var c = t.Cell().Background(bg).Padding(2);
                        var tx = (right ? c.AlignRight() : c).Text(text).FontColor(off ? "#94a3b8" : "#0f172a");
                        if (off && !text.StartsWith("Cancelled")) tx.Strikethrough();
                    }
                    Cell(N(l, "LineSeq").ToString("0")); Cell(S(l, "TestCode")); Cell(LineName(l)); Cell(S(l, "ItemType")); Cell(S(l, "Department"));
                    Cell(Money(N(l, "Rate")), true); Cell(Money(N(l, "Discount")), true); Cell(Money(N(l, "Gst")), true); Cell(Money(N(l, "NetAmount")), true);
                    Cell(off ? "Cancelled" : "Active");
                }
            });
        }
        col.Item().PaddingTop(8).Background("#dbeafe").Padding(5).Text(t =>
        {
            t.Span($"Total: {rows.Count} bills, {rows.Sum(b => N(b, "TestCount")):0} tests   ").Bold();
            foreach (var (f, l) in Totals) t.Span($"{l} {Money(rows.Sum(b => N(b, f)))}   ");
        });
    });
}
