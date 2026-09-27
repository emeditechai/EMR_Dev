using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabOrganismApiClient(IHttpClientFactory factory) : ILabOrganismApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabOrganismModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");
        var qs = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabOrganismModel>>>($"api/lab-organisms{qs}");
        return res?.Data ?? [];
    }

    public async Task<LabOrganismModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabOrganismModel>>($"api/lab-organisms/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabOrganismCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-organisms", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Organism.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabOrganismUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-organisms/{req.Organism_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Organism.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabOrganismToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-organisms/{req.Organism_ID}/toggle-status", req);
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
        var res = await Client.DeleteAsync($"api/lab-organisms/{id}{qs}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Organism.");
        }
        return true;
    }
}
