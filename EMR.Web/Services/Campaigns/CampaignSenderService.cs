using System.Net;
using System.Text.Json;
using Microsoft.AspNetCore.DataProtection;

namespace EMR.Web.Services.Campaigns;

/// <summary>Turns a campaign and one recipient into the email that is sent (and the preview / test email).</summary>
public static class CampaignMail
{
    public const string OptOutPurpose = "Campaign.OptOut.v1";

    /// <summary>Subject and full HTML (common layout, hospital in the header; patients get an unsubscribe line).</summary>
    public static (string Subject, string Html) Render(string subject, string htmlBody, IReadOnlyDictionary<string, string?> values,
                                                       string hospital, string? unsubscribeUrl)
    {
        var htmlValues = values.ToDictionary(v => v.Key, v => (string?)WebUtility.HtmlEncode(v.Value ?? ""));
        var body = EmailTemplateDesigner.Fill(htmlBody, htmlValues);
        var footer = unsubscribeUrl is null ? null
            : $"You are receiving this because you are a patient of {WebUtility.HtmlEncode(hospital)}. "
              + $"<a href=\"{WebUtility.HtmlEncode(unsubscribeUrl)}\" style=\"color:#644098;\">Unsubscribe</a> from these emails.";
        return (EmailTemplateDesigner.Fill(subject, values).Trim(), EmailLayout.Wrap(body, organisation: hospital, footerHtml: footer));
    }

    public static string? UnsubscribeUrl(IDataProtectionProvider dp, string? baseUrl, int companyId, int campaignId, string email)
    {
        if (string.IsNullOrWhiteSpace(baseUrl)) return null;
        var token = dp.CreateProtector(OptOutPurpose).Protect($"{companyId}|{campaignId}|{email.Trim().ToLowerInvariant()}");
        return $"{baseUrl.TrimEnd('/')}/Campaign/Unsubscribe/{Uri.EscapeDataString(token)}";
    }
}

/// <summary>
/// Utility > Campaigns sender (SQLScripts/2299): starts scheduled campaigns when their time comes and sends the
/// pending recipients of running campaigns a few at a time, with a short pause between emails so the mail server is
/// not flooded. Every email goes out with the mail settings (SMTP) of the campaign's "send from" branch. All data goes
/// through EMR.Api (api/campaigns/sender/*, service token). Each recipient ends Sent, Failed (with the reason) or
/// Skipped. Settings: Campaigns:Enabled, Campaigns:BatchSize (default 25), Campaigns:PauseMs (default 400).
/// </summary>
public sealed class CampaignSenderService(IServiceProvider services, ILogger<CampaignSenderService> logger, IConfiguration config) : BackgroundService
{
    private static readonly SemaphoreSlim Gate = new(1, 1);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!config.GetValue("Campaigns:Enabled", true)) { logger.LogInformation("Campaign sender is disabled in appsettings."); return; }
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(20));
        do
        {
            try { await RunOnceAsync(stoppingToken); }
            catch (Exception ex) when (ex is not OperationCanceledException) { logger.LogWarning(ex, "Campaign sender: run failed."); }
        }
        while (await Next(timer, stoppingToken));
    }

    private static async Task<bool> Next(PeriodicTimer t, CancellationToken token)
    {
        try { return await t.WaitForNextTickAsync(token); } catch (OperationCanceledException) { return false; }
    }

    public async Task RunOnceAsync(CancellationToken token)
    {
        if (!await Gate.WaitAsync(0, token)) return;
        try
        {
            using var scope = services.CreateScope();
            var api = scope.ServiceProvider.GetRequiredService<EMR.Web.ApiClients.ICampaignApiClient>();
            var email = scope.ServiceProvider.GetRequiredService<IEmailService>();
            var dp = scope.ServiceProvider.GetRequiredService<IDataProtectionProvider>();
            var batch = Math.Clamp(config.GetValue("Campaigns:BatchSize", 25), 1, 500);
            var pause = Math.Clamp(config.GetValue("Campaigns:PauseMs", 400), 0, 10_000);

            foreach (var c in await api.SenderRunningAsync())
            {
                token.ThrowIfCancellationRequested();
                var stillSending = true;
                foreach (var r in await api.SenderNextAsync(c.CampaignId, batch))
                {
                    token.ThrowIfCancellationRequested();
                    var values = Fields(r.FieldsJson);
                    values["HospitalName"] = c.HospitalName;
                    var unsubscribe = c.AudienceType == "P" ? CampaignMail.UnsubscribeUrl(dp, c.BaseUrl, c.CompanyId, c.CampaignId, r.Email ?? "") : null;
                    var (subject, html) = CampaignMail.Render(c.Subject, c.HtmlBody, values, c.HospitalName, unsubscribe);
                    (bool ok, string msg) result;
                    // the branch's own mail settings send the email
                    try { result = await email.SendEmailAsync(c.BranchId, r.Email!.Trim(), subject, html); }
                    catch (Exception ex) { result = (false, ex.Message); }

                    stillSending = await api.SenderMarkAsync(r.RecipientId, result.ok, result.ok ? null : result.msg);
                    if (!stillSending) break;   // cancelled meanwhile
                    if (pause > 0) await Task.Delay(pause, token);
                }
                if (stillSending) await api.SenderFinishAsync(c.CampaignId);   // completes it when nothing is left
            }
        }
        finally { Gate.Release(); }
    }

    private static Dictionary<string, string?> Fields(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return [];
        try { return JsonSerializer.Deserialize<Dictionary<string, string?>>(json) ?? []; } catch (JsonException) { return []; }
    }
}
