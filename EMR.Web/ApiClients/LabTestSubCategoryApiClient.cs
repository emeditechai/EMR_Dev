using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabTestSubCategoryApiClient(IHttpClientFactory factory) : ILabTestSubCategoryApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabTestSubCategoryModel>> GetListAsync(int? categoryId = null, bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (categoryId.HasValue) query.Add($"categoryId={categoryId.Value}");
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabTestSubCategoryModel>>>($"api/lab-test-sub-categories{queryString}");
        return res?.Data ?? [];
    }

    public async Task<LabTestSubCategoryModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabTestSubCategoryModel>>($"api/lab-test-sub-categories/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabTestSubCategoryCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-test-sub-categories", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Lab Test Sub Category.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabTestSubCategoryUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-test-sub-categories/{req.SubCategory_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Lab Test Sub Category.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabTestSubCategoryToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-test-sub-categories/{req.SubCategory_ID}/toggle-status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
        return true;
    }

    public async Task<bool> DeleteAsync(int id)
    {
        var res = await Client.DeleteAsync($"api/lab-test-sub-categories/{id}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Lab Test Sub Category.");
        }
        return true;
    }
}
