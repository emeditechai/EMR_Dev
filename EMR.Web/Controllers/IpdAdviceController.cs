using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// OPD admission advice (Phase 4, SQLScripts/2438). OPD > Doctor Dashboard > consultation > Advise Admission (control
/// ADVISE_ADMISSION of OPD.DOCTORDASHBOARD) saves it; the IPD Dashboard lists the pending ones (IPD.INDEX) and admits from
/// them (IPD.ADMISSION, ADVICE_CANCEL to cancel). Web -> EMR.Api api/ipd/advice -> stored procedures.
/// </summary>
[Authorize]
public class IpdAdviceController(IpdApiClient api, IAuditLogService auditLogService, ILogger<IpdAdviceController> logger) : Controller
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
            await auditLogService.LogActivityAsync(eventType: "IPD Advice", actionName: action, description: description, userId: User.GetUserId(),
                branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: row.I("AdviceId"));
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    [HttpGet]
    public Task<IActionResult> List(string? status) => Read(async () => await api.GetAsync("/advice" + IpdApiClient.Q(("status", status ?? "PENDING"))));

    /// <summary>The pending advice of an OPD visit (to edit it from the consultation).</summary>
    [HttpGet]
    public Task<IActionResult> ForVisit(int opdServiceId) => Read(async () => await api.GetAsync("/advice" + IpdApiClient.Q(("status", "PENDING"), ("opdServiceId", opdServiceId))));

    [HttpGet]
    public Task<IActionResult> Departments() => Read(async () => await api.GetAsync("/advice/departments"));

    [HttpGet]
    public Task<IActionResult> Icd(string? q) => Read(async () => await api.GetAsync("/icd" + IpdApiClient.Q(("q", q))));

    public sealed class AdviceBody
    {
        public int OpdServiceId { get; set; }
        public string? Reason { get; set; }
        public string? Diagnosis { get; set; }
        public string? DiagnosisCode { get; set; }
        public string? Urgency { get; set; }
        public DateTime? ExpectedAt { get; set; }
        public int? DepartmentId { get; set; }
        public string? Remarks { get; set; }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Save([FromBody] AdviceBody b) =>
        Write(() => api.PostAsync("/advice", b), "IPD.AdviseAdmission", $"Admission advised from OPD visit {b.OpdServiceId} ({b.Urgency}): {b.Reason}");

    public sealed class ReasonBody { public string? Reason { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Cancel(int id, [FromBody] ReasonBody b) =>
        Write(() => api.PostAsync($"/advice/{id}/cancel", new { b.Reason }), "IPD.AdviceCancel", $"Admission advice {id} cancelled: {b.Reason}");
}
