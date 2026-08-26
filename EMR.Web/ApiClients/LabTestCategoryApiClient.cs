using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabTestCategoryApiClient(IHttpClientFactory factory) : ILabTestCategoryApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabTestCategoryModel>> GetListAsync(int? departmentId = null, bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (departmentId.HasValue) query.Add($"departmentId={departmentId.Value}");
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabTestCategoryModel>>>($"api/lab-test-categories{queryString}");
        return res?.Data ?? [];
    }

    public async Task<LabTestCategoryModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabTestCategoryModel>>($"api/lab-test-categories/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabTestCategoryCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-test-categories", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Lab Test Category.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabTestCategoryUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-test-categories/{req.Category_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Lab Test Category.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabTestCategoryToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-test-categories/{req.Category_ID}/toggle-status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
        return true;
    }

    public async Task<bool> DeleteAsync(int id)
    {
        var res = await Client.DeleteAsync($"api/lab-test-categories/{id}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Lab Test Category.");
        }
        return true;
    }
}
