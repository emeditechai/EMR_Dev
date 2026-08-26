using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabUnitApiClient(IHttpClientFactory factory) : ILabUnitApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabUnitModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabUnitModel>>>($"api/lab-units{queryString}");
        return res?.Data ?? [];
    }

    public async Task<LabUnitModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabUnitModel>>($"api/lab-units/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabUnitCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-units", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Unit.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabUnitUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-units/{req.Unit_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Unit.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabUnitToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-units/{req.Unit_ID}/toggle-status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
        return true;
    }

    public async Task<bool> DeleteAsync(int id)
    {
        var res = await Client.DeleteAsync($"api/lab-units/{id}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Unit.");
        }
        return true;
    }
}
