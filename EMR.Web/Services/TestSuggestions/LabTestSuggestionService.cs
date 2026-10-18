using Dapper;
using EMR.Web.Data;
using Microsoft.Extensions.Caching.Memory;

namespace EMR.Web.Services.TestSuggestions;

/// <summary>A test / profile / package usually billed together with what is already in the order.</summary>
/// <param name="Key">The booking screen's item key: "I_&lt;test id&gt;" (test or profile) or "P_&lt;package id&gt;".</param>
/// <param name="BecauseKey">The selected item that supports it most (null when the referring doctor's habit does).</param>
/// <param name="Score">Combined, conservative likelihood (0-1) that it belongs on this bill.</param>
/// <param name="Bills">Past bills that had both <paramref name="BecauseKey"/> and this item.</param>
/// <param name="Of">Past bills that had <paramref name="BecauseKey"/>.</param>
/// <param name="Basis">What the numbers are from: "branch", "company", "gender" (same-gender patients) or "doctor".</param>
public sealed record TestSuggestion(string Key, string? BecauseKey, double Score, int Bills, int Of, string Basis);

/// <summary>A profile / package that contains several of the selected tests / profiles.</summary>
/// <param name="CoversKeys">The selected items it contains (keys as the booking screen uses them).</param>
public sealed record BundleSuggestion(string Key, string[] CoversKeys);

public sealed record TestSuggestionResult(IReadOnlyList<TestSuggestion> Together, IReadOnlyList<BundleSuggestion> Bundles, int LearnedFromBills, bool CompanyWide);

/// <summary>What the screen knows about the patient and the bill, used to make suggestions fit.</summary>
public sealed record TestSuggestionContext(string? Gender, int? ReferralDoctorId);

public interface ILabTestSuggestionService
{
    /// <summary>Suggestions for the items selected on a B2C bill (keys as the booking screen uses them).</summary>
    Task<TestSuggestionResult> SuggestAsync(int companyId, int branchId, IReadOnlyCollection<string> selectedKeys, TestSuggestionContext context);

    /// <summary>Records a suggestion accepted (Add / Switch) or dismissed, for the engine to learn from.</summary>
    Task RecordFeedbackAsync(int companyId, int branchId, int userId, string suggestedKey, string? contextKey, char kind, char action);
}

/// <summary>
/// AI test suggestions at B2C billing (Hospital Settings > Enable AI Features at Billing). Learned from our own bills:
/// <list type="bullet">
/// <item>association rules over the last 12 months of active B2C bills of the branch (or the whole company while the
///   branch has fewer than <see cref="MinBranchBills"/>), recent bills counting more (half-life <see cref="HalfLifeDays"/> days);</item>
/// <item>each "bills with X also had Y" rate taken at its Wilson lower bound, so a few bills cannot look certain;</item>
/// <item>the evidence of every selected item combined (noisy-OR), plus the referring doctor's own ordering habit;</item>
/// <item>same-gender history when there is enough of it;</item>
/// <item>staff feedback: what is usually dismissed fades, what is usually taken rises.</item>
/// </list>
/// Packages and profiles come from their masters. The learned model is kept in memory for an hour per branch.
/// Suggestions only: the screen adds nothing without a click.
/// </summary>
public sealed class LabTestSuggestionService(IDbConnectionFactory db, IMemoryCache cache) : ILabTestSuggestionService
{
    private const int MinBranchBills = 30;       // below this, learn from every branch of the company
    private const int MinTogetherBills = 3;      // a pair seen fewer times is chance
    private const int MinSegmentBills = 15;      // same-gender history used only when the selected item has this many
    private const int MinDoctorBills = 10;       // a referring doctor's habit used only from this many of their bills
    private const double HalfLifeDays = 180;     // a bill half a year old counts half
    private const double Z = 1.28;               // Wilson lower bound at ~80% one-sided confidence
    private const double MinScore = 0.15;        // combined score to be shown
    private const double MinLift = 1.2;          // clearly more often than the item is billed anyway
    private const int MaxTogether = 5;
    private const int MaxBundles = 3;

    /// <summary>Counts of one population of bills (all, one gender, one doctor): raw for the statistics, weighted for recency.</summary>
    private sealed class Stats
    {
        public int Bills;
        public double WBills;
        public readonly Dictionary<string, int> Count = new();
        public readonly Dictionary<string, double> WCount = new();
        public readonly Dictionary<string, Dictionary<string, (int N, double W)>> Pair = new();

        public void Add(List<string> items, double w)
        {
            Bills++; WBills += w;
            foreach (var a in items)
            {
                Count[a] = Count.GetValueOrDefault(a) + 1;
                WCount[a] = WCount.GetValueOrDefault(a) + w;
                if (!Pair.TryGetValue(a, out var row)) Pair[a] = row = new();
                foreach (var b in items)
                    if (b != a) { var c = row.GetValueOrDefault(b); row[b] = (c.N + 1, c.W + w); }
            }
        }
    }

    private sealed class Model
    {
        public Stats All = new();
        public readonly Dictionary<string, Stats> ByGender = new(StringComparer.OrdinalIgnoreCase);
        public readonly Dictionary<int, Stats> ByDoctor = new();
        public bool CompanyWide;
    }

    private sealed record Bundle(string Key, HashSet<int> Tests);

    public async Task<TestSuggestionResult> SuggestAsync(int companyId, int branchId, IReadOnlyCollection<string> selectedKeys, TestSuggestionContext context)
    {
        var selected = selectedKeys.Where(k => k.Length > 2).Distinct().ToHashSet();
        if (selected.Count == 0) return new TestSuggestionResult([], [], 0, false);

        var model = await GetModelAsync(companyId, branchId);
        var bundles = await GetBundlesAsync(companyId);
        var feedback = await GetFeedbackAsync(companyId);
        var bundleByKey = bundles.ToDictionary(b => b.Key);

        // tests already inside a selected profile / package are not suggested again
        var covered = new HashSet<string>(selected);
        foreach (var k in selected)
            if (bundleByKey.TryGetValue(k, out var b))
                foreach (var t in b.Tests) covered.Add("I_" + t);

        // ── billed together ──
        // per candidate: the conservative rate from each selected item (and the doctor), combined by noisy-OR
        var evidence = new Dictionary<string, List<(double Lower, string? Because, int Bills, int Of, string Basis, double Lift)>>();
        void Collect(Stats s, string x, string basis)
        {
            if (!s.Count.TryGetValue(x, out var nx) || nx == 0 || !s.Pair.TryGetValue(x, out var row)) return;
            var wx = s.WCount[x];
            foreach (var (y, pair) in row)
            {
                if (covered.Contains(y) || pair.N < MinTogetherBills) continue;
                var lower = WilsonLower(pair.N, nx);
                var weighted = pair.W / wx;                                     // recent bills count more
                var conservative = Math.Min(lower, weighted);
                var lift = (pair.W / wx) / (s.WCount.GetValueOrDefault(y) / s.WBills);
                if (!evidence.TryGetValue(y, out var list)) evidence[y] = list = new();
                list.Add((conservative, basis == "doctor" ? null : x, pair.N, nx, basis, lift));
            }
        }

        Stats? genderStats = null;
        if (!string.IsNullOrWhiteSpace(context.Gender)) model.ByGender.TryGetValue(context.Gender.Trim(), out genderStats);
        foreach (var x in selected)
        {
            // same-gender history when the selected item has enough of it, else everyone's
            var useGender = genderStats is not null && genderStats.Count.GetValueOrDefault(x) >= MinSegmentBills;
            Collect(useGender ? genderStats! : model.All, x, useGender ? "gender" : (model.CompanyWide ? "company" : "branch"));
        }
        if (context.ReferralDoctorId is int doc && model.ByDoctor.TryGetValue(doc, out var docStats) && docStats.Bills >= MinDoctorBills)
            foreach (var x in selected) Collect(docStats, x, "doctor");

        var together = new List<TestSuggestion>();
        foreach (var (y, list) in evidence)
        {
            if (list.All(e => e.Lift < MinLift)) continue;                       // ordered with everything anyway
            var score = 1 - list.Aggregate(1.0, (acc, e) => acc * (1 - e.Lower));
            score *= FeedbackFactor(feedback, y);
            if (score < MinScore) continue;
            var best = list.OrderByDescending(e => e.Lower).First();
            together.Add(new TestSuggestion(y, best.Because, Math.Round(Math.Min(score, 0.99), 2), best.Bills, best.Of, best.Basis));
        }

        // ── a profile / package that contains several of the selected tests and profiles ──
        // a selected test is inside it when its id is; a selected profile when the package lists the profile itself,
        // or every test of that profile
        bool Contains(Bundle b, string key)
        {
            if (!key.StartsWith("I_") || !int.TryParse(key[2..], out var id)) return false;
            if (b.Tests.Contains(id)) return true;
            return bundleByKey.TryGetValue(key, out var profile) && profile.Tests.Count > 0 && profile.Tests.IsSubsetOf(b.Tests);
        }
        var bundleHits = bundles
            .Where(b => !selected.Contains(b.Key) && FeedbackFactor(feedback, b.Key) >= 0.35)
            .Select(b => new BundleSuggestion(b.Key, selected.Where(k => Contains(b, k)).OrderBy(k => k).ToArray()))
            .Where(b => b.CoversKeys.Length >= 2)
            .OrderByDescending(b => b.CoversKeys.Length)
            .Take(MaxBundles)
            .ToList();

        return new TestSuggestionResult(
            together.OrderByDescending(s => s.Score).ThenByDescending(s => s.Bills).Take(MaxTogether).ToList(),
            bundleHits, model.All.Bills, model.CompanyWide);
    }

    /// <summary>Lower bound of the Wilson score interval: the rate we can be fairly sure of from k of n bills.</summary>
    private static double WilsonLower(int k, int n)
    {
        if (n <= 0) return 0;
        var p = (double)k / n;
        var z2 = Z * Z;
        return Math.Max(0, (p + z2 / (2 * n) - Z * Math.Sqrt(p * (1 - p) / n + z2 / (4.0 * n * n))) / (1 + z2 / n));
    }

    /// <summary>Staff feedback on an item: (accepted + 1) / (accepted + dismissed + 2), scaled so no feedback = 1.</summary>
    private static double FeedbackFactor(Dictionary<string, (int A, int D)> feedback, string key)
    {
        if (!feedback.TryGetValue(key, out var f)) return 1;
        var rate = (f.A + 1.0) / (f.A + f.D + 2.0);   // 0.5 with no feedback
        return Math.Clamp(rate * 2, 0.15, 1.5);
    }

    private async Task<Model> GetModelAsync(int companyId, int branchId)
    {
        var key = $"LabTestSuggest:model:{companyId}:{branchId}";
        if (cache.TryGetValue(key, out Model? hit) && hit is not null) return hit;

        using var con = db.CreateConnection();
        var rows = (await con.QueryAsync<(int LabOrderId, int BranchId, DateTime OrderDate, string? Gender, int? DoctorId, string Item)>(@"
            SELECT DISTINCT o.LabOrderId, o.BranchId, o.OrderDate, p.Gender, o.ReferralDoctorId,
                   i.Type + '_' + CAST(i.InvestigationId AS varchar(12)) AS Item
              FROM dbo.LabOrder o
              JOIN dbo.LabOrderItem i ON i.LabOrderId = o.LabOrderId AND i.IsActive = 1
              JOIN dbo.Branchmaster b ON b.BranchID = o.BranchId
              LEFT JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
             WHERE o.IsActive = 1 AND ISNULL(o.IsB2B, 0) = 0 AND b.CompanyId = @companyId
               AND o.OrderDate >= DATEADD(YEAR, -1, GETDATE())", new { companyId }, commandTimeout: 60)).ToList();

        var branchBills = rows.Where(r => r.BranchId == branchId).Select(r => r.LabOrderId).Distinct().Count();
        var model = new Model { CompanyWide = branchBills < MinBranchBills };
        var today = DateTime.Today;
        foreach (var bill in rows.Where(r => model.CompanyWide || r.BranchId == branchId).GroupBy(r => r.LabOrderId))
        {
            var first = bill.First();
            var items = bill.Select(r => r.Item).Distinct().ToList();
            var w = Math.Pow(0.5, Math.Max(0, (today - first.OrderDate.Date).TotalDays) / HalfLifeDays);
            model.All.Add(items, w);
            if (!string.IsNullOrWhiteSpace(first.Gender))
            {
                if (!model.ByGender.TryGetValue(first.Gender.Trim(), out var g)) model.ByGender[first.Gender.Trim()] = g = new Stats();
                g.Add(items, w);
            }
            if (first.DoctorId is int d && d > 0)
            {
                if (!model.ByDoctor.TryGetValue(d, out var s)) model.ByDoctor[d] = s = new Stats();
                s.Add(items, w);
            }
        }
        cache.Set(key, model, TimeSpan.FromHours(1));
        return model;
    }

    /// <summary>Accepted / dismissed counts per suggested item over the last 6 months (a few minutes in memory).</summary>
    private async Task<Dictionary<string, (int A, int D)>> GetFeedbackAsync(int companyId)
    {
        var key = $"LabTestSuggest:feedback:{companyId}";
        if (cache.TryGetValue(key, out Dictionary<string, (int, int)>? hit) && hit is not null) return hit;
        var result = new Dictionary<string, (int A, int D)>();
        try
        {
            using var con = db.CreateConnection();
            var rows = await con.QueryAsync<(string SuggestedKey, int A, int D)>(@"
                SELECT SuggestedKey, SUM(CASE WHEN Action = 'A' THEN 1 ELSE 0 END), SUM(CASE WHEN Action = 'D' THEN 1 ELSE 0 END)
                  FROM dbo.LabAiSuggestionFeedback
                 WHERE CompanyId = @companyId AND CreatedDate >= DATEADD(MONTH, -6, GETDATE())
                 GROUP BY SuggestedKey", new { companyId });
            foreach (var r in rows) result[r.SuggestedKey] = (r.A, r.D);
        }
        catch (Microsoft.Data.SqlClient.SqlException)
        {
            // feedback table not there yet (SQLScripts/2288): suggest without it
        }
        cache.Set(key, result, TimeSpan.FromMinutes(5));
        return result;
    }

    public async Task RecordFeedbackAsync(int companyId, int branchId, int userId, string suggestedKey, string? contextKey, char kind, char action)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            INSERT dbo.LabAiSuggestionFeedback (CompanyId, BranchId, SuggestedKey, ContextKey, Kind, Action, UserId)
            VALUES (@companyId, @branchId, @suggestedKey, @contextKey, @kind, @action, @userId)",
            new { companyId, branchId, suggestedKey, contextKey, kind = kind.ToString(), action = action.ToString(), userId });
        cache.Remove($"LabTestSuggest:feedback:{companyId}");
    }

    /// <summary>Active profiles ("I_" + their test id) and packages ("P_" + their id) with the tests inside them,
    /// a profile inside a package opened up to its own tests.</summary>
    private async Task<List<Bundle>> GetBundlesAsync(int companyId)
    {
        var key = $"LabTestSuggest:bundles:{companyId}";
        if (cache.TryGetValue(key, out List<Bundle>? hit) && hit is not null) return hit;

        using var con = db.CreateConnection();
        var rows = (await con.QueryAsync<(int Profile_ID, int Profile_Type, int? Test_ID, int DetailTest)>(@"
            SELECT h.Profile_ID, h.Profile_Type, h.Test_ID, d.Test_ID AS DetailTest
              FROM dbo.LabInvestigationProfileHeader h
              JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND ISNULL(d.IsDeleted, 0) = 0
             WHERE h.CompanyId = @companyId AND h.Status = 1 AND ISNULL(h.IsDeleted, 0) = 0
               AND (h.Effective_Start_Date IS NULL OR h.Effective_Start_Date <= GETDATE())
               AND (h.Effective_End_Date IS NULL OR h.Effective_End_Date >= CAST(GETDATE() AS date))", new { companyId })).ToList();

        var profileTests = rows.Where(r => r.Profile_Type == 1 && r.Test_ID.HasValue)
            .GroupBy(r => r.Test_ID!.Value).ToDictionary(g => g.Key, g => g.Select(r => r.DetailTest).ToHashSet());

        var bundles = new List<Bundle>();
        foreach (var g in rows.GroupBy(r => r.Profile_ID))
        {
            var first = g.First();
            var bundleKey = first.Profile_Type == 2 ? "P_" + first.Profile_ID : first.Test_ID is int t ? "I_" + t : null;
            if (bundleKey is null) continue;
            var tests = new HashSet<int>();
            foreach (var r in g)
            {
                tests.Add(r.DetailTest);
                if (profileTests.TryGetValue(r.DetailTest, out var inner)) tests.UnionWith(inner);   // a profile inside a package
            }
            bundles.Add(new Bundle(bundleKey, tests));
        }
        cache.Set(key, bundles, TimeSpan.FromMinutes(30));
        return bundles;
    }
}
