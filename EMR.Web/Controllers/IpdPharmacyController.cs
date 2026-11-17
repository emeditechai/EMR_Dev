using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD Patient workspace > Medicines and Consumables tabs (Phase 4, SQLScripts/2437): pharmacy issue of batches from a
/// selling store against the IP number (charged to the IP bill) and return of unused quantity. Controls of IPD.PATIENT:
/// PH_ISSUE, PH_RETURN. Web -> EMR.Api api/ipd -> stored procedures (stock through usp_PhStock_Move).
/// </summary>
[Authorize]
public class IpdPharmacyController(IpdApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, ILogger<IpdPharmacyController> logger) : Controller
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
            await auditLogService.LogActivityAsync(eventType: "IPD Pharmacy", actionName: action, description: description + (row.S("IssueNo") is { Length: > 0 } n ? $" ({n})" : ""),
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    [HttpGet]
    public Task<IActionResult> PhItems(int id, string? q, int? storeId) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/ph-items" + IpdApiClient.Q(("q", q), ("storeId", storeId)));
        return new { items = s.ElementAtOrDefault(0), stores = s.ElementAtOrDefault(1) };
    });

    [HttpGet]
    public Task<IActionResult> PhBatches(int itemId, int? storeId) => Read(async () => await api.GetAsync($"/ph-batches/{itemId}" + IpdApiClient.Q(("storeId", storeId))));

    [HttpGet]
    public Task<IActionResult> PhIssues(int id, string? head) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/ph-issues" + IpdApiClient.Q(("head", head)));
        return new { issues = s.ElementAtOrDefault(0), returns = s.ElementAtOrDefault(1) };
    });

    public sealed class IssueLine { public int ItemId { get; set; } public int BatchId { get; set; } public decimal Qty { get; set; } }
    public sealed class IssueBody { public List<IssueLine> Lines { get; set; } = []; public string? Head { get; set; } public int? StoreId { get; set; } public int? DoctorId { get; set; } public string? Remarks { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Issue(int id, [FromBody] IssueBody b)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, IpdAdmissionController.PatientPage, "PH_ISSUE")) return Fail(PermissionFilter.DeniedMessage);
        if (b.Lines.Count == 0) return Fail("Add at least one item.");
        return await Write(() => api.PostAsync($"/admissions/{id}/ph-issues", new { Lines = JsonSerializer.Serialize(b.Lines), b.Head, b.StoreId, b.DoctorId, b.Remarks }),
            "IPD.PharmacyIssue", $"Admission {id}: {b.Lines.Count} item(s) issued", id);
    }

    public sealed class ReturnLine { public int LineId { get; set; } public decimal Qty { get; set; } }
    public sealed class ReturnBody { public List<ReturnLine> Lines { get; set; } = []; public string? Reason { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Return(int id, [FromBody] ReturnBody b)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, IpdAdmissionController.PatientPage, "PH_RETURN")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/admissions/{id}/ph-returns", new { Lines = JsonSerializer.Serialize(b.Lines), b.Reason }),
            "IPD.PharmacyReturn", $"Admission {id}: return of {b.Lines.Count} item(s): {b.Reason}", id);
    }

    // ── medicine indent (SQLScripts/2475): the ward raises an indent (no stock), receives what the pharmacy issued ──
    [HttpGet]
    public Task<IActionResult> IndentItems(int id, string? q, int? storeId) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/ph-indent-items" + IpdApiClient.Q(("q", q), ("storeId", storeId)));
        return new { items = s.ElementAtOrDefault(0), stores = s.ElementAtOrDefault(1) };
    });

    [HttpGet]
    public Task<IActionResult> Indents(int id) => Read(async () => await api.GetAsync($"/admissions/{id}/ph-indents"));

    public sealed class IndentLine { public int ItemId { get; set; } public decimal Qty { get; set; } public string? Mode { get; set; } public string? Remarks { get; set; } public int? ReIndentOfLineId { get; set; } public int? ReIndentOfIssueLineId { get; set; } }
    public sealed class IndentBody { public List<IndentLine> Lines { get; set; } = []; public int? StoreId { get; set; } public int? DoctorId { get; set; } public string? Priority { get; set; } public string? Remarks { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> IndentSave(int id, [FromBody] IndentBody b)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, IpdAdmissionController.PatientPage, "PH_INDENT")) return Fail(PermissionFilter.DeniedMessage);
        if (b.Lines.Count == 0) return Fail("Add at least one medicine.");
        var re = b.Lines.Any(l => l.ReIndentOfLineId != null || l.ReIndentOfIssueLineId != null);
        return await WriteNo(() => api.PostAsync($"/admissions/{id}/ph-indents", new { Lines = JsonSerializer.Serialize(b.Lines), b.StoreId, b.DoctorId, b.Priority, b.Remarks }),
            re ? "IPD.MedicineReIndent" : "IPD.MedicineIndent", $"Admission {id}: {(re ? "re-indent" : "indent")} of {b.Lines.Count} medicine(s)", id, "IndentNo");
    }

    public sealed class IndentCancelBody { public int IndentId { get; set; } public int? LineId { get; set; } public string? Reason { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> IndentCancel(int id, [FromBody] IndentCancelBody b)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, IpdAdmissionController.PatientPage, "PH_INDENT")) return Fail(PermissionFilter.DeniedMessage);
        return await WriteNo(() => api.PostAsync($"/admissions/{id}/ph-indents/cancel", b), "IPD.MedicineIndentCancel", $"Admission {id}: indent cancelled - {b.Reason}", id, "IndentNo");
    }

    public sealed class ReceiveLine { public int LineId { get; set; } public bool Received { get; set; } = true; public string? Remarks { get; set; } }
    public sealed class ReceiveBody { public List<ReceiveLine> Lines { get; set; } = []; }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Receive(int id, [FromBody] ReceiveBody b)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, IpdAdmissionController.PatientPage, "PH_RECEIVE")) return Fail(PermissionFilter.DeniedMessage);
        if (b.Lines.Count == 0) return Fail("Choose the items received.");
        var not = b.Lines.Count(l => !l.Received);
        return await Write(() => api.PostAsync($"/admissions/{id}/ph-receive", new { Lines = JsonSerializer.Serialize(b.Lines) }),
            "IPD.MedicineReceive", $"Admission {id}: {b.Lines.Count - not} received, {not} not received", id);
    }

    private async Task<IActionResult> WriteNo(Func<Task<JsonElement>> call, string action, string description, int refId, string noField)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            await auditLogService.LogActivityAsync(eventType: "IPD Pharmacy", actionName: action, description: description + (row.S(noField) is { Length: > 0 } n ? $" ({n})" : ""),
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }
}
