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
public class MarketingExecutivesController(MarketingExecutiveApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, IPasswordHasherService passwordHasher, ILogger<MarketingExecutivesController> logger) : Controller
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
        // 2444: password of the login made for an executive with an e-mail ID (new login only; never sent to the API in clear)
        public string? LoginPassword { get; set; }
        public string? LoginConfirmPassword { get; set; }
    }

    [HttpGet]
    public Task<IActionResult> CheckEmail(string? email, int? executiveId) =>
        Read(async () => await api.GetAsync("/check-email" + IpdApiClient.Q(("email", email), ("executiveId", executiveId?.ToString()))));

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
        // the login (SQLScripts/2444): an executive with an e-mail ID gets one, made on add or on the first edit without one
        string? hash = null, salt = null;
        if (!string.IsNullOrWhiteSpace(b.LoginPassword))
        {
            if (b.LoginPassword.Length < 6) return Fail("The login password must have at least 6 characters.");
            if (b.LoginPassword != b.LoginConfirmPassword) return Fail("The passwords do not match.");
            (hash, salt) = passwordHasher.HashPassword(b.LoginPassword);
        }
        var body = new
        {
            b.ExecutiveId, b.ExecutiveType, b.ExecutiveName, b.ExecutiveCode, b.PhoneNumber, b.EmailId, b.Address, b.MonthlyTarget, b.IsActive,
            BranchId = User.GetCurrentBranchId(), LoginPasswordHash = hash, LoginSalt = salt
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
