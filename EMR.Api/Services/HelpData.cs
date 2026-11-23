using System.Data;
using System.Globalization;
using System.Text.RegularExpressions;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

/// <summary>
/// Ask AI answers from live data (SQLScripts/2321). A fixed set of READ-ONLY questions - a bill, a token, a patient, the
/// collection / bills of a period, dues, lab work - each answered by one procedure, limited to the user's branch and to
/// the data scopes EMR.Web allows from the user's page permissions. No SQL is ever built from the question.
/// What a question asks for is decided by the numbers in it (bill / token / phone / Patient ID) and, without one, by an
/// ML.NET text classifier (<see cref="HelpTextClassifier"/>) trained on example wordings, after typos in the data words
/// are corrected ("colection yesturday" -> "collection yesterday").
/// </summary>
public static partial class HelpData
{
    public const string Help = "HELP", Bill = "BILL", Token = "TOKEN", Patient = "PATIENT", Summary = "SUMMARY", Dues = "DUES", LabWork = "LABWORK";

    // scopes EMR.Web passes (from page permissions)
    public const string ScopeLab = "LAB", ScopeOpd = "OPD", ScopeSamples = "SAMPLES", ScopePatients = "PATIENTS";

    private static readonly Lazy<HelpTextClassifier> Model = new(() => HelpTextClassifier.Train(Examples(), 60));

    // ── recognising the question ─────────────────────────────────────────────────────────────────────────────

    [GeneratedRegex(@"\b(?:LAB|OPD|IPD|B2B|PH|BILL)?\s*/\s*[A-Z]{1,6}\s*\d{6,}\b|\b[A-Z]{2,5}\d{10}\b", RegexOptions.IgnoreCase)]
    private static partial Regex BillNoRegex();
    [GeneratedRegex(@"\b(?:B2B-)?(?:LAB-)?[A-Z]{2,5}-\d{3,5}\b", RegexOptions.IgnoreCase)]
    private static partial Regex TokenRegex();
    [GeneratedRegex(@"\bP[A-Z]{1,5}\d{8,12}\b", RegexOptions.IgnoreCase)]
    private static partial Regex PatientCodeRegex();
    [GeneratedRegex(@"(?<!\d)(?:\+?91[\s-]?)?([6-9]\d{4}[\s-]?\d{5})(?!\d)")]
    private static partial Regex PhoneRegex();
    [GeneratedRegex(@"[a-z]+|\d+")]
    private static partial Regex WordRegex();
    [GeneratedRegex(@"^\s*(how|where|why|can i|steps?|what is the (process|procedure|way)|what should|what do i|guide|help me)\b", RegexOptions.IgnoreCase)]
    private static partial Regex HowToRegex();
    [GeneratedRegex(@"\b(open|show|print|view|display|see|get|find)\b", RegexOptions.IgnoreCase)]
    private static partial Regex OpenVerbRegex();
    [GeneratedRegex(@"^\s*(?:find|search|show|open|lookup|look up|get|details of|who is)?\s*(?:the\s+)?patient(?:s)?\s+(?:named\s+|name\s+|details\s+(?:of|for)\s+|of\s+|for\s+)?(?<name>[a-z][a-z .]{2,40})\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex PatientAskRegex();
    [GeneratedRegex(@"\b(?:patient|name|named|for|of)\s+([a-z][a-z .]{2,40})$", RegexOptions.IgnoreCase)]
    private static partial Regex PatientNameRegex();

    /// <summary>Words of data questions; a misspelt word within edit distance 1-2 is replaced by the nearest one.</summary>
    private static readonly string[] Vocabulary =
    [
        "today", "yesterday", "week", "month", "year", "last", "this", "previous", "days", "daily",
        "collection", "collected", "collect", "revenue", "sale", "sales", "income", "amount", "total", "earning", "business", "cash",
        "due", "dues", "pending", "outstanding", "unpaid", "balance", "receivable",
        "bill", "bills", "billing", "invoice", "receipt", "token", "patient", "patients", "phone", "mobile", "number",
        "sample", "samples", "report", "reports", "approval", "approved", "result", "results", "test", "tests", "investigation",
        "lab", "opd", "consultation", "doctor", "cancelled", "cancel", "count", "many", "much", "list", "show", "open", "status",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"
    ];
    private static readonly HashSet<string> VocabSet = new(Vocabulary, StringComparer.OrdinalIgnoreCase);

    /// <summary>Lower case and data words corrected for typos (transpositions count as one edit).</summary>
    public static string Correct(string question)
    {
        var text = HelpText.Normalize(question);
        return WordRegex().Replace(text, m =>
        {
            var w = m.Value;
            if (w.Length < 4 || char.IsDigit(w[0]) || VocabSet.Contains(w)) return w;
            var max = w.Length >= 7 ? 2 : 1;
            var best = Vocabulary.Where(v => Math.Abs(v.Length - w.Length) <= max)
                                 .Select(v => (v, d: Distance(v, w, max))).Where(x => x.d <= max)
                                 .OrderBy(x => x.d).FirstOrDefault();
            return best.v ?? w;
        });
    }

    public sealed record Understood(string Kind, double P, string? Value, string Modules, DateTime From, DateTime To, string PeriodLabel, bool WantsOpen,
                                    string Target = TargetBill);

    // the screen a bill / token question asks for ("LAB/HO2627000295 open lab reporting entry page")
    public const string TargetBill = "BILL", TargetEntry = "ENTRY", TargetReport = "REPORT", TargetSample = "SAMPLE", TargetBarcode = "BARCODE";

    /// <summary>Which screen of a bill is asked for; the bill itself when none is named.</summary>
    public static string ScreenTarget(string text)
    {
        if (Regex.IsMatch(text, @"\bbarcodes?\b|\bstickers?\b|\blabels?\b")) return TargetBarcode;
        if (Regex.IsMatch(text, @"\b(report(ing)?\s+entry|result(s)?\s+entry|entry\s+(page|screen)|enter\s+(the\s+)?results?|reporting|result(s)?|entry|microbiology|culture|image\s+report(ing)?|radiology)\b")) return TargetEntry;
        if (Regex.IsMatch(text, @"\breports?\b|\bpdf\b|\bdispatch\b")) return TargetReport;
        if (Regex.IsMatch(text, @"\bsamples?\b|\bcollection\b|\bcollect\b|\bphlebotom")) return TargetSample;
        return TargetBill;
    }

    /// <summary>What the question asks for; Kind = HELP when it is a how-to / help question.</summary>
    public static Understood Understand(string question, DateTime today)
    {
        var raw = question.Trim();
        var text = Correct(raw);
        var (from, to, label) = Period(text, today);
        var modules = Modules(text);
        var target = ScreenTarget(text);
        // naming a screen ("... lab reporting entry page") is asking to open it
        var open = OpenVerbRegex().IsMatch(text) || target != TargetBill || Regex.IsMatch(text, @"\b(page|screen)\b");

        // a Patient ID first (PHO2627000035 also looks like a bill number without its prefix; no patient -> tried as a bill)
        if (!raw.Contains('/') && PatientCodeRegex().Match(raw) is { Success: true } pc)
            return new(Patient, 1, pc.Value.ToUpperInvariant(), modules, from, to, label, open);
        if (BillNoRegex().Match(raw) is { Success: true } b && Regex.IsMatch(b.Value, @"\d{6,}"))
            return new(Bill, 1, Regex.Replace(b.Value, @"\s+", ""), modules, from, to, label, open, target);
        if (TokenRegex().Match(raw) is { Success: true } t)
            return new(Token, 1, t.Value.ToUpperInvariant(), modules, from, to, label, open, target);
        if (PhoneRegex().Match(raw) is { Success: true } ph)
            return new(Patient, 1, Regex.Replace(ph.Groups[1].Value, @"[\s-]", ""), modules, from, to, label, open);

        // "find patient anita mitra", "patient named kajal": a name search
        if (PatientAskRegex().Match(raw) is { Success: true } pn && !HowToRegex().IsMatch(text))
            return new(Patient, 1, pn.Groups["name"].Value.Trim(), modules, from, to, label, open);

        // "how do I collect a due" is a help question even though it has data words
        if (HowToRegex().IsMatch(text) && !Regex.IsMatch(text, @"\bhow (much|many)\b")) return new(Help, 1, null, modules, from, to, label, open);

        var (kind, p) = Model.Value.Predict(text, 1).Select(x => (x.Label, x.P)).FirstOrDefault();
        if (kind is null || kind == Help || p < 0.5) return new(Help, p, null, modules, from, to, label, open);
        if (kind is Bill or Token) return new(Help, p, null, modules, from, to, label, open);   // a bill / token question needs its number
        string? name = null;
        if (kind == Patient)
        {
            name = PatientNameRegex().Match(raw) is { Success: true } n ? n.Groups[1].Value.Trim() : null;
            if (name is null) return new(Help, p, null, modules, from, to, label, open);
        }
        return new(kind, p, name, modules, from, to, label, open);
    }

    private static string Modules(string text)
    {
        var lab = Regex.IsMatch(text, @"\b(lab|laboratory|pathology|test|tests|sample|samples|b2c|investigation)\b");
        var opd = Regex.IsMatch(text, @"\b(opd|consultation|doctor|visit|visits|appointment)\b");
        return lab == opd ? "LAB,OPD" : lab ? "LAB" : "OPD";
    }

    private static readonly string[] MonthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];

    /// <summary>The period a question is about; today when it names none.</summary>
    public static (DateTime From, DateTime To, string Label) Period(string text, DateTime today)
    {
        today = today.Date;
        if (Regex.Match(text, @"\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})\b") is { Success: true } d
            && DateTime.TryParseExact($"{d.Groups[1].Value.PadLeft(2, '0')}/{d.Groups[2].Value.PadLeft(2, '0')}/{(d.Groups[3].Value.Length == 2 ? "20" + d.Groups[3].Value : d.Groups[3].Value)}",
                                      "dd/MM/yyyy", CultureInfo.InvariantCulture, DateTimeStyles.None, out var on))
            return (on, on, on.ToString("dd MMM yyyy"));
        if (Regex.Match(text, @"\blast (\d{1,3}) days?\b") is { Success: true } n)
        {
            var k = Math.Clamp(int.Parse(n.Groups[1].Value), 1, 366);
            return (today.AddDays(-(k - 1)), today, $"last {k} days");
        }
        if (Regex.IsMatch(text, @"\byesterday\b")) return (today.AddDays(-1), today.AddDays(-1), "yesterday");
        if (Regex.IsMatch(text, @"\b(last|previous) week\b"))
        {
            var start = today.AddDays(-(((int)today.DayOfWeek + 6) % 7) - 7);
            return (start, start.AddDays(6), "last week");
        }
        if (Regex.IsMatch(text, @"\bthis week\b|\bweekly\b"))
            return (today.AddDays(-(((int)today.DayOfWeek + 6) % 7)), today, "this week");
        if (Regex.IsMatch(text, @"\b(last|previous) month\b"))
        {
            var s = new DateTime(today.Year, today.Month, 1).AddMonths(-1);
            return (s, s.AddMonths(1).AddDays(-1), s.ToString("MMMM yyyy"));
        }
        if (Regex.IsMatch(text, @"\bthis month\b|\bmonthly\b|\bmonth to date\b|\bmtd\b"))
            return (new DateTime(today.Year, today.Month, 1), today, today.ToString("MMMM yyyy"));
        if (Regex.IsMatch(text, @"\bthis year\b|\byearly\b|\bytd\b"))
            return (new DateTime(today.Year, 1, 1), today, today.Year.ToString());
        for (var i = 0; i < 12; i++)
            if (Regex.IsMatch(text, $@"\b(in|of|for|during)?\s*{MonthNames[i]}\b"))
            {
                var y = today.Month >= i + 1 ? today.Year : today.Year - 1;
                var s = new DateTime(y, i + 1, 1);
                var e = s.AddMonths(1).AddDays(-1);
                return (s, e > today ? today : e, s.ToString("MMMM yyyy"));
            }
        return (today, today, "today");
    }

    // ── training sentences for the ML.NET data-intent model ──────────────────────────────────────────────────

    private static IEnumerable<(string, string)> Examples()
    {
        string[] periods = ["today", "yesterday", "this month", "last month", "this week", "last 7 days", ""];
        string[] modules = ["lab", "opd", ""];
        foreach (var p in periods)
            foreach (var m in modules)
            {
                foreach (var s in new[] { $"{m} collection {p}", $"total {m} collection {p}", $"how much collected {p} {m}", $"{m} revenue {p}",
                                          $"{m} sales {p}", $"how many {m} bills {p}", $"{m} business {p}", $"{m} bill count {p}", $"total amount billed {p} {m}",
                                          $"show {m} summary {p}", $"how many patients {p} {m}", $"cash received {p} {m}", $"{m} income {p}" })
                    yield return (s.Trim(), Summary);
                foreach (var s in new[] { $"{m} dues {p}", $"pending dues {p} {m}", $"outstanding amount {p} {m}", $"unpaid {m} bills {p}",
                                          $"which bills have due {p}", $"due list {p} {m}", $"balance due {m} {p}", $"how much due {p} {m}", $"show pending payment {p}" })
                    yield return (s.Trim(), Dues);
            }
        foreach (var p in periods)
            foreach (var s in new[] { $"pending samples {p}", $"samples not collected {p}", $"how many samples collected {p}", $"reports pending approval {p}",
                                      $"pending reports {p}", $"lab work status {p}", $"how many reports approved {p}", $"tests waiting for result {p}",
                                      $"sample collection status {p}", $"rejected samples {p}" })
                yield return (s.Trim(), LabWork);
        foreach (var s in new[] { "find patient rahul das", "show patient anita mitra", "patient details of abhik porel", "search patient named kajal",
                                  "open patient profile of samir", "patient history of manas mitra", "who is patient arun", "patient record for anjali" })
            yield return (s, Patient);
        foreach (var s in new[] { "open bill", "show this bill", "print bill", "bill details", "status of bill", "open the bill number", "token status", "find token" })
            yield return (s, s.Contains("token") ? Token : Bill);
        // help questions: how-to wording about the same subjects
        foreach (var s in new[] { "how do i collect a due on a lab bill", "how to cancel a lab bill", "where do i see the collection report", "how to print a bill",
                                  "how to approve a report", "how to collect a sample", "what is next after sample collection", "how to register a patient",
                                  "steps to create a b2c bill", "how do i give discount", "where is day closing", "lab workflow", "opd workflow",
                                  "how to add a new test", "how to refund", "how to transfer sample", "what to do before billing", "how to change password",
                                  "how to set up rate list", "explain membership card", "add new doctor", "how to book opd appointment", "what is token management",
                                  "how to send report on whatsapp", "barcode printing problem", "sample rejected what to do", "how to settle b2b bills",
                                  "configure hospital settings", "how to unlock user", "create user", "set permissions for role" })
            yield return (s, Help);
    }

    private static int Distance(string a, string b, int max)
    {
        var d = new int[a.Length + 1, b.Length + 1];
        for (var i = 0; i <= a.Length; i++) d[i, 0] = i;
        for (var j = 0; j <= b.Length; j++) d[0, j] = j;
        for (var i = 1; i <= a.Length; i++)
        {
            var rowMin = int.MaxValue;
            for (var j = 1; j <= b.Length; j++)
            {
                var cost = a[i - 1] == b[j - 1] ? 0 : 1;
                d[i, j] = Math.Min(Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1), d[i - 1, j - 1] + cost);
                if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) d[i, j] = Math.Min(d[i, j], d[i - 2, j - 2] + 1);
                rowMin = Math.Min(rowMin, d[i, j]);
            }
            if (rowMin > max) return max + 1;
        }
        return d[a.Length, b.Length];
    }

    // ── answering ────────────────────────────────────────────────────────────────────────────────────────────

    private static string Money(decimal v) => "₹" + v.ToString("N2", CultureInfo.GetCultureInfo("en-IN"));
    private static string Date(DateTime? v) => v is null ? "—" : v.Value.ToString("dd MMM yyyy HH:mm");
    private static string PayStatus(string? s, decimal due, bool active) =>
        !active ? "Cancelled" : s switch { "P" => "Paid", "R" => "Refunded", _ => due > 0 ? "Due" : "Paid" };
    private static string BillUrl(string module, int id) => module == "OPD" ? $"/OPD/PrintBill/{id}" : $"/LabOrderBooking/PrintBill?labOrderId={id}";

    /// <summary>
    /// The screens of a bill, the one asked for first (primary, opened at once). Report entry goes to the screen of the
    /// bill's tests: Image Report Entry (Reporting Type Image), Microbiology Report Entry (Template / Culture) or Lab
    /// Report Entry (the rest; it also links a mixed bill on to Microbiology). A bill with image and other tests opens the
    /// one named ("image", "radiology", "microbiology") or Lab Report Entry, and offers the other.
    /// </summary>
    private static (List<HelpDataAction> Actions, string? Note) BillActions(BillRow b, string target, string text)
    {
        var bill = new HelpDataAction { Title = "Open Bill", Url = BillUrl(b.Module, b.RefId), Icon = "bi-receipt" };
        if (b.Module != "LAB") return ([bill with { Primary = true }], target == TargetBill ? null : "Reporting, samples and barcodes are for LAB bills; this is an OPD bill.");

        var numeric = b.Tests - b.ImageTests - b.MicroTests;
        var image = new HelpDataAction { Title = "Image Report Entry", Url = $"/LabImageReporting/Entry?labOrderId={b.RefId}", Icon = "bi-image" };
        var micro = new HelpDataAction { Title = "Microbiology Report Entry", Url = $"/MicrobiologyReporting/Entry?labOrderId={b.RefId}", Icon = "bi-virus" };
        var lab = new HelpDataAction { Title = "Lab Report Entry", Url = $"/LabReporting/Entry?labOrderId={b.RefId}", Icon = "bi-clipboard2-pulse" };
        var entries = new List<HelpDataAction>();
        if (numeric > 0) entries.Add(lab);
        if (b.ImageTests > 0) entries.Add(image);
        if (b.MicroTests > 0) entries.Add(micro);
        if (entries.Count == 0) entries.Add(lab);
        // the one named first
        if (Regex.IsMatch(text, @"\b(image|radiology|ct|mri|x\s?ray|usg|ultrasound)\b") && b.ImageTests > 0) entries = [image, .. entries.Where(e => e != image)];
        else if (Regex.IsMatch(text, @"\b(microbiology|culture|micro)\b") && b.MicroTests > 0) entries = [micro, .. entries.Where(e => e != micro)];

        var report = new HelpDataAction { Title = "Print Report", Url = $"/LabReportDispatch/PrintReportPdf?labOrderId={b.RefId}", Icon = "bi-file-earmark-pdf" };
        var sample = new HelpDataAction
        {
            Title = "Sample Collection", Icon = "bi-droplet",
            Url = $"/SampleCollection/Index?search={Uri.EscapeDataString(b.BillNo)}&fromDate={b.BillDate:yyyy-MM-dd}&toDate={b.BillDate:yyyy-MM-dd}"
        };
        var barcode = new HelpDataAction { Title = "Print Barcode", Url = $"/SampleCollection/PrintBarcode?labOrderId={b.RefId}", Icon = "bi-upc-scan" };

        List<HelpDataAction> order = target switch
        {
            TargetEntry => [.. entries, bill, sample, report],
            TargetReport => [report, bill, .. entries, sample],
            TargetSample => [sample, bill, barcode, .. entries],
            TargetBarcode => [barcode, sample, bill],
            _ => [bill, .. entries, sample, report]
        };
        order[0] = order[0] with { Primary = true };
        string? note = null;
        if (target == TargetEntry && b.SamplesCollected == 0)
            note = "No sample of this bill is collected yet - report entry opens once its samples are collected.";
        else if (target == TargetEntry && entries.Count > 1)
            note = $"This bill has tests on {entries.Count} reporting screens - {order[0].Title} is opened; the others are below.";
        else if (target == TargetReport && b.ReportsApproved == 0)
            note = "No report of this bill is approved yet - the report shows only approved results.";
        return (order, note);
    }

    private static string AllowedModules(string wanted, IReadOnlyCollection<string> scopes) =>
        string.Join(',', wanted.Split(',').Where(m => scopes.Contains(m, StringComparer.OrdinalIgnoreCase)));

    private static HelpAnswer Denied(string what) => new()
    {
        Found = true, Kind = "DATA", Code = "DATA:DENIED", Title = "No access",
        Text = $"You do not have permission to see {what}. Ask your administrator for access to the related screen."
    };

    /// <summary>The data answer, or null when the question is not a data question.</summary>
    public static async Task<HelpAnswer?> AnswerAsync(IDbConnection db, HelpAskRequest r, DateTime today)
    {
        var q = Understand(r.Question ?? "", today);
        if (q.Kind == Help) return null;
        var scopes = r.DataScopes ?? [];
        if (scopes.Count == 0) return null;   // data answers are off for this user: help answers only
        var p = new { r.CompanyId, r.BranchId };
        const CommandType sp = CommandType.StoredProcedure;
        var from = q.From.Date; var to = q.To.Date;
        var periodText = from == to ? from.ToString("dd MMM yyyy") : $"{from:dd MMM yyyy} – {to:dd MMM yyyy}";

        switch (q.Kind)
        {
            case Bill:
            {
                var mods = AllowedModules("LAB,OPD", scopes);
                if (mods.Length == 0) return Denied("bills");
                var rows = (await db.QueryAsync<BillRow>("dbo.usp_HelpData_BillLookup", new { p.CompanyId, p.BranchId, Text = q.Value, Modules = mods }, commandType: sp)).ToList();
                if (rows.Count == 0)
                    return new HelpAnswer { Found = true, Kind = "DATA", Code = "DATA:BILL", Title = "Bill not found",
                        Text = $"No bill \"{q.Value}\" was found{(r.BranchId is null ? "" : " in this branch")}. Check the number, or search it in the B2C Order List / Service Booking." };
                var b = rows[0];
                var a = new HelpAnswer
                {
                    Found = true, Kind = "DATA", Code = "DATA:BILL", Title = $"{b.Module} bill {b.BillNo}",
                    Text = $"{b.PatientName} ({b.PatientCode}) - {(b.IsActive ? PayStatus(b.PaymentStatus, b.Due, true) : "Cancelled")}, net {Money(b.NetAmount)}.",
                    Data = new HelpDataView
                    {
                        Facts =
                        [
                            new() { Label = "Bill date", Value = Date(b.BillDate) },
                            new() { Label = "Token", Value = b.TokenNo ?? "—" },
                            new() { Label = "Patient", Value = $"{b.PatientName} · {b.PatientCode}" },
                            new() { Label = "Phone", Value = b.PhoneNumber ?? "—" },
                            new() { Label = "Net amount", Value = Money(b.NetAmount) },
                            new() { Label = "Paid", Value = Money(b.Paid), Tone = "good" },
                            new() { Label = "Due", Value = Money(b.Due), Tone = b.Due > 0 ? "bad" : null },
                            new() { Label = "Status", Value = b.IsActive ? PayStatus(b.PaymentStatus, b.Due, true) : "Cancelled", Tone = !b.IsActive ? "bad" : b.Due > 0 ? "warn" : "good" },
                        ],
                    }
                };
                var (actions, note) = BillActions(b, q.Target, Correct(r.Question ?? ""));
                a.Data.Actions = actions;
                a.Data.Note = note;
                if (b.Module == "LAB")
                {
                    a.Data.Facts.Add(new() { Label = "Tests", Value = $"{b.Tests}{(string.IsNullOrWhiteSpace(b.TestNames) ? "" : " · " + b.TestNames)}" });
                    a.Data.Facts.Add(new() { Label = "Samples collected", Value = $"{b.SamplesCollected} of {b.Samples}" });
                    a.Data.Facts.Add(new() { Label = "Reports approved", Value = $"{b.ReportsApproved} of {b.Tests}" });
                    if (q.Target == TargetBill) a.Data.Actions.Add(new() { Title = "B2C Order List", Url = $"/LabOrderBooking/B2COrderList?search={Uri.EscapeDataString(b.BillNo)}&fromDate={b.BillDate:yyyy-MM-dd}&toDate={b.BillDate:yyyy-MM-dd}", Icon = "bi-list-ul" });
                }
                if (r.BranchId is null && b.BranchName is not null) a.Data.Facts.Insert(1, new() { Label = "Branch", Value = b.BranchName });
                if (rows.Count > 1) a.Data.Rows = rows.Skip(1).Select(x => new HelpDataRow { Cells = [x.BillNo, Date(x.BillDate), x.PatientName ?? "", Money(x.NetAmount)], Url = BillUrl(x.Module, x.RefId) }).ToList();
                if (rows.Count > 1) a.Data.Columns = ["Other matching bill", "Date", "Patient", "Net"];
                if (q.WantsOpen && rows.Count == 1) a.OpenUrl = actions[0].Url;
                if (q.Target != TargetBill) a.Title += " · " + actions[0].Title;
                return a;
            }
            case Token:
            {
                var mods = AllowedModules(q.Modules, scopes);
                if (mods.Length == 0) mods = AllowedModules("LAB,OPD", scopes);
                if (mods.Length == 0) return Denied("bills");
                // a token number repeats every day: today unless a date was named
                var rows = (await db.QueryAsync<BillRow>("dbo.usp_HelpData_TokenLookup", new { p.CompanyId, p.BranchId, Text = q.Value, From = from, To = to, Modules = mods }, commandType: sp)).ToList();
                if (rows.Count == 0)
                    return new HelpAnswer { Found = true, Kind = "DATA", Code = "DATA:TOKEN", Title = "Token not found", Text = $"No token {q.Value} on {periodText}. Add a date (e.g. \"{q.Value} yesterday\")." };
                var b = rows[0];
                // the token's bill, with what its screens need (reporting types, samples)
                var full = (await db.QueryAsync<BillRow>("dbo.usp_HelpData_BillLookup", new { p.CompanyId, p.BranchId, Text = b.BillNo, Modules = b.Module }, commandType: sp))
                           .FirstOrDefault(x => x.RefId == b.RefId && x.Module == b.Module) ?? b;
                var (tActions, tNote) = BillActions(full, q.Target, Correct(r.Question ?? ""));
                return new HelpAnswer
                {
                    Found = true, Kind = "DATA", Code = "DATA:TOKEN", Title = $"Token {b.TokenNo}" + (q.Target != TargetBill ? " · " + tActions[0].Title : ""),
                    Text = $"{b.Module} bill {b.BillNo} of {b.PatientName} ({b.PatientCode}), {Date(b.BillDate)}.",
                    OpenUrl = q.WantsOpen && rows.Count == 1 ? tActions[0].Url : null,
                    Data = new HelpDataView
                    {
                        Facts =
                        [
                            new() { Label = "Bill", Value = b.BillNo }, new() { Label = "Patient", Value = $"{b.PatientName} · {b.PhoneNumber}" },
                            new() { Label = "Net amount", Value = Money(b.NetAmount) }, new() { Label = "Due", Value = Money(b.Due), Tone = b.Due > 0 ? "bad" : null },
                            new() { Label = "Status", Value = PayStatus(b.PaymentStatus, b.Due, b.IsActive), Tone = b.IsActive ? null : "bad" }
                        ],
                        Actions = tActions,
                        Note = tNote
                    }
                };
            }
            case Patient:
            {
                if (!scopes.Contains(ScopePatients, StringComparer.OrdinalIgnoreCase)) return Denied("patient records");
                var rows = (await db.QueryAsync<PatientRow>("dbo.usp_HelpData_PatientLookup", new { p.CompanyId, p.BranchId, Text = q.Value }, commandType: sp)).ToList();
                if (rows.Count == 0 && PatientCodeRegex().IsMatch(q.Value ?? "") && AllowedModules("LAB,OPD", scopes).Length > 0)
                    return await AnswerAsync(db, new HelpAskRequest { CompanyId = r.CompanyId, BranchId = r.BranchId, DataScopes = scopes, Question = "LAB/" + q.Value }, today);
                if (rows.Count == 0)
                    return new HelpAnswer { Found = true, Kind = "DATA", Code = "DATA:PATIENT", Title = "Patient not found", Text = $"No patient matches \"{q.Value}\"." };
                return new HelpAnswer
                {
                    Found = true, Kind = "DATA", Code = "DATA:PATIENT", Title = rows.Count == 1 ? rows[0].PatientName : $"{rows.Count} patients found",
                    Text = rows.Count == 1 ? $"{rows[0].PatientCode} · {rows[0].Gender}{(rows[0].AgeYears is { } y ? $", {y} years" : "")} · {rows[0].Bills} bill(s), last visit {Date(rows[0].LastVisit)}."
                                           : $"Patients matching \"{q.Value}\":",
                    Data = new HelpDataView
                    {
                        Columns = ["Patient ID", "Name", "Phone", "Bills", "Last visit", "Due"],
                        Rows = rows.Select(x => new HelpDataRow
                        {
                            Cells = [x.PatientCode ?? "", x.PatientName ?? "", x.PhoneNumber ?? "", x.Bills.ToString(), Date(x.LastVisit), Money(x.Due ?? 0)],
                            Url = $"/LabOrderBooking/B2CBooking?patientId={x.PatientId}"
                        }).ToList(),
                        Note = "Click a patient to start a B2C booking with their details."
                    }
                };
            }
            case Summary:
            {
                var mods = AllowedModules(q.Modules, scopes);
                if (mods.Length == 0) return Denied(q.Modules == "LAB" ? "LAB billing" : q.Modules == "OPD" ? "OPD billing" : "billing");
                var rows = (await db.QueryAsync<SummaryRow>("dbo.usp_HelpData_Summary", new { p.CompanyId, p.BranchId, From = from, To = to, Modules = mods }, commandType: sp)).ToList();
                var tot = (Bills: rows.Sum(x => x.Bills), Net: rows.Sum(x => x.NetAmount), Paid: rows.Sum(x => x.Paid), Due: rows.Sum(x => x.Due));
                var a = new HelpAnswer
                {
                    Found = true, Kind = "DATA", Code = "DATA:SUMMARY", Title = $"Billing {q.PeriodLabel}",
                    Text = rows.Count == 0 ? $"No bills on {periodText}." : $"{tot.Bills} bill(s) on {periodText}: net {Money(tot.Net)}, paid {Money(tot.Paid)}, due {Money(tot.Due)}.",
                    Data = new HelpDataView
                    {
                        Columns = ["Module", "Bills", "Patients", "Net", "Paid", "Due", "Cancelled"],
                        Rows = rows.Select(x => new HelpDataRow { Cells = [x.Module, x.Bills.ToString(), x.Patients.ToString(), Money(x.NetAmount), Money(x.Paid), Money(x.Due), x.Cancelled.ToString()] }).ToList(),
                        Note = "Amounts of the bills made in the period (paid = received against those bills), cancelled bills excluded."
                    }
                };
                if (mods.Contains("LAB")) a.Data.Actions.Add(new() { Title = "B2C Order List", Url = $"/LabOrderBooking/B2COrderList?fromDate={from:yyyy-MM-dd}&toDate={to:yyyy-MM-dd}", Icon = "bi-list-ul" });
                if (mods.Contains("OPD")) a.Data.Actions.Add(new() { Title = "OPD Service Booking", Url = $"/OPD/ServiceBooking?fromDate={from:yyyy-MM-dd}&toDate={to:yyyy-MM-dd}", Icon = "bi-list-ul" });
                return a;
            }
            case Dues:
            {
                var mods = AllowedModules(q.Modules, scopes);
                if (mods.Length == 0) return Denied("billing");
                // "dues" without a period: the whole current financial year is more useful than today only
                if (q.PeriodLabel == "today" && !Regex.IsMatch(Correct(r.Question ?? ""), @"\btoday\b"))
                {
                    from = new DateTime(today.Month >= 4 ? today.Year : today.Year - 1, 4, 1);
                    periodText = $"{from:dd MMM yyyy} – {to:dd MMM yyyy}";
                }
                using var multi = await db.QueryMultipleAsync("dbo.usp_HelpData_Dues", new { p.CompanyId, p.BranchId, From = from, To = to, Modules = mods }, commandType: sp);
                var head = await multi.ReadSingleAsync<(int Bills, decimal Due)>();
                var rows = (await multi.ReadAsync<DueRow>()).ToList();
                var a = new HelpAnswer
                {
                    Found = true, Kind = "DATA", Code = "DATA:DUES", Title = "Pending dues",
                    Text = head.Bills == 0 ? $"No bill with a due on {periodText}." : $"{head.Bills} bill(s) with {Money(head.Due)} due ({periodText}){(head.Bills > 10 ? " - the 10 largest:" : ":")}",
                    Data = new HelpDataView
                    {
                        Columns = ["Bill", "Date", "Patient", "Phone", "Net", "Due"],
                        Rows = rows.Select(x => new HelpDataRow { Cells = [x.BillNo, x.BillDate.ToString("dd MMM yyyy"), x.PatientName ?? "", x.PhoneNumber ?? "", Money(x.NetAmount), Money(x.Due)], Url = BillUrl(x.Module, x.RefId) }).ToList()
                    }
                };
                if (mods.Contains("LAB")) a.Data.Actions.Add(new() { Title = "LAB dues list", Url = $"/LabOrderBooking/B2COrderList?fromDate={from:yyyy-MM-dd}&toDate={to:yyyy-MM-dd}&paymentStatus=DUE", Icon = "bi-cash-coin" });
                if (mods.Contains("OPD")) a.Data.Actions.Add(new() { Title = "OPD dues list", Url = $"/OPD/ServiceBooking?fromDate={from:yyyy-MM-dd}&toDate={to:yyyy-MM-dd}&paymentStatus=DUE", Icon = "bi-cash-coin" });
                return a;
            }
            case LabWork:
            {
                if (!scopes.Contains(ScopeSamples, StringComparer.OrdinalIgnoreCase)) return Denied("sample and report status");
                var w = await db.QuerySingleAsync<LabWorkRow>("dbo.usp_HelpData_LabWork", new { p.CompanyId, p.BranchId, From = from, To = to }, commandType: sp);
                return new HelpAnswer
                {
                    Found = true, Kind = "DATA", Code = "DATA:LABWORK", Title = $"Lab work {q.PeriodLabel}",
                    Text = w.Tests == 0 ? $"No lab tests booked on {periodText}." : $"{w.Tests} test(s) booked on {periodText}.",
                    Data = new HelpDataView
                    {
                        Facts =
                        [
                            new() { Label = "Samples pending", Value = w.SamplesPending.ToString(), Tone = w.SamplesPending > 0 ? "warn" : null },
                            new() { Label = "Samples collected", Value = w.SamplesCollected.ToString() },
                            new() { Label = "Samples rejected", Value = w.SamplesRejected.ToString(), Tone = w.SamplesRejected > 0 ? "bad" : null },
                            new() { Label = "Awaiting result entry", Value = w.AwaitingResult.ToString(), Tone = w.AwaitingResult > 0 ? "warn" : null },
                            new() { Label = "Awaiting approval", Value = w.AwaitingApproval.ToString(), Tone = w.AwaitingApproval > 0 ? "warn" : null },
                            new() { Label = "Reports approved", Value = w.ReportsApproved.ToString(), Tone = "good" }
                        ],
                        Actions =
                        [
                            new() { Title = "Sample Collection", Url = "/SampleCollection/Index", Icon = "bi-droplet" },
                            new() { Title = "Lab Reporting", Url = "/LabReporting/Index", Icon = "bi-clipboard2-pulse" }
                        ]
                    }
                };
            }
        }
        return null;
    }

    private sealed class BillRow
    {
        public string Module { get; set; } = ""; public int RefId { get; set; } public string BillNo { get; set; } = ""; public string? TokenNo { get; set; }
        public DateTime? BillDate { get; set; } public bool IsActive { get; set; } public bool IsB2B { get; set; }
        public decimal NetAmount { get; set; } public decimal Paid { get; set; } public decimal Due { get; set; } public string? PaymentStatus { get; set; }
        public string? PatientCode { get; set; } public string? PatientName { get; set; } public string? PhoneNumber { get; set; } public string? Gender { get; set; }
        public int? AgeYears { get; set; } public string? BranchName { get; set; }
        public int Samples { get; set; } public int SamplesCollected { get; set; } public int ReportsApproved { get; set; } public int Tests { get; set; } public string? TestNames { get; set; }
        public int ImageTests { get; set; } public int MicroTests { get; set; }
    }
    private sealed class PatientRow
    {
        public int PatientId { get; set; } public string? PatientCode { get; set; } public string? PatientName { get; set; } public string? PhoneNumber { get; set; }
        public string? Gender { get; set; } public int? AgeYears { get; set; } public int Bills { get; set; } public DateTime? LastVisit { get; set; } public decimal? Due { get; set; }
    }
    private sealed class SummaryRow
    {
        public string Module { get; set; } = ""; public int Bills { get; set; } public int Cancelled { get; set; } public decimal NetAmount { get; set; }
        public decimal Paid { get; set; } public decimal Due { get; set; } public int DueBills { get; set; } public int Patients { get; set; }
    }
    private sealed class DueRow
    {
        public string Module { get; set; } = ""; public int RefId { get; set; } public string BillNo { get; set; } = ""; public DateTime BillDate { get; set; }
        public decimal NetAmount { get; set; } public decimal Paid { get; set; } public decimal Due { get; set; } public string? PatientName { get; set; } public string? PhoneNumber { get; set; }
    }
    private sealed class LabWorkRow
    {
        public int Tests { get; set; } public int SamplesPending { get; set; } public int SamplesCollected { get; set; } public int SamplesRejected { get; set; }
        public int AwaitingResult { get; set; } public int AwaitingApproval { get; set; } public int ReportsApproved { get; set; }
    }
}
