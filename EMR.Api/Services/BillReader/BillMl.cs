using System.Text.RegularExpressions;
using Microsoft.ML;
using Microsoft.ML.Data;
using Microsoft.ML.Transforms.Text;

namespace EMR.Api.Services.BillReader;

/// <summary>
/// ML.NET: what a column heading on a distributor's bill means. A text classifier (words + character 2-4 grams, SDCA maximum
/// entropy) trained in memory from the way Indian pharma bills label their columns ("Exp. Dt", "Sch Qty", "P.Rate", "Btch No" ...),
/// so spelling, short forms and OCR slips still land on the right field. NONE = not a heading (drug names, numbers, words).
/// </summary>
public static class BillHeaderModel
{
    private sealed class Row { public string Text { get; set; } = ""; public string Label { get; set; } = ""; }
    private sealed class Prediction { [ColumnName("Score")] public float[] Score { get; set; } = []; }

    private static readonly Lazy<(PredictionEngine<Row, Prediction> Engine, string[] Labels)> Model = new(Train);
    private static readonly Lock Gate = new();

    public static readonly Dictionary<string, string[]> Examples = new()
    {
        ["ITEM"] = ["item", "items", "item name", "product", "product name", "description", "particulars", "item description", "name of product", "product description", "medicine", "goods", "description of goods", "itm name", "prod name", "product / pack", "name"],
        ["PACK"] = ["pack", "packing", "pkg", "pack size", "unit", "uom", "pck", "packing size"],
        ["MFG"] = ["mfg", "mfr", "company", "co", "mfg by", "manufacturer", "make", "comp"],
        ["HSN"] = ["hsn", "hsn code", "hsn/sac", "hsn sac", "h.s.n", "hsncode"],
        ["BATCH"] = ["batch", "batch no", "batch no.", "b.no", "bno", "btch", "lot", "lot no", "batch number", "bat no", "b no"],
        ["EXPIRY"] = ["exp", "expiry", "exp.", "exp dt", "exp date", "expiry date", "exp.dt", "expdt", "exp. date", "expiry dt", "ex.dt", "use before"],
        ["MRP"] = ["mrp", "m.r.p", "m.r.p.", "mrp rs", "mrp/unit", "old mrp", "new mrp", "mrp per pack", "max retail price"],
        ["QTY"] = ["qty", "quantity", "q'ty", "qnty", "billed qty", "qty.", "sale qty", "nos", "units", "bill qty", "qnty."],
        ["FREE"] = ["free", "free qty", "sch", "scheme", "sch qty", "bonus", "fr qty", "free goods", "f.qty", "schm"],
        ["RATE"] = ["rate", "ptr", "p.rate", "price", "pur rate", "purchase rate", "unit price", "rate/unit", "net rate", "trade price", "pts", "rate rs", "s.rate", "billing rate"],
        ["DISC"] = ["disc", "disc%", "disc %", "discount", "dis%", "cd%", "td%", "disc.", "dis", "cd", "trade disc", "spl disc"],
        ["GST"] = ["gst", "gst%", "gst %", "tax%", "tax %", "gst rate", "tax", "vat%", "gst(%)"],
        ["CGST"] = ["cgst", "cgst%", "cgst %", "c.gst", "cgst rate"],
        ["SGST"] = ["sgst", "sgst%", "sgst %", "s.gst", "sgst rate", "utgst"],
        ["IGST"] = ["igst", "igst%", "igst %", "i.gst", "igst rate"],
        ["TAXABLE"] = ["taxable", "taxable value", "taxable amt", "taxable amount", "value", "gross", "gross amt", "assessable value", "net value"],
        ["AMOUNT"] = ["amount", "amt", "total", "net amt", "net amount", "total amt", "line total", "value rs", "amount rs", "net"],
        ["SNO"] = ["s.no", "sno", "sr", "sr.no", "sl", "sl.no", "#", "no", "s no"],
        ["NONE"] = ["dolo 650", "paracetamol", "tablet", "tablets", "capsule", "syrup", "injection", "strip", "10x10", "15's", "pharma", "pvt ltd", "limited", "laboratories",
                    "invoice", "gstin", "dl no", "phone", "address", "kolkata", "west bengal", "terms", "conditions", "signature", "authorised", "for", "subject to", "jurisdiction",
                    "12.50", "150", "2027", "06/27", "abc123", "and", "the", "of", "to", "cash", "credit", "bank", "ifsc", "a/c", "date", "bill", "e&oe", "page", "continued"]
    };

    private static (PredictionEngine<Row, Prediction>, string[]) Train()
    {
        var ml = new MLContext(seed: 11);
        var rows = Examples.SelectMany(kv => kv.Value.SelectMany(t => new[] { t, t.ToUpperInvariant(), t.Replace(".", "").Replace(" ", "") }).Select(t => new Row { Text = Normalize(t), Label = kv.Key }));
        var data = ml.Data.LoadFromEnumerable(rows);
        var pipeline = ml.Transforms.Conversion.MapValueToKey("Label")
            .Append(ml.Transforms.Text.FeaturizeText("Features", new TextFeaturizingEstimator.Options
            {
                CaseMode = TextNormalizingEstimator.CaseMode.Lower, KeepPunctuations = false, KeepNumbers = true,
                WordFeatureExtractor = new WordBagEstimator.Options { NgramLength = 2, UseAllLengths = true },
                CharFeatureExtractor = new WordBagEstimator.Options { NgramLength = 3, UseAllLengths = true },
                Norm = TextFeaturizingEstimator.NormFunction.L2
            }, nameof(Row.Text)))
            .Append(ml.MulticlassClassification.Trainers.SdcaMaximumEntropy("Label", "Features", maximumNumberOfIterations: 60));
        var model = pipeline.Fit(data);
        VBuffer<ReadOnlyMemory<char>> names = default;
        model.GetOutputSchema(data.Schema)["Score"].Annotations.GetValue("SlotNames", ref names);
        return (ml.Model.CreatePredictionEngine<Row, Prediction>(model), names.DenseValues().Select(n => n.ToString()).ToArray());
    }

    public static string Normalize(string s) => Regex.Replace(s.ToLowerInvariant().Replace("'", ""), @"[^a-z0-9%/#&\. ]+", " ").Trim();

    /// <summary>The field a heading means and the model's probability.</summary>
    public static (string Label, double P) Classify(string text)
    {
        var (engine, labels) = Model.Value;
        float[] s;
        lock (Gate) s = engine.Predict(new Row { Text = Normalize(text) }).Score;
        var best = 0;
        for (var i = 1; i < s.Length; i++) if (s[i] > s[best]) best = i;
        return (labels[best], s[best]);
    }
}

/// <summary>
/// ML.NET: which Item Master item a printed item name is. Every item (name, strength, pack, generic, code) and every name the
/// users have confirmed before is turned into a character n-gram vector (FeaturizeText, L2); a bill line is matched by cosine
/// similarity, so "DOLO-650 TAB 15S", "Dolo 650mg" and an OCR "D0LO 650" all find Dolo 650. Built per company and refreshed.
/// </summary>
public sealed class BillItemMatcher
{
    private sealed class Doc { public string Text { get; set; } = ""; }
    private sealed class Vec { [VectorType] public float[] Features { get; set; } = []; }

    private readonly PredictionEngine<Doc, Vec> _engine;
    private readonly List<(int ItemId, string Name, float[] V, bool Learnt)> _docs = [];
    private readonly Dictionary<string, int> _codes = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<(int Supplier, string Text), int> _aliases = [];
    private readonly Dictionary<int, string> _names = [];
    private readonly Lock _gate = new();
    public DateTime Built { get; } = DateTime.UtcNow;

    public BillItemMatcher(IEnumerable<(int ItemId, string ItemCode, string ItemName, string? Strength, string? Pack, string? Generic, string? Barcode)> items,
                           IEnumerable<(int SupplierId, string BillText, int ItemId)> aliases)
    {
        var itemList = items.ToList();
        var aliasList = aliases.ToList();
        var texts = itemList.Select(i => Clean($"{i.ItemName} {i.Strength} {i.Generic}"))
                            .Concat(aliasList.Select(a => Clean(a.BillText))).Where(t => t.Length > 0).DefaultIfEmpty("x").ToList();
        var ml = new MLContext(seed: 5);
        var fit = ml.Transforms.Text.FeaturizeText("Features", new TextFeaturizingEstimator.Options
        {
            CaseMode = TextNormalizingEstimator.CaseMode.Lower, KeepPunctuations = false, KeepNumbers = true,
            WordFeatureExtractor = new WordBagEstimator.Options { NgramLength = 1 },
            CharFeatureExtractor = new WordBagEstimator.Options { NgramLength = 3, UseAllLengths = false },
            Norm = TextFeaturizingEstimator.NormFunction.L2
        }, nameof(Doc.Text)).Fit(ml.Data.LoadFromEnumerable(texts.Select(t => new Doc { Text = t })));
        _engine = ml.Model.CreatePredictionEngine<Doc, Vec>(fit);
        foreach (var i in itemList)
        {
            _names[i.ItemId] = i.ItemName;
            _docs.Add((i.ItemId, i.ItemName, Embed(Clean($"{i.ItemName} {i.Strength} {i.Generic}")), false));
            if (!string.IsNullOrWhiteSpace(i.ItemCode)) _codes[i.ItemCode.Trim()] = i.ItemId;
            if (!string.IsNullOrWhiteSpace(i.Barcode)) _codes[i.Barcode.Trim()] = i.ItemId;
        }
        foreach (var a in aliasList)
        {
            if (!_names.ContainsKey(a.ItemId)) continue;
            _aliases[(a.SupplierId, Key(a.BillText))] = a.ItemId;
            _docs.Add((a.ItemId, _names[a.ItemId], Embed(Clean(a.BillText)), true));
        }
    }

    private float[] Embed(string text) { lock (_gate) return _engine.Predict(new Doc { Text = text }).Features.ToArray(); }

    public static string Key(string s) => Regex.Replace(s.ToUpperInvariant(), @"\s+", " ").Trim();

    /// <summary>Upper case, OCR zero / O confusion inside words fixed, pack words dropped ("TAB", "15'S", "1X10").</summary>
    public static string Clean(string s)
    {
        s = s.ToUpperInvariant();
        s = Regex.Replace(s, @"(?<=[A-Z])0(?=[A-Z])", "O");
        s = Regex.Replace(s, @"\b(\d+\s*['`]?\s*S|\d+\s*X\s*\d+|TABS?|TABLETS?|CAPS?|CAPSULES?|STRIPS?|STRP|BOTTLE|BTL|VIAL|INJ|SYP|SYRUP|PCS|NOS|MG|ML|GM)\b", " ");
        s = Regex.Replace(s, @"(?<=\d)(MG|ML|GM)\b", " ");
        return Regex.Replace(s, @"[^A-Z0-9 ]+", " ").Trim();
    }

    /// <summary>Learnt name (this supplier, then any) -> code / barcode in the text -> nearest name by cosine.</summary>
    public (int? ItemId, string? Name, double Score, string By, List<(int, string, double)> Alternatives) Match(string billText, int supplierId)
    {
        var key = Key(billText);
        if (_aliases.TryGetValue((supplierId, key), out var a1) || _aliases.TryGetValue((0, key), out a1)) return (a1, _names[a1], 0.99, "LEARNT", []);
        foreach (var tok in Regex.Split(billText, @"\s+"))
            if (tok.Length >= 5 && _codes.TryGetValue(tok, out var c)) return (c, _names[c], 0.98, "CODE", []);
        var clean = Clean(billText);
        if (clean.Length < 2 || _docs.Count == 0) return (null, null, 0, "NONE", []);
        var v = Embed(clean);
        var ranked = _docs.Select(d => (d.ItemId, d.Name, Score: Cos(v, d.V) + (d.Learnt ? 0.03 : 0)))
                          .GroupBy(x => x.ItemId).Select(g => g.OrderByDescending(x => x.Score).First())
                          .OrderByDescending(x => x.Score).Take(4).ToList();
        if (ranked.Count == 0) return (null, null, 0, "NONE", []);
        var best = ranked[0];
        // the leading number usually is the strength: a different one is a different product (Pan 40 vs Pan 20)
        var num = Regex.Match(clean, @"\b\d{2,4}\b").Value;
        if (num.Length > 0 && !Clean(best.Name).Contains(num) && ranked.Skip(1).FirstOrDefault(r => Clean(r.Name).Contains(num)) is { ItemId: > 0 } sameStrength && sameStrength.Score > best.Score - 0.12)
            best = sameStrength;
        var score = Math.Min(0.97, best.Score);
        var alts = ranked.Where(r => r.ItemId != best.ItemId).Select(r => (r.ItemId, r.Name, Math.Round(r.Score, 2))).ToList();
        return score >= 0.45 ? (best.ItemId, best.Name, score, "ML", alts) : (null, null, score, "NONE", ranked.Select(r => (r.ItemId, r.Name, Math.Round(r.Score, 2))).ToList());
    }

    private static double Cos(float[] a, float[] b)
    {
        double s = 0; var n = Math.Min(a.Length, b.Length);
        for (var i = 0; i < n; i++) s += a[i] * b[i];
        return s;   // both are L2-normalised
    }
}
