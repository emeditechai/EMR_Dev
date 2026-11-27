using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD Phase 3 - Clinical (SQLScripts/2562-2565): the Clinical tab (doctor's assessment, rounds / progress notes, CPOE orders with
/// verbal-order countersign, cross-consultation), the Nursing tab (eMAR, vitals with NEWS2, intake / output, nursing notes, Morse /
/// Braden risk, nursing assessment, care plan, SBAR handover, incidents) and IPD > Nursing Station. Each write checks its own
/// IPD.PATIENT control; page IPD.NURSINGSTATION. Web -> EMR.Api api/ipd -> procedures.
/// </summary>
[Authorize]
public class IpdClinicalController(IpdApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, ILogger<IpdClinicalController> logger) : Controller
{
    public const string StationPage = "IPD.NURSINGSTATION";
    private const string PatientPage = IpdAdmissionController.PatientPage;

    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    /// <summary>Checks the control, calls the API, writes the audit line (when given) and returns the procedure's row.</summary>
    private async Task<IActionResult> Write(string control, Func<Task<JsonElement>> call, string? action = null, string? description = null, int refId = 0)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, PatientPage, control)) return Fail(PermissionFilter.DeniedMessage);
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            if (action != null)
                await auditLogService.LogActivityAsync(eventType: "IPD Clinical", actionName: action, description: description, userId: User.GetUserId(),
                    branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    private static JsonElement? P(JsonElement b, string name) => b.ValueKind == JsonValueKind.Object && b.TryGetProperty(name, out var v) && v.ValueKind != JsonValueKind.Null ? v : null;
    private static string? Str(JsonElement b, string name) => P(b, name) is { } v ? (v.ValueKind == JsonValueKind.String ? v.GetString() : v.ToString()) : null;
    private static bool Bool(JsonElement b, string name) => P(b, name) is { } v && (v.ValueKind == JsonValueKind.True || (v.ValueKind == JsonValueKind.String && v.GetString() == "true"));

    // ── reads ──────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> Data(int id) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/clinical");
        return new
        {
            state = s.ElementAtOrDefault(0), assessments = s.ElementAtOrDefault(1), notes = s.ElementAtOrDefault(2), orders = s.ElementAtOrDefault(3),
            consults = s.ElementAtOrDefault(4), frequencies = s.ElementAtOrDefault(5), doctors = s.ElementAtOrDefault(6)
        };
    });

    [HttpGet]
    public Task<IActionResult> NursingData(int id, DateTime? fromAt, DateTime? toAt) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/nursing" + IpdApiClient.Q(("fromAt", fromAt?.ToString("yyyy-MM-ddTHH:mm")), ("toAt", toAt?.ToString("yyyy-MM-ddTHH:mm"))));
        return new
        {
            state = s.ElementAtOrDefault(0), medOrders = s.ElementAtOrDefault(1), doses = s.ElementAtOrDefault(2), vitals = s.ElementAtOrDefault(3),
            io = s.ElementAtOrDefault(4), notes = s.ElementAtOrDefault(5), risks = s.ElementAtOrDefault(6), plans = s.ElementAtOrDefault(7),
            handovers = s.ElementAtOrDefault(8), incidents = s.ElementAtOrDefault(9), instructions = s.ElementAtOrDefault(10)
        };
    });

    [HttpGet]
    public Task<IActionResult> Services(string? q) => Read(async () => await api.GetAsync("/clinical/services" + IpdApiClient.Q(("q", q))));

    // ── IPD > Nursing Station ──────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Station()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        ViewData["CanPatient"] = await permissionGuard.AllowsAsync(HttpContext, PatientPage, "VIEW");
        return View();
    }

    [HttpGet]
    public Task<IActionResult> StationData(int? stationId) => Read(async () =>
    {
        var s = await api.SetsAsync("/nursing-station" + IpdApiClient.Q(("stationId", stationId)));
        var rows = s.ElementAtOrDefault(1);
        // the patient workspace link (encrypted, opened on the Nursing tab)
        var links = rows.ValueKind == JsonValueKind.Array
            ? rows.EnumerateArray().Select(r => new { id = r.I("AdmissionId"), url = Url.ActionEncrypted("Patient", "IpdAdmission", new { id = r.I("AdmissionId"), tab = "nursing" }) }).ToList()
            : [];
        return new { stations = s.ElementAtOrDefault(0), patients = rows, links };
    });

    // ── doctor ─────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SaveAssessment(int id, [FromBody] JsonElement b) =>
        Write("CLIN_ASSESS", () => api.PostAsync($"/admissions/{id}/assessment", new { Kind = "DOCTOR", Data = Str(b, "data") ?? "{}", Sign = Bool(b, "sign"), AmendReason = Str(b, "amendReason") }),
            Bool(b, "sign") ? "IPD.DoctorAssessmentSign" : null, $"Admission {id}: doctor's initial assessment signed", id);

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SaveNursingAssessment(int id, [FromBody] JsonElement b) =>
        Write("NURS_ASSESS", () => api.PostAsync($"/admissions/{id}/assessment", new { Kind = "NURSING", Data = Str(b, "data") ?? "{}", Sign = Bool(b, "sign"), AmendReason = Str(b, "amendReason") }),
            Bool(b, "sign") ? "IPD.NursingAssessmentSign" : null, $"Admission {id}: nursing initial assessment signed", id);

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SaveNote(int id, [FromBody] JsonElement b) =>
        Write("CLIN_NOTE", () => api.PostAsync($"/admissions/{id}/notes", b), Bool(b, "sign") ? "IPD.NoteSign" : null, $"Admission {id}: {Str(b, "noteType")} note signed", id);

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SaveOrder(int id, [FromBody] JsonElement b) =>
        Write("CLIN_ORDER", () => api.PostAsync($"/admissions/{id}/orders", b), "IPD.Order",
            $"Admission {id}: {Str(b, "orderType")} order {Str(b, "drugName") ?? Str(b, "dietType") ?? Str(b, "details") ?? ""}".Trim(), id);

    public sealed class OrderActionBody { public int OrderId { get; set; } public string? Reason { get; set; } public DateTime? At { get; set; } public int? IndentId { get; set; } }

    private Task<IActionResult> OrderAction(string control, string action, OrderActionBody b, bool audit = true) =>
        Write(control, () => api.PostAsync($"/orders/{b.OrderId}/action", new { Action = action, b.Reason, b.At, b.IndentId }),
            audit ? "IPD.Order" + action : null, $"Order {b.OrderId}: {action}{(string.IsNullOrWhiteSpace(b.Reason) ? "" : " - " + b.Reason)}", b.OrderId);

    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> StopOrder([FromBody] OrderActionBody b) => OrderAction("CLIN_ORDER", "STOP", b);
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> CancelOrder([FromBody] OrderActionBody b) => OrderAction("CLIN_ORDER", "CANCEL", b);
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> Countersign([FromBody] OrderActionBody b) => OrderAction("CLIN_COUNTERSIGN", "COUNTERSIGN", b);
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> AckOrder([FromBody] OrderActionBody b) => OrderAction("NURS_MAR", "ACK", b, audit: false);
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> OrderDone([FromBody] OrderActionBody b) => OrderAction("ORDER_DONE", "DONE", b);
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> LinkIndent([FromBody] OrderActionBody b) => OrderAction("CLIN_ORDER", "INDENT", b, audit: false);

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> CrossConsult(int id, [FromBody] JsonElement b) =>
        Write("CLIN_CONSULT", () => api.PostAsync($"/admissions/{id}/cross-consults", b), "IPD.CrossConsult",
            $"Admission {id}: cross-consultation {(Bool(b, "cancel") ? "cancelled" : "requested")}", id);

    // ── nursing ────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Mar(int orderId, [FromBody] JsonElement b) =>
        Write("NURS_MAR", () => api.PostAsync($"/orders/{orderId}/mar", b), Str(b, "outcome") is "HELD" or "REFUSED" ? "IPD.MarNotGiven" : null,
            $"Order {orderId}: dose {Str(b, "outcome")} - {Str(b, "reason")}", orderId);

    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> Vital(int id, [FromBody] JsonElement b) => Write("NURS_CHART", () => api.PostAsync($"/admissions/{id}/vitals", b));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> IntakeOutput(int id, [FromBody] JsonElement b) => Write("NURS_CHART", () => api.PostAsync($"/admissions/{id}/intake-output", b));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> NursingNote(int id, [FromBody] JsonElement b) => Write("NURS_CHART", () => api.PostAsync($"/admissions/{id}/nursing-notes", b));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> Risk(int id, [FromBody] JsonElement b) => Write("NURS_CHART", () => api.PostAsync($"/admissions/{id}/risk", b));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> CarePlan(int id, [FromBody] JsonElement b) => Write("NURS_ASSESS", () => api.PostAsync($"/admissions/{id}/care-plan", b));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> Handover(int id, [FromBody] JsonElement b) => Write("NURS_HANDOVER", () => api.PostAsync($"/admissions/{id}/handover", b));

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Incident(int id, [FromBody] JsonElement b) =>
        Write("NURS_INCIDENT", () => api.PostAsync($"/admissions/{id}/incidents", b), "IPD.Incident",
            $"Admission {id}: incident {(Bool(b, "close") ? "closed" : $"{Str(b, "incidentType")} ({Str(b, "severity")}) reported")}", id);

    public sealed class StrikeBody { public string Kind { get; set; } = ""; public long Id { get; set; } public string? Reason { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Strike([FromBody] StrikeBody b) =>
        Write("CLIN_CORRECT", () => api.PostAsync("/clinical/strike", new { b.Kind, b.Id, b.Reason }), "IPD.ClinicalStrike", $"{b.Kind} {b.Id} struck out: {b.Reason}", (int)b.Id);
}
