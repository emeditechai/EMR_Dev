using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Settings > Audit Notification Setup (SQLScripts/2397): for each event (LAB / OPD bill cancelled, refund, LAB report
/// un-authorised) the users who get a WhatsApp alert (their User Master mobile), and whether the alert is on.
/// Kept per company in dbo.AuditNotifyEventSetting / dbo.AuditNotifyRecipient.
/// </summary>
[Authorize]
public class AuditNotificationSetupController(IDbConnectionFactory db, IAuditNotificationService notify, IAuditLogService audit) : Controller
{
    // per branch: the signed-in user's current branch
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

    [HttpGet]
    public IActionResult Index() => View();

    [HttpGet]
    public async Task<IActionResult> Data()
    {
        using var con = db.CreateConnection();
        using var grid = await con.QueryMultipleAsync("dbo.usp_AuditNotify_GetSetup", new { CompanyId = User.GetCompanyId(), BranchId }, commandType: CommandType.StoredProcedure);
        var events = Camel(await grid.ReadAsync());
        var recipients = Camel(await grid.ReadAsync());
        var users = Camel(await grid.ReadAsync());
        var log = Camel(await con.QueryAsync("dbo.usp_AuditNotify_RecentLog", new { CompanyId = User.GetCompanyId(), BranchId, Top = 50 }, commandType: CommandType.StoredProcedure));
        var branchName = User.FindFirst("BranchName")?.Value ?? User.FindFirst("BranchCode")?.Value;
        return Json(new { success = true, branchName, events, recipients, users, log });
    }

    // the procedure's rows with camelCase keys, as the page reads them
    private static List<Dictionary<string, object?>> Camel(IEnumerable<dynamic> rows) =>
        rows.Select(r => ((IDictionary<string, object?>)r).ToDictionary(k => char.ToLowerInvariant(k.Key[0]) + k.Key[1..], k => k.Value)).ToList();

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string eventCode, bool isEnabled, string? userIds)
    {
        if (string.IsNullOrWhiteSpace(eventCode) || eventCode.Length > 40) return Json(new { success = false, message = "Unknown event." });
        if (userIds is { Length: > 4000 } || (userIds ?? "").Any(c => !char.IsDigit(c) && c != ','))
            return Json(new { success = false, message = "Invalid user list." });
        try
        {
            using var con = db.CreateConnection();
            await con.ExecuteAsync("dbo.usp_AuditNotify_SaveEvent",
                new { CompanyId = User.GetCompanyId(), BranchId, EventCode = eventCode, IsEnabled = isEnabled, UserIds = userIds, UserId = User.GetUserId() },
                commandType: CommandType.StoredProcedure);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50000)
        {
            return Json(new { success = false, message = ex.Message });
        }
        await audit.LogAsync("Update", "AuditNotificationSetup",
            $"Audit alert {eventCode} (branch {BranchId}) {(isEnabled ? "on" : "off")}, users: {(string.IsNullOrEmpty(userIds) ? "none" : userIds)}", User.GetUserId(), User.GetCurrentBranchId());
        return Json(new { success = true, message = isEnabled ? "Saved - the alert is on." : "Saved - the alert is off." });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SendTest(string eventCode)
    {
        if (string.IsNullOrWhiteSpace(eventCode) || eventCode.Length > 40) return Json(new { success = false, message = "Unknown event." });
        var (sent, _, message) = await notify.SendTestAsync(User.GetCompanyId(), BranchId, eventCode,
            User.FindFirst("DisplayName")?.Value ?? User.Identity?.Name, User.GetUserId());
        return Json(new { success = sent > 0, message });
    }
}
