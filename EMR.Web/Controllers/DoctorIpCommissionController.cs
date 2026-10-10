using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

/// <summary>
/// Doctor IP commission computed from lab orders. The commission screen is confidential: it opens only while
/// Doctor IP is unlocked with the company access code (same session unlock as <see cref="DoctorIpController"/>).
/// The Reports > LAB pages in this controller need only their page permission.
/// </summary>
[Authorize]
public class DoctorIpCommissionController(
    IDoctorIpCommissionApiClient apiClient,
    IDoctorIpApiClient doctorIpApiClient,
    IReportApiClient reportApiClient,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService) : Controller
{
    // Must match DoctorIpController.UnlockKey: one unlock opens both pages.
    private string UnlockKey => $"DoctorIp.UnlockedUntil.{User.GetCompanyId()}.{User.GetUserId()}";

    private DateTime? UnlockedUntil()
    {
        var raw = HttpContext.Session.GetString(UnlockKey);
        return long.TryParse(raw, out var ticks) ? new DateTime(ticks, DateTimeKind.Utc) : null;
    }

    // Reports > LAB pages: governed by the normal page permission only, no access code.
    private static readonly string[] OpenActions =
        [nameof(ReportBusiness), nameof(ReportStatement), nameof(ReportItemWise), nameof(ReportPending), nameof(ReportUnconfigured), nameof(GetReportData)];

    public override async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        if (OpenActions.Contains(context.RouteData.Values["action"]?.ToString(), StringComparer.OrdinalIgnoreCase))
        {
            await next();
            return;
        }

        var until = UnlockedUntil();
        if (until == null || until.Value < DateTime.UtcNow)
        {
            HttpContext.Session.Remove(UnlockKey);
            context.Result = RedirectToAction("Unlock", "DoctorIp",
                new { returnUrl = Request.Method == "GET" ? Request.Path + Request.QueryString : Url.Action(nameof(Index)) });
            return;
        }

        var minutes = HttpContext.Session.GetInt32(UnlockKey + ".Minutes") ?? 15;
        HttpContext.Session.SetString(UnlockKey, DateTime.UtcNow.AddMinutes(minutes).Ticks.ToString());
        await next();
    }

    [HttpGet]
    public async Task<IActionResult> Index(int? doctorId = null, DateTime? fromDate = null, DateTime? toDate = null, string tab = "pending")
    {
        var branchId = User.GetCurrentBranchId();
        if (!branchId.HasValue)
        {
            TempData["ErrorMessage"] = "Select a branch to work with Doctor IP commission.";
            return RedirectToAction("Index", "Home");
        }

        var from = (fromDate ?? new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1)).Date;
        var to = (toDate ?? DateTime.Today).Date;
        if (to < from) (from, to) = (to, from);
        var companyId = User.GetCompanyId();

        try
        {
            var pending = await apiClient.GetPendingAsync(branchId.Value, doctorId, from, to, companyId);
            var computed = await apiClient.GetListAsync(branchId, doctorId, from, to, companyId);
            var setups = await doctorIpApiClient.GetListAsync(companyId, branchId);
            var until = UnlockedUntil();
            var (mode, runTime) = await RunSettingsAsync(branchId.Value);

            return View(new DoctorIpCommissionIndexViewModel
            {
                ComputeMode = mode,
                AutoRunTime = runTime,
                PendingItems = pending.ToList(),
                ComputedItems = computed.ToList(),
                SelectedDoctorId = doctorId,
                FromDate = from,
                ToDate = to,
                ActiveTab = tab == "computed" ? "computed" : "pending",
                BranchName = (await dbContext.BranchMasters.FindAsync(branchId.Value))?.BranchName,
                UnlockMinutesLeft = until == null ? 0 : Math.Max(0, (int)Math.Ceiling((until.Value - DateTime.UtcNow).TotalMinutes)),
                DoctorOptions = setups.GroupBy(s => s.Doctor_ID).Select(g => g.First()).OrderBy(s => s.Doctor_Name)
                    .Select(s => new SelectListItem { Value = s.Doctor_ID.ToString(), Text = s.Doctor_Name, Selected = s.Doctor_ID == doctorId })
                    .ToList()
            });
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Doctor IP Commission";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Calculate(int? doctorId, DateTime fromDate, DateTime toDate)
    {
        var branchId = User.GetCurrentBranchId();
        if (!branchId.HasValue) return RedirectToAction(nameof(Index));
        if ((await RunSettingsAsync(branchId.Value)).Mode == "Automatic")
        {
            TempData["ErrorMessage"] = "Doctor IP commission is set to Automatic in Hospital Settings; it is computed by the scheduled job only.";
            return RedirectToAction(nameof(Index), new { doctorId });
        }
        if (fromDate == default || toDate == default || toDate.Date < fromDate.Date)
        {
            TempData["ErrorMessage"] = "Choose a valid From and To date before calculating.";
            return RedirectToAction(nameof(Index), new { doctorId });
        }

        try
        {
            var results = (await apiClient.CalculateAsync(new DoctorIpCommissionCalculateRequestModel
            {
                BranchId = branchId.Value,
                DoctorId = doctorId,
                FromDate = fromDate.Date,
                ToDate = toDate.Date,
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId(),
                Source = "MANUAL"
            })).ToList();

            if (results.Count == 0)
            {
                TempData["ErrorMessage"] = "No pending lab order items found for the selected doctor and period.";
                return RedirectToAction(nameof(Index), new { doctorId, fromDate = fromDate.ToString("yyyy-MM-dd"), toDate = toDate.ToString("yyyy-MM-dd") });
            }

            var items = results.Sum(r => r.Items_Computed);
            var total = results.Sum(r => r.Total_Commission);
            await auditLogService.LogAsync("Calculate Doctor IP Commission", "Create",
                $"Computed Doctor IP commission {fromDate:dd-MMM-yyyy} to {toDate:dd-MMM-yyyy}: {results.Count} doctor(s), {items} item(s), total {total:N2}",
                User.GetUserId(), branchId.Value);

            TempData["SuccessMessage"] = $"Commission computed for {results.Count} doctor(s): {items} test(s), total ₹{total:N2}.";
            return RedirectToAction(nameof(Index), new { doctorId, fromDate = fromDate.ToString("yyyy-MM-dd"), toDate = toDate.ToString("yyyy-MM-dd"), tab = "computed" });
        }
        catch (InvalidOperationException ex)
        {
            TempData["ErrorMessage"] = ex.Message;
            return RedirectToAction(nameof(Index), new { doctorId, fromDate = fromDate.ToString("yyyy-MM-dd"), toDate = toDate.ToString("yyyy-MM-dd") });
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Doctor IP Commission";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(long id)
    {
        try
        {
            var item = await apiClient.GetDetailAsync(id);
            var branchId = User.GetCurrentBranchId();
            if (item == null || (branchId.HasValue && item.Header.Branch_ID != branchId.Value))
            {
                TempData["ErrorMessage"] = "Commission record not found for this branch.";
                return RedirectToAction(nameof(Index), new { tab = "computed" });
            }
            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Doctor IP Commission";
            return View("ApiDown");
        }
    }

    /// <summary>Hospital Settings > LAB: how commission is computed for the branch, and the scheduled time.</summary>
    private async Task<(string Mode, TimeSpan? RunTime)> RunSettingsAsync(int branchId)
    {
        var s = await dbContext.HospitalSettings.AsNoTracking()
            .Where(x => x.BranchId == branchId && x.IsActive)
            .Select(x => new { x.DoctorIpComputeMode, x.DoctorIpAutoRunTime })
            .FirstOrDefaultAsync();
        return (string.IsNullOrWhiteSpace(s?.DoctorIpComputeMode) ? "Manual" : s!.DoctorIpComputeMode, s?.DoctorIpAutoRunTime);
    }

    // ── Reports > LAB > Doctor IP (Views/DoctorIpCommission/Report*.cshtml on the shared LAB report shell) ──

    private static readonly Dictionary<string, string[]> ReportFilters = new(StringComparer.OrdinalIgnoreCase)
    {
        ["doctorip-business"]     = ["doctorId", "commissionStatus"],
        ["doctorip-statement"]    = ["doctorId", "itemType"],
        ["doctorip-itemwise"]     = ["doctorId", "itemType"],
        ["doctorip-pending"]      = ["doctorId", "itemType", "frequency"],
        ["doctorip-unconfigured"] = ["doctorId", "reason"],
    };

    [HttpGet] public IActionResult ReportBusiness() => View();
    [HttpGet] public IActionResult ReportStatement() => View();
    [HttpGet] public IActionResult ReportItemWise() => View();
    [HttpGet] public IActionResult ReportPending() => View();
    [HttpGet] public IActionResult ReportUnconfigured() => View();

    [HttpGet]
    public async Task<IActionResult> GetReportData(string report, string fromDate, string toDate, string? search)
    {
        if (string.IsNullOrWhiteSpace(report) || !ReportFilters.TryGetValue(report, out var filters))
            return Json(new { success = false, message = "Unknown report." });
        var branchId = User.GetCurrentBranchId();
        if (!branchId.HasValue) return Json(new { success = false, message = "Select a branch first." });

        if (!DateTime.TryParse(fromDate, out var fDate)) fDate = DateTime.Today;
        if (!DateTime.TryParse(toDate, out var tDate)) tDate = DateTime.Today;
        if (tDate < fDate) (fDate, tDate) = (tDate, fDate);
        if ((tDate - fDate).TotalDays > 366)
            return Json(new { success = false, message = "Please select a date range of up to one year." });

        var query = new Dictionary<string, string?>
        {
            ["branchId"] = branchId.Value.ToString(),
            ["fromDate"] = fDate.ToString("yyyy-MM-dd"),
            ["toDate"] = tDate.ToString("yyyy-MM-dd"),
            ["search"] = search,
            ["userId"] = User.GetUserId().ToString(),
            ["isAdmin"] = "true",
            ["isSuperAdmin"] = User.IsSuperAdmin() ? "true" : "false"
        };
        foreach (var f in filters) query[f] = Request.Query[f].ToString();

        var result = await reportApiClient.RunLabReportRawAsync(report, query);
        if (!result.IsSuccess)
            return Json(new { success = false, message = result.ErrorMessage ?? "Unable to load the report." });
        return Content("{\"success\":true,\"scope\":\"ALL\",\"data\":" + result.Data + "}", "application/json");
    }
}
