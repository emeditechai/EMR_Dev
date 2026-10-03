using System.Text.Json;
using Microsoft.Extensions.Options;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using SkiaSharp;

namespace EMR.Web.Services.PrescriptionAssist;

/// <summary>A handwritten line of the prescription and the test name / abbreviation it most likely is.</summary>
/// <summary>
/// A handwritten line of the prescription and the test name / abbreviation it most likely is. Score: average log-likelihood of
/// the name given the line image; Lift: how much the image raised it above the name's likelihood on a blank image (a name the
/// model likes anyway, e.g. an ordinary English word, gets little lift from a scribble).
/// </summary>
public sealed record HandwrittenLine(string Best, double Score, double Lift, double Margin, string? Second, double SecondScore);

public interface IHandwritingRecognizer
{
    bool IsAvailable { get; }

    /// <summary>
    /// The handwritten lines of the image, each matched to the most likely of <paramref name="candidates"/> (the bookable test
    /// names and abbreviations). Areas OCR already read as print (<paramref name="printedAreas"/>) are left out.
    /// </summary>
    IReadOnlyList<HandwrittenLine> Read(string imageFile, IReadOnlyList<string> candidates, IReadOnlyList<SKRectI> printedAreas, CancellationToken ct);
}

/// <summary>
/// Offline handwriting reading with Microsoft TrOCR (small, handwritten) run by ONNX Runtime on this server.
/// 1. Lines: the ink of the photo (local threshold, so uneven light does not matter) is cut into lines, each line into
///    word groups at wide gaps; prescriptions list tests in a left-aligned column, so only groups that start at that
///    column's left edge are read (not the "Rx" sign, margin notes, braces or the page edge).
/// 2. Reading: instead of letting the model spell freely (it was trained on English sentences and turns "BUN" into a word),
///    every bookable test name / abbreviation is scored against the line image - the model says how likely each is - and
///    the best is kept. A model that cannot spell "SGPT" still recognises it among a known list.
/// </summary>
public sealed class HandwritingRecognizer : IHandwritingRecognizer, IDisposable
{
    private const int StartToken = 2, EndToken = 2, PadToken = 1, ImageSize = 384, MaxGroups = 16, Batch = 24, PruneTo = 48;
    private const float WorkWidth = 480f;   // line finding works on the photo scaled to this width

    private readonly IOptionsMonitor<PrescriptionAssistOptions> _options;
    private readonly IWebHostEnvironment _env;
    private readonly ILogger<HandwritingRecognizer> _logger;
    private readonly object _gate = new();
    private InferenceSession? _encoder, _decoder;
    private Dictionary<string, (int Id, double Score)>? _vocab;
    private readonly Dictionary<string, int[]?> _encoded = new();
    private readonly Dictionary<string, double> _prior = new();   // a candidate's likelihood on a blank image: how "easy" it is regardless of the writing
    private float[]? _blankHidden;
    private bool _loadFailed;

    public HandwritingRecognizer(IOptionsMonitor<PrescriptionAssistOptions> options, IWebHostEnvironment env, ILogger<HandwritingRecognizer> logger)
    {
        _options = options; _env = env; _logger = logger;
    }

    public bool IsAvailable => _options.CurrentValue.HandwritingEnabled && EnsureLoaded();

    private string ModelDir => Path.IsPathRooted(_options.CurrentValue.HandwritingModelPath)
        ? _options.CurrentValue.HandwritingModelPath
        : Path.Combine(_env.ContentRootPath, _options.CurrentValue.HandwritingModelPath);

    private bool EnsureLoaded()
    {
        if (_encoder is not null) return true;
        if (_loadFailed) return false;
        lock (_gate)
        {
            if (_encoder is not null) return true;
            if (_loadFailed) return false;
            try
            {
                var dir = ModelDir;
                var enc = Path.Combine(dir, "encoder_model.onnx");
                var dec = Path.Combine(dir, "decoder_model.onnx");
                var tok = Path.Combine(dir, "tokenizer.json");
                if (!File.Exists(enc) || !File.Exists(dec) || !File.Exists(tok))
                {
                    _logger.LogWarning("Prescription assist: handwriting model not found in {Dir} - OCR only. Run Tools/AiModels/download-trocr.", dir);
                    _loadFailed = true;
                    return false;
                }
                var so = new Microsoft.ML.OnnxRuntime.SessionOptions { GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL };
                _vocab = LoadVocab(tok);
                _decoder = new InferenceSession(dec, so);
                _encoder = new InferenceSession(enc, so);
                _logger.LogInformation("Prescription assist: handwriting model loaded from {Dir}", dir);
                return true;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Prescription assist: handwriting model could not be loaded - OCR only");
                _loadFailed = true;
                return false;
            }
        }
    }

    public IReadOnlyList<HandwrittenLine> Read(string imageFile, IReadOnlyList<string> candidates, IReadOnlyList<SKRectI> printedAreas, CancellationToken ct)
    {
        if (!IsAvailable || candidates.Count == 0) return [];
        using var codec = SKCodec.Create(imageFile);
        if (codec is null) return [];
        using var decoded = SKBitmap.Decode(codec);
        if (decoded is null) return [];
        using var photo = Upright(decoded, codec.EncodedOrigin);

        var cands = candidates.Select(c => (Text: c, Ids: Encode(c))).Where(c => c.Ids is { Length: > 0 and <= 24 }).ToList();
        var groups = FindWordGroups(photo, printedAreas);
        var picked = groups.Take(MaxGroups).ToList();
        var lines = new HandwrittenLine?[picked.Count];
        // a time budget: a page full of writing (clinical notes) must not keep the user waiting - what is read in time is used
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(ct);
        budget.CancelAfter(TimeSpan.FromSeconds(8));
        try
        {
        Parallel.For(0, picked.Count, new ParallelOptions { MaxDegreeOfParallelism = 3, CancellationToken = budget.Token }, gi =>
        {
            if (budget.IsCancellationRequested) return;
            var (rect, estChars) = picked[gi];
            var hidden = EncodeImage(photo, rect);
            // the length of what is written: candidates far too short or long are not worth scoring
            var pool = cands.Where(c => c.Text.Length >= estChars / 3.2 && c.Text.Length <= estChars * 3.2 + 2).ToList();
            if (pool.Count == 0) return;
            // pruning: only the candidates whose first piece the model finds plausible for this line are scored in full
            if (pool.Count > PruneTo)
            {
                var first = FirstTokenLogProbs(hidden);
                pool = pool.OrderByDescending(c => first[c.Ids![0]]).Take(PruneTo).ToList();
            }
            var scores = ScoreCandidates(hidden, pool.Select(c => c.Ids!).ToList());
            var priors = Priors(pool);
            var ranked = pool.Select((c, i) => (c.Text, Score: scores[i] - 0.6 * Math.Abs(Math.Log(c.Text.Length / Math.Max(1.0, estChars)))
                                                         - (c.Text.Length > 12 ? 1.0 : 0),   // a long name needs to be read very surely
                                                 Lift: scores[i] - priors[i]))
                             .OrderByDescending(x => x.Score).Take(2).ToList();
            var second = ranked.Count > 1 ? ranked[1] : default;
            _logger.LogDebug("Prescription assist: handwriting line {Rect} ~{Chars:0.0} chars -> {Best} ({Score:0.00}, lift {Lift:0.00}), then {Second} ({SecondScore:0.00}, lift {SecondLift:0.00})",
                rect, estChars, ranked[0].Text, ranked[0].Score, ranked[0].Lift, ranked.Count > 1 ? second.Text : "-", ranked.Count > 1 ? second.Score : 0, ranked.Count > 1 ? second.Lift : 0);
            lines[gi] = new HandwrittenLine(ranked[0].Text, ranked[0].Score, ranked[0].Lift, ranked.Count > 1 ? ranked[0].Score - second.Score : 9,
                                           ranked.Count > 1 ? second.Text : null, ranked.Count > 1 ? second.Score : double.MinValue);
        });
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            _logger.LogInformation("Prescription assist: handwriting time budget reached - {Count} of {Total} line groups read", lines.Count(l => l is not null), picked.Count);
        }
        return lines.Where(l => l is not null).Select(l => l!).ToList();
    }

    /// <summary>Log-probability of every vocabulary piece as the first piece of the line.</summary>
    private float[] FirstTokenLogProbs(float[] hidden)
    {
        var enc = new DenseTensor<float>(hidden, [1, 578, 384]);
        var input = new DenseTensor<long>(new long[] { StartToken }, [1, 1]);
        using var outputs = _decoder!.Run([NamedOnnxValue.CreateFromTensor("input_ids", input), NamedOnnxValue.CreateFromTensor("encoder_hidden_states", enc)], ["logits"]);
        var row = outputs.First().AsEnumerable<float>().ToArray();
        var max = row.Max();
        var lse = max + Math.Log(row.Sum(v => Math.Exp(v - max)));
        for (var i = 0; i < row.Length; i++) row[i] = (float)(row[i] - lse);
        return row;
    }

    // ── lines / word groups ──────────────────────────────────────────────────
    /// <summary>Word groups (in photo pixels) that start at the left edge of the written column, with the number of characters they hold (estimate).</summary>
    private static List<(SKRectI Rect, double EstChars)> FindWordGroups(SKBitmap photo, IReadOnlyList<SKRectI> printedAreas)
    {
        var scale = WorkWidth / photo.Width;
        int W = (int)WorkWidth, H = Math.Max(1, (int)(photo.Height * scale));
        using var work = new SKBitmap(new SKImageInfo(W, H, SKColorType.Gray8));
        using (var canvas = new SKCanvas(work))
        using (var img = SKImage.FromBitmap(photo))
            canvas.DrawImage(img, new SKRect(0, 0, W, H), new SKSamplingOptions(SKCubicResampler.Mitchell));
        var g = work.GetPixelSpan().ToArray();

        // ink: darker than the local mean (window ~1/20 of the page) by 18 grey levels
        var r = Math.Max(15, (Math.Min(W, H) / 20) | 1) / 2;
        var integral = new long[(H + 1) * (W + 1)];
        for (var y = 0; y < H; y++)
        {
            long row = 0;
            for (var x = 0; x < W; x++) { row += g[y * W + x]; integral[(y + 1) * (W + 1) + x + 1] = integral[y * (W + 1) + x + 1] + row; }
        }
        var ink = new bool[W * H];
        for (var y = 0; y < H; y++)
        {
            int y0 = Math.Max(0, y - r), y1 = Math.Min(H, y + r + 1);
            for (var x = 0; x < W; x++)
            {
                int x0 = Math.Max(0, x - r), x1 = Math.Min(W, x + r + 1);
                long sum = integral[y1 * (W + 1) + x1] - integral[y0 * (W + 1) + x1] - integral[y1 * (W + 1) + x0] + integral[y0 * (W + 1) + x0];
                var mean = sum / (double)((y1 - y0) * (x1 - x0));
                ink[y * W + x] = g[y * W + x] < mean - 18;
            }
        }
        // page edges / shadows / margin lines run down most rows: not writing
        for (var x = 0; x < W; x++)
        {
            var c = 0; for (var y = 0; y < H; y++) if (ink[y * W + x]) c++;
            if (c > H * 0.3) for (var y = 0; y < H; y++) ink[y * W + x] = false;
        }
        // printed text OCR has read: leave it to OCR
        foreach (var p in printedAreas)
        {
            int px0 = Math.Max(0, (int)(p.Left * scale)), px1 = Math.Min(W, (int)Math.Ceiling(p.Right * scale));
            int py0 = Math.Max(0, (int)(p.Top * scale)), py1 = Math.Min(H, (int)Math.Ceiling(p.Bottom * scale));
            for (var y = py0; y < py1; y++) for (var x = px0; x < px1; x++) ink[y * W + x] = false;
        }

        // lines: runs of rows with enough ink
        var on = new bool[H];
        for (var y = 0; y < H; y++) { var c = 0; for (var x = 0; x < W; x++) if (ink[y * W + x]) c++; on[y] = c > Math.Max(8, 0.02 * W); }
        var bands = new List<(int T, int B)>();
        for (var i = 0; i < H;)
        {
            if (!on[i]) { i++; continue; }
            var j = i;
            while (j < H && (on[j] || (j + 2 < H && on[j + 2]))) j++;
            if (j - i >= 10 && j - i <= H * 0.12) bands.Add((i, j));
            i = j;
        }
        if (bands.Count == 0) return [];
        var lineH = bands.Select(b => b.B - b.T).OrderBy(h => h).ElementAt(bands.Count / 2);

        // word groups: split a line at gaps wider than ~ one line height
        var groups = new List<(int T, int B, int L, int R)>();
        foreach (var (t, b) in bands)
        {
            var cols = new List<int>();
            for (var x = 0; x < W; x++) { for (var y = t; y < b; y++) if (ink[y * W + x]) { cols.Add(x); break; } }
            if (cols.Count == 0) continue;
            var gap = Math.Max(14, (int)(lineH * 0.9));
            int start = cols[0], prev = cols[0];
            foreach (var c in cols.Skip(1))
            {
                if (c - prev > gap) { groups.Add((t, b, start, prev)); start = c; }
                prev = c;
            }
            groups.Add((t, b, start, prev));
        }
        groups = groups.Where(gr => gr.R - gr.L >= (gr.B - gr.T) * 0.8 && gr.L > W * 0.03 && gr.R < W * 0.97).ToList();
        if (groups.Count == 0) return [];
        // the written column: groups starting near the median left edge of the lines
        var firsts = groups.GroupBy(gr => gr.T).Select(x => x.Min(gr => gr.L)).OrderBy(v => v).ToList();
        var margin = firsts[firsts.Count / 2];
        var kept = groups.Where(gr => Math.Abs(gr.L - margin) <= W * 0.08).ToList();
        // each word of a group as well ("CBC, LFT, Creatinine" -> CBC / LFT / Creatinine; "Lipid Prof" -> Lipid)
        var words = new List<(int T, int B, int L, int R)>();
        foreach (var gr in kept)
        {
            var wgap = Math.Max(6, (int)(lineH * 0.42));
            var cols = new List<int>();
            for (var x = gr.L; x <= gr.R; x++) { for (var y = gr.T; y < gr.B; y++) if (ink[y * W + x]) { cols.Add(x); break; } }
            var parts = new List<(int L, int R)>();
            int st = cols[0], pv = cols[0];
            foreach (var c in cols.Skip(1)) { if (c - pv > wgap) { parts.Add((st, pv)); st = c; } pv = c; }
            parts.Add((st, pv));
            if (parts.Count > 1)
                words.AddRange(parts.Where(pt => pt.R - pt.L >= (gr.B - gr.T) * 0.6).Select(pt => (gr.T, gr.B, pt.L, pt.R)));
        }
        return kept.Concat(words)
            .Select(gr =>
            {
                double est = Math.Max(1.0, (gr.R - gr.L) / (double)Math.Max(1, gr.B - gr.T) * 1.4);
                var rect = new SKRectI((int)((gr.L - 8) / scale), (int)((gr.T - 6) / scale), (int)((gr.R + 8) / scale), (int)((gr.B + 6) / scale));
                rect.Intersect(new SKRectI(0, 0, photo.Width, photo.Height));
                return (rect, est);
            }).ToList();
    }

    // ── model ────────────────────────────────────────────────────────────────
    private float[] EncodeImage(SKBitmap photo, SKRectI rect)
    {
        using var input = new SKBitmap(new SKImageInfo(ImageSize, ImageSize, SKColorType.Rgba8888, SKAlphaType.Premul));
        using (var canvas = new SKCanvas(input))
        using (var img = SKImage.FromBitmap(photo))
        {
            canvas.Clear(SKColors.White);
            canvas.DrawImage(img, new SKRect(rect.Left, rect.Top, rect.Right, rect.Bottom), new SKRect(0, 0, ImageSize, ImageSize),
                new SKSamplingOptions(SKCubicResampler.CatmullRom));
        }
        var px = input.GetPixelSpan();
        var tensor = new DenseTensor<float>([1, 3, ImageSize, ImageSize]);
        for (var y = 0; y < ImageSize; y++)
            for (var x = 0; x < ImageSize; x++)
            {
                var o = (y * ImageSize + x) * 4;
                tensor[0, 0, y, x] = px[o] / 127.5f - 1f;
                tensor[0, 1, y, x] = px[o + 1] / 127.5f - 1f;
                tensor[0, 2, y, x] = px[o + 2] / 127.5f - 1f;
            }
        using var outputs = _encoder!.Run([NamedOnnxValue.CreateFromTensor("pixel_values", tensor)]);
        return outputs.First(o => o.Name == "last_hidden_state").AsEnumerable<float>().ToArray();
    }

    /// <summary>Each candidate's average log-probability on a blank image (cached): its likelihood before any writing is seen.</summary>
    private double[] Priors(List<(string Text, int[]? Ids)> pool)
    {
        lock (_prior)
        {
            if (_blankHidden is null)
            {
                using var blank = new SKBitmap(64, 32);
                blank.Erase(SKColors.White);
                _blankHidden = EncodeImage(blank, new SKRectI(0, 0, 64, 32));
            }
            var missing = pool.Where(c => !_prior.ContainsKey(c.Text)).ToList();
            if (missing.Count > 0)
            {
                var sc = ScoreCandidates(_blankHidden, missing.Select(c => c.Ids!).ToList());
                for (var i = 0; i < missing.Count; i++) _prior[missing[i].Text] = sc[i];
            }
            return pool.Select(c => _prior[c.Text]).ToArray();
        }
    }

    /// <summary>Average log-probability of each candidate's tokens (and the end) given the line image.</summary>
    private double[] ScoreCandidates(float[] hidden, List<int[]> candidates)
    {
        const int seqLen = 578, dim = 384;
        var scores = new double[candidates.Count];
        for (var start = 0; start < candidates.Count; start += Batch)
        {
            var part = candidates.Skip(start).Take(Batch).ToList();
            var n = part.Count;
            var L = part.Max(p => p.Length) + 1;   // start token + tokens; targets = tokens + end
            var ids = new DenseTensor<long>([n, L]);
            for (var k = 0; k < n; k++)
            {
                ids[k, 0] = StartToken;
                for (var t = 1; t < L; t++) ids[k, t] = t - 1 < part[k].Length ? part[k][t - 1] : PadToken;
            }
            var enc = new DenseTensor<float>([n, seqLen, dim]);
            var encSpan = enc.Buffer.Span;
            for (var k = 0; k < n; k++) hidden.AsSpan().CopyTo(encSpan.Slice(k * seqLen * dim, seqLen * dim));

            using var outputs = _decoder!.Run([NamedOnnxValue.CreateFromTensor("input_ids", ids), NamedOnnxValue.CreateFromTensor("encoder_hidden_states", enc)],
                                              ["logits"]);
            var logits = outputs.First().AsTensor<float>();
            var vocab = logits.Dimensions[2];
            var buffer = logits is DenseTensor<float> dense ? dense.Buffer : logits.ToArray().AsMemory();
            var span = buffer.Span;
            for (var k = 0; k < n; k++)
            {
                var targets = part[k].Append(EndToken).ToArray();
                double total = 0;
                for (var t = 0; t < targets.Length; t++)
                {
                    var row = span.Slice((k * L + t) * vocab, vocab);
                    float max = float.MinValue;
                    foreach (var v in row) if (v > max) max = v;
                    double sum = 0;
                    foreach (var v in row) sum += Math.Exp(v - max);
                    total += row[targets[t]] - max - Math.Log(sum);
                }
                scores[start + k] = total / targets.Length;
            }
        }
        return scores;
    }

    // ── tokenizer (sentencepiece unigram, from tokenizer.json) ───────────────
    private static Dictionary<string, (int, double)> LoadVocab(string file)
    {
        using var doc = JsonDocument.Parse(File.ReadAllBytes(file));
        var vocab = doc.RootElement.GetProperty("model").GetProperty("vocab");
        var map = new Dictionary<string, (int, double)>();
        var i = 0;
        foreach (var e in vocab.EnumerateArray())
        {
            var piece = e[0].GetString() ?? "";
            map.TryAdd(piece, (i, e[1].GetDouble()));
            i++;
        }
        return map;
    }

    /// <summary>Best segmentation of the text into vocabulary pieces (Viterbi on piece scores), as sentencepiece does.</summary>
    private int[]? Encode(string text)
    {
        lock (_encoded)
            if (_encoded.TryGetValue(text, out var cached)) return cached;
        var s = "▁" + text.Replace(' ', '▁');
        var n = s.Length;
        var best = new double[n + 1]; var from = new int[n + 1]; var piece = new int[n + 1];
        Array.Fill(best, double.NegativeInfinity); best[0] = 0;
        for (var i = 1; i <= n; i++)
            for (var j = Math.Max(0, i - 16); j < i; j++)
            {
                if (double.IsNegativeInfinity(best[j]) || !_vocab!.TryGetValue(s[j..i], out var v)) continue;
                var sc = best[j] + v.Score;
                if (sc > best[i]) { best[i] = sc; from[i] = j; piece[i] = v.Id; }
            }
        int[]? ids = null;
        if (!double.IsNegativeInfinity(best[n]))
        {
            var list = new List<int>();
            for (var i = n; i > 0; i = from[i]) list.Add(piece[i]);
            list.Reverse();
            ids = list.ToArray();
        }
        lock (_encoded) _encoded[text] = ids;
        return ids;
    }

    private static SKBitmap Upright(SKBitmap src, SKEncodedOrigin origin)
    {
        var (deg, swap) = origin switch
        {
            SKEncodedOrigin.RightTop => (90, true),
            SKEncodedOrigin.BottomRight => (180, false),
            SKEncodedOrigin.LeftBottom => (270, true),
            _ => (0, false)
        };
        if (deg == 0) return src.Copy();
        var dst = new SKBitmap(swap ? src.Height : src.Width, swap ? src.Width : src.Height);
        using var c = new SKCanvas(dst);
        c.Translate(dst.Width / 2f, dst.Height / 2f);
        c.RotateDegrees(deg);
        c.Translate(-src.Width / 2f, -src.Height / 2f);
        c.DrawBitmap(src, 0, 0);
        return dst;
    }

    public void Dispose()
    {
        _encoder?.Dispose();
        _decoder?.Dispose();
    }
}
