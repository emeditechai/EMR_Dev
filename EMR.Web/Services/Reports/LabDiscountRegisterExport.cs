using System.Globalization;
using ClosedXML.Excel;
using EMR.Web.ApiClients.Models;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Web.Services.Reports;

/// <summary>What the export prints above the data: branch, period, the filters in use and who produced it.</summary>
public sealed record DiscountRegisterExportInfo(
    string BranchName, DateTime From, DateTime To, IReadOnlyList<string> Filters, string GeneratedBy, DateTime GeneratedAt, bool AllUsers);

/// <summary>
/// Reports > LAB > Discount Register, server-side Excel and PDF: bill by bill, each bill followed by its tests and the
/// discount each test carries (a department-wise % / ₹, or its share of the bill's overall discount).
/// </summary>
public static class LabDiscountRegisterExport
{
    private static readonly CultureInfo InCulture = CultureInfo.GetCultureInfo("en-IN");

    // ── shared wording (same as the Detail tab) ──
    public static string DiscountKind(DiscountRegisterBillRow b) => b.DiscountType switch
    {
        "P" when b.DiscountValue is > 0 => $"{b.DiscountValue.Value.ToString("0.##", InCulture)}%",
        "F" => "Fixed",
        "D" => "By department",
        _ => string.Empty
    };

    public static string LineDiscountLabel(DiscountRegisterBillRow b, DiscountRegisterLineRow l)
    {
        if (l.DiscountAmount <= 0) return "—";
        if (b.DiscountType == "D")
        {
            if (l.LineDiscountType == "P") return $"{(l.LineDiscountValue ?? 0).ToString("0.##", InCulture)}% of {l.HeadName}";
            if (l.LineDiscountType == "F") return $"{Money(l.LineDiscountValue ?? 0)} on {l.HeadName}";
        }
        return "Share of bill discount";
    }

    /// <summary>A note when the tests do not carry the whole bill discount (older bills discounted on the total).</summary>
    public static string? LinesNote(DiscountRegisterBillRow b, IReadOnlyList<DiscountRegisterLineRow> lines)
    {
        if (lines.Count == 0) return "No test details recorded for this bill.";
        var d = lines.Where(l => l.IsActive).Sum(l => l.DiscountAmount);
        if (b.DiscountAmount > 0 && d == 0) return "The discount was given on the bill total, not split by test.";
        if (Math.Abs(d - b.DiscountAmount) >= 0.01m) return $"The tests carry {Money(d)} of the bill's {Money(b.DiscountAmount)} discount.";
        return null;
    }

    public static string Money(decimal v) => "₹" + v.ToString("#,##0.00", InCulture);
    private static string Date(DateTime d) => d.ToString("dd MMM yyyy", CultureInfo.InvariantCulture);
    private static string Period(DiscountRegisterExportInfo i) => i.From.Date == i.To.Date ? Date(i.From) : $"{Date(i.From)} – {Date(i.To)}";

    private static Dictionary<int, List<DiscountRegisterLineRow>> LinesByBill(DiscountRegisterResult r) =>
        r.Lines.GroupBy(l => l.LabOrderId).ToDictionary(g => g.Key, g => g.OrderBy(l => l.LabOrderItemId).ToList());

    /// <summary>Discount by department / Packages over the exported bills' active tests.</summary>
    private static List<(string Head, int Tests, decimal Mrp, decimal Discount)> ByHead(IEnumerable<DiscountRegisterBillRow> bills, Dictionary<int, List<DiscountRegisterLineRow>> lines) =>
        bills.SelectMany(b => lines.TryGetValue(b.LabOrderId, out var ls) ? ls : [])
             .Where(l => l.IsActive)
             .GroupBy(l => string.IsNullOrWhiteSpace(l.HeadName) ? "Other" : l.HeadName!)
             .Select(g => (g.Key, g.Count(), g.Sum(l => l.Mrp), g.Sum(l => l.DiscountAmount)))
             .OrderByDescending(x => x.Item4).ThenBy(x => x.Key)
             .ToList();

    // ════════════════════════════════════ Excel ════════════════════════════════════
    private const string MoneyFormat = "#,##0.00";
    private static readonly XLColor Amber = XLColor.FromHtml("#B45309");
    private static readonly XLColor BillFill = XLColor.FromHtml("#FEF3C7");
    private static readonly XLColor HeadFill = XLColor.FromHtml("#F1F5F9");

    public static byte[] BuildExcel(DiscountRegisterResult r, IReadOnlyList<DiscountRegisterBillRow> bills, DiscountRegisterExportInfo info)
    {
        var lines = LinesByBill(r);
        using var wb = new XLWorkbook();
        WriteBillWise(wb.Worksheets.Add("Bill-wise"), bills, lines, info);
        WriteTestWise(wb.Worksheets.Add("Test-wise"), bills, lines, info);
        WriteSummary(wb.Worksheets.Add("Summary"), r, bills, lines, info);
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    private static int WriteTitle(IXLWorksheet ws, string title, DiscountRegisterExportInfo info, int lastCol)
    {
        ws.Cell(1, 1).Value = title;
        ws.Cell(1, 1).Style.Font.SetBold().Font.SetFontSize(14).Font.SetFontColor(Amber);
        ws.Cell(2, 1).Value = $"{(string.IsNullOrWhiteSpace(info.BranchName) ? "" : "Branch: " + info.BranchName + "   ")}Period: {Period(info)}";
        ws.Cell(3, 1).Value = info.Filters.Count > 0 ? "Filters: " + string.Join(" · ", info.Filters) : "Filters: none";
        ws.Cell(4, 1).Value = $"Generated by {info.GeneratedBy} on {info.GeneratedAt:dd MMM yyyy, hh:mm tt}" +
                              (info.AllUsers ? " · all users' discounts of this branch" : " · only the discounts entered by this user");
        ws.Range(2, 1, 4, 1).Style.Font.SetFontColor(XLColor.FromHtml("#475569"));
        for (var row = 1; row <= 4; row++) ws.Range(row, 1, row, lastCol).Merge();
        return 6;
    }

    private static void HeaderRow(IXLWorksheet ws, int row, string[] heads)
    {
        for (var c = 0; c < heads.Length; c++) ws.Cell(row, c + 1).Value = heads[c];
        var rg = ws.Range(row, 1, row, heads.Length);
        rg.Style.Font.SetBold().Font.SetFontColor(XLColor.White).Fill.SetBackgroundColor(Amber);
        rg.Style.Alignment.SetVertical(XLAlignmentVerticalValues.Center).Alignment.SetWrapText(true);
    }

    // one bill row, its tests grouped (collapsible) under it
    private static void WriteBillWise(IXLWorksheet ws, IReadOnlyList<DiscountRegisterBillRow> bills, Dictionary<int, List<DiscountRegisterLineRow>> lines, DiscountRegisterExportInfo info)
    {
        string[] heads = ["#", "Bill No", "Token", "Bill Date", "Patient", "Patient ID", "Phone", "Type", "Test / item", "Department / head",
                          "Gross / MRP", "Discount given as", "Discount", "Discount %", "Net", "Balance", "Reason", "Approved By", "Approved On", "Entered By", "Status"];
        var row = WriteTitle(ws, "Discount Register — bill-wise, test-wise discount", info, heads.Length);
        HeaderRow(ws, row, heads);
        var headRow = row++;
        ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;

        var n = 0;
        foreach (var b in bills)
        {
            n++;
            ws.Cell(row, 1).Value = n;
            ws.Cell(row, 2).Value = b.BillNo ?? "";
            ws.Cell(row, 3).Value = b.TokenNo ?? "";
            ws.Cell(row, 4).Value = b.BillDate; ws.Cell(row, 4).Style.DateFormat.Format = "dd-MMM-yyyy";
            ws.Cell(row, 5).Value = b.PatientName ?? "";
            ws.Cell(row, 6).Value = b.PatientCode ?? "";
            ws.Cell(row, 7).Value = b.PhoneNumber ?? "";
            ws.Cell(row, 8).Value = b.BillingType;
            ws.Cell(row, 9).Value = "Bill total";
            ws.Cell(row, 11).Value = b.GrossAmount;
            ws.Cell(row, 12).Value = DiscountKind(b);
            ws.Cell(row, 13).Value = b.DiscountAmount;
            ws.Cell(row, 14).Value = b.DiscountPercent / 100m; ws.Cell(row, 14).Style.NumberFormat.Format = "0.0%";
            ws.Cell(row, 15).Value = b.NetAmount;
            ws.Cell(row, 16).Value = b.BalanceDue;
            ws.Cell(row, 17).Value = string.IsNullOrWhiteSpace(b.DiscountReason) ? "Not recorded" : b.DiscountReason;
            ws.Cell(row, 18).Value = string.IsNullOrWhiteSpace(b.ApprovedBy) ? "Not recorded" : b.ApprovedBy;
            if (b.ApprovedDate is { } ad) { ws.Cell(row, 19).Value = ad; ws.Cell(row, 19).Style.DateFormat.Format = "dd-MMM-yyyy"; }
            ws.Cell(row, 20).Value = b.EnteredBy ?? "";
            ws.Cell(row, 21).Value = b.IsBillActive ? "" : "Cancelled";
            var br = ws.Range(row, 1, row, heads.Length);
            br.Style.Font.SetBold().Fill.SetBackgroundColor(BillFill);
            br.Style.Border.SetTopBorder(XLBorderStyleValues.Thin).Border.SetTopBorderColor(XLColor.FromHtml("#E5C07B"));
            row++;

            var ls = lines.TryGetValue(b.LabOrderId, out var x) ? x : [];
            var first = row;
            foreach (var l in ls)
            {
                ws.Cell(row, 2).Value = b.BillNo ?? "";
                ws.Cell(row, 2).Style.Font.SetFontColor(XLColor.FromHtml("#94A3B8"));
                ws.Cell(row, 9).Value = (l.ItemName ?? "") + (string.IsNullOrWhiteSpace(l.ItemType) ? "" : $" ({l.ItemType})");
                ws.Cell(row, 9).Style.Alignment.SetIndent(1);
                ws.Cell(row, 10).Value = l.HeadName ?? "";
                ws.Cell(row, 11).Value = l.Mrp;
                ws.Cell(row, 12).Value = LineDiscountLabel(b, l);
                ws.Cell(row, 13).Value = l.DiscountAmount;
                if (l.Mrp > 0) { ws.Cell(row, 14).Value = l.DiscountAmount / l.Mrp; ws.Cell(row, 14).Style.NumberFormat.Format = "0.0%"; }
                ws.Cell(row, 15).Value = l.NetAmount;
                ws.Cell(row, 21).Value = l.IsActive ? "" : "Cancelled";
                if (!l.IsActive) ws.Range(row, 9, row, 15).Style.Font.SetStrikethrough();
                row++;
            }
            var note = LinesNote(b, ls);
            if (note != null)
            {
                ws.Cell(row, 9).Value = note;
                ws.Cell(row, 9).Style.Font.SetItalic().Font.SetFontColor(XLColor.FromHtml("#64748B"));
                row++;
            }
            if (row > first) ws.Rows(first, row - 1).Group();
        }

        // totals over the bills
        ws.Cell(row, 9).Value = $"Total ({bills.Count} bill(s))";
        ws.Cell(row, 11).Value = bills.Sum(b => b.GrossAmount);
        ws.Cell(row, 13).Value = bills.Sum(b => b.DiscountAmount);
        var gross = bills.Sum(b => b.GrossAmount);
        if (gross > 0) { ws.Cell(row, 14).Value = bills.Sum(b => b.DiscountAmount) / gross; ws.Cell(row, 14).Style.NumberFormat.Format = "0.0%"; }
        ws.Cell(row, 15).Value = bills.Sum(b => b.NetAmount);
        ws.Cell(row, 16).Value = bills.Sum(b => b.BalanceDue);
        var tr = ws.Range(row, 1, row, heads.Length);
        tr.Style.Font.SetBold().Fill.SetBackgroundColor(HeadFill).Border.SetTopBorder(XLBorderStyleValues.Medium);

        foreach (var c in new[] { 11, 13, 15, 16 }) ws.Range(headRow + 1, c, row, c).Style.NumberFormat.Format = MoneyFormat;
        ws.Columns().AdjustToContents(headRow, row);
        ws.Column(9).Width = Math.Min(Math.Max(ws.Column(9).Width, 28), 48);
        ws.Column(12).Width = Math.Min(Math.Max(ws.Column(12).Width, 20), 34);
        ws.Column(17).Width = Math.Min(ws.Column(17).Width, 30);
        ws.Column(1).Width = 6;
        ws.SheetView.FreezeRows(headRow);
        ws.PageSetup.PageOrientation = XLPageOrientation.Landscape;
        ws.PageSetup.FitToPages(1, 0);
        ws.PageSetup.SetRowsToRepeatAtTop(headRow, headRow);
    }

    // one row per test, filterable
    private static void WriteTestWise(IXLWorksheet ws, IReadOnlyList<DiscountRegisterBillRow> bills, Dictionary<int, List<DiscountRegisterLineRow>> lines, DiscountRegisterExportInfo info)
    {
        string[] heads = ["Bill No", "Bill Date", "Patient", "Patient ID", "Bill discount", "Test / item", "Item type", "Department / head",
                          "MRP", "Discount given as", "Discount", "Net", "Status"];
        var row = WriteTitle(ws, "Discount Register — test-wise discount", info, heads.Length);
        HeaderRow(ws, row, heads);
        var headRow = row++;
        foreach (var b in bills)
        {
            if (!lines.TryGetValue(b.LabOrderId, out var ls)) continue;
            foreach (var l in ls)
            {
                ws.Cell(row, 1).Value = b.BillNo ?? "";
                ws.Cell(row, 2).Value = b.BillDate; ws.Cell(row, 2).Style.DateFormat.Format = "dd-MMM-yyyy";
                ws.Cell(row, 3).Value = b.PatientName ?? "";
                ws.Cell(row, 4).Value = b.PatientCode ?? "";
                ws.Cell(row, 5).Value = DiscountKind(b);
                ws.Cell(row, 6).Value = l.ItemName ?? "";
                ws.Cell(row, 7).Value = l.ItemType ?? "";
                ws.Cell(row, 8).Value = l.HeadName ?? "";
                ws.Cell(row, 9).Value = l.Mrp;
                ws.Cell(row, 10).Value = LineDiscountLabel(b, l);
                ws.Cell(row, 11).Value = l.DiscountAmount;
                ws.Cell(row, 12).Value = l.NetAmount;
                ws.Cell(row, 13).Value = !b.IsBillActive ? "Bill cancelled" : (l.IsActive ? "" : "Cancelled");
                row++;
            }
        }
        if (row > headRow + 1)
        {
            ws.Range(headRow, 1, row - 1, heads.Length).SetAutoFilter();
            ws.Cell(row, 6).Value = "Total (active tests)";
            var active = bills.SelectMany(b => lines.TryGetValue(b.LabOrderId, out var ls) ? ls : []).Where(l => l.IsActive).ToList();
            ws.Cell(row, 9).Value = active.Sum(l => l.Mrp);
            ws.Cell(row, 11).Value = active.Sum(l => l.DiscountAmount);
            ws.Cell(row, 12).Value = active.Sum(l => l.NetAmount);
            ws.Range(row, 1, row, heads.Length).Style.Font.SetBold().Fill.SetBackgroundColor(HeadFill).Border.SetTopBorder(XLBorderStyleValues.Medium);
        }
        else ws.Cell(row, 1).Value = "No test details recorded for these bills.";
        foreach (var c in new[] { 9, 11, 12 }) ws.Range(headRow + 1, c, row, c).Style.NumberFormat.Format = MoneyFormat;
        ws.Columns().AdjustToContents(headRow, row);
        ws.Column(6).Width = Math.Min(Math.Max(ws.Column(6).Width, 24), 48);
        ws.SheetView.FreezeRows(headRow);
        ws.PageSetup.PageOrientation = XLPageOrientation.Landscape;
        ws.PageSetup.FitToPages(1, 0);
        ws.PageSetup.SetRowsToRepeatAtTop(headRow, headRow);
    }

    private static void WriteSummary(IXLWorksheet ws, DiscountRegisterResult r, IReadOnlyList<DiscountRegisterBillRow> bills, Dictionary<int, List<DiscountRegisterLineRow>> lines, DiscountRegisterExportInfo info)
    {
        var row = WriteTitle(ws, "Discount Register — summary", info, 5);
        var gross = bills.Sum(b => b.GrossAmount);
        var disc = bills.Sum(b => b.DiscountAmount);
        var noReason = bills.Where(b => string.IsNullOrWhiteSpace(b.DiscountReason)).ToList();
        (string, object)[] kpis =
        [
            ("Discounted bills", bills.Count),
            ("Total discount", disc),
            ("Gross of discounted bills", gross),
            ("Discount % of gross", gross > 0 ? disc / gross : 0m),
            ("Highest discount on a bill", bills.Count > 0 ? bills.Max(b => b.DiscountAmount) : 0m),
            ("Bills without a reason", noReason.Count),
            ("Discount without a reason", noReason.Sum(b => b.DiscountAmount)),
        ];
        foreach (var (label, value) in kpis)
        {
            ws.Cell(row, 1).Value = label;
            var c = ws.Cell(row, 2);
            if (value is int i) c.Value = i;
            else { c.Value = (decimal)value; c.Style.NumberFormat.Format = label.Contains('%') ? "0.0%" : MoneyFormat; }
            ws.Cell(row, 1).Style.Font.SetFontColor(XLColor.FromHtml("#475569"));
            c.Style.Font.SetBold();
            row++;
        }
        row++;

        void Group(string title, string[] heads, IEnumerable<object[]> rows)
        {
            ws.Cell(row, 1).Value = title;
            ws.Cell(row, 1).Style.Font.SetBold().Font.SetFontSize(12).Font.SetFontColor(Amber);
            row++;
            HeaderRow(ws, row, heads);
            row++;
            var start = row;
            foreach (var vals in rows)
            {
                for (var c = 0; c < vals.Length; c++)
                {
                    var cell = ws.Cell(row, c + 1);
                    switch (vals[c])
                    {
                        case int iv: cell.Value = iv; break;
                        case decimal dv: cell.Value = dv; cell.Style.NumberFormat.Format = heads[c].EndsWith('%') ? "0.0%" : MoneyFormat; break;
                        default: cell.Value = vals[c]?.ToString() ?? ""; break;
                    }
                }
                row++;
            }
            if (row == start) { ws.Cell(row, 1).Value = "—"; row++; }
            row++;
        }

        var byHead = ByHead(bills, lines);
        Group("Discount by department / head (active tests)", ["Department / head", "Tests", "MRP", "Discount", "Discount %"],
              byHead.Select(h => new object[] { h.Head, h.Tests, h.Mrp, h.Discount, h.Mrp > 0 ? h.Discount / h.Mrp : 0m }));

        IEnumerable<object[]> GroupRows(Func<DiscountRegisterBillRow, string> key) =>
            bills.GroupBy(key).Select(g => (Name: g.Key, Bills: g.Count(), Gross: g.Sum(b => b.GrossAmount), Disc: g.Sum(b => b.DiscountAmount)))
                 .OrderByDescending(g => g.Disc)
                 .Select(g => new object[] { g.Name, g.Bills, g.Gross, g.Disc, g.Gross > 0 ? g.Disc / g.Gross : 0m });
        string[] gh(string first) => [first, "Bills", "Gross", "Discount", "Discount %"];
        Group("By approver", gh("Approved by"), GroupRows(b => string.IsNullOrWhiteSpace(b.ApprovedBy) ? "Not recorded" : b.ApprovedBy!));
        Group("By reason", gh("Reason"), GroupRows(b => string.IsNullOrWhiteSpace(b.DiscountReason) ? "Not recorded" : b.DiscountReason!));
        Group("By entered by", gh("Entered by"), GroupRows(b => b.EnteredBy ?? ""));
        Group("By bill date", gh("Bill date"), bills.GroupBy(b => b.BillDate.Date).OrderBy(g => g.Key)
            .Select(g => new object[] { Date(g.Key), g.Count(), g.Sum(b => b.GrossAmount), g.Sum(b => b.DiscountAmount),
                                        g.Sum(b => b.GrossAmount) > 0 ? g.Sum(b => b.DiscountAmount) / g.Sum(b => b.GrossAmount) : 0m }));

        ws.Column(1).Width = 34;
        foreach (var c in new[] { 2, 3, 4, 5 }) ws.Column(c).Width = 16;
    }

    // ════════════════════════════════════ PDF ════════════════════════════════════
    private const string PdfInk = "#0f172a";
    private const string PdfMuted = "#64748b";
    private const string PdfAmber = "#b45309";
    private const string PdfLine = "#e2e8f0";
    private const string PdfBillBg = "#fef3c7";

    static LabDiscountRegisterExport()
    {
        QuestPDF.Settings.License = LicenseType.Community;
    }

    public static byte[] BuildPdf(DiscountRegisterResult r, IReadOnlyList<DiscountRegisterBillRow> bills, DiscountRegisterExportInfo info)
    {
        var lines = LinesByBill(r);
        return Document.Create(doc => doc.Page(page =>
        {
            page.Size(PageSizes.A4.Landscape());
            page.Margin(22);
            page.DefaultTextStyle(t => t.FontSize(8).FontColor(PdfInk));

            page.Header().Column(h =>
            {
                h.Item().Row(rw =>
                {
                    rw.RelativeItem().Column(c =>
                    {
                        c.Item().Text("Discount Register").FontSize(15).Bold().FontColor(PdfAmber);
                        c.Item().Text("Bill-wise, test-wise discount · LAB").FontSize(9).FontColor(PdfMuted);
                    });
                    rw.RelativeItem().AlignRight().Column(c =>
                    {
                        if (!string.IsNullOrWhiteSpace(info.BranchName)) c.Item().AlignRight().Text("Branch: " + info.BranchName).SemiBold();
                        c.Item().AlignRight().Text("Period: " + Period(info));
                        c.Item().AlignRight().Text(info.AllUsers ? "All users' discounts of this branch" : "Only the discounts entered by " + info.GeneratedBy)
                            .FontSize(7).FontColor(PdfMuted);
                    });
                });
                if (info.Filters.Count > 0)
                    h.Item().PaddingTop(2).Text("Filters: " + string.Join(" · ", info.Filters)).FontSize(7).FontColor(PdfMuted);
                h.Item().PaddingTop(4).LineHorizontal(1).LineColor(PdfAmber);
            });

            page.Content().PaddingTop(6).Column(col =>
            {
                col.Spacing(6);
                col.Item().Element(c => Kpis(c, bills));
                if (bills.Count == 0)
                    col.Item().PaddingTop(20).AlignCenter().Text("No discounted bills for the selected filters.").FontColor(PdfMuted);

                var n = 0;
                foreach (var b in bills)
                {
                    n++;
                    var ls = lines.TryGetValue(b.LabOrderId, out var x) ? x : [];
                    col.Item().EnsureSpace(70).Element(c => BillBlock(c, n, b, ls));
                }

                if (bills.Count > 0)
                {
                    col.Item().EnsureSpace(60).Element(c => Totals(c, bills));
                    var byHead = ByHead(bills, lines);
                    if (byHead.Count > 0) col.Item().EnsureSpace(60).Element(c => HeadSummary(c, byHead));
                }
            });

            page.Footer().BorderTop(0.5f).BorderColor(PdfLine).PaddingTop(3).Row(rw =>
            {
                rw.RelativeItem().Text($"Generated by {info.GeneratedBy} on {info.GeneratedAt:dd MMM yyyy, hh:mm tt}").FontSize(7).FontColor(PdfMuted);
                rw.RelativeItem().AlignRight().Text(t =>
                {
                    t.DefaultTextStyle(s => s.FontSize(7).FontColor(PdfMuted));
                    t.Span("Page "); t.CurrentPageNumber(); t.Span(" of "); t.TotalPages();
                });
            });
        })).GeneratePdf();
    }

    private static void Kpis(IContainer c, IReadOnlyList<DiscountRegisterBillRow> bills)
    {
        var gross = bills.Sum(b => b.GrossAmount);
        var disc = bills.Sum(b => b.DiscountAmount);
        var noReason = bills.Where(b => string.IsNullOrWhiteSpace(b.DiscountReason)).ToList();
        (string, string)[] k =
        [
            ("Total discount", Money(disc)),
            ("Discounted bills", bills.Count.ToString(InCulture)),
            ("Discount % of gross", gross > 0 ? (disc * 100 / gross).ToString("0.0", InCulture) + "%" : "—"),
            ("Gross of discounted bills", Money(gross)),
            ("Highest on a bill", Money(bills.Count > 0 ? bills.Max(b => b.DiscountAmount) : 0)),
            ("Without a reason", $"{noReason.Count} · {Money(noReason.Sum(b => b.DiscountAmount))}"),
        ];
        c.Row(rw =>
        {
            rw.Spacing(5);
            foreach (var (label, value) in k)
                rw.RelativeItem().Border(0.5f).BorderColor(PdfLine).Background("#f8fafc").Padding(5).Column(x =>
                {
                    x.Item().Text(label.ToUpperInvariant()).FontSize(6).FontColor(PdfMuted).LetterSpacing(0.05f);
                    x.Item().Text(value).FontSize(10).Bold();
                });
        });
    }

    private static void BillBlock(IContainer c, int n, DiscountRegisterBillRow b, IReadOnlyList<DiscountRegisterLineRow> ls)
    {
        // the bill line (and the tests' column headings) repeat when a long bill runs onto the next page
        c.Border(0.5f).BorderColor("#e5c07b").Decoration(dec =>
        {
            dec.Before().Column(col =>
            {
                col.Item().Background(PdfBillBg).PaddingHorizontal(6).PaddingVertical(4).Row(rw =>
                {
                    rw.ConstantItem(18).Text(n.ToString(InCulture)).FontColor(PdfMuted);
                    rw.RelativeItem(3.2f).Column(x =>
                    {
                        x.Item().Text(t =>
                        {
                            t.Span(b.BillNo ?? "").Bold();
                            if (!string.IsNullOrWhiteSpace(b.TokenNo)) t.Span("  " + b.TokenNo).FontSize(7).FontColor(PdfMuted);
                            if (!b.IsBillActive) t.Span("  CANCELLED").FontSize(7).Bold().FontColor("#b91c1c");
                        });
                        x.Item().Text($"{Date(b.BillDate)} · {b.BillingType}").FontSize(7).FontColor(PdfMuted);
                    });
                    rw.RelativeItem(3.6f).Column(x =>
                    {
                        x.Item().Text(b.PatientName ?? "").SemiBold();
                        x.Item().Text((b.PatientCode ?? "") + (string.IsNullOrWhiteSpace(b.PhoneNumber) ? "" : " · " + b.PhoneNumber)).FontSize(7).FontColor(PdfMuted);
                    });
                    rw.RelativeItem(2.2f).Element(Lbl("Gross", Money(b.GrossAmount)));
                    rw.RelativeItem(2.6f).Element(Lbl("Discount" + (DiscountKind(b) is { Length: > 0 } k ? " · " + k : ""), "−" + Money(b.DiscountAmount), PdfAmber));
                    rw.RelativeItem(1.4f).Element(Lbl("Disc %", b.DiscountPercent.ToString("0.0", InCulture) + "%"));
                    rw.RelativeItem(2.2f).Element(Lbl("Net", Money(b.NetAmount)));
                    rw.RelativeItem(2.2f).Element(Lbl("Balance", Money(b.BalanceDue), b.BalanceDue > 0 ? "#b91c1c" : PdfInk));
                });
                col.Item().PaddingHorizontal(6).PaddingVertical(3).Text(t =>
                {
                    t.DefaultTextStyle(s => s.FontSize(7).FontColor(PdfMuted));
                    t.Span("Reason: "); t.Span(string.IsNullOrWhiteSpace(b.DiscountReason) ? "Not recorded" : b.DiscountReason).FontColor(PdfInk);
                    t.Span("   Approved by: "); t.Span(string.IsNullOrWhiteSpace(b.ApprovedBy) ? "Not recorded" : b.ApprovedBy + (b.ApprovedDate is { } ad ? $" ({Date(ad)})" : "")).FontColor(PdfInk);
                    t.Span("   Entered by: "); t.Span(b.EnteredBy ?? "").FontColor(PdfInk);
                });
            });

            // its tests
            dec.Content().Column(col =>
            {
                if (ls.Count > 0)
                    col.Item().PaddingHorizontal(6).PaddingBottom(4).Table(t =>
                    {
                        t.ColumnsDefinition(cd =>
                        {
                            cd.ConstantColumn(16); cd.RelativeColumn(4.5f); cd.RelativeColumn(2.2f); cd.RelativeColumn(1.6f);
                            cd.RelativeColumn(2.6f); cd.RelativeColumn(1.6f); cd.RelativeColumn(1.6f);
                        });
                        t.Header(h =>
                        {
                            foreach (var (txt, right) in new[] { ("#", false), ("Test / item", false), ("Department / head", false), ("MRP", true),
                                                                 ("Discount given as", false), ("Discount", true), ("Net", true) })
                            {
                                var cell = h.Cell().BorderBottom(0.5f).BorderColor("#cbd5e1").PaddingVertical(2).PaddingHorizontal(2);
                                (right ? cell.AlignRight() : cell).Text(txt).FontSize(6.5f).SemiBold().FontColor(PdfMuted);
                            }
                        });
                        var i = 0;
                        foreach (var l in ls)
                        {
                            i++;
                            IContainer Cell(IContainer x) => x.BorderBottom(0.3f).BorderColor(PdfLine).PaddingVertical(2).PaddingHorizontal(2);
                            void Txt(IContainer x, string s, bool right = false, string? color = null, bool bold = false)
                            {
                                var tx = (right ? Cell(x).AlignRight() : Cell(x)).Text(s).FontColor(color ?? (l.IsActive ? PdfInk : PdfMuted));
                                if (!l.IsActive) tx.Strikethrough();
                                if (bold) tx.SemiBold();
                            }
                            Txt(t.Cell(), i.ToString(InCulture), color: PdfMuted);
                            t.Cell().Element(Cell).Text(x =>
                            {
                                var s = x.Span(l.ItemName ?? "").FontColor(l.IsActive ? PdfInk : PdfMuted);
                                if (!l.IsActive) s.Strikethrough();
                                if (!string.IsNullOrWhiteSpace(l.ItemType)) x.Span("  " + l.ItemType).FontSize(6.5f).FontColor(PdfMuted);
                                if (!l.IsActive) x.Span("  cancelled").FontSize(6.5f).FontColor("#b91c1c");
                            });
                            Txt(t.Cell(), l.HeadName ?? "");
                            Txt(t.Cell(), Money(l.Mrp), true);
                            Txt(t.Cell(), LineDiscountLabel(b, l));
                            Txt(t.Cell(), l.DiscountAmount > 0 ? "−" + Money(l.DiscountAmount) : "—", true, l.DiscountAmount > 0 && l.IsActive ? PdfAmber : null, true);
                            Txt(t.Cell(), Money(l.NetAmount), true);
                        }
                    });
                if (LinesNote(b, ls) is { } note)
                    col.Item().PaddingHorizontal(6).PaddingBottom(4).Text(note).FontSize(6.5f).Italic().FontColor(PdfMuted);
            });
        });
    }

    private static Action<IContainer> Lbl(string label, string value, string color = PdfInk) => c => c.AlignRight().Column(x =>
    {
        x.Item().AlignRight().Text(label).FontSize(6).FontColor(PdfMuted);
        x.Item().AlignRight().Text(value).Bold().FontColor(color);
    });

    private static void Totals(IContainer c, IReadOnlyList<DiscountRegisterBillRow> bills)
    {
        var gross = bills.Sum(b => b.GrossAmount);
        var disc = bills.Sum(b => b.DiscountAmount);
        c.Background("#f1f5f9").Border(0.5f).BorderColor("#cbd5e1").Padding(6).Row(rw =>
        {
            rw.RelativeItem(6.8f).Text($"Total · {bills.Count} bill(s)").Bold();
            rw.RelativeItem(2.2f).Element(Lbl("Gross", Money(gross)));
            rw.RelativeItem(2.6f).Element(Lbl("Discount", "−" + Money(disc), PdfAmber));
            rw.RelativeItem(1.4f).Element(Lbl("Disc %", gross > 0 ? (disc * 100 / gross).ToString("0.0", InCulture) + "%" : "—"));
            rw.RelativeItem(2.2f).Element(Lbl("Net", Money(bills.Sum(b => b.NetAmount))));
            rw.RelativeItem(2.2f).Element(Lbl("Balance", Money(bills.Sum(b => b.BalanceDue))));
        });
    }

    private static void HeadSummary(IContainer c, List<(string Head, int Tests, decimal Mrp, decimal Discount)> rows)
    {
        c.Column(col =>
        {
            col.Item().PaddingTop(4).Text("Discount by department / head").FontSize(10).Bold().FontColor(PdfAmber);
            col.Item().Table(t =>
            {
                t.ColumnsDefinition(cd => { cd.RelativeColumn(4); cd.RelativeColumn(1.2f); cd.RelativeColumn(2); cd.RelativeColumn(2); cd.RelativeColumn(1.4f); });
                t.Header(h =>
                {
                    foreach (var (txt, right) in new[] { ("Department / head", false), ("Tests", true), ("MRP", true), ("Discount", true), ("Discount %", true) })
                    {
                        var cell = h.Cell().Background(PdfAmber).Padding(3);
                        (right ? cell.AlignRight() : cell).Text(txt).FontSize(7).Bold().FontColor(Colors.White);
                    }
                });
                foreach (var r in rows)
                {
                    IContainer Cell(IContainer x) => x.BorderBottom(0.3f).BorderColor(PdfLine).Padding(3);
                    t.Cell().Element(Cell).Text(r.Head);
                    t.Cell().Element(Cell).AlignRight().Text(r.Tests.ToString(InCulture));
                    t.Cell().Element(Cell).AlignRight().Text(Money(r.Mrp));
                    t.Cell().Element(Cell).AlignRight().Text(Money(r.Discount)).SemiBold().FontColor(PdfAmber);
                    t.Cell().Element(Cell).AlignRight().Text(r.Mrp > 0 ? (r.Discount * 100 / r.Mrp).ToString("0.0", InCulture) + "%" : "—");
                }
            });
            col.Item().PaddingTop(2).Text("Active tests of the bills above. A bill with an overall discount counts each test's share under that test's department.")
                .FontSize(6.5f).Italic().FontColor(PdfMuted);
        });
    }
}
