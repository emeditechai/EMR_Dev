using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace EMR.Web.Services.PrescriptionAssist;

public interface IPrescriptionOcrEngine
{
    /// <summary>
    /// Text of the prescription: an image is read with OCR; a PDF gives its own text when it has some (typed / digital
    /// prescriptions), otherwise its pages are rendered and read with OCR. Throws <see cref="PrescriptionOcrUnavailableException"/>
    /// when the OCR engine is needed but not installed.
    /// </summary>
    Task<PrescriptionReading> ReadAsync(Stream document, string fileExtension, IReadOnlyList<string> handwritingCandidates, CancellationToken ct);
}

/// <summary>What was read: the text (OCR, or a typed PDF's own text) and the handwritten lines the handwriting model recognised.</summary>
public sealed record PrescriptionReading(string Text, IReadOnlyList<HandwrittenLine> Handwriting);

public sealed class PrescriptionOcrUnavailableException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// OCR with the Tesseract engine installed on this server (command line), PDF text with PdfPig, PDF pages rendered with
/// PDFium. Files are written to temporary files, read, and deleted at once - never stored and never sent anywhere.
/// An image is read in three page-layout modes at once (column of text / uniform block / sparse text) and the lines
/// are merged: handwriting that one mode misreads is often read right by another.
/// </summary>
public sealed class TesseractOcrEngine(IOptionsMonitor<PrescriptionAssistOptions> options, IHandwritingRecognizer handwriting,
    ILogger<TesseractOcrEngine> logger) : IPrescriptionOcrEngine
{
    private static readonly string[] PageModes = ["4", "6", "11"];
    private const int MaxPdfPages = 3;

    public async Task<PrescriptionReading> ReadAsync(Stream document, string fileExtension, IReadOnlyList<string> handwritingCandidates, CancellationToken ct)
    {
        if (fileExtension.Equals(".pdf", StringComparison.OrdinalIgnoreCase))
            return await ReadPdfAsync(document, handwritingCandidates, ct);

        var tempFile = TempPath(fileExtension);
        try
        {
            await using (var fs = File.Create(tempFile))
                await document.CopyToAsync(fs, ct);
            return await ReadImageFileAsync(tempFile, handwritingCandidates, ct);
        }
        finally { Delete(tempFile); }
    }

    // ── PDF ──────────────────────────────────────────────────────────────────
    private async Task<PrescriptionReading> ReadPdfAsync(Stream pdf, IReadOnlyList<string> handwritingCandidates, CancellationToken ct)
    {
        using var ms = new MemoryStream();
        await pdf.CopyToAsync(ms, ct);
        var bytes = ms.ToArray();

        // 1. a typed / digital prescription carries its own text - exact, no OCR needed
        try
        {
            using var doc = PdfDocument.Open(bytes);
            var sb = new StringBuilder();
            foreach (var page in doc.GetPages().Take(MaxPdfPages))
                sb.AppendLine(ContentOrderTextExtractor.GetText(page));
            var text = sb.ToString();
            if (text.Count(char.IsLetter) >= 25) return new PrescriptionReading(text, []);   // typed: exact text, no handwriting
        }
        catch (Exception ex)
        {
            logger.LogInformation(ex, "Prescription assist: PDF text could not be read, falling back to OCR");
        }

        // 2. a scanned prescription: render the first pages and read them with OCR
        var pages = new List<string>();
        try
        {
            int count;
            using (var s = new MemoryStream(bytes)) count = PDFtoImage.Conversion.GetPageCount(s);
            for (var i = 0; i < Math.Min(count, MaxPdfPages); i++)
            {
                var png = TempPath(".png");
                pages.Add(png);
                // 300 DPI, but never more than ~3000 px on the long side (some scans come as huge pages)
                System.Drawing.SizeF size;
                using (var ps = new MemoryStream(bytes)) size = PDFtoImage.Conversion.GetPageSize(ps, i);
                var longInches = Math.Max(size.Width, size.Height) / 72.0;
                var dpi = (int)Math.Clamp(3000 / Math.Max(longInches, 0.1), 72, 300);
                using var s = new MemoryStream(bytes);
                PDFtoImage.Conversion.SavePng(png, s, i, options: new PDFtoImage.RenderOptions(Dpi: dpi));
            }
        }
        catch (Exception ex) when (ex is not PrescriptionOcrUnavailableException)
        {
            pages.ForEach(Delete);
            throw new InvalidOperationException("The PDF could not be opened. Upload an unprotected PDF, or a photo of the prescription.", ex);
        }

        try
        {
            var texts = new List<string>();
            var lines = new List<HandwrittenLine>();
            for (var i = 0; i < pages.Count; i++)
            {
                // handwriting is read on the first page (where the prescription is); OCR reads every page
                var r = await ReadImageFileAsync(pages[i], i == 0 ? handwritingCandidates : [], ct);
                texts.Add(r.Text); lines.AddRange(r.Handwriting);
            }
            return new PrescriptionReading(string.Join("\n", texts), lines);
        }
        finally { pages.ForEach(Delete); }
    }

    // ── image ────────────────────────────────────────────────────────────────
    private async Task<PrescriptionReading> ReadImageFileAsync(string file, IReadOnlyList<string> handwritingCandidates, CancellationToken ct)
    {
        var o = options.CurrentValue;
        var enhanced = Enhance(file);
        try
        {
            // the sparse-text pass returns word boxes too: words read with confidence are print, left to OCR
            var sparse = RunAsync(o, file, "11", ct, tsv: true);
            var runs = new List<Task<string>> { RunAsync(o, file, "4", ct), RunAsync(o, file, "6", ct) };
            if (enhanced is not null) runs.Add(RunAsync(o, enhanced, "6", ct));
            var (sparseText, printed) = ParseTsv(await sparse);
            var reads = (await Task.WhenAll(runs)).ToList();
            reads.Insert(2, sparseText);
            var text = MergeReads(reads);

            IReadOnlyList<HandwrittenLine> hand = [];
            if (handwritingCandidates.Count > 0 && handwriting.IsAvailable)
            {
                try { hand = await Task.Run(() => handwriting.Read(file, handwritingCandidates, printed, ct), ct); }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    logger.LogWarning(ex, "Prescription assist: handwriting reading failed - OCR text only");
                }
            }
            return new PrescriptionReading(text, hand);
        }
        finally { if (enhanced is not null) Delete(enhanced); }
    }

    /// <summary>Tesseract TSV: the text by lines, and the boxes of words read with high confidence (printed text).</summary>
    private static (string Text, List<SkiaSharp.SKRectI> Printed) ParseTsv(string tsv)
    {
        var lines = new List<(string Key, List<string> Words)>();
        var printed = new List<SkiaSharp.SKRectI>();
        foreach (var row in tsv.Split('\n').Skip(1))
        {
            var c = row.Split('\t');
            if (c.Length < 12 || c[0] != "5") continue;
            var word = c[11].Trim();
            if (word.Length == 0) continue;
            var key = $"{c[2]}.{c[3]}.{c[4]}";
            var line = lines.FirstOrDefault(l => l.Key == key);
            if (line.Key is null) { line = (key, new List<string>()); lines.Add(line); }
            line.Words.Add(word);
            if (double.TryParse(c[10], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var conf)
                && conf >= 80 && word.Count(char.IsLetter) >= 3
                && int.TryParse(c[6], out var l) && int.TryParse(c[7], out var t) && int.TryParse(c[8], out var w) && int.TryParse(c[9], out var h))
                printed.Add(new SkiaSharp.SKRectI(l, t, l + w, t + h));
        }
        return (string.Join("\n", lines.Select(l => string.Join(' ', l.Words))), printed);
    }

    /// <summary>
    /// A cleaned-up copy of a photo for one more OCR pass: turned upright (phone orientation), enlarged so the writing is
    /// about 2000 px wide, grey, with its contrast stretched (faint ink on yellowed paper). Null when it cannot be made.
    /// </summary>
    private string? Enhance(string file)
    {
        try
        {
            using var codec = SkiaSharp.SKCodec.Create(file);
            if (codec is null) return null;
            using var decoded = SkiaSharp.SKBitmap.Decode(codec);
            if (decoded is null) return null;
            using var upright = Orient(decoded, codec.EncodedOrigin);

            var scale = Math.Clamp(2000f / Math.Max(upright.Width, 1), 1f, 3f);
            var w = (int)(upright.Width * scale); var h = (int)(upright.Height * scale);
            var info = new SkiaSharp.SKImageInfo(w, h, SkiaSharp.SKColorType.Gray8);
            using var gray = new SkiaSharp.SKBitmap(info);
            using (var canvas = new SkiaSharp.SKCanvas(gray))
            using (var paint = new SkiaSharp.SKPaint())
            {
                canvas.Clear(SkiaSharp.SKColors.White);
                using var img = SkiaSharp.SKImage.FromBitmap(upright);
                canvas.DrawImage(img, new SkiaSharp.SKRect(0, 0, w, h), new SkiaSharp.SKSamplingOptions(SkiaSharp.SKCubicResampler.Mitchell), paint);
            }

            // contrast stretch between the 2nd and 98th percentile of brightness
            var pixels = gray.GetPixelSpan().ToArray();
            var hist = new int[256];
            foreach (var v in pixels) hist[v]++;
            int Pct(double q) { long acc = 0, target = (long)(pixels.Length * q); for (var i = 0; i < 256; i++) { acc += hist[i]; if (acc >= target) return i; } return 255; }
            int lo = Pct(0.02), hi = Pct(0.98);
            if (hi - lo > 20)
            {
                for (var i = 0; i < pixels.Length; i++) pixels[i] = (byte)Math.Clamp((pixels[i] - lo) * 255 / (hi - lo), 0, 255);
                System.Runtime.InteropServices.Marshal.Copy(pixels, 0, gray.GetPixels(), pixels.Length);
            }

            var outFile = TempPath(".png");
            using var data = gray.Encode(SkiaSharp.SKEncodedImageFormat.Png, 100);
            using (var fs = File.Create(outFile)) data.SaveTo(fs);
            return outFile;
        }
        catch (Exception ex)
        {
            logger.LogInformation(ex, "Prescription assist: image could not be enhanced, reading the original only");
            return null;
        }
    }

    private static SkiaSharp.SKBitmap Orient(SkiaSharp.SKBitmap src, SkiaSharp.SKEncodedOrigin origin)
    {
        var (deg, swap) = origin switch
        {
            SkiaSharp.SKEncodedOrigin.RightTop => (90, true),
            SkiaSharp.SKEncodedOrigin.BottomRight => (180, false),
            SkiaSharp.SKEncodedOrigin.LeftBottom => (270, true),
            _ => (0, false)
        };
        if (deg == 0) return src.Copy();
        var dst = new SkiaSharp.SKBitmap(swap ? src.Height : src.Width, swap ? src.Width : src.Height);
        using var c = new SkiaSharp.SKCanvas(dst);
        c.Translate(dst.Width / 2f, dst.Height / 2f);
        c.RotateDegrees(deg);
        c.Translate(-src.Width / 2f, -src.Height / 2f);
        c.DrawBitmap(src, 0, 0);
        return dst;
    }

    /// <summary>The first read in full, then the lines only the other reads found (compared on letters and digits).</summary>
    private static string MergeReads(IEnumerable<string> reads)
    {
        var seen = new HashSet<string>();
        var lines = new List<string>();
        foreach (var read in reads)
            foreach (var raw in read.Split('\n'))
            {
                var line = raw.TrimEnd();
                var key = Regex.Replace(line.ToLowerInvariant(), "[^a-z0-9]", "");
                if (key.Length == 0 || !seen.Add(key)) continue;
                lines.Add(line);
            }
        return string.Join("\n", lines);
    }

    private static async Task<string> RunAsync(PrescriptionAssistOptions o, string file, string psm, CancellationToken ct, bool tsv = false)
    {
        var psi = new ProcessStartInfo
        {
            FileName = string.IsNullOrWhiteSpace(o.TesseractPath) ? "tesseract" : o.TesseractPath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8
        };
        foreach (var a in new[] { file, "stdout", "-l", string.IsNullOrWhiteSpace(o.Languages) ? "eng" : o.Languages, "--psm", psm, "-c", "preserve_interword_spaces=1" })
            psi.ArgumentList.Add(a);
        if (tsv) psi.ArgumentList.Add("tsv");

        Process proc;
        try
        {
            proc = Process.Start(psi) ?? throw new PrescriptionOcrUnavailableException("The OCR engine could not be started.");
        }
        catch (System.ComponentModel.Win32Exception ex)
        {
            throw new PrescriptionOcrUnavailableException(
                "The OCR engine (Tesseract) is not installed on the server, or PrescriptionAssist:TesseractPath does not point to it.", ex);
        }

        using (proc)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(Math.Max(5, o.TimeoutSeconds)));
            var stdout = proc.StandardOutput.ReadToEndAsync(timeout.Token);
            var stderr = proc.StandardError.ReadToEndAsync(timeout.Token);
            try
            {
                await proc.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                try { proc.Kill(entireProcessTree: true); } catch { /* already gone */ }
                throw new TimeoutException("Reading the prescription took too long. Try a smaller or clearer image.");
            }
            var text = await stdout;
            if (proc.ExitCode != 0)
            {
                var err = await stderr;
                throw new InvalidOperationException("The prescription image could not be read." +
                    (err.Contains("Failed loading language", StringComparison.OrdinalIgnoreCase) ? " OCR language data is missing on the server." : ""));
            }
            return text;
        }
    }

    private static string TempPath(string ext) => Path.Combine(Path.GetTempPath(), $"rx_{Guid.NewGuid():N}{ext}");

    private void Delete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (Exception ex) { logger.LogWarning(ex, "Prescription assist: temporary file could not be deleted"); }
    }
}
