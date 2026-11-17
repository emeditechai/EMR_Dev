using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.Models.ViewModels;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Web.Services;

/// <summary>LAB > Work Sheet (SQLScripts/2477): one day's bills with their numeric tests (profiles as a header with their
/// tests under it), as the screen, the A4 print and the PDF show it.</summary>
public sealed class LabWorksheetDoc
{
    public DateTime Date { get; init; }
    public string DateType { get; init; } = "ORDER";
    public string Channel { get; init; } = "ALL";
    public string ValueFilter { get; init; } = "ALL";
    public List<LabWorksheetBill> Bills { get; init; } = [];

    // print / PDF header and footer: the branch's Lab Report print template, else the hospital details
    public PrintLayout? Template { get; set; }
    public Dictionary<string, string?> Values { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, byte[]> Images { get; set; } = [];
    public string? LogoUrl { get; set; }
    public byte[]? Logo { get; set; }
    public string? HospitalName { get; set; }
    public string? HospitalAddress { get; set; }
    public string? HospitalContact { get; set; }
    public string PrintedBy { get; set; } = "";
    public DateTime PrintedAt { get; set; } = DateTime.Now;

    public int TestCount => Bills.Sum(b => b.Groups.Sum(g => g.Tests.Count));
    public int FilledCount => Bills.Sum(b => b.Groups.Sum(g => g.Tests.Count(t => !string.IsNullOrWhiteSpace(t.Value))));
    public string DateTypeLabel => DateType switch { "BOOKING" => "Booking date", "COLLECTION" => "Sample collection date", _ => "Order (bill) date" };
    public string ChannelLabel => Channel switch { "B2C" => "B2C", "B2B" => "B2B", _ => "All (B2C + B2B)" };
    public string ValueLabel => ValueFilter switch { "WITH" => "with value", "WITHOUT" => "without value", _ => "" };
    public string Subtitle => $"{DateTypeLabel}: {Date:dd-MMM-yyyy} · {ChannelLabel}{(ValueLabel.Length > 0 ? " · tests " + ValueLabel : "")} · {Bills.Count} bill(s), {TestCount} test(s)";

    public static LabWorksheetDoc From(List<JsonElement> rows, DateTime date, string dateType, string channel, string valueFilter = "ALL")
    {
        var doc = new LabWorksheetDoc { Date = date, DateType = dateType, Channel = channel, ValueFilter = valueFilter };
        foreach (var bill in rows.GroupBy(r => r.I("LabOrderId")))
        {
            var f = bill.First();
            var b = new LabWorksheetBill
            {
                LabOrderId = bill.Key, BillNo = f.S("BillNo"), TokenNo = f.S("TokenNo"), BillDate = f.D("BillDate"), IsB2B = f.B("IsB2B"), IsIpd = f.B("IsIpd"),
                PatientCode = f.S("PatientCode"), PatientName = f.S("PatientName"), AgeText = f.S("AgeText"), Gender = f.S("Gender")
            };
            // in bill order: a single test is its own group (no header); a profile / package groups its tests
            foreach (var g in bill.GroupBy(r => (Item: r.I("LabOrderItemId"), Profile: r.NI("ProfileId"))))
            {
                var gf = g.First();
                b.Groups.Add(new LabWorksheetGroup
                {
                    ProfileName = g.Key.Profile is null ? null : gf.S("ProfileName"),
                    Tests = g.Select(r => new LabWorksheetTest
                    {
                        TestCode = r.S("TestCode"), TestName = r.S("TestName"), Unit = r.S("Unit"), CollectedAt = r.D("CollectedAt"), Barcode = r.S("BarcodeNo"),
                        Value = r.S("TestValue"), Flag = r.S("AbnormalFlag")
                    }).ToList()
                });
            }
            b.CollectedAt = b.Groups.SelectMany(x => x.Tests).Where(t => t.CollectedAt != null).Min(t => t.CollectedAt);
            doc.Bills.Add(b);
        }
        return doc;
    }
}

public sealed class LabWorksheetBill
{
    public int LabOrderId { get; init; }
    public string BillNo { get; init; } = "";
    public string TokenNo { get; init; } = "";
    public DateTime? BillDate { get; init; }
    public bool IsB2B { get; init; }
    public bool IsIpd { get; init; }
    public string PatientCode { get; init; } = "";
    public string PatientName { get; init; } = "";
    public string AgeText { get; init; } = "";
    public string Gender { get; init; } = "";
    public DateTime? CollectedAt { get; set; }
    public List<LabWorksheetGroup> Groups { get; } = [];
    public string AgeSex => string.Join(" / ", new[] { AgeText, Gender }.Where(s => !string.IsNullOrWhiteSpace(s)));
    public string Channel => IsB2B ? "B2B" : IsIpd ? "IPD" : "B2C";
    /// <summary>Rows the bill takes in the grid: a header row per profile + a row per test.</summary>
    public int RowCount => Groups.Sum(g => g.Tests.Count + (g.ProfileName is null ? 0 : 1));
}

public sealed class LabWorksheetGroup
{
    public string? ProfileName { get; init; }
    public List<LabWorksheetTest> Tests { get; init; } = [];
}

public sealed class LabWorksheetTest
{
    public string TestCode { get; init; } = "";
    public string TestName { get; init; } = "";
    public string Unit { get; init; } = "";
    public DateTime? CollectedAt { get; init; }
    public string Barcode { get; init; } = "";
    public string Value { get; init; } = "";
    public string Flag { get; init; } = "";
}

/// <summary>The work sheet as an A4 portrait PDF: template header / footer on every page, a ruled grid with a box per value.</summary>
public static class LabWorksheetPdf
{
    private const string Line = "#475569", Band = "#f1f5f9", Head = "#e2e8f0", ProfileBg = "#eef2ff", Ink = "#0f172a", Muted = "#64748b";

    public static byte[] Build(LabWorksheetDoc d) => Document.Create(doc => doc.Page(page =>
    {
        page.Size(PageSizes.A4);
        page.MarginHorizontal(10, Unit.Millimetre);
        page.MarginVertical(8, Unit.Millimetre);
        page.DefaultTextStyle(t => t.FontSize(8.5f).FontColor(Ink));

        page.Header().Column(col =>
        {
            if (d.Template is not null)
                col.Item().PaddingBottom(3).Element(c => PrintBandPdf.Compose(c, d.Template.Header, d.Values, Image(d), isFooter: false));
            else
                col.Item().BorderBottom(1.2f).BorderColor(Ink).PaddingBottom(4).Row(r =>
                {
                    if (d.Logo is { } logo) r.ConstantItem(45).Height(36).Image(logo).FitArea();
                    r.RelativeItem().PaddingLeft(6).Column(h =>
                    {
                        h.Item().Text(d.HospitalName ?? "").FontSize(13).Bold();
                        if (!string.IsNullOrWhiteSpace(d.HospitalAddress)) h.Item().Text(d.HospitalAddress!).FontSize(7.5f).FontColor(Muted);
                        if (!string.IsNullOrWhiteSpace(d.HospitalContact)) h.Item().Text(d.HospitalContact!).FontSize(7.5f).FontColor(Muted);
                    });
                });
            col.Item().PaddingTop(3).Row(r =>
            {
                r.RelativeItem().Text("LAB WORK SHEET").FontSize(12).Bold().LetterSpacing(0.06f);
                r.RelativeItem().AlignRight().AlignBottom().Text(d.Subtitle).FontSize(7.5f).FontColor(Muted);
            });
            if (d.Bills.Count > 0)
                col.Item().PaddingTop(2).Table(t =>
                {
                    Columns(t);
                    foreach (var x in new[] { "#", "Bill date", "Lab order / Token", "Patient / Age / Sex", "Test", "Unit", "Sample collected", "Value" })
                        t.Cell().Border(0.6f).BorderColor(Line).Background(Head).PaddingVertical(3).PaddingHorizontal(3).Text(x).FontSize(7.5f).Bold();
                });
        });

        page.Content().Column(col =>
        {
            if (d.Bills.Count == 0) { col.Item().PaddingTop(20).AlignCenter().Text("No numeric tests for this filter.").FontColor(Muted); return; }
            var n = 0;
            foreach (var b in d.Bills)
            {
                n++;
                var bg = n % 2 == 0 ? Band : "#ffffff";
                uint span = (uint)Math.Max(1, b.RowCount);
                var no = n;
                // a bill is kept on one page (unless it is longer than a page)
                var item = col.Item();
                if (b.RowCount <= 26) item = item.ShowEntire();
                item.Table(t =>
                {
                    Columns(t);
                    t.Cell().RowSpan(span).Border(0.6f).BorderColor(Line).Background(bg).Padding(3).AlignCenter().Text(no.ToString()).Bold();
                    t.Cell().RowSpan(span).Border(0.6f).BorderColor(Line).Background(bg).Padding(3).Text(b.BillDate?.ToString("dd-MMM-yy\nhh:mm tt") ?? "").FontSize(7.5f);
                    t.Cell().RowSpan(span).Border(0.6f).BorderColor(Line).Background(bg).Padding(3).Column(c =>
                    {
                        c.Item().Text(b.BillNo).FontSize(7.5f).Bold();
                        if (!string.IsNullOrWhiteSpace(b.TokenNo)) c.Item().Text("Token " + b.TokenNo).FontSize(7.5f);
                        c.Item().Text(b.Channel).FontSize(6.5f).FontColor(Muted);
                    });
                    t.Cell().RowSpan(span).Border(0.6f).BorderColor(Line).Background(bg).Padding(3).Column(c =>
                    {
                        c.Item().Text(b.PatientName).Bold();
                        c.Item().Text(b.AgeSex).FontSize(7.5f);
                        if (!string.IsNullOrWhiteSpace(b.PatientCode)) c.Item().Text(b.PatientCode).FontSize(6.5f).FontColor(Muted);
                    });
                    foreach (var g in b.Groups)
                    {
                        if (g.ProfileName is not null)
                            t.Cell().ColumnSpan(4).Border(0.6f).BorderColor(Line).Background(ProfileBg).PaddingVertical(2.5f).PaddingHorizontal(3)
                                .Text(g.ProfileName.ToUpperInvariant()).FontSize(7.5f).Bold().LetterSpacing(0.03f);
                        foreach (var x in g.Tests)
                        {
                            t.Cell().Border(0.6f).BorderColor(Line).Background(bg).PaddingVertical(4).PaddingHorizontal(3).PaddingLeft(g.ProfileName is null ? 3 : 9)
                                .Text(x.TestName);
                            t.Cell().Border(0.6f).BorderColor(Line).Background(bg).PaddingVertical(4).PaddingHorizontal(2).Text(x.Unit).FontSize(7.5f);
                            t.Cell().Border(0.6f).BorderColor(Line).Background(bg).PaddingVertical(4).PaddingHorizontal(2).Text(x.CollectedAt?.ToString("dd-MMM hh:mm tt") ?? "—").FontSize(7.5f);
                            // the value box: white, ruled, to be written in by pen (a value already entered is printed)
                            t.Cell().Border(0.6f).BorderColor(Line).Background("#ffffff").Padding(2.5f).MinHeight(18)
                                .Border(0.9f).BorderColor(Ink).AlignMiddle().AlignCenter()
                                .Text(string.IsNullOrWhiteSpace(x.Value) ? " " : x.Value).Bold().FontSize(9);
                        }
                    }
                });
            }
            col.Item().PaddingTop(14).Row(r =>
            {
                r.RelativeItem().Column(c => { c.Item().PaddingTop(18).BorderTop(0.6f).BorderColor(Line).Text("Technician (name / sign)").FontSize(7.5f).FontColor(Muted); });
                r.ConstantItem(30);
                r.RelativeItem().Column(c => { c.Item().PaddingTop(18).BorderTop(0.6f).BorderColor(Line).Text("Checked by (name / sign)").FontSize(7.5f).FontColor(Muted); });
                r.ConstantItem(30);
                r.RelativeItem().Column(c => { c.Item().PaddingTop(18).BorderTop(0.6f).BorderColor(Line).Text("Entered in system by / date").FontSize(7.5f).FontColor(Muted); });
            });
        });

        page.Footer().Column(col =>
        {
            if (d.Template is not null)
                col.Item().Element(c => PrintBandPdf.Compose(c, d.Template.Footer, d.Values, Image(d), isFooter: true));
            col.Item().BorderTop(0.5f).BorderColor(Head).PaddingTop(2).Row(r =>
            {
                r.RelativeItem().Text($"Printed by {d.PrintedBy} on {d.PrintedAt:dd-MMM-yyyy hh:mm tt}").FontSize(7).FontColor(Muted);
                r.RelativeItem().AlignRight().Text(t =>
                {
                    t.DefaultTextStyle(s => s.FontSize(7).FontColor(Muted));
                    t.Span("Page "); t.CurrentPageNumber(); t.Span(" of "); t.TotalPages();
                });
            });
        });
    })).GeneratePdf();

    private static void Columns(TableDescriptor t) => t.ColumnsDefinition(c =>
    {
        c.ConstantColumn(16);      // #
        c.ConstantColumn(48);      // bill date
        c.ConstantColumn(74);      // order / token
        c.RelativeColumn(1.2f);    // patient
        c.RelativeColumn(1.6f);    // test
        c.ConstantColumn(34);      // unit
        c.ConstantColumn(52);      // collected
        c.ConstantColumn(62);      // value box
    });

    private static Func<string?, byte[]?> Image(LabWorksheetDoc d) => path =>
        string.IsNullOrWhiteSpace(path) ? null
        : string.Equals(path, d.LogoUrl, StringComparison.OrdinalIgnoreCase) ? d.Logo
        : d.Images.GetValueOrDefault(path!);
}

/// <summary>The merged patient cells of a bill in the print grid (rowspan over the bill's rows).</summary>
public static class LabWorksheetHtml
{
    public static Microsoft.AspNetCore.Html.IHtmlContent BillCells(LabWorksheetBill b, int n)
    {
        var e = System.Text.Encodings.Web.HtmlEncoder.Default;
        var span = Math.Max(1, b.RowCount);
        var html = $"<td rowspan=\"{span}\" class=\"c b\">{n}</td>"
                 + $"<td rowspan=\"{span}\" class=\"sm\">{e.Encode(b.BillDate?.ToString("dd-MMM-yy") ?? "")}<br/>{e.Encode(b.BillDate?.ToString("hh:mm tt") ?? "")}</td>"
                 + $"<td rowspan=\"{span}\"><div class=\"b sm\">{e.Encode(b.BillNo)}</div>"
                 + (string.IsNullOrWhiteSpace(b.TokenNo) ? "" : $"<div class=\"sm\">Token {e.Encode(b.TokenNo)}</div>")
                 + $"<div class=\"mut\">{b.Channel}</div></td>"
                 + $"<td rowspan=\"{span}\"><div class=\"b\">{e.Encode(b.PatientName)}</div><div class=\"sm\">{e.Encode(b.AgeSex)}</div><div class=\"mut\">{e.Encode(b.PatientCode)}</div></td>";
        return new Microsoft.AspNetCore.Html.HtmlString(html);
    }
}
