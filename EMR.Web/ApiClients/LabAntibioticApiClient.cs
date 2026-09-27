using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabAntibioticApiClient(IHttpClientFactory factory) : ILabAntibioticApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabAntibioticModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");
        var qs = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabAntibioticModel>>>($"api/lab-antibiotics{qs}");
        return res?.Data ?? [];
    }

    public async Task<LabAntibioticModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabAntibioticModel>>($"api/lab-antibiotics/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabAntibioticCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-antibiotics", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Antibiotic.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabAntibioticUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-antibiotics/{req.Antibiotic_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Antibiotic.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabAntibioticToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-antibiotics/{req.Antibiotic_ID}/toggle-status", req);
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
        var res = await Client.DeleteAsync($"api/lab-antibiotics/{id}{qs}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Antibiotic.");
        }
        return true;
    }
}
