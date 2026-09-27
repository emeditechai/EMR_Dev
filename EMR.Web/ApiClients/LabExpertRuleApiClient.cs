using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabExpertRuleApiClient(IHttpClientFactory factory) : ILabExpertRuleApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabExpertRuleModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null, int? organism_ID = null, int? antibiotic_ID = null)
    {
        var query = new List<string>();
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");
        if (organism_ID.HasValue) query.Add($"organism_ID={organism_ID.Value}");
        if (antibiotic_ID.HasValue) query.Add($"antibiotic_ID={antibiotic_ID.Value}");
        var qs = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabExpertRuleModel>>>($"api/lab-expert-rules{qs}");
        return res?.Data ?? [];
    }

    public async Task<LabExpertRuleModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabExpertRuleModel>>($"api/lab-expert-rules/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabExpertRuleCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-expert-rules", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Expert Rule.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabExpertRuleUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-expert-rules/{req.Rule_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Expert Rule.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabExpertRuleToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-expert-rules/{req.Rule_ID}/toggle-status", req);
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
        var res = await Client.DeleteAsync($"api/lab-expert-rules/{id}{qs}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Expert Rule.");
        }
        return true;
    }

    public async Task<IEnumerable<LabExpertRuleLookupModel>> LookupOrganismsAsync(int? companyId)
    {
        var qs = companyId.HasValue ? $"?companyId={companyId.Value}" : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabExpertRuleLookupModel>>>($"api/lab-expert-rules/lookup/organisms{qs}");
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<LabExpertRuleLookupModel>> LookupAntibioticsAsync(int? companyId)
    {
        var qs = companyId.HasValue ? $"?companyId={companyId.Value}" : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabExpertRuleLookupModel>>>($"api/lab-expert-rules/lookup/antibiotics{qs}");
        return res?.Data ?? [];
    }
}
