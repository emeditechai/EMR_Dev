using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD Patient workspace > LAB and Radiology tabs (Phase 4, SQLScripts/2436): tests ordered for an admitted patient at the
/// branch's IPD LAB rates, charged to the IP bill. The order is an ordinary LAB order, so the LAB screens (sample collection,
/// result entry, reports) work it as usual. Controls of IPD.PATIENT: LAB_ORDER, LAB_CANCEL. Web -> EMR.Api api/ipd -> procedures.
/// </summary>
[Authorize]
public class IpdLabController(IpdApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, ILogger<IpdLabController> logger) : Controller
{
    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, string description, int refId)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            await auditLogService.LogActivityAsync(eventType: "IPD LAB", actionName: action, description: description + (row.S("BillNo") is { Length: > 0 } b ? $" ({b})" : ""),
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    [HttpGet]
    public Task<IActionResult> LabItems(int id, string? kind) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/lab-items" + IpdApiClient.Q(("kind", kind)));
        return new { items = s.ElementAtOrDefault(0), hasRateList = s.ElementAtOrDefault(1) };
    });

    [HttpGet]
    public Task<IActionResult> LabOrders(int id, string? kind, bool includeCancelled = false) => Read(async () =>
        await api.GetAsync($"/admissions/{id}/lab-orders" + IpdApiClient.Q(("kind", kind), ("includeCancelled", includeCancelled))));

    public sealed class OrderLine { public string ItemType { get; set; } = ""; public int ItemId { get; set; } public bool IsUrgent { get; set; } }
    public sealed class OrderBody { public List<OrderLine> Items { get; set; } = []; public int? DoctorId { get; set; } public string? Remarks { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Order(int id, [FromBody] OrderBody b)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, IpdAdmissionController.PatientPage, "LAB_ORDER")) return Fail(PermissionFilter.DeniedMessage);
        if (b.Items.Count == 0) return Fail("Add at least one test.");
        return await Write(() => api.PostAsync($"/admissions/{id}/lab-orders", new { Items = JsonSerializer.Serialize(b.Items), b.DoctorId, b.Remarks }),
            "IPD.LabOrder", $"Admission {id}: {b.Items.Count} LAB item(s) ordered", id);
    }

    public sealed class ReasonBody { public string? Reason { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CancelItem(int itemId, [FromBody] ReasonBody b)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, IpdAdmissionController.PatientPage, "LAB_CANCEL")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/lab-items/{itemId}/cancel", new { b.Reason }), "IPD.LabCancel", $"LAB test {itemId} cancelled: {b.Reason}", itemId);
    }
}
