using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabInvestigationProfileApiClient(IHttpClientFactory factory) : ILabInvestigationProfileApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabInvestigationProfileHeaderModel>> GetListAsync(string? profileType = null, bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (!string.IsNullOrWhiteSpace(profileType)) query.Add($"profileType={Uri.EscapeDataString(profileType)}");
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabInvestigationProfileHeaderModel>>>($"api/lab-investigation-profiles{queryString}");
        return res?.Data ?? [];
    }

    public async Task<LabInvestigationProfileFullDetailModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabInvestigationProfileFullDetailModel>>($"api/lab-investigation-profiles/{id}");
        return res?.Data;
    }

    public async Task<int> SaveAsync(LabInvestigationProfileSaveRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-investigation-profiles", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to save Investigation Profile.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task ToggleStatusAsync(LabInvestigationProfileToggleStatusRequestModel req)
    {
        var res = await Client.PatchAsJsonAsync($"api/lab-investigation-profiles/{req.Profile_ID}/status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
    }

    public async Task DeleteAsync(int id)
    {
        var res = await Client.DeleteAsync($"api/lab-investigation-profiles/{id}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Investigation Profile.");
        }
    }
}
