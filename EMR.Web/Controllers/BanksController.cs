using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Master > General > Bank Master (SQLScripts/2522): the company's own bank accounts - add, edit, view, activate / deactivate.
/// Page MASTER.BANKS: VIEW, ADD, EDIT, STATUS. Web -> EMR.Api api/banks -> procedures (rules there).
/// </summary>
[Authorize]
public class BanksController(BankFundApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, ILogger<BanksController> logger) : Controller
{
    public const string Page = "MASTER.BANKS";
    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Bank API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, string description)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            await auditLogService.LogActivityAsync(eventType: "Master", actionName: action, description: description, userId: User.GetUserId(),
                branchId: User.GetCurrentBranchId(), moduleCode: "MASTER", referenceId: row.I("BankId"));
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Bank API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        foreach (var c in new[] { "DETAILS", "ADD", "EDIT", "STATUS" }) ViewData["Can" + c] = await permissionGuard.AllowsAsync(HttpContext, Page, c);
        return View();
    }

    [HttpGet]
    public Task<IActionResult> ListData(string? search, string? status) =>
        Read(async () => await api.GetAsync("api/banks" + IpdApiClient.Q(("search", search), ("status", status))));

    /// <summary>SQLScripts/2523: standard banks (name, IFSC bank code, category) for the bank name list and the IFSC check.</summary>
    [HttpGet]
    public Task<IActionResult> Directory() => Read(async () => await api.GetAsync("api/banks/directory"));

    [HttpGet]
    public async Task<IActionResult> Get(int id) =>
        !await permissionGuard.AllowsAsync(HttpContext, Page, "DETAILS") ? Fail(PermissionFilter.DeniedMessage)
            : await Read(async () => await api.GetAsync($"api/banks/{id}"));

    public sealed class SaveBody
    {
        public int? BankId { get; set; }
        public string? BankName { get; set; }
        public string? AccountHolderName { get; set; }
        public string? AccountNumber { get; set; }
        public string? AccountType { get; set; }
        public string? IFSCCode { get; set; }
        public string? MICRCode { get; set; }
        public string? SwiftCode { get; set; }
        public string? BranchName { get; set; }
        public string? BranchAddress { get; set; }
        public string? City { get; set; }
        public string? UpiId { get; set; }
        public string? UpiHolderName { get; set; }
        public string? ContactPerson { get; set; }
        public string? ContactPhone { get; set; }
        public string? ContactEmail { get; set; }
        public string? Remarks { get; set; }
        public bool IsPrimary { get; set; }
        public bool IsActive { get; set; } = true;
    }

    /// <summary>Add (control ADD) or edit (control EDIT); a status change in the form needs STATUS too.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromBody] SaveBody b)
    {
        if (b is null) return Fail("Nothing to save.");
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, b.BankId is > 0 ? "EDIT" : "ADD")) return Fail(PermissionFilter.DeniedMessage);
        if (b.BankId is not > 0) b.IsActive = true;
        else if (!await permissionGuard.AllowsAsync(HttpContext, Page, "STATUS"))
        {
            try
            {
                var cur = await api.GetAsync($"api/banks/{b.BankId}");
                if (cur.ValueKind == JsonValueKind.Object && cur.B("IsActive") != b.IsActive) return Fail("You are not allowed to change the status (Status permission).");
            }
            catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException) { return Fail(ex.Message); }
        }
        return await Write(() => api.PostAsync("api/banks", b), b.BankId is > 0 ? "Bank.Edit" : "Bank.Add",
            $"Bank account {(b.BankId is > 0 ? "edited" : "added")}: {b.BankName} a/c ending {Last4(b.AccountNumber)} ({b.IFSCCode}){(b.IsPrimary ? ", primary" : "")}");
    }

    public sealed class StatusBody { public int Id { get; set; } public bool IsActive { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SetStatus([FromBody] StatusBody b) =>
        !await permissionGuard.AllowsAsync(HttpContext, Page, "STATUS") ? Fail(PermissionFilter.DeniedMessage) : await Write(() => api.PostAsync($"api/banks/{b.Id}/status", new { b.IsActive }), "Bank.Status", $"Bank account #{b.Id} {(b.IsActive ? "activated" : "deactivated")}");

    private static string Last4(string? s) => string.IsNullOrEmpty(s) ? "" : s.Length <= 4 ? s : s[^4..];
}
