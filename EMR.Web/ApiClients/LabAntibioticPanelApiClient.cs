using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabAntibioticPanelApiClient(IHttpClientFactory factory) : ILabAntibioticPanelApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabAntibioticPanelModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null, int? sample_Type_ID = null)
    {
        var query = new List<string>();
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");
        if (sample_Type_ID.HasValue) query.Add($"sample_Type_ID={sample_Type_ID.Value}");
        var qs = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabAntibioticPanelModel>>>($"api/lab-antibiotic-panels{qs}");
        return res?.Data ?? [];
    }

    public async Task<LabAntibioticPanelModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabAntibioticPanelModel>>($"api/lab-antibiotic-panels/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabAntibioticPanelCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-antibiotic-panels", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Antibiotic Panel.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabAntibioticPanelUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-antibiotic-panels/{req.Panel_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Antibiotic Panel.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabAntibioticPanelToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-antibiotic-panels/{req.Panel_ID}/toggle-status", req);
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
        var res = await Client.DeleteAsync($"api/lab-antibiotic-panels/{id}{qs}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Antibiotic Panel.");
        }
        return true;
    }

    public async Task<IEnumerable<LabAntibioticPanelLookupModel>> LookupAntibioticsAsync(int? companyId)
    {
        var qs = companyId.HasValue ? $"?companyId={companyId.Value}" : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabAntibioticPanelLookupModel>>>($"api/lab-antibiotic-panels/lookup/antibiotics{qs}");
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<LabAntibioticPanelLookupModel>> LookupSampleTypesAsync(int? companyId)
    {
        var qs = companyId.HasValue ? $"?companyId={companyId.Value}" : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabAntibioticPanelLookupModel>>>($"api/lab-antibiotic-panels/lookup/sample-types{qs}");
        return res?.Data ?? [];
    }
}
