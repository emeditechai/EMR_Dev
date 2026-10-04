using System.Text.Json;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients;

public class LabCriticalApiClient(IHttpClientFactory httpClientFactory, ILogger<LabCriticalApiClient> logger) : ILabCriticalApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    private static string Query(int branchId, int labOrderId, IEnumerable<long>? sampleIds, string context, int userId, bool isSuperAdmin)
    {
        var q = $"branchId={branchId}&labOrderId={labOrderId}&context={Uri.EscapeDataString(context)}&userId={userId}&isSuperAdmin={(isSuperAdmin ? "true" : "false")}";
        if (sampleIds != null)
        {
            var ids = string.Join(",", sampleIds.Distinct());
            if (ids.Length > 0) q += "&sampleIds=" + Uri.EscapeDataString(ids);
        }
        return q;
    }

    private static async Task<string> ErrorOf(HttpResponseMessage response)
    {
        try
        {
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            if (doc.RootElement.TryGetProperty("message", out var m) && m.GetString() is { Length: > 0 } msg) return msg;
        }
        catch (JsonException) { }
        return $"The reporting service answered {(int)response.StatusCode}.";
    }

    public async Task<(string? Json, string? Error)> GetPendingRawAsync(int branchId, int labOrderId, IEnumerable<long>? sampleIds, string context,
        int userId, bool isSuperAdmin)
    {
        var response = await Client.GetAsync("api/lab-critical/pending?" + Query(branchId, labOrderId, sampleIds, context, userId, isSuperAdmin));
        return response.IsSuccessStatusCode ? (await response.Content.ReadAsStringAsync(), null) : (null, await ErrorOf(response));
    }

    public async Task<(List<LabCriticalRecordedDto>? Rows, string? Error)> RecordAsync(LabCriticalRecordRequestDto request)
    {
        var response = await Client.PostAsJsonAsync("api/lab-critical/record", request);
        return response.IsSuccessStatusCode
            ? (await response.Content.ReadFromJsonAsync<List<LabCriticalRecordedDto>>() ?? new(), null)
            : (null, await ErrorOf(response));
    }

    public async Task<string?> GetSignoffBlockAsync(int branchId, int labOrderId, IEnumerable<long> sampleIds, string context, int userId, bool isSuperAdmin)
    {
        var ids = sampleIds.Distinct().ToList();
        if (ids.Count == 0) return null;
        try
        {
            var response = await Client.GetAsync("api/lab-critical/signoff-check?" + Query(branchId, labOrderId, ids, context, userId, isSuperAdmin));
            if (!response.IsSuccessStatusCode) return "Could not verify the critical value communication: " + await ErrorOf(response);
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            return doc.RootElement.TryGetProperty("blocked", out var b) && b.ValueKind == JsonValueKind.True
                ? doc.RootElement.GetProperty("message").GetString()
                : null;
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or TaskCanceledException)
        {
            logger.LogWarning(ex, "[LAB-CRITICAL] Sign-off check failed for LabOrderId {LabOrderId}", labOrderId);
            return "Could not verify the critical value communication right now. Please try again.";
        }
    }
}
