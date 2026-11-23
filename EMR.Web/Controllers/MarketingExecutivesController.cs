using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Master > General > Marketing Executive Master (SQLScripts/2440): add, edit, view, activate / deactivate, delete.
/// Page MASTER.MARKETINGEXECUTIVES: VIEW, ADD, EDIT, STATUS, DELETE. Web -> EMR.Api api/marketing-executives -> procedures.
/// </summary>
[Authorize]
public class MarketingExecutivesController(MarketingExecutiveApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, ILogger<MarketingExecutivesController> logger) : Controller
{
    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Marketing executive API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, string description)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            // SQLScripts/2470: the executive's login is created / renamed by the procedure - keep the central user register in step
            if (row.ValueKind == JsonValueKind.Object && row.TryGetProperty("LoginUserId", out var login) && login.ValueKind == JsonValueKind.Number && login.GetInt32() > 0)
                await HttpContext.RequestServices.GetRequiredService<EMR.Web.Services.Licensing.ICentralUserRegistry>().SyncUserAsync(login.GetInt32());
            await auditLogService.LogActivityAsync(eventType: "Master", actionName: action, description: description, userId: User.GetUserId(),
                branchId: User.GetCurrentBranchId(), moduleCode: "MASTER", referenceId: row.I("ExecutiveId"));
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Marketing executive API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        foreach (var c in new[] { "ADD", "EDIT", "STATUS", "DELETE" }) ViewData["Can" + c] = await permissionGuard.AllowsAsync(HttpContext, Page, c);
        return View();
    }

    [HttpGet]
    public Task<IActionResult> ListData(string? type, string? search, string? status) =>
        Read(async () => await api.GetAsync(IpdApiClient.Q(("type", type), ("search", search), ("status", status))));

    [HttpGet]
    public Task<IActionResult> Get(int id) => Read(async () => await api.GetAsync($"/{id}"));

    public sealed class SaveBody
    {
        public int? ExecutiveId { get; set; }
        public string? ExecutiveType { get; set; }
        public string? ExecutiveName { get; set; }
        public string? ExecutiveCode { get; set; }
        public string? PhoneNumber { get; set; }
        public string? EmailId { get; set; }
        public string? Address { get; set; }
        public decimal MonthlyTarget { get; set; }
        public bool IsActive { get; set; } = true;
    }

    [HttpGet]
    public Task<IActionResult> CheckEmail(string? email, int? executiveId) =>
        Read(async () =>
        {
            var local = await api.GetAsync("/check-email" + IpdApiClient.Q(("email", email), ("executiveId", executiveId?.ToString())));
            // SQLScripts/2490: free here, and also across all installations (central user register) - same check as User Master
            if (local.ValueKind == JsonValueKind.Object && local.TryGetProperty("Available", out var av) && av.ValueKind == JsonValueKind.True
                && await CentralTakenAsync(email, executiveId) is string taken)
                return (object)new { Available = false, Message = taken };
            return local;
        });

    /// <summary>SQLScripts/2490: the message when another sign-in (here or in another installation) holds the e-mail centrally;
    /// null when it is free, unchanged for this executive's own login, or the central register cannot be reached (never blocks then).</summary>
    private async Task<string?> CentralTakenAsync(string? email, int? executiveId)
    {
        var e = (email ?? "").Trim().ToLowerInvariant();
        if (e.Length == 0) return null;
        int? loginId = null;
        if (executiveId is > 0)
        {
            try
            {
                var cur = await api.GetAsync($"/{executiveId}");
                if (cur.ValueKind == JsonValueKind.Object)
                {
                    if (string.Equals(cur.S("LoginUsername")?.Trim(), e, StringComparison.OrdinalIgnoreCase)) return null;   // its own login
                    loginId = cur.I("LoginUserId") is int li && li > 0 ? li : null;
                }
            }
            catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException) { }
        }
        var r = await HttpContext.RequestServices.GetRequiredService<EMR.Web.Services.Licensing.ICentralUserRegistry>()
            .CheckAsync((int?)User.GetCompanyId() ?? 0, e, loginId);
        return r.Taken ? r.Message : null;
    }

    public const string Page = "MASTER.MARKETINGEXECUTIVES";

    /// <summary>Add (no id: control ADD) or edit (control EDIT): Save is mapped to both, so the right one is checked here.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromBody] SaveBody b)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, b.ExecutiveId is > 0 ? "EDIT" : "ADD")) return Fail(PermissionFilter.DeniedMessage);
        // status changes only from the edit form and only with the Status right; a new executive is always created active
        if (b.ExecutiveId is not > 0) b.IsActive = true;
        else if (!await permissionGuard.AllowsAsync(HttpContext, Page, "STATUS"))
        {
            try
            {
                var cur = await api.GetAsync($"/{b.ExecutiveId}");
                if (cur.ValueKind == JsonValueKind.Object && cur.B("IsActive") != b.IsActive) return Fail("You are not allowed to change the status (Status permission).");
            }
            catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException) { return Fail(ex.Message); }
        }
        // SQLScripts/2490: the login e-mail must be free across all installations (server side, as User Master)
        if (await CentralTakenAsync(b.EmailId, b.ExecutiveId) is string centralTaken) return Fail(centralTaken);
        // the login (SQLScripts/2444): an executive with an e-mail ID gets one, made on add or on the first edit without one
        // 2457: no password is taken here; the executive verifies by code in the mobile app and sets the password there
        var body = new
        {
            b.ExecutiveId, b.ExecutiveType, b.ExecutiveName, b.ExecutiveCode, b.PhoneNumber, b.EmailId, b.Address, b.MonthlyTarget, b.IsActive,
            BranchId = User.GetCurrentBranchId()
        };
        return await Write(() => api.PostAsync("", body), b.ExecutiveId is > 0 ? "MarketingExecutive.Edit" : "MarketingExecutive.Add",
            $"Marketing executive {(b.ExecutiveId is > 0 ? "edited" : "added")}: {b.ExecutiveName} ({b.ExecutiveCode}, {b.ExecutiveType})");
    }

    public sealed class StatusBody { public bool IsActive { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SetStatus(int id, [FromBody] StatusBody b) =>
        Write(() => api.PostAsync($"/{id}/status", b), "MarketingExecutive.Status", $"Marketing executive {id} {(b.IsActive ? "activated" : "deactivated")}");

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Delete(int id) =>
        Write(() => api.PostAsync($"/{id}/delete", new { }), "MarketingExecutive.Delete", $"Marketing executive {id} deleted");
}
