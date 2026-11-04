using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;

namespace EMR.Api.Services;

public enum WhatsAppSendResult { Sent, NotConfigured, InvalidNumber, NotOnWhatsApp, Busy, Failed }

public interface IWhatsAppTextSender
{
    /// <summary>
    /// Sends a text with the branch's WhatsApp configuration, or the company's default one, and records it in
    /// dbo.WhatsAppLog under <paramref name="moduleCode"/>. <paramref name="logText"/> is what the log keeps, so a code
    /// in the message can be left out of it.
    /// </summary>
    Task<WhatsAppSendResult> SendAsync(int branchId, string? phoneNumber, string text, string moduleCode, int? moduleRefId = null, string? logText = null);
}

public sealed class WhatsAppTextSender(
    IDbConnectionFactory db,
    IHttpClientFactory httpClientFactory,
    ILogger<WhatsAppTextSender> logger) : IWhatsAppTextSender
{
    public async Task<WhatsAppSendResult> SendAsync(int branchId, string? phoneNumber, string text, string moduleCode, int? moduleRefId = null, string? logText = null)
    {
        using var con = db.CreateConnection();
        var config = await con.QueryFirstOrDefaultAsync<WhatsAppConfig>(
            @"SELECT TOP 1 w.Id, w.ApiUrl, w.AuthHeaderKey, w.ApiKey, w.DefaultCountryCode
                FROM dbo.WhatsAppConfiguration w JOIN dbo.Branchmaster b ON b.BranchID = @branchId
               WHERE w.IsActive = 1 AND w.IsEnabled = 1 AND (w.BranchId = @branchId OR (w.IsDefault = 1 AND w.CompanyId = b.CompanyId))
               ORDER BY CASE WHEN w.BranchId = @branchId THEN 0 ELSE 1 END, w.BranchId", new { branchId });
        if (config is null || string.IsNullOrWhiteSpace(config.ApiKey)) return WhatsAppSendResult.NotConfigured;

        var to = Normalize(phoneNumber, config.DefaultCountryCode);
        var log = new LogRow(config.Id, branchId, moduleCode, moduleRefId, to ?? (phoneNumber ?? ""), logText ?? text);
        if (to is null)
        {
            await WriteLogAsync(con, log with { Error = "The mobile number is not a valid number." });
            return WhatsAppSendResult.InvalidNumber;
        }

        var (result, body, error, status) = await PostAsync(config, to, text, branchId);
        if (result == WhatsAppSendResult.Busy)
        {
            // the account allows one message every few seconds: wait for it once, then try again
            var wait = RetryAfterSeconds(body);
            await Task.Delay(TimeSpan.FromSeconds(wait + 1));
            (result, body, error, status) = await PostAsync(config, to, text, branchId);
        }

        await WriteLogAsync(con, log with { Success = result == WhatsAppSendResult.Sent, Body = body, Error = error, Status = status,
            MsgId = Field(body, "msgId"), Jid = Field(body, "jid") });
        return result;
    }

    private async Task<(WhatsAppSendResult Result, string? Body, string? Error, string? Status)> PostAsync(WhatsAppConfig config, string to, string text, int branchId)
    {
        var token = config.ApiKey.Trim();
        if (token.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) token = token[7..].Trim();
        var headerKey = string.IsNullOrWhiteSpace(config.AuthHeaderKey) ? "Authorization" : config.AuthHeaderKey.Trim();
        var message = new HttpRequestMessage(HttpMethod.Post, config.ApiUrl)
        {
            Content = new StringContent(JsonSerializer.Serialize(new { to, text }), Encoding.UTF8, "application/json")
        };
        if (headerKey.Equals("Authorization", StringComparison.OrdinalIgnoreCase)) message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        else message.Headers.TryAddWithoutValidation(headerKey, "Bearer " + token);

        try
        {
            var client = httpClientFactory.CreateClient();
            client.Timeout = TimeSpan.FromSeconds(25);
            var response = await client.SendAsync(message);
            var body = await response.Content.ReadAsStringAsync();
            if (response.IsSuccessStatusCode) return (WhatsAppSendResult.Sent, body, null, Field(body, "status"));

            var error = Field(body, "message") ?? $"WhatsApp answered {(int)response.StatusCode}";
            logger.LogWarning("[WHATSAPP] Not sent for branch {BranchId}: {Status} {Error}", branchId, (int)response.StatusCode, error);
            var result = error.Contains("does not exist on WhatsApp", StringComparison.OrdinalIgnoreCase) ? WhatsAppSendResult.NotOnWhatsApp
                       : (int)response.StatusCode == 429 || error.Contains("only send 1 message", StringComparison.OrdinalIgnoreCase) ? WhatsAppSendResult.Busy
                       : WhatsAppSendResult.Failed;
            return (result, body, error, "failed");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            logger.LogWarning(ex, "[WHATSAPP] Not sent for branch {BranchId}", branchId);
            return (WhatsAppSendResult.Failed, null, ex.Message, "failed");
        }
    }

    /// <summary>Digits with the country code; null when it cannot be a mobile number (a 10-digit number, with or without 0 or the code).</summary>
    internal static string? Normalize(string? phoneNumber, string? defaultCountryCode)
    {
        var digits = new string((phoneNumber ?? "").Where(char.IsDigit).ToArray());
        var country = new string((defaultCountryCode ?? "91").Where(char.IsDigit).ToArray());
        if (country.Length == 0) country = "91";
        if (digits.StartsWith("00")) digits = digits[2..];
        if (digits.Length == 11 && digits[0] == '0') digits = digits[1..];
        if (digits.Length == 10) digits = country + digits;
        return digits.Length == country.Length + 10 && digits.StartsWith(country) && digits[country.Length] != '0' ? digits : null;
    }

    private static int RetryAfterSeconds(string? body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body ?? "");
            if (doc.RootElement.TryGetProperty("retry_after", out var r) && r.TryGetInt32(out var s)) return Math.Clamp(s, 1, 10);
        }
        catch (JsonException) { }
        return 5;
    }

    private static string? Field(string? body, string name)
    {
        try
        {
            using var doc = JsonDocument.Parse(body ?? "");
            var root = doc.RootElement;
            if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object && data.TryGetProperty(name, out var d)) return d.ToString();
            return root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var v) ? v.ToString() : null;
        }
        catch (JsonException) { return null; }
    }

    private async Task WriteLogAsync(System.Data.IDbConnection con, LogRow r)
    {
        try
        {
            await con.ExecuteAsync(
                @"INSERT dbo.WhatsAppLog (ConfigId, BranchId, ModuleCode, ModuleRefId, RecipientPhone, MessageText, IsSuccess, MsgId, Jid, Status, ApiResponse, ErrorMessage)
                  VALUES (@ConfigId, @BranchId, @ModuleCode, @ModuleRefId, LEFT(@Phone, 50), @Text, @Success, LEFT(@MsgId, 100), LEFT(@Jid, 100), LEFT(@Status, 50), @Body, LEFT(@Error, 1000))",
                r);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[WHATSAPP] Log not written for {Module}", r.ModuleCode);
        }
    }

    private sealed record LogRow(int ConfigId, int BranchId, string ModuleCode, int? ModuleRefId, string Phone, string Text,
        bool Success = false, string? MsgId = null, string? Jid = null, string? Status = null, string? Body = null, string? Error = null);

    private sealed class WhatsAppConfig
    {
        public int Id { get; set; }
        public string ApiUrl { get; set; } = "";
        public string? AuthHeaderKey { get; set; }
        public string ApiKey { get; set; } = "";
        public string? DefaultCountryCode { get; set; }
    }
}
