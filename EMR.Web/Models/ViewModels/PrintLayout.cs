using System.Text.Json;
using System.Text.Json.Serialization;

namespace EMR.Web.Models.ViewModels;

/// <summary>
/// Utility > Print Templates (SQLScripts/2324): a header and a footer, each a band of rows; a row is split into columns
/// on a 12-column grid; a column holds blocks (logo, data field, text, image, barcode, line, spacer, page info).
/// The same layout is drawn in the bill page (Views/Shared/_PrintBand) and in the lab report PDF (PrintBandPdf), so a
/// template looks the same on both. Sizes are in points (text) and millimetres (heights), as on paper.
/// </summary>
public class PrintLayout
{
    public PrintBand Header { get; set; } = new();
    public PrintBand Footer { get; set; } = new();

    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public static PrintLayout? Parse(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try { return Normalize(JsonSerializer.Deserialize<PrintLayout>(json, Json)); }
        catch (JsonException) { return null; }
    }

    public string ToJson() => JsonSerializer.Serialize(this, Json);

    /// <summary>Clamps what a hand-edited or old layout could carry out of range.</summary>
    public static PrintLayout? Normalize(PrintLayout? l)
    {
        if (l is null) return null;
        foreach (var band in new[] { l.Header, l.Footer })
        {
            band.Rows ??= [];
            band.MinHeightMm = Math.Clamp(band.MinHeightMm, 0, 120);
            band.PaddingMm = Math.Clamp(band.PaddingMm, 0, 10);
            band.MarginTopMm = Math.Clamp(band.MarginTopMm, 0, 80);
            band.MarginBottomMm = Math.Clamp(band.MarginBottomMm, 0, 80);
            foreach (var row in band.Rows)
            {
                row.Cols ??= [];
                if (row.Cols.Count == 0) row.Cols.Add(new PrintCol { Span = 12 });
                foreach (var col in row.Cols)
                {
                    col.Span = Math.Round(Math.Clamp(col.Span, 0.12m, 12m), 3);
                    col.Blocks ??= [];
                    foreach (var b in col.Blocks)
                    {
                        b.Size = Math.Clamp(b.Size <= 0 ? 9 : b.Size, 5, 28);
                        b.HeightMm = Math.Clamp(b.HeightMm, 0, 60);
                        b.WidthPct = Math.Clamp(b.WidthPct <= 0 ? 100 : b.WidthPct, 10, 100);
                        b.Thickness = Math.Clamp(b.Thickness <= 0 ? 1 : b.Thickness, 0.5m, 4);
                        b.LetterSpacing = Math.Clamp(b.LetterSpacing, 0, 0.3m);
                        b.Font = PrintFonts.Find(b.Font);
                    }
                }
            }
        }
        return l;
    }
}

public class PrintBand
{
    public List<PrintRow> Rows { get; set; } = [];
    /// <summary>Lowest height of the band (the letterhead area); 0 = as tall as its content.</summary>
    public decimal MinHeightMm { get; set; }
    public decimal PaddingMm { get; set; } = 1;
    /// <summary>Space above the band: for the header, from the top of the page; for the footer, after the bill / report body.</summary>
    public decimal MarginTopMm { get; set; }
    /// <summary>Space below the band: for the header, before the bill / report body; for the footer, under it.</summary>
    public decimal MarginBottomMm { get; set; }
    /// <summary>A line under the header / over the footer.</summary>
    public bool Border { get; set; } = true;
    public string BorderColor { get; set; } = "#1a3a6b";
    public string? Background { get; set; }
}

public class PrintRow
{
    public List<PrintCol> Cols { get; set; } = [];
}

public class PrintCol
{
    /// <summary>Width in twelfths of the row - any value, not only whole twelfths (dragged or typed as a % in the designer);
    /// 6 = half the row, 2.75 = 22.9%.</summary>
    public decimal Span { get; set; } = 12;
    /// <summary>top | middle | bottom</summary>
    public string VAlign { get; set; } = "top";
    public List<PrintBlock> Blocks { get; set; } = [];
}

public class PrintBlock
{
    /// <summary>field | text | logo | image | barcode | line | spacer | pageinfo</summary>
    public string Type { get; set; } = "field";
    /// <summary>The data point of a field block (<see cref="PrintFields"/>).</summary>
    public string? Field { get; set; }
    /// <summary>The words of a text block (line breaks kept); the label of a field block when ShowLabel.</summary>
    public string? Text { get; set; }
    public bool ShowLabel { get; set; }
    /// <summary>left | center | right</summary>
    public string Align { get; set; } = "left";
    public decimal Size { get; set; } = 9;
    public bool Bold { get; set; }
    public bool Italic { get; set; }
    public bool Underline { get; set; }
    public bool Strike { get; set; }
    public bool Upper { get; set; }
    /// <summary>One of <see cref="PrintFonts.All"/>; null = Arial (the bills' font).</summary>
    public string? Font { get; set; }
    /// <summary>Extra space between letters, in em (0 - 0.3).</summary>
    public decimal LetterSpacing { get; set; }
    public string Color { get; set; } = "#111111";
    /// <summary>plain | badge (a small rounded pill)</summary>
    public string Style { get; set; } = "plain";
    /// <summary>Logo / image / barcode height, spacer height.</summary>
    public decimal HeightMm { get; set; }
    /// <summary>Line / barcode / image width as a share of the column.</summary>
    public decimal WidthPct { get; set; } = 100;
    public decimal Thickness { get; set; } = 1;
    public string? ImageUrl { get; set; }
}

/// <summary>
/// Fonts a block can use: installed with Windows (the server that makes the report PDF), so the bill page and the PDF
/// print the same face. A browser without one falls back to a similar face of the same kind.
/// </summary>
public static class PrintFonts
{
    public record Font(string Name, string Css);

    public static readonly IReadOnlyList<Font> All =
    [
        new("Arial", "Arial, Helvetica, sans-serif"),
        new("Calibri", "Calibri, Carlito, 'Segoe UI', Arial, sans-serif"),
        new("Segoe UI", "'Segoe UI', 'Helvetica Neue', Arial, sans-serif"),
        new("Tahoma", "Tahoma, Verdana, sans-serif"),
        new("Verdana", "Verdana, Geneva, sans-serif"),
        new("Trebuchet MS", "'Trebuchet MS', 'Lucida Grande', sans-serif"),
        new("Times New Roman", "'Times New Roman', Times, serif"),
        new("Georgia", "Georgia, 'Times New Roman', serif"),
        new("Cambria", "Cambria, Caladea, Georgia, serif"),
        new("Book Antiqua", "'Book Antiqua', Palatino, 'Palatino Linotype', serif"),
        new("Courier New", "'Courier New', Courier, monospace"),
        new("Impact", "Impact, 'Arial Black', sans-serif")
    ];

    /// <summary>The font by name (any case); null when not one of the list (= Arial).</summary>
    public static string? Find(string? name) => All.FirstOrDefault(f => string.Equals(f.Name, name?.Trim(), StringComparison.OrdinalIgnoreCase))?.Name;

    public static string Css(string? name) => All.FirstOrDefault(f => f.Name == name)?.Css ?? All[0].Css;
}

/// <summary>The data points a field block can show: the branch's Hospital Settings and the printed document.</summary>
public static class PrintFields
{
    public record Field(string Key, string Label, string Group, string Kinds, string ShortLabel, string Sample);

    public static readonly IReadOnlyList<Field> All =
    [
        new("hospitalName", "Hospital Name", "Organisation", "BILL,REPORT", "", "City Care Hospital"),
        new("hospitalType", "Hospital Type", "Organisation", "BILL,REPORT", "", "Super Speciality Hospital"),
        new("registrationNo", "Registration / License No", "Organisation", "BILL,REPORT", "Reg. No", "WB/KOL/HOSP/2022/889"),
        new("gstCode", "GST Code", "Organisation", "BILL,REPORT", "GSTIN", "19ABCDE1234F1Z5"),
        new("branchName", "Branch Name", "Branch contact", "BILL,REPORT", "Branch", "Head Office"),
        new("address", "Address", "Branch contact", "BILL,REPORT", "Address", "12 Park Street, Kolkata 700016"),
        new("contact1", "Contact Number 1", "Branch contact", "BILL,REPORT", "Tel", "033 4000 1234"),
        new("contact2", "Contact Number 2", "Branch contact", "BILL,REPORT", "Tel", "98300 12345"),
        new("emergency", "Emergency Helpline", "Branch contact", "BILL,REPORT", "Emergency", "+91 33 2456 9999"),
        new("email", "Email", "Branch contact", "BILL,REPORT", "Email", "care@citycare.in"),
        new("website", "Website", "Branch contact", "BILL,REPORT", "Web", "www.citycare.in"),
        new("nabhStatus", "NABH Status", "Accreditation", "BILL,REPORT", "NABH", "Entry Level Accredited"),
        new("nabhCertNo", "NABH Certificate No", "Accreditation", "BILL,REPORT", "NABH Cert", "NABH-2024-HOSP-0941"),
        new("nabhValidity", "NABH Valid From - To", "Accreditation", "BILL,REPORT", "Valid", "01-Apr-2024 to 31-Mar-2027"),
        new("docNo", "Bill No", "Document", "BILL,REPORT", "Bill No", "LAB/HO2627000296"),
        new("docDate", "Bill / Report Date", "Document", "BILL,REPORT", "Date", "25-Oct-2026 10:13 AM"),
        new("tokenNo", "Token No", "Document", "BILL", "Token", "LAB-HO-0001"),
        new("copyLabel", "Original / Duplicate", "Document", "BILL,REPORT", "", "Original"),
        new("processingLab", "Test performed at (lab and address)", "Document", "REPORT", "Performed at", "City Care Hospital, 12 Park Street"),
        new("printedAt", "Printed date and time", "Footer", "BILL,REPORT", "Printed", "25-Oct-2026 11:23 AM"),
        new("printedBy", "Printed by", "Footer", "BILL,REPORT", "Printed by", "Super Admin"),
        new("createdBy", "Created by", "Footer", "BILL", "Created by", "Super Admin")
    ];

    public static Field? Find(string? key) => All.FirstOrDefault(f => string.Equals(f.Key, key, StringComparison.OrdinalIgnoreCase));

    public static Dictionary<string, string?> Samples() => All.ToDictionary(f => f.Key, f => (string?)f.Sample);
}

/// <summary>Ready layouts a new template starts from (the user changes them in the designer).</summary>
public static class PrintLayoutStarters
{
    private static PrintBlock F(string field, decimal size = 8, bool bold = false, string align = "left", bool label = false, string color = "#333333", string style = "plain") =>
        new() { Type = "field", Field = field, Size = size, Bold = bold, Align = align, ShowLabel = label, Color = color, Style = style };

    /// <summary>Logo + name + accreditation | emergency + barcode, then the contact strip; footer: disclaimer, printed by, page.</summary>
    public static PrintLayout Standard(string kind) => new()
    {
        Header = new PrintBand
        {
            MinHeightMm = 0, Border = true, BorderColor = "#1a3a6b",
            Rows =
            [
                new PrintRow { Cols =
                [
                    new PrintCol { Span = 2, VAlign = "middle", Blocks = [new PrintBlock { Type = "logo", HeightMm = 16, Align = "left" }] },
                    new PrintCol { Span = 7, VAlign = "middle", Blocks =
                    [
                        F("hospitalName", 15, true, color: "#1a3a6b"),
                        F("hospitalType", 7.5m, color: "#555555", style: "badge"),
                        F("registrationNo", 7.5m, label: true, color: "#555555"),
                        F("nabhStatus", 7.5m, true, label: true, color: "#1a3a6b")
                    ] },
                    new PrintCol { Span = 3, VAlign = "middle", Blocks =
                    [
                        F("emergency", 7.5m, true, "right", true, "#b91c1c"),
                        new PrintBlock { Type = "barcode", Align = "right", HeightMm = 8, WidthPct = 100, ShowLabel = kind == "BILL" }
                    ] }
                ] },
                new PrintRow { Cols =
                [
                    new PrintCol { Span = 4, Blocks = [F("address", 7.5m, label: true)] },
                    new PrintCol { Span = 2, Blocks = [F("contact1", 7.5m, label: true)] },
                    new PrintCol { Span = 3, Blocks = [F("email", 7.5m, label: true)] },
                    new PrintCol { Span = 3, Blocks = [F("website", 7.5m, align: "right", label: true)] }
                ] }
            ]
        },
        Footer = new PrintBand
        {
            Border = true, BorderColor = "#999999",
            Rows = kind == "REPORT"
                ?
                [
                    new PrintRow { Cols = [new PrintCol { Span = 12, Blocks = [F("processingLab", 7.5m, true, label: true, color: "#111111")] }] },
                    new PrintRow { Cols =
                    [
                        new PrintCol { Span = 9, Blocks = [F("printedAt", 7, label: true, color: "#666666")] },
                        new PrintCol { Span = 3, Blocks = [new PrintBlock { Type = "pageinfo", Align = "right", Size = 7.5m, Color = "#666666" }] }
                    ] }
                ]
                :
                [
                    new PrintRow { Cols = [new PrintCol { Span = 12, Blocks =
                    [
                        new PrintBlock { Type = "text", Size = 7, Color = "#444444",
                            Text = "This is a computer generated document, does not require any signature. Terms and Conditions Applicable." }
                    ] }] },
                    new PrintRow { Cols =
                    [
                        new PrintCol { Span = 5, Blocks = [F("createdBy", 7, label: true, color: "#444444")] },
                        new PrintCol { Span = 4, Blocks = [F("printedAt", 7, label: true, color: "#444444")] },
                        new PrintCol { Span = 3, Blocks = [new PrintBlock { Type = "pageinfo", Align = "right", Size = 7, Color = "#444444" }] }
                    ] }
                ]
        }
    };

    /// <summary>Everything centred: logo above the name, one contact line.</summary>
    public static PrintLayout Centred(string kind)
    {
        var l = Standard(kind);
        l.Header.Rows =
        [
            new PrintRow { Cols = [new PrintCol { Span = 12, Blocks =
            [
                new PrintBlock { Type = "logo", HeightMm = 14, Align = "center" },
                F("hospitalName", 16, true, "center", color: "#1a3a6b"),
                F("hospitalType", 8, align: "center", color: "#555555"),
                F("address", 7.5m, align: "center"),
                F("contact1", 7.5m, align: "center", label: true),
                F("email", 7.5m, align: "center", label: true)
            ] }] }
        ];
        return l;
    }

    public static PrintLayout Blank() => new()
    {
        Header = new PrintBand { Rows = [new PrintRow { Cols = [new PrintCol { Span = 12 }] }] },
        Footer = new PrintBand { Rows = [new PrintRow { Cols = [new PrintCol { Span = 12 }] }] }
    };
}

/// <summary>What a band is drawn with: the band, the values of the data points, the branch logo and how to draw it.</summary>
public class PrintBandView
{
    public PrintBand Band { get; set; } = new();
    public bool IsFooter { get; set; }
    public Dictionary<string, string?> Values { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public string? LogoUrl { get; set; }
    /// <summary>Designer canvas: selectable parts and placeholders for empty columns.</summary>
    public bool DesignMode { get; set; }
    /// <summary>"h" or "f" - the prefix of the designer paths.</summary>
    public string PathPrefix { get; set; } = "h";
    public string? SelectedPath { get; set; }
}
