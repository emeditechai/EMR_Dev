namespace EMR.Api.Services;

/// <summary>
/// Ask AI daily learning (SQLScripts/2321): once a day (02:00 server time, and two minutes after each start
/// of the API) answers chosen by several different users are promoted to learned answers, and the ML.NET
/// models are retrained with them on the next question.
/// </summary>
public sealed class HelpLearningWorker(IServiceScopeFactory scopes, ILogger<HelpLearningWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try { await Task.Delay(TimeSpan.FromMinutes(2), stoppingToken); } catch (OperationCanceledException) { return; }
        await RunAsync();
        while (!stoppingToken.IsCancellationRequested)
        {
            var next = DateTime.Today.AddDays(1).AddHours(2);
            try { await Task.Delay(next - DateTime.Now, stoppingToken); } catch (OperationCanceledException) { return; }
            await RunAsync();
        }
    }

    private async Task RunAsync()
    {
        try
        {
            using var scope = scopes.CreateScope();
            var (promoted, demoted) = await scope.ServiceProvider.GetRequiredService<IHelpService>().LearnNightlyAsync();
            logger.LogInformation("Ask AI daily learning: {Promoted} answer(s) learned, {Demoted} withdrawn.", promoted, demoted);
        }
        catch (Exception ex) { logger.LogWarning(ex, "Ask AI daily learning failed (is SQLScripts/2321 applied?)."); }
    }
}
