// Ask eMedi evaluation (local engine): dotnet run --project Tools/HelpEval [-- --file holdout.json --company 1 --show-all]
// questions.json = the tuning set; holdout.json = questions never tuned against (the honest score).
// Each question in questions.json lists the answers that are right ("expect": article / page codes; a code may end in * to
// accept a prefix). Top-1 = the answer given is right; Top-3 = right answer is the answer or one of the first two related links.
using System.Text.Json;
using EMR.Api.Data;
using EMR.Api.Models;
using EMR.Api.Services;
using EMR.Shared.Security;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

var root = FindRoot();
var company = args.SkipWhile(a => a != "--company").Skip(1).Select(int.Parse).FirstOrDefault(1);
var showAll = args.Contains("--show-all");
var file = args.SkipWhile(a => a != "--file").Skip(1).FirstOrDefault() ?? "questions.json";

if (args.Contains("--data"))
{
    // live-data question understanding (no database needed)
    var dq = JsonSerializer.Deserialize<List<DataCase>>(File.ReadAllText(Path.Combine(root, "Tools", "HelpEval", "data-questions.json")),
                                                        new JsonSerializerOptions { PropertyNameCaseInsensitive = true, ReadCommentHandling = JsonCommentHandling.Skip })!;
    var ok = 0;
    foreach (var c in dq)
    {
        var u = HelpData.Understand(c.Q, new DateTime(2026, 11, 27));
        var good = u.Kind == c.Kind && (c.Modules is null || u.Modules == c.Modules) && (c.Period is null || u.PeriodLabel == c.Period);
        if (good) ok++;
        Console.WriteLine($"{(good ? "  ok " : " MISS")} | {c.Q,-48} | got {u.Kind} {u.Modules} {u.PeriodLabel} | want {c.Kind} {c.Modules} {c.Period}");
    }
    Console.WriteLine($"\n{dq.Count} data questions · understood {ok} ({100.0 * ok / dq.Count:0}%)");
    return;
}

var config = new ConfigurationBuilder()
    .AddJsonFile(Path.Combine(root, "EMR.Api", "appsettings.json"), optional: false)
    .AddInMemoryCollection(new Dictionary<string, string?> { ["HelpAssistant:DryRun"] = "true", ["HelpAssistant:AnthropicApiKey"] = "" })
    .Build();
config.DecryptConnectionStrings();

var services = new ServiceCollection().AddLogging(b => b.AddSimpleConsole().SetMinimumLevel(LogLevel.Warning)).AddMemoryCache().AddHttpClient().BuildServiceProvider();
var help = new HelpService(new DbConnectionFactory(config), services.GetRequiredService<IMemoryCache>(), services.GetRequiredService<IHttpClientFactory>(),
                           config, services.GetRequiredService<ILogger<HelpService>>());

// one question answered against the database with every data scope (as a Super Admin): -- --ask "is there any cancelled bill today"
if (args.SkipWhile(a => a != "--ask").Skip(1).FirstOrDefault() is { } ask)
{
    var ans = await help.AskAsync(new HelpAskRequest { CompanyId = company, Question = ask, DataScopes = ["LAB", "OPD", "SAMPLES", "PATIENTS", "IPD", "PHARMACY"] });
    Console.WriteLine($"{ans.Kind} {ans.Code} | {ans.Title}\n{ans.Text}");
    if (ans.Data is { } dv)
    {
        if (dv.Columns.Count > 0) Console.WriteLine(string.Join(" | ", dv.Columns));
        foreach (var row in dv.Rows) Console.WriteLine(string.Join(" | ", row.Cells));
        if (dv.Note is not null) Console.WriteLine(dv.Note);
    }
    return;
}

// every menu screen: "where is <screen>" and "how do I use <screen>" must lead to that screen (its page, a guide or
// workflow that names it, or the first two related links): -- --pages
if (args.Contains("--pages"))
{
    using var con = new DbConnectionFactory(config).CreateConnection();
    using var grid = await Dapper.SqlMapper.QueryMultipleAsync(con, "dbo.usp_Help_Catalog", new { CompanyId = company }, commandType: System.Data.CommandType.StoredProcedure);
    await grid.ReadAsync();
    var pages = (await grid.ReadAsync<HelpPageRow>()).GroupBy(x => x.PageCode).Select(g => g.First()).ToList();
    int pass = 0, strict = 0, total = 0;
    var bad = new List<string>();
    foreach (var pg in pages)
        foreach (var form in new[] { $"where is {pg.Title}", $"how do i use {pg.Title}" })
        {
            total++;
            var ans = await help.AskAsync(new HelpAskRequest { CompanyId = company, Question = form });
            bool Leads(string? code) => code is not null && (string.Equals(code, "PAGE:" + pg.PageCode, StringComparison.OrdinalIgnoreCase)
                                                              || string.Equals(code, pg.PageCode, StringComparison.OrdinalIgnoreCase));
            var good = ans.Found && (Leads(ans.Code) || ans.Pages.Any(x => Leads(x.Code)) || ans.Related.Take(2).Any(x => Leads(x.Code)));
            var main = ans.Found && (Leads(ans.Code) || ans.Pages.Any(x => Leads(x.Code)));
            if (good) pass++;
            if (main) strict++; else bad.Add($"{(good ? " rel " : " MISS")} | {form,-70} | got {ans.Code} ({ans.Title})");
        }
    bad.ForEach(Console.WriteLine);
    Console.WriteLine($"\n{pages.Count} screens, {total} questions · main answer {strict} ({100.0 * strict / total:0}%) · incl. related {pass} ({100.0 * pass / total:0}%)");
    return;
}

var cases = JsonSerializer.Deserialize<List<Case>>(File.ReadAllText(Path.Combine(root, "Tools", "HelpEval", file)),
                                                   new JsonSerializerOptions { PropertyNameCaseInsensitive = true, ReadCommentHandling = JsonCommentHandling.Skip })!;
int top1 = 0, top3 = 0, found = 0;
var sw = System.Diagnostics.Stopwatch.StartNew();
await help.AskAsync(new HelpAskRequest { CompanyId = company, Question = "warm up" });   // builds the catalog and trains the models once
sw.Restart();
var misses = new List<string>();
foreach (var c in cases)
{
    var a = await help.AskAsync(new HelpAskRequest { CompanyId = company, Question = c.Q, PageCode = c.Page });
    bool Ok(string? code) => code is not null && c.Expect.Any(e => e.EndsWith('*') ? code.StartsWith(e[..^1], StringComparison.OrdinalIgnoreCase)
                                                                                  : string.Equals(code, e, StringComparison.OrdinalIgnoreCase));
    var got = a.Code ?? a.Workflow?.Code;
    var ok1 = a.Found && (Ok(a.Code) || Ok(a.Workflow?.Code));
    var ok3 = ok1 || (a.Found && a.Related.Take(2).Any(r => Ok(r.Code))) || a.Pages.Take(2).Any(p => Ok("PAGE:" + p.Code) || Ok(p.Code));
    if (a.Found) found++;
    if (ok1) top1++;
    if (ok3) top3++;
    if (!ok1 || showAll)
        misses.Add($"{(ok1 ? "  ok " : ok3 ? " top3" : " MISS")} | {c.Q,-58} | got {got ?? "-",-40} ({a.Confidence:0.00}, {a.Intent}) | want {string.Join(" / ", c.Expect)}");
}
var ms = sw.ElapsedMilliseconds;
misses.ForEach(Console.WriteLine);
Console.WriteLine($"\n{cases.Count} questions · Top-1 {Pct(top1)} · Top-3 {Pct(top3)} · answered {Pct(found)} · {ms / Math.Max(1, cases.Count)} ms per question");
string Pct(int n) => $"{n} ({100.0 * n / cases.Count:0}%)";

static string FindRoot()
{
    var d = new DirectoryInfo(AppContext.BaseDirectory);
    while (d is not null && !File.Exists(Path.Combine(d.FullName, "EMR.Api", "EMR.Api.csproj"))) d = d.Parent;
    return d?.FullName ?? Directory.GetCurrentDirectory();
}

sealed class DataCase
{
    public string Q { get; set; } = "";
    public string Kind { get; set; } = "";
    public string? Modules { get; set; }
    public string? Period { get; set; }
}

sealed class Case
{
    public string Q { get; set; } = "";
    public string? Page { get; set; }
    public List<string> Expect { get; set; } = [];
}
