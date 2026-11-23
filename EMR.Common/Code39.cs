using System.Text;

namespace EMR.Common;

/// <summary>Code 39 barcodes as SVG (membership cards, print template barcodes).</summary>
public static class Code39
{
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
    public static string? Svg(string value)
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
