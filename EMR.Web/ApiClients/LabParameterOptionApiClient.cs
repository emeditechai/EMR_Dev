using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabParameterOptionApiClient(IHttpClientFactory factory) : ILabParameterOptionApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabParameterOptionModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null, int? test_ID = null)
    {
        var query = new List<string>();
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");
        if (test_ID.HasValue) query.Add($"test_ID={test_ID.Value}");
        var qs = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabParameterOptionModel>>>($"api/lab-parameter-options{qs}");
        return res?.Data ?? [];
    }

    public async Task<LabParameterOptionModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabParameterOptionModel>>($"api/lab-parameter-options/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabParameterOptionCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-parameter-options", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Parameter Option.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabParameterOptionUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-parameter-options/{req.Option_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Parameter Option.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabParameterOptionToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-parameter-options/{req.Option_ID}/toggle-status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
        return true;
    }

    public async Task<bool> DeleteAsync(int id, int? userId = null)
    {
        var qs = userId.HasValue ? $"?userId={userId.Value}" : "";
        var res = await Client.DeleteAsync($"api/lab-parameter-options/{id}{qs}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Parameter Option.");
        }
        return true;
    }

    public async Task<IEnumerable<LabParameterOptionLookupModel>> LookupTestsAsync(int? companyId)
    {
        var qs = companyId.HasValue ? $"?companyId={companyId.Value}" : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabParameterOptionLookupModel>>>($"api/lab-parameter-options/lookup/tests{qs}");
        return res?.Data ?? [];
    }
}
