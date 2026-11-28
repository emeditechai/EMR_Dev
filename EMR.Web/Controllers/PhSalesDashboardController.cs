using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Pharmacy > Sales > Sales Dashboard (PHARMACY.SALESDASHBOARD, SQLScripts/2568): the period's sales split into
/// POS (walk-in), Direct (patient / credit customer) and IPD (issues to admitted patients), with the document list.
/// </summary>
[Authorize]
public class PhSalesDashboardController(IPharmacySalesDashboardService dashboard, ILogger<PhSalesDashboardController> logger) : Controller
{
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();

    private static readonly string[] Channels = ["POS", "DIRECT", "IPD"];

    [HttpGet]
    public async Task<IActionResult> Index(string? range, DateTime? from, DateTime? to, string? channel, string? search, int page = 1, int pageSize = 25)
    {
        var today = DateTime.Today;
        range = (range ?? (from != null || to != null ? "custom" : "month")).ToLowerInvariant();
        (from, to) = range switch
        {
            "today" => (today, today),
            "yesterday" => (today.AddDays(-1), today.AddDays(-1)),
            "7d" => (today.AddDays(-6), today),
            "30d" => (today.AddDays(-29), today),
            "lastmonth" => (new DateTime(today.Year, today.Month, 1).AddMonths(-1), new DateTime(today.Year, today.Month, 1).AddDays(-1)),
            "custom" => (from?.Date ?? new DateTime(today.Year, today.Month, 1), to?.Date ?? today),
            _ => (new DateTime(today.Year, today.Month, 1), today)
        };
        if (range is not ("today" or "yesterday" or "7d" or "30d" or "lastmonth" or "custom")) range = "month";
        if (to < from) (from, to) = (to, from);
        if ((to!.Value - from!.Value).TotalDays > 365) from = to.Value.AddDays(-365);

        channel = channel?.ToUpperInvariant();
        if (channel != null && !Channels.Contains(channel)) channel = null;
        page = Math.Max(1, page);
        pageSize = pageSize is 10 or 25 or 50 or 100 ? pageSize : 25;

        PhSalesDashboard model;
        try
        {
            model = await dashboard.GetAsync(CompanyId, BranchId, from.Value, to.Value, channel, search?.Trim(), page, pageSize);
        }
        catch (Exception ex) when (ex is HttpRequestException or InvalidOperationException or TaskCanceledException)
        {
            logger.LogWarning(ex, "Pharmacy sales dashboard could not be loaded");
            ViewBag.Error = ex is InvalidOperationException ? ex.Message : "The EMR API is not reachable. Try again in a moment.";
            model = new PhSalesDashboard { From = from.Value, To = to.Value, Channel = channel, Search = search, Page = page, PageSize = pageSize };
        }
        model.Range = range;
        return View("~/Views/PharmacySales/Dashboard.cshtml", model);
    }
}
