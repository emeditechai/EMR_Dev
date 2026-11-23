using System.Data;
using System.Globalization;
using System.Net;
using System.Text;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

/// <summary>Settings > Audit Notification Setup > OPD Doctor Roster Notification (SQLScripts/2528): its events.</summary>
public static class RosterNotifyEvents
{
    public const string DailyRoster = "OPD_ROSTER_DAILY";
    public static bool Is(string? code) => code is DailyRoster;
}

/// <summary>A doctor and the room assigned (Room Doctor Assignment), read before and after a change.</summary>
public sealed class DoctorRoomInfo
{
    public int DoctorId { get; set; }
    public string? DoctorName { get; set; }
    public string? SpecialityName { get; set; }
    public string? Mobile { get; set; }
    public string? Email { get; set; }
    public int? RoomId { get; set; }
    public string? RoomName { get; set; }
    public string? FloorName { get; set; }
    public string? BranchName { get; set; }
    public int CompanyId { get; set; }
}

/// <summary>A session (Doctor Schedule) or a leave, read before it is removed.</summary>
public sealed class RosterItem
{
    public int DoctorId { get; set; }
    public int BranchId { get; set; }
    public byte? DayOfWeek { get; set; }
    public TimeSpan? StartTime { get; set; }
    public TimeSpan? EndTime { get; set; }
    public DateTime? ExceptionDate { get; set; }
    public string? Reason { get; set; }

    private static readonly string[] Days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    public static string DayName(byte dow) => dow < 7 ? Days[dow] : "Day " + dow;
    public static string Session(byte dow, TimeSpan from, TimeSpan to) =>
        $"{DayName(dow)} {DateTime.Today.Add(from).ToString("hh:mm tt", CultureInfo.InvariantCulture)} - {DateTime.Today.Add(to).ToString("hh:mm tt", CultureInfo.InvariantCulture)}";
    public static string Dates(DateTime from, DateTime to) =>
        from.Date == to.Date ? from.ToString("dd-MMM-yyyy", CultureInfo.InvariantCulture)
                             : $"{from.ToString("dd-MMM-yyyy", CultureInfo.InvariantCulture)} to {to.ToString("dd-MMM-yyyy", CultureInfo.InvariantCulture)}";
    /// <summary>What it was, for "removed / cancelled" lines.</summary>
    public string Describe() => ExceptionDate is { } d
        ? Dates(d, d) + (string.IsNullOrWhiteSpace(Reason) ? "" : $" ({Reason})")
        : DayOfWeek is { } w && StartTime is { } a && EndTime is { } b ? Session(w, a, b) : "a session";
}

/// <summary>
/// OPD Doctor Roster Notification (SQLScripts/2528), per branch:
///   Daily doctor roster - every doctor with a session today (Doctor Schedule, effective, not on leave) gets the day's
///     sessions, slots, capacity, booked so far and room, by WhatsApp and / or e-mail (Doctor Master mobile / e-mail); the
///     same message goes to the users chosen for the event. A doctor on leave: the users are told, the doctor is not.
///   A doctor's room assigned / changed / removed (Room Doctor Assignment) - the same roster message of that doctor is sent
///     again (with a line saying the room changed) to the doctor and the users of the daily roster.
///   A doctor's roster changed (Doctor Schedule: a session added / changed / deactivated, a leave added / removed) - what
///     changed, with the doctor's weekly sessions and coming leave, to the doctor and the users of the daily roster.
/// Channels, "send to the doctor" and the daily send time are the event's options on the page. Every message is logged in
/// dbo.AuditNotifyLog (Sent / Failed / Skipped, channel). Room changes are sent in the background after the change is saved.
/// </summary>
public interface IDoctorRosterNotificationService
{
    /// <summary>Today's roster of a branch to its doctors and users. usersOnly: the doctors are not messaged.</summary>
    Task<(int Sent, int Skipped, string Message)> SendDailyRosterAsync(int branchId, DateTime date, int? triggeredBy, bool usersOnly = false);

    Task<DoctorRoomInfo?> GetDoctorRoomAsync(int doctorId, int branchId);

    /// <summary>A doctor's room changed (before = the room before the change): the doctor's roster is sent again, in the background.</summary>
    void QueueRoomChange(int doctorId, int branchId, DoctorRoomInfo? before, string? actorName, int? actorUserId);

    /// <summary>A session or leave about to be removed (Doctor Schedule): whose it is and what it was.</summary>
    Task<RosterItem?> GetRosterItemAsync(int? scheduleId, int? exceptionId);

    /// <summary>
    /// A doctor's roster changed (Doctor Schedule): what changed, with the doctor's weekly sessions and coming leave, to the
    /// doctor and the users of the daily roster - in the background, when the daily roster is on for the branch.
    /// </summary>
    void QueueRosterChange(int doctorId, int branchId, string change, string? actorName, int? actorUserId);

    /// <summary>A sample of the event to its chosen users only (never the doctors) - the Send test button.</summary>
    Task<(int Sent, int Skipped, string Message)> SendTestAsync(int branchId, string eventCode, string? actorName, int? actorUserId);
}

public class DoctorRosterNotificationService(IServiceScopeFactory scopeFactory, IDbConnectionFactory db, IWhatsAppService whatsApp,
    IEmailService email, ILogger<DoctorRosterNotificationService> logger) : IDoctorRosterNotificationService
{
    private sealed class Setting
    {
        public int CompanyId { get; set; }
        public int BranchId { get; set; }
        public bool IsEnabled { get; set; }
        public bool SendWhatsApp { get; set; }
        public bool SendEmail { get; set; }
        public bool NotifyDoctor { get; set; }
        public string? BranchName { get; set; }
    }

    private sealed class Recipient
    {
        public int? UserId { get; set; }
        public string? Name { get; set; }
        public string? Mobile { get; set; }
        public string? Email { get; set; }
    }

    private sealed class Session
    {
        public int DoctorId { get; set; }
        public string? DoctorName { get; set; }
        public string? SpecialityName { get; set; }
        public string? Mobile { get; set; }
        public string? Email { get; set; }
        public int ScheduleId { get; set; }
        public TimeSpan StartTime { get; set; }
        public TimeSpan EndTime { get; set; }
        public int? SlotDurationMinutes { get; set; }
        public int? MaxPatientsPerSlot { get; set; }
        public int? MaxPatientsPerSession { get; set; }
        public string? RoomName { get; set; }
        public string? FloorName { get; set; }
        public int Booked { get; set; }
        public string? LeaveReason { get; set; }
        public bool OnLeave { get; set; }
        public string? BranchName { get; set; }
        public int CompanyId { get; set; }
    }

    /// <summary>One message in its two forms: WhatsApp text and an e-mail (subject + HTML).</summary>
    private sealed record Message(string Text, string Subject, string Html, string RefNo);

    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    private static string T(TimeSpan t) => DateTime.Today.Add(t).ToString("hh:mm tt", Inv);
    private static string Room(string? room, string? floor) =>
        string.IsNullOrWhiteSpace(room) ? "Not assigned" : "Room " + room + (string.IsNullOrWhiteSpace(floor) ? "" : $" ({floor})");

    // ── daily roster ─────────────────────────────────────────────────────────────────────────────────────────
    public async Task<(int Sent, int Skipped, string Message)> SendDailyRosterAsync(int branchId, DateTime date, int? triggeredBy, bool usersOnly = false)
    {
        using var con = db.CreateConnection();
        var setting = await SettingAsync(con, branchId, RosterNotifyEvents.DailyRoster);
        if (setting is not { IsEnabled: true }) return (0, 0, "The daily roster alert is off for this branch.");
        var users = await UsersAsync(con, branchId, RosterNotifyEvents.DailyRoster);
        var sessions = (await con.QueryAsync<Session>("dbo.usp_AuditNotify_DoctorRoster",
            new { BranchId = branchId, Date = date.Date, DoctorId = (int?)null }, commandType: CommandType.StoredProcedure)).ToList();
        if (sessions.Count == 0) return (0, 0, $"No doctor has a session on {date:dd-MMM-yyyy} in this branch.");

        int sent = 0, skipped = 0;
        foreach (var doc in sessions.GroupBy(s => s.DoctorId))
        {
            var first = doc.First();
            var msg = RosterMessage(doc.ToList(), date, setting.BranchName ?? first.BranchName);
            var to = new List<Recipient>();
            // the doctor (not when on leave - the users are told)
            if (setting.NotifyDoctor && !usersOnly && !first.OnLeave)
                to.Add(new Recipient { Name = first.DoctorName, Mobile = first.Mobile, Email = first.Email });
            to.AddRange(users);
            var (s, k) = await DeliverAsync(con, setting, RosterNotifyEvents.DailyRoster, to, msg, triggeredBy, "OPD", first.DoctorId);
            sent += s; skipped += k;
        }
        return (sent, skipped, $"Roster of {sessions.Select(s => s.DoctorId).Distinct().Count()} doctor(s): {sent} sent" +
                               (skipped > 0 ? $", {skipped} not sent (see the log below)." : "."));
    }

    /// <param name="update">a room change: the line telling it (the message is otherwise the daily roster)</param>
    /// <param name="noSession">the doctor has no session today (rows = the doctor and room only)</param>
    private static Message RosterMessage(List<Session> rows, DateTime date, string? branch, string? update = null, bool noSession = false)
    {
        var d = rows[0];
        var day = date.ToString("dddd, dd-MMM-yyyy", Inv);
        var rooms = rows.Select(r => Room(r.RoomName, r.FloorName)).Distinct().ToList();
        var sb = new StringBuilder();
        if (update is not null) sb.Append("🔄 *").Append(update).Append("*\n\n");
        if (noSession)
        {
            sb.Append("🗓️ *OPD roster - ").Append(d.DoctorName).Append("*\n\n")
              .Append("Date: ").Append(day).Append('\n')
              .Append("Room: *").Append(rooms[0]).Append("*\n");
            if (!string.IsNullOrWhiteSpace(d.SpecialityName)) sb.Append("Department: ").Append(d.SpecialityName).Append('\n');
            sb.Append("Branch: ").Append(branch ?? "-").Append("\n\nNo OPD session today.");
        }
        else if (d.OnLeave)
        {
            sb.Append("🗓️ *OPD roster - ").Append(d.DoctorName).Append("*\n\n")
              .Append("Date: ").Append(day).Append('\n')
              .Append("Status: *On leave today*").Append(string.IsNullOrWhiteSpace(d.LeaveReason) ? "" : $" ({d.LeaveReason})").Append('\n')
              .Append("Sessions cancelled: ").Append(string.Join(", ", rows.Select(r => $"{T(r.StartTime)} - {T(r.EndTime)}"))).Append('\n')
              .Append("Branch: ").Append(branch ?? "-");
        }
        else
        {
            sb.Append("🗓️ *Today's OPD roster - ").Append(d.DoctorName).Append("*\n\n")
              .Append("Date: ").Append(day).Append('\n')
              .Append("Room: *").Append(string.Join(" / ", rooms)).Append("*\n");
            if (!string.IsNullOrWhiteSpace(d.SpecialityName)) sb.Append("Department: ").Append(d.SpecialityName).Append('\n');
            sb.Append("Branch: ").Append(branch ?? "-").Append("\n\n*Sessions*\n");
            foreach (var r in rows) sb.Append("• ").Append(SessionLine(r, rows.Count > 1 && rooms.Count > 1)).Append('\n');
            sb.Append("\nBooked so far: ").Append(rows.Sum(r => r.Booked)).Append(" patient(s).");
        }

        var html = new StringBuilder();
        html.Append("<div style=\"font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937\">");
        if (update is not null) html.Append("<p style=\"margin:0 0 8px;color:#b45309\"><b>").Append(H(update)).Append("</b></p>");
        html.Append("<h3 style=\"margin:0 0 8px\">").Append(d.OnLeave || noSession ? "OPD roster" : "Today's OPD roster").Append(" - ").Append(H(d.DoctorName)).Append("</h3>")
            .Append("<table cellpadding=\"4\" style=\"border-collapse:collapse\">")
            .Append(Row("Date", day)).Append(d.OnLeave ? Row("Status", "On leave today" + (string.IsNullOrWhiteSpace(d.LeaveReason) ? "" : $" ({d.LeaveReason})"))
                                                         : Row("Room", string.Join(" / ", rooms)))
            .Append(string.IsNullOrWhiteSpace(d.SpecialityName) ? "" : Row("Department", d.SpecialityName!)).Append(Row("Branch", branch ?? "-")).Append("</table>");
        if (noSession)
        {
            html.Append("<p style=\"margin-top:10px\">No OPD session today.</p></div>");
            return new Message(sb.ToString(), (update is null ? "" : update + " - ") + "OPD roster - " + d.DoctorName + " - " + date.ToString("dd-MMM-yyyy", Inv),
                html.ToString(), $"{d.DoctorName} {date:dd-MMM}");
        }
        html.Append("<table cellpadding=\"6\" style=\"border-collapse:collapse;margin-top:10px;border:1px solid #e5e7eb\">")
            .Append("<tr style=\"background:#f3f4f6;text-align:left\"><th>Session</th><th>Slot</th><th>Per slot</th><th>Max</th><th>Room</th><th>Booked</th></tr>");
        foreach (var r in rows)
            html.Append("<tr style=\"border-top:1px solid #e5e7eb\"><td>").Append(T(r.StartTime)).Append(" - ").Append(T(r.EndTime))
                .Append("</td><td>").Append(r.SlotDurationMinutes is > 0 ? $"{r.SlotDurationMinutes} min" : "-")
                .Append("</td><td>").Append(r.MaxPatientsPerSlot?.ToString() ?? "-")
                .Append("</td><td>").Append(r.MaxPatientsPerSession?.ToString() ?? "-")
                .Append("</td><td>").Append(H(Room(r.RoomName, r.FloorName)))
                .Append("</td><td>").Append(r.Booked).Append("</td></tr>");
        html.Append("</table></div>");

        var subject = (update is null ? "" : update + " - ") + (d.OnLeave ? "OPD roster (on leave) - " : "Today's OPD roster - ") + d.DoctorName + " - " + date.ToString("dd-MMM-yyyy", Inv);
        return new Message(sb.ToString(), subject, html.ToString(), $"{d.DoctorName} {date:dd-MMM}");
    }

    private static string SessionLine(Session r, bool withRoom) =>
        $"{T(r.StartTime)} - {T(r.EndTime)}" +
        (r.SlotDurationMinutes is > 0 ? $" · {r.SlotDurationMinutes} min slots" : "") +
        (r.MaxPatientsPerSlot is > 0 ? $" · {r.MaxPatientsPerSlot}/slot" : "") +
        (r.MaxPatientsPerSession is > 0 ? $" · max {r.MaxPatientsPerSession}" : "") +
        $" · booked {r.Booked}" + (withRoom ? $" · {Room(r.RoomName, r.FloorName)}" : "");

    // ── room change ──────────────────────────────────────────────────────────────────────────────────────────
    public async Task<DoctorRoomInfo?> GetDoctorRoomAsync(int doctorId, int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<DoctorRoomInfo>("dbo.usp_AuditNotify_DoctorRoom",
            new { DoctorId = doctorId, BranchId = branchId }, commandType: CommandType.StoredProcedure);
    }

    public void QueueRoomChange(int doctorId, int branchId, DoctorRoomInfo? before, string? actorName, int? actorUserId)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                var svc = (DoctorRosterNotificationService)scope.ServiceProvider.GetRequiredService<IDoctorRosterNotificationService>();
                await svc.SendRoomChangeAsync(doctorId, branchId, before, actorName, actorUserId);
            }
            catch (Exception ex) { logger.LogWarning(ex, "[ROSTER-NOTIFY] Room change alert failed for doctor {DoctorId}", doctorId); }
        });
    }

    private async Task SendRoomChangeAsync(int doctorId, int branchId, DoctorRoomInfo? before, string? actorName, int? actorUserId)
    {
        using var con = db.CreateConnection();
        var setting = await SettingAsync(con, branchId, RosterNotifyEvents.DailyRoster);
        if (setting is not { IsEnabled: true }) return;
        var after = await con.QueryFirstOrDefaultAsync<DoctorRoomInfo>("dbo.usp_AuditNotify_DoctorRoom",
            new { DoctorId = doctorId, BranchId = branchId }, commandType: CommandType.StoredProcedure);
        if (after is null || before?.RoomId == after.RoomId) return;           // nothing changed
        var newRoom = after.RoomId is null ? null : Room(after.RoomName, after.FloorName);
        var oldRoom = before?.RoomId is null ? null : Room(before.RoomName, before.FloorName);
        var update = newRoom is null ? $"Room removed (was {oldRoom})" : oldRoom is null ? $"Room assigned: {newRoom}" : $"Room changed: {newRoom} (was {oldRoom})";

        // today's roster of the doctor - or, with no session today, the doctor and the room
        var rows = (await con.QueryAsync<Session>("dbo.usp_AuditNotify_DoctorRoster",
            new { BranchId = branchId, Date = DateTime.Today, DoctorId = doctorId }, commandType: CommandType.StoredProcedure)).ToList();
        var noSession = rows.Count == 0;
        if (noSession)
            rows.Add(new Session { DoctorId = doctorId, DoctorName = after.DoctorName, SpecialityName = after.SpecialityName, RoomName = after.RoomName,
                                   FloorName = after.FloorName, Mobile = after.Mobile, Email = after.Email });
        var msg = RosterMessage(rows, DateTime.Today, setting.BranchName ?? after.BranchName, update, noSession);
        var to = new List<Recipient>();
        if (setting.NotifyDoctor) to.Add(new Recipient { Name = after.DoctorName, Mobile = after.Mobile, Email = after.Email });
        to.AddRange(await UsersAsync(con, branchId, RosterNotifyEvents.DailyRoster));
        await DeliverAsync(con, setting, RosterNotifyEvents.DailyRoster, to, msg, actorUserId, "OPD", doctorId);
    }

    // ── roster change (Doctor Schedule) ──────────────────────────────────────────────────────────────────────
    private sealed class WeeklyRow
    {
        public byte DayOfWeek { get; set; }
        public TimeSpan StartTime { get; set; }
        public TimeSpan EndTime { get; set; }
        public int? SlotDurationMinutes { get; set; }
        public int? MaxPatientsPerSlot { get; set; }
        public int? MaxPatientsPerSession { get; set; }
        public DateTime EffectiveFrom { get; set; }
        public DateTime? EffectiveTo { get; set; }
        public string? RoomName { get; set; }
        public string? FloorName { get; set; }
    }

    private sealed class LeaveRow
    {
        public DateTime ExceptionDate { get; set; }
        public string? ExceptionType { get; set; }
        public string? Reason { get; set; }
    }

    public async Task<RosterItem?> GetRosterItemAsync(int? scheduleId, int? exceptionId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<RosterItem>("dbo.usp_AuditNotify_RosterItem",
            new { ScheduleId = scheduleId, ExceptionId = exceptionId }, commandType: CommandType.StoredProcedure);
    }

    public void QueueRosterChange(int doctorId, int branchId, string change, string? actorName, int? actorUserId)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                var svc = (DoctorRosterNotificationService)scope.ServiceProvider.GetRequiredService<IDoctorRosterNotificationService>();
                await svc.SendRosterChangeAsync(doctorId, branchId, change, actorName, actorUserId);
            }
            catch (Exception ex) { logger.LogWarning(ex, "[ROSTER-NOTIFY] Roster change alert failed for doctor {DoctorId}", doctorId); }
        });
    }

    private async Task SendRosterChangeAsync(int doctorId, int branchId, string change, string? actorName, int? actorUserId)
    {
        using var con = db.CreateConnection();
        var setting = await SettingAsync(con, branchId, RosterNotifyEvents.DailyRoster);
        if (setting is not { IsEnabled: true }) return;
        var doc = await con.QueryFirstOrDefaultAsync<DoctorRoomInfo>("dbo.usp_AuditNotify_DoctorRoom",
            new { DoctorId = doctorId, BranchId = branchId }, commandType: CommandType.StoredProcedure);
        if (doc is null) return;
        List<WeeklyRow> week; List<LeaveRow> leave;
        using (var grid = await con.QueryMultipleAsync("dbo.usp_AuditNotify_DoctorWeekly", new { DoctorId = doctorId, BranchId = branchId },
                   commandType: CommandType.StoredProcedure))
        {
            week = (await grid.ReadAsync<WeeklyRow>()).ToList();
            leave = (await grid.ReadAsync<LeaveRow>()).ToList();
        }
        actorName ??= actorUserId is > 0 ? await con.QueryFirstOrDefaultAsync<string>(
            "SELECT ISNULL(NULLIF(LTRIM(RTRIM(FullName)), ''), Username) FROM dbo.Users WHERE Id = @id", new { id = actorUserId }) : null;
        var msg = RosterChangeMessage(change, doc, week, leave, setting.BranchName ?? doc.BranchName, actorName);
        var to = new List<Recipient>();
        if (setting.NotifyDoctor) to.Add(new Recipient { Name = doc.DoctorName, Mobile = doc.Mobile, Email = doc.Email });
        to.AddRange(await UsersAsync(con, branchId, RosterNotifyEvents.DailyRoster));
        await DeliverAsync(con, setting, RosterNotifyEvents.DailyRoster, to, msg, actorUserId, "OPD", doctorId);
    }

    private static Message RosterChangeMessage(string change, DoctorRoomInfo d, List<WeeklyRow> week, List<LeaveRow> leave, string? branch, string? actor)
    {
        var todayDow = (byte)DateTime.Today.DayOfWeek;                        // 0 = Sunday, as the schedules keep it
        var docRoom = Room(d.RoomName, d.FloorName);
        string Line(WeeklyRow w) =>
            RosterItem.Session(w.DayOfWeek, w.StartTime, w.EndTime) +
            (w.SlotDurationMinutes is > 0 ? $" · {w.SlotDurationMinutes} min slots" : "") +
            (w.MaxPatientsPerSlot is > 0 ? $" · {w.MaxPatientsPerSlot}/slot" : "") +
            (w.MaxPatientsPerSession is > 0 ? $" · max {w.MaxPatientsPerSession}" : "") +
            (string.IsNullOrWhiteSpace(w.RoomName) ? "" : $" · {Room(w.RoomName, w.FloorName)}") +
            (w.EffectiveFrom.Date > DateTime.Today ? $" · from {w.EffectiveFrom:dd-MMM-yyyy}" : "") +
            (w.DayOfWeek == todayDow && w.EffectiveFrom.Date <= DateTime.Today ? "  ← today" : "");
        string LeaveLine(LeaveRow l) => l.ExceptionDate.ToString("ddd, dd-MMM-yyyy", Inv) +
            (string.IsNullOrWhiteSpace(l.ExceptionType) || l.ExceptionType == "Leave" ? "" : $" ({l.ExceptionType})") +
            (string.IsNullOrWhiteSpace(l.Reason) ? "" : $" - {l.Reason}");
        var when = DateTime.Now.ToString("dd-MMM-yyyy hh:mm tt", Inv);

        var sb = new StringBuilder();
        sb.Append("🔄 *Roster updated: ").Append(change).Append("*\n\n")
          .Append("🗓️ *OPD roster - ").Append(d.DoctorName).Append("*\n\n")
          .Append("Room: *").Append(docRoom).Append("*\n");
        if (!string.IsNullOrWhiteSpace(d.SpecialityName)) sb.Append("Department: ").Append(d.SpecialityName).Append('\n');
        sb.Append("Branch: ").Append(branch ?? "-").Append("\n\n*Weekly sessions*\n");
        if (week.Count == 0) sb.Append("No active session.\n");
        foreach (var w in week) sb.Append("• ").Append(Line(w)).Append('\n');
        if (leave.Count > 0)
        {
            sb.Append("\n*Leave (next 60 days)*\n");
            foreach (var l in leave) sb.Append("• ").Append(LeaveLine(l)).Append('\n');
        }
        sb.Append("\nBy: ").Append(string.IsNullOrWhiteSpace(actor) ? "System" : actor).Append(" · ").Append(when);

        var html = new StringBuilder();
        html.Append("<div style=\"font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937\">")
            .Append("<p style=\"margin:0 0 8px;color:#b45309\"><b>Roster updated: ").Append(H(change)).Append("</b></p>")
            .Append("<h3 style=\"margin:0 0 8px\">OPD roster - ").Append(H(d.DoctorName)).Append("</h3>")
            .Append("<table cellpadding=\"4\" style=\"border-collapse:collapse\">").Append(Row("Room", docRoom))
            .Append(string.IsNullOrWhiteSpace(d.SpecialityName) ? "" : Row("Department", d.SpecialityName!)).Append(Row("Branch", branch ?? "-"))
            .Append(Row("Weekly sessions", week.Count == 0 ? "No active session." : string.Join("<br>", week.Select(w => H(Line(w)))), raw: true));
        if (leave.Count > 0) html.Append(Row("Leave (next 60 days)", string.Join("<br>", leave.Select(l => H(LeaveLine(l)))), raw: true));
        html.Append(Row("By", (string.IsNullOrWhiteSpace(actor) ? "System" : actor) + " · " + when)).Append("</table></div>");
        return new Message(sb.ToString(), $"Roster updated - {d.DoctorName}: {change}", html.ToString(), $"{d.DoctorName} roster");
    }

    // ── test ─────────────────────────────────────────────────────────────────────────────────────────────────
    public async Task<(int Sent, int Skipped, string Message)> SendTestAsync(int branchId, string eventCode, string? actorName, int? actorUserId)
    {
        using var con = db.CreateConnection();
        var setting = await SettingAsync(con, branchId, eventCode);
        var users = await UsersAsync(con, branchId, eventCode);
        if (setting is not { IsEnabled: true } || users.Count == 0)
            return (0, 0, "This alert is off for this branch, or no user is chosen for it - save it with users first (a test never goes to doctors).");
        // the real roster of today's first doctor, marked as a test
        Message msg;
        {
            var rows = (await con.QueryAsync<Session>("dbo.usp_AuditNotify_DoctorRoster",
                new { BranchId = branchId, Date = DateTime.Today, DoctorId = (int?)null }, commandType: CommandType.StoredProcedure)).ToList();
            var doc = rows.Count > 0 ? rows.Where(r => r.DoctorId == rows[0].DoctorId).ToList()
                : [new Session { DoctorName = "Dr. Sample Doctor", StartTime = new TimeSpan(10, 0, 0), EndTime = new TimeSpan(13, 0, 0), SlotDurationMinutes = 15, MaxPatientsPerSlot = 1, RoomName = "101" }];
            msg = RosterMessage(doc, DateTime.Today, setting.BranchName);
        }
        msg = msg with { Text = "🧪 *TEST* - no change was made.\n\n" + msg.Text, Subject = "[TEST] " + msg.Subject,
                         Html = "<p style=\"color:#b45309\"><b>TEST</b> - no change was made.</p>" + msg.Html, RefNo = "TEST" };
        var (s, k) = await DeliverAsync(con, setting, eventCode, users, msg, actorUserId, "AUDIT", null);
        return (s, k, $"{s} sent{(k > 0 ? $", {k} not sent (see the log below)" : "")}.");
    }

    // ── delivery ─────────────────────────────────────────────────────────────────────────────────────────────
    private async Task<(int Sent, int Skipped)> DeliverAsync(IDbConnection con, Setting setting, string eventCode, List<Recipient> to, Message msg,
        int? triggeredBy, string moduleCode, int? refId)
    {
        int sent = 0, skipped = 0;
        foreach (var r in to)
        {
            if (setting.SendWhatsApp)
            {
                string status, detail;
                if (string.IsNullOrWhiteSpace(r.Mobile)) { status = "Skipped"; detail = r.UserId is null ? "No mobile number in Doctor Master." : "No mobile number in User Master."; }
                else
                {
                    try
                    {
                        var res = await whatsApp.SendTextMessageAsync(r.Mobile!, msg.Text, setting.BranchId, moduleCode, refId);
                        status = res.Success ? "Sent" : "Failed";
                        detail = res.Success ? $"WhatsApp to {r.Mobile}" : (res.ErrorMessage ?? "WhatsApp did not accept the message.");
                    }
                    catch (Exception ex) { status = "Failed"; detail = ex.Message; }
                }
                if (status == "Sent") sent++; else skipped++;
                await LogAsync(con, setting, eventCode, msg, r, r.Mobile, "WHATSAPP", status, detail, msg.Text, triggeredBy);
            }
            if (setting.SendEmail)
            {
                string status, detail;
                if (string.IsNullOrWhiteSpace(r.Email) || !r.Email.Contains('@')) { status = "Skipped"; detail = r.UserId is null ? "No e-mail in Doctor Master." : "No e-mail in User Master."; }
                else
                {
                    try
                    {
                        var (ok, m) = await email.SendEmailAsync(setting.BranchId, r.Email!, msg.Subject, msg.Html);
                        status = ok ? "Sent" : "Failed";
                        detail = ok ? $"E-mail to {r.Email}" : (string.IsNullOrWhiteSpace(m) ? "The e-mail was not sent." : m);
                    }
                    catch (Exception ex) { status = "Failed"; detail = ex.Message; }
                }
                if (status == "Sent") sent++; else skipped++;
                await LogAsync(con, setting, eventCode, msg, r, r.Email, "EMAIL", status, detail, msg.Subject, triggeredBy);
            }
        }
        return (sent, skipped);
    }

    private static Task LogAsync(IDbConnection con, Setting s, string eventCode, Message msg, Recipient r, string? address, string channel,
        string status, string detail, string body, int? triggeredBy) =>
        con.ExecuteAsync("dbo.usp_AuditNotify_Log", new
        {
            s.CompanyId, BranchId = (int?)s.BranchId, EventCode = eventCode, RefNo = msg.RefNo, UserId = r.UserId, Phone = address,
            Status = status, Detail = detail, Message = body, TriggeredBy = triggeredBy, Channel = channel,
            RecipientName = r.UserId is null ? r.Name : null
        }, commandType: CommandType.StoredProcedure);

    private static Task<Setting?> SettingAsync(IDbConnection con, int branchId, string eventCode) =>
        con.QueryFirstOrDefaultAsync<Setting>("dbo.usp_AuditNotify_EventSetting", new { BranchId = branchId, EventCode = eventCode },
            commandType: CommandType.StoredProcedure);

    private static async Task<List<Recipient>> UsersAsync(IDbConnection con, int branchId, string eventCode) =>
        (await con.QueryAsync<Recipient>("dbo.usp_AuditNotify_GetRecipients", new { BranchId = branchId, EventCode = eventCode },
            commandType: CommandType.StoredProcedure)).ToList();

    private static string H(string? s) => WebUtility.HtmlEncode(s ?? "");
    private static string Row(string label, string value, bool raw = false) =>
        $"<tr><td style=\"color:#6b7280;padding-right:14px;vertical-align:top\">{H(label)}</td><td><b>{(raw ? value : H(value))}</b></td></tr>";
}
