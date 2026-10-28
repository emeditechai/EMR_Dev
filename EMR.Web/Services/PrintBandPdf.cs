using EMR.Web.Models.ViewModels;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Web.Services;

/// <summary>
/// Draws a Print Templates band (SQLScripts/2324) in a QuestPDF document - the lab report header and footer.
/// The same layout as Views/Shared/_PrintBand.cshtml draws in the bill page: rows of 12-column grids, blocks in points and
/// millimetres, empty data points skipped.
/// </summary>
public static class PrintBandPdf
{
    public static void Compose(IContainer container, PrintBand band, Dictionary<string, string?> values, Func<string?, byte[]?> loadImage, bool isFooter)
    {
        // space above / below the band (outside its line and background)
        var c = container.PaddingTop((float)band.MarginTopMm, Unit.Millimetre).PaddingBottom((float)band.MarginBottomMm, Unit.Millimetre);
        if (!string.IsNullOrWhiteSpace(band.Background)) c = c.Background(Hex(band.Background, Colors.White));
        if (band.Border)
            c = isFooter ? c.BorderTop(0.8f).BorderColor(Hex(band.BorderColor, Colors.Grey.Darken2))
                         : c.BorderBottom(1.4f).BorderColor(Hex(band.BorderColor, Colors.Blue.Darken4));
        if (band.MinHeightMm > 0) c = c.MinHeight((float)band.MinHeightMm, Unit.Millimetre);
        c = c.PaddingVertical((float)band.PaddingMm, Unit.Millimetre);

        c.Column(col =>
        {
            foreach (var row in band.Rows)
            {
                if (row.Cols.All(x => x.Blocks.Count == 0 || x.Blocks.All(b => IsEmpty(b, values)))) continue;
                col.Item().PaddingBottom(1).Row(r =>
                {
                    foreach (var pc in row.Cols)
                        r.RelativeItem((float)pc.Span).Element(cell =>
                        {
                            var aligned = pc.VAlign switch { "middle" => cell.AlignMiddle(), "bottom" => cell.AlignBottom(), _ => cell.AlignTop() };
                            aligned.PaddingHorizontal(2).Column(blocks =>
                            {
                                foreach (var b in pc.Blocks.Where(b => !IsEmpty(b, values)))
                                    blocks.Item().Element(e => Block(e, b, values, loadImage));
                            });
                        });
                });
            }
        });
    }

    private static bool IsEmpty(PrintBlock b, Dictionary<string, string?> values) => b.Type switch
    {
        "field" => string.IsNullOrWhiteSpace(values.GetValueOrDefault(b.Field ?? "")),
        "text" => string.IsNullOrWhiteSpace(b.Text),
        "barcode" => string.IsNullOrWhiteSpace(values.GetValueOrDefault("docNo")),
        _ => false
    };

    private static IContainer Aligned(IContainer c, string align) => align switch { "center" => c.AlignCenter(), "right" => c.AlignRight(), _ => c.AlignLeft() };

    private static void Block(IContainer c, PrintBlock b, Dictionary<string, string?> values, Func<string?, byte[]?> loadImage)
    {
        switch (b.Type)
        {
            case "field":
            case "text":
            case "pageinfo":
            {
                var box = Aligned(c, b.Align);
                if (b.Style == "badge")
                    box = box.Border(0.5f).BorderColor(Hex(b.Color, Colors.Grey.Darken2)).PaddingHorizontal(3).PaddingVertical(0.5f);
                box.Text(t =>
                {
                    t.DefaultTextStyle(s =>
                    {
                        s = s.FontSize((float)b.Size).FontColor(Hex(b.Color, Colors.Black));
                        if (PdfFonts.Resolve(b.Font) is { } family) s = s.FontFamily(family);
                        if (b.Bold) s = s.Bold();
                        if (b.Italic) s = s.Italic();
                        if (b.Underline) s = s.Underline();
                        if (b.Strike) s = s.Strikethrough();
                        if (b.LetterSpacing > 0) s = s.LetterSpacing((float)b.LetterSpacing);
                        return s;
                    });
                    if (b.Align == "center") t.AlignCenter(); else if (b.Align == "right") t.AlignRight();
                    if (b.Type == "pageinfo")
                    {
                        t.Span(string.IsNullOrWhiteSpace(b.Text) ? "Page " : b.Text + " ");
                        t.CurrentPageNumber(); t.Span(" of "); t.TotalPages();
                        return;
                    }
                    var words = b.Type == "text" ? b.Text! : FieldText(b, values);
                    t.Span(b.Upper ? words.ToUpperInvariant() : words);
                });
                break;
            }
            case "logo":
            case "image":
            {
                var bytes = loadImage(b.Type == "logo" ? values.GetValueOrDefault("__logo") : b.ImageUrl);
                var h = (float)(b.HeightMm > 0 ? b.HeightMm : 14);
                if (bytes is null) { c.Height(h, Unit.Millimetre); break; }
                try { Aligned(c, b.Align).Height(h, Unit.Millimetre).Image(bytes).FitHeight(); }
                catch { c.Height(h, Unit.Millimetre); }
                break;
            }
            case "barcode":
            {
                var svg = MembershipCardPdfDocument.Code39Svg(values.GetValueOrDefault("docNo") ?? "");
                if (svg is null) break;
                var h = (float)(b.HeightMm > 0 ? b.HeightMm : 8);
                // an SVG needs a width to stretch to: the block takes WidthPct of the column, placed by its alignment
                var pct = (float)Math.Clamp(b.WidthPct, 10, 100);
                c.Row(row =>
                {
                    if (b.Align == "right" && pct < 100) row.RelativeItem(100 - pct);
                    if (b.Align == "center" && pct < 100) row.RelativeItem((100 - pct) / 2);
                    row.RelativeItem(pct).Column(col =>
                    {
                        col.Item().Height(h, Unit.Millimetre).Svg(svg).FitArea();
                        if (b.ShowLabel)
                            col.Item().AlignCenter().Text(values.GetValueOrDefault("docNo")).FontSize(6.5f);
                    });
                    if (b.Align == "center" && pct < 100) row.RelativeItem((100 - pct) / 2);
                    if (b.Align == "left" && pct < 100) row.RelativeItem(100 - pct);
                });
                break;
            }
            case "line":
                Aligned(c, b.Align).PaddingVertical(1).LineHorizontal((float)b.Thickness).LineColor(Hex(b.Color, Colors.Grey.Darken1));
                break;
            case "spacer":
                c.Height((float)(b.HeightMm > 0 ? b.HeightMm : 3), Unit.Millimetre);
                break;
        }
    }

    /// <summary>The words of a field block: "Label: value" when ShowLabel (the block's own label, else the field's short label).</summary>
    public static string FieldText(PrintBlock b, Dictionary<string, string?> values)
    {
        var value = values.GetValueOrDefault(b.Field ?? "") ?? "";
        if (!b.ShowLabel) return value;
        var label = !string.IsNullOrWhiteSpace(b.Text) ? b.Text : PrintFields.Find(b.Field)?.ShortLabel;
        return string.IsNullOrWhiteSpace(label) ? value : $"{label}: {value}";
    }

    private static Color Hex(string? hex, Color fallback)
    {
        if (string.IsNullOrWhiteSpace(hex)) return fallback;
        try { return Color.FromHex(hex.Trim()); } catch { return fallback; }
    }
}

/// <summary>
/// Fonts in the report PDF for Print Templates: QuestPDF draws with its built-in Lato unless the installed (system)
/// fonts are switched on; a template font is used only when the server has it - checked once per font - otherwise
/// Arial, otherwise the built-in face. A missing font never stops a report.
/// </summary>
public static class PdfFonts
{
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> Available = new(StringComparer.OrdinalIgnoreCase);

    static PdfFonts()
    {
        QuestPDF.Settings.License ??= LicenseType.Community;
        // the installed fonts (Arial, Georgia, Times New Roman ...) may be named by a template; documents that name no
        // font keep QuestPDF's default face as before
        QuestPDF.Settings.UseSystemFonts = true;
    }

    /// <summary>The family to draw a template font with, or null for the default face.</summary>
    public static string? Resolve(string? font)
    {
        var name = PrintFonts.Find(font) ?? "Arial";
        if (IsAvailable(name)) return name;
        return name != "Arial" && IsAvailable("Arial") ? "Arial" : null;
    }

    private static bool IsAvailable(string family) => Available.GetOrAdd(family, f =>
    {
        try
        {
            Document.Create(d => d.Page(p => p.Content().Text("Ag").FontFamily(f))).GeneratePdf();
            return true;
        }
        catch { return false; }
    });
}
