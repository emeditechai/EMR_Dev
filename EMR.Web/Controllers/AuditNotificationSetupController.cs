using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Settings > Audit Notification Setup (SQLScripts/2397, 2528): notification AREAS (dbo.AuditNotifyArea), each with its events -
/// Audit alerts (LAB / OPD bill cancelled, refund, LAB report un-authorised) and OPD Doctor Roster Notification (daily roster,
/// room changes). Per branch and event: on / off, the users who get it, and its options (WhatsApp / e-mail, also the doctor,
/// the daily send time). Kept in dbo.AuditNotifyEventSetting / dbo.AuditNotifyRecipient.
/// </summary>
[Authorize]
public class AuditNotificationSetupController(IDbConnectionFactory db, IAuditNotificationService notify, IDoctorRosterNotificationService roster,
    IAuditLogService audit) : Controller
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
        var areas = Camel(await grid.ReadAsync());
        var log = Camel(await con.QueryAsync("dbo.usp_AuditNotify_RecentLog", new { CompanyId = User.GetCompanyId(), BranchId, Top = 50 }, commandType: CommandType.StoredProcedure));
        var branchName = User.FindFirst("BranchName")?.Value ?? User.FindFirst("BranchCode")?.Value;
        return Json(new { success = true, branchName, areas, events, recipients, users, log });
    }

    // the procedure's rows with camelCase keys, as the page reads them
    private static List<Dictionary<string, object?>> Camel(IEnumerable<dynamic> rows) =>
        rows.Select(r => ((IDictionary<string, object?>)r).ToDictionary(k => char.ToLowerInvariant(k.Key[0]) + k.Key[1..], k => k.Value)).ToList();

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string eventCode, bool isEnabled, string? userIds,
        bool? sendWhatsApp = null, bool? sendEmail = null, bool? notifyDoctor = null, string? sendTime = null, decimal? thresholdPct = null)
    {
        if (string.IsNullOrWhiteSpace(eventCode) || eventCode.Length > 40) return Json(new { success = false, message = "Unknown event." });
        if (!string.IsNullOrWhiteSpace(sendTime) && !TimeSpan.TryParseExact(sendTime, @"hh\:mm", null, out _))
            return Json(new { success = false, message = "Enter the send time as HH:mm (for example 07:30)." });
        if (userIds is { Length: > 4000 } || (userIds ?? "").Any(c => !char.IsDigit(c) && c != ','))
            return Json(new { success = false, message = "Invalid user list." });
        try
        {
            using var con = db.CreateConnection();
            await con.ExecuteAsync("dbo.usp_AuditNotify_SaveEvent",
                new { CompanyId = User.GetCompanyId(), BranchId, EventCode = eventCode, IsEnabled = isEnabled, UserIds = userIds, UserId = User.GetUserId(),
                      SendWhatsApp = sendWhatsApp, SendEmail = sendEmail, NotifyDoctor = notifyDoctor, SendTime = sendTime, ThresholdPct = thresholdPct },
                commandType: CommandType.StoredProcedure);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50000)
        {
            return Json(new { success = false, message = ex.Message });
        }
        await audit.LogAsync("Update", "AuditNotificationSetup",
            $"Notification {eventCode} (branch {BranchId}) {(isEnabled ? "on" : "off")}, users: {(string.IsNullOrEmpty(userIds) ? "none" : userIds)}" +
            (sendWhatsApp is null ? "" : $", WhatsApp {(sendWhatsApp == true ? "on" : "off")}") + (sendEmail is null ? "" : $", e-mail {(sendEmail == true ? "on" : "off")}") +
            (notifyDoctor is null ? "" : $", doctor {(notifyDoctor == true ? "yes" : "no")}") + (string.IsNullOrWhiteSpace(sendTime) ? "" : $", at {sendTime}") +
            (thresholdPct is null ? "" : $", above {thresholdPct:0.##}%"), User.GetUserId(), User.GetCurrentBranchId());
        return Json(new { success = true, message = isEnabled ? "Saved - the alert is on." : "Saved - the alert is off." });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SendTest(string eventCode)
    {
        if (string.IsNullOrWhiteSpace(eventCode) || eventCode.Length > 40) return Json(new { success = false, message = "Unknown event." });
        var actor = User.FindFirst("DisplayName")?.Value ?? User.Identity?.Name;
        var (sent, _, message) = RosterNotifyEvents.Is(eventCode)
            ? await roster.SendTestAsync(BranchId, eventCode, actor, User.GetUserId())
            : await notify.SendTestAsync(User.GetCompanyId(), BranchId, eventCode, actor, User.GetUserId());
        return Json(new { success = sent > 0, message });
    }

    /// <summary>
    /// "Send today's roster now" (SQLScripts/2528): today's roster of this branch to its doctors and chosen users, now. Once
    /// a day - the scheduler then skips today; a second send needs force (the page asks first).
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SendNow(string eventCode, bool force = false)
    {
        if (eventCode != RosterNotifyEvents.DailyRoster) return Json(new { success = false, message = "Only the daily roster can be sent now." });
        using (var con = db.CreateConnection())
        {
            var claimed = await con.ExecuteScalarAsync<bool>("dbo.usp_AuditNotify_ClaimDaily",
                new { BranchId, EventCode = eventCode, UserId = User.GetUserId() }, commandType: CommandType.StoredProcedure);
            if (!claimed && !force)
                return Json(new { success = false, needsForce = true, message = "Today's roster has already been sent for this branch. Send it again?" });
        }
        var (sent, _, message) = await roster.SendDailyRosterAsync(BranchId, DateTime.Today, User.GetUserId());
        await audit.LogAsync("Send", "AuditNotificationSetup", $"Daily doctor roster sent now (branch {BranchId}){(force ? " - again" : "")}: {message}",
            User.GetUserId(), User.GetCurrentBranchId());
        return Json(new { success = sent > 0, message });
    }
}
