using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabInvestigationApiClient(IHttpClientFactory factory) : ILabInvestigationApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabInvestigationModel>> GetListAsync(int? branchId = null, int? departmentId = null, int? categoryId = null, bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (branchId.HasValue) query.Add($"branchId={branchId.Value}");
        if (departmentId.HasValue) query.Add($"departmentId={departmentId.Value}");
        if (categoryId.HasValue) query.Add($"categoryId={categoryId.Value}");
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabInvestigationModel>>>($"api/lab-investigations{queryString}");
        return res?.Data ?? [];
    }

    public async Task<LabInvestigationModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabInvestigationModel>>($"api/lab-investigations/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabInvestigationCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-investigations", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Lab Investigation.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task UpdateAsync(int id, LabInvestigationUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-investigations/{id}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Lab Investigation.");
        }
    }

    public async Task ToggleStatusAsync(LabInvestigationToggleStatusRequestModel req)
    {
        var res = await Client.PatchAsJsonAsync($"api/lab-investigations/{req.Test_ID}/status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
    }

    public async Task DeleteAsync(int id)
    {
        var res = await Client.DeleteAsync($"api/lab-investigations/{id}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Lab Investigation.");
        }
    }
}
