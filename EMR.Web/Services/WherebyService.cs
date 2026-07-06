using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using EMR.Web.Data;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class WherebyService(ApplicationDbContext dbContext, IHttpClientFactory httpClientFactory) : IWherebyService
{
    private static readonly TimeZoneInfo IstZone =
        TimeZoneInfo.FindSystemTimeZoneById(
            OperatingSystem.IsWindows() ? "India Standard Time" : "Asia/Kolkata");

    // ── Prefix Generation (BRD FR-02) ────────────────────────────────────────
    public string GenerateMeetingPrefix(int patientId, DateTime appointmentDate, TimeSpan slotTime)
    {
        var raw = $"P{patientId}{appointmentDate:yyyyMMdd}{(int)slotTime.TotalHours:D2}{slotTime.Minutes:D2}";
        return Regex.Replace(raw, "[^a-zA-Z0-9]", "");
    }

    // ── Create Meeting (BRD FR-04) ────────────────────────────────────────────
    public async Task<WherebyMeetingResult?> CreateMeetingAsync(
        int patientId, DateTime appointmentDate, TimeSpan slotStartTime,
        TimeSpan slotEndTime, int graceTimeMinutes)
    {
        try
        {
            // Retrieve config from DB
            var configs = await dbContext.VideoSystemConfigs
                .Where(c => c.IsActive)
                .ToDictionaryAsync(c => c.ConfigKey, c => c.ConfigValue);

            if (!configs.TryGetValue("WherebyApiKey", out var apiKey) || string.IsNullOrWhiteSpace(apiKey))
            {
                Console.WriteLine("[WHEREBY] WherebyApiKey not found in tbl_VideoSystemConfig.");
                return null;
            }

            if (!configs.TryGetValue("WherebyBaseUrl", out var baseUrl) || string.IsNullOrWhiteSpace(baseUrl))
                baseUrl = "https://api.whereby.dev/v1/meetings";

            if (!configs.TryGetValue("WherebyRoomMode", out var roomMode) || string.IsNullOrWhiteSpace(roomMode))
                roomMode = "normal";

            // Generate room name prefix (BRD FR-02)
            var prefix = GenerateMeetingPrefix(patientId, appointmentDate, slotStartTime);

            // Calculate endDate (BRD FR-03): date + slotEndTime + grace, converted to UTC
            var slotEndDateTime = appointmentDate.Date + slotEndTime + TimeSpan.FromMinutes(graceTimeMinutes);
            // Convert IST → UTC
            var endDateUtc = TimeZoneInfo.ConvertTimeToUtc(slotEndDateTime, IstZone);
            var endDateStr = endDateUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ");

            // Build request body (BRD FR-04)
            var requestBody = new
            {
                endDate        = endDateStr,
                isLocked       = true,
                roomMode       = roomMode,
                roomNamePrefix = prefix,
                fields         = new[] { "hostRoomUrl" }
            };

            var json    = JsonSerializer.Serialize(requestBody);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            var client = httpClientFactory.CreateClient("Whereby");
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);

            Console.WriteLine($"[WHEREBY] Calling POST {baseUrl}, prefix={prefix}, endDate={endDateStr}");

            var response = await client.PostAsync(baseUrl, content);
            var responseJson = await response.Content.ReadAsStringAsync();

            Console.WriteLine($"[WHEREBY] Response: {(int)response.StatusCode} {responseJson}");

            if (!response.IsSuccessStatusCode)
            {
                Console.WriteLine($"[WHEREBY] API call failed: {(int)response.StatusCode} {responseJson}");
                return null;
            }

            using var doc = JsonDocument.Parse(responseJson);
            var root = doc.RootElement;

            return new WherebyMeetingResult
            {
                MeetingId   = root.GetProperty("meetingId").GetString() ?? string.Empty,
                RoomUrl     = root.GetProperty("roomUrl").GetString() ?? string.Empty,
                HostRoomUrl = root.TryGetProperty("hostRoomUrl", out var hostProp)
                                ? (hostProp.GetString() ?? string.Empty)
                                : string.Empty,
                StartDate   = root.TryGetProperty("startDate", out var sdProp) && sdProp.GetString() is { } sd
                                ? DateTime.Parse(sd).ToUniversalTime()
                                : DateTime.UtcNow,
                EndDate     = endDateUtc
            };
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[WHEREBY] Exception in CreateMeetingAsync: {ex}");
            return null;
        }
    }
}
