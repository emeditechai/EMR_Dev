using System.Data;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using Microsoft.Extensions.Caching.Memory;

namespace EMR.Api.Services;

/// <summary>Utility > Help Center (SQLScripts/2300): the user guide, help for every page and the Help Assistant.</summary>
public interface IHelpService
{
    Task<HelpHomeView> HomeAsync(int companyId);
    Task<HelpModuleView?> ModuleAsync(int companyId, string module);
    Task<HelpArticleView?> ArticleAsync(int companyId, string code);
    Task<HelpPageView?> PageAsync(int companyId, string? pageCode, string? controller, string? action);
    Task<HelpAnswer> AskAsync(HelpAskRequest request);
    Task FeedbackAsync(HelpFeedbackRequest request);
    Task<HelpFeedbackList> FeedbackListAsync(int companyId);
    Task<HelpLearningStats> LearningStatsAsync(int companyId);
    Task TeachAsync(HelpTeachRequest request);
    Task<bool> ForgetAsync(int companyId, int learnedId, int? userId);
    /// <summary>Help Insights: questions answered weakly (SQLScripts/2321) and the last nightly learning pass.</summary>
    Task<HelpGapsView> GapsAsync(int companyId);
    /// <summary>The nightly learning pass (SQLScripts/2321); the catalogs (and their ML.NET models) are rebuilt after it.</summary>
    Task<(int Promoted, int Demoted)> LearnNightlyAsync();
}

public partial class HelpService(IDbConnectionFactory connectionFactory, IMemoryCache cache, IHttpClientFactory httpFactory,
                                 IConfiguration config, ILogger<HelpService> logger) : IHelpService
{
    private const CommandType Sp = CommandType.StoredProcedure;

    // ── the catalog (cached 10 minutes per company) ─────────────────────────────────────────────────────────────

    private sealed class Body
    {
        public List<string> Steps { get; set; } = [];
        public List<string> Prereq { get; set; } = [];
        public List<string> Tips { get; set; } = [];
        public List<string> Next { get; set; } = [];
        public List<string> Menus { get; set; } = [];
        public string? Icon { get; set; }
        public List<SetupItem> Setup { get; set; } = [];
        /// <summary>A workflow's steps in the order the work happens (Kind FLOW).</summary>
        public List<FlowStep> Flow { get; set; } = [];
        /// <summary>An everyday workflow (answers "what next" by default); special ones need the question to point to them.</summary>
        public bool Primary { get; set; }
    }
    private sealed class SetupItem { public string Page { get; set; } = ""; public string Why { get; set; } = ""; }
    private sealed class FlowStep
    {
        public string Page { get; set; } = "";
        public string Title { get; set; } = "";
        public string Do { get; set; } = "";
        public string? Article { get; set; }
        public bool Optional { get; set; }
        public string? When { get; set; }
    }

    private sealed class Article
    {
        public HelpArticleRow Row { get; init; } = new();
        public Body Body { get; init; } = new();
        public List<string> Pages { get; init; } = [];
    }

    private sealed class Catalog
    {
        public List<HelpMenuRow> Menus { get; init; } = [];
        public Dictionary<string, HelpPageRow> Pages { get; init; } = [];
        public ILookup<string, string> Controls { get; init; } = Array.Empty<HelpControlRow>().ToLookup(c => c.PageCode, c => c.Title);
        public List<Article> Articles { get; init; } = [];
        public Dictionary<string, Article> ByCode { get; init; } = [];
        public Dictionary<string, string> MenuModule { get; init; } = [];   // menu code -> module code
        public Index Search { get; init; } = new();
        /// <summary>ML.NET classifier: which help topic / screen a question is about.</summary>
        public HelpTextClassifier? Topics { get; set; }
        public List<Article> Flows { get; init; } = [];
        // ── learned from use (SQLScripts/2301) ──
        public List<HelpLearnedRow> Learned { get; init; } = [];
        /// <summary>ML.NET classifier: what the user wants (built-in sentences + learned ones).</summary>
        public HelpTextClassifier? Intents { get; set; }
        /// <summary>Questions with a confirmed answer: question key -> topic (Admin: taught by an administrator).</summary>
        public Dictionary<string, (string Target, bool Admin)> Memory { get; } = new(StringComparer.OrdinalIgnoreCase);
        /// <summary>Questions whose intent an administrator set.</summary>
        public Dictionary<string, string> MemoryIntent { get; } = new(StringComparer.OrdinalIgnoreCase);
        /// <summary>"question key|topic" pairs users rejected: that topic is pushed down for that question.</summary>
        public HashSet<string> Rejected { get; } = new(StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>The weight of a learned row from its votes: confirmed answers count, rejected ones do not.</summary>
    private static double Net(HelpLearnedRow l) => l.UpVotes + 0.5 * l.Clicks - 1.5 * l.DownVotes;

    private static bool TargetExists(Catalog c, string? code) =>
        code is not null && (code.StartsWith("PAGE:", StringComparison.OrdinalIgnoreCase) ? c.Pages.ContainsKey(code[5..]) : c.ByCode.ContainsKey(code));

    private static void BuildMemory(Catalog c)
    {
        foreach (var g in c.Learned.Where(l => TargetExists(c, l.TargetCode)).GroupBy(l => l.QuestionKey, StringComparer.OrdinalIgnoreCase))
        {
            var admin = g.FirstOrDefault(l => l.Source == "ADMIN");
            if (admin is not null) c.Memory[g.Key] = (admin.TargetCode!, true);
            // confirmed by 2+ different users (the nightly learning pass, SQLScripts/2321)
            else if (g.Where(l => l.Source == "AUTO").OrderByDescending(Net).FirstOrDefault() is { } auto) c.Memory[g.Key] = (auto.TargetCode!, false);
            else if (g.Where(l => Net(l) >= 2).OrderByDescending(Net).FirstOrDefault() is { } best) c.Memory[g.Key] = (best.TargetCode!, false);
            foreach (var bad in g.Where(l => l.Source != "ADMIN" && l.DownVotes - l.UpVotes >= 2)) c.Rejected.Add(g.Key + "|" + bad.TargetCode);
        }
        foreach (var l in c.Learned.Where(l => l.Source == "ADMIN" && l.Intent is not null)) c.MemoryIntent[l.QuestionKey] = l.Intent!;
    }

    private static double Jaccard(HashSet<string> a, HashSet<string> b) => a.Count == 0 || b.Count == 0 ? 0 : (double)a.Intersect(b).Count() / a.Union(b).Count();

    /// <summary>A question's key: its words normalised and stemmed, without filler words ("How do I cancel a LAB bill?" -> "cancel lab bill").</summary>
    private static string QuestionKey(string? question)
    {
        var key = string.Join(' ', Tokens(question).Distinct());
        return key.Length > 400 ? key[..400] : key;
    }

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private static string CatalogKey(int companyId) => $"help:catalog:{companyId}";

    private async Task<Catalog> CatalogAsync(int companyId) =>
        (await cache.GetOrCreateAsync(CatalogKey(companyId), async e =>
        {
            e.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(10);
            using var db = connectionFactory.CreateConnection();
            using var multi = await db.QueryMultipleAsync("dbo.usp_Help_Catalog", new { CompanyId = companyId }, commandType: Sp);
            var menus = (await multi.ReadAsync<HelpMenuRow>()).ToList();
            var pages = (await multi.ReadAsync<HelpPageRow>()).GroupBy(p => p.PageCode).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
            var controls = (await multi.ReadAsync<HelpControlRow>()).ToLookup(c => c.PageCode, c => c.Title, StringComparer.OrdinalIgnoreCase);
            var articles = (await multi.ReadAsync<HelpArticleRow>()).Select(r => new Article
            {
                Row = r,
                Body = Parse(r.BodyJson),
                Pages = (r.PageCodes ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList()
            }).ToList();

            // which module a menu belongs to: its own code or the nearest parent listed by a module overview
            var moduleOfMenu = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var m in articles.Where(a => a.Row.Kind == "MODULE"))
                foreach (var menu in m.Body.Menus) moduleOfMenu[menu] = m.Row.Module;
            var byId = menus.ToDictionary(m => m.MenuId);
            var menuModule = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var m in menus)
            {
                var cur = m;
                for (var i = 0; i < 6 && cur is not null; i++)
                {
                    if (moduleOfMenu.TryGetValue(cur.MenuCode, out var mod)) { menuModule[m.MenuCode] = mod; break; }
                    cur = cur.ParentMenuId is int p && byId.TryGetValue(p, out var parent) ? parent : null;
                }
            }

            var c = new Catalog
            {
                Menus = menus, Pages = pages, Controls = controls, Articles = articles,
                ByCode = articles.ToDictionary(a => a.Row.Code, StringComparer.OrdinalIgnoreCase), MenuModule = menuModule,
                Flows = articles.Where(a => a.Row.Kind == "FLOW" && a.Body.Flow.Count > 0).ToList()
            };
            BuildIndex(c);
            try { c.Learned.AddRange(await db.QueryAsync<HelpLearnedRow>("dbo.usp_Help_Learned_List", new { CompanyId = companyId }, commandType: Sp)); }
            catch (Exception ex) { logger.LogWarning(ex, "Help assistant: learned answers could not be read (is SQLScripts/2301 applied?)."); }
            BuildMemory(c);
            c.Topics = TopicModel(c);
            c.Intents = IntentModel(c);
            return c;
        }))!;

    private static Body Parse(string json)
    {
        try { return JsonSerializer.Deserialize<Body>(json, Json) ?? new Body(); } catch (JsonException) { return new Body(); }
    }

    // ── links and paths ──────────────────────────────────────────────────────────────────────────────────────

    private static string? Url(HelpPageRow p) =>
        // always with the action: the app's default action is Login, so "/Controller" alone does not open the screen
        string.IsNullOrWhiteSpace(p.Controller) ? null : "/" + p.Controller + "/" + (string.IsNullOrWhiteSpace(p.Action) ? "Index" : p.Action);

    private static string PathOf(Catalog c, HelpPageRow p)
    {
        var names = new List<string> { p.Title };
        var byCode = c.Menus.ToDictionary(m => m.MenuCode, StringComparer.OrdinalIgnoreCase);
        var byId = c.Menus.ToDictionary(m => m.MenuId);
        var cur = byCode.TryGetValue(p.MenuCode, out var m0) ? m0 : null;
        for (var i = 0; i < 6 && cur is not null; i++)
        {
            names.Insert(0, cur.Title);
            cur = cur.ParentMenuId is int pid && byId.TryGetValue(pid, out var parent) ? parent : null;
        }
        return string.Join(" › ", names);
    }

    private static HelpLink? PageLink(Catalog c, string code, string? note = null) =>
        c.Pages.TryGetValue(code, out var p) ? new HelpLink { Code = p.PageCode, Title = p.Title, Url = Url(p), Path = PathOf(c, p), Note = note } : null;

    private static HelpLink ArticleLink(Article a) => new() { Code = a.Row.Code, Title = a.Row.Title, Note = a.Row.Kind, Summary = a.Row.Summary };

    private string ModuleTitle(Catalog c, string module) =>
        c.ByCode.TryGetValue("MOD." + module, out var m) ? m.Row.Title : module;

    private string ModuleOf(Catalog c, HelpPageRow p) => c.MenuModule.TryGetValue(p.MenuCode, out var m) ? m : "GENERAL";

    // ── views ────────────────────────────────────────────────────────────────────────────────────────────────

    public async Task<HelpHomeView> HomeAsync(int companyId)
    {
        var c = await CatalogAsync(companyId);
        var modules = new List<HelpModuleView>();
        foreach (var m in c.Articles.Where(a => a.Row.Kind == "MODULE").OrderBy(a => a.Row.SortOrder))
            modules.Add(await ModuleCoreAsync(c, m));
        return new HelpHomeView
        {
            Modules = modules,
            QuickStart = c.Articles.Where(a => a.Row.Module == "GENERAL" && a.Row.Kind == "GUIDE").Select(ArticleLink).ToList(),
            // each workflow with its chain of steps; Note: DAILY (everyday work), WORK (other work) or SETUP
            Workflows = c.Flows.Select(f => new HelpLink
            {
                Code = f.Row.Code, Title = f.Row.Title, Summary = string.Join(" → ", f.Body.Flow.Select(st => StepTitle(c, st))),
                Note = f.Row.Code.StartsWith("FLOW.SETUP.") ? "SETUP" : f.Body.Primary ? "DAILY" : "WORK"
            }).ToList(),
            Faqs = c.Articles.Where(a => a.Row.Kind == "FAQ").Select(ArticleLink).ToList(),
            Troubles = c.Articles.Where(a => a.Row.Kind == "TROUBLE").Select(ArticleLink).ToList(),
            PageCount = c.Pages.Count,
            ArticleCount = c.Articles.Count(a => a.Row.Kind != "MODULE")
        };
    }

    public async Task<HelpModuleView?> ModuleAsync(int companyId, string module)
    {
        var c = await CatalogAsync(companyId);
        return c.ByCode.TryGetValue("MOD." + module, out var m) ? await ModuleCoreAsync(c, m) : null;
    }

    private Task<HelpModuleView> ModuleCoreAsync(Catalog c, Article m)
    {
        var code = m.Row.Module;
        var pages = c.Pages.Values.Where(p => ModuleOf(c, p) == code).ToList();
        var menuTitles = c.Menus.ToDictionary(x => x.MenuCode, x => x.Title, StringComparer.OrdinalIgnoreCase);
        var menuSort = c.Menus.ToDictionary(x => x.MenuCode, x => x.SortOrder, StringComparer.OrdinalIgnoreCase);
        return Task.FromResult(new HelpModuleView
        {
            Code = code, Title = m.Row.Title, Summary = m.Row.Summary, Icon = m.Body.Icon ?? "bi-book",
            Setup = m.Body.Setup.Select(s => PageLink(c, s.Page, s.Why)).OfType<HelpLink>().ToList(),
            Workflows = c.Flows.Where(f => f.Row.Module == code || f.Body.Flow.Any(s => pages.Any(p => p.PageCode == s.Page) && !f.Row.Code.StartsWith("FLOW.SETUP.")))
                               .Select(ArticleLink).ToList(),
            Guides = c.Articles.Where(a => a.Row.Module == code && a.Row.Kind == "GUIDE").Select(ArticleLink).ToList(),
            Faqs = c.Articles.Where(a => a.Row.Module == code && a.Row.Kind == "FAQ").Select(ArticleLink).ToList(),
            Troubles = c.Articles.Where(a => a.Row.Module == code && a.Row.Kind == "TROUBLE").Select(ArticleLink).ToList(),
            Groups = pages.GroupBy(p => p.MenuCode).OrderBy(g => menuSort.GetValueOrDefault(g.Key))
                          .Select(g => new HelpPageGroup
                          {
                              Title = menuTitles.GetValueOrDefault(g.Key, g.Key),
                              Pages = g.OrderBy(p => p.SortOrder).Select(p => PageLink(c, p.PageCode)!).ToList()
                          }).ToList(),
            PageCount = pages.Count
        });
    }

    public async Task<HelpArticleView?> ArticleAsync(int companyId, string code)
    {
        var c = await CatalogAsync(companyId);
        return c.ByCode.TryGetValue(code, out var a) && a.Row.Kind != "MODULE" ? View(c, a) : null;
    }

    private HelpArticleView View(Catalog c, Article a) => new()
    {
        Code = a.Row.Code, Kind = a.Row.Kind, Module = a.Row.Module, ModuleTitle = ModuleTitle(c, a.Row.Module),
        Title = a.Row.Title, Summary = a.Row.Summary, Steps = a.Body.Steps, Tips = a.Body.Tips,
        Prereq = a.Body.Prereq.Select(p => PageLink(c, p)).OfType<HelpLink>().ToList(),
        Next = a.Body.Next.Select(p => PageLink(c, p)).OfType<HelpLink>().ToList(),
        Pages = a.Pages.Select(p => PageLink(c, p)).OfType<HelpLink>().ToList(),
        // articles about the same pages, then of the same module
        Related = c.Articles.Where(x => x != a && x.Row.Kind != "MODULE" && x.Pages.Intersect(a.Pages, StringComparer.OrdinalIgnoreCase).Any())
                   .Concat(c.Articles.Where(x => x != a && x.Row.Kind != "MODULE" && x.Row.Module == a.Row.Module))
                   .Distinct().Take(6).Select(ArticleLink).ToList(),
        Workflows = a.Row.Kind == "FLOW" ? [WorkflowView(c, a, -1, -1)] : WorkflowsOf(c, a.Row.Code, null)
    };

    public async Task<HelpPageView?> PageAsync(int companyId, string? pageCode, string? controller, string? action)
    {
        var c = await CatalogAsync(companyId);
        if (string.IsNullOrWhiteSpace(pageCode) && !string.IsNullOrWhiteSpace(controller))
        {
            using var db = connectionFactory.CreateConnection();
            pageCode = await db.ExecuteScalarAsync<string?>("dbo.usp_Help_PageByRoute",
                new { CompanyId = companyId, Controller = controller, Action = action ?? "Index" }, commandType: Sp);
        }
        if (string.IsNullOrWhiteSpace(pageCode) || !c.Pages.TryGetValue(pageCode, out var p)) return null;

        var module = ModuleOf(c, p);
        var guides = c.Articles.Where(a => a.Row.Kind == "GUIDE" && a.Pages.Contains(p.PageCode, StringComparer.OrdinalIgnoreCase)).ToList();
        var before = new List<HelpLink>();
        var after = new List<HelpLink>();
        // the guides' own prerequisites first, then the module's setup order
        foreach (var g in guides) before.AddRange(g.Body.Prereq.Select(x => PageLink(c, x)).OfType<HelpLink>());
        // a page in any module's setup order (e.g. Ward Master in IPD): the steps before it
        var inSetup = false;
        foreach (var m in c.Articles.Where(a => a.Row.Kind == "MODULE"))
        {
            var idx = m.Body.Setup.FindIndex(x => x.Page.Equals(p.PageCode, StringComparison.OrdinalIgnoreCase));
            if (idx < 0) continue;
            inSetup = true;
            before.AddRange(m.Body.Setup.Take(idx).Select(x => PageLink(c, x.Page, x.Why)).OfType<HelpLink>());
        }
        // a working screen of a module: the module's whole setup must be in place
        if (!inSetup && c.ByCode.TryGetValue("MOD." + module, out var mod)
            && !p.MenuCode.StartsWith("MASTER", StringComparison.OrdinalIgnoreCase) && module is not ("REPORTS" or "GENERAL" or "SETTINGS"))
            before.AddRange(mod.Body.Setup.Select(x => PageLink(c, x.Page, x.Why)).OfType<HelpLink>());
        foreach (var g in guides) after.AddRange(g.Body.Next.Select(x => PageLink(c, x)).OfType<HelpLink>());
        before = before.Where(l => l.Code != p.PageCode).GroupBy(l => l.Code).Select(g => g.First()).ToList();
        after = after.Where(l => l.Code != p.PageCode).GroupBy(l => l.Code).Select(g => g.First()).ToList();

        var path = PathOf(c, p);
        return new HelpPageView
        {
            PageCode = p.PageCode, Title = p.Title, Path = path, Url = Url(p), Module = module, ModuleTitle = ModuleTitle(c, module),
            Actions = c.Controls[p.PageCode].Distinct().ToList(),
            Before = before, After = after,
            Guides = guides.Select(g => View(c, g)).ToList(),
            HasWrittenGuide = guides.Count > 0,
            Workflows = WorkflowsOf(c, null, p.PageCode),
            GeneralSteps = guides.Count > 0 ? [] : GeneralSteps(c, p, path, module),
            Faqs = c.Articles.Where(a => a.Row.Kind == "FAQ" && (a.Pages.Contains(p.PageCode, StringComparer.OrdinalIgnoreCase) || a.Row.Module == module))
                    .OrderByDescending(a => a.Pages.Contains(p.PageCode, StringComparer.OrdinalIgnoreCase)).Take(6).Select(ArticleLink).ToList(),
            Troubles = c.Articles.Where(a => a.Row.Kind == "TROUBLE" && (a.Pages.Contains(p.PageCode, StringComparer.OrdinalIgnoreCase) || a.Row.Module == module))
                        .OrderByDescending(a => a.Pages.Contains(p.PageCode, StringComparer.OrdinalIgnoreCase)).Take(5).Select(ArticleLink).ToList()
        };
    }

    /// <summary>Steps for a page that has no written guide, from what kind of page it is and its actions.</summary>
    private List<string> GeneralSteps(Catalog c, HelpPageRow p, string path, string module)
    {
        var actions = c.Controls[p.PageCode].Select(a => a.ToLowerInvariant()).ToList();
        bool Has(params string[] words) => actions.Any(a => words.Any(a.Contains));
        var steps = new List<string> { $"Open {path} from the top menu." };
        if (module == "REPORTS" || p.MenuCode.StartsWith("REPORTS", StringComparison.OrdinalIgnoreCase))
        {
            steps.Add("Choose the period (quick buttons or your own dates) and the filters, then click Apply / Show Report.");
            steps.Add("Read the summary, open the detail (click a row or tab to drill down).");
            steps.Add("Export with Excel or PDF, or Print, to share or file the report.");
            return steps;
        }
        if (p.MenuCode.StartsWith("MASTER", StringComparison.OrdinalIgnoreCase) || p.MenuCode.StartsWith("QUALITY.MASTERS", StringComparison.OrdinalIgnoreCase))
        {
            steps.Add("The list shows the existing records - search or filter to find one.");
            if (Has("add", "create", "new")) steps.Add("Click Add / New, fill the required fields (marked *) and Save.");
            if (Has("edit", "update", "modify")) steps.Add("To change a record click Edit, correct it and Save.");
            if (Has("delete", "deactivate", "status", "inactive")) steps.Add("Records no longer used can be made inactive (or deleted when nothing uses them).");
            steps.Add("Some changes need approval (Settings › Approval Matrix); the approver is notified.");
            return steps;
        }
        steps.Add("Use the filters / search at the top to find what you need.");
        foreach (var a in c.Controls[p.PageCode].Distinct().Take(6)) steps.Add($"{a} - available if your role allows it.");
        steps.Add("Save your work; the action is recorded in the audit log.");
        return steps;
    }

    // ── the Help Assistant ───────────────────────────────────────────────────────────────────────────────────
    // Two rankings are blended: ML.NET (a text classifier trained on the help content: which topic / screen a
    // question is about) and BM25 keyword search (title, keywords, summary, steps; synonyms and typo tolerance).
    // A second ML.NET model reads what the user wants (how-to, next step, before, whole workflow, problem, where);
    // "next / before / process" questions are answered from the workflows - the order the work really happens in.
    // With HelpAssistant:AnthropicApiKey set, Claude writes the answer text from the matched content only.

    private sealed class Doc
    {
        public string Key { get; init; } = "";      // article code, or "PAGE:" + page code
        public Article? Article { get; init; }
        public HelpPageRow? Page { get; init; }
        public Dictionary<string, double> Tf { get; init; } = [];
        public double Length { get; init; }
    }

    private sealed class Index
    {
        public List<Doc> Docs { get; set; } = [];
        public Dictionary<string, int> Df { get; set; } = [];
        public HashSet<string> Vocab { get; set; } = [];
        public double AvgLength { get; set; } = 1;
    }

    private static readonly HashSet<string> Stop = new(StringComparer.OrdinalIgnoreCase)
    {
        "a","an","the","is","are","was","were","be","to","of","in","on","for","and","or","i","my","me","we","our","you","your","it","its","this",
        "that","with","at","by","from","as","do","does","did","can","cant","cannot","could","should","how","what","why","when","where","which",
        "who","not","no","yes","please","get","got","there","here","have","has","had","will","would","into","up","out","any","some","all","so","if"
    };

    // words people use -> words the help uses
    private static readonly Dictionary<string, string[]> Synonyms = new(StringComparer.OrdinalIgnoreCase)
    {
        ["invoice"] = ["bill"], ["receipt"] = ["bill", "payment"], ["billing"] = ["bill"], ["specimen"] = ["sample"], ["blood"] = ["sample"],
        ["tube"] = ["sample", "barcode"], ["investigation"] = ["test"], ["result"] = ["report"], ["results"] = ["report"],
        ["authorise"] = ["approve"], ["authorize"] = ["approve"], ["signoff"] = ["approve"], ["sign"] = ["approve", "sign"],
        ["unauthorise"] = ["unapprove"], ["unauthorize"] = ["unapprove"], ["amend"] = ["unapprove", "correct"], ["modify"] = ["edit", "correct"],
        ["refund"] = ["cancel", "refund"], ["delete"] = ["cancel", "delete"], ["void"] = ["cancel"], ["login"] = ["sign"], ["logon"] = ["sign"],
        ["signin"] = ["sign"], ["pwd"] = ["password"], ["pass"] = ["password"], ["mail"] = ["email"], ["e-mail"] = ["email"],
        ["sms"] = ["whatsapp"], ["consultant"] = ["doctor"], ["dr"] = ["doctor"], ["physician"] = ["doctor"], ["customer"] = ["patient"],
        ["client"] = ["patient"], ["appointment"] = ["booking", "book"], ["visit"] = ["booking", "visit"], ["price"] = ["rate", "price"],
        ["cost"] = ["rate", "cost"], ["mrp"] = ["rate"], ["tariff"] = ["rate", "tariff"], ["centre"] = ["branch"], ["center"] = ["branch"],
        ["clinic"] = ["branch"], ["lab"] = ["lab"], ["pathology"] = ["lab"], ["collection"] = ["collect"], ["collected"] = ["collect"],
        ["missing"] = ["not", "appear"], ["visible"] = ["appear", "see"], ["show"] = ["appear", "see"], ["showing"] = ["appear"],
        ["error"] = ["error", "fail"], ["failed"] = ["fail"], ["failing"] = ["fail"], ["slow"] = ["slow"], ["hang"] = ["slow"],
        ["print"] = ["print"], ["printer"] = ["print"], ["permission"] = ["permission", "access"], ["rights"] = ["permission"],
        ["role"] = ["role", "permission"], ["franchisee"] = ["franchise"], ["partner"] = ["b2b", "franchise", "corporate"],
        ["walkin"] = ["b2c"], ["opd"] = ["opd"], ["ipd"] = ["ipd"], ["admission"] = ["ipd"], ["qc"] = ["iqc", "quality"],
        ["newsletter"] = ["campaign"], ["bulk"] = ["campaign"], ["promotion"] = ["campaign"], ["template"] = ["template"],
        ["ai"] = ["ai"], ["ocr"] = ["scan"], ["aadhar"] = ["aadhaar"], ["id"] = ["id"], ["dues"] = ["due", "outstanding"],
        ["pending"] = ["pending", "due"], ["balance"] = ["due", "balance"], ["outstanding"] = ["due", "outstanding"],
        ["unpaid"] = ["due"], ["take"] = ["collect"], ["receive"] = ["collect"], ["accept"] = ["collect"], ["reprint"] = ["print"],
        ["duplicate"] = ["print", "duplicate"], ["copy"] = ["print"], ["closing"] = ["close"], ["eod"] = ["close", "day"], ["cash"] = ["cash", "collect"]
    };

    private static string Stem(string w)
    {
        if (w.Length > 5 && w.EndsWith("ing")) w = w[..^3];
        else if (w.Length > 4 && w.EndsWith("ied")) w = w[..^3] + "y";
        else if (w.Length > 4 && w.EndsWith("ed")) w = w[..^2];
        else if (w.Length > 4 && w.EndsWith("es") && !w.EndsWith("ses")) w = w[..^2];
        else if (w.Length > 3 && w.EndsWith('s') && !w.EndsWith("ss")) w = w[..^1];
        // collection -> collect, approval -> approv, validation -> valid: the noun meets its verb
        if (w.Length > 7 && w.EndsWith("ation")) w = w[..^5];
        else if (w.Length > 6 && w.EndsWith("ion")) w = w[..^3];
        else if (w.Length > 6 && w.EndsWith("al")) w = w[..^2];
        else if (w.Length > 6 && w.EndsWith("ate")) w = w[..^3];
        // approve / approving / approved -> approv: a final e is dropped so every form meets
        if (w.Length > 4 && w.EndsWith('e')) w = w[..^1];
        return w;
    }

    private static IEnumerable<string> Tokens(string? text) =>
        WordRegex().Matches(HelpText.Normalize(text)).Select(m => m.Value).Where(w => w.Length > 1 && !Stop.Contains(w)).Select(Stem);

    private static void Add(Dictionary<string, double> tf, string? text, double weight)
    {
        foreach (var t in Tokens(text)) tf[t] = tf.GetValueOrDefault(t) + weight;
    }

    private static void BuildIndex(Catalog c)
    {
        var docs = new List<Doc>();
        foreach (var a in c.Articles.Where(a => a.Row.Kind != "MODULE"))
        {
            var tf = new Dictionary<string, double>();
            Add(tf, a.Row.Title, 3); Add(tf, a.Row.Keywords, 2.5); Add(tf, a.Row.Summary, 1.5);
            Add(tf, string.Join(" ", a.Body.Steps), 1); Add(tf, string.Join(" ", a.Body.Tips), 0.7);
            Add(tf, string.Join(" ", a.Pages.Select(p => c.Pages.TryGetValue(p, out var pg) ? pg.Title : "")), 1.2);
            docs.Add(new Doc { Key = a.Row.Code, Article = a, Tf = tf, Length = tf.Values.Sum() });
        }
        foreach (var p in c.Pages.Values)
        {
            var tf = new Dictionary<string, double>();
            Add(tf, p.Title, 3); Add(tf, PathOf(c, p), 1); Add(tf, string.Join(" ", c.Controls[p.PageCode]), 0.8);
            docs.Add(new Doc { Key = "PAGE:" + p.PageCode, Page = p, Tf = tf, Length = tf.Values.Sum() });
        }
        var df = new Dictionary<string, int>();
        foreach (var d in docs) foreach (var t in d.Tf.Keys) df[t] = df.GetValueOrDefault(t) + 1;
        c.Search.Docs = docs; c.Search.Df = df; c.Search.Vocab = [.. df.Keys];
        c.Search.AvgLength = docs.Count == 0 ? 1 : docs.Average(d => d.Length);
    }

    /// <summary>The question's words, corrected for typos against the help vocabulary, with synonyms (weighted lower).</summary>
    private static Dictionary<string, double> QueryTerms(Index ix, string question)
    {
        var terms = new Dictionary<string, double>();
        foreach (var raw in WordRegex().Matches(HelpText.Normalize(question)).Select(m => m.Value).Where(w => w.Length > 1 && !Stop.Contains(w)))
        {
            var t = Stem(raw);
            if (!ix.Vocab.Contains(t) && t.Length >= 4)
            {
                var max = t.Length >= 7 ? 2 : 1;
                var best = ix.Vocab.Where(v => Math.Abs(v.Length - t.Length) <= max).Select(v => (v, d: Distance(v, t, max))).Where(x => x.d <= max)
                                   .OrderBy(x => x.d).ThenByDescending(x => ix.Df[x.v]).FirstOrDefault();
                if (best.v is not null) t = best.v;
                // two words typed together ("duecollection", "samplecollect"): both halves when each is a known word
                else if (t.Length >= 7 && Enumerable.Range(3, t.Length - 5).Select(i => (A: Stem(t[..i]), B: Stem(t[i..])))
                                                    .FirstOrDefault(x => ix.Vocab.Contains(x.A) && ix.Vocab.Contains(x.B)) is { A: not null } split)
                {
                    terms[split.A] = Math.Max(terms.GetValueOrDefault(split.A), 1);
                    t = split.B;
                }
            }
            else if (!ix.Vocab.Contains(t) && t.Length == 3)
            {
                // a short word: corrected only when exactly one known 3-letter word is one edit away (e.g. "lba" -> "lab")
                var near = ix.Vocab.Where(v => v.Length == 3 && Distance(v, t, 1) <= 1).Take(2).ToList();
                if (near.Count == 1) t = near[0];
            }
            terms[t] = Math.Max(terms.GetValueOrDefault(t), 1);
            if (Synonyms.TryGetValue(raw, out var syn) || Synonyms.TryGetValue(t, out syn))
                foreach (var s in syn.Select(Stem)) terms[s] = Math.Max(terms.GetValueOrDefault(s), 0.6);
        }
        return terms;
    }

    private static int Distance(string a, string b, int max)
    {
        var prev = Enumerable.Range(0, b.Length + 1).ToArray();
        int[]? prevPrev = null;
        for (var i = 1; i <= a.Length; i++)
        {
            var cur = new int[b.Length + 1];
            cur[0] = i;
            var rowMin = cur[0];
            for (var j = 1; j <= b.Length; j++)
            {
                cur[j] = Math.Min(Math.Min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
                // two letters swapped ("colelct") count as one edit
                if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] && prevPrev is not null) cur[j] = Math.Min(cur[j], prevPrev[j - 2] + 1);
                rowMin = Math.Min(rowMin, cur[j]);
            }
            if (rowMin > max) return max + 1;
            prevPrev = prev;
            prev = cur;
        }
        return prev[b.Length];
    }

    private static List<(Doc Doc, double Score)> Rank(Index ix, string question, string? pageCode)
    {
        var q = QueryTerms(ix, question);
        if (q.Count == 0) return [];
        const double k1 = 1.4, b = 0.75;
        var n = ix.Docs.Count;
        var results = new List<(Doc, double)>();
        foreach (var d in ix.Docs)
        {
            double score = 0;
            foreach (var (t, w) in q)
            {
                if (!d.Tf.TryGetValue(t, out var f)) continue;
                var idf = Math.Log(1 + (n - ix.Df[t] + 0.5) / (ix.Df[t] + 0.5));
                score += w * idf * f * (k1 + 1) / (f + k1 * (1 - b + b * d.Length / ix.AvgLength));
            }
            if (score <= 0) continue;
            // answers (guides, FAQs, fixes) before bare pages; a little extra for the page the user is on
            if (d.Article is not null) score *= 1.2;
            if (pageCode is not null && (d.Page?.PageCode == pageCode || (d.Article?.Pages.Contains(pageCode, StringComparer.OrdinalIgnoreCase) ?? false))) score *= 1.2;
            results.Add((d, score));
        }
        return results.OrderByDescending(r => r.Item2).ToList();
    }

    // ── ML.NET topic model ──

    /// <summary>The topic classifier trained from the help content; cached by the content, so a catalog reload does not retrain it.</summary>
    private HelpTextClassifier? TopicModel(Catalog c)
    {
        var examples = TopicExamples(c).ToList();
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
            Encoding.UTF8.GetBytes(string.Join("\n", examples.Select(e => e.Label + "|" + e.Text)))));
        try
        {
            return cache.GetOrCreate("help:ml:" + hash, e =>
            {
                e.SlidingExpiration = TimeSpan.FromHours(12);
                var sw = System.Diagnostics.Stopwatch.StartNew();
                var model = HelpTextClassifier.Train(examples);
                logger.LogInformation("Help assistant: ML.NET topic model trained on {Rows} sentences / {Classes} topics in {Ms} ms",
                    examples.Count, model.Classes, sw.ElapsedMilliseconds);
                return model;
            });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Help assistant: the ML.NET topic model could not be trained; keyword ranking only.");
            return null;
        }
    }

    /// <summary>The intent classifier: built-in sentences plus the intents learned from use; cached by its training data.</summary>
    private HelpTextClassifier? IntentModel(Catalog c)
    {
        var learned = c.Learned.Where(l => l.Intent is not null && (l.Source == "ADMIN" || l.UpVotes - l.DownVotes >= 1))
                               .SelectMany(l => Enumerable.Repeat((l.Question, l.Intent!), l.Source == "ADMIN" ? 4 : Math.Min(3, l.UpVotes - l.DownVotes)))
                               .ToList();
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(string.Join("\n", learned.Select(e => e.Item2 + "|" + e.Item1)))));
        try
        {
            return cache.GetOrCreate("help:intent:" + hash, e =>
            {
                e.SlidingExpiration = TimeSpan.FromHours(12);
                var sw = System.Diagnostics.Stopwatch.StartNew();
                var model = HelpIntent.Train(learned);
                logger.LogInformation("Help assistant: ML.NET intent model trained ({Learned} learned sentences) in {Ms} ms", learned.Count, sw.ElapsedMilliseconds);
                return model;
            });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Help assistant: the ML.NET intent model could not be trained.");
            return null;
        }
    }

    /// <summary>Training sentences for every help topic and screen, from its title, keywords, summary, steps and pages.</summary>
    private static IEnumerable<(string Text, string Label)> TopicExamples(Catalog c)
    {
        static string Head(string s, int words) => string.Join(' ', s.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(words));
        static IEnumerable<string> Windows(string? text, int size)
        {
            var w = (text ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries);
            for (var i = 0; i < w.Length; i += 2) yield return string.Join(' ', w.Skip(i).Take(size));
        }

        foreach (var a in c.Articles.Where(a => a.Row.Kind != "MODULE"))
        {
            var k = a.Row.Code;
            var t = a.Row.Title;
            yield return (t, k);
            yield return (a.Row.Kind == "TROUBLE" ? t + " not working" : "how do i " + t, k);
            yield return (a.Row.Summary, k);
            if (!string.IsNullOrWhiteSpace(a.Row.Keywords))
            {
                yield return (a.Row.Keywords, k);
                foreach (var w in Windows(a.Row.Keywords, 3)) yield return (w, k);
            }
            foreach (var st in a.Body.Steps) yield return (Head(st, 22), k);
            foreach (var pg in a.Pages.Take(4)) yield return (PageTitleOf(c, pg) + " " + Head(t, 5), k);
            // the ways people ask for a guide ("how can I ...", "steps to ...", "I want to ...")
            if (a.Row.Kind == "GUIDE")
            {
                var task = t.Split(" - ")[0].ToLowerInvariant();
                foreach (var form in GuideForms) yield return (string.Format(form, task), k);
            }
        }
        // learned from use: questions whose answer users confirmed (or an administrator taught) - the more votes, the more weight
        foreach (var l in c.Learned.Where(l => TargetExists(c, l.TargetCode)))
        {
            var weight = l.Source == "ADMIN" ? 5 : Net(l) >= 1 ? Math.Min(4, (int)Math.Ceiling(Net(l))) : 0;
            for (var i = 0; i < weight; i++) yield return (l.Question, l.TargetCode!);
        }
        foreach (var p in c.Pages.Values)
        {
            var k = "PAGE:" + p.PageCode;
            yield return (p.Title, k);
            yield return ("where is " + p.Title, k);
            yield return (PathOf(c, p), k);
            var actions = string.Join(' ', c.Controls[p.PageCode].Distinct().Take(8));
            if (actions.Length > 0) yield return (p.Title + " " + actions, k);
            // every action of the screen (the permission catalog): "how to collect payment in B2C Order List"
            foreach (var act in c.Controls[p.PageCode].Distinct())
            {
                var a = act.ToLowerInvariant();
                yield return ($"how to {a} in {p.Title}", k);
                yield return ($"{a} {p.Title}", k);
            }
        }
    }

    private static readonly string[] GuideForms =
        ["how can i {0}", "steps to {0}", "i want to {0}", "where do i {0}", "process to {0}", "{0} how", "help to {0}"];

    private static string PageTitleOf(Catalog c, string code) => c.Pages.TryGetValue(code, out var p) ? p.Title : "";

    // ── ranking: ML.NET + keywords ──

    private sealed record Hit(Doc Doc, double Score);

    private static List<Hit> Blend(Catalog c, string question, string? pageCode)
    {
        var bm = Rank(c.Search, question, pageCode).ToDictionary(x => x.Doc.Key, x => x.Score);
        var ml = c.Topics?.All(question) ?? [];
        var hits = new List<Hit>();
        foreach (var d in c.Search.Docs)
        {
            var p = ml.GetValueOrDefault(d.Key);
            var b = bm.GetValueOrDefault(d.Key);
            if (p < 0.004 && b <= 0) continue;
            // the keyword score against a fixed bar (12 = a strong match); the ML probability made comparable
            var kw = Math.Min(1, b / 12.0);
            var score = ml.Count == 0 ? kw : 0.55 * Math.Min(1, p * 3) + 0.45 * kw;
            if (d.Article is not null) score *= 1.05;   // a written answer before a bare screen
            hits.Add(new Hit(d, score));
        }
        return hits.OrderByDescending(h => h.Score).ToList();
    }

    // ── workflows ──

    // words that say what the user wants, not what it is about
    private static readonly HashSet<string> IntentWords = new(new[]
    {
        "after", "next", "step", "befor", "process", "workflow", "flow", "then", "done", "complet", "finish", "now", "go", "goe",
        "happen", "come", "previou", "first", "stage", "order", "end", "need", "requir", "prerequisit", "ready", "should", "must",
        "screen", "page", "whole", "show", "explain", "full", "entir", "do", "work", "where"
    }.Select(Stem), StringComparer.OrdinalIgnoreCase);   // stemmed the same way as the question

    private sealed record FlowMatch(Article Flow, int Index, double Score, double StepScore)
    {
        /// <summary>A close match in another workflow, offered as "or did you mean".</summary>
        public FlowMatch? Alternative { get; set; }
    }

    /// <summary>The workflow step the question talks about ("after creating a B2C bill" -> FLOW.LAB.B2C, step 1).</summary>
    private static FlowMatch? MatchStep(Catalog c, string question, List<Hit> hits, string intent, string? pageCode)
    {
        var by = hits.ToDictionary(h => h.Doc.Key, h => h.Score);
        var q = Tokens(question).Where(t => !IntentWords.Contains(t)).ToHashSet();
        double Overlap(string text) { var w = Tokens(text).ToHashSet(); return q.Count == 0 ? 0 : (double)q.Count(w.Contains) / q.Count; }

        // a module named in the question ("first step for LAB"): its workflows first
        var modules = c.Flows.Select(f => f.Row.Module).Distinct(StringComparer.OrdinalIgnoreCase)
                             .Where(m => q.Contains(Stem(m.ToLowerInvariant()))).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var onPage = pageCode is not null && c.Flows.Any(f => f.Body.Flow.Any(st => st.Page.Equals(pageCode, StringComparison.OrdinalIgnoreCase)));
        var all = new List<FlowMatch>();
        foreach (var f in c.Flows)
        {
            var flowScore = by.GetValueOrDefault(f.Row.Code);
            for (var i = 0; i < f.Body.Flow.Count; i++)
            {
                var st = f.Body.Flow[i];
                // the guide / screen the step is about (ranked by ML.NET + keywords) and the step's own words - its title and
                // screen first, the description counts less (a step that mentions "vitals" is not the vitals step)
                var anchor = Math.Max(st.Article is null ? 0 : by.GetValueOrDefault(st.Article), by.GetValueOrDefault("PAGE:" + st.Page));
                var overlap = Math.Max(Overlap(StepTitle(c, st) + " " + PageTitleOf(c, st.Page)), 0.6 * Overlap(StepTitle(c, st) + " " + st.Do + " " + PageTitleOf(c, st.Page)));
                // asked from a screen ("what do I do after this?"): the screen is the step
                var here = pageCode is not null && st.Page.Equals(pageCode, StringComparison.OrdinalIgnoreCase);
                if (q.Count == 0 && onPage && !here) continue;   // nothing else named: only the workflows of this screen
                if (here && q.Count == 0) { overlap = st.Optional ? 0.7 : 1; anchor = 1; }   // the screen's main workflow first
                else if (here) overlap += 0.15;
                var stepScore = 0.4 * anchor + 0.6 * overlap;
                // "what is the process / workflow": the workflow as a whole matters most; "next / before": the step does
                var score = (intent == HelpIntent.Flow ? flowScore + 0.3 * stepScore : stepScore + 0.25 * flowScore)
                            - (modules.Count > 0 && !modules.Contains(f.Row.Module) ? 0.15 : 0);
                all.Add(new FlowMatch(f, i, score, stepScore));
            }
        }
        if (all.Count == 0) return null;
        // among close matches the everyday workflow wins; a special one (B2B, correction, setup) only when clearly better
        var top = all.Max(m => m.Score);
        var best = all.OrderByDescending(m => m.Score).First();
        // the same screen is also a step of an everyday workflow (correction / B2B repeat the B2C steps): that one, unless
        // the question clearly points to the special workflow
        if (!best.Flow.Body.Primary
            && all.Where(m => m.Flow.Body.Primary && m.Flow.Body.Flow[m.Index].Page.Equals(best.Flow.Body.Flow[best.Index].Page, StringComparison.OrdinalIgnoreCase)
                              && m.Score >= best.Score - 0.12)
                  .OrderByDescending(m => m.Score).FirstOrDefault() is { } everyday)
            best = everyday;
        // a step that reads the same in a workflow of another kind (setup vs. daily work): offered too
        static bool Setup(FlowMatch m) => m.Flow.Row.Code.StartsWith("FLOW.SETUP.", StringComparison.OrdinalIgnoreCase);
        best.Alternative = all.Where(m => Setup(m) != Setup(best) && m.Score >= best.Score - 0.25
                                         && StepTitle(c, m.Flow.Body.Flow[m.Index]) != StepTitle(c, best.Flow.Body.Flow[best.Index]))
                              .OrderByDescending(m => m.Score).FirstOrDefault();
        return best;
    }

    private static string StepTitle(Catalog c, FlowStep s) => s.Title.Length > 0 ? s.Title : PageTitleOf(c, s.Page);

    private static HelpWorkflowView WorkflowView(Catalog c, Article f, int current, int highlight) => new()
    {
        Code = f.Row.Code, Title = f.Row.Title, Summary = f.Row.Summary, Current = current, Highlight = highlight,
        Steps = f.Body.Flow.Select(s => new HelpFlowStepView
        {
            Title = StepTitle(c, s), Do = s.Do, When = s.When, Optional = s.Optional, ArticleCode = s.Article, Page = PageLink(c, s.Page)
        }).ToList()
    };

    /// <summary>The workflows a guide or a screen is part of (the work order around it), best first.</summary>
    private static List<HelpWorkflowView> WorkflowsOf(Catalog c, string? articleCode, string? pageCode) =>
        c.Flows.Select(f => (f, i: f.Body.Flow.FindIndex(s => (articleCode is not null && s.Article == articleCode)
                                                                || (pageCode is not null && s.Page.Equals(pageCode, StringComparison.OrdinalIgnoreCase)))))
               .Where(x => x.i >= 0)
               .OrderBy(x => x.f.Row.Code.StartsWith("FLOW.SETUP.") ? 1 : 0).ThenBy(x => x.f.Row.SortOrder)
               .Select(x => WorkflowView(c, x.f, x.i, -1)).ToList();

    [GeneratedRegex(@"\b(first|start|begin|beginning|starting)\b")]
    private static partial Regex StartWords();

    private static Regex Cue(string intent) => intent switch
    {
        HelpIntent.Next => NextCue(),
        HelpIntent.Before => BeforeCue(),
        _ => FlowCue()
    };
    [GeneratedRegex(@"\b(after|next|then|once|done|finished|complete[d]?|comes?|following|afterwards)\b")]
    private static partial Regex NextCue();
    [GeneratedRegex(@"\b(before|prior|prerequisites?|required|requirements?|need|needed|ready|previous|first|beforehand)\b")]
    private static partial Regex BeforeCue();
    [GeneratedRegex(@"\b(process|workflow|flow|steps|stages?|end to end|lifecycle|life cycle|order|sequence|start|first|begin|whole|full|complete|overall)\b")]
    private static partial Regex FlowCue();

    private HelpAnswer FlowAnswer(Catalog c, string question, string intent, FlowMatch m)
    {
        var f = m.Flow;
        var steps = f.Body.Flow;
        var cur = steps[m.Index];
        var curTitle = StepTitle(c, cur);
        HelpLink? Page(FlowStep s) => PageLink(c, s.Page, s.When);
        List<string> GuideSteps(FlowStep s) => s.Article is not null && c.ByCode.TryGetValue(s.Article, out var g) ? g.Body.Steps : [];
        string Where(FlowStep s) => c.Pages.TryGetValue(s.Page, out var p) ? PathOf(c, p) : s.Page;

        if (intent == HelpIntent.Flow)
        {
            var strong = m.StepScore >= 0.35;
            var start = StartWords().IsMatch(HelpText.Normalize(question));
            return new HelpAnswer
            {
                Found = true, Kind = "FLOW", Code = f.Row.Code, Title = f.Row.Title, Text = f.Row.Summary,
                Steps = f.Body.Steps, Pages = steps.Select(Page).OfType<HelpLink>().GroupBy(l => l.Code).Select(g => g.First()).Take(6).ToList(),
                Workflow = WorkflowView(c, f, strong && !start ? m.Index : -1, start ? 0 : -1)
            };
        }

        if (intent == HelpIntent.Next)
        {
            if (m.Index == steps.Count - 1)
                return new HelpAnswer
                {
                    Found = true, Kind = "NEXT", Code = f.Row.Code, Title = $"\"{curTitle}\" is the last step",
                    Text = $"\"{curTitle}\" is the last step of {f.Row.Title}. Nothing else is needed for this work.",
                    Workflow = WorkflowView(c, f, m.Index, -1)
                };
            // the next steps up to the first one that is always done (optional ones in between are mentioned)
            var next = new List<int>();
            for (var j = m.Index + 1; j < steps.Count; j++) { next.Add(j); if (!steps[j].Optional) break; }
            var main = steps[next[^1]];
            var text = new StringBuilder($"After \"{curTitle}\", the next step is \"{StepTitle(c, main)}\" in {Where(main)}: {main.Do}");
            foreach (var j in next.Take(next.Count - 1))
                text.Append($"\nBefore that, {char.ToLower(StepTitle(c, steps[j])[0])}{StepTitle(c, steps[j])[1..]} - {steps[j].When}.");
            if (main.Optional) text.Append($"\n(This step is {main.When}.)");
            return new HelpAnswer
            {
                Found = true, Kind = "NEXT", Code = main.Article ?? f.Row.Code, Title = "Next: " + StepTitle(c, main), Text = text.ToString(),
                Steps = GuideSteps(main), Pages = next.Select(j => Page(steps[j])).OfType<HelpLink>().ToList(),
                Workflow = WorkflowView(c, f, m.Index, next[^1])
            };
        }

        // before
        if (m.Index == 0)
        {
            var guide = cur.Article is not null && c.ByCode.TryGetValue(cur.Article, out var g) ? g : null;
            var pre = (guide?.Body.Prereq ?? []).Select(p => PageLink(c, p)).OfType<HelpLink>().ToList();
            return new HelpAnswer
            {
                Found = true, Kind = "BEFORE", Code = cur.Article ?? f.Row.Code, Title = "Before: " + curTitle,
                Text = $"\"{curTitle}\" is the first step of {f.Row.Title}." +
                       (pre.Count > 0 ? " These must be set up before it: " + string.Join(", ", pre.Select(p => p.Title)) + "." : " Nothing comes before it in this work."),
                Steps = pre.Select(p => $"{p.Path}").ToList(), Pages = pre.Take(6).ToList(),
                Workflow = WorkflowView(c, f, 0, -1)
            };
        }
        var prev = new List<int>();
        for (var j = m.Index - 1; j >= 0; j--) { prev.Insert(0, j); if (!steps[j].Optional) break; }
        var before = steps[prev[0]];
        var t = new StringBuilder($"Before \"{curTitle}\", \"{StepTitle(c, before)}\" must be done in {Where(before)}: {before.Do}");
        foreach (var j in prev.Skip(1)) t.Append($"\nThen, {steps[j].When}: {StepTitle(c, steps[j])}.");
        return new HelpAnswer
        {
            Found = true, Kind = "BEFORE", Code = before.Article ?? f.Row.Code, Title = "Before this: " + StepTitle(c, before), Text = t.ToString(),
            Steps = GuideSteps(before), Pages = prev.Select(j => Page(steps[j])).OfType<HelpLink>().ToList(),
            Workflow = WorkflowView(c, f, m.Index, prev[0])
        };
    }

    private HelpAnswer TopicAnswer(Catalog c, Doc d)
    {
        if (d.Article is { } a)
        {
            if (a.Row.Kind == "FLOW")
                return new HelpAnswer
                {
                    Found = true, Kind = "FLOW", Code = a.Row.Code, Title = a.Row.Title, Text = a.Row.Summary, Steps = a.Body.Steps,
                    Pages = a.Body.Flow.Select(s => PageLink(c, s.Page, s.When)).OfType<HelpLink>().GroupBy(l => l.Code).Select(g => g.First()).Take(6).ToList(),
                    Workflow = WorkflowView(c, a, -1, -1)
                };
            return new HelpAnswer
            {
                Found = true, Code = a.Row.Code, Kind = a.Row.Kind, Title = a.Row.Title, Text = a.Row.Summary, Steps = a.Body.Steps,
                Pages = a.Pages.Concat(a.Body.Prereq).Select(p => PageLink(c, p)).OfType<HelpLink>().GroupBy(l => l.Code).Select(g => g.First()).Take(5).ToList(),
                // where this work sits in the application's flow
                Workflow = WorkflowsOf(c, a.Row.Code, a.Pages.FirstOrDefault())
                           .FirstOrDefault(w => a.Row.Kind == "GUIDE" || (c.ByCode.TryGetValue(w.Code, out var f) && f.Body.Primary))
            };
        }
        var p = d.Page!;
        return new HelpAnswer
        {
            Found = true, Code = "PAGE:" + p.PageCode, Kind = "PAGE", Title = p.Title, Text = $"This is done in {PathOf(c, p)}.",
            Steps = GeneralSteps(c, p, PathOf(c, p), ModuleOf(c, p)), Pages = [PageLink(c, p.PageCode)!],
            Workflow = WorkflowsOf(c, null, p.PageCode).FirstOrDefault()
        };
    }

    public async Task<HelpAnswer> AskAsync(HelpAskRequest r)
    {
        var question = (r.Question ?? "").Trim();
        if (question.Length > 400) question = question[..400];

        // a question about live data (a bill number, today's collection, dues...): answered from the database (SQLScripts/2321)
        HelpAnswer? data = null;
        try
        {
            using var ddb = connectionFactory.CreateConnection();
            data = await HelpData.AnswerAsync(ddb, r, DateTime.Today);
        }
        catch (Exception ex) { logger.LogWarning(ex, "Help assistant: data answer failed; a help answer is given instead."); }
        if (data is not null)
        {
            data.Intent = "DATA";
            data.Confidence = 1;
            await LogAskAsync(r, question, "DATA", data);
            return data;
        }

        var c = await CatalogAsync(r.CompanyId);
        var hits = Blend(c, question, r.PageCode);
        var key = QuestionKey(question);
        var (intent, intentP) = HelpIntent.Predict(c.Intents, question);
        if (c.MemoryIntent.TryGetValue(key, out var taughtIntent)) intent = taughtIntent;
        // a workflow answer needs the words of one ("after", "before", "process"...); otherwise it is a how-to question
        else if (intent is HelpIntent.Next or HelpIntent.Before or HelpIntent.Flow && !Cue(intent).IsMatch(HelpText.Normalize(question)))
            intent = HelpIntent.HowTo;
        // learned from use: topics users rejected for this question go down, a confirmed / taught one goes to the top
        if (hits.Any(h => c.Rejected.Contains(key + "|" + h.Doc.Key)))
            hits = hits.Select(h => c.Rejected.Contains(key + "|" + h.Doc.Key) ? h with { Score = h.Score * 0.3 } : h).OrderByDescending(h => h.Score).ToList();
        (string Target, bool Admin) memory = default;
        var remembered = c.Memory.TryGetValue(key, out memory) && c.Search.Docs.Any(d => d.Key == memory.Target);
        // a question worded like a confirmed / taught one ("apply discount in lab billing" ~ "give discount on a lab bill"): its answer is lifted
        if (!remembered && c.Memory.Count > 0)
        {
            var words = key.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet();
            var near = c.Memory.Select(m => (m.Value.Target, Sim: Jaccard(words, m.Key.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet())))
                               .Where(x => x.Sim >= 0.5).OrderByDescending(x => x.Sim).FirstOrDefault();
            if (near.Target is not null)
                hits = hits.Select(h => h.Doc.Key == near.Target ? h with { Score = h.Score + 0.4 * near.Sim } : h).OrderByDescending(h => h.Score).ToList();
        }
        if (remembered)
        {
            var doc = c.Search.Docs.First(d => d.Key == memory.Target);
            hits = hits.Where(h => h.Doc.Key != memory.Target).Prepend(new Hit(doc, Math.Max(0.95, hits.FirstOrDefault()?.Score ?? 0))).ToList();
        }
        var top = hits.FirstOrDefault();

        HelpAnswer? answer = null;
        FlowMatch? alt = null;
        // an answer an administrator taught (or users confirmed for a how-to / problem question) is given as it is
        if (remembered && (memory.Admin || intent is not (HelpIntent.Next or HelpIntent.Before or HelpIntent.Flow)))
        {
            answer = TopicAnswer(c, top!.Doc);
            answer.Learned = true;
        }
        if (answer is null && intent is HelpIntent.Next or HelpIntent.Before or HelpIntent.Flow && MatchStep(c, question, hits, intent, string.IsNullOrWhiteSpace(r.PageCode) ? null : r.PageCode) is { } m
            && (m.StepScore >= 0.3 || (intent == HelpIntent.Flow && m.Score >= 0.25)))
        {
            answer = FlowAnswer(c, question, intent, m);
            alt = intent == HelpIntent.Flow ? null : m.Alternative;
        }
        // asked from a screen that is in no workflow ("what do I do after this screen?" on Licence): its usual before / after
        var subjectless = !Tokens(question).Any(t => !IntentWords.Contains(t));
        if (answer is null && subjectless && intent is HelpIntent.Next or HelpIntent.Before or HelpIntent.Flow
            && !string.IsNullOrWhiteSpace(r.PageCode) && await PageAsync(r.CompanyId, r.PageCode, null, null) is { } here)
        {
            var list = intent == HelpIntent.Before ? here.Before : here.After;
            answer = new HelpAnswer
            {
                Found = true, Kind = "PAGE", Code = "PAGE:" + here.PageCode, Title = here.Title,
                Text = $"{here.Title} is not a step of a fixed workflow - it is used when needed." +
                       (list.Count > 0 ? (intent == HelpIntent.Before ? " Before it, these must be ready: " : " Usually next: ") + string.Join(", ", list.Take(5).Select(l => l.Title)) + "." : ""),
                Steps = here.Guides.FirstOrDefault()?.Steps ?? here.GeneralSteps, Pages = list.Take(5).ToList()
            };
        }
        if (answer is null && top is not null && top.Score >= 0.2)
            answer = TopicAnswer(c, top.Doc);

        if (answer is null)
        {
            answer = new HelpAnswer
            {
                Found = false,
                Text = "I could not find a clear answer to that. Try other words (for example \"cancel a LAB bill\", \"what is next after sample collection\" " +
                       "or \"LAB workflow\"), or open a module below to browse its guides.",
                Related = hits.Take(5).Select(h => Link(c, h.Doc)).ToList()
            };
            await FeedbackAsync(new HelpFeedbackRequest { CompanyId = r.CompanyId, UserId = r.UserId, Question = question, PageCode = r.PageCode });
        }
        else
        {
            answer.Confidence = Math.Round(Math.Min(1, top?.Score ?? 0), 2);
            var shown = new HashSet<string>(answer.Pages.Select(p => "PAGE:" + p.Code).Append(answer.Code ?? "").Append(answer.Workflow?.Code ?? ""), StringComparer.OrdinalIgnoreCase);
            answer.Related = hits.Where(h => !shown.Contains(h.Doc.Key) && h.Score >= 0.08).Take(4).Select(h => Link(c, h.Doc)).ToList();
            // the same words read in another workflow (e.g. the pathologist approval step vs. the approval-flow setup)
            if (alt is not null) answer.Related.Insert(0, new HelpLink
            {
                Code = alt.Flow.Row.Code, Title = $"Or did you mean \"{StepTitle(c, alt.Flow.Body.Flow[alt.Index])}\" in {alt.Flow.Row.Title}?", Note = "FLOW"
            });
            if (await AiAnswerAsync(c, question, hits.Take(5).Select(h => h.Doc).ToList(), answer) is { } ai)
            {
                answer.Text = ai;
                answer.Source = "AI";
            }
        }
        answer.Intent = intent;
        await LogAskAsync(r, question, intent, answer);
        logger.LogDebug("Help assistant: \"{Q}\" -> intent {Intent} ({P:0.00}), answer {Code}", question, intent, intentP, answer.Code);
        return answer;
    }

    private async Task LogAskAsync(HelpAskRequest r, string question, string? intent, HelpAnswer answer)
    {
        try
        {
            using var db = connectionFactory.CreateConnection();
            await db.ExecuteAsync("dbo.usp_Help_Ask_Log", new
            {
                r.CompanyId, Question = question, Intent = intent is { Length: > 10 } ? intent[..10] : intent, AnswerCode = answer.Found ? answer.Code : null, answer.Found,
                Confidence = (decimal)Math.Round(answer.Confidence, 2), PageCode = string.IsNullOrWhiteSpace(r.PageCode) ? null : r.PageCode, r.UserId
            }, commandType: Sp);
        }
        catch (Exception ex) { logger.LogWarning(ex, "Help assistant: the question could not be logged."); }
    }

    private static HelpLink Link(Catalog c, Doc d) => d.Article is not null
        ? ArticleLink(d.Article)
        : new HelpLink { Code = "PAGE:" + d.Page!.PageCode, Title = d.Page.Title, Url = Url(d.Page), Path = PathOf(c, d.Page), Note = "PAGE" };

    /// <summary>Claude's answer written only from the matched help content and workflow; null when not configured or on any failure.</summary>
    private async Task<string?> AiAnswerAsync(Catalog c, string question, List<Doc> docs, HelpAnswer local)
    {
        var key = config["HelpAssistant:AnthropicApiKey"];
        if (string.IsNullOrWhiteSpace(key) || docs.Count == 0) return null;
        try
        {
            var context = new StringBuilder();
            context.AppendLine($"### Best answer found: {local.Title}\n{local.Text}\n{string.Join("\n", local.Steps.Select((s, i) => $"{i + 1}. {s}"))}\n");
            if (local.Workflow is { } wf)
                context.AppendLine($"### Workflow: {wf.Title}\n" + string.Join("\n", wf.Steps.Select((s, i) =>
                    $"{i + 1}. {s.Title}{(s.When is null ? "" : $" ({s.When})")}: {s.Do} [{s.Page?.Path}]{(i == wf.Current ? "  <- the step asked about" : "")}")) + "\n");
            foreach (var d in docs)
            {
                if (d.Article is { } a)
                    context.AppendLine($"### {a.Row.Title}\n{a.Row.Summary}\n{string.Join("\n", a.Body.Steps.Select((s, i) => $"{i + 1}. {s}"))}\n{string.Join("\n", a.Body.Tips.Select(t => "Tip: " + t))}\n");
                else if (d.Page is { } p)
                    context.AppendLine($"### Page: {PathOf(c, p)}\nActions: {string.Join(", ", c.Controls[p.PageCode])}\n");
            }
            var body = new
            {
                model = config["HelpAssistant:Model"] ?? "claude-haiku-5-5",
                max_tokens = 600,
                system = "You are the help assistant of eCare360Plus+, a hospital and laboratory management application. Answer the user's question " +
                         "using ONLY the help content provided, following the application's workflow order when the question is about what comes " +
                         "next or before. Be brief and practical: one short sentence, then numbered steps naming the exact menus and buttons. " +
                         "If the content does not answer the question, say so and suggest the closest topic. Never invent menus or features.",
                messages = new[] { new { role = "user", content = $"Help content:\n{context}\n\nQuestion: {question}" } }
            };
            using var http = httpFactory.CreateClient("Anthropic");
            http.Timeout = TimeSpan.FromSeconds(20);
            using var req = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages")
            {
                Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json")
            };
            req.Headers.Add("x-api-key", key);
            req.Headers.Add("anthropic-version", "2023-06-01");
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            using var res = await http.SendAsync(req);
            if (!res.IsSuccessStatusCode) { logger.LogWarning("Help assistant AI answered {Status}", (int)res.StatusCode); return null; }
            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync());
            var text = string.Concat(doc.RootElement.GetProperty("content").EnumerateArray()
                .Where(x => x.GetProperty("type").GetString() == "text").Select(x => x.GetProperty("text").GetString()));
            return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Help assistant AI answer failed; the help content answer is used.");
            return null;
        }
    }

    // ── feedback ─────────────────────────────────────────────────────────────────────────────────────────────

    public async Task FeedbackAsync(HelpFeedbackRequest r)
    {
        using var db = connectionFactory.CreateConnection();
        var click = string.Equals(r.Signal, "CLICK", StringComparison.OrdinalIgnoreCase);
        if (!click)
            await db.ExecuteAsync("dbo.usp_Help_Feedback_Save", new
            {
                r.CompanyId, ArticleCode = r.ArticleCode is { Length: > 60 } ? r.ArticleCode[..60] : r.ArticleCode,
                r.PageCode, r.Question, r.Helpful, r.Comment, r.UserId
            }, commandType: Sp);

        // learn from it: what answered (or did not answer) this question
        var key = QuestionKey(r.Question);
        if (key.Length == 0 || (r.Helpful is null && !click)) return;
        var flowAnswer = r.Kind is "NEXT" or "BEFORE" or "FLOW";   // a workflow answer teaches what the user wanted, not a topic
        await db.ExecuteAsync("dbo.usp_Help_Learn", new
        {
            r.CompanyId, Question = r.Question!.Length > 400 ? r.Question[..400] : r.Question, QuestionKey = key,
            TargetCode = flowAnswer && !click ? null : Code120(r.ArticleCode),
            Intent = click ? null : r.Intent,
            Signal = click ? "CLICK" : r.Helpful == true ? "UP" : "DOWN", r.UserId
        }, commandType: Sp);
        // kept per user for the nightly learning pass (an answer is learned when several different users choose it)
        if (Code120(r.ArticleCode) is { } target && !target.StartsWith("DATA:") && !(flowAnswer && !click))
            try
            {
                await db.ExecuteAsync("dbo.usp_Help_Signal_Log", new
                {
                    r.CompanyId, QuestionKey = key, TargetCode = target, Signal = click ? "CLICK" : r.Helpful == true ? "UP" : "DOWN", r.UserId
                }, commandType: Sp);
            }
            catch (Exception ex) { logger.LogWarning(ex, "Help assistant: the signal could not be logged (is SQLScripts/2321 applied?)."); }
    }

    public async Task<HelpGapsView> GapsAsync(int companyId)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync("dbo.usp_Help_Gaps", new { CompanyId = companyId }, commandType: Sp);
        return new HelpGapsView
        {
            Gaps = (await multi.ReadAsync<HelpGapRow>()).ToList(),
            LastRun = await multi.ReadSingleOrDefaultAsync<HelpLearningRunRow>()
        };
    }

    public async Task<(int Promoted, int Demoted)> LearnNightlyAsync()
    {
        using var db = connectionFactory.CreateConnection();
        var r = await db.QuerySingleAsync<(int Promoted, int Demoted)>("dbo.usp_Help_Learn_Nightly", commandType: Sp, commandTimeout: 300);
        // each company's catalog is rebuilt on its next question: the ML.NET models retrain with what was learned
        foreach (var companyId in await db.QueryAsync<int>("SELECT DISTINCT CompanyId FROM dbo.HelpLearned"))
            cache.Remove(CatalogKey(companyId));
        return r;
    }

    private static string? Code120(string? code) => string.IsNullOrWhiteSpace(code) ? null : code.Length > 120 ? code[..120] : code;

    public async Task TeachAsync(HelpTeachRequest r)
    {
        var key = QuestionKey(r.Question);
        if (key.Length == 0) return;
        using (var db = connectionFactory.CreateConnection())
            await db.ExecuteAsync("dbo.usp_Help_Learn", new
            {
                r.CompanyId, Question = r.Question.Length > 400 ? r.Question[..400] : r.Question, QuestionKey = key,
                TargetCode = Code120(r.TargetCode), Intent = string.IsNullOrWhiteSpace(r.Intent) ? null : r.Intent, Signal = "TEACH", r.UserId
            }, commandType: Sp);
        cache.Remove(CatalogKey(r.CompanyId));   // taught answers apply at once (the models retrain on the next question)
    }

    public async Task<bool> ForgetAsync(int companyId, int learnedId, int? userId)
    {
        using var db = connectionFactory.CreateConnection();
        var n = await db.ExecuteScalarAsync<int>("dbo.usp_Help_Learned_Forget", new { CompanyId = companyId, LearnedId = learnedId, UserId = userId }, commandType: Sp);
        cache.Remove(CatalogKey(companyId));
        return n > 0;
    }

    public async Task<HelpLearningStats> LearningStatsAsync(int companyId)
    {
        var c = await CatalogAsync(companyId);
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync("dbo.usp_Help_Learning_Stats", new { CompanyId = companyId }, commandType: Sp);
        var stats = new HelpLearningStats
        {
            Days = (await multi.ReadAsync<HelpDayStat>()).ToList(),
            Learned = (await multi.ReadAsync<HelpLearnedView>()).ToList(),
            // what an administrator can teach: every help topic, then every screen
            Topics = c.Articles.Where(a => a.Row.Kind != "MODULE").OrderBy(a => a.Row.Kind).ThenBy(a => a.Row.Title)
                      .Select(a => new HelpLink { Code = a.Row.Code, Title = a.Row.Title, Note = a.Row.Kind })
                      .Concat(c.Pages.Values.OrderBy(p => p.Title).Select(p => new HelpLink { Code = "PAGE:" + p.PageCode, Title = p.Title, Path = PathOf(c, p), Note = "PAGE" }))
                      .ToList()
        };
        foreach (var l in stats.Learned.Where(l => l.TargetCode?.StartsWith("PAGE:") == true && l.TargetTitle is null))
            l.TargetTitle = c.Pages.TryGetValue(l.TargetCode![5..], out var p) ? "Screen: " + p.Title : l.TargetCode;
        return stats;
    }

    public async Task<HelpFeedbackList> FeedbackListAsync(int companyId)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync("dbo.usp_Help_Feedback_List", new { CompanyId = companyId }, commandType: Sp);
        return new HelpFeedbackList
        {
            Open = (await multi.ReadAsync<HelpFeedbackRow>()).ToList(),
            Scores = (await multi.ReadAsync<HelpArticleScore>()).ToList()
        };
    }

    [GeneratedRegex(@"[a-z0-9][a-z0-9\-]*")]
    private static partial Regex WordRegex();
}
