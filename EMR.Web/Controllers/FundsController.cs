using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Accounts > Fund Master (SQLScripts/2522): the funds the hospital pays from (the payout mechanism uses them
/// later) - Wallet or Bank (a Bank Master account), opening balance, top-ups and the history with the running balance.
/// Page UTILITY.ACCOUNTS.FUNDS: VIEW, ADD, EDIT, TOPUP, STATUS. Web -> EMR.Api api/funds -> procedures (rules there).
/// </summary>
[Authorize]
public class FundsController(BankFundApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, ILogger<FundsController> logger) : Controller
{
    public const string Page = "UTILITY.ACCOUNTS.FUNDS";
    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Fund API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, Func<JsonElement, string> description)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            await auditLogService.LogActivityAsync(eventType: "Accounts", actionName: action, description: description(row), userId: User.GetUserId(),
                branchId: User.GetCurrentBranchId(), moduleCode: "ACCOUNTS", referenceId: row.I("FundId"));
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Fund API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        foreach (var c in new[] { "DETAILS", "HISTORY", "ADD", "EDIT", "TOPUP", "STATUS" }) ViewData["Can" + c] = await permissionGuard.AllowsAsync(HttpContext, Page, c);
        return View();
    }

    [HttpGet]
    public Task<IActionResult> ListData(string? search, string? type, string? status) =>
        Read(async () => await api.GetAsync("api/funds" + IpdApiClient.Q(("search", search), ("type", type), ("status", status))));

    [HttpGet]
    public async Task<IActionResult> Get(int id) =>
        !await permissionGuard.AllowsAsync(HttpContext, Page, "DETAILS") ? Fail(PermissionFilter.DeniedMessage)
            : await Read(async () => await api.GetAsync($"api/funds/{id}"));

    [HttpGet]
    public async Task<IActionResult> History(int id, string? fromDate, string? toDate) =>
        !await permissionGuard.AllowsAsync(HttpContext, Page, "HISTORY") ? Fail(PermissionFilter.DeniedMessage) : await Read(async () => await api.GetAsync($"api/funds/{id}/history" + IpdApiClient.Q(("fromDate", fromDate), ("toDate", toDate))));

    /// <summary>Bank Master accounts a Bank fund can use (active; the fund's own one too).</summary>
    [HttpGet]
    public Task<IActionResult> BankOptions(int? fundId) =>
        Read(async () => await api.GetAsync("api/banks/options" + IpdApiClient.Q(("fundId", fundId?.ToString()))));

    public sealed class SaveBody
    {
        public int? FundId { get; set; }
        public string? FundCode { get; set; }
        public string? FundName { get; set; }
        public string? FundType { get; set; }
        public int? BankId { get; set; }
        public decimal OpeningBalance { get; set; }
        public DateTime? OpeningDate { get; set; }
        public string? Remarks { get; set; }
        public bool IsActive { get; set; } = true;
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromBody] SaveBody b)
    {
        if (b is null) return Fail("Nothing to save.");
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, b.FundId is > 0 ? "EDIT" : "ADD")) return Fail(PermissionFilter.DeniedMessage);
        if (b.FundId is not > 0) b.IsActive = true;
        else if (!await permissionGuard.AllowsAsync(HttpContext, Page, "STATUS"))
        {
            try
            {
                var cur = await api.GetAsync($"api/funds/{b.FundId}");
                if (cur.ValueKind == JsonValueKind.Object && cur.B("IsActive") != b.IsActive) return Fail("You are not allowed to change the status (Status permission).");
            }
            catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException) { return Fail(ex.Message); }
        }
        var body = new { b.FundId, BranchId = User.GetCurrentBranchId(), b.FundCode, b.FundName, b.FundType, b.BankId, b.OpeningBalance, b.OpeningDate, b.Remarks, b.IsActive };
        return await Write(() => api.PostAsync("api/funds", body), b.FundId is > 0 ? "Fund.Edit" : "Fund.Add",
            _ => $"Fund {(b.FundId is > 0 ? "edited" : "added")}: {b.FundName} ({b.FundCode}, {b.FundType}), opening ₹{b.OpeningBalance:N2}");
    }

    public sealed class TopUpBody
    {
        public int FundId { get; set; }
        public decimal Amount { get; set; }
        public DateTime? TxnDate { get; set; }
        public string? PaymentMode { get; set; }
        public string? ReferenceNo { get; set; }
        public string? Remarks { get; set; }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> TopUp([FromBody] TopUpBody b) =>
        !await permissionGuard.AllowsAsync(HttpContext, Page, "TOPUP") ? Fail(PermissionFilter.DeniedMessage) : await Write(() => api.PostAsync($"api/funds/{b.FundId}/topup", new { b.FundId, BranchId = User.GetCurrentBranchId(), b.Amount, b.TxnDate, b.PaymentMode, b.ReferenceNo, b.Remarks }),
            "Fund.TopUp", row => $"Fund #{b.FundId} topped up ₹{b.Amount:N2} by {b.PaymentMode}{(string.IsNullOrWhiteSpace(b.ReferenceNo) ? "" : " (" + b.ReferenceNo + ")")}; balance {row.M("Balance").Rs()}");

    public sealed class StatusBody { public int Id { get; set; } public bool IsActive { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SetStatus([FromBody] StatusBody b) =>
        !await permissionGuard.AllowsAsync(HttpContext, Page, "STATUS") ? Fail(PermissionFilter.DeniedMessage) : await Write(() => api.PostAsync($"api/funds/{b.Id}/status", new { b.IsActive }), "Fund.Status", _ => $"Fund #{b.Id} {(b.IsActive ? "activated" : "deactivated")}");
}
