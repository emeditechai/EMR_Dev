using System.Data;
using System.Net;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

/// <summary>
/// Membership renewal reminders by e-mail (script 2226). Every few minutes it asks which cards have reached a
/// reminder stage that has not been handled: Hospital Settings of the issuing branch says whether reminders are on,
/// how many days before expiry they go out and from what time of day. Times are the server's local time.
/// It lives in EMR.Web because the SMTP configuration, its protected password and the mail log are here.
/// Each reminder is a REMINDER row on the card's ledger, which is also what stops a second mail for the same stage.
/// </summary>
public class MembershipRenewalReminderBackgroundService(
    IServiceProvider serviceProvider,
    ILogger<MembershipRenewalReminderBackgroundService> logger,
    IConfiguration configuration) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!configuration.GetValue("MembershipRenewalReminder:Enabled", true))
        {
            logger.LogInformation("Membership renewal reminder scheduler is disabled in appsettings.");
            return;
        }

        var poll = TimeSpan.FromMinutes(Math.Clamp(configuration.GetValue("MembershipRenewalReminder:PollMinutes", 15), 1, 240));
        logger.LogInformation("Membership renewal reminder scheduler started; checking every {Minutes} minute(s).", poll.TotalMinutes);

        using var timer = new PeriodicTimer(poll);
        do
        {
            try
            {
                await SendDueRemindersAsync(stoppingToken);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Membership renewal reminder scheduler: check failed.");
            }
        }
        while (await WaitAsync(timer, stoppingToken));
    }

    private static async Task<bool> WaitAsync(PeriodicTimer timer, CancellationToken token)
    {
        try { return await timer.WaitForNextTickAsync(token); }
        catch (OperationCanceledException) { return false; }
    }

    private async Task SendDueRemindersAsync(CancellationToken token)
    {
        using var scope = serviceProvider.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<IDbConnectionFactory>();
        var emailService = scope.ServiceProvider.GetRequiredService<IEmailService>();
        var now = DateTime.Now;

        List<DueReminder> due;
        using (var con = db.CreateConnection())
            due = (await con.QueryAsync<DueReminder>("dbo.usp_MembershipRenewalReminder_GetDue", new { Now = now }, commandType: CommandType.StoredProcedure)).ToList();
        if (due.Count == 0) return;

        int sent = 0, skipped = 0, failed = 0;
        foreach (var r in due)
        {
            if (token.IsCancellationRequested) break;

            long? ledgerId;
            using (var con = db.CreateConnection())
                ledgerId = await con.QuerySingleAsync<long?>("dbo.usp_MembershipRenewalReminder_Claim",
                    new { r.CardId, r.StageDays, Now = now }, commandType: CommandType.StoredProcedure);
            if (ledgerId == null) continue;   // another server took it, or the card is no longer due

            string outcome, detail;
            try
            {
                if (string.IsNullOrWhiteSpace(r.EmailId))
                {
                    (outcome, detail) = ("skipped", "the primary member has no email address");
                    skipped++;
                }
                else
                {
                    var (ok, text) = await emailService.SendEmailAsync(r.BranchId, r.EmailId, Subject(r), Body(r));
                    if (ok) { (outcome, detail) = ("sent", "emailed to " + r.EmailId); sent++; }
                    else { (outcome, detail) = ("failed", text); failed++; }
                }
            }
            catch (Exception ex)
            {
                (outcome, detail) = ("failed", ex.Message);
                failed++;
                logger.LogError(ex, "Membership renewal reminder: card {CardNo} failed.", r.CardNo);
            }

            using (var con = db.CreateConnection())
                await con.ExecuteAsync("dbo.usp_MembershipRenewalReminder_Complete",
                    new { LedgerId = ledgerId.Value, Outcome = outcome, Detail = detail.Length > 200 ? detail[..200] : detail },
                    commandType: CommandType.StoredProcedure);
        }

        logger.LogInformation("Membership renewal reminders: {Due} card(s) due - {Sent} sent, {Skipped} skipped (no email), {Failed} failed.",
            due.Count, sent, skipped, failed);
    }

    private static string HospitalName(DueReminder r) => string.IsNullOrWhiteSpace(r.HospitalName) ? "our lab" : r.HospitalName!;

    private static string Subject(DueReminder r) =>
        r.DaysLeft <= 0
            ? $"Your {r.PlanName} membership expires today - {HospitalName(r)}"
            : $"Your {r.PlanName} membership expires in {r.DaysLeft} day(s) - {HospitalName(r)}";

    private static string Body(DueReminder r)
    {
        var template = string.IsNullOrWhiteSpace(r.Template) ? HospitalSettings.DefaultMembershipRenewalReminderMessage : r.Template!;
        var message = template
            .Replace("{PatientName}", r.PatientName)
            .Replace("{HospitalName}", HospitalName(r))
            .Replace("{PlanName}", r.PlanName)
            .Replace("{CardNo}", r.CardNo)
            .Replace("{ValidTo}", r.ValidTo.ToString("dd MMM yyyy"))
            .Replace("{DaysLeft}", r.DaysLeft <= 0 ? "today" : $"in {r.DaysLeft} day(s)")
            .Replace("{Points}", r.PointsBalance.ToString("0.##"))
            .Trim();

        return EmailLayout.Wrap(
            EmailLayout.P(WebUtility.HtmlEncode(message).Replace("\n", "<br/>"))
            + EmailLayout.Details(
                ("Card No", WebUtility.HtmlEncode(r.CardNo)),
                ("Plan", WebUtility.HtmlEncode(r.PlanName)),
                ("Valid to", r.ValidTo.ToString("dd MMM yyyy")),
                ("Points balance", r.PointsBalance.ToString("0.##"))),
            heading: r.DaysLeft <= 0 ? "Your membership expires today" : "Your membership is due for renewal",
            organisation: HospitalName(r));
    }

    private sealed class DueReminder
    {
        public int CardId { get; set; }
        public int CompanyId { get; set; }
        public int BranchId { get; set; }
        public string CardNo { get; set; } = string.Empty;
        public string PlanName { get; set; } = string.Empty;
        public string PatientName { get; set; } = string.Empty;
        public string? EmailId { get; set; }
        public DateTime ValidTo { get; set; }
        public int DaysLeft { get; set; }
        public int StageDays { get; set; }
        public decimal PointsBalance { get; set; }
        public string? HospitalName { get; set; }
        public string? Template { get; set; }
    }
}
