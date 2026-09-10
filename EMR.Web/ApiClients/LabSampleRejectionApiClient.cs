using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabSampleRejectionApiClient(IHttpClientFactory factory) : ILabSampleRejectionApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabSampleRejectionModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabSampleRejectionModel>>>($"api/lab-sample-rejections{queryString}");
        return res?.Data ?? [];
    }

    public async Task<LabSampleRejectionModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabSampleRejectionModel>>($"api/lab-sample-rejections/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabSampleRejectionCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-sample-rejections", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Sample Rejection.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabSampleRejectionUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-sample-rejections/{req.Rejection_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Sample Rejection.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabSampleRejectionToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-sample-rejections/{req.Rejection_ID}/toggle-status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
        return true;
    }

    public async Task<bool> DeleteAsync(int id)
    {
        var res = await Client.DeleteAsync($"api/lab-sample-rejections/{id}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Sample Rejection.");
        }
        return true;
    }
}
