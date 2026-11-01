using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;

namespace EMR.Api.Services;

public enum WhatsAppSendResult { Sent, NotConfigured, Failed }

public interface IWhatsAppTextSender
{
    /// <summary>Sends a text with the branch's WhatsApp configuration, or the company's default one.</summary>
    Task<WhatsAppSendResult> SendAsync(int branchId, string? phoneNumber, string text);
}

public sealed class WhatsAppTextSender(
    IDbConnectionFactory db,
    IHttpClientFactory httpClientFactory,
    ILogger<WhatsAppTextSender> logger) : IWhatsAppTextSender
{
    public async Task<WhatsAppSendResult> SendAsync(int branchId, string? phoneNumber, string text)
    {
        using var con = db.CreateConnection();
        var config = await con.QueryFirstOrDefaultAsync<WhatsAppConfig>(
            @"SELECT TOP 1 w.ApiUrl, w.AuthHeaderKey, w.ApiKey, w.DefaultCountryCode
                FROM dbo.WhatsAppConfiguration w JOIN dbo.Branchmaster b ON b.BranchID = @branchId
               WHERE w.IsActive = 1 AND w.IsEnabled = 1 AND (w.BranchId = @branchId OR (w.IsDefault = 1 AND w.CompanyId = b.CompanyId))
               ORDER BY CASE WHEN w.BranchId = @branchId THEN 0 ELSE 1 END, w.BranchId", new { branchId });
        if (config is null || string.IsNullOrWhiteSpace(config.ApiKey)) return WhatsAppSendResult.NotConfigured;

        var digits = new string((phoneNumber ?? "").Where(char.IsDigit).ToArray());
        var country = new string((config.DefaultCountryCode ?? "91").Where(char.IsDigit).ToArray());
        if (digits.Length == 10) digits = country + digits;

        var token = config.ApiKey.Trim();
        if (token.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) token = token[7..].Trim();
        var headerKey = string.IsNullOrWhiteSpace(config.AuthHeaderKey) ? "Authorization" : config.AuthHeaderKey.Trim();
        var message = new HttpRequestMessage(HttpMethod.Post, config.ApiUrl)
        {
            Content = new StringContent(JsonSerializer.Serialize(new { to = digits, text }), Encoding.UTF8, "application/json")
        };
        if (headerKey.Equals("Authorization", StringComparison.OrdinalIgnoreCase)) message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        else message.Headers.TryAddWithoutValidation(headerKey, "Bearer " + token);

        try
        {
            var client = httpClientFactory.CreateClient();
            client.Timeout = TimeSpan.FromSeconds(25);
            var response = await client.SendAsync(message);
            if (response.IsSuccessStatusCode) return WhatsAppSendResult.Sent;
            logger.LogWarning("[WHATSAPP] Answered {Status} for branch {BranchId}", (int)response.StatusCode, branchId);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            logger.LogWarning(ex, "[WHATSAPP] Not sent for branch {BranchId}", branchId);
        }
        return WhatsAppSendResult.Failed;
    }

    private sealed class WhatsAppConfig
    {
        public string ApiUrl { get; set; } = "";
        public string? AuthHeaderKey { get; set; }
        public string ApiKey { get; set; } = "";
        public string? DefaultCountryCode { get; set; }
    }
}
