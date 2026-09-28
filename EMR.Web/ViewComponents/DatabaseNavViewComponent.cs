using EMR.Shared.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Caching.Memory;

namespace EMR.Web.ViewComponents;

/// <summary>
/// The navigation bar rendered from MenuMaster / PageMaster (Authorization:DatabaseNavigation).
/// A page shows when the user may open it; a menu or nav item shows only when something beneath it
/// does, so an empty group never renders. Hiding is a courtesy - every page is checked again on the request.
/// </summary>
public class DatabaseNavViewComponent(IPermissionDataSource data, IPermissionService permissions, IMemoryCache cache,
    EMR.Web.Services.ILabReportingEligibility labReporting) : ViewComponent
{
    public async Task<IViewComponentResult> InvokeAsync()
    {
        var subject = PermissionSubjectReader.FromPrincipal(HttpContext.User);
        if (subject is null) return Content(string.Empty);

        var tree = await cache.GetOrCreateAsync($"authz:navtree:{subject.CompanyId}:{permissions.NavigationGeneration}", e =>
        {
            e.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(5);
            return data.GetNavTreeAsync(subject.CompanyId);
        });
        var set = await permissions.GetPermissionSetAsync(subject);
        // Lab Reporting / Image Reporting also need a Lab Technician or Pathologist (or an Administrator)
        var hidden = (await labReporting.CheckAsync(HttpContext)).Allowed
            ? new HashSet<string>()
            : new HashSet<string>(EMR.Web.Services.LabReportingEligibility.PageCodes, StringComparer.OrdinalIgnoreCase);
        return View(Build(tree!, set, hidden));
    }

    private List<NavItem> Build(NavTree tree, PermissionSet set, HashSet<string> hidden)
    {
        var childMenus = tree.Menus.Where(m => m.Parent_Menu_ID != null).ToLookup(m => m.Parent_Menu_ID!.Value);
        var pagesByMenu = tree.Pages.Where(p => p.Menu_ID != null).ToLookup(p => p.Menu_ID!.Value);

        List<NavItem> Children(int menuId)
        {
            // Divider groups come from ALL siblings (a gap > 10 in Sort_Order), so hiding an item never invents a divider.
            var siblings = childMenus[menuId].Select(m => (Sort: m.Sort_Order, Menu: (NavMenuRow?)m, Page: (NavPageRow?)null))
                .Concat(pagesByMenu[menuId].Select(p => (Sort: p.Sort_Order, Menu: (NavMenuRow?)null, Page: (NavPageRow?)p)))
                .OrderBy(x => x.Sort).ToList();
            var items = new List<NavItem>();
            int group = 0, previousSort = int.MinValue;
            foreach (var x in siblings)
            {
                if (previousSort != int.MinValue && x.Sort - previousSort > 10) group++;
                previousSort = x.Sort;
                if (x.Menu is { } m)
                {
                    var kids = Children(m.Menu_ID);
                    if (kids.Count > 0) items.Add(new NavItem(m.Title, m.Icon, null, null, m.Sort_Order, group, m.Menu_Code, kids));
                }
                else if (x.Page is { } p && set.Can(p.Page_Code) && !hidden.Contains(p.Page_Code))
                {
                    items.Add(new NavItem(p.Title, p.Icon, PageUrl(p), p.Link_Target, p.Sort_Order, group, p.Page_Code, null));
                }
            }
            return items;
        }

        return tree.Menus.Where(m => m.Parent_Menu_ID == null && m.Menu_Type == "NAV")
            .OrderBy(m => m.Sort_Order)
            .Select(nav => new NavItem(nav.Title, nav.Icon, null, null, nav.Sort_Order, 0, nav.Menu_Code, Children(nav.Menu_ID)))
            .Where(nav => nav.Children!.Count > 0)
            .ToList();
    }

    private string? PageUrl(NavPageRow p)
    {
        var values = new RouteValueDictionary();
        if (!string.IsNullOrWhiteSpace(p.Area)) values["area"] = p.Area;
        foreach (var pair in (p.Route_Values ?? string.Empty).Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = pair.Split('=', 2);
            values[Uri.UnescapeDataString(kv[0])] = kv.Length > 1 ? Uri.UnescapeDataString(kv[1]) : string.Empty;
        }
        return Url.Action(p.Action, p.Controller, values);
    }
}

/// <summary>One rendered entry: a link (Url set) or a group (Children set).</summary>
public sealed record NavItem(string Title, string? Icon, string? Url, string? Target, int SortOrder, int Group, string Code, List<NavItem>? Children)
{
    public bool IsGroup => Children != null;

    /// <summary>A nav item holding exactly one page and no groups renders as a plain link (Home, IPD).</summary>
    public NavItem? SingleLink => Children is { Count: 1 } c && !c[0].IsGroup ? c[0] : null;

    /// <summary>A divider separates two visible items that sit in different divider groups of the full sibling list.</summary>
    public static bool DividerBetween(NavItem? previous, NavItem current) => previous != null && current.Group != previous.Group;
}
