using System.Text.RegularExpressions;
using EMR.Web.Models.DTOs;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.ML;
using Microsoft.ML.Data;
using Microsoft.ML.Transforms.Text;

namespace EMR.Web.Services.PrescriptionAssist;

/// <summary>A test the prescription seems to ask for: the search box option to add (I_/P_ + id) and why.</summary>
public sealed record PrescriptionSuggestion(
    string OptionKey, int InvestigationId, string TestCode, string TestName, string Kind,
    decimal Mrp, double Score, bool Preselect, string MatchedText);

public sealed record PrescriptionMatchResult(IReadOnlyList<PrescriptionSuggestion> Suggestions, IReadOnlyList<string> UnmatchedLines);

public interface IPrescriptionTestMatcher
{
    PrescriptionMatchResult Match(string ocrText, IReadOnlyList<AvailableInvestigationDto> catalogue, string catalogueKey, double minScore, double preselectScore,
        IReadOnlyList<HandwrittenLine>? handwriting = null);

    /// <summary>What a handwritten line may say: the bookable tests' names, their short forms and the lab abbreviations.</summary>
    IReadOnlyList<string> HandwritingCandidates(IReadOnlyList<AvailableInvestigationDto> catalogue);
}

/// <summary>
/// Matches prescription text to the bookable investigations / profiles / packages with ML.NET: every catalogue entry
/// (name + code + the lab abbreviations it is known by) and every phrase of the prescription become TF-IDF vectors of
/// word and character n-grams, compared by cosine similarity - so OCR slips ("Lipid Profle", "Haemogram") and
/// abbreviations ("CBC", "LFT", "FBS/PPBS") still find the right test. The model is learnt from the catalogue itself
/// and cached per catalogue.
/// </summary>
public sealed class PrescriptionTestMatcher(IMemoryCache cache) : IPrescriptionTestMatcher
{
    private sealed class TextRow { public string Text { get; set; } = string.Empty; }
    private sealed class VectorRow { [VectorType] public float[] Features { get; set; } = []; }

    private sealed record Entry(AvailableInvestigationDto Test, string Code, float[] Vector);
    private sealed record Model(MLContext Ml, ITransformer Transformer, List<Entry> Entries, Dictionary<string, AvailableInvestigationDto> Codes);

    // Common lab abbreviations / synonyms on prescriptions -> words the catalogue names use.
    private static readonly (string Abbr, string Words)[] Abbreviations =
    [
        ("cbc", "complete blood count haemogram hemogram"), ("hemogram", "complete blood count"), ("haemogram", "complete blood count"),
        ("esr", "erythrocyte sedimentation rate"), ("crp", "c reactive protein"), ("hscrp", "high sensitivity c reactive protein"),
        ("lft", "liver function test"), ("kft", "kidney renal function test"), ("rft", "renal kidney function test"),
        ("tft", "thyroid profile function t3 t4 tsh"), ("tsh", "thyroid stimulating hormone"), ("ft3", "free t3"), ("ft4", "free t4"),
        ("fbs", "fasting blood sugar glucose"), ("ppbs", "post prandial blood sugar glucose"), ("rbs", "random blood sugar glucose"),
        ("bsf", "fasting blood sugar"), ("bspp", "post prandial blood sugar"), ("bsr", "random blood sugar"),
        ("hba1c", "glycated haemoglobin hba1c"), ("a1c", "glycated haemoglobin hba1c"), ("gtt", "glucose tolerance test"),
        ("lipid", "lipid profile"), ("bun", "blood urea nitrogen"), ("urea", "blood urea"), ("creat", "serum creatinine"),
        ("ua", "uric acid"), ("alp", "alkaline phosphatase"), ("sgpt", "alt alanine aminotransferase"), ("sgot", "ast aspartate aminotransferase"),
        ("ggt", "gamma glutamyl transferase"), ("na", "sodium"), ("k", "potassium"), ("cl", "chloride"),
        ("electrolytes", "sodium potassium chloride electrolytes"), ("lytes", "electrolytes sodium potassium"),
        ("re", "routine examination"), ("rm", "routine microscopy"), ("urine", "urine routine"),
        ("pt", "prothrombin time"), ("inr", "prothrombin time inr"), ("aptt", "activated partial thromboplastin time"),
        ("ns1", "dengue ns1 antigen"), ("widal", "widal typhoid"), ("mp", "malaria parasite"), ("hbsag", "hepatitis b surface antigen"),
        ("hcv", "hepatitis c"), ("hiv", "hiv"), ("vdrl", "vdrl syphilis"), ("psa", "prostate specific antigen"),
        ("vit", "vitamin"), ("b12", "vitamin b12"), ("d3", "vitamin d"), ("hb", "haemoglobin hemoglobin"),
        ("plt", "platelet count"), ("tlc", "total leucocyte count"), ("dlc", "differential leucocyte count"),
        ("xray", "x ray"), ("cxr", "chest x ray"), ("usg", "ultrasonography ultrasound"), ("ct", "ct scan"), ("mri", "mri"),
        ("ecg", "electrocardiogram ecg"), ("echo", "echocardiography"),
        ("fbg", "fasting blood glucose sugar"), ("ppbg", "post prandial blood glucose sugar"), ("rbg", "random blood glucose sugar"),
        ("ogtt", "oral glucose tolerance test"), ("t3", "t3 triiodothyronine"), ("t4", "t4 thyroxine"),
        ("fsh", "follicle stimulating hormone"), ("lh", "luteinizing hormone"), ("prl", "prolactin"), ("hcg", "beta hcg"),
        ("tg", "triglycerides"), ("hdl", "hdl cholesterol"), ("ldl", "ldl cholesterol"), ("chol", "cholesterol"),
        ("cpk", "creatine kinase cpk"), ("ldh", "lactate dehydrogenase"), ("amylase", "serum amylase"), ("lipase", "serum lipase"),
        ("calcium", "serum calcium"), ("phos", "phosphorus"), ("tibc", "total iron binding capacity"), ("ferritin", "serum ferritin"),
        ("afb", "acid fast bacilli"), ("abo", "blood group"), ("bt", "bleeding time"), ("uacr", "urine albumin creatinine ratio"),
        ("acr", "albumin creatinine ratio"), ("cea", "carcinoembryonic antigen"), ("afp", "alpha fetoprotein"),
        ("ra", "rheumatoid factor"), ("aso", "anti streptolysin o"), ("ana", "antinuclear antibody"), ("ddimer", "d dimer"),
        // radiology / imaging
        ("xr", "x ray"), ("skiagram", "x ray"), ("skiagraph", "x ray"), ("radiograph", "x ray"), ("pa", "chest pa"),
        ("ultrasound", "usg"), ("sonography", "usg"), ("ultrasonography", "usg"), ("tvs", "usg pelvis transvaginal"),
        ("wa", "whole abdomen"), ("kub", "usg kub kidney ureter bladder"), ("anomaly", "obstetric anomaly scan"),
        ("hrct", "ct chest hrct"), ("cect", "contrast"), ("ncct", "plain"), ("thorax", "chest"), ("head", "brain"),
        ("pns", "ct pns paranasal sinus"), ("ls", "lumbar spine"), ("lumbosacral", "lumbar spine"), ("cervical", "cervical spine"),
        ("mammo", "mammography"), ("dvt", "doppler lower limb venous"), ("carotid", "doppler carotid"),
        // microbiology
        ("cs", "culture sensitivity"), ("zn", "afb zn stain"), ("koh", "koh mount fungal"), ("gram", "gram stain"),
        ("pus", "pus wound culture"), ("csf", "csf"), ("semen", "semen analysis"), ("stool", "stool routine"),
        // other common tests (matched only when the catalogue has them; they stop an OCR-slip match being forced elsewhere)
        ("pft", "pulmonary function test spirometry"), ("tmt", "treadmill test"), ("eeg", "electroencephalogram"),
        ("emg", "electromyography"), ("ncv", "nerve conduction velocity"), ("abg", "arterial blood gas"), ("bmd", "bone mineral density dexa"),
        ("dexa", "bone mineral density dexa"), ("opg", "orthopantomogram"), ("hsg", "hysterosalpingography"), ("ivp", "intravenous pyelography"),
        ("mrcp", "mrcp"), ("ercp", "ercp"), ("ugie", "upper gi endoscopy"), ("fnac", "fine needle aspiration cytology"),
        ("hpe", "histopathology"), ("pap", "pap smear"), ("cbnaat", "cbnaat genexpert"), ("rtpcr", "rt pcr")
    ];

    // Abbreviations that only qualify another word (Urine R/E, Vit D3, CT abdomen) - never a test on their own.
    private static readonly HashSet<string> ModifierOnly = ["re", "rm", "vit", "ct", "urea", "cs", "pa", "wa", "zn", "ls", "head", "thorax", "cervical", "mri", "usg", "xr"];

    // Abbreviations that may be matched with OCR slips (3+ letters; the 1-2 letter ones only when read exactly).
    private static readonly string[] FuzzyKeys = Abbreviations.Select(a => a.Abbr).Where(a => a.Length >= 3).Distinct().ToArray();

    // Prescription words that look like abbreviations but are not tests.
    private static readonly HashSet<string> CommonWords =
    [
        "tab", "cap", "syp", "inj", "od", "bd", "tds", "tid", "qid", "hs", "sos", "stat", "day", "days", "week", "weeks", "month",
        "for", "with", "and", "the", "after", "before", "food", "rest", "review", "report", "reports", "sd", "mbbs", "md", "ms",
        "dnb", "frcs", "reg", "mg", "ml", "gm", "mcg", "iu", "kg", "yrs", "yr", "age", "sex", "male", "female", "date", "dr", "mr",
        "mrs", "ms", "smt", "sri", "also", "then", "once", "twice", "daily", "night", "morning", "empty", "stomach", "all", "test",
        "tests", "inv", "invest", "adv", "advice", "pt", "plan", "repeat", "done", "new", "old", "now", "here", "clinic"
    ];

    // Characters OCR swaps for one another (handwriting and phone photos): a swap of these costs 0.35 instead of 1.
    private static readonly HashSet<(char, char)> Confusable = BuildConfusable(
        "ec eb b6 b8 co o0 ao fi fl ft fr il i1 l1 t1 it ij k1 kr kx s5 g9 g6 z2 uv nu hb hu rn 38 3s 7t vy");

    private static HashSet<(char, char)> BuildConfusable(string pairs)
    {
        var set = new HashSet<(char, char)>();
        foreach (var p in pairs.Split(' ')) { set.Add((p[0], p[1])); set.Add((p[1], p[0])); }
        return set;
    }

    /// <summary>Edit distance where a swap OCR typically makes costs 0.35; inserting / dropping a character costs 1.</summary>
    private static double OcrDistance(string a, string b)
    {
        var d = new double[a.Length + 1, b.Length + 1];
        for (var i = 0; i <= a.Length; i++) d[i, 0] = i;
        for (var j = 0; j <= b.Length; j++) d[0, j] = j;
        for (var i = 1; i <= a.Length; i++)
            for (var j = 1; j <= b.Length; j++)
            {
                var sub = a[i - 1] == b[j - 1] ? 0 : Confusable.Contains((a[i - 1], b[j - 1])) ? 0.35 : 1;
                d[i, j] = Math.Min(Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1), d[i - 1, j - 1] + sub);
            }
        return d[a.Length, b.Length];
    }

    /// <summary>
    /// The abbreviations in a phrase: read exactly ("TSH"), or read with an OCR slip ("LIT" -> lft, "FEG" -> fbg) - only
    /// for short words that are not ordinary prescription words. Returns the abbreviation and the slip's cost (0 = exact).
    /// </summary>
    private static IEnumerable<(string Token, string Abbr, double Cost)> AbbreviationsIn(string phrase)
    {
        var tokens = Norm(phrase).Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(t => t.Replace("/", "")).Where(t => t.Length > 0).ToList();
        // capitals of each word as written (OCR keeps them): "LIT" looks like an abbreviation, "tes" does not
        var capitals = Regex.Matches(phrase, "[A-Za-z0-9]+").GroupBy(m => m.Value.ToLowerInvariant())
            .ToDictionary(g => g.Key, g => g.Max(m => m.Value.Count(char.IsUpper)));
        foreach (var t in tokens)
        {
            if (CommonWords.Contains(t)) continue;
            if (ModifierOnly.Contains(t)) continue;
            if (Abbreviations.Any(a => a.Abbr == t))
            {
                if (t.Length >= 3 || (tokens.Count <= 3 && tokens.All(x => x.Length <= 2 || IsKnownWord(x)))) yield return (t, t, 0);
                continue;
            }
            if (t.Length is < 3 or > 6 || !t.Any(char.IsLetter)) continue;
            if (t.Length <= 4 && capitals.GetValueOrDefault(t) < 2) continue;   // a word fragment, not an abbreviation
            var limit = Math.Max(0.75, 0.25 * t.Length);
            var bestKey = (string?)null; var bestCost = double.MaxValue;
            foreach (var k in FuzzyKeys)
            {
                if (Math.Abs(k.Length - t.Length) > 1) continue;
                var c = OcrDistance(t, k);
                if (c < bestCost) { bestCost = c; bestKey = k; }
            }
            if (bestKey is not null && bestCost <= limit) yield return (t, bestKey, bestCost);
        }
    }

    // Letterhead and furniture anywhere in a line (e-mail, registration, titles, timings): never a test.
    private static readonly Regex Letterhead = new(
        @"@|www\.|oscopist|ologist\b|\bs\s?d\w?\s*/|[$=©£¥~_].*[$=©£¥~_]|\bregd?\b|\bregn\b|e-?mail|\bmob(ile)?\b|\bph(one)?\b|consultant|specialist|physician|surgeon|bronchoscopist|\bmbbs\b|\bm\.?\s?d\b|\bdnb\b|\bfrcs\b|nursing\s+home|hospital|clinic|polyclinic|chamber|timing|\bdate\b|\bage\b|\bsex\b|\bname\b|\buhid\b|\bpin\b|\bwbmc\b|\bmci\b",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    // Lines that are prescription furniture, not tests.
    private static readonly Regex Noise = new(
        @"^(rx|r/x|dr\.?|doctor|name|age|sex|date|reg|regn|mob|mobile|ph|phone|address|signature|sign|clinic|hospital|patient|uhid|opd|follow|review|diagnosis|c/o|o/e|bp|pulse|temp|weight|tab|tablet|cap|capsule|syp|syrup|inj|injection|rest|diet|avoid|continue|stop)\b",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public IReadOnlyList<string> HandwritingCandidates(IReadOnlyList<AvailableInvestigationDto> catalogue)
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var t in catalogue)
        {
            var name = (t.TestName ?? "").Trim();
            if (name.Length == 0) continue;
            if (name.Length <= 30) set.Add(name);
            var plain = Regex.Replace(name, @"\s*\(.*?\)", "").Trim();          // "HbA1c (Glycated Hemoglobin)" -> "HbA1c"
            if (plain.Length is >= 2 and <= 30) set.Add(plain);
            foreach (Match m in Regex.Matches(name, @"\(([^)]+)\)"))            // the abbreviations in brackets: (CBC), (KFT / RFT)
                foreach (var a in m.Groups[1].Value.Split(',', '/'))
                    if (a.Trim().Length is >= 2 and <= 12) set.Add(a.Trim());
            // each distinctive word of a longer name, as doctors write it: "Creatinine" for Serum Creatinine, "Lipid" for Lipid Profile
            foreach (var w in plain.Split(' ', StringSplitOptions.RemoveEmptyEntries))
                if (w.Length >= 4 && w.Any(char.IsLetter) && !GenericWords.Contains(w.ToLowerInvariant()) && !CommonWords.Contains(w.ToLowerInvariant())
                    && !NotATestOnItsOwn.Contains(w.ToLowerInvariant().Trim('(', ')', ',', '.')) && !w.Any(char.IsDigit)) set.Add(w);
        }
        // lab abbreviations whose test is bookable here
        var names = catalogue.Select(t => Norm(t.TestName ?? "")).ToList();
        foreach (var (abbr, words2) in Abbreviations)
        {
            if (abbr.Length < 2 || ModifierOnly.Contains(abbr)) continue;
            var key = words2.Split(' ').FirstOrDefault(w => w.Length >= 3 && !GenericWords.Contains(w));
            if (names.Any(n => n.Contains(abbr) || (key is not null && n.Contains(key))))
                set.Add(abbr.Length <= 5 ? abbr.ToUpperInvariant().Replace("HBA1C", "HbA1c") : char.ToUpperInvariant(abbr[0]) + abbr[1..]);
        }
        return set.ToList();
    }

    public PrescriptionMatchResult Match(string ocrText, IReadOnlyList<AvailableInvestigationDto> catalogue, string catalogueKey, double minScore, double preselectScore,
        IReadOnlyList<HandwrittenLine>? handwriting = null)
    {
        if ((string.IsNullOrWhiteSpace(ocrText) && (handwriting is null || handwriting.Count == 0)) || catalogue.Count == 0)
            return new PrescriptionMatchResult([], []);

        var model = cache.GetOrCreate("rx-match:" + catalogueKey, e =>
        {
            e.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(15);
            e.Size = 1;
            return Build(catalogue);
        })!;
        var engine = model.Ml.Model.CreatePredictionEngine<TextRow, VectorRow>(model.Transformer);   // not thread-safe: one per call

        var best = new Dictionary<string, PrescriptionSuggestion>();
        var unmatched = new List<string>();
        foreach (var line in Lines(ocrText))
        {
            var lineHit = false;
            foreach (var phrase in Phrases(line))
            {
                var candidates = new List<(AvailableInvestigationDto? Test, double Score, string From)>();
                var (test, score) = BestMatch(model, engine, phrase);
                // a match through generic words only ("wine R/E" -> Stool Routine Examination) is not a real match
                if (test is not null && score < 0.99 && !SharesDistinctiveWord(phrase, test.TestName ?? "")) score *= 0.55;
                candidates.Add((test, score, phrase));

                // each abbreviation of the phrase on its own ("T3 T4 TSH"), also when OCR misread it ("LIT KIT")
                var wholeName = test is not null && score >= minScore ? " " + Norm(test.TestName ?? "") + " " : null;
                foreach (var (token, abbr, cost) in AbbreviationsIn(phrase))
                {
                    // already part of the test the whole phrase names ("CBC with ESR" -> not ESR again; "Sputum C/S" -> not Blood C/S)
                    if (wholeName is not null && (wholeName.Contains(" " + abbr + " ") || AbbreviationWords(abbr).All(w => wholeName.Contains(" " + w + " ")))) continue;
                    var (t2, s2) = BestMatch(model, engine, abbr);
                    if (t2 is null) continue;
                    if (!SharesDistinctiveWord(abbr, t2.TestName ?? "")) continue;   // "PFT" is not "Liver Function Test"
                    var adjusted = cost == 0 ? s2 : Math.Min(s2, 0.9) * (1 - 0.3 * cost);
                    candidates.Add((t2, adjusted, cost == 0 ? token : $"{token} (read as {abbr.ToUpperInvariant()})"));
                }

                foreach (var (t, sc, from) in candidates)
                {
                    if (t is null || sc < minScore) continue;
                    lineHit = true;
                    var key = OptionKey(t);
                    if (!best.TryGetValue(key, out var have) || have.Score < sc)
                        best[key] = new PrescriptionSuggestion(key, t.InvestigationId, t.TestCode ?? "", t.TestName ?? "",
                            t.IsPackage ? "Package" : t.IsProfileTest ? "Profile" : "Investigation",
                            t.MRP, Math.Round(sc, 3), sc >= preselectScore, from);
                }
            }
            if (!lineHit && LooksLikeTestLine(line)) unmatched.Add(line);
        }

        // handwritten lines: the handwriting model's reading, with its own confidence
        foreach (var h in handwriting ?? [])
        {
            // High: read clearly (score better than -4.5) and the writing, not the model's taste for the word, made it likely (lift >= 3).
            // Possible: a short abbreviation the writing clearly favours (lift >= 2.3) though read less surely - offered unticked.
            var strong = h.Score >= -4.5 && h.Lift >= 3.0;
            var possible = !strong && h.Score >= -8.0 && h.Lift >= 2.3 && h.Best.Length <= 6;
            var readings = strong ? new List<(string, double)> { (h.Best, Math.Clamp(0.95 + (h.Score + 2.5) * 0.08, 0.62, 0.95)) }
                         : possible ? new List<(string, double)> { (h.Best, 0.5) } : [];
            foreach (var (text, conf) in readings)
            {
                var (t, cos) = BestMatch(model, engine, text);
                if (t is null || cos < 0.45 || !SharesDistinctiveWord(text, t.TestName ?? "")) continue;
                var sc = Math.Min(conf, Math.Max(cos, conf));
                if (sc < minScore) continue;
                var key = OptionKey(t);
                var from = strong ? $"handwriting: {text}" : $"handwriting, unsure: {text}";
                if (!best.TryGetValue(key, out var have) || have.Score < sc)
                    best[key] = new PrescriptionSuggestion(key, t.InvestigationId, t.TestCode ?? "", t.TestName ?? "",
                        t.IsPackage ? "Package" : t.IsProfileTest ? "Profile" : "Investigation", t.MRP, Math.Round(sc, 3), sc >= preselectScore, from);
            }
        }

        var suggestions = best.Values.OrderByDescending(s => s.Score).ThenBy(s => s.TestName).Take(25).ToList();

        // another OCR pass's misreading of a line that was matched ("Unune routine" when "Unine routine" gave Urine) is not "not matched"
        var matchedWords = suggestions.SelectMany(s => Norm(s.MatchedText).Split(' ')).Where(w => w.Length >= 4).Distinct().ToList();
        // and OCR's garbled reading of a line the handwriting model recognised ("Creatiac" when "Creatinine" was read)
        var handStems = suggestions.Where(x => x.MatchedText.StartsWith("handwriting", StringComparison.Ordinal))
            .SelectMany(x => Norm(x.MatchedText.Split(':').Last()).Split(' ')).Where(w => w.Length >= 3).Select(w => w[..3]).Distinct().ToList();
        var stillUnmatched = unmatched.Distinct()
            .Where(l => !Norm(l).Split(' ').Where(w => w.Length >= 4).Any(w => matchedWords.Any(m => OcrDistance(w, m) <= 1.4)))
            .Where(l => !Norm(l).Split(' ').Where(w => w.Length >= 3).Any(w => handStems.Contains(w[..3])))
            .Take(10).ToList();
        return new PrescriptionMatchResult(suggestions, stillUnmatched);
    }

    private static string OptionKey(AvailableInvestigationDto t) => (t.IsPackage ? "P_" : "I_") + t.InvestigationId;

    // ── model ────────────────────────────────────────────────────────────────
    private static Model Build(IReadOnlyList<AvailableInvestigationDto> catalogue)
    {
        var ml = new MLContext(seed: 1);
        var docs = catalogue.Select(t => new TextRow { Text = CatalogueText(t) }).ToList();
        var pipeline = ml.Transforms.Text.FeaturizeText(nameof(VectorRow.Features), new TextFeaturizingEstimator.Options
        {
            CaseMode = TextNormalizingEstimator.CaseMode.Lower,
            KeepDiacritics = false,
            KeepPunctuations = false,
            KeepNumbers = true,
            StopWordsRemoverOptions = new StopWordsRemovingEstimator.Options { Language = TextFeaturizingEstimator.Language.English },
            WordFeatureExtractor = new WordBagEstimator.Options { NgramLength = 2, UseAllLengths = true, Weighting = NgramExtractingEstimator.WeightingCriteria.TfIdf },
            CharFeatureExtractor = new WordBagEstimator.Options { NgramLength = 3, UseAllLengths = false, Weighting = NgramExtractingEstimator.WeightingCriteria.TfIdf },
            Norm = TextFeaturizingEstimator.NormFunction.L2
        }, nameof(TextRow.Text));
        var transformer = pipeline.Fit(ml.Data.LoadFromEnumerable(docs));
        var engine = ml.Model.CreatePredictionEngine<TextRow, VectorRow>(transformer);

        var entries = catalogue.Select((t, i) => new Entry(t, Norm(t.TestCode ?? ""), Unit(engine.Predict(docs[i]).Features))).ToList();
        var codes = new Dictionary<string, AvailableInvestigationDto>();
        foreach (var e in entries.Where(e => e.Code.Length >= 3)) codes.TryAdd(e.Code, e.Test);
        return new Model(ml, transformer, entries, codes);
    }

    /// <summary>Catalogue text: name, code, and the abbreviations whose words the name contains (so "CBC" meets "Complete Blood Count").</summary>
    private static string CatalogueText(AvailableInvestigationDto t)
    {
        var name = Norm(t.TestName ?? "");
        var extra = Abbreviations.Where(a => a.Words.Split(' ').Take(2).All(w => name.Contains(w))).Select(a => a.Abbr);
        return $"{name} {name} {Norm(t.TestCode ?? "")} {string.Join(' ', extra)}";
    }

    private static (AvailableInvestigationDto? Test, double Score) BestMatch(Model model, PredictionEngine<TextRow, VectorRow> engine, string phrase)
    {
        var norm = Norm(phrase);
        // a test code written on the prescription
        foreach (var token in norm.Split(' '))
            if (token.Length >= 3 && model.Codes.TryGetValue(token, out var byCode)) return (byCode, 0.99);

        // the phrase as written, with synonyms put in place (thorax -> chest), and with abbreviations spelt out:
        // spelling out helps "CBC", but dilutes "Sputum for AFB" - so each test gets the best of the three
        var substituted = Substitute(norm);
        var vectors = new[] { norm, substituted, Expand(substituted) }.Distinct()
            .Select(t => Unit(engine.Predict(new TextRow { Text = t }).Features))
            .Where(v => v.Length > 0 && v.Any(x => x != 0)).ToList();
        if (vectors.Count == 0) return (null, 0);
        AvailableInvestigationDto? best = null; double bestScore = 0;
        foreach (var e in model.Entries)
        {
            double dot = 0;
            foreach (var v in vectors)
            {
                double d = 0;
                var n = Math.Min(v.Length, e.Vector.Length);
                for (var i = 0; i < n; i++) d += v[i] * e.Vector[i];
                if (d > dot) dot = d;
            }
            // prefer the single test over a bigger panel on a tie (e.g. "Serum Creatinine" vs a profile containing it)
            if (dot > bestScore + 1e-6 || (Math.Abs(dot - bestScore) <= 1e-6 && best is not null && best.IsPackage && !e.Test.IsPackage))
            { bestScore = dot; best = e.Test; }
        }
        return (best, bestScore);
    }

    // words of test names that do not name a test on their own (body parts, methods, qualifiers, marketing names)
    private static readonly HashSet<string> NotATestOnItsOwn =
    [
        "mean", "post", "rate", "spine", "chest", "brain", "knee", "abdomen", "pelvis", "plain", "contrast", "bilateral", "free", "cells",
        "cell", "stain", "culture", "sensitivity", "microscopy", "appearance", "colour", "reaction", "respiratory", "virus", "covid-19",
        "package", "packages", "special", "summer", "monsoon", "fluid", "body", "lower", "upper", "limb", "venous", "whole", "prandial",
        "fasting", "random", "high", "sensitivity", "lumbar", "cervical", "thyroid", "obstetric", "anomaly", "scan", "wound", "visible",
        "progressive", "non-progressive", "immotile", "normal", "round", "consistency", "mucus", "occult", "trophozoites", "cysts", "crystals",
        "casts", "bacteria", "yeast", "epithelial", "specific", "gravity", "ketone", "bile", "salts", "pigments", "nitrite", "esterase", "pus"
    ];

    private static readonly HashSet<string> KnownWords = new(Abbreviations.SelectMany(a => a.Words.Split(' ').Append(a.Abbr))
        .Concat(["serum", "blood", "urine", "test", "profile", "level", "total", "random", "fasting", "count", "s", "sr"]));

    /// <summary>A word of the lab vocabulary (an abbreviation, a word of one, or a common lab word) - not OCR debris.</summary>
    private static bool IsKnownWord(string w) => KnownWords.Contains(w);

    private static IEnumerable<string> AbbreviationWords(string abbr) =>
        Abbreviations.Where(a => a.Abbr == abbr).SelectMany(a => a.Words.Split(' ')).Where(w => w.Length >= 3 && !GenericWords.Contains(w)).DefaultIfEmpty(abbr);

    private static readonly HashSet<string> GenericWords =
    [
        "routine", "examination", "test", "tests", "serum", "blood", "total", "level", "levels", "with", "and", "of", "for", "the",
        "profile", "panel", "count", "function", "ratio", "type", "random", "plasma", "analysis", "estimation", "screening"
    ];

    /// <summary>
    /// Whether the phrase and the test name share a word that says what the test is - exactly or with an OCR / spelling
    /// slip ("Profle", "Lipia"), including the words an abbreviation stands for - not just generic words like "routine".
    /// </summary>
    private static bool SharesDistinctiveWord(string phrase, string testName)
    {
        static IEnumerable<string> Words(string s) => s.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(w => w.Replace("/", "")).Where(w => w.Length >= 2 && !GenericWords.Contains(w));
        var norm = Substitute(Norm(phrase));   // head -> brain, W/A -> whole abdomen
        var phraseWords = Words(norm).ToList();
        var shortPhrase = phraseWords.Count <= 3 && phraseWords.All(w => w.Length <= 2 || IsKnownWord(w));
        if (!shortPhrase) phraseWords = phraseWords.Where(w => w.Length >= 3).ToList();   // "Na", "K" count only in a short phrase about them
        phraseWords.AddRange(phraseWords.SelectMany(w => Abbreviations.Where(a => a.Abbr == w && (a.Abbr.Length >= 3 || shortPhrase)).SelectMany(a => Words(a.Words))).ToList());
        var nameWords = Words(Norm(testName)).ToHashSet();
        foreach (var pw in phraseWords)
            foreach (var nw in nameWords)
            {
                if (pw == nw) return true;
                if (pw.Length >= 5 && nw.Length >= 5 && OcrDistance(pw, nw) <= 1) return true;
            }
        return false;
    }

    /// <summary>Scales a feature vector to length 1, so the dot product of two vectors is their cosine similarity (0-1).</summary>
    private static float[] Unit(float[] v)
    {
        double len = 0;
        foreach (var x in v) len += x * x;
        if (len <= 0) return v;
        var f = (float)(1 / Math.Sqrt(len));
        var r = new float[v.Length];
        for (var i = 0; i < v.Length; i++) r[i] = v[i] * f;
        return r;
    }

    // ── prescription text ────────────────────────────────────────────────────
    private static string Norm(string s)
    {
        var t = Regex.Replace(Regex.Replace(s.ToLowerInvariant().Replace("&", " and "), @"[^a-z0-9/ ]", " "), @"\s+", " ").Trim();
        // what OCR makes of 1 / l / I in common lab terms: HbAic, HbAlc -> hba1c; T3 / T4 / B12 written with letters
        t = Regex.Replace(t, @"\b[hu][bh]\s?a\s?[1ilt|]\s?[ceo0]\b", "hba1c");
        t = Regex.Replace(t, @"\bb\s?[1il]2\b", "b12");
        return t;
    }

    // Words written for the same thing as the catalogue's word: replaced in place.
    private static readonly (string From, string To)[] Synonyms =
    [
        ("thorax", "chest"), ("head", "brain"), ("w/a", "whole abdomen"), ("wa", "whole abdomen"), ("skiagram", "x ray"), ("skiagraph", "x ray"),
        ("xray", "x ray"), ("xr", "x ray"), ("cxr", "x ray chest pa"), ("ultrasound", "usg"), ("sonography", "usg"), ("ultrasonography", "usg"),
        ("c/s", "culture sensitivity"), ("cs", "culture sensitivity"), ("ls", "lumbar"), ("lumbosacral", "lumbar"), ("mammo", "mammography"),
        ("haemogram", "complete blood count"), ("hemogram", "complete blood count"), ("bsf", "fasting blood sugar"), ("bspp", "post prandial blood sugar")
    ];

    private static string Substitute(string norm)
    {
        var words = norm.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // a 1-2 letter synonym ("cs", "wa", "xr") only in a short phrase about it, not inside a garbled line
        var shortPhrase = words.Length <= 3 && words.All(w => w.Replace("/", "").Length <= 2 || IsKnownWord(w.Replace("/", "")));
        return string.Join(' ', words.Select(w => w.Replace("/", "").Length <= 2 && !shortPhrase ? w : Synonyms.FirstOrDefault(sy => sy.From == w).To ?? w));
    }

    /// <summary>The phrase plus the words of any abbreviation in it.</summary>
    private static string Expand(string norm)
    {
        var words = norm.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // "Na", "K", "Cl" mean sodium ... only when the phrase is about them ("Na K", "S. Na"), not inside a garbled line
        var shortPhrase = words.Length <= 3 && words.All(w => w.Length <= 2 || IsKnownWord(w));
        var extra = words.SelectMany(w => Abbreviations.Where(a => a.Abbr == w.Replace("/", "") && (a.Abbr.Length >= 3 || shortPhrase)).Select(a => a.Words));
        return string.Join(' ', words.Concat(extra));
    }

    private static IEnumerable<string> Lines(string text) =>
        text.Split('\n').Select(l => Regex.Replace(l, @"^\s*(\d+\s*[.)]|[-*•>]+)\s*", "").Trim())
            // a label in front of the tests: "Inv: CBC, LFT", "Adv - USG W/A", "Advice: ..." -> the tests
            .Select(l => Regex.Replace(l, @"^(inv|invs|invest|investigations?|adv|advice|advised|tests?|lab)\s*[:.\-–]\s*", "", RegexOptions.IgnoreCase).Trim())
            .Where(l => l.Count(char.IsLetter) >= 2 && !Noise.IsMatch(l) && !Letterhead.IsMatch(l) && !IsJunk(l));

    /// <summary>OCR debris: mostly 1-2 character fragments ("2 cl ee eae of 0 ..."), or hardly any letters.</summary>
    private static bool IsJunk(string line)
    {
        // "R/E", "C/S", "W/A" are abbreviations, not fragments
        var cleaned = Regex.Replace(line, @"\b([A-Za-z])\s*/\s*([A-Za-z])\b", "$1$2");
        var tokens = Regex.Matches(cleaned, "[A-Za-z0-9]+").Select(m => m.Value).ToList();
        if (tokens.Count == 0) return true;
        var letters = cleaned.Count(char.IsLetter);
        if (letters < cleaned.Count(c => !char.IsWhiteSpace(c)) * 0.5) return true;
        return tokens.Count >= 5 && tokens.Count(t => t.Length <= 2) >= tokens.Count * 0.5;
    }

    /// <summary>A line and its parts: "CBC, LFT + FBS/PPBS" -> the line, "CBC", "LFT", "FBS", "PPBS". "R/E" stays whole.</summary>
    private static IEnumerable<string> Phrases(string line)
    {
        var parts = Regex.Split(line, @"\s*(?:,|;|\+|\band\b|\s&\s|(?<=[A-Za-z0-9]{2}\s*)/(?=\s*[A-Za-z0-9]{2}))\s*", RegexOptions.IgnoreCase)
            .Select(p => p.Trim()).Where(p => p.Count(char.IsLetterOrDigit) >= 2).ToList();
        if (parts.Count > 1) foreach (var p in parts) yield return p;
        else yield return line;
    }

    private static bool LooksLikeTestLine(string line)
    {
        var words = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return words.Length is >= 1 and <= 6 && line.Count(char.IsLetter) >= 3;
    }
}
