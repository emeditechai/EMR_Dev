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

var config = new ConfigurationBuilder()
    .AddJsonFile(Path.Combine(root, "EMR.Api", "appsettings.json"), optional: false)
    .AddInMemoryCollection(new Dictionary<string, string?> { ["HelpAssistant:DryRun"] = "true", ["HelpAssistant:AnthropicApiKey"] = "" })
    .Build();
config.DecryptConnectionStrings();

var services = new ServiceCollection().AddLogging(b => b.AddSimpleConsole().SetMinimumLevel(LogLevel.Warning)).AddMemoryCache().AddHttpClient().BuildServiceProvider();
var help = new HelpService(new DbConnectionFactory(config), services.GetRequiredService<IMemoryCache>(), services.GetRequiredService<IHttpClientFactory>(),
                           config, services.GetRequiredService<ILogger<HelpService>>());

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

sealed class Case
{
    public string Q { get; set; } = "";
    public string? Page { get; set; }
    public List<string> Expect { get; set; } = [];
}
