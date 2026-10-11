using ClosedXML.Excel;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Web.Services;

/// <summary>
/// One Accounts report as a plain grid, written out as Excel or as a PDF (Utility > Accounts > Reports, Export).
/// Cells are strings, decimals (money, right-aligned, blank when zero) or dates; the last row is the total row when
/// <see cref="HasTotalRow"/> is set, and a row listed in <see cref="GroupRows"/> is a group heading.
/// </summary>
public class AccReportGrid
{
    public string Title { get; set; } = "";
    public string? Subject { get; set; }          // e.g. the ledger of a statement
    public string Period { get; set; } = "";
    public string? Company { get; set; }
    public string[] Heads { get; set; } = [];
    public float[] Widths { get; set; } = [];     // relative column widths for the PDF (same count as Heads)
    public List<object?[]> Rows { get; } = [];
    public HashSet<int> GroupRows { get; } = [];
    public bool HasTotalRow { get; set; }

    public string FileName(string extension) =>
        string.Concat((Subject is null ? Title : $"{Title}_{Subject}").Select(c => char.IsLetterOrDigit(c) ? c : '_')).Trim('_') + "." + extension;

    public byte[] ToExcel()
    {
        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add(Title.Length > 31 ? Title[..31] : Title);
        ws.Cell(1, 1).Value = Subject is null ? Title : $"{Title} - {Subject}";
        ws.Cell(1, 1).Style.Font.SetBold().Font.SetFontSize(13);
        ws.Cell(2, 1).Value = Period;
        for (var i = 0; i < Heads.Length; i++) ws.Cell(4, i + 1).Value = Heads[i];
        ws.Range(4, 1, 4, Heads.Length).Style.Font.SetBold().Fill.SetBackgroundColor(XLColor.FromHtml("#E2E8F0"));

        var r = 5;
        for (var n = 0; n < Rows.Count; n++, r++)
        {
            var row = Rows[n];
            for (var i = 0; i < row.Length; i++)
            {
                var cell = ws.Cell(r, i + 1);
                switch (row[i])
                {
                    case decimal d: if (d != 0) cell.Value = d; cell.Style.NumberFormat.Format = "#,##0.00"; break;
                    case DateTime dt: cell.Value = dt; cell.Style.DateFormat.Format = "dd-MMM-yyyy"; break;
                    case int k: cell.Value = k; break;
                    case null: break;
                    default: cell.Value = row[i]!.ToString(); break;
                }
            }
            if (GroupRows.Contains(n) || (HasTotalRow && n == Rows.Count - 1)) ws.Row(r).Style.Font.SetBold();
        }
        ws.Columns().AdjustToContents(4, Math.Max(4, r - 1));

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    public byte[] ToPdf()
    {
        QuestPDF.Settings.License = LicenseType.Community;
        var widths = Widths.Length == Heads.Length ? Widths : Enumerable.Repeat(1f, Heads.Length).ToArray();
        // a money column is one that holds a decimal in any row: its heading is right-aligned too
        var money = Enumerable.Range(0, Heads.Length).Select(i => Rows.Any(row => i < row.Length && row[i] is decimal)).ToArray();

        return Document.Create(doc => doc.Page(page =>
        {
            page.Size(Heads.Length > 6 ? PageSizes.A4.Landscape() : PageSizes.A4);
            page.Margin(24);
            page.DefaultTextStyle(t => t.FontSize(8));

            page.Header().PaddingBottom(8).Column(col =>
            {
                if (!string.IsNullOrWhiteSpace(Company)) col.Item().AlignCenter().Text(Company).FontSize(13).Bold();
                col.Item().AlignCenter().Text(Subject is null ? Title : $"{Title} - {Subject}").FontSize(11).SemiBold();
                col.Item().AlignCenter().Text(Period).FontSize(8.5f).FontColor(Colors.Grey.Darken2);
            });

            page.Content().Table(table =>
            {
                table.ColumnsDefinition(c => { foreach (var w in widths) c.RelativeColumn(w); });
                table.Header(h =>
                {
                    for (var i = 0; i < Heads.Length; i++)
                    {
                        var cell = h.Cell().Background(Colors.Grey.Lighten3).BorderBottom(0.75f).BorderColor(Colors.Grey.Darken1).PaddingVertical(4).PaddingHorizontal(3);
                        (money[i] ? cell.AlignRight() : cell).Text(Heads[i]).SemiBold();
                    }
                });

                for (var n = 0; n < Rows.Count; n++)
                {
                    var row = Rows[n];
                    var strong = GroupRows.Contains(n) || (HasTotalRow && n == Rows.Count - 1);
                    for (var i = 0; i < Heads.Length; i++)
                    {
                        var value = i < row.Length ? row[i] : null;
                        var cell = (strong ? table.Cell().Background(Colors.Grey.Lighten4) : table.Cell())
                            .BorderBottom(0.4f).BorderColor(Colors.Grey.Lighten1).PaddingVertical(2.5f).PaddingHorizontal(3);
                        var text = value switch
                        {
                            decimal d => d == 0 ? "" : d.ToString("N2"),
                            DateTime dt => dt.ToString("dd-MMM-yyyy"),
                            null => "",
                            _ => value.ToString() ?? ""
                        };
                        var written = (value is decimal ? cell.AlignRight() : cell).Text(text);
                        if (strong) written.SemiBold();
                    }
                }
            });

            page.Footer().PaddingTop(6).Row(row =>
            {
                row.RelativeItem().Text($"Printed {DateTime.Now:dd-MMM-yyyy HH:mm}").FontSize(7).FontColor(Colors.Grey.Darken1);
                row.RelativeItem().AlignRight().Text(t => { t.DefaultTextStyle(s => s.FontSize(7).FontColor(Colors.Grey.Darken1)); t.Span("Page "); t.CurrentPageNumber(); t.Span(" of "); t.TotalPages(); });
            });
        })).GeneratePdf();
    }
}
