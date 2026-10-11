using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

/// <summary>
/// Membership points expiry (SQLScripts/2236): points not used by their expiry date (the plan's Points Expiry Days
/// after they were earned) are taken out of the card - an EXPIRE row in the card ledger, the card and primary
/// patient's running totals and the accounting entry. Runs every 6 hours; the procedure only touches points that are
/// past their date, so running it again does nothing.
/// </summary>
public sealed class MembershipPointsExpiryService(IServiceScopeFactory scopeFactory, ILogger<MembershipPointsExpiryService> logger) : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromHours(6);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try { await Task.Delay(TimeSpan.FromMinutes(3), stoppingToken); } catch (OperationCanceledException) { return; }
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                using var con = scope.ServiceProvider.GetRequiredService<IDbConnectionFactory>().CreateConnection();
                var cards = await con.ExecuteScalarAsync<int>("dbo.usp_Membership_ExpirePoints", new { UserId = 1 },
                    commandType: System.Data.CommandType.StoredProcedure, commandTimeout: 120);
                if (cards > 0) logger.LogInformation("[Membership] points expired on {Cards} card(s)", cards);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "[Membership] points expiry run failed");
            }
            try { await Task.Delay(Interval, stoppingToken); } catch (OperationCanceledException) { return; }
        }
    }
}
