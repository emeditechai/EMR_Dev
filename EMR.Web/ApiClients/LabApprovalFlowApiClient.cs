using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabApprovalFlowApiClient(IHttpClientFactory httpClientFactory) : ILabApprovalFlowApiClient
{
    private const string Base = "api/lab-approval-flows";
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabApprovalFlowModel>> GetListAsync(int? companyId = null, int? branchScope = null, int? departmentId = null, int? categoryId = null, bool? status = null, string? search = null)
    {
        var q = new List<string>();
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");
        if (branchScope.HasValue) q.Add($"branchScope={branchScope.Value}");
        if (departmentId.HasValue) q.Add($"departmentId={departmentId.Value}");
        if (categoryId.HasValue) q.Add($"categoryId={categoryId.Value}");
        if (status.HasValue) q.Add($"status={status.Value.ToString().ToLowerInvariant()}");
        if (!string.IsNullOrWhiteSpace(search)) q.Add($"search={Uri.EscapeDataString(search.Trim())}");

        var response = await Client.GetAsync(q.Count > 0 ? $"{Base}?{string.Join("&", q)}" : Base);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<IEnumerable<LabApprovalFlowModel>>() ?? [];
    }

    public async Task<LabApprovalFlowDetailModel?> GetByIdAsync(int id)
    {
        var response = await Client.GetAsync($"{Base}/{id}");
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<LabApprovalFlowDetailModel>();
    }

    public async Task<int> CreateAsync(LabApprovalFlowCreateRequestModel request)
    {
        var response = await Client.PostAsJsonAsync(Base, request);
        await ThrowIfFailedAsync(response, "Failed to create the approval flow.");

        var result = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
        return result?.TryGetValue("id", out var idObj) == true && int.TryParse(idObj?.ToString(), out var id) ? id : 0;
    }

    public async Task UpdateAsync(LabApprovalFlowUpdateRequestModel request)
    {
        var response = await Client.PutAsJsonAsync($"{Base}/{request.Flow_ID}", request);
        await ThrowIfFailedAsync(response, "Failed to update the approval flow.");
    }

    public async Task ToggleStatusAsync(LabApprovalFlowToggleStatusRequestModel request)
    {
        var response = await Client.PatchAsJsonAsync($"{Base}/{request.Flow_ID}/toggle-status", request);
        await ThrowIfFailedAsync(response, "Failed to change the status.");
    }

    public async Task DeleteAsync(int id, int? userId = null)
    {
        var response = await Client.DeleteAsync(userId.HasValue ? $"{Base}/{id}?userId={userId.Value}" : $"{Base}/{id}");
        await ThrowIfFailedAsync(response, "Failed to delete the approval flow.");
    }

    public async Task<IEnumerable<LabApprovalEligibleApproverModel>> GetEligibleApproversAsync(int companyId, int? branchId = null, int? departmentId = null, IEnumerable<int>? categoryIds = null, bool includeIneligible = false)
    {
        var q = new List<string> { $"companyId={companyId}" };
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (departmentId.HasValue) q.Add($"departmentId={departmentId.Value}");
        var ids = (categoryIds ?? Enumerable.Empty<int>()).Where(c => c > 0).Distinct().ToList();
        if (ids.Count > 0) q.Add($"categoryIds={string.Join(",", ids)}");
        if (includeIneligible) q.Add("includeIneligible=true");

        var response = await Client.GetAsync($"{Base}/eligible-approvers?{string.Join("&", q)}");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<IEnumerable<LabApprovalEligibleApproverModel>>() ?? [];
    }

    /// <summary>Turns the API's {message} body into an exception the controller shows next to the form.</summary>
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

        // a 5xx means the service failed, not that the user's input was wrong
        if ((int)response.StatusCode >= 500)
            throw new HttpRequestException(string.IsNullOrWhiteSpace(message) ? fallback : message);

        throw new InvalidOperationException(string.IsNullOrWhiteSpace(message) ? fallback : message);
    }
}
