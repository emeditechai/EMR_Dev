using EMR.Api.Models;

namespace EMR.Api.Services;

/// <summary>
/// Scheduled Doctor IP commission. Every few minutes it asks which branches are due: Hospital Settings mode
/// Automatic / Both, the branch's run time reached, and not yet run today (Doctor_IP_Commission_RunLog).
/// Times are the server's local time.
/// </summary>
public class DoctorIpCommissionBackgroundService(
    IServiceProvider serviceProvider,
    ILogger<DoctorIpCommissionBackgroundService> logger,
    IConfiguration configuration) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!configuration.GetValue("DoctorIpCommission:Enabled", true))
        {
            logger.LogInformation("Doctor IP Commission scheduler is disabled in appsettings.");
            return;
        }

        var poll = TimeSpan.FromMinutes(Math.Clamp(configuration.GetValue("DoctorIpCommission:PollMinutes", 5), 1, 60));
        logger.LogInformation("Doctor IP Commission scheduler started; checking every {Minutes} minute(s).", poll.TotalMinutes);

        using var timer = new PeriodicTimer(poll);
        do
        {
            try
            {
                await RunDueBranchesAsync();
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Doctor IP Commission scheduler: check failed.");
            }
        }
        while (await WaitAsync(timer, stoppingToken));
    }

    private static async Task<bool> WaitAsync(PeriodicTimer timer, CancellationToken token)
    {
        try { return await timer.WaitForNextTickAsync(token); }
        catch (OperationCanceledException) { return false; }
    }

    private async Task RunDueBranchesAsync()
    {
        using var scope = serviceProvider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<IDoctorIpCommissionService>();
        var now = DateTime.Now;

        foreach (var branch in await service.GetDueBranchesAsync(now))
        {
            var runId = await service.StartRunAsync(branch.Branch_ID, now);
            if (runId == null) continue;   // another instance took today's run

            int items = 0, failed = 0;
            decimal commission = 0;
            string? message = null;
            var schedules = new List<DoctorIpCommissionDueSchedule>();
            try
            {
                schedules = (await service.GetDueSchedulesAsync(now, branch.Branch_ID)).ToList();
                foreach (var s in schedules)
                {
                    try
                    {
                        var results = (await service.CalculateAsync(new DoctorIpCommissionCalculateRequest
                        {
                            BranchId = s.Branch_ID,
                            DoctorId = s.Doctor_ID,
                            FromDate = s.Period_From,
                            ToDate = s.Period_To,
                            CompanyId = s.CompanyId,
                            UserId = null,
                            Source = "AUTO"
                        })).ToList();
                        items += results.Sum(r => r.Items_Computed);
                        commission += results.Sum(r => r.Total_Commission);
                    }
                    catch (Exception ex)
                    {
                        failed++;
                        message = ex.Message;
                        logger.LogError(ex, "Doctor IP Commission: branch {BranchId}, doctor {DoctorId} ({Frequency}) failed.",
                            s.Branch_ID, s.Doctor_ID, s.Frequency_Of_Disbursal);
                    }
                }
            }
            catch (Exception ex)
            {
                failed++;
                message = ex.Message;
                logger.LogError(ex, "Doctor IP Commission: branch {BranchId} failed.", branch.Branch_ID);
            }

            await service.FinishRunAsync(runId.Value, schedules.Count, items, commission, failed,
                message is { Length: > 500 } ? message[..500] : message);
            logger.LogInformation("Doctor IP Commission: branch {BranchId} scheduled run done - {Schedules} doctor period(s) due, {Items} item(s), commission {Commission:N2}, {Failed} failure(s).",
                branch.Branch_ID, schedules.Count, items, commission, failed);
        }
    }
}
