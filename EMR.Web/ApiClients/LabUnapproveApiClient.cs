using System.Text.Json;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients;

public class LabUnapproveApiClient(IHttpClientFactory httpClientFactory) : ILabUnapproveApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<LabUnapproveListResult> GetHeadersAsync(int branchId, DateTime? fromDate, DateTime? toDate, string dateBasis, string? search, string approvalType)
    {
        var q = new List<string>
        {
            $"branchId={branchId}",
            $"dateBasis={Uri.EscapeDataString(dateBasis)}",
            $"approvalType={Uri.EscapeDataString(approvalType)}"
        };
        if (fromDate.HasValue) q.Add($"fromDate={Uri.EscapeDataString(fromDate.Value.ToString("yyyy-MM-ddTHH:mm:ss"))}");
        if (toDate.HasValue) q.Add($"toDate={Uri.EscapeDataString(toDate.Value.ToString("yyyy-MM-ddTHH:mm:ss"))}");
        if (!string.IsNullOrWhiteSpace(search)) q.Add($"search={Uri.EscapeDataString(search.Trim())}");

        var response = await Client.GetAsync($"api/lab-unapprove/headers?{string.Join("&", q)}");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<LabUnapproveListResult>() ?? new LabUnapproveListResult();
    }

    public async Task<LabUnapproveDetailResult?> GetDetailAsync(int labOrderId)
    {
        var response = await Client.GetAsync($"api/lab-unapprove/detail/{labOrderId}");
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<LabUnapproveDetailResult>();
    }

    public async Task<(int Count, string? Error)> UnapproveAsync(LabUnapproveRequest request)
    {
        var response = await Client.PostAsJsonAsync("api/lab-unapprove/unapprove", request);
        if (response.IsSuccessStatusCode)
        {
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            return (doc.RootElement.TryGetProperty("count", out var c) ? c.GetInt32() : 0, null);
        }

        if ((int)response.StatusCode == 400)
        {
            try
            {
                using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                if (doc.RootElement.TryGetProperty("message", out var m)) return (0, m.GetString());
            }
            catch (JsonException) { }
            return (0, "The request was rejected.");
        }

        response.EnsureSuccessStatusCode();
        return (0, "Unexpected response.");
    }
}
