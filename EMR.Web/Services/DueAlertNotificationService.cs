using System.Data;
using System.Globalization;
using System.Net;
using System.Text;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

/// <summary>Settings > Audit Notification Setup > Due Alert (SQLScripts/2531): its events.</summary>
public static class DueNotifyEvents
{
    public const string OpdDue = "OPD_DUE_ALERT";
    public const string LabDue = "LAB_DUE_ALERT";
    public static readonly string[] All = [OpdDue, LabDue];
    public static bool Is(string? code) => code is OpdDue or LabDue;
}

/// <summary>
/// Due Alert (SQLScripts/2531): the OPD / LAB B2C bills of a branch whose due (net - paid) as on the date has reached the
/// amount set for the branch - bill no, patient, due of each bill and the total - to the users chosen for the event, by
/// WhatsApp and / or e-mail. Sent every day at the branch's send time (DueAlertNotificationWorker) or with "Send now".
/// Company and branch wise: the list, the setting and the users are those of the one branch (of its company).
/// </summary>
public interface IDueAlertNotificationService
{
    /// <summary>The branch's due list of the event, now, to its chosen users. Nothing is sent when no bill has reached the amount.</summary>
    Task<(int Sent, int Skipped, string Message)> SendDueListAsync(int branchId, string eventCode, int? triggeredBy);

    /// <summary>The branch's real due list marked as a test (or sample rows when there is none), to the chosen users.</summary>
    Task<(int Sent, int Skipped, string Message)> SendTestAsync(int branchId, string eventCode, int? actorUserId);
}

public class DueAlertNotificationService(IDbConnectionFactory db, IWhatsAppService whatsApp, IEmailService email) : IDueAlertNotificationService
{
    private sealed class Header
    {
        public int CompanyId { get; set; }
        public int BranchId { get; set; }
        public string? BranchName { get; set; }
        public bool IsEnabled { get; set; }
        public bool SendWhatsApp { get; set; }
        public bool SendEmail { get; set; }
        public decimal ThresholdAmount { get; set; }
        public string Module { get; set; } = "OPD";
        public string? Title { get; set; }
        public int BillCount { get; set; }
        public int PatientCount { get; set; }
        public decimal TotalDue { get; set; }
        public DateTime AsOn { get; set; }
    }

    private sealed class Bill
    {
        public int RefId { get; set; }
        public string? BillNo { get; set; }
        public DateTime? BillDate { get; set; }
        public int AgeDays { get; set; }
        public string? PatientCode { get; set; }
        public string? PatientName { get; set; }
        public string? Mobile { get; set; }
        public decimal NetAmount { get; set; }
        public decimal PaidAmount { get; set; }
        public decimal DueAmount { get; set; }
    }

    private sealed class Recipient
    {
        public int UserId { get; set; }
        public string? Name { get; set; }
        public string? Mobile { get; set; }
        public string? Email { get; set; }
    }

    private sealed record Message(string Text, string Subject, string Html, string RefNo);

    private const int WhatsAppBills = 25;     // a WhatsApp message stays short: the largest dues, then "+N more"
    private const int EmailBills = 500;

    private static readonly CultureInfo In = CultureInfo.GetCultureInfo("en-IN");
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    private static string Rs(decimal v) => "₹" + v.ToString("#,##0.00", In);
    private static string D(DateTime? d) => d?.ToString("dd-MMM-yyyy", Inv) ?? "-";
    private static string H(string? s) => WebUtility.HtmlEncode(s ?? "");

    private async Task<(Header? Head, List<Bill> Bills)> LoadAsync(IDbConnection con, int branchId, string eventCode)
    {
        using var grid = await con.QueryMultipleAsync("dbo.usp_AuditNotify_DueList", new { BranchId = branchId, EventCode = eventCode, Top = EmailBills },
            commandType: CommandType.StoredProcedure);
        if (grid.IsConsumed) return (null, []);
        var head = await grid.ReadFirstOrDefaultAsync<Header>();
        var bills = grid.IsConsumed ? [] : (await grid.ReadAsync<Bill>()).ToList();
        return (head, bills);
    }

    private static async Task<List<Recipient>> UsersAsync(IDbConnection con, int branchId, string eventCode) =>
        (await con.QueryAsync<Recipient>("dbo.usp_AuditNotify_GetRecipients", new { BranchId = branchId, EventCode = eventCode },
            commandType: CommandType.StoredProcedure)).ToList();

    public async Task<(int Sent, int Skipped, string Message)> SendDueListAsync(int branchId, string eventCode, int? triggeredBy)
    {
        if (!DueNotifyEvents.Is(eventCode)) return (0, 0, "Unknown due alert.");
        using var con = db.CreateConnection();
        var (head, bills) = await LoadAsync(con, branchId, eventCode);
        if (head is not { IsEnabled: true }) return (0, 0, "This alert is off for this branch - switch it on and save it first.");
        if (head.BillCount == 0) return (0, 0, $"No {Area(head)} bill has a due of {Rs(head.ThresholdAmount)} or more today - nothing to send.");
        var users = await UsersAsync(con, branchId, eventCode);
        if (users.Count == 0) return (0, 0, "Nobody is chosen for this alert - save it with users first.");
        var (s, k) = await DeliverAsync(con, head, eventCode, users, Compose(head, bills), triggeredBy);
        return (s, k, $"{head.BillCount} bill(s), total due {Rs(head.TotalDue)}: {s} sent{(k > 0 ? $", {k} not sent (see the log below)" : "")}.");
    }

    public async Task<(int Sent, int Skipped, string Message)> SendTestAsync(int branchId, string eventCode, int? actorUserId)
    {
        if (!DueNotifyEvents.Is(eventCode)) return (0, 0, "Unknown due alert.");
        using var con = db.CreateConnection();
        var (head, bills) = await LoadAsync(con, branchId, eventCode);
        var users = await UsersAsync(con, branchId, eventCode);
        if (head is not { IsEnabled: true } || users.Count == 0)
            return (0, 0, "This alert is off for this branch, or nobody is chosen for it - save it with users first.");
        if (bills.Count == 0)
        {
            var mod = head.Module == "LAB" ? "LAB" : "OPD";
            bills =
            [
                new Bill { BillNo = $"{mod}/SAMPLE/0001", BillDate = DateTime.Today.AddDays(-3), PatientCode = "P0001", PatientName = "Sample patient 1", NetAmount = 2500, PaidAmount = 1000, DueAmount = 1500 },
                new Bill { BillNo = $"{mod}/SAMPLE/0002", BillDate = DateTime.Today, PatientCode = "P0002", PatientName = "Sample patient 2", NetAmount = 1200, DueAmount = 1200 }
            ];
            head.BillCount = bills.Count; head.PatientCount = bills.Count; head.TotalDue = bills.Sum(b => b.DueAmount);
        }
        var msg = Compose(head, bills);
        msg = msg with { Text = "🧪 *TEST* - nothing was changed.\n\n" + msg.Text, Subject = "[TEST] " + msg.Subject,
                         Html = "<p style=\"color:#b45309\"><b>TEST</b> - nothing was changed.</p>" + msg.Html, RefNo = "TEST" };
        var (s, k) = await DeliverAsync(con, head, eventCode, users, msg, actorUserId);
        return (s, k, $"{s} sent{(k > 0 ? $", {k} not sent (see the log below)" : "")}.");
    }

    private static string Area(Header h) => h.Module == "LAB" ? "LAB B2C" : "OPD";

    // ── the message: due as on date, then each bill - bill no, patient, due amount ──
    private static Message Compose(Header h, List<Bill> bills)
    {
        var asOn = h.AsOn == default ? DateTime.Now : h.AsOn;
        var title = $"{Area(h)} Due Alert - as on {D(asOn)}";

        var sb = new StringBuilder();
        sb.Append("🔔 *").Append(title).Append("*\n\n");
        sb.Append("Branch: ").Append(h.BranchName ?? "-").Append('\n');
        sb.Append("Bills with due of ").Append(Rs(h.ThresholdAmount)).Append(" or more: *").Append(h.BillCount).Append("*\n");
        sb.Append("Total due as on ").Append(D(asOn)).Append(": *").Append(Rs(h.TotalDue)).Append("*\n\n");
        var i = 0;
        foreach (var b in bills.Take(WhatsAppBills))
        {
            i++;
            sb.Append(i).Append(". Bill ").Append(b.BillNo).Append(" (").Append(D(b.BillDate)).Append(")\n   ")
              .Append(b.PatientName).Append(string.IsNullOrWhiteSpace(b.PatientCode) ? "" : $" ({b.PatientCode})")
              .Append(" · Due *").Append(Rs(b.DueAmount)).Append("*\n");
        }
        if (h.BillCount > i) sb.Append("\n+").Append(h.BillCount - i).Append(" more bill(s) - see the e-mail or the ").Append(Area(h)).Append(" Outstanding Dues report.\n");
        sb.Append("\nSent ").Append(asOn.ToString("dd-MMM-yyyy hh:mm tt", Inv));

        var html = new StringBuilder();
        html.Append("<div style=\"font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#111827\">")
            .Append("<h3 style=\"margin:0 0 6px\">").Append(H(title)).Append("</h3>")
            .Append("<table style=\"border-collapse:collapse;margin-bottom:12px\">")
            .Append(Row("Branch", h.BranchName ?? "-"))
            .Append(Row("Bills with due of " + Rs(h.ThresholdAmount) + " or more", h.BillCount.ToString(Inv)))
            .Append(Row("Patients", h.PatientCount.ToString(Inv)))
            .Append(Row("Total due as on " + D(asOn), Rs(h.TotalDue)))
            .Append("</table>")
            .Append("<table style=\"border-collapse:collapse;width:100%;font-size:13px\"><thead><tr style=\"background:#f3f4f6\">");
        foreach (var c in new[] { "#", "Bill No", "Bill date", "Patient", "Net", "Paid", "Due" })
            html.Append("<th style=\"text-align:").Append(c is "Net" or "Paid" or "Due" ? "right" : "left").Append(";padding:6px;border:1px solid #e5e7eb\">").Append(c).Append("</th>");
        html.Append("</tr></thead><tbody>");
        i = 0;
        foreach (var b in bills)
        {
            i++;
            const string td = "padding:6px;border:1px solid #e5e7eb";
            html.Append("<tr><td style=\"").Append(td).Append("\">").Append(i).Append("</td>")
                .Append("<td style=\"").Append(td).Append("\">").Append(H(b.BillNo)).Append("</td>")
                .Append("<td style=\"").Append(td).Append("\">").Append(D(b.BillDate)).Append(b.AgeDays > 0 ? $" <span style=\"color:#6b7280\">({b.AgeDays} d)</span>" : "").Append("</td>")
                .Append("<td style=\"").Append(td).Append("\">").Append(H(b.PatientName)).Append(string.IsNullOrWhiteSpace(b.PatientCode) ? "" : $" <span style=\"color:#6b7280\">({H(b.PatientCode)})</span>").Append("</td>")
                .Append("<td style=\"").Append(td).Append(";text-align:right\">").Append(Rs(b.NetAmount)).Append("</td>")
                .Append("<td style=\"").Append(td).Append(";text-align:right\">").Append(Rs(b.PaidAmount)).Append("</td>")
                .Append("<td style=\"").Append(td).Append(";text-align:right;font-weight:600;color:#b91c1c\">").Append(Rs(b.DueAmount)).Append("</td></tr>");
        }
        html.Append("<tr style=\"background:#f9fafb;font-weight:700\"><td colspan=\"6\" style=\"padding:6px;border:1px solid #e5e7eb;text-align:right\">Total due</td>")
            .Append("<td style=\"padding:6px;border:1px solid #e5e7eb;text-align:right;color:#b91c1c\">").Append(Rs(h.TotalDue)).Append("</td></tr></tbody></table>");
        if (h.BillCount > bills.Count)
            html.Append("<p style=\"color:#6b7280\">The ").Append(bills.Count).Append(" largest dues are listed; ").Append(h.BillCount - bills.Count)
                .Append(" more bill(s) are in the ").Append(Area(h)).Append(" Outstanding Dues report.</p>");
        html.Append("<p style=\"color:#6b7280;font-size:12px\">Due = net amount - paid, as on ").Append(asOn.ToString("dd-MMM-yyyy hh:mm tt", Inv)).Append(".</p></div>");

        return new Message(sb.ToString(), $"{title} - {h.BranchName} - {h.BillCount} bill(s), {Rs(h.TotalDue)}", html.ToString(),
            $"{h.Module} DUE {asOn.ToString("dd-MMM-yyyy", Inv)}");
    }

    private static string Row(string label, string value) =>
        $"<tr><td style=\"color:#6b7280;padding:2px 14px 2px 0\">{H(label)}</td><td><b>{H(value)}</b></td></tr>";

    // ── delivery: WhatsApp and / or e-mail to each chosen user, each logged ──
    private async Task<(int Sent, int Skipped)> DeliverAsync(IDbConnection con, Header h, string eventCode, List<Recipient> to, Message msg, int? triggeredBy)
    {
        int sent = 0, skipped = 0;
        foreach (var r in to)
        {
            if (h.SendWhatsApp)
            {
                string status, detail;
                if (string.IsNullOrWhiteSpace(r.Mobile)) { status = "Skipped"; detail = "No mobile number in User Master."; }
                else
                {
                    try
                    {
                        var res = await whatsApp.SendTextMessageAsync(r.Mobile!, msg.Text, h.BranchId, "AUDIT", null);
                        status = res.Success ? "Sent" : "Failed";
                        detail = res.Success ? $"WhatsApp to {r.Mobile}" : (res.ErrorMessage ?? "WhatsApp did not accept the message.");
                    }
                    catch (Exception ex) { status = "Failed"; detail = ex.Message; }
                }
                if (status == "Sent") sent++; else skipped++;
                await LogAsync(con, h, eventCode, msg, r, r.Mobile, "WHATSAPP", status, detail, msg.Text, triggeredBy);
            }
            if (h.SendEmail)
            {
                string status, detail;
                if (string.IsNullOrWhiteSpace(r.Email) || !r.Email.Contains('@')) { status = "Skipped"; detail = "No e-mail in User Master."; }
                else
                {
                    try
                    {
                        var (ok, m) = await email.SendEmailAsync(h.BranchId, r.Email!, msg.Subject, msg.Html);
                        status = ok ? "Sent" : "Failed";
                        detail = ok ? $"E-mail to {r.Email}" : (string.IsNullOrWhiteSpace(m) ? "The e-mail was not sent." : m);
                    }
                    catch (Exception ex) { status = "Failed"; detail = ex.Message; }
                }
                if (status == "Sent") sent++; else skipped++;
                await LogAsync(con, h, eventCode, msg, r, r.Email, "EMAIL", status, detail, msg.Subject, triggeredBy);
            }
        }
        return (sent, skipped);
    }

    private static Task LogAsync(IDbConnection con, Header h, string eventCode, Message msg, Recipient r, string? address, string channel,
        string status, string detail, string body, int? triggeredBy) =>
        con.ExecuteAsync("dbo.usp_AuditNotify_Log", new
        {
            h.CompanyId, BranchId = (int?)h.BranchId, EventCode = eventCode, RefNo = msg.RefNo, UserId = (int?)r.UserId, Phone = address,
            Status = status, Detail = detail.Length > 500 ? detail[..500] : detail, Message = body, TriggeredBy = triggeredBy, Channel = channel,
            RecipientName = (string?)null
        }, commandType: CommandType.StoredProcedure);
}
