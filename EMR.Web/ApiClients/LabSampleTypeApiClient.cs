using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabSampleTypeApiClient(IHttpClientFactory factory) : ILabSampleTypeApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabSampleTypeModel>> GetListAsync(string? containerType = null, bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (!string.IsNullOrWhiteSpace(containerType)) query.Add($"containerType={Uri.EscapeDataString(containerType)}");
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabSampleTypeModel>>>($"api/lab-sample-types{queryString}");
        return res?.Data ?? [];
    }

    public async Task<LabSampleTypeModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabSampleTypeModel>>($"api/lab-sample-types/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabSampleTypeCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-sample-types", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Lab Sample Type.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabSampleTypeUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-sample-types/{req.Sample_Type_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Lab Sample Type.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabSampleTypeToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-sample-types/{req.Sample_Type_ID}/toggle-status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
        return true;
    }

    public async Task<bool> DeleteAsync(int id)
    {
        var res = await Client.DeleteAsync($"api/lab-sample-types/{id}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Lab Sample Type.");
        }
        return true;
    }
}
