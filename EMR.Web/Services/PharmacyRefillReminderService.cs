using System.Data;
using System.Globalization;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

/// <summary>
/// Pharmacy refill reminders (SQLScripts/2406) and loyalty points expiry reminders (SQLScripts/2409). A counter bill line with "lasts N days" makes a reminder for the buyer's
/// mobile N days later, less Hospital Settings > MED > "Remind (Days Before Run-out)". When the branch has
/// "Refill Reminders by WhatsApp" on, this job sends the due ones by WhatsApp every 30 minutes between 09:00 and 19:00.
/// Each reminder is claimed in the database first (usp_PhRefill_Due), so it goes out once; a cancelled bill, or the same
/// medicine bought again since, is not reminded. Outcome is kept on dbo.PhRefillReminder (SENT / FAILED / SKIPPED).
/// </summary>
public sealed class PharmacyRefillReminderService(IServiceScopeFactory scopeFactory, ILogger<PharmacyRefillReminderService> logger) : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromMinutes(30);
    private const int SendFromHour = 9, SendUntilHour = 19;

    private sealed class Due
    {
        public int ReminderId { get; set; }
        public int BranchId { get; set; }
        public int SaleId { get; set; }
        public string? Name { get; set; }
        public string Mobile { get; set; } = "";
        public DateTime RunOutDate { get; set; }
        public string ItemName { get; set; } = "";
        public string? SaleNo { get; set; }
        public string? PharmacyName { get; set; }
        public string? PharmacyPhone { get; set; }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try { await Task.Delay(TimeSpan.FromMinutes(3), stoppingToken); } catch (OperationCanceledException) { return; }
        while (!stoppingToken.IsCancellationRequested)
        {
            var hour = DateTime.Now.Hour;
            if (hour >= SendFromHour && hour < SendUntilHour)
            {
                try { await RunOnceAsync(stoppingToken); }
                catch (Exception ex) when (ex is not OperationCanceledException) { logger.LogError(ex, "[PH-REFILL] Reminder run failed"); }
            }
            try { await Task.Delay(Interval, stoppingToken); } catch (OperationCanceledException) { return; }
        }
    }

    /// <summary>Sends every reminder due now (public for a manual run / test). Answers how many were sent.</summary>
    public async Task<int> RunOnceAsync(CancellationToken ct = default)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<IDbConnectionFactory>();
        var whatsApp = scope.ServiceProvider.GetRequiredService<IWhatsAppService>();
        using var con = db.CreateConnection();
        var due = (await con.QueryAsync<Due>("dbo.usp_PhRefill_Due", new { Take = 50 }, commandType: CommandType.StoredProcedure)).ToList();
        var sent = 0;
        foreach (var r in due)
        {
            ct.ThrowIfCancellationRequested();
            string status, detail;
            try
            {
                var res = await whatsApp.SendTextMessageAsync(r.Mobile, Compose(r), r.BranchId, "PHR", r.SaleId);
                status = res.Success ? "SENT" : "FAILED";
                detail = res.Success ? $"Sent to {r.Mobile}" : (res.ErrorMessage ?? "WhatsApp did not accept the message.");
                if (res.Success) sent++;
            }
            catch (Exception ex) { status = "FAILED"; detail = ex.Message; }
            await con.ExecuteAsync("dbo.usp_PhRefill_Mark", new { r.ReminderId, Status = status, Detail = detail }, commandType: CommandType.StoredProcedure);
        }
        if (due.Count > 0) logger.LogInformation("[PH-REFILL] {Sent} of {Due} refill reminder(s) sent", sent, due.Count);

        // loyalty wallet points about to expire (SQLScripts/2409): one WhatsApp per member, claimed in the database first
        var expiring = (await con.QueryAsync<ExpiryDue>("dbo.usp_PhLoyalty_ExpiryDue", new { Take = 50 }, commandType: CommandType.StoredProcedure)).ToList();
        foreach (var e in expiring.Where(x => !string.IsNullOrWhiteSpace(x.Phone)))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                var name = string.IsNullOrWhiteSpace(e.Name) ? "" : " " + e.Name.Trim();
                var pts = Math.Min(e.Expiring > 0 ? e.Expiring : e.Available, e.Available);
                var msg = $"Hello{name},\n\n*{pts:0} loyalty points* (₹{pts * (e.PointValue ?? 1):N2}) in your wallet expire on {e.ExpiresOn.ToString("dd-MMM-yyyy", CultureInfo.InvariantCulture)}. " +
                          $"Use them on your next purchase.\nWallet balance: {e.Available:0} points.\n\n- {e.PharmacyName ?? "Pharmacy"}";
                var res = await whatsApp.SendTextMessageAsync(e.Phone!, msg, e.BranchId, "PHR");
                if (!res.Success) logger.LogWarning("[PH-LOYALTY] Expiry reminder not sent to {Phone}: {Err}", e.Phone, res.ErrorMessage);
            }
            catch (Exception ex) { logger.LogWarning(ex, "[PH-LOYALTY] Expiry reminder failed"); }
        }
        return sent;
    }

    private sealed class ExpiryDue
    {
        public int BranchId { get; set; }
        public DateTime ExpiresOn { get; set; }
        public string? Phone { get; set; }
        public string? Name { get; set; }
        public decimal Available { get; set; }
        public decimal Expiring { get; set; }
        public string? PharmacyName { get; set; }
        public decimal? PointValue { get; set; }
    }

    private static string Compose(Due r)
    {
        var name = string.IsNullOrWhiteSpace(r.Name) ? "" : " " + r.Name.Trim();
        var phone = string.IsNullOrWhiteSpace(r.PharmacyPhone) ? "" : $"\nCall {r.PharmacyPhone} to keep it ready.";
        return $"Hello{name},\n\nYour medicine *{r.ItemName}* (bill {r.SaleNo}) is due to run out on {r.RunOutDate.ToString("dd-MMM-yyyy", CultureInfo.InvariantCulture)}. " +
               $"Please refill it in time - do not stop a medicine without asking your doctor.{phone}\n\n- {r.PharmacyName ?? "Pharmacy"}";
    }
}
