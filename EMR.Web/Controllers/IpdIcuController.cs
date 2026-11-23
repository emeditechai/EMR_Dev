using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD Phase 8 - ICU (SQLScripts/2493, 2494): IPD > ICU Board and the ICU Chart tab of the IPD Patient workspace (hourly flowsheet,
/// infusions, device use, ICU stays with return within 48 h, chart print). Controls: IPD.PATIENT ICU_CHART, ICU_CORRECT; page IPD.ICUBOARD.
/// Web -> EMR.Api api/ipd -> procedures.
/// </summary>
[Authorize]
public class IpdIcuController(IpdApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, IPrintTemplateRuntime printRuntime, ILogger<IpdIcuController> logger) : Controller
{
    public const string BoardPage = "IPD.ICUBOARD";
    private const string PatientPage = IpdAdmissionController.PatientPage;

    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(string control, Func<Task<JsonElement>> call, string action, string description, int refId, bool audit = true)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, PatientPage, control)) return Fail(PermissionFilter.DeniedMessage);
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            if (audit)
                await auditLogService.LogActivityAsync(eventType: "IPD ICU", actionName: action, description: description, userId: User.GetUserId(),
                    branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    private static object Sets(List<JsonElement> s) => new
    {
        state = s.ElementAtOrDefault(0), stays = s.ElementAtOrDefault(1), observations = s.ElementAtOrDefault(2), infusions = s.ElementAtOrDefault(3),
        events = s.ElementAtOrDefault(4), devices = s.ElementAtOrDefault(5), deviceHeads = s.ElementAtOrDefault(6), io = s.ElementAtOrDefault(7)
    };

    private static string Window(DateTime? fromAt, DateTime? toAt) =>
        IpdApiClient.Q(("fromAt", fromAt?.ToString("yyyy-MM-ddTHH:mm")), ("toAt", toAt?.ToString("yyyy-MM-ddTHH:mm")));

    // ── IPD > ICU Board ─────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Board()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        ViewData["CanPatient"] = await permissionGuard.AllowsAsync(HttpContext, PatientPage, "VIEW");
        return View();
    }

    [HttpGet]
    public Task<IActionResult> BoardData() => Read(async () =>
    {
        var s = await api.SetsAsync("/icu/board");
        return new { patients = s.ElementAtOrDefault(0), beds = s.ElementAtOrDefault(1), returns = s.ElementAtOrDefault(2) };
    });

    // ── ICU Chart tab ───────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> Data(int id, DateTime? fromAt, DateTime? toAt) => Read(async () => Sets(await api.SetsAsync($"/admissions/{id}/icu" + Window(fromAt, toAt))));

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> AddObservation(int id, [FromBody] JsonElement b) =>
        Write("ICU_CHART", () => api.PostAsync($"/admissions/{id}/icu/observations", b), "IPD.IcuObservation", $"Admission {id}: ICU observation", id, audit: false);

    public sealed class StrikeBody { public string Kind { get; set; } = ""; public long Id { get; set; } public string? Reason { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Strike([FromBody] StrikeBody b) =>
        Write("ICU_CORRECT", () => api.PostAsync("/icu/strike", new { b.Kind, b.Id, b.Reason }), "IPD.IcuStrike", $"ICU {b.Kind} {b.Id} struck out: {b.Reason}", (int)b.Id);

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Infusion(int id, [FromBody] JsonElement b) =>
        Write("ICU_CHART", () => api.PostAsync($"/admissions/{id}/icu/infusions", b), "IPD.IcuInfusion",
            $"Admission {id}: infusion {(b.S("eventType") is { Length: > 0 } t ? t : "START")} {b.S("drug")}", id);

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Device(int id, [FromBody] JsonElement b) =>
        Write("ICU_CHART", () => api.PostAsync($"/admissions/{id}/icu/devices", b), "IPD.IcuDevice",
            $"Admission {id}: {(b.Prop("deviceId") is null ? "device started " + b.S("headName") : "device stopped")}", id);

    /// <summary>ICU chart print of a window (default the last 24 hours).</summary>
    [HttpGet]
    public async Task<IActionResult> PrintChart(int id, DateTime? fromAt, DateTime? toAt)
    {
        try
        {
            var s = await api.SetsAsync($"/admissions/{id}/icu" + Window(fromAt, toAt));
            var head = await api.SetsAsync($"/admissions/{id}");
            var header = head.ElementAtOrDefault(0);
            if (header.ValueKind != JsonValueKind.Array || header.GetArrayLength() == 0) return NotFound();
            if (header[0].I("BranchId") is var br && br > 0 && br != (User.GetCurrentBranchId() ?? 0)) return NotFound();
            await IpdPrint.PrepareAsync(this, printRuntime, logger, User.GetCurrentBranchId() ?? 0,
                new PrintDocInfo { DocNo = header[0].S("IpNo"), DocDate = DateTime.Now.ToString("dd-MMM-yyyy HH:mm"), CopyLabel = "Original", PrintedBy = this.PrintedBy() });
            ViewData["Print"] = JsonSerializer.Serialize(new { header = header[0], chart = Sets(s), printedBy = User.Identity?.Name, printedAt = DateTime.Now });
            return View();
        }
        catch (HttpRequestException) { ViewData["PageName"] = "ICU Chart"; return View("ApiDown"); }
        catch (InvalidOperationException ex) { return Content(ex.Message); }
    }
}
