using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabTestMethodApiClient(IHttpClientFactory factory) : ILabTestMethodApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabTestMethodModel>> GetListAsync(int? departmentId = null, bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (departmentId.HasValue) query.Add($"departmentId={departmentId.Value}");
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabTestMethodModel>>>($"api/lab-test-methods{queryString}");
        return res?.Data ?? [];
    }

    public async Task<LabTestMethodModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabTestMethodModel>>($"api/lab-test-methods/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabTestMethodCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-test-methods", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Lab Test Method.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabTestMethodUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-test-methods/{req.Method_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Lab Test Method.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabTestMethodToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-test-methods/{req.Method_ID}/toggle-status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
        return true;
    }

    public async Task<bool> DeleteAsync(int id)
    {
        var res = await Client.DeleteAsync($"api/lab-test-methods/{id}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Lab Test Method.");
        }
        return true;
    }
}
