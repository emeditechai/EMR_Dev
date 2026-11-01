using System.Diagnostics;
using System.Globalization;
using SkiaSharp;
using UglyToad.PdfPig;

namespace EMR.Api.Services.BillReader;

/// <summary>
/// The words of a bill with their position. A PDF that carries text is read directly (PdfPig, exact); a scanned PDF is
/// rendered page by page (PDFtoImage, 300 dpi) and read with Tesseract OCR, as is a photo (JPG / PNG). Photos are
/// straightened in grey, sharpened and enlarged first, which Tesseract reads far better.
/// Tesseract runs as the "tesseract" program (BillReader:TesseractPath, BillReader:TessdataPath in appsettings).
/// </summary>
public sealed class BillTextSource(IConfiguration config, ILogger<BillTextSource> logger)
{
    private string Tesseract => config["BillReader:TesseractPath"] is { Length: > 0 } p ? p : "tesseract";
    private string? Tessdata => config["BillReader:TessdataPath"] is { Length: > 0 } p ? p : null;

    public async Task<BillText> ReadAsync(byte[] file, string fileName, CancellationToken ct)
    {
        var ext = Path.GetExtension(fileName).ToLowerInvariant();
        var isPdf = ext == ".pdf" || (file.Length > 4 && file[0] == '%' && file[1] == 'P' && file[2] == 'D' && file[3] == 'F');
        if (isPdf)
        {
            var text = ReadPdfText(file);
            // a PDF with real text: enough words with letters in them
            if (text.Words.Count(w => w.Text.Any(char.IsLetter)) >= 15) return text;
            var ocr = new BillText { Source = "OCR" };
            ocr.Notes.Add("The PDF has no text layer (a scan): it was read with OCR.");
            var page = 0;
            foreach (var bmp in PDFtoImage.Conversion.ToImages(file, options: new PDFtoImage.RenderOptions(Dpi: 300)))
            {
                using (bmp) await OcrAsync(bmp, page++, ocr, ct);
                if (page >= 6) { ocr.Notes.Add("Only the first 6 pages were read."); break; }
            }
            ocr.Pages = page;
            return ocr;
        }
        using var image = SKBitmap.Decode(file) ?? throw new InvalidOperationException("The file is not a PDF or a picture (JPG / PNG) that can be read.");
        var res = new BillText { Source = "OCR", Pages = 1 };
        await OcrAsync(image, 0, res, ct);
        return res;
    }

    private static BillText ReadPdfText(byte[] file)
    {
        var res = new BillText { Source = "PDF_TEXT" };
        using var pdf = PdfDocument.Open(file);
        var offset = 0.0;
        foreach (var page in pdf.GetPages())
        {
            var h = page.Height;
            foreach (var w in page.GetWords())
            {
                if (string.IsNullOrWhiteSpace(w.Text)) continue;
                var b = w.BoundingBox;
                // PDF y grows upwards; pages are stacked one under the other
                res.Words.Add(new BillWord(w.Text.Trim(), b.Left, offset + (h - b.Top), b.Right, offset + (h - b.Bottom), page.Number - 1));
            }
            offset += h + 20;
            res.Pages++;
        }
        return res;
    }

    private async Task OcrAsync(SKBitmap source, int page, BillText into, CancellationToken ct)
    {
        using var prepared = Prepare(source);
        var tmp = Path.Combine(Path.GetTempPath(), "emr-bill-" + Guid.NewGuid().ToString("N") + ".png");
        try
        {
            using (var fs = File.Create(tmp)) prepared.Encode(fs, SKEncodedImageFormat.Png, 100);
            var offset = into.Words.Count == 0 ? 0 : into.Words.Max(w => w.Y1) + 40;
            var tsv = await RunTesseractAsync(tmp, ct);
            var scale = (double)source.Width / prepared.Width;   // back to the size of the page
            var firstWord = into.Words.Count;
            foreach (var line in tsv.Split('\n').Skip(1))
            {
                var c = line.Split('\t');
                if (c.Length < 12 || c[0] != "5") continue;           // level 5 = word
                var text = c[11].Trim();
                if (text.Length == 0) continue;
                var conf = double.TryParse(c[10], NumberStyles.Float, CultureInfo.InvariantCulture, out var cf) ? cf / 100 : 0;
                if (conf < 0.15 && !text.Any(char.IsLetterOrDigit)) continue;
                double L = int.Parse(c[6]), T = int.Parse(c[7]), W = int.Parse(c[8]), H = int.Parse(c[9]);
                into.Words.Add(new BillWord(text, L * scale, offset + T * scale, (L + W) * scale, offset + (T + H) * scale, page, Math.Max(0, conf)));
            }
            Deskew(into.Words, firstWord, into);
        }
        finally { try { File.Delete(tmp); } catch { /* temp file */ } }
    }

    /// <summary>
    /// A photo is rarely straight: across a wide bill one printed line drifts up or down by more than a line's height, which
    /// splits product rows. The tilt is measured from neighbouring words on the same line (median slope) and every word's
    /// height is corrected for it.
    /// </summary>
    private static void Deskew(List<BillWord> words, int from, BillText into)
    {
        var page = words.Skip(from).ToList();
        if (page.Count < 30) return;
        var slopes = new List<double>();
        foreach (var w in page)
        {
            var right = page.Where(o => o.X0 > w.X1 && o.X0 - w.X1 < w.H * 8 && Math.Abs(o.Yc - w.Yc) < w.H * 0.8 && Math.Abs(o.H - w.H) < w.H * 0.5)
                            .OrderBy(o => o.X0).FirstOrDefault();
            if (right != null && right.Xc - w.Xc > w.H) slopes.Add((right.Yc - w.Yc) / (right.Xc - w.Xc));
        }
        if (slopes.Count < 15) return;
        slopes.Sort();
        var slope = slopes[slopes.Count / 2];
        if (Math.Abs(slope) < 0.002) return;                 // straight enough (under ~0.1 degree)
        var x0 = page.Min(w => w.X0);
        for (var i = from; i < words.Count; i++)
        {
            var w = words[i]; var dy = slope * (w.Xc - x0);
            words[i] = w with { Y0 = w.Y0 - dy, Y1 = w.Y1 - dy };
        }
        into.Notes.Add($"The photo was tilted by {Math.Atan(slope) * 180 / Math.PI:0.0} degrees; straightened.");
    }

    /// <summary>Grey, enlarged so text is ~30 px high (Tesseract's best), contrast stretched.</summary>
    private static SKBitmap Prepare(SKBitmap src)
    {
        var factor = src.Width < 1800 ? Math.Min(3.0, 2400.0 / src.Width) : 1.0;
        var w = (int)(src.Width * factor); var h = (int)(src.Height * factor);
        var dst = new SKBitmap(w, h, SKColorType.Gray8, SKAlphaType.Opaque);
        using var canvas = new SKCanvas(dst);
        canvas.Clear(SKColors.White);
        using var paint = new SKPaint
        {
            ColorFilter = SKColorFilter.CreateColorMatrix(
            [
                0.299f * 1.35f, 0.587f * 1.35f, 0.114f * 1.35f, 0, -0.12f,
                0.299f * 1.35f, 0.587f * 1.35f, 0.114f * 1.35f, 0, -0.12f,
                0.299f * 1.35f, 0.587f * 1.35f, 0.114f * 1.35f, 0, -0.12f,
                0, 0, 0, 1, 0
            ])
        };
        canvas.DrawImage(SKImage.FromBitmap(src), new SKRect(0, 0, w, h), new SKSamplingOptions(SKCubicResampler.Mitchell), paint);
        return dst;
    }

    private async Task<string> RunTesseractAsync(string image, CancellationToken ct)
    {
        // --psm 6: one uniform block of text, which keeps the columns of a bill on the same line
        var psi = new ProcessStartInfo(Tesseract) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in new[] { image, "stdout", "--psm", "6", "-l", "eng", "-c", "preserve_interword_spaces=1", "tsv" }) psi.ArgumentList.Add(a);
        if (Tessdata != null) psi.Environment["TESSDATA_PREFIX"] = Tessdata;
        Process p;
        try { p = Process.Start(psi) ?? throw new InvalidOperationException("Tesseract did not start."); }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            logger.LogError(ex, "Tesseract OCR is not installed or not found at {Path}", Tesseract);
            throw new InvalidOperationException("OCR (Tesseract) is not installed on the server, so scans and photos cannot be read. Digital PDF bills still work. Install Tesseract or set BillReader:TesseractPath.");
        }
        using (p)
        {
            using var reg = ct.Register(() => { try { p.Kill(true); } catch { /* ended */ } });
            var stdout = p.StandardOutput.ReadToEndAsync(ct);
            var stderr = p.StandardError.ReadToEndAsync(ct);
            await p.WaitForExitAsync(ct);
            if (p.ExitCode != 0) throw new InvalidOperationException("OCR failed: " + (await stderr).Trim());
            return await stdout;
        }
    }
}
