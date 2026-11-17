using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Pharmacy > Sales > IPD Issue (PHARMACY.IPDISSUE, SQLScripts/2475): dashboard of the medicine indents raised by the wards.
/// Per indent line the pharmacist issues batches (stock out, IP bill - the 2437 issue) and / or marks the rest not issued with
/// a reason; a line the ward did not receive can be taken back to stock. Controls: ISSUE, TAKE_BACK.
/// Web -> EMR.Api api/ipd -> stored procedures.
/// </summary>
[Authorize]
public class PhIpdIssueController(IpdApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, ILogger<PhIpdIssueController> logger) : Controller
{
    public const string Page = "PHARMACY.IPDISSUE";
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
            await auditLogService.LogActivityAsync(eventType: "Pharmacy IPD Issue", actionName: action, description: description + (row.S("IssueNo") is { Length: > 0 } n ? $" ({n})" : ""),
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "PHARMACY", referenceId: refId);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewData["CanIssue"] = await permissionGuard.AllowsAsync(HttpContext, Page, "ISSUE");
        ViewData["CanTakeBack"] = await permissionGuard.AllowsAsync(HttpContext, Page, "TAKE_BACK");
        return View("~/Views/PharmacyIpdIssue/Index.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> Board(string? status, int? storeId, string? q, DateTime? from, DateTime? to) => Read(async () =>
    {
        var s = await api.SetsAsync("/ph-indent-board" + IpdApiClient.Q(("status", status), ("storeId", storeId), ("q", q),
            ("from", from?.ToString("yyyy-MM-dd")), ("to", to?.ToString("yyyy-MM-dd"))));
        return new { tiles = s.ElementAtOrDefault(0), rows = s.ElementAtOrDefault(1) };
    });

    [HttpGet]
    public Task<IActionResult> Detail(int id) => Read(async () =>
    {
        var s = await api.SetsAsync($"/ph-indents/{id}");
        return new { header = s.ElementAtOrDefault(0), lines = s.ElementAtOrDefault(1), issues = s.ElementAtOrDefault(2) };
    });

    [HttpGet]
    public Task<IActionResult> Batches(int itemId, int? storeId) => Read(async () => await api.GetAsync($"/ph-batches/{itemId}" + IpdApiClient.Q(("storeId", storeId))));

    public sealed class IssueLine { public int IndentLineId { get; set; } public int BatchId { get; set; } public decimal Qty { get; set; } }
    public sealed class NotIssueLine { public int IndentLineId { get; set; } public string? Reason { get; set; } public string? Remarks { get; set; } }
    public sealed class ProcessBody { public List<IssueLine> Issue { get; set; } = []; public List<NotIssueLine> NotIssue { get; set; } = []; public int? StoreId { get; set; } public string? Remarks { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Process(int id, [FromBody] ProcessBody b)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, "ISSUE")) return Fail(PermissionFilter.DeniedMessage);
        if (b.Issue.Count == 0 && b.NotIssue.Count == 0) return Fail("Enter a quantity to issue, or mark a line not issued.");
        return await Write(() => api.PostAsync($"/ph-indents/{id}/process", new
        {
            Issue = b.Issue.Count > 0 ? JsonSerializer.Serialize(b.Issue) : null,
            NotIssue = b.NotIssue.Count > 0 ? JsonSerializer.Serialize(b.NotIssue) : null,
            b.StoreId, b.Remarks
        }), "PharmacyIpdIssue", $"Indent {id}: {b.Issue.Count} batch line(s) issued, {b.NotIssue.Count} line(s) not issued", id);
    }

    public sealed class TakeBackBody { public string? Remarks { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> TakeBack(int lineId, [FromBody] TakeBackBody b)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, "TAKE_BACK")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/ph-issue-lines/{lineId}/take-back", b), "PharmacyIpdTakeBack", $"Issue line {lineId} taken back (not received by the ward)", lineId);
    }
}
