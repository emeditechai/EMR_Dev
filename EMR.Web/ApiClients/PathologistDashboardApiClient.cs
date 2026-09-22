using System.Text.Json;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients;

public class PathologistDashboardApiClient(IHttpClientFactory httpClientFactory) : IPathologistDashboardApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<PathologistAccessResult> GetAccessAsync(int userId, int branchId)
    {
        var response = await Client.GetAsync($"api/pathologist-dashboard/access?userId={userId}&branchId={branchId}");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<PathologistAccessResult>() ?? new PathologistAccessResult();
    }

    public async Task<PathologistDashboardListResult> GetHeadersAsync(int userId, int branchId, DateTime? fromDate, DateTime? toDate,
        string dateBasis, string? search, int? departmentId, int? categoryId, string statusFilter)
    {
        var q = new List<string>
        {
            $"userId={userId}",
            $"branchId={branchId}",
            $"dateBasis={Uri.EscapeDataString(dateBasis)}",
            $"statusFilter={Uri.EscapeDataString(statusFilter)}"
        };
        if (fromDate.HasValue) q.Add($"fromDate={Uri.EscapeDataString(fromDate.Value.ToString("yyyy-MM-ddTHH:mm:ss"))}");
        if (toDate.HasValue) q.Add($"toDate={Uri.EscapeDataString(toDate.Value.ToString("yyyy-MM-ddTHH:mm:ss"))}");
        if (!string.IsNullOrWhiteSpace(search)) q.Add($"search={Uri.EscapeDataString(search.Trim())}");
        if (departmentId is > 0) q.Add($"departmentId={departmentId}");
        if (categoryId is > 0) q.Add($"categoryId={categoryId}");

        var response = await Client.GetAsync($"api/pathologist-dashboard/headers?{string.Join("&", q)}");
        if (response.StatusCode == System.Net.HttpStatusCode.Forbidden) return new PathologistDashboardListResult();
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<PathologistDashboardListResult>() ?? new PathologistDashboardListResult();
    }

    public async Task<PathologistDetailResult?> GetDetailAsync(int labOrderId, int userId, int branchId)
    {
        var response = await Client.GetAsync($"api/pathologist-dashboard/detail/{labOrderId}?userId={userId}&branchId={branchId}");
        if (response.StatusCode is System.Net.HttpStatusCode.NotFound or System.Net.HttpStatusCode.Forbidden) return null;
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<PathologistDetailResult>();
    }

    public async Task<(PathologistApproveResult? Result, string? Error)> ApproveAsync(PathologistApproveRequest request)
    {
        var response = await Client.PostAsJsonAsync("api/pathologist-dashboard/approve", request);
        if (response.IsSuccessStatusCode)
            return (await response.Content.ReadFromJsonAsync<PathologistApproveResult>(), null);

        if ((int)response.StatusCode is 400 or 403)
        {
            try
            {
                using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                if (doc.RootElement.TryGetProperty("message", out var m)) return (null, m.GetString());
            }
            catch (JsonException) { }
            return (null, "The approval was refused.");
        }

        response.EnsureSuccessStatusCode();
        return (null, "Unexpected response.");
    }
}
