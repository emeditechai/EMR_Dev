using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabReportingConditionApiClient(IHttpClientFactory httpClientFactory) : ILabReportingConditionApiClient
{
    private const string Base = "api/lab-reporting-conditions";
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabReportingConditionModel>> GetListAsync(bool? status = null, int? branchScope = null, string? search = null, int? companyId = null)
    {
        var q = new List<string>();
        if (status.HasValue) q.Add($"status={status.Value.ToString().ToLowerInvariant()}");
        if (branchScope.HasValue) q.Add($"branchScope={branchScope.Value}");
        if (!string.IsNullOrWhiteSpace(search)) q.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var response = await Client.GetAsync(q.Count > 0 ? $"{Base}?{string.Join("&", q)}" : Base);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<IEnumerable<LabReportingConditionModel>>() ?? [];
    }

    public async Task<LabReportingConditionModel?> GetByIdAsync(int id)
    {
        var response = await Client.GetAsync($"{Base}/{id}");
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<LabReportingConditionModel>();
    }

    public async Task<int> CreateAsync(LabReportingConditionCreateRequestModel request)
    {
        var response = await Client.PostAsJsonAsync(Base, request);
        await ThrowIfFailedAsync(response, "Failed to create Condition of Reporting.");

        var result = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
        return result?.TryGetValue("id", out var idObj) == true && int.TryParse(idObj?.ToString(), out var id) ? id : 0;
    }

    public async Task UpdateAsync(LabReportingConditionUpdateRequestModel request)
    {
        var response = await Client.PutAsJsonAsync($"{Base}/{request.Condition_ID}", request);
        await ThrowIfFailedAsync(response, "Failed to update Condition of Reporting.");
    }

    public async Task ToggleStatusAsync(LabReportingConditionToggleStatusRequestModel request)
    {
        var response = await Client.PatchAsJsonAsync($"{Base}/{request.Condition_ID}/toggle-status", request);
        await ThrowIfFailedAsync(response, "Failed to toggle status.");
    }

    public async Task DeleteAsync(int id, int? userId = null)
    {
        var response = await Client.DeleteAsync(userId.HasValue ? $"{Base}/{id}?userId={userId.Value}" : $"{Base}/{id}");
        await ThrowIfFailedAsync(response, "Failed to delete Condition of Reporting.");
    }

    public async Task<LabReportConditionsForReportModel?> GetForReportAsync(int companyId, int? branchId)
    {
        var url = $"{Base}/for-report?companyId={companyId}" + (branchId.HasValue ? $"&branchId={branchId.Value}" : "");
        var response = await Client.GetAsync(url);
        if (!response.IsSuccessStatusCode) return null;

        return await response.Content.ReadFromJsonAsync<LabReportConditionsForReportModel>();
    }

    private static async Task ThrowIfFailedAsync(HttpResponseMessage response, string fallback)
    {
        if (response.IsSuccessStatusCode) return;

        string? message = null;
        try
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            if (err?.TryGetValue("message", out var m) == true) message = m?.ToString();
        }
        catch { /* non-JSON error body */ }

        throw new InvalidOperationException(string.IsNullOrWhiteSpace(message) ? fallback : message);
    }
}
