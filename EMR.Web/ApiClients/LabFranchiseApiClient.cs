using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabFranchiseApiClient(IHttpClientFactory httpClientFactory, ILogger<LabFranchiseApiClient> logger) : ILabFranchiseApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabFranchiseModel>> GetListAsync(bool? status = null, bool? isActive = null, string? search = null, int? companyId = null, int? franchiseType = null, int? parentBranchId = null)
    {
        var queryParams = new List<string>();
        if (status.HasValue) queryParams.Add($"status={status.Value}");
        if (isActive.HasValue) queryParams.Add($"isActive={isActive.Value}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) queryParams.Add($"companyId={companyId.Value}");
        if (franchiseType.HasValue) queryParams.Add($"franchiseType={franchiseType.Value}");
        if (parentBranchId.HasValue) queryParams.Add($"parentBranchId={parentBranchId.Value}");

        var url = "api/LabFranchise";
        if (queryParams.Any()) url += "?" + string.Join("&", queryParams);

        var response = await Client.GetAsync(url);
        response.EnsureSuccessStatusCode();

        return await response.Content.ReadFromJsonAsync<IEnumerable<LabFranchiseModel>>() ?? [];
    }

    public async Task<LabFranchiseModel?> GetByIdAsync(int id)
    {
        var response = await Client.GetAsync($"api/LabFranchise/{id}");
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
            return null;

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<LabFranchiseModel>();
    }

    public async Task<int> CreateAsync(LabFranchiseCreateRequestModel request)
    {
        var response = await Client.PostAsJsonAsync("api/LabFranchise", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            var msg = err?.TryGetValue("message", out var m) == true ? m?.ToString() : "Failed to create Lab Franchise.";
            throw new InvalidOperationException(msg);
        }

        var result = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
        if (result?.TryGetValue("id", out var idObj) == true && int.TryParse(idObj?.ToString(), out var id))
        {
            return id;
        }

        return 0;
    }

    public async Task UpdateAsync(LabFranchiseUpdateRequestModel request)
    {
        var response = await Client.PutAsJsonAsync($"api/LabFranchise/{request.Franchise_ID}", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            var msg = err?.TryGetValue("message", out var m) == true ? m?.ToString() : "Failed to update Lab Franchise.";
            throw new InvalidOperationException(msg);
        }
    }

    public async Task ToggleStatusAsync(LabFranchiseToggleStatusRequestModel request)
    {
        var response = await Client.PatchAsJsonAsync($"api/LabFranchise/{request.Franchise_ID}/toggle-status", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            var msg = err?.TryGetValue("message", out var m) == true ? m?.ToString() : "Failed to update active status.";
            throw new InvalidOperationException(msg);
        }
    }

    public async Task ToggleSuspensionAsync(LabFranchiseToggleSuspensionRequestModel request)
    {
        var response = await Client.PatchAsJsonAsync($"api/LabFranchise/{request.Franchise_ID}/toggle-suspension", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            var msg = err?.TryGetValue("message", out var m) == true ? m?.ToString() : "Failed to update suspension status.";
            throw new InvalidOperationException(msg);
        }
    }

    public async Task DeleteAsync(int id, int? userId = null)
    {
        var url = $"api/LabFranchise/{id}";
        if (userId.HasValue) url += $"?userId={userId.Value}";

        var response = await Client.DeleteAsync(url);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            var msg = err?.TryGetValue("message", out var m) == true ? m?.ToString() : "Failed to delete Lab Franchise.";
            throw new InvalidOperationException(msg);
        }
    }
}
