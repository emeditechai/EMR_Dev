using System.Globalization;
using System.Linq.Expressions;
using System.Text.RegularExpressions;
using EMR.Shared.Security;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;

namespace EMR.Web.Services;

/// <summary>
/// The personal parts of the Home dashboard: the pages the user may open ("Go to" search), the screens they used
/// last ("Continue where you left off") and their recent actions with a link back to the screen or record.
/// Everything comes from the page catalogue (MenuMaster / PageMaster / PageEndpointMap), the user's own audit trail
/// and their permissions - no business figures. A page or link the user may not open is never offered.
/// </summary>
public interface IHomeDashboardService
{
    /// <summary>The pages of the navigation the user may open, with their menu path - the same set the navbar shows.</summary>
    Task<IReadOnlyList<HomePageLink>> GetPageCatalogAsync(HttpContext http);

    /// <summary>The distinct screens the user opened last in the branch, newest first.</summary>
    Task<IReadOnlyList<HomeRecentScreen>> GetRecentScreensAsync(HttpContext http, IReadOnlyList<HomePageLink> catalog,
        int userId, int branchId, int take);

    /// <summary>The user's latest real actions in the branch (page views and sign-in events are not activity), newest first.</summary>
    Task<IReadOnlyList<HomeActivityItem>> GetRecentActivityAsync(HttpContext http, IReadOnlyList<HomePageLink> catalog,
        int userId, int branchId, int take);
}

public sealed class HomeDashboardService(
    ApplicationDbContext dbContext,
    IPermissionDataSource permissionData,
    IPermissionService permissions,
    IMemoryCache cache,
    ILabReportingEligibility labReporting,
    LinkGenerator links) : IHomeDashboardService
{
    // Screens that are not work: the dashboard itself and the sign-in steps.
    private static readonly HashSet<string> NotWorkControllers = new(StringComparer.OrdinalIgnoreCase) { "Dashboard", "Home", "Account" };

    // Screens that open one lab order by its id (AuditLogs.ReferenceId is the LabOrderId for LAB events).
    private static readonly Dictionary<string, string> OrderEntryScreens = new(StringComparer.OrdinalIgnoreCase)
    {
        ["LabReporting"] = "Entry",
        ["LabImageReporting"] = "Entry",
        ["MicrobiologyReporting"] = "Entry",
        ["PathologistDashboard"] = "Approve"
    };

    /// <summary>
    /// What counts as something the user did themselves. Left out:
    ///   * opening a page (ModuleCode PAGE_VIEW; older page views carry no module and read "Viewed ... page");
    ///   * signing in, choosing a branch / role, signing out;
    ///   * system work: anything written outside a web request (no RoutePath - the background report e-mail /
    ///     WhatsApp senders, for example) and the automatic notification outcomes even when written during a request
    ///     ("LAB.ReportEmailed", "...EmailSkipped", "...WhatsAppSent", "...WhatsAppFailed", SMS and other notifications).
    /// </summary>
    private static readonly Expression<Func<AuditLog, bool>> IsUserActivity = x =>
        (x.ModuleCode == null || x.ModuleCode != "PAGE_VIEW")
        && !(x.Description != null && x.Description.StartsWith("Viewed ") && x.Description.EndsWith(" page"))
        && x.EventType != "AuthSuccess" && x.EventType != "AuthFailure" && x.EventType != "Auth"
        && x.RoutePath != null && x.RoutePath != ""
        && !EF.Functions.Like(x.ActionName, "%Emailed")
        && !EF.Functions.Like(x.ActionName, "%EmailSent")
        && !EF.Functions.Like(x.ActionName, "%EmailSkipped")
        && !EF.Functions.Like(x.ActionName, "%EmailFailed")
        && !EF.Functions.Like(x.ActionName, "%WhatsAppSent")
        && !EF.Functions.Like(x.ActionName, "%WhatsAppSkipped")
        && !EF.Functions.Like(x.ActionName, "%WhatsAppFailed")
        && !EF.Functions.Like(x.ActionName, "%SmsSent")
        && !EF.Functions.Like(x.ActionName, "%SmsSkipped")
        && !EF.Functions.Like(x.ActionName, "%SmsFailed")
        && !EF.Functions.Like(x.ActionName, "%Notification%");

    public async Task<IReadOnlyList<HomePageLink>> GetPageCatalogAsync(HttpContext http)
    {
        var subject = PermissionSubjectReader.FromPrincipal(http.User);
        if (subject is null) return [];

        var tree = await cache.GetOrCreateAsync($"authz:navtree:{subject.CompanyId}:{permissions.NavigationGeneration}", e =>
        {
            e.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(5);
            return permissionData.GetNavTreeAsync(subject.CompanyId);
        });
        if (tree is null) return [];

        var set = await permissions.GetPermissionSetAsync(subject);
        // Lab Reporting / Image / Microbiology Reporting also need a Lab Technician or Pathologist, as in the navbar
        var hidden = (await labReporting.CheckAsync(http)).Allowed
            ? new HashSet<string>()
            : new HashSet<string>(LabReportingEligibility.PageCodes, StringComparer.OrdinalIgnoreCase);

        var childMenus = tree.Menus.Where(m => m.Parent_Menu_ID != null).ToLookup(m => m.Parent_Menu_ID!.Value);
        var pagesByMenu = tree.Pages.Where(p => p.Menu_ID != null).ToLookup(p => p.Menu_ID!.Value);
        var result = new List<HomePageLink>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void Walk(int menuId, List<string> path)
        {
            var siblings = childMenus[menuId].Select(m => (Sort: m.Sort_Order, Menu: (NavMenuRow?)m, Page: (NavPageRow?)null))
                .Concat(pagesByMenu[menuId].Select(p => (Sort: p.Sort_Order, Menu: (NavMenuRow?)null, Page: (NavPageRow?)p)))
                .OrderBy(x => x.Sort);
            foreach (var x in siblings)
            {
                if (x.Menu is { } m)
                {
                    Walk(m.Menu_ID, [.. path, m.Title]);
                }
                else if (x.Page is { } p && set.Can(p.Page_Code) && !hidden.Contains(p.Page_Code) && seen.Add(p.Page_Code))
                {
                    var url = PageUrl(http, p);
                    if (url is null) continue;
                    result.Add(new HomePageLink(p.Page_Code, p.Title, p.Icon, url, p.Link_Target, string.Join(" › ", path),
                        p.Controller, p.Action));
                }
            }
        }

        foreach (var nav in tree.Menus.Where(m => m.Parent_Menu_ID == null && m.Menu_Type == "NAV").OrderBy(m => m.Sort_Order))
            Walk(nav.Menu_ID, [nav.Title]);

        return result;
    }

    public async Task<IReadOnlyList<HomeRecentScreen>> GetRecentScreensAsync(HttpContext http, IReadOnlyList<HomePageLink> catalog,
        int userId, int branchId, int take)
    {
        if (userId <= 0 || catalog.Count == 0) return [];

        var views = await dbContext.AuditLogs
            .Where(x => x.UserId == userId && x.BranchId == branchId && x.ModuleCode == "PAGE_VIEW")
            .OrderByDescending(x => x.Id)
            .Select(x => new { x.ControllerName, x.ActionName, x.CreatedDate })
            .Take(300)
            .ToListAsync();

        var endpointPages = await EndpointPagesAsync();
        var result = new List<HomeRecentScreen>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var v in views)
        {
            var controller = v.ControllerName;
            // page views record ActionName as "Controller.Action"
            var action = v.ActionName is { } a && a.Contains('.') ? a[(a.LastIndexOf('.') + 1)..] : v.ActionName;
            if (string.IsNullOrWhiteSpace(controller) || string.IsNullOrWhiteSpace(action) || NotWorkControllers.Contains(controller))
                continue;

            var page = FindPage(catalog, endpointPages, "GET", controller, action);
            if (page is null || !seen.Add(page.Code)) continue;

            result.Add(new HomeRecentScreen(page, v.CreatedDate));
            if (result.Count >= take) break;
        }
        return result;
    }

    public async Task<IReadOnlyList<HomeActivityItem>> GetRecentActivityAsync(HttpContext http, IReadOnlyList<HomePageLink> catalog,
        int userId, int branchId, int take)
    {
        if (userId <= 0) return [];

        // What the user did themselves in this branch - not page views, sign-in steps or system notifications.
        var rows = await dbContext.AuditLogs
            .Where(x => x.UserId == userId && x.BranchId == branchId)
            .Where(IsUserActivity)
            .OrderByDescending(x => x.Id)
            .Select(x => new
            {
                x.Description, x.CreatedDate, x.ModuleCode, x.EventType, x.ControllerName, x.ActionName,
                x.RoutePath, x.HttpMethod, x.ReferenceNo, x.ReferenceId
            })
            .Take(take)
            .ToListAsync();
        if (rows.Count == 0) return [];

        var endpointPages = await EndpointPagesAsync();
        var orders = await LabOrdersAsync(rows.Where(r => r.ModuleCode == "LAB" && r.ReferenceId is > 0 and <= int.MaxValue).Select(r => (int)r.ReferenceId!.Value));
        var subject = PermissionSubjectReader.FromPrincipal(http.User);
        var labEntryAllowed = (await labReporting.CheckAsync(http)).Allowed;
        var allowedCache = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);

        async Task<bool> CanOpenAsync(string controller, string action)
        {
            if (subject is null) return false;
            var key = $"{controller}/{action}";
            if (!allowedCache.TryGetValue(key, out var ok))
            {
                var decision = await permissions.AuthorizeEndpointAsync(subject, "WEB", "GET", controller, action, false);
                ok = decision.Outcome is EndpointOutcome.Allowed or EndpointOutcome.Public;
                allowedCache[key] = ok;
            }
            return ok;
        }

        var items = new List<HomeActivityItem>();
        foreach (var r in rows)
        {
            // the MVC controller / action that did the work: from the route ("/LabOrderBooking/SaveBookingWithPayment")
            var segments = (r.RoutePath ?? string.Empty).Split('/', StringSplitOptions.RemoveEmptyEntries);
            var controller = segments.Length > 0 ? segments[0] : r.ControllerName;
            var action = segments.Length > 1 ? segments[1] : "Index";
            var page = string.IsNullOrWhiteSpace(controller)
                ? null
                : FindPage(catalog, endpointPages, string.IsNullOrWhiteSpace(r.HttpMethod) ? "GET" : r.HttpMethod!, controller!, action);

            var item = new HomeActivityItem
            {
                Description = CleanDescription(r.Description),
                At = r.CreatedDate,
                Module = r.ModuleCode,
                EventTitle = EventTitle(r.ActionName, r.EventType),
                ScreenTitle = page?.Title ?? Humanize(controller),
                ScreenPath = page?.Path,
                ScreenIcon = page?.Icon,
                ReferenceNo = r.ReferenceNo
            };

            // 1. the record itself, when a screen opens it by id and the user may open that screen
            if (r.ModuleCode == "LAB" && r.ReferenceId is > 0 and <= int.MaxValue && !string.IsNullOrWhiteSpace(controller))
            {
                var id = (int)r.ReferenceId.Value;
                if (OrderEntryScreens.TryGetValue(controller!, out var entryAction))
                {
                    var labScreen = !controller!.Equals("PathologistDashboard", StringComparison.OrdinalIgnoreCase);
                    if ((!labScreen || labEntryAllowed) && await CanOpenAsync(controller!, entryAction))
                    {
                        item.OpenUrl = links.GetPathByAction(http, entryAction, controller, new { labOrderId = id });
                        item.OpenLabel = "Open report";
                    }
                }
                else if (orders.TryGetValue(id, out var order) && !string.IsNullOrWhiteSpace(order.BillNo))
                {
                    var from = order.OrderDay.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                    if (controller!.Equals("LabOrderBooking", StringComparison.OrdinalIgnoreCase))
                    {
                        var listAction = order.IsB2B ? "B2BRegistration" : "B2COrderList";
                        if (await CanOpenAsync("LabOrderBooking", listAction))
                        {
                            item.OpenUrl = links.GetPathByAction(http, listAction, "LabOrderBooking", new { search = order.BillNo, fromDate = from });
                            item.OpenLabel = "Open order";
                        }
                    }
                    else if (controller!.Equals("SampleCollection", StringComparison.OrdinalIgnoreCase) && await CanOpenAsync("SampleCollection", "Index"))
                    {
                        item.OpenUrl = links.GetPathByAction(http, "Index", "SampleCollection", new { search = order.BillNo, fromDate = from });
                        item.OpenLabel = "Open order";
                    }
                }
            }

            // 2. otherwise the screen it was done on (already limited to pages the user may open)
            if (item.OpenUrl is null && page is not null)
            {
                item.OpenUrl = page.Url;
                item.OpenLabel = "Open screen";
            }

            items.Add(item);
        }
        return items;
    }

    // ---- helpers ------------------------------------------------------------------------------------------------

    /// <summary>The catalogue page a controller / action belongs to: the page itself, else the page its endpoint is mapped to.</summary>
    private static HomePageLink? FindPage(IReadOnlyList<HomePageLink> catalog, ILookup<string, string> endpointPages,
        string httpMethod, string controller, string action)
    {
        var direct = catalog.FirstOrDefault(p => p.Controller.Equals(controller, StringComparison.OrdinalIgnoreCase)
                                                 && p.Action.Equals(action, StringComparison.OrdinalIgnoreCase));
        if (direct is not null) return direct;

        var codes = endpointPages[EndpointKey(httpMethod, controller, action)]
            .Concat(endpointPages[EndpointKey("GET", controller, action)]);
        foreach (var code in codes)
        {
            var page = catalog.FirstOrDefault(p => p.Code.Equals(code, StringComparison.OrdinalIgnoreCase));
            if (page is not null) return page;
        }

        // a screen of the same controller (e.g. a save on the booking screen belongs to that booking page)
        return catalog.FirstOrDefault(p => p.Controller.Equals(controller, StringComparison.OrdinalIgnoreCase)
                                           && p.Action.Equals("Index", StringComparison.OrdinalIgnoreCase));
    }

    private async Task<ILookup<string, string>> EndpointPagesAsync()
    {
        var map = await cache.GetOrCreateAsync("home:endpoint-pages", async e =>
        {
            e.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(5);
            var rows = await permissionData.GetEndpointMapAsync("WEB");
            return rows.Where(r => !string.IsNullOrWhiteSpace(r.Page_Code))
                       .ToLookup(r => EndpointKey(r.Http_Method, r.Controller, r.Action), r => r.Page_Code!, StringComparer.OrdinalIgnoreCase);
        });
        return map!;
    }

    private static string EndpointKey(string method, string controller, string action)
        => $"{method.ToUpperInvariant()}|{controller}|{action}";

    private string? PageUrl(HttpContext http, NavPageRow p)
    {
        var values = new RouteValueDictionary();
        if (!string.IsNullOrWhiteSpace(p.Area)) values["area"] = p.Area;
        foreach (var pair in (p.Route_Values ?? string.Empty).Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = pair.Split('=', 2);
            values[Uri.UnescapeDataString(kv[0])] = kv.Length > 1 ? Uri.UnescapeDataString(kv[1]) : string.Empty;
        }
        return links.GetPathByAction(http, p.Action, p.Controller, values);
    }

    private sealed class LabOrderRef
    {
        public int LabOrderId { get; set; }
        public string? BillNo { get; set; }
        public bool IsB2B { get; set; }
        public DateTime OrderDay { get; set; }
    }

    private async Task<Dictionary<int, LabOrderRef>> LabOrdersAsync(IEnumerable<int> ids)
    {
        var csv = string.Join(",", ids.Distinct());
        if (csv.Length == 0) return [];
        try
        {
            var rows = await dbContext.Database.SqlQuery<LabOrderRef>($@"
                SELECT o.LabOrderId, o.BillNo, CAST(ISNULL(o.IsB2B, 0) AS BIT) AS IsB2B,
                       CAST(COALESCE(o.OrderDate, o.BookingDate, o.CreatedDate) AS DATE) AS OrderDay
                FROM dbo.LabOrder o
                WHERE o.LabOrderId IN (SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT({csv}, ','))").ToListAsync();
            return rows.ToDictionary(x => x.LabOrderId);
        }
        catch
        {
            return [];   // a link is a convenience: without it the screen link is offered
        }
    }

    /// <summary>Drops empty fragments the audit text can carry, e.g. "(Token: )" when an order has no token.</summary>
    internal static string? CleanDescription(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return text;
        text = Regex.Replace(text, @"\s*\(\s*Token:\s*\)", string.Empty);
        text = Regex.Replace(text, @",\s*Token:\s*(?=[.,;]|$)", string.Empty);
        return Regex.Replace(text, @"\s{2,}", " ").Trim();
    }

    /// <summary>"LAB.PaymentReceived" -> "Payment received"; "Users.Edit" -> "Edit".</summary>
    internal static string EventTitle(string? actionName, string? eventType)
    {
        var name = actionName;
        if (!string.IsNullOrWhiteSpace(name) && name.Contains('.')) name = name[(name.LastIndexOf('.') + 1)..];
        var words = Humanize(name);
        if (string.IsNullOrWhiteSpace(words)) return eventType ?? "Activity";
        words = char.ToUpperInvariant(words[0]) + words[1..].ToLowerInvariant();
        return Regex.Replace(words, @"\bwhatsapp\b", "WhatsApp", RegexOptions.IgnoreCase)
                    .Replace(" pdf", " PDF").Replace(" sms", " SMS").Replace(" opd", " OPD");
    }

    /// <summary>"LabOrderBooking" -> "Lab Order Booking".</summary>
    internal static string Humanize(string? name)
        => string.IsNullOrWhiteSpace(name)
            ? string.Empty
            : Regex.Replace(name.Trim(), "(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", " ")
                .Replace("Whats App", "WhatsApp", StringComparison.OrdinalIgnoreCase);
}
