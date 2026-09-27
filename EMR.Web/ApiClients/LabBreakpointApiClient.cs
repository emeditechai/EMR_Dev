using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabBreakpointApiClient(IHttpClientFactory factory) : ILabBreakpointApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabBreakpointModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null, int? organism_ID = null, int? antibiotic_ID = null)
    {
        var query = new List<string>();
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");
        if (organism_ID.HasValue) query.Add($"organism_ID={organism_ID.Value}");
        if (antibiotic_ID.HasValue) query.Add($"antibiotic_ID={antibiotic_ID.Value}");
        var qs = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabBreakpointModel>>>($"api/lab-breakpoints{qs}");
        return res?.Data ?? [];
    }

    public async Task<LabBreakpointModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabBreakpointModel>>($"api/lab-breakpoints/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabBreakpointCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-breakpoints", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Breakpoint.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabBreakpointUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-breakpoints/{req.Breakpoint_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Breakpoint.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabBreakpointToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-breakpoints/{req.Breakpoint_ID}/toggle-status", req);
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
        var res = await Client.DeleteAsync($"api/lab-breakpoints/{id}{qs}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Breakpoint.");
        }
        return true;
    }

    public async Task<IEnumerable<LabBreakpointLookupModel>> LookupOrganismsAsync(int? companyId)
    {
        var qs = companyId.HasValue ? $"?companyId={companyId.Value}" : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabBreakpointLookupModel>>>($"api/lab-breakpoints/lookup/organisms{qs}");
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<LabBreakpointLookupModel>> LookupAntibioticsAsync(int? companyId)
    {
        var qs = companyId.HasValue ? $"?companyId={companyId.Value}" : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabBreakpointLookupModel>>>($"api/lab-breakpoints/lookup/antibiotics{qs}");
        return res?.Data ?? [];
    }
}
