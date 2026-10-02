using System;
using System.Linq;
using System.Security.Claims;
using System.Threading.Tasks;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class LabDashboardController(
    ILabDashboardApiClient labDashboardApiClient,
    ApplicationDbContext dbContext,
    IActionPermissionGuard permissionGuard) : Controller
{
    public const string PageCode = "LAB.LABDASHBOARD";

    /// <summary>The client tabs in display order and the page control that grants each (Role Permissions, script 2188).</summary>
    public static readonly (string Client, string Control)[] ClientTabs =
        [("ALL", "CLIENT_ALL"), ("B2C", "CLIENT_B2C"), ("B2B", "CLIENT_B2B")];

    [HttpGet]
    public async Task<IActionResult> Index(string? date, string? clientType)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "Please select a branch first.";
            return RedirectToAction("SelectBranch", "Account");
        }

        var selectedDate = DateTime.TryParse(date, out var d) ? d : DateTime.Today;
        var dateStr = selectedDate.ToString("yyyy-MM-dd");

        var hospitalSettings = await dbContext.HospitalSettings
            .Where(x => x.BranchId == branchId.Value)
            .Select(x => new { x.HospitalName, x.LogoPath })
            .FirstOrDefaultAsync();

        var currentBranchName = User.FindFirstValue("BranchName") ?? "N/A";
        // Which client tabs the user may use; the tab asked for is served only when they hold it, otherwise the first they hold.
        var allowed = new List<string>();
        foreach (var (tab, control) in ClientTabs)
        {
            if (await permissionGuard.ShowsAsync(HttpContext, PageCode, control)) allowed.Add(tab);
        }

        var requested = clientType?.Trim().ToUpperInvariant() is "ALL" or "B2B" or "B2C" ? clientType!.Trim().ToUpperInvariant() : null;
        string? client = null;
        if (requested is not null)
        {
            var control = ClientTabs.First(t => t.Client == requested).Control;
            // logs the refusal of a tab asked for in the address (and lets it through while the module is in audit)
            if (await permissionGuard.AllowsAsync(HttpContext, PageCode, control)) client = requested;
        }
        client ??= allowed.FirstOrDefault();
        if (client is null)
        {
            // none of the tabs: every figure on the page belongs to one of them
            return RedirectToAction("AccessDenied", "Account",
                new { returnUrl = Request.Path + Request.QueryString, page = PageCode,
                      control = ClientTabs.FirstOrDefault(t => t.Client == requested).Control ?? ClientTabs[0].Control });
        }
        if (!allowed.Contains(client)) allowed.Add(client);   // audit mode: served, so shown
        allowed = ClientTabs.Select(t => t.Client).Where(allowed.Contains).ToList();

        var labData = await labDashboardApiClient.GetDashboardStatsAsync(branchId.Value, dateStr, client)
                      ?? new ApiClients.Models.LabDashboardData();

        var model = new LabDashboardViewModel
        {
            UserDisplayName = User.FindFirstValue("DisplayName") ?? User.Identity?.Name ?? "User",
            CurrentBranchName = currentBranchName,
            CurrentHospitalName = string.IsNullOrWhiteSpace(hospitalSettings?.HospitalName)
                ? currentBranchName
                : hospitalSettings.HospitalName!,
            HospitalLogoPath = hospitalSettings?.LogoPath,
            SelectedDate = dateStr,
            ClientType = client,
            AllowedClientTypes = allowed,
            Data = labData
        };

        ViewData["Title"] = "LAB Dashboard";
        return View(model);
    }
}
