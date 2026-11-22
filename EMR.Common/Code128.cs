using System.Text;

namespace EMR.Common;

/// <summary>
/// Code 128 barcodes as SVG (print template "Barcode (bill no)"). Code 128 carries every printable ASCII character -
/// bill numbers such as LAB/HO2627000414 included ('/' breaks Code 39 on scanners in Full ASCII mode) - and is read by
/// any standard 1D scanner. Code set B for text, switching to C for runs of digits (shorter, so the bars stay wider).
/// Quiet zone of 10 modules on each side; the check digit is added.
/// </summary>
public static class Code128
{
    // module widths (bar, space, bar, space, bar, space) of values 0..105, and STOP (106, seven elements)
    private static readonly string[] Patterns =
    [
        "212222","222122","222221","121223","121322","131222","122213","122312","132212","221213",
        "221312","231212","112232","122132","122231","113222","123122","123221","223211","221132",
        "221231","213212","223112","312131","311222","321122","321221","312212","322112","322211",
        "212123","212321","232121","111323","131123","131321","112313","132113","132311","211313",
        "231113","231311","112133","112331","132131","113123","113321","133121","313121","211331",
        "231131","213113","213311","213131","311123","311321","331121","312113","312311","332111",
        "314111","221411","431111","111224","111422","121124","121421","141122","141221","112214",
        "112412","122114","122411","142112","142211","241211","221114","413111","241112","134111",
        "111242","121142","121241","114212","124112","124211","411212","421112","421211","212141",
        "214121","412121","111143","111341","131141","114113","114311","411113","411311","113141",
        "114131","311141","411131","211412","211214","211232","2331112"
    ];
    private const int StartB = 104, StartC = 105, CodeB = 100, CodeC = 99, Stop = 106;

    /// <summary>Narrowest bar a scanner / phone camera reads reliably on paper (mm) - the barcode is never drawn finer.</summary>
    public const double MinModuleMm = 0.33;

    /// <summary>The barcode's width in modules (bars, spaces and both quiet zones); 0 when it cannot be drawn.</summary>
    public static int Modules(string value)
    {
        var svg = Svg(value);
        if (svg is null) return 0;
        var i = svg.IndexOf("viewBox=\"0 0 ", StringComparison.Ordinal) + 13;
        return int.Parse(svg.AsSpan(i, svg.IndexOf(' ', i) - i));
    }

    /// <summary>The narrowest width (mm) at which the value still scans reliably.</summary>
    public static double MinWidthMm(string value) => Modules(value) * MinModuleMm;

    /// <summary>The value as a Code 128 barcode (SVG that stretches to its box), or null when it is empty or has a character
    /// outside printable ASCII.</summary>
    public static string? Svg(string value)
    {
        value = (value ?? string.Empty).Trim();
        if (value.Length == 0 || value.Any(ch => ch < 32 || ch > 126)) return null;

        var codes = Encode(value);
        int sum = codes[0];
        for (int i = 1; i < codes.Count; i++) sum += codes[i] * i;
        codes.Add(sum % 103);
        codes.Add(Stop);

        const int quiet = 10;
        var widths = string.Concat(codes.Select(c => Patterns[c]));
        int total = widths.Sum(ch => ch - '0') + quiet * 2;
        var svg = new StringBuilder();
        svg.Append($"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {total} 40\" preserveAspectRatio=\"none\" shape-rendering=\"crispEdges\">");
        svg.Append($"<rect x=\"0\" y=\"0\" width=\"{total}\" height=\"40\" fill=\"#fff\"/>");
        int x = quiet;
        for (int i = 0; i < widths.Length; i++)
        {
            int w = widths[i] - '0';
            if (i % 2 == 0) svg.Append($"<rect x=\"{x}\" y=\"0\" width=\"{w}\" height=\"40\" fill=\"#000\"/>");
            x += w;
        }
        svg.Append("</svg>");
        return svg.ToString();
    }

    private static int DigitRun(string s, int from)
    {
        int n = 0;
        while (from + n < s.Length && char.IsAsciiDigit(s[from + n])) n++;
        return n;
    }

    private static List<int> Encode(string s)
    {
        var codes = new List<int>();
        int i = 0;
        // start in C when the value opens with 4+ digits (an even count of them is packed in pairs)
        bool inC = DigitRun(s, 0) >= 4;
        codes.Add(inC ? StartC : StartB);
        while (i < s.Length)
        {
            if (inC)
            {
                if (DigitRun(s, i) >= 2) { codes.Add((s[i] - '0') * 10 + (s[i + 1] - '0')); i += 2; continue; }
                codes.Add(CodeB); inC = false; continue;
            }
            int run = DigitRun(s, i);
            // switch to C for a run of 4+ digits that reaches the end, or 6+ in the middle (only when it saves space)
            if ((run >= 4 && i + run == s.Length) || run >= 6)
            {
                if (run % 2 == 1) { codes.Add(s[i] - 32); i++; }   // odd run: one digit in B first
                codes.Add(CodeC); inC = true; continue;
            }
            codes.Add(s[i] - 32); i++;
        }
        return codes;
    }
}
