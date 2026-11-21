using System.Net;
using System.Text.RegularExpressions;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Common;

// The patient app's bill and Image report PDFs, drawn in code with QuestPDF (as the LAB report is,
// LabReportPdfDocument), so the server needs no browser to make them. They follow the print pages
// (LabOrderBooking / OPD PrintBill, LabImageReporting/Print) in content: letterhead, patient and bill
// details, the lines and totals or the report text, sign-off.

/// <summary>The hospital's letterhead, from Hospital Settings of the bill's branch.</summary>
public sealed record PdfLetterhead(string HospitalName, string? HospitalType, string? Address, string? Phone, string? Email,
    string? Website, string? RegistrationNo, string? Gstin, string? Nabh, byte[]? Logo);

public sealed record PdfBillLine(string Name, string? Detail, decimal Amount, decimal Discount, bool Cancelled);
public sealed record PdfBillPayment(string Method, string? Reference, DateTime? Date, decimal Amount);
public sealed record PdfAmount(string Label, decimal Amount, bool Strong = false);

/// <summary>A LAB or OPD bill, as the bill print shows it.</summary>
public sealed class PdfBill
{
    public required string Title { get; init; }   // "LAB Bill" / "OPD Bill"
    public required (string Label, string? Value)[] Patient { get; init; }
    public required (string Label, string? Value)[] Bill { get; init; }
    public required string ItemHeader { get; init; }   // "Investigation" / "Service"
    public required List<PdfBillLine> Lines { get; init; }
    public required List<PdfAmount> Totals { get; init; }
    public required List<PdfBillPayment> Payments { get; init; }
    public string? AmountInWords { get; init; }
    public string? Status { get; init; }   // "PAID" / "PARTLY PAID" / "UNPAID" / "CANCELLED"
    public string? PrintedBy { get; init; }
}

public sealed record PdfSignatory(string Name, string? Title, string? RegistrationNo, byte[]? Signature);
public sealed record PdfReportSection(string TestName, string? Html);

/// <summary>The Image report (X-Ray, USG, ...): the findings written in the report editor, per test.</summary>
public sealed class PdfImageReport
{
    public required (string Label, string? Value)[] Patient { get; init; }
    public required (string Label, string? Value)[] Order { get; init; }
    public required List<PdfReportSection> Sections { get; init; }
    public required List<PdfSignatory> Signatories { get; init; }
}

public static class PatientPdfDocuments
{
    private static readonly string Accent = "#4B2C82";
    private static readonly string Grey = "#5F6470";
    private static readonly string Line = "#D9DCE3";

    static PatientPdfDocuments() => QuestPDF.Settings.License = LicenseType.Community;

    public static byte[] Bill(PdfLetterhead head, PdfBill bill) => Render(head, bill.Title.ToUpperInvariant(), c => BillBody(c, bill), bill.PrintedBy);

    public static byte[] ImageReport(PdfLetterhead head, PdfImageReport report) => Render(head, "IMAGING REPORT", c => ReportBody(c, report), null);

    // an unreadable logo must not lose the document: drawn again without it
    private static byte[] Render(PdfLetterhead head, string title, Action<ColumnDescriptor> body, string? printedBy)
    {
        try { return Make(head, title, body, printedBy); }
        catch when (head.Logo != null) { return Make(head with { Logo = null }, title, body, printedBy); }
    }

    private static byte[] Make(PdfLetterhead head, string title, Action<ColumnDescriptor> body, string? printedBy) =>
        Document.Create(doc => doc.Page(page =>
        {
            page.Size(PageSizes.A4);
            page.Margin(28);
            page.DefaultTextStyle(t => t.FontSize(9).FontColor("#1E2230"));
            page.Header().Element(c => Letterhead(c, head, title));
            page.Content().PaddingTop(10).Column(body);
            page.Footer().BorderTop(0.5f).BorderColor(Line).PaddingTop(4).Row(r =>
            {
                r.RelativeItem().Text(t =>
                {
                    t.Span($"Digital copy · {DateTime.Now:dd/MMM/yyyy HH:mm}").FontSize(7).FontColor(Grey);
                    if (!string.IsNullOrWhiteSpace(printedBy)) t.Span($" · {printedBy}").FontSize(7).FontColor(Grey);
                });
                r.AutoItem().Text(t =>
                {
                    t.Span("Page ").FontSize(7).FontColor(Grey);
                    t.CurrentPageNumber().FontSize(7).FontColor(Grey);
                    t.Span(" of ").FontSize(7).FontColor(Grey);
                    t.TotalPages().FontSize(7).FontColor(Grey);
                });
            });
        })).GeneratePdf();

    private static void Letterhead(IContainer c, PdfLetterhead h, string title) => c.Column(col =>
    {
        col.Item().BorderBottom(1.5f).BorderColor(Accent).PaddingBottom(6).Row(r =>
        {
            if (h.Logo is { Length: > 0 }) r.ConstantItem(64).Height(52).AlignMiddle().Image(h.Logo).FitArea();
            r.RelativeItem().PaddingLeft(h.Logo is { Length: > 0 } ? 8 : 0).Column(n =>
            {
                n.Item().Text(h.HospitalName).FontSize(15).Bold().FontColor(Accent);
                if (!string.IsNullOrWhiteSpace(h.HospitalType)) n.Item().Text(h.HospitalType).FontSize(8).FontColor(Grey);
                if (!string.IsNullOrWhiteSpace(h.Nabh)) n.Item().Text(h.Nabh).FontSize(7.5f).FontColor(Grey);
            });
            r.RelativeItem().AlignRight().Column(a =>
            {
                void L(string? text) { if (!string.IsNullOrWhiteSpace(text)) a.Item().AlignRight().Text(text).FontSize(7.5f).FontColor(Grey); }
                L(h.Address);
                L(string.IsNullOrWhiteSpace(h.Phone) ? null : $"Ph: {h.Phone}");
                L(h.Email);
                L(h.Website);
                L(string.IsNullOrWhiteSpace(h.RegistrationNo) ? null : $"Reg. No: {h.RegistrationNo}");
                L(string.IsNullOrWhiteSpace(h.Gstin) ? null : $"GSTIN: {h.Gstin}");
            });
        });
        col.Item().PaddingTop(6).AlignCenter().Text(title).FontSize(11).Bold().LetterSpacing(0.08f);
    });

    private static void InfoBoxes(ColumnDescriptor col, (string Label, string? Value)[] left, (string Label, string? Value)[] right) =>
        col.Item().Border(0.5f).BorderColor(Line).Padding(6).Row(r =>
        {
            void Box(RowDescriptor row, (string Label, string? Value)[] rows) => row.RelativeItem().Column(b =>
            {
                foreach (var (label, value) in rows.Where(x => !string.IsNullOrWhiteSpace(x.Value)))
                    b.Item().PaddingVertical(1).Row(x =>
                    {
                        x.ConstantItem(78).Text(label).FontColor(Grey);
                        x.RelativeItem().Text(value!).SemiBold();
                    });
            });
            Box(r, left);
            r.ConstantItem(12);
            Box(r, right);
        });

    private static string Rs(decimal v) => v.ToString("N2");

    private static void BillBody(ColumnDescriptor col, PdfBill bill)
    {
        col.Spacing(8);
        InfoBoxes(col, bill.Patient, bill.Bill);
        if (!string.IsNullOrWhiteSpace(bill.Status))
            col.Item().AlignRight().Text(bill.Status).Bold().FontColor(bill.Status == "PAID" ? "#1B7F45" : "#B3261E");

        var anyDiscount = bill.Lines.Any(l => l.Discount != 0);
        col.Item().Table(t =>
        {
            t.ColumnsDefinition(cd =>
            {
                cd.ConstantColumn(24);
                cd.RelativeColumn(5);
                cd.RelativeColumn(2);
                if (anyDiscount) cd.RelativeColumn(1.6f);
                cd.RelativeColumn(1.8f);
            });
            t.Header(h =>
            {
                IContainer H(IContainer x) => x.Background("#EEEAF6").PaddingVertical(4).PaddingHorizontal(4);
                h.Cell().Element(H).Text("#").Bold();
                h.Cell().Element(H).Text(bill.ItemHeader).Bold();
                h.Cell().Element(H).AlignRight().Text("Amount").Bold();
                if (anyDiscount) h.Cell().Element(H).AlignRight().Text("Discount").Bold();
                h.Cell().Element(H).AlignRight().Text("Net").Bold();
            });
            var i = 0;
            foreach (var l in bill.Lines)
            {
                IContainer C(IContainer x) => x.BorderBottom(0.5f).BorderColor(Line).PaddingVertical(3).PaddingHorizontal(4);
                t.Cell().Element(C).Text((++i).ToString()).FontColor(Grey);
                t.Cell().Element(C).Column(n =>
                {
                    var name = n.Item().Text(l.Name + (l.Cancelled ? "  (cancelled)" : ""));
                    if (l.Cancelled) name.Strikethrough().FontColor(Grey);
                    if (!string.IsNullOrWhiteSpace(l.Detail)) n.Item().Text(l.Detail).FontSize(7.5f).FontColor(Grey);
                });
                t.Cell().Element(C).AlignRight().Text(Rs(l.Amount));
                if (anyDiscount) t.Cell().Element(C).AlignRight().Text(l.Discount == 0 ? "—" : Rs(l.Discount));
                var net = t.Cell().Element(C).AlignRight().Text(Rs(l.Amount - l.Discount));
                if (l.Cancelled) net.Strikethrough().FontColor(Grey);
            }
        });

        col.Item().Row(r =>
        {
            r.RelativeItem().Column(p =>
            {
                if (bill.Payments.Count == 0) return;
                p.Item().Text("Payments").Bold().FontColor(Accent);
                foreach (var pay in bill.Payments)
                    p.Item().PaddingTop(2).Text(t =>
                    {
                        t.Span($"{pay.Method}  ").SemiBold();
                        t.Span(Rs(pay.Amount));
                        var extra = string.Join(" · ", new[] { pay.Reference, pay.Date?.ToString("dd/MMM/yyyy HH:mm") }.Where(x => !string.IsNullOrWhiteSpace(x)));
                        if (extra.Length > 0) t.Span($"   {extra}").FontSize(7.5f).FontColor(Grey);
                    });
            });
            r.ConstantItem(14);
            r.ConstantItem(220).Column(tot =>
            {
                foreach (var a in bill.Totals)
                    tot.Item().BorderBottom(a.Strong ? 0 : 0.3f).BorderColor(Line).PaddingVertical(2).Row(x =>
                    {
                        var label = x.RelativeItem().Text(a.Label);
                        var value = x.AutoItem().Text($"Rs. {Rs(a.Amount)}");
                        if (a.Strong) { label.Bold(); value.Bold(); }
                    });
            });
        });
        if (!string.IsNullOrWhiteSpace(bill.AmountInWords))
            col.Item().Text(t => { t.Span("Amount received in words: ").FontColor(Grey); t.Span(bill.AmountInWords).Italic(); });
        col.Item().PaddingTop(6).Text("This is a computer generated bill and does not need a signature.").FontSize(7.5f).FontColor(Grey);
    }

    private static void ReportBody(ColumnDescriptor col, PdfImageReport report)
    {
        col.Spacing(8);
        InfoBoxes(col, report.Patient, report.Order);
        foreach (var s in report.Sections)
        {
            col.Item().PaddingTop(4).Text(s.TestName.ToUpperInvariant()).FontSize(10.5f).Bold().FontColor(Accent).LetterSpacing(0.04f);
            col.Item().Column(c => HtmlBlocks.Compose(c, s.Html));
        }
        if (report.Signatories.Count > 0)
            col.Item().PaddingTop(18).Row(r =>
            {
                r.RelativeItem();
                foreach (var p in report.Signatories)
                    r.ConstantItem(150).AlignCenter().Column(sg =>
                    {
                        if (p.Signature is { Length: > 0 })
                            sg.Item().Height(34).AlignCenter().Element(e => { try { e.Image(p.Signature).FitArea(); } catch { } });
                        else sg.Item().Height(34);
                        sg.Item().AlignCenter().Text(p.Name).Bold();
                        if (!string.IsNullOrWhiteSpace(p.Title)) sg.Item().AlignCenter().Text(p.Title).FontSize(8).FontColor(Grey);
                        if (!string.IsNullOrWhiteSpace(p.RegistrationNo)) sg.Item().AlignCenter().Text($"Reg. No: {p.RegistrationNo}").FontSize(7.5f).FontColor(Grey);
                    });
            });
        col.Item().PaddingTop(10).AlignCenter().Text("— End of report —").FontSize(8).FontColor(Grey);
    }
}

/// <summary>
/// The report editor's HTML (paragraphs, headings, bold / italic / underline, lists, tables, line breaks) laid out as
/// QuestPDF text. Styles, colours and images in the HTML are left out; the words and their structure are kept.
/// </summary>
internal static partial class HtmlBlocks
{
    private sealed record Run(string Text, bool Bold, bool Italic, bool Underline);
    private abstract record Block;
    private sealed record Para(List<Run> Runs, int Heading, string? Bullet) : Block;
    private sealed record TableBlock(List<List<List<Run>>> Rows) : Block;

    [GeneratedRegex(@"<!--.*?-->|<(/?)([a-zA-Z0-9]+)([^>]*)>|([^<]+)", RegexOptions.Singleline)]
    private static partial Regex Tokens();

    [GeneratedRegex(@"<(style|script|head)[^>]*>.*?</\1>", RegexOptions.Singleline | RegexOptions.IgnoreCase)]
    private static partial Regex Hidden();

    private static readonly HashSet<string> BlockTags = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "blockquote", "section", "article", "pre"];

    public static void Compose(ColumnDescriptor col, string? html)
    {
        col.Spacing(4);
        var blocks = Parse(html ?? "");
        if (blocks.Count == 0) { col.Item().Text("—").FontColor("#5F6470"); return; }
        foreach (var b in blocks)
        {
            if (b is Para p)
                col.Item().PaddingLeft(p.Bullet != null ? 12 : 0).Text(t =>
                {
                    if (p.Bullet != null) t.Span(p.Bullet + " ");
                    var size = p.Heading switch { 1 => 13f, 2 => 12f, 3 => 11f, > 3 => 10f, _ => 9.5f };
                    foreach (var r in p.Runs) Style(t.Span(r.Text).FontSize(size), r, p.Heading > 0);
                });
            else if (b is TableBlock tb && tb.Rows.Count > 0)
            {
                var cols = tb.Rows.Max(r => r.Count);
                col.Item().Table(t =>
                {
                    t.ColumnsDefinition(cd => { for (var i = 0; i < cols; i++) cd.RelativeColumn(); });
                    foreach (var row in tb.Rows)
                        for (var i = 0; i < cols; i++)
                        {
                            var cell = i < row.Count ? row[i] : [];
                            t.Cell().Border(0.5f).BorderColor("#D9DCE3").Padding(3).Text(x =>
                            {
                                foreach (var r in cell) Style(x.Span(r.Text).FontSize(9), r, false);
                            });
                        }
                });
            }
        }
    }

    private static void Style(TextSpanDescriptor s, Run r, bool heading)
    {
        if (r.Bold || heading) s.Bold();
        if (r.Italic) s.Italic();
        if (r.Underline) s.Underline();
    }

    private static List<Block> Parse(string html)
    {
        var blocks = new List<Block>();
        var runs = new List<Run>();
        int bold = 0, italic = 0, underline = 0, heading = 0;
        var lists = new Stack<(bool Ordered, int N)>();
        string? bullet = null;
        List<List<List<Run>>>? table = null;
        List<List<Run>>? row = null;
        List<Run>? cell = null;

        void Flush()
        {
            // trim the paragraph's edges; empty paragraphs are dropped
            while (runs.Count > 0 && string.IsNullOrWhiteSpace(runs[0].Text)) runs.RemoveAt(0);
            while (runs.Count > 0 && string.IsNullOrWhiteSpace(runs[^1].Text)) runs.RemoveAt(runs.Count - 1);
            if (runs.Count > 0)
            {
                runs[0] = runs[0] with { Text = runs[0].Text.TrimStart() };
                runs[^1] = runs[^1] with { Text = runs[^1].Text.TrimEnd() };
                blocks.Add(new Para([.. runs], heading, bullet));
            }
            runs.Clear();
            bullet = null;
        }

        foreach (Match m in Tokens().Matches(Hidden().Replace(html, "")))
        {
            if (m.Groups[4].Success)
            {
                var text = Regex.Replace(WebUtility.HtmlDecode(m.Groups[4].Value), @"[ \t\r\n]+", " ").Replace(' ', ' ');
                if (text.Length == 0) continue;
                var run = new Run(text, bold > 0, italic > 0, underline > 0);
                if (cell != null) cell.Add(run); else runs.Add(run);
                continue;
            }
            if (!m.Groups[2].Success) continue;
            var close = m.Groups[1].Value == "/";
            var tag = m.Groups[2].Value.ToLowerInvariant();
            var attrs = m.Groups[3].Value;
            switch (tag)
            {
                case "b" or "strong": bold += close ? -1 : 1; bold = Math.Max(0, bold); break;
                case "i" or "em": italic += close ? -1 : 1; italic = Math.Max(0, italic); break;
                case "u": underline += close ? -1 : 1; underline = Math.Max(0, underline); break;
                case "span" when !close && Regex.IsMatch(attrs, @"font-weight\s*:\s*(bold|[6-9]00)", RegexOptions.IgnoreCase):
                    break;   // inline styles are not followed
                case "br":
                    if (cell != null) cell.Add(new Run("\n", false, false, false));
                    else { Flush(); }
                    break;
                case "table":
                    if (!close) { Flush(); table = []; }
                    else if (table != null) { blocks.Add(new TableBlock(table)); table = null; row = null; cell = null; }
                    break;
                case "tr":
                    if (table == null) break;
                    if (!close) { row = []; table.Add(row); } else row = null;
                    break;
                case "td" or "th":
                    if (row == null) break;
                    if (!close) { cell = []; row.Add(cell); if (tag == "th") bold++; }
                    else { cell = null; if (tag == "th") bold = Math.Max(0, bold - 1); }
                    break;
                case "ul" or "ol":
                    Flush();
                    if (!close) lists.Push((tag == "ol", 0)); else if (lists.Count > 0) lists.Pop();
                    break;
                case "li":
                    Flush();
                    if (!close)
                    {
                        if (lists.Count > 0)
                        {
                            var (ordered, n) = lists.Pop();
                            lists.Push((ordered, n + 1));
                            bullet = ordered ? $"{n + 1}." : "•";
                        }
                        else bullet = "•";
                    }
                    break;
                case "h1" or "h2" or "h3" or "h4" or "h5" or "h6":
                    Flush();
                    heading = close ? 0 : tag[1] - '0';
                    break;
                default:
                    if (BlockTags.Contains(tag) && cell == null) Flush();
                    break;
            }
        }
        Flush();
        if (table != null) blocks.Add(new TableBlock(table));
        return blocks;
    }
}
