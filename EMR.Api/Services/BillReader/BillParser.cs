using System.Globalization;
using System.Text.RegularExpressions;

namespace EMR.Api.Services.BillReader;

/// <summary>
/// Layout of a pharma distributor bill: words -> rows (by position) -> the item table (its heading row found by the ML heading
/// model, columns by the headings' position) -> one line per product row; header fields (GSTIN, invoice no / date, total,
/// freight) by their labels. Every value is checked for its type (expiry, money, %), and each line by arithmetic
/// (qty x rate - discount = amount, with or without GST); what does not add up gets a lower confidence for the user to check.
/// </summary>
public static class BillParser
{
    private sealed record Phrase(string Text, double X0, double X1, double Y0, double Y1)
    {
        public double Xc => (X0 + X1) / 2;
    }

    private sealed class Line
    {
        public List<BillWord> Words { get; } = [];
        public double Y => Words.Average(w => w.Yc);
        public string Text => string.Join(' ', Words.OrderBy(w => w.X0).Select(w => w.Text));
    }

    private sealed record Column(string Field, double X0, double X1, string Heading)
    {
        public double Xc => (X0 + X1) / 2;
    }

    private static readonly CultureInfo In = CultureInfo.InvariantCulture;
    private static readonly string[] TableEnd = ["GRAND TOTAL", "SUB TOTAL", "SUBTOTAL", "TOTAL", "NET AMOUNT", "NET PAYABLE", "AMOUNT IN WORDS", "RUPEES", "E.&O.E", "E & O E", "TAXABLE VALUE", "LESS", "ROUND OFF", "BANK DETAILS", "TERMS"];
    private static readonly HashSet<string> Numeric = ["MRP", "QTY", "FREE", "RATE", "DISC", "GST", "CGST", "SGST", "IGST", "TAXABLE", "AMOUNT"];

    public static BillReadResult Parse(BillText text)
    {
        var res = new BillReadResult { Source = text.Source, Pages = text.Pages };
        res.Notes.AddRange(text.Notes);
        var words = text.Words.Where(w => w.Text.Length > 0).ToList();
        if (words.Count == 0) { res.Notes.Add("No text could be read from the file."); return res; }
        var lines = Rows(words);

        Header(lines, res);
        Table(lines, res);
        Totals(lines, res);
        return res;
    }

    // ── rows: words whose vertical centres are close, per page ────────────────────────────────────────────
    private static List<Line> Rows(List<BillWord> words)
    {
        var h = Median(words.Select(w => w.H).Where(x => x > 0)) is var m and > 0 ? m : 10;
        var rows = new List<Line>();
        foreach (var w in words.OrderBy(w => w.Page).ThenBy(w => w.Yc).ThenBy(w => w.X0))
        {
            var row = rows.LastOrDefault(r => r.Words[0].Page == w.Page && Math.Abs(r.Y - w.Yc) <= h * 0.55);
            if (row == null) { row = new Line(); rows.Add(row); }
            row.Words.Add(w);
        }
        return rows;
    }

    private static List<Phrase> Phrases(Line line, double gapFactor = 0.9)
    {
        var ws = line.Words.OrderBy(w => w.X0).ToList();
        var res = new List<Phrase>();
        foreach (var w in ws)
        {
            var last = res.LastOrDefault();
            var gap = last == null ? double.MaxValue : w.X0 - last.X1;
            if (last != null && gap < w.H * gapFactor)
                res[^1] = last with { Text = last.Text + " " + w.Text, X1 = w.X1, Y0 = Math.Min(last.Y0, w.Y0), Y1 = Math.Max(last.Y1, w.Y1) };
            else res.Add(new Phrase(w.Text, w.X0, w.X1, w.Y0, w.Y1));
        }
        return res;
    }

    // ── header: GSTIN, supplier, invoice number and date ──────────────────────────────────────────────────
    private static readonly Regex Gstin = new(@"\b([0-3][0-9])([A-Z]{5}[0-9]{4}[A-Z])([1-9A-Z])Z([0-9A-Z])\b", RegexOptions.Compiled);

    private static void Header(List<Line> lines, BillReadResult res)
    {
        var top = lines.Take(Math.Max(12, lines.Count / 2)).ToList();
        // GSTINs: OCR reads O for 0 and I for 1 in the digit places; the first one printed is the seller's
        foreach (var l in top)
        {
            var t = Regex.Replace(l.Text.ToUpperInvariant(), @"\s+", "");
            foreach (Match g in Regex.Matches(t, @"[0-9OIl]{2}[A-Z]{5}[0-9OIl]{4}[A-Z][0-9A-Z]Z[0-9A-Z]"))
            {
                var v = FixGstinDigits(g.Value);
                if (Gstin.IsMatch(v)) { res.SupplierGstin ??= v; break; }
            }
            if (res.SupplierGstin != null) break;
        }

        string? Labelled(Regex label, Regex value)
        {
            for (var i = 0; i < Math.Min(lines.Count, 40); i++)
            {
                var t = lines[i].Text;
                var m = label.Match(t);
                if (!m.Success) continue;
                var after = t[(m.Index + m.Length)..];
                var v = value.Match(after);
                if (v.Success) return v.Value;
                if (i + 1 < lines.Count)                        // the value printed under the label
                {
                    var below = Phrases(lines[i + 1]).OrderBy(p => Math.Abs(p.X0 - lines[i].Words.First(w => t.IndexOf(w.Text, StringComparison.Ordinal) >= m.Index - 1).X0)).FirstOrDefault();
                    if (below != null && value.Match(below.Text) is { Success: true } vb) return vb.Value;
                }
            }
            return null;
        }

        var no = Labelled(new Regex(@"(INVOICE|INV|BILL|TAX\s*INVOICE)\s*(NO|NUMBER|#)\.?\s*[:\-]?\s*", RegexOptions.IgnoreCase), new Regex(@"[A-Z0-9][A-Z0-9/\-]{1,24}", RegexOptions.IgnoreCase));
        if (no != null && no.Any(char.IsDigit)) res.InvoiceNo = BillField<string>.Of(no.ToUpperInvariant().Trim('-', '/'), 0.85);

        var ds = Labelled(new Regex(@"(INVOICE|INV|BILL)?\s*(DATE|DT|DATED)\.?\s*[:\-]?\s*", RegexOptions.IgnoreCase), new Regex(@"\d{1,2}[\-/\. ]([A-Za-z]{3,9}|\d{1,2})[\-/\. ,]*\d{2,4}"));
        if (ParseDate(ds) is DateTime d && d <= DateTime.Today.AddDays(1) && d > DateTime.Today.AddYears(-2)) res.InvoiceDate = BillField<DateTime?>.Of(d, 0.85);
        else
        {
            // no label: the first date near the top
            foreach (var l in top)
                if (ParseDate(Regex.Match(l.Text, @"\b\d{1,2}[\-/\.]([A-Za-z]{3}|\d{1,2})[\-/\.]\d{2,4}\b").Value) is DateTime d2 && d2 <= DateTime.Today.AddDays(1) && d2 > DateTime.Today.AddYears(-2))
                { res.InvoiceDate = BillField<DateTime?>.Of(d2, 0.55); break; }
        }
        res.Notes.Add(res.SupplierGstin == null ? "The supplier's GSTIN was not found on the bill." : "Supplier GSTIN " + res.SupplierGstin);
        // the supplier's name: the largest text in the top lines (used when the GSTIN is not in the Supplier Master)
        var nameLine = lines.Take(8).Where(l => l.Text.Count(char.IsLetter) >= 4 && !Regex.IsMatch(l.Text, "INVOICE|GSTIN|PHONE|DL NO|TAX", RegexOptions.IgnoreCase)
                                                && l.Text.Count(char.IsLetter) > l.Text.Count(char.IsDigit) * 2
                                                && Phrases(l).Count(p => BillHeaderModel.Classify(p.Text) is { Label: not "NONE", P: >= 0.5 }) < 3)
                            .OrderByDescending(l => l.Words.Average(w => w.H)).FirstOrDefault();
        res.SupplierName = nameLine?.Text.Trim();
    }

    private static string FixGstinDigits(string g)
    {
        static char D(char c) => c switch { 'O' => '0', 'I' or 'l' => '1', _ => c };
        var a = g.ToCharArray();
        foreach (var i in new[] { 0, 1, 7, 8, 9, 10 }) a[i] = D(a[i]);
        return new string(a);
    }

    // ── the item table ────────────────────────────────────────────────────────────────────────────────────
    private static void Table(List<Line> lines, BillReadResult res)
    {
        // heading row: the row (or two stacked rows) with the most distinct column fields
        int headIdx = -1; List<Column>? cols = null; var bestScore = 0.0;
        for (var i = 0; i < lines.Count; i++)
        {
            foreach (var span in new[] { 1, 2 })
            {
                if (i + span > lines.Count) continue;
                var merged = new Line();
                for (var k = 0; k < span; k++) merged.Words.AddRange(lines[i + k].Words);
                if (span == 2 && lines[i + 1].Words.Count(w => Regex.IsMatch(w.Text, @"^\d+([.,]\d+)?$")) > 1) continue;
                // the row above a heading row is only part of it when it holds no values (a "Bill No.: AT-55621" row is not)
                if (span == 2 && lines[i].Words.Any(w => w.Text.Count(char.IsDigit) >= 3)) continue;
                var c = Columns(span == 1 ? Phrases(merged) : StackedPhrases(lines[i], lines[i + 1]));
                var fields = c.Select(x => x.Field).Distinct().ToList();
                var score = fields.Count + (fields.Contains("ITEM") ? 1.5 : 0) + (fields.Contains("QTY") ? 1 : 0) + (fields.Contains("AMOUNT") || fields.Contains("RATE") ? 1 : 0);
                if (fields.Count >= 3 && score > bestScore + 0.01) { bestScore = score; headIdx = i + span - 1; cols = c; }
            }
        }
        if (cols == null) { res.Notes.Add("The item table's heading row was not recognised; no lines were read."); return; }
        if (!cols.Any(c => c.Field == "ITEM"))
        {
            // a bill without a heading over the product: everything left of the first known column is the item
            var first = cols.Min(c => c.X0);
            cols.Insert(0, new Column("ITEM", 0, first - 1, "(item)"));
        }
        cols = cols.OrderBy(c => c.Xc).ToList();
        res.Columns = cols.Select(c => $"{c.Field}: {c.Heading}").ToList();

        // column boundaries halfway between neighbouring headings; numbers are right-aligned so they are placed by their right edge
        var bounds = new List<(Column C, double L, double R)>();
        for (var k = 0; k < cols.Count; k++)
        {
            var l = k == 0 ? double.MinValue : (cols[k - 1].X1 + cols[k].X0) / 2;
            var r = k == cols.Count - 1 ? double.MaxValue : (cols[k].X1 + cols[k + 1].X0) / 2;
            bounds.Add((cols[k], l, r));
        }
        Column Place(Phrase p)
        {
            var isNum = Regex.IsMatch(p.Text, @"^[\d.,%/\-+]+$");
            var x = isNum ? p.X1 - 1 : p.X0 + 1;
            var hit = bounds.FirstOrDefault(b => x >= b.L && x < b.R);
            if (isNum)   // a right-aligned number sits under the heading whose right edge it is closest to
            {
                var near = bounds.Where(b => Numeric.Contains(b.C.Field) || b.C.Field is "BATCH" or "EXPIRY" or "HSN" or "PACK")
                                 .OrderBy(b => Math.Min(Math.Abs(b.C.X1 - p.X1), Math.Abs(b.C.Xc - p.Xc))).FirstOrDefault();
                if (near.C != null && Math.Abs(near.C.X1 - p.X1) < (near.C.X1 - near.C.X0) + 40) return near.C;
            }
            return hit.C ?? cols[0];
        }

        var gstFromCols = cols.Any(c => c.Field is "CGST" or "SGST" or "IGST" or "GST");
        var hasIgst = cols.Any(c => c.Field == "IGST");
        BillLine? current = null;
        var row = 0;
        for (var i = headIdx + 1; i < lines.Count; i++)
        {
            var t = lines[i].Text.ToUpperInvariant();
            if (TableEnd.Any(e => Regex.IsMatch(t, @"(^|\s)" + Regex.Escape(e) + @"(\s|:|$)")) && !Regex.IsMatch(t, @"\b\d{2}/\d{2}\b.*\b\d+\.\d{2}\b.*\b\d+\.\d{2}\b")) break;
            var cells = new Dictionary<string, List<string>>();
            foreach (var p in Phrases(lines[i], 0.6))
            {
                var c = Place(p);
                if (!cells.TryGetValue(c.Field, out var lst)) cells[c.Field] = lst = [];
                lst.Add(p.Text);
            }
            string Cell(string f) => cells.TryGetValue(f, out var v) ? string.Join(' ', v).Trim() : "";
            var itemText = Cell("ITEM");
            var numbersInRow = cells.Where(kv => Numeric.Contains(kv.Key)).Sum(kv => kv.Value.Count(v => Num(v) != null));
            if (numbersInRow == 0)
            {
                // a wrapped item name continues on the next row
                if (current != null && itemText.Length > 0 && itemText.Any(char.IsLetter) && current.BillText.Length < 60) current.BillText += " " + itemText;
                continue;
            }
            if (!itemText.Any(char.IsLetter) && Cell("BATCH").Length == 0) continue;   // totals / page carry lines
            current = new BillLine { Row = ++row, BillText = Regex.Replace(itemText, @"^\d{1,3}[\.\)]?\s+", "").Trim() };
            ReadCells(current, Cell, gstFromCols);
            res.Lines.Add(current);
        }
        if (hasIgst && res.Lines.Any(l => l.GstPercent.Value > 0)) res.IsInterState = BillField<bool?>.Of(true, 0.8);
        else if (cols.Any(c => c.Field is "CGST" or "SGST")) res.IsInterState = BillField<bool?>.Of(false, 0.8);
        if (res.Lines.Count == 0) res.Notes.Add("The item table was found but no product rows could be read.");
    }

    private static List<Column> Columns(List<Phrase> phrases)
    {
        var res = new List<Column>();
        foreach (var p in phrases)
        {
            if (p.Text.Length > 32 || Regex.IsMatch(p.Text, @"^\d+([.,]\d+)?$") || p.Text.Count(char.IsDigit) >= 3) continue;
            var (label, prob) = BillHeaderModel.Classify(p.Text);
            // two headings printed close together ("SGST% Net Amt"): split when the words are different fields on their own
            var words = p.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (words.Length > 1)
            {
                var parts = words.Select(w => BillHeaderModel.Classify(w)).ToList();
                var distinct = parts.Where(x => x.Label is not ("NONE" or "SNO") && x.P >= 0.5).Select(x => x.Label).Distinct().Count();
                if (distinct >= 2) { label = "NONE"; prob = 0; }
            }
            if (label == "NONE" || prob < 0.35)
            {
                // a heading glued to its neighbour ("Batch Exp."): try the words one by one
                var parts = p.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length > 1)
                {
                    var w = (p.X1 - p.X0) / p.Text.Length; var x = p.X0;
                    foreach (var part in parts)
                    {
                        var (l2, p2) = BillHeaderModel.Classify(part);
                        if (l2 != "NONE" && p2 >= 0.45 && res.All(r => r.Field != l2)) res.Add(new Column(l2, x, x + part.Length * w, part));
                        x += (part.Length + 1) * w;
                    }
                }
                continue;
            }
            if (label == "SNO") continue;
            // the same field twice (e.g. "Amount" for tax and for line): keep the right-most for AMOUNT, the first otherwise
            var dup = res.FindIndex(r => r.Field == label);
            if (dup >= 0) { if (label is "AMOUNT" or "TAXABLE") res[dup] = new Column(label, p.X0, p.X1, p.Text); continue; }
            res.Add(new Column(label, p.X0, p.X1, p.Text));
        }
        // a lone "GST" / "CGST" heading over a % and an amount column: the % column is the one with the % sign or the smaller values - left as found
        return res;
    }

    private static List<Phrase> StackedPhrases(Line a, Line b)
    {
        var pa = Phrases(a); var pb = Phrases(b);
        var res = new List<Phrase>();
        foreach (var p in pa)
        {
            var under = pb.Where(q => q.X0 < p.X1 && q.X1 > p.X0).ToList();
            res.Add(under.Count == 0 ? p : p with { Text = p.Text + " " + string.Join(' ', under.Select(u => u.Text)), X0 = Math.Min(p.X0, under.Min(u => u.X0)), X1 = Math.Max(p.X1, under.Max(u => u.X1)) });
        }
        res.AddRange(pb.Where(q => !pa.Any(p => q.X0 < p.X1 && q.X1 > p.X0)));
        return res.OrderBy(p => p.X0).ToList();
    }

    private static void ReadCells(BillLine l, Func<string, string> cell, bool gstFromCols)
    {
        // batch: letters and digits, no spaces; OCR of "O" in numbers kept as is (batch numbers mix both)
        var batch = Regex.Match(cell("BATCH").ToUpperInvariant(), @"[A-Z0-9][A-Z0-9\-/]{2,19}").Value;
        if (batch.Length > 0) l.BatchNo = BillField<string>.Of(batch, 0.85);
        var exp = ParseExpiry(cell("EXPIRY"));
        if (exp == null && cell("BATCH").Split(' ').Length > 1) exp = ParseExpiry(cell("BATCH").Split(' ').Last());   // "B123 06/27" in one column
        if (exp != null) l.ExpiryDate = BillField<DateTime?>.Of(exp, exp > DateTime.Today ? 0.9 : 0.5);
        l.Mrp = Money(cell("MRP"));
        // "10+2" in the quantity column is quantity plus free
        var q = cell("QTY");
        var plus = Regex.Match(q, @"^\s*(\d+(?:\.\d+)?)\s*\+\s*(\d+(?:\.\d+)?)");
        if (plus.Success) { l.Qty = BillField<decimal?>.Of(decimal.Parse(plus.Groups[1].Value, In), 0.85); l.FreeQty = BillField<decimal?>.Of(decimal.Parse(plus.Groups[2].Value, In), 0.85); }
        else l.Qty = Quantity(q);
        if (!plus.Success) l.FreeQty = Quantity(cell("FREE")) is { Value: not null } f ? f : BillField<decimal?>.Of(0m, 0.6);
        l.Rate = Money(cell("RATE"));
        l.DiscPercent = Percent(cell("DISC"), 100) is { Value: not null } d ? d : BillField<decimal?>.Of(0m, 0.6);
        // GST %: the GST column, else CGST + SGST, else IGST; a value above 28 in a % column is an amount and is ignored
        var gst = Percent(cell("GST"), 28);
        if (gst.Value == null && gstFromCols)
        {
            var c = Percent(cell("CGST"), 14); var s = Percent(cell("SGST"), 14); var ig = Percent(cell("IGST"), 28);
            if (c.Value != null && s.Value != null) gst = BillField<decimal?>.Of(c.Value + s.Value, 0.85);
            else if (ig.Value != null) gst = ig;
        }
        if (gst.Value is decimal gv && !new[] { 0m, 5m, 12m, 18m, 28m }.Contains(gv)) gst = BillField<decimal?>.Of(Snap(gv), 0.5);
        l.GstPercent = gst;
        l.Amount = Money(cell("AMOUNT")) is { Value: not null } am ? am : Money(cell("TAXABLE"));

        // arithmetic: qty x rate x (1 - disc) = amount before GST or with GST; repair a missing rate or quantity
        decimal? qty = l.Qty.Value, rate = l.Rate.Value, amt = l.Amount.Value;
        decimal disc = l.DiscPercent.Value ?? 0, g = l.GstPercent.Value ?? 0;
        if (rate == null && qty is > 0 && amt is > 0)
        {
            var r1 = amt.Value / qty.Value / (1 - disc / 100);
            var withGst = l.Mrp.Value is decimal mrp && r1 > mrp / (1 + g / 100);
            l.Rate = BillField<decimal?>.Of(Math.Round(withGst ? r1 / (1 + g / 100) : r1, 2), 0.55);
            l.Notes.Add("Rate worked out from the amount.");
        }
        else if (qty == null && rate is > 0 && amt is > 0)
        {
            var q1 = amt.Value / (rate.Value * (1 - disc / 100));
            var q2 = q1 / (1 + g / 100);
            var pick = Math.Abs(q2 - Math.Round(q2)) < Math.Abs(q1 - Math.Round(q1)) ? q2 : q1;
            l.Qty = BillField<decimal?>.Of(Math.Round(pick), 0.5);
            l.Notes.Add("Quantity worked out from the amount.");
        }
        if (l.Qty.Value is > 0 && l.Rate.Value is > 0 && l.Amount.Value is > 0)
        {
            var net = l.Qty.Value.Value * l.Rate.Value.Value * (1 - disc / 100);
            var ok = Near(net, l.Amount.Value.Value) || Near(net * (1 + g / 100), l.Amount.Value.Value);
            if (ok) { l.Qty.Confidence = Math.Max(l.Qty.Confidence, 0.95); l.Rate.Confidence = Math.Max(l.Rate.Confidence, 0.95); l.Amount.Confidence = 0.95; }
            else { l.Qty.Confidence = Math.Min(l.Qty.Confidence, 0.5); l.Rate.Confidence = Math.Min(l.Rate.Confidence, 0.5); l.Notes.Add("Quantity x rate does not match the amount on the bill: check them."); }
        }
        if (l.Mrp.Value is decimal m && l.Rate.Value is decimal rr && rr > m) { l.Mrp.Confidence = Math.Min(l.Mrp.Confidence, 0.5); l.Notes.Add("Rate is above MRP: check them."); }
    }

    private static bool Near(decimal a, decimal b) => Math.Abs(a - b) <= Math.Max(1m, b * 0.02m);
    private static decimal Snap(decimal g) => new[] { 0m, 5m, 12m, 18m, 28m }.OrderBy(x => Math.Abs(x - g)).First();

    // ── totals and freight ────────────────────────────────────────────────────────────────────────────────
    private static void Totals(List<Line> lines, BillReadResult res)
    {
        res.LinesTotal = res.Lines.Count == 0 ? null : res.Lines.Sum(l => l.Amount.Value ?? 0);
        decimal? Last(Regex label, out double conf)
        {
            conf = 0;
            foreach (var l in Enumerable.Reverse(lines))
            {
                if (!label.IsMatch(l.Text)) continue;
                var nums = Regex.Matches(l.Text[label.Match(l.Text).Index..], @"\d[\d,]*\.\d{1,2}|\d[\d,]{2,}").Select(m => Num(m.Value)).Where(v => v is > 0).ToList();
                if (nums.Count > 0) { conf = 0.85; return nums.Last(); }
            }
            return null;
        }
        var total = Last(new Regex(@"GRAND\s*TOTAL|NET\s*(AMOUNT|AMT|PAYABLE|BILL)|BILL\s*AMOUNT|INVOICE\s*(TOTAL|VALUE|AMOUNT)|TOTAL\s*AMOUNT|AMOUNT\s*PAYABLE", RegexOptions.IgnoreCase), out var tc);
        if (total != null) res.InvoiceAmount = BillField<decimal?>.Of(total, tc);
        var freight = Last(new Regex(@"FREIGHT|CARTAGE|TRANSPORT|OTHER\s*CHARGES|PACKING\s*CHARGES", RegexOptions.IgnoreCase), out var fc);
        res.OtherCharges = BillField<decimal?>.Of(freight ?? 0, freight == null ? 0.6 : fc);
    }

    // ── value parsing ─────────────────────────────────────────────────────────────────────────────────────
    public static decimal? Num(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        s = s.Trim().Replace("₹", "").Replace("Rs.", "").Replace("Rs", "").Replace(",", "").TrimEnd('%', '/', '-').Replace('O', '0').Replace('o', '0');
        return decimal.TryParse(s, NumberStyles.Number, In, out var v) ? v : null;
    }

    private static BillField<decimal?> Money(string s)
    {
        var m = Regex.Matches(s, @"\d[\d,]*(\.\d{1,4})?").Select(x => Num(x.Value)).Where(v => v != null).ToList();
        return m.Count == 0 ? new() : BillField<decimal?>.Of(m.Last(), Regex.IsMatch(s, @"\.\d{2}\b") ? 0.85 : 0.7);
    }

    private static BillField<decimal?> Quantity(string s)
    {
        var m = Regex.Match(s, @"\d+(\.\d+)?");
        return m.Success ? BillField<decimal?>.Of(decimal.Parse(m.Value, In), 0.8) : new();
    }

    private static BillField<decimal?> Percent(string s, decimal max)
    {
        var m = Regex.Matches(s, @"\d+(\.\d+)?").Select(x => Num(x.Value)).Where(v => v != null && v <= max).ToList();
        return m.Count == 0 ? new() : BillField<decimal?>.Of(m.First(), s.Contains('%') ? 0.9 : 0.8);
    }

    private static readonly string[] Months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];

    /// <summary>06/27, 6/27, 06-2027, JUN-27, JUN 2027, 0627, 30/06/2027 -> the first of that month.</summary>
    public static DateTime? ParseExpiry(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        s = s.Trim().ToUpperInvariant().Replace('O', '0');
        Match m;
        if ((m = Regex.Match(s, @"\b(\d{1,2})[/\-\.](\d{1,2})[/\-\.](\d{2,4})\b")).Success) return Ym(m.Groups[3].Value, m.Groups[2].Value);
        if ((m = Regex.Match(s, @"\b(\d{1,2})[/\-\.](\d{2}|\d{4})\b")).Success) return Ym(m.Groups[2].Value, m.Groups[1].Value);
        if ((m = Regex.Match(s.Replace('0', 'O'), @"\b([A-Z]{3})[A-Z]*[\s\-/\.']*(\d{2}|\d{4})\b")).Success && Array.IndexOf(Months, m.Groups[1].Value) is var mi and >= 0)
            return Ym(m.Groups[2].Value, (mi + 1).ToString());
        if ((m = Regex.Match(s, @"^(\d{2})(\d{2})$")).Success) return Ym(m.Groups[2].Value, m.Groups[1].Value);
        return null;
    }

    private static DateTime? Ym(string y, string mo)
    {
        if (!int.TryParse(y, out var yy) || !int.TryParse(mo, out var mm) || mm is < 1 or > 12) return null;
        if (yy < 100) yy += 2000;
        return yy is < 2000 or > 2099 ? null : new DateTime(yy, mm, 1);
    }

    public static DateTime? ParseDate(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        s = Regex.Replace(s.Trim(), @"[\.\s,]+", "-").Replace('/', '-');
        foreach (var f in new[] { "d-M-yyyy", "d-M-yy", "d-MMM-yyyy", "d-MMM-yy", "d-MMMM-yyyy", "dd-MM-yyyy", "dd-MM-yy" })
            if (DateTime.TryParseExact(s, f, In, DateTimeStyles.None, out var d)) return d;
        return null;
    }

    private static double Median(IEnumerable<double> v)
    {
        var a = v.OrderBy(x => x).ToArray();
        return a.Length == 0 ? 0 : a[a.Length / 2];
    }
}
