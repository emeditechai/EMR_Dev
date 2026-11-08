using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD > Doctor Visit Charges (SQLScripts/2434): the IPD visit fee of each IPD doctor by visit type (routine round,
/// emergency, cross consultation, night) and tariff category, with effective dates. Separate from the OPD consulting fee;
/// the Doctor Visits tab of the IPD Patient workspace charges from it. Page IPD.DOCTORFEE: VIEW, SAVE, DELETE.
/// </summary>
[Authorize]
public class IpdDoctorFeeController(IpdApiClient api, IAuditLogService auditLogService, ILogger<IpdDoctorFeeController> logger) : Controller
{
    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, string description)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            await auditLogService.LogActivityAsync(eventType: "IPD Masters", actionName: action, description: description, userId: User.GetUserId(),
                branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: row.I("FeeId"));
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    [HttpGet]
    public IActionResult Index()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        return View();
    }

    [HttpGet]
    public Task<IActionResult> Lookups() => Read(async () =>
    {
        var s = await api.SetsAsync("/doctor-fees/lookups");
        return new { doctors = s.ElementAtOrDefault(0), tariffCategories = s.ElementAtOrDefault(1) };
    });

    [HttpGet]
    public Task<IActionResult> ListData(int? doctorId, string? search, bool includeInactive = false) => Read(async () =>
        await api.GetAsync("/doctor-fees" + IpdApiClient.Q(("doctorId", doctorId), ("search", search), ("includeInactive", includeInactive))));

    public sealed class FeeBody
    {
        public int? FeeId { get; set; }
        public int DoctorId { get; set; }
        public string? VisitType { get; set; }
        public int? TariffCategoryId { get; set; }
        public decimal Rate { get; set; }
        public DateTime EffectiveFrom { get; set; }
        public DateTime? EffectiveTo { get; set; }
        public string? Remarks { get; set; }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Save([FromBody] FeeBody b) =>
        Write(() => api.PostAsync("/doctor-fees", b), "IPD.DoctorFeeSave", $"IPD visit charge {(b.FeeId is null ? "added" : "edited")}: doctor {b.DoctorId}, {b.VisitType}, ₹{b.Rate:N2} from {b.EffectiveFrom:dd-MMM-yyyy}");

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Remove(int id) =>
        Write(() => api.PostAsync($"/doctor-fees/{id}/remove", new { }), "IPD.DoctorFeeRemove", $"IPD visit charge {id} removed");
}
