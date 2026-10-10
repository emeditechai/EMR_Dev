using System.Text;
using EMR.Web.Models.ViewModels;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Web.Services;

/// <summary>What the card shows about the issuing lab (from Hospital Settings of the branch).</summary>
public class MembershipCardIssuer
{
    public string Name { get; set; } = "Membership";
    public string? Contact { get; set; }
    public string? Website { get; set; }
    public byte[]? Logo { get; set; }
}

/// <summary>
/// Membership card PDF (QuestPDF), ID-1 / CR80 card size (85.6 mm x 54 mm).
/// Page 1 is the front: issuer, plan, card number with a Code 39 barcode, primary member, validity.
/// Page 2 onwards is the back: covered members and the plan terms.
/// The same PDF is printed at the desk and sent to the member as the soft copy.
/// </summary>
public static class MembershipCardPdfDocument
{
    private const string Navy = "#0f3d6b";
    private const string Ink = "#111827";
    private const string Grey = "#475569";
    private const string Soft = "#cbd5e1";

    static MembershipCardPdfDocument()
    {
        // QuestPDF Community licence (free for organisations under the licence's revenue threshold).
        QuestPDF.Settings.License = LicenseType.Community;
    }

    /// <summary>Renders the card. If the logo image is unreadable the card is rendered again without it.</summary>
    public static byte[] Generate(MembershipCardDetailViewModel card, MembershipCardIssuer issuer)
    {
        try
        {
            return Build(card, issuer, issuer.Logo).GeneratePdf();
        }
        catch (Exception) when (issuer.Logo != null)
        {
            return Build(card, issuer, null).GeneratePdf();
        }
    }

    private static Document Build(MembershipCardDetailViewModel card, MembershipCardIssuer issuer, byte[]? logo) =>
        Document.Create(doc =>
        {
            doc.Page(page =>
            {
                CardPage(page);
                page.Content().Column(col =>
                {
                    col.Item().Height(13, Unit.Millimetre).Background(Navy).PaddingHorizontal(4, Unit.Millimetre).Row(row =>
                    {
                        if (logo != null)
                            row.ConstantItem(10, Unit.Millimetre).PaddingVertical(1.5f, Unit.Millimetre).AlignMiddle().Image(logo).FitArea();
                        row.RelativeItem().PaddingLeft(logo != null ? 2 : 0, Unit.Millimetre).AlignMiddle().Column(c =>
                        {
                            c.Item().Text(issuer.Name).FontSize(9).Bold().FontColor(Colors.White).ClampLines(1);
                            c.Item().Text("MEMBERSHIP CARD").FontSize(5.5f).FontColor(Soft);
                        });
                        row.AutoItem().AlignMiddle().Text(card.PlanName.ToUpperInvariant()).FontSize(7).Bold().FontColor(Colors.White);
                    });

                    col.Item().PaddingHorizontal(4, Unit.Millimetre).PaddingTop(2.5f, Unit.Millimetre).Column(body =>
                    {
                        body.Item().Text(card.PatientName).FontSize(10).Bold().FontColor(Ink).ClampLines(1);
                        body.Item().Text($"{card.PatientCode}{(string.IsNullOrWhiteSpace(card.PhoneNumber) ? "" : "  |  " + card.PhoneNumber)}")
                            .FontSize(6.5f).FontColor(Grey);

                        body.Item().PaddingTop(2, Unit.Millimetre).Row(r =>
                        {
                            r.RelativeItem().Column(c =>
                            {
                                c.Item().Text("CARD NO.").FontSize(5).FontColor(Grey);
                                c.Item().Text(card.CardNo).FontSize(11).Bold().FontColor(Navy);
                            });
                            r.AutoItem().AlignRight().Column(c =>
                            {
                                c.Item().AlignRight().Text("VALID").FontSize(5).FontColor(Grey);
                                c.Item().AlignRight().Text($"{card.ValidFrom:dd MMM yyyy} - {card.ValidTo:dd MMM yyyy}").FontSize(7).Bold().FontColor(Ink);
                            });
                        });

                        var barcode = Code39Svg(card.CardNo);
                        if (barcode != null)
                            body.Item().PaddingTop(2, Unit.Millimetre).Height(9, Unit.Millimetre).Svg(barcode);

                        body.Item().PaddingTop(1, Unit.Millimetre).Text($"{card.Members.Count} member(s)  |  {card.PlanType}")
                            .FontSize(5.5f).FontColor(Grey);
                    });
                });
            });

            doc.Page(page =>
            {
                CardPage(page);
                page.Content().Padding(4, Unit.Millimetre).Column(col =>
                {
                    col.Item().Text($"MEMBERS  |  CARD {card.CardNo}").FontSize(6).Bold().FontColor(Navy);
                    col.Item().PaddingTop(1, Unit.Millimetre).LineHorizontal(0.5f).LineColor(Soft);

                    foreach (var m in card.Members)
                    {
                        col.Item().PaddingTop(0.8f, Unit.Millimetre).Row(r =>
                        {
                            r.RelativeItem().Text(m.PatientName).FontSize(6.5f).FontColor(Ink).ClampLines(1);
                            r.ConstantItem(24, Unit.Millimetre).AlignRight().Text(m.Relation).FontSize(6).FontColor(Grey).ClampLines(1);
                        });
                    }

                    if (!string.IsNullOrWhiteSpace(card.Terms))
                    {
                        col.Item().PaddingTop(2, Unit.Millimetre).Text("TERMS").FontSize(5).Bold().FontColor(Grey);
                        col.Item().Text(card.Terms).FontSize(5).FontColor(Grey);
                    }

                    var contact = string.Join("  |  ", new[] { issuer.Contact, issuer.Website }.Where(s => !string.IsNullOrWhiteSpace(s)));
                    if (contact.Length > 0)
                        col.Item().PaddingTop(1.5f, Unit.Millimetre).Text(contact).FontSize(5.5f).FontColor(Navy);
                });
            });
        });

    private static void CardPage(PageDescriptor page)
    {
        page.Size(85.6f, 54f, Unit.Millimetre);
        page.Margin(0);
        page.PageColor(Colors.White);
        page.DefaultTextStyle(t => t.FontSize(7).FontColor(Ink));
    }

    // ── Code 39 ──────────────────────────────────────────────────────────────
    // Same character set and bar patterns as the JsBarcode CODE39 the label screens use,
    // so a card scans exactly like a label printed from the browser.
    private const string Code39Chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%*";
    private static readonly int[] Code39Patterns =
    [
        20957, 29783, 23639, 30485, 20951, 29813, 23669, 20855, 29789, 23645, 29975, 23831, 30533, 22295, 30149, 24005,
        21623, 29981, 23837, 22301, 30023, 23879, 30545, 22343, 30161, 24017, 21959, 30065, 23921, 22385, 29015, 18263,
        29141, 17879, 29045, 18293, 17783, 29021, 18269, 17477, 17489, 17681, 20753, 35770
    ];

    /// <summary>The value as a Code 39 barcode (SVG that stretches to its box), or null if it has a character Code 39 cannot carry.</summary>
    internal static string? Code39Svg(string value)
    {
        value = (value ?? string.Empty).Trim().ToUpperInvariant();
        if (value.Length == 0 || value.Any(ch => ch == '*' || Code39Chars.IndexOf(ch) < 0)) return null;

        var bits = new StringBuilder();
        void Append(char ch) => bits.Append(Convert.ToString(Code39Patterns[Code39Chars.IndexOf(ch)], 2));
        // The '*' pattern already ends with its gap; every data character is followed by one
        Append('*');
        foreach (var ch in value) { Append(ch); bits.Append('0'); }
        Append('*');

        const int quiet = 10;
        int width = bits.Length + quiet * 2;
        var svg = new StringBuilder();
        svg.Append($"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {width} 30\" preserveAspectRatio=\"none\">");
        for (int i = 0; i < bits.Length;)
        {
            if (bits[i] != '1') { i++; continue; }
            int start = i;
            while (i < bits.Length && bits[i] == '1') i++;
            svg.Append($"<rect x=\"{start + quiet}\" y=\"0\" width=\"{i - start}\" height=\"30\" fill=\"#000\"/>");
        }
        svg.Append("</svg>");
        return svg.ToString();
    }
}
