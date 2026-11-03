using System.Data;
using System.Globalization;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

/// <summary>The events of Settings > Audit Notification Setup (dbo.AuditNotifyEvent, SQLScripts/2397).</summary>
public static class AuditNotifyEvents
{
    public const string LabBillCancel = "LAB_BILL_CANCEL";
    public const string LabRefund = "LAB_REFUND";
    public const string OpdBillCancel = "OPD_BILL_CANCEL";
    public const string OpdRefund = "OPD_REFUND";
    public const string LabReportUnauthorised = "LAB_REPORT_UNAUTH";

    public static string Cancel(string moduleCode) => string.Equals(moduleCode, "OPD", StringComparison.OrdinalIgnoreCase) ? OpdBillCancel : LabBillCancel;
    public static string Refund(string moduleCode) => string.Equals(moduleCode, "OPD", StringComparison.OrdinalIgnoreCase) ? OpdRefund : LabRefund;
}

/// <summary>What happened, for one alert: the bill it is about and the lines that describe the action.</summary>
public sealed record AuditNotice(string EventCode, string ModuleCode, int ModuleRefId, string Title, IReadOnlyList<(string Label, string Value)> Lines,
    string? ActorName, int? ActorUserId);

/// <summary>
/// Settings > Audit Notification Setup (SQLScripts/2397): WhatsApp alerts of sensitive actions - a LAB / OPD bill cancelled
/// (full or partial), a refund, a LAB report un-authorised - to the users chosen for that event (their User Master mobile).
/// Sent in the background after the action has succeeded: it never slows down or fails the action. Every alert is logged
/// (Sent / Failed / Skipped) in dbo.AuditNotifyLog.
/// </summary>
public interface IAuditNotificationService
{
    /// <summary>Sends the alert in the background (returns at once).</summary>
    void Queue(AuditNotice notice);

    /// <summary>A bill was cancelled (LAB or OPD): its cancellation number, type, items, amounts and reason.</summary>
    void QueueCancellation(int cancellationId, string? actorName, int? actorUserId);

    /// <summary>A refund against a cancellation (LAB or OPD).</summary>
    void QueueRefund(string moduleCode, int moduleRefId, int cancellationId, decimal amount, string? mode, string? reference, string? actorName, int? actorUserId);

    Task<(int Sent, int Skipped, string Message)> SendNowAsync(AuditNotice notice);

    /// <summary>A sample alert of an event to its chosen users (the Test button of the page).</summary>
    Task<(int Sent, int Skipped, string Message)> SendTestAsync(int companyId, int branchId, string eventCode, string? actorName, int? actorUserId);
}

public class AuditNotificationService(IServiceScopeFactory scopeFactory, IDbConnectionFactory db, IWhatsAppService whatsApp,
    ILogger<AuditNotificationService> logger) : IAuditNotificationService
{
    private sealed class Context
    {
        public string? BillNo { get; set; }
        public string? TokenNo { get; set; }
        public string? PatientCode { get; set; }
        public string? PatientName { get; set; }
        public int BranchId { get; set; }
        public string? BranchName { get; set; }
        public int CompanyId { get; set; }
        public string? BillingType { get; set; }
    }

    private sealed class Recipient
    {
        public int UserId { get; set; }
        public string? Name { get; set; }
        public string? Mobile { get; set; }
    }

    private sealed class CancellationRow
    {
        public string? CancellationNo { get; set; }
        public string ModuleCode { get; set; } = "LAB";
        public int ModuleRefId { get; set; }
        public string? CancellationType { get; set; }
        public decimal CancelledAmount { get; set; }
        public decimal DiscountAdjusted { get; set; }
        public string? Reason { get; set; }
        public string? ItemNames { get; set; }
    }

    private static readonly CultureInfo In = CultureInfo.GetCultureInfo("en-IN");
    private static string Rs(decimal v) => "₹" + v.ToString("#,##0.00", In);

    public void Queue(AuditNotice notice) => Background(svc => svc.SendNowAsync(notice), notice.EventCode);

    public void QueueCancellation(int cancellationId, string? actorName, int? actorUserId) => Background(async svc =>
    {
        using var con = db.CreateConnection();
        var c = await con.QueryFirstOrDefaultAsync<CancellationRow>("dbo.usp_AuditNotify_Cancellation",
            new { CancellationId = cancellationId }, commandType: CommandType.StoredProcedure);
        if (c is null) return;
        var lines = new List<(string, string)>
        {
            ("Cancellation", $"{c.CancellationNo} ({c.CancellationType})"),
            (c.ModuleCode == "OPD" ? "Services" : "Tests", string.IsNullOrWhiteSpace(c.ItemNames) ? "-" : c.ItemNames!),
            ("Amount", Rs(c.CancelledAmount) + (c.DiscountAdjusted > 0 ? $" (discount taken back {Rs(c.DiscountAdjusted)})" : "")),
            ("Reason", c.Reason ?? "-")
        };
        await svc.SendNowAsync(new AuditNotice(AuditNotifyEvents.Cancel(c.ModuleCode), c.ModuleCode, c.ModuleRefId,
            $"{c.ModuleCode} bill cancelled - {c.CancellationType?.ToLowerInvariant()}", lines, actorName, actorUserId));
    }, "CANCEL");

    public void QueueRefund(string moduleCode, int moduleRefId, int cancellationId, decimal amount, string? mode, string? reference,
        string? actorName, int? actorUserId) => Background(async svc =>
    {
        string? cancNo = null;
        using (var con = db.CreateConnection())
            cancNo = (await con.QueryFirstOrDefaultAsync<CancellationRow>("dbo.usp_AuditNotify_Cancellation",
                new { CancellationId = cancellationId }, commandType: CommandType.StoredProcedure))?.CancellationNo;
        var lines = new List<(string, string)>
        {
            ("Refund", Rs(amount) + (string.IsNullOrWhiteSpace(mode) ? "" : $" by {mode}") + (string.IsNullOrWhiteSpace(reference) ? "" : $" (ref {reference})")),
            ("Against", cancNo ?? $"cancellation #{cancellationId}")
        };
        var module = string.Equals(moduleCode, "OPD", StringComparison.OrdinalIgnoreCase) ? "OPD" : "LAB";
        await svc.SendNowAsync(new AuditNotice(AuditNotifyEvents.Refund(module), module, moduleRefId, $"{module} refund", lines, actorName, actorUserId));
    }, "REFUND");

    private void Background(Func<IAuditNotificationService, Task> work, string what)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                await work(scope.ServiceProvider.GetRequiredService<IAuditNotificationService>());
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "[AUDIT-NOTIFY] {What} alert failed", what);
            }
        });
    }

    public async Task<(int Sent, int Skipped, string Message)> SendNowAsync(AuditNotice n)
    {
        using var con = db.CreateConnection();
        var ctx = await con.QueryFirstOrDefaultAsync<Context>("dbo.usp_AuditNotify_Context",
            new { ModuleCode = n.ModuleCode, ModuleRefId = n.ModuleRefId }, commandType: CommandType.StoredProcedure);
        if (ctx is null) return (0, 0, "The bill was not found.");
        return await SendAsync(con, ctx, n, test: false);
    }

    public async Task<(int Sent, int Skipped, string Message)> SendTestAsync(int companyId, int branchId, string eventCode, string? actorName, int? actorUserId)
    {
        using var con = db.CreateConnection();
        var branch = await con.QueryFirstOrDefaultAsync<string>("SELECT BranchName FROM dbo.Branchmaster WHERE BranchID = @branchId", new { branchId });
        var ctx = new Context { BillNo = "TEST", PatientName = "Sample patient", PatientCode = "-", BranchId = branchId, BranchName = branch, CompanyId = companyId };
        var title = await con.QueryFirstOrDefaultAsync<string>("SELECT Title FROM dbo.AuditNotifyEvent WHERE EventCode = @eventCode", new { eventCode }) ?? eventCode;
        var notice = new AuditNotice(eventCode, "TEST", 0, title + " (test)",
            [("Note", "This is a test of the audit alert - no bill was changed.")], actorName, actorUserId);
        return await SendAsync(con, ctx, notice, test: true);
    }

    private async Task<(int Sent, int Skipped, string Message)> SendAsync(IDbConnection con, Context ctx, AuditNotice n, bool test)
    {
        var recipients = (await con.QueryAsync<Recipient>("dbo.usp_AuditNotify_GetRecipients",
            new { ctx.BranchId, n.EventCode }, commandType: CommandType.StoredProcedure)).ToList();
        if (recipients.Count == 0)
            return (0, 0, test ? "This alert is off for this branch, or nobody is chosen for it - save it with users first." : "No recipient.");

        if (string.IsNullOrWhiteSpace(n.ActorName) && n.ActorUserId is > 0)
            n = n with { ActorName = await con.QueryFirstOrDefaultAsync<string>(
                "SELECT ISNULL(NULLIF(LTRIM(RTRIM(FullName)), ''), Username) FROM dbo.Users WHERE Id = @id", new { id = n.ActorUserId }) };
        var text = Compose(ctx, n);
        int sent = 0, skipped = 0;
        foreach (var r in recipients)
        {
            string status, detail;
            if (string.IsNullOrWhiteSpace(r.Mobile)) { status = "Skipped"; detail = "No mobile number in User Master."; skipped++; }
            else
            {
                try
                {
                    var res = await whatsApp.SendTextMessageAsync(r.Mobile!, text, ctx.BranchId, "AUDIT", n.ModuleRefId > 0 ? n.ModuleRefId : null);
                    status = res.Success ? "Sent" : "Failed";
                    detail = res.Success ? $"Sent to {r.Mobile}" : (res.ErrorMessage ?? "WhatsApp did not accept the message.");
                    if (res.Success) sent++; else skipped++;
                }
                catch (Exception ex) { status = "Failed"; detail = ex.Message; skipped++; }
            }
            await con.ExecuteAsync("dbo.usp_AuditNotify_Log", new
            {
                ctx.CompanyId, BranchId = ctx.BranchId > 0 ? ctx.BranchId : (int?)null, n.EventCode, RefNo = ctx.BillNo,
                UserId = r.UserId, Phone = r.Mobile, Status = status, Detail = detail, Message = text, TriggeredBy = n.ActorUserId
            }, commandType: CommandType.StoredProcedure);
        }
        return (sent, skipped, $"{sent} sent{(skipped > 0 ? $", {skipped} not sent (see the log below)" : "")}.");
    }

    private static string Compose(Context c, AuditNotice n)
    {
        var sb = new System.Text.StringBuilder();
        sb.Append("🔔 *Audit alert - ").Append(n.Title).Append("*\n\n");
        if (n.ModuleCode != "TEST")
        {
            sb.Append("Bill: ").Append(c.BillNo).Append(string.IsNullOrWhiteSpace(c.BillingType) ? "" : $" ({c.BillingType})")
              .Append(string.IsNullOrWhiteSpace(c.TokenNo) ? "" : $" · Token {c.TokenNo}").Append('\n');
            sb.Append("Patient: ").Append(c.PatientName).Append(string.IsNullOrWhiteSpace(c.PatientCode) ? "" : $" ({c.PatientCode})").Append('\n');
        }
        foreach (var (label, value) in n.Lines) sb.Append(label).Append(": ").Append(value).Append('\n');
        sb.Append("Branch: ").Append(c.BranchName ?? "-").Append('\n');
        sb.Append("By: ").Append(string.IsNullOrWhiteSpace(n.ActorName) ? "System" : n.ActorName).Append(" · ").Append(DateTime.Now.ToString("dd-MMM-yyyy hh:mm tt", CultureInfo.InvariantCulture));
        return sb.ToString();
    }
}
