using System.Text.RegularExpressions;
using EMR.Web.Services.PrescriptionAssist;
using Microsoft.ML;
using Microsoft.ML.Data;

namespace EMR.Web.Services.IdDocumentAssist;

/// <summary>The ID documents the reader recognises; Name is matched to IdentificationTypeMaster.IdentificationTypeName.</summary>
public enum IdDocumentKind { Aadhaar, Pan, VoterId, Passport, DrivingLicence, RationCard, Unknown }

/// <summary>What was found on an uploaded ID document.</summary>
public sealed record IdDocumentReading(
    IdDocumentKind Kind,
    string? Number,
    bool NumberVerified,        // passed the document's own check (Aadhaar Verhoeff, passport MRZ check digit, PAN structure)
    bool NumberMasked,          // masked Aadhaar (XXXX XXXX 1234): the type is known, the full number is not on the document
    double Confidence,          // 0-1
    string Evidence)            // why, in a few words, for the user
{
    /// <summary>The holder's details printed on an Aadhaar card or passport, for checking what was entered on the bill.</summary>
    public IdDocumentPerson? Person { get; init; }
}

/// <summary>Holder details read from the document; any of them may be missing (not printed, or not readable).</summary>
public sealed record IdDocumentPerson(
    string? FullName, string? FirstName, string? MiddleName, string? LastName,
    string? DateOfBirth,        // yyyy-MM-dd when the full date is printed
    int? YearOfBirth,           // when only the year is printed (older Aadhaar)
    string? Gender,             // Male / Female / Transgender
    string? Address,
    string Source,
    string NameText);           // the document's letters (A-Z only), for checking an entered name is printed on it             // "MRZ" for a passport's machine-readable zone, else "OCR" / "PDF text"

public interface IIdDocumentReader
{
    /// <summary>Reads the document with OCR on this server (the file is never stored or sent anywhere), works out its
    /// type with the ML.NET classifier and the number with each document's own pattern and check digit.</summary>
    Task<IdDocumentReading> ReadAsync(Stream document, string fileExtension, CancellationToken ct);

    /// <summary>The same decision on text already read (used by the reader, and testable without OCR).</summary>
    IdDocumentReading Analyse(string text);
}

/// <summary>
/// ID document assist: Tesseract OCR (the Prescription Assist engine), an ML.NET multiclass text classifier for the
/// document type, and rule-based number extraction with validation. The classifier is trained once, in memory, on
/// the wording printed on each Indian ID document; it gives the type when no valid number decides it, and confirms
/// it when one does. A number is only filled when it has the document's exact format (and check digit where the
/// document has one).
/// </summary>
public sealed class IdDocumentReader(IPrescriptionOcrEngine ocr, ILogger<IdDocumentReader> logger) : IIdDocumentReader
{
    // ── ML.NET document-type classifier ─────────────────────────────────────────────────────────────
    private sealed class DocText { public string Label { get; set; } = ""; public string Text { get; set; } = ""; }
    private sealed class DocPrediction
    {
        [ColumnName("PredictedLabel")] public string Label { get; set; } = "";
        public float[] Score { get; set; } = [];
    }

    private static readonly Lazy<(PredictionEngine<DocText, DocPrediction> Engine, string[] Labels, object Gate)> Classifier = new(Train, true);

    /// <summary>Training text: the words printed on each document, in the variants OCR typically returns.</summary>
    private static readonly Dictionary<IdDocumentKind, string[]> Corpus = new()
    {
        [IdDocumentKind.Aadhaar] =
        [
            "government of india aadhaar unique identification authority of india",
            "aadhaar mera aadhaar meri pehchaan dob male female",
            "unique identification authority of india uidai address enrolment no",
            "your aadhaar no vid help uidai gov in www uidai gov in 1947",
            "aadhaar is proof of identity not of citizenship verify identity using secure qr code",
            "bharat sarkar aadhaar year of birth gender",
            "e aadhaar download date issue date aadhaar number",
            "aadhar card government of india dob father",
            "unique identification authority aadhaar letter to"
        ],
        [IdDocumentKind.Pan] =
        [
            "income tax department govt of india permanent account number card",
            "permanent account number name father's name date of birth signature",
            "income tax department pan card govt of india",
            "e permanent account number card nsdl utiitsl",
            "income tax department permanent account number signature",
            "aaykar vibhag bharat sarkar permanent account number"
        ],
        [IdDocumentKind.VoterId] =
        [
            "election commission of india elector photo identity card",
            "elector's name father's name sex date of birth epic",
            "election commission of india identity card electoral registration officer",
            "voter id card elector photo identity card assembly constituency",
            "electoral registration officer part no assembly constituency"
        ],
        [IdDocumentKind.Passport] =
        [
            "republic of india passport type country code nationality indian",
            "passport no surname given names date of birth place of birth date of issue date of expiry",
            "p<ind mrz passport republic of india",
            "place of issue passport nationality indian file no",
            "name of father legal guardian name of mother name of spouse old passport no"
        ],
        [IdDocumentKind.DrivingLicence] =
        [
            "driving licence union of india transport department",
            "driving license dl no date of issue validity non transport cov",
            "indian union driving licence issued by government of",
            "form 7 rule 16 driving licence licensing authority",
            "dl no valid till class of vehicle lmv mcwg blood group",
            "transport department driving licence holder's signature"
        ],
        [IdDocumentKind.RationCard] =
        [
            "ration card food and civil supplies department",
            "ration card no head of family members fair price shop",
            "department of food supplies and consumer affairs ration card",
            "national food security act ration card aay phh bpl apl",
            "digital ration card family members card type",
            "head of the family dealer name dealer address fps fair price shop",
            "name of father husband head of the family age as on dealer name",
            "signature of issuing officer ration card food supplies",
            "rkshy aay phh sphh rksy ration card number card category",
            "khadya sathi food and supplies department government of west bengal"
        ],
        [IdDocumentKind.Unknown] =
        [
            "invoice bill amount total gst",
            "prescription rx tablet capsule doctor",
            "laboratory report test result reference range",
            "certificate this is to certify",
            "receipt payment received thank you",
            "bank statement account number ifsc branch"
        ]
    };

    private static (PredictionEngine<DocText, DocPrediction>, string[], object) Train()
    {
        var ml = new MLContext(seed: 7);
        var rows = Corpus.SelectMany(kv => kv.Value.Select(t => new DocText { Label = kv.Key.ToString(), Text = t })).ToList();
        var data = ml.Data.LoadFromEnumerable(rows);
        var pipeline = ml.Transforms.Conversion.MapValueToKey("LabelKey", nameof(DocText.Label))
            .Append(ml.Transforms.Text.FeaturizeText("Features", new Microsoft.ML.Transforms.Text.TextFeaturizingEstimator.Options
            {
                CaseMode = Microsoft.ML.Transforms.Text.TextNormalizingEstimator.CaseMode.Lower,
                KeepPunctuations = false,
                KeepDiacritics = false,
                WordFeatureExtractor = new Microsoft.ML.Transforms.Text.WordBagEstimator.Options { NgramLength = 2, UseAllLengths = true },
                // character n-grams survive OCR misspellings ("aadhaer", "lncome tax")
                CharFeatureExtractor = new Microsoft.ML.Transforms.Text.WordBagEstimator.Options { NgramLength = 4, UseAllLengths = false }
            }, nameof(DocText.Text)))
            .Append(ml.MulticlassClassification.Trainers.SdcaMaximumEntropy("LabelKey", "Features"))
            .Append(ml.Transforms.Conversion.MapKeyToValue("PredictedLabel"));
        var model = pipeline.Fit(data);

        // the order of Score follows the label key values
        VBuffer<ReadOnlyMemory<char>> keys = default;
        model.GetOutputSchema(data.Schema)["Score"].GetSlotNames(ref keys);
        var labels = keys.DenseValues().Select(k => k.ToString()).ToArray();
        return (ml.Model.CreatePredictionEngine<DocText, DocPrediction>(model), labels, new object());
    }

    private static Dictionary<IdDocumentKind, double> Classify(string text)
    {
        var (engine, labels, gate) = Classifier.Value;
        DocPrediction p;
        lock (gate) p = engine.Predict(new DocText { Text = text });   // PredictionEngine is not thread-safe
        var result = new Dictionary<IdDocumentKind, double>();
        for (var i = 0; i < labels.Length && i < p.Score.Length; i++)
            if (Enum.TryParse<IdDocumentKind>(labels[i], out var k)) result[k] = p.Score[i];
        return result;
    }

    // ── reading ─────────────────────────────────────────────────────────────────────────────────────
    public async Task<IdDocumentReading> ReadAsync(Stream document, string fileExtension, CancellationToken ct)
    {
        IdDocumentReading result;
        if (fileExtension.Equals(".pdf", StringComparison.OrdinalIgnoreCase))
        {
            using var ms = new MemoryStream();
            await document.CopyToAsync(ms, ct);
            result = Analyse(await ReadPdfAsync(ms.ToArray(), ct));
        }
        else
        {
            var reading = await ocr.ReadAsync(document, fileExtension, [], ct);
            result = Analyse(reading.Text);
        }
        logger.LogInformation("ID document assist: {Kind} (confidence {Confidence:0.00}, number {HasNumber})",
            result.Kind, result.Confidence, result.Number is null ? "not found" : result.NumberVerified ? "verified" : "found");
        return result;
    }

    private const int MaxPdfPages = 2;

    /// <summary>
    /// A PDF of an ID is usually a scan of the card(s) pasted on an A4 page: the card is a small picture on a white sheet,
    /// and OCR of the whole page skips it ("too few characters"). So: the PDF's own text when it has some (e-PAN, e-Aadhaar),
    /// then every picture on the page cut out of a white-background render, enlarged and read on its own, then the
    /// whole page as a last resort.
    /// </summary>
    private async Task<string> ReadPdfAsync(byte[] bytes, CancellationToken ct)
    {
        var texts = new List<string>();
        var regions = new List<(int Page, double Left, double Top, double Width, double Height, double PageW, double PageH)>();
        try
        {
            using var doc = UglyToad.PdfPig.PdfDocument.Open(bytes);
            foreach (var page in doc.GetPages().Take(MaxPdfPages))
            {
                var t = UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor.ContentOrderTextExtractor.GetText(page);
                if (t.Count(char.IsLetter) >= 25) texts.Add(t);
                foreach (var img in page.GetImages())
                {
                    var b = img.Bounds;
                    if (b.Width < 90 || b.Height < 45) continue;            // signatures, logos
                    regions.Add((page.Number - 1, b.Left, page.Height - b.Top, b.Width, b.Height, page.Width, page.Height));
                }
            }
        }
        catch (Exception ex)
        {
            logger.LogInformation(ex, "ID document assist: PDF structure could not be read, rendering the pages instead");
        }

        // a digital ID (its own text) is exact: no OCR needed when it already names the document
        if (texts.Count > 0 && Analyse(string.Join("\n", texts)) is { Kind: not IdDocumentKind.Unknown, Confidence: >= 0.8 })
            return string.Join("\n", texts);

        int pages;
        try { using var s = new MemoryStream(bytes); pages = Math.Min(PDFtoImage.Conversion.GetPageCount(s), MaxPdfPages); }
        catch (Exception ex) { throw new InvalidOperationException("The PDF could not be opened (is it password-protected?).", ex); }

        for (var p = 0; p < pages; p++)
        {
            const int dpi = 300;
            SkiaSharp.SKBitmap page;
            using (var s = new MemoryStream(bytes))
                page = PDFtoImage.Conversion.ToImage(s, p, options: new PDFtoImage.RenderOptions(Dpi: dpi, BackgroundColor: SkiaSharp.SKColors.White));
            using (page)
            {
                var onPage = regions.Where(r => r.Page == p).ToList();
                foreach (var r in onPage)
                {
                    var scale = page.Width / r.PageW;
                    var rect = SkiaSharp.SKRectI.Intersect(new SkiaSharp.SKRectI(0, 0, page.Width, page.Height),
                        SkiaSharp.SKRectI.Round(new SkiaSharp.SKRect((float)(r.Left * scale), (float)(r.Top * scale),
                            (float)((r.Left + r.Width) * scale), (float)((r.Top + r.Height) * scale))));
                    if (rect.Width < 50 || rect.Height < 30) continue;
                    texts.Add(await ReadBitmapAsync(page, rect, ct));
                }
                if (onPage.Count == 0 || Analyse(string.Join("\n", texts)) is { Kind: IdDocumentKind.Unknown } or { Confidence: < 0.8 })
                    texts.Add(await ReadBitmapAsync(page, new SkiaSharp.SKRectI(0, 0, page.Width, page.Height), ct));
            }
        }
        return string.Join("\n", texts);
    }

    /// <summary>OCR of one area of a rendered page, enlarged (about 2000 px on its short side), on white.</summary>
    private async Task<string> ReadBitmapAsync(SkiaSharp.SKBitmap page, SkiaSharp.SKRectI area, CancellationToken ct)
    {
        // small print needs ~2000 px across the short side: a tall phone photo of a card is enlarged by its width, not its height
        var scale = Math.Clamp(Math.Max(2400f / Math.Max(area.Width, area.Height), 2000f / Math.Min(area.Width, area.Height)), 1f, 4f);
        if (area.Width * scale > 9000 || area.Height * scale > 9000) scale = 9000f / Math.Max(area.Width, area.Height);
        var w = (int)(area.Width * scale); var h = (int)(area.Height * scale);
        using var bmp = new SkiaSharp.SKBitmap(new SkiaSharp.SKImageInfo(w, h, SkiaSharp.SKColorType.Rgb888x, SkiaSharp.SKAlphaType.Opaque));
        using (var canvas = new SkiaSharp.SKCanvas(bmp))
        using (var img = SkiaSharp.SKImage.FromBitmap(page))
        {
            canvas.Clear(SkiaSharp.SKColors.White);
            canvas.DrawImage(img, new SkiaSharp.SKRect(area.Left, area.Top, area.Right, area.Bottom), new SkiaSharp.SKRect(0, 0, w, h),
                new SkiaSharp.SKSamplingOptions(SkiaSharp.SKCubicResampler.Mitchell));
        }
        using var data = bmp.Encode(SkiaSharp.SKEncodedImageFormat.Png, 100);
        using var ms = new MemoryStream(data.ToArray());
        return (await ocr.ReadAsync(ms, ".png", [], ct)).Text;
    }

    public IdDocumentReading Analyse(string text)
    {
        var r = AnalyseCore(text);
        if (r.Kind is IdDocumentKind.Aadhaar or IdDocumentKind.Passport)
        {
            try { r = r with { Person = ReadPerson(r.Kind, text ?? "") }; }
            catch (Exception ex) { logger.LogInformation(ex, "ID document assist: holder details could not be read"); }
        }
        return r;
    }

    private IdDocumentReading AnalyseCore(string text)
    {
        var upper = (text ?? "").ToUpperInvariant();
        var probs = string.IsNullOrWhiteSpace(upper) ? new Dictionary<IdDocumentKind, double>() : Classify(upper);
        double P(IdDocumentKind k) => probs.GetValueOrDefault(k);

        var candidates = new List<(IdDocumentKind Kind, string? Number, bool Verified, bool Masked, double Strength, string Why)>();

        // any 12-digit number passes the Verhoeff check one time in ten: it decides the type only on a document whose
        // wording is Aadhaar's (a dealer / FPS code on a ration card is not an Aadhaar card)
        if (FindAadhaar(upper) is string aadhaar)
        {
            var aadhaarWording = P(IdDocumentKind.Aadhaar) >= 0.3 || Regex.IsMatch(upper, @"AADHA+R|UIDAI|UNIQUE IDENTIFICATION");
            candidates.Add((IdDocumentKind.Aadhaar, aadhaar, true, false, aadhaarWording ? 1.0 : 0.35, "12-digit Aadhaar number with a valid check digit"));
        }
        else if (HasMaskedAadhaar(upper)) candidates.Add((IdDocumentKind.Aadhaar, null, false, true, 0.6, "masked Aadhaar number (only the last 4 digits are printed)"));

        if (FindPan(upper) is string pan) candidates.Add((IdDocumentKind.Pan, pan, true, false, 0.95, "PAN in the income-tax format (AAAAA9999A)"));

        var (passport, mrz) = FindPassport(upper);
        if (passport is not null) candidates.Add((IdDocumentKind.Passport, passport, mrz, false, mrz ? 1.0 : 0.55, mrz ? "passport number confirmed by the machine-readable zone" : "passport number format"));

        if (FindDrivingLicence(upper) is string dl) candidates.Add((IdDocumentKind.DrivingLicence, dl, true, false, 0.85, "licence number in the state / RTO / year format"));

        if (FindVoterId(upper) is string epic) candidates.Add((IdDocumentKind.VoterId, epic, true, false, 0.6, "EPIC number format (AAA9999999)"));

        if (FindLabelled(upper, @"RATION\s*CARD\s*(?:NO|NUMBER)|CARD\s*NO") is string ration && Regex.IsMatch(upper, "RATION|DEALER|FAIR PRICE|FOOD"))
            candidates.Add((IdDocumentKind.RationCard, ration, false, false, 0.7, "number printed against \"Ration Card No\""));
        else if (Regex.Match(upper, @"(?<![A-Z0-9])((?:RKSY-?I{1,2}|SPHH|PHH|AAY|NPHH)[ \-]?\d{8,12})(?!\d)") is { Success: true } rc)
            candidates.Add((IdDocumentKind.RationCard, Regex.Replace(rc.Groups[1].Value, @"\s+", " "), false, false, 0.7, "ration card number with its card category"));

        // score = the number's strength, plus what the wording of the document says (ML.NET)
        var best = candidates
            .Select(c => (c.Kind, c.Number, c.Verified, c.Masked, c.Why, Score: c.Strength * 0.65 + P(c.Kind) * 0.35))
            .OrderByDescending(c => c.Score)
            .FirstOrDefault();

        // no number decides it: the classifier alone, when it is clear enough
        var (topKind, topP) = probs.Where(kv => kv.Key != IdDocumentKind.Unknown).OrderByDescending(kv => kv.Value)
            .Select(kv => (kv.Key, kv.Value)).FirstOrDefault();

        if (candidates.Count == 0)
        {
            return topP >= 0.45 && P(IdDocumentKind.Unknown) < topP
                ? new IdDocumentReading(topKind, null, false, false, Math.Round(topP * 0.8, 2), "the wording on the document; its number could not be read")
                : new IdDocumentReading(IdDocumentKind.Unknown, null, false, false, 0, "no ID document wording or number was recognised");
        }

        // a number pattern that the document's wording clearly contradicts loses to the wording (e.g. a weak passport-like code on a PAN card)
        if (!best.Verified && topKind != best.Kind && topP >= 0.6)
            return new IdDocumentReading(topKind, null, false, false, Math.Round(topP * 0.8, 2), "the wording on the document; its number could not be read");

        return new IdDocumentReading(best.Kind, best.Number, best.Verified, best.Masked, Math.Round(Math.Min(best.Score, 0.99), 2), best.Why);
    }

    // ── numbers ─────────────────────────────────────────────────────────────────────────────────────
    private static string? FindAadhaar(string t)
    {
        // 12 digits in 4-4-4 groups (not part of a 16-digit VID), first digit 2-9, Verhoeff check digit valid
        foreach (Match m in Regex.Matches(t, @"(?<![\dA-Z])([2-9]\d{3})[ \-]?(\d{4})[ \-]?(\d{4})(?![ \-]?\d)"))
        {
            var digits = m.Groups[1].Value + m.Groups[2].Value + m.Groups[3].Value;
            if (Verhoeff(digits)) return $"{digits[..4]} {digits[4..8]} {digits[8..]}";
        }
        return null;
    }

    private static bool HasMaskedAadhaar(string t) => Regex.IsMatch(t, @"[X\*]{4}[ \-]?[X\*]{4}[ \-]?\d{4}");

    private static string? FindPan(string t)
    {
        foreach (Match m in Regex.Matches(t, @"(?<![A-Z0-9])[A-Z0-9]{5}[A-Z0-9]{4}[A-Z0-9](?![A-Z0-9])"))
        {
            var s = m.Value.ToCharArray();
            for (var i = 0; i < 5; i++) s[i] = ToLetter(s[i]);
            for (var i = 5; i < 9; i++) s[i] = ToDigit(s[i]);
            s[9] = ToLetter(s[9]);
            var pan = new string(s);
            if (Regex.IsMatch(pan, "^[A-Z]{3}[ABCFGHLJPT][A-Z][0-9]{4}[A-Z]$")) return pan;
        }
        return null;
    }

    private static (string? Number, bool FromMrz) FindPassport(string t)
    {
        // MRZ line 2: passport number (9, '<' padded), check digit, nationality
        foreach (Match m in Regex.Matches(t.Replace(" ", ""), @"([A-Z0-9<]{9})(\d)(IND|[A-Z<]{3})\d{6}"))
        {
            var no = m.Groups[1].Value;
            if (MrzCheck(no) == m.Groups[2].Value[0] - '0')
            {
                var clean = no.TrimEnd('<');
                if (Regex.IsMatch(clean, "^[A-Z][0-9]{7}$")) return (clean, true);
            }
        }
        // the printed number of an Indian passport: one letter and seven digits, near "PASSPORT"
        if (t.Contains("PASSPORT"))
        {
            var m2 = Regex.Match(t, @"(?<![A-Z0-9])([A-PR-WY][1-9]\d{6})(?![A-Z0-9])");
            if (m2.Success) return (m2.Groups[1].Value, false);
        }
        return (null, false);
    }

    private static string? FindDrivingLicence(string t)
    {
        // SS-RR YYYY NNNNNNN (state, RTO, year of issue, serial), with the usual separators
        var m = Regex.Match(t, @"(?<![A-Z0-9])([A-Z]{2})[ \-]?(\d{2})[ \-]?((?:19|20)\d{2})[ \-]?(\d{7})(?!\d)");
        return m.Success ? $"{m.Groups[1].Value}{m.Groups[2].Value} {m.Groups[3].Value}{m.Groups[4].Value}" : null;
    }

    private static string? FindVoterId(string t)
    {
        // OCR often splits the letters from the digits ("ABC 1234567")
        foreach (Match m in Regex.Matches(t, @"(?<![A-Z0-9])([A-Z0-9]{3})[ \-]?(\d{7})(?![A-Z0-9])"))
        {
            var s = (m.Groups[1].Value + m.Groups[2].Value).ToCharArray();
            for (var i = 0; i < 3; i++) s[i] = ToLetter(s[i]);
            var epic = new string(s);
            if (Regex.IsMatch(epic, "^[A-Z]{3}[0-9]{7}$")) return epic;
        }
        return null;
    }

    private static string? FindLabelled(string t, string label)
    {
        var m = Regex.Match(t, label + @"\s*[:.\-]?\s*([A-Z0-9][A-Z0-9/\-]{5,19})");
        return m.Success ? m.Groups[1].Value : null;
    }

    private static char ToLetter(char c) => c switch { '0' => 'O', '1' => 'I', '2' => 'Z', '5' => 'S', '8' => 'B', '6' => 'G', _ => c };
    private static char ToDigit(char c) => c switch { 'O' or 'D' or 'Q' => '0', 'I' or 'L' => '1', 'Z' => '2', 'S' => '5', 'B' => '8', 'G' => '6', _ => c };

    // ── holder details (Aadhaar / passport) ─────────────────────────────────────────────────────────
    private static readonly HashSet<string> NameStopWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "GOVERNMENT", "INDIA", "OF", "AADHAAR", "AADHAR", "UNIQUE", "IDENTIFICATION", "AUTHORITY", "DOB", "MALE", "FEMALE",
        "ADDRESS", "ENROLMENT", "ENROLLMENT", "VID", "YEAR", "BIRTH", "DATE", "ISSUE", "DOWNLOAD", "REPUBLIC", "PASSPORT",
        "NATIONALITY", "INDIAN", "SIGNATURE", "HELP", "WWW", "UIDAI", "GOV", "IN", "MERA", "MERI", "PEHCHAAN", "BHARAT", "SARKAR",
        "TRANSGENDER", "FATHER", "HUSBAND", "NO", "NUMBER", "VALID", "PROOF", "IDENTITY", "CITIZENSHIP"
    };

    private static IdDocumentPerson? ReadPerson(IdDocumentKind kind, string text)
    {
        var upper = text.ToUpperInvariant();
        var lines = upper.Split('\n').Select(l => Regex.Replace(l, @"\s+", " ").Trim()).Where(l => l.Length > 0).ToList();

        string? first = null, middle = null, last = null, full = null, dob = null, gender = null, source = "OCR";
        int? yob = null;

        if (kind == IdDocumentKind.Passport && ReadMrz(upper) is { } mrz)
        {
            (first, middle, last, dob, gender) = mrz;
            var joined = string.Join(' ', new[] { first, middle, last }.Where(s => !string.IsNullOrEmpty(s)));
            full = joined.Length > 0 ? joined : null;
            source = "MRZ";
        }

        if (dob is null)
        {
            var m = Regex.Match(upper, @"(?:DOB|D\.O\.B|DATE OF BIRTH|BIRTH)[^0-9\n]{0,20}(\d{2})[/\-.](\d{2})[/\-.]((?:19|20)\d{2})");
            if (m.Success && DateTime.TryParseExact($"{m.Groups[1].Value}/{m.Groups[2].Value}/{m.Groups[3].Value}", "dd/MM/yyyy",
                    System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var d) && d <= DateTime.Today)
                dob = d.ToString("yyyy-MM-dd");
            else
            {
                var y = Regex.Match(upper, @"YEAR OF BIRTH[^0-9\n]{0,12}((?:19|20)\d{2})");
                if (y.Success) yob = int.Parse(y.Groups[1].Value);
            }
        }

        gender ??= Regex.Match(upper, @"\b(FEMALE|MALE|TRANSGENDER)\b") is { Success: true } g
            ? System.Globalization.CultureInfo.InvariantCulture.TextInfo.ToTitleCase(g.Groups[1].Value.ToLowerInvariant()) : null;

        if (full is null && kind == IdDocumentKind.Aadhaar)
        {
            // the English name is printed a few lines above the date / year of birth or the gender (a regional-language
            // name and a "Father:" line can sit in between), and in the letter part right after "To"
            var windows = new List<int>();
            for (var a = 0; a < lines.Count; a++)
            {
                if (Regex.IsMatch(lines[a], @"DOB|D\.O\.B|DATE OF BIRTH|YEAR OF BIRTH|\b(FEMALE|MALE)\b"))
                    for (var i = a - 1; i >= Math.Max(0, a - 5); i--) windows.Add(i);
                if (lines[a] is "TO" or "TO," or "TO:")
                    for (var i = a + 1; i < Math.Min(lines.Count, a + 4); i++) windows.Add(i);
            }
            var found = windows
                .Where(i => !Regex.IsMatch(lines[i], @"^(FATHER|HUSBAND|MOTHER|GUARDIAN|[CSDW]\s*/\s*O|CARE OF)\b"))
                .Where(i => LooksLikeName(lines[i]))
                .Select(i => Clean(lines[i]))
                .ToList();
            // the holder's name is printed several times (letter part, card, OCR passes); stray fragments of the
            // regional-language text are not: pick the candidate printed most often in the whole document
            // (a line counts when every word of the name is on it, one OCR slip allowed in words of 5+ letters)
            var squashed = lines.Select(l => Regex.Replace(l, "[^A-Z]", "")).ToList();
            full = found.Distinct()
                .Select(n => (Name: n, Hits: squashed.Count(l => n.Split(' ').All(w => ApproxContains(l, w)))))
                .OrderByDescending(x => x.Hits).ThenBy(x => found.IndexOf(x.Name))
                .Select(x => x.Name).FirstOrDefault();
            if (full is not null)
            {
                var w = full.Split(' ');
                first = w[0]; last = w.Length > 1 ? w[^1] : null; middle = w.Length > 2 ? string.Join(' ', w[1..^1]) : null;
            }
        }

        var address = ReadAddress(lines) ?? (full is null ? null : ReadLetterAddress(lines, full));

        // every letter of the document, so the page can check an entered name is printed on it even when OCR could not
        // tell which line holds the name (the passport MRZ is included with its '<' fillers removed)
        var nameText = Regex.Replace(upper.Replace('<', ' '), "[^A-Z]", "");
        if (nameText.Length > 6000) nameText = nameText[..6000];

        if (full is null && dob is null && yob is null && gender is null && address is null && nameText.Length < 10) return null;
        string? Title(string? s) => s is null ? null : System.Globalization.CultureInfo.InvariantCulture.TextInfo.ToTitleCase(s.ToLowerInvariant());
        return new IdDocumentPerson(Title(full), Title(first), Title(middle), Title(last), dob, yob, gender, Title(address), source, nameText);
    }

    /// <summary>The word is in the text with at most one edit when it has 5+ letters (approximate substring, Sellers).</summary>
    private static bool ApproxContains(string text, string word)
    {
        if (word.Length == 0) return true;
        var k = word.Length >= 5 ? 1 : 0;
        if (k == 0) return text.Contains(word);
        var prev = new int[word.Length + 1];
        for (var i = 0; i <= word.Length; i++) prev[i] = i;
        foreach (var ch in text)
        {
            var cur = new int[word.Length + 1];
            for (var i = 1; i <= word.Length; i++)
                cur[i] = Math.Min(Math.Min(prev[i] + 1, cur[i - 1] + 1), prev[i - 1] + (word[i - 1] == ch ? 0 : 1));
            if (cur[word.Length] <= k) return true;
            prev = cur;
        }
        return prev[word.Length] <= k;
    }

    private static bool LooksLikeName(string line)
    {
        var raw = line.Replace(" ", "");
        if (raw.Length == 0 || raw.Count(c => c is >= 'A' and <= 'Z' or '.' or '\'') < raw.Length * 0.9) return false;   // OCR noise, digits
        var l = Clean(line);
        if (l.Length < 4 || l.Length > 45 || !Regex.IsMatch(l, @"^[A-Z][A-Z .']+$")) return false;
        var words = l.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length is < 1 or > 5) return false;
        if (words.Any(w => NameStopWords.Contains(w.Trim('.')))) return false;
        // real names: every word has a vowel and at least 3 letters (initials like "K." aside) - OCR fragments such as "NG" do not
        return words.Length >= 2 && l.Count(char.IsLetter) >= 5
            && words.All(w => w.EndsWith('.') && w.Length <= 2 || (w.Trim('.').Length >= 3 && w.IndexOfAny(['A', 'E', 'I', 'O', 'U', 'Y']) >= 0));
    }

    private static string Clean(string s) => Regex.Replace(Regex.Replace(s, @"[^A-Z .']", " "), @"\s+", " ").Trim();

    /// <summary>The text after "Address" up to the line with the 6-digit PIN code (care-of prefix removed).</summary>
    private static string? ReadAddress(List<string> lines)
    {
        var start = lines.FindIndex(l => Regex.IsMatch(l, @"\bADDRESS\b\s*:?"));
        if (start < 0) return null;
        var parts = new List<string>();
        var firstLine = Regex.Replace(lines[start], @"^.*?\bADDRESS\b\s*:?\s*", "");
        if (firstLine.Length > 0) parts.Add(firstLine);
        var done = Regex.IsMatch(firstLine, @"(?<!\d)\d{6}(?!\d)");
        for (var i = start + 1; !done && i < lines.Count && i <= start + 8; i++)
        {
            if (Regex.IsMatch(lines[i], @"^\d{4} \d{4} \d{4}$|UIDAI|WWW\.|HELP@|1947|VID")) break;
            parts.Add(lines[i]);
            if (Regex.IsMatch(lines[i], @"(?<!\d)\d{6}(?!\d)")) break;
        }
        if (!parts.Any(p => Regex.IsMatch(p, @"(?<!\d)\d{6}(?!\d)")) && parts.Count < 2) return null;
        var a = string.Join(", ", parts);
        a = Regex.Replace(a, @"^(?:[CSDW]\s*/\s*O|CARE OF)\s*:?\s*[A-Z .]+?,\s*", "");     // "S/O: Ramen Porel," -> the place itself
        a = Regex.Replace(a, @"[^A-Z0-9 ,./\-]", " ");
        a = Regex.Replace(Regex.Replace(a, @"\s+", " "), @"(\s*,\s*)+", ", ").Trim(' ', ',', '-');
        return a.Length >= 10 ? (a.Length > 300 ? a[..300] : a) : null;
    }

    /// <summary>
    /// The e-Aadhaar / letter part prints the address without an "Address" label: the lines after the holder's name
    /// (care-of line first) down to the line with the PIN code.
    /// </summary>
    private static string? ReadLetterAddress(List<string> lines, string name)
    {
        var key = name.Replace(" ", "");
        var start = lines.FindIndex(l => Regex.Replace(l, "[^A-Z]", "").Contains(key));
        while (start >= 0)
        {
            var parts = new List<string>();
            for (var i = start + 1; i < lines.Count && i <= start + 9; i++)
            {
                if (Regex.IsMatch(lines[i], @"DOB|AADHAAR|ENROL|^\d{4} \d{4} \d{4}")) break;
                // OCR noise at the start of a line (margin marks, rotated side text): "S KACHHARIPARA" -> "KACHHARIPARA"
                var l = Regex.Replace(lines[i], @"^[^A-Z0-9]*(?:[A-Z]{1,2}\s+(?=[A-Z]{3}|\d)|\d\s+(?=[A-Z]))?", "").Trim();
                // the care-of line names a person, not the place
                if (l.Length > 0 && !Regex.IsMatch(l, @"^(?:[CSDW]\s*/\s*O|CARE OF)\b")) parts.Add(l);
                if (Regex.IsMatch(lines[i], @"(?<!\d)\d{6}(?!\d)")) return ReadAddress(["ADDRESS:", .. parts]);
            }
            start = lines.FindIndex(start + 1, l => Regex.Replace(l, "[^A-Z]", "").Contains(key));
        }
        return null;
    }

    /// <summary>Passport MRZ: names from line 1, date of birth and sex from line 2 (with its check digit).</summary>
    private static (string? First, string? Middle, string? Last, string? Dob, string? Gender)? ReadMrz(string upper)
    {
        var flat = upper.Replace(" ", "");
        // line 1 is used for the names only when OCR kept its '<' fillers (no check digit protects it)
        var l1 = Regex.Match(flat, @"P<IND([A-Z]+)<<([A-Z]+(?:<[A-Z]+)*)<{2,}");
        var l2 = Regex.Match(flat, @"[A-Z0-9<]{9}\d[A-Z<]{3}(\d{6})(\d)([MF<])\d{6}");
        if (!l1.Success && !l2.Success) return null;

        string? first = null, middle = null, last = null, dob = null, gender = null;
        if (l1.Success)
        {
            last = l1.Groups[1].Value;
            var g = l1.Groups[2].Value.Split('<', StringSplitOptions.RemoveEmptyEntries);
            first = g.Length > 0 ? g[0] : null;
            middle = g.Length > 1 ? string.Join(' ', g[1..]) : null;
        }
        if (l2.Success && MrzCheck(l2.Groups[1].Value) == l2.Groups[2].Value[0] - '0')
        {
            var s = l2.Groups[1].Value;
            var yy = int.Parse(s[..2]);
            var year = yy > DateTime.Today.Year % 100 ? 1900 + yy : 2000 + yy;
            if (DateTime.TryParseExact($"{year}{s[2..]}", "yyyyMMdd", System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.None, out var d))
                dob = d.ToString("yyyy-MM-dd");
            gender = l2.Groups[3].Value switch { "M" => "Male", "F" => "Female", _ => null };
        }
        return (first, middle, last, dob, gender);
    }

    private static int MrzCheck(string s)
    {
        int[] w = [7, 3, 1];
        var sum = 0;
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            var v = c == '<' ? 0 : char.IsDigit(c) ? c - '0' : c - 'A' + 10;
            sum += v * w[i % 3];
        }
        return sum % 10;
    }

    private static readonly int[,] VD = { { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, { 1, 2, 3, 4, 0, 6, 7, 8, 9, 5 }, { 2, 3, 4, 0, 1, 7, 8, 9, 5, 6 }, { 3, 4, 0, 1, 2, 8, 9, 5, 6, 7 }, { 4, 0, 1, 2, 3, 9, 5, 6, 7, 8 }, { 5, 9, 8, 7, 6, 0, 4, 3, 2, 1 }, { 6, 5, 9, 8, 7, 1, 0, 4, 3, 2 }, { 7, 6, 5, 9, 8, 2, 1, 0, 4, 3 }, { 8, 7, 6, 5, 9, 3, 2, 1, 0, 4 }, { 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 } };
    private static readonly int[,] VP = { { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, { 1, 5, 7, 6, 2, 8, 3, 0, 9, 4 }, { 5, 8, 0, 3, 7, 9, 6, 1, 4, 2 }, { 8, 9, 1, 6, 0, 4, 3, 5, 2, 7 }, { 9, 4, 5, 3, 1, 2, 6, 8, 7, 0 }, { 4, 2, 8, 6, 5, 7, 3, 9, 0, 1 }, { 2, 7, 9, 3, 8, 0, 6, 4, 1, 5 }, { 7, 0, 4, 6, 9, 1, 3, 2, 5, 8 } };

    /// <summary>Verhoeff check (UIDAI's check digit on the Aadhaar number).</summary>
    private static bool Verhoeff(string digits)
    {
        var c = 0;
        for (var i = 0; i < digits.Length; i++)
            c = VD[c, VP[i % 8, digits[digits.Length - 1 - i] - '0']];
        return c == 0;
    }
}
