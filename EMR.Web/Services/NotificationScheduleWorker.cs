using System.Data;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

/// <summary>
/// Settings > Notification Setup - scheduled sends of ALL areas (SQLScripts/2531): every minute, for every daily event
/// (dbo.AuditNotifyEvent.IsDaily - the doctor roster, the OPD / LAB due alerts, and any daily event added later) the branches
/// whose event is on and whose send time has passed today are claimed in the database (once per branch, event and day,
/// usp_AuditNotify_DailyDue) and sent. A run that sends nothing (nothing to send, or it failed) is written to the page's log.
/// </summary>
public sealed class NotificationScheduleWorker(IServiceScopeFactory scopeFactory, ILogger<NotificationScheduleWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(20), stoppingToken); } catch (OperationCanceledException) { return; }
        while (!stoppingToken.IsCancellationRequested)
        {
            try { await RunOnceAsync(stoppingToken); }
            catch (Exception ex) when (!stoppingToken.IsCancellationRequested) { logger.LogError(ex, "[NOTIFY-SCHEDULE] Run failed"); }
            // next check just after the start of the next minute - a send time of 16:36 goes at 16:36
            var now = DateTime.Now;
            var next = now.AddSeconds(-now.Second).AddMilliseconds(-now.Millisecond).AddMinutes(1).AddSeconds(2);
            try { await Task.Delay(next - now, stoppingToken); } catch (OperationCanceledException) { return; }
        }
    }

    private async Task RunOnceAsync(CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<IDbConnectionFactory>();
        using var con = db.CreateConnection();
        var events = (await con.QueryAsync<string>("dbo.usp_AuditNotify_DailyEvents", commandType: CommandType.StoredProcedure)).ToList();
        foreach (var eventCode in events)
        {
            var branches = (await con.QueryAsync<int>("dbo.usp_AuditNotify_DailyDue", new { EventCode = eventCode },
                commandType: CommandType.StoredProcedure)).ToList();
            foreach (var branchId in branches)
            {
                ct.ThrowIfCancellationRequested();
                int sent = 0, skipped = 0; string message; var status = "Skipped";
                try
                {
                    (sent, skipped, message) = await SendAsync(scope.ServiceProvider, eventCode, branchId);
                }
                catch (Exception ex) when (!ct.IsCancellationRequested)
                {
                    status = "Failed"; message = "The scheduled send failed: " + ex.Message;
                    logger.LogWarning(ex, "[NOTIFY-SCHEDULE] Branch {Branch} {Event} failed", branchId, eventCode);
                }
                logger.LogInformation("[NOTIFY-SCHEDULE] Branch {Branch} {Event}: {Sent} sent, {Skipped} not sent - {Message}", branchId, eventCode, sent, skipped, message);
                // nothing went out (nothing to send / off / failed): one log line, so the run shows on the page
                if (sent == 0 && skipped == 0)
                    await con.ExecuteAsync("dbo.usp_AuditNotify_LogRun",
                        new { BranchId = branchId, EventCode = eventCode, Status = status, Detail = message.Length > 500 ? message[..500] : message },
                        commandType: CommandType.StoredProcedure);
            }
        }
    }

    // the sender of each daily event; a new daily event is one line here
    private static Task<(int Sent, int Skipped, string Message)> SendAsync(IServiceProvider sp, string eventCode, int branchId) => eventCode switch
    {
        RosterNotifyEvents.DailyRoster => sp.GetRequiredService<IDoctorRosterNotificationService>().SendDailyRosterAsync(branchId, DateTime.Today, null),
        _ when DueNotifyEvents.Is(eventCode) => sp.GetRequiredService<IDueAlertNotificationService>().SendDueListAsync(branchId, eventCode, null),
        _ => Task.FromResult((0, 0, $"No scheduled sender for {eventCode} yet."))
    };
}
