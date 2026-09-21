using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabFormulaParameterApiClient(IHttpClientFactory factory) : ILabFormulaParameterApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabFormulaParameterModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabFormulaParameterModel>>>($"api/lab-formula-parameters{queryString}");
        return res?.Data ?? [];
    }

    public async Task<LabFormulaParameterModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabFormulaParameterModel>>($"api/lab-formula-parameters/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabFormulaParameterCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-formula-parameters", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Lab Formula Parameter.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabFormulaParameterUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-formula-parameters/{req.Parameter_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Lab Formula Parameter.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabFormulaParameterToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-formula-parameters/{req.Parameter_ID}/toggle-status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
        return true;
    }

    public async Task<bool> DeleteAsync(int id)
    {
        var res = await Client.DeleteAsync($"api/lab-formula-parameters/{id}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Lab Formula Parameter.");
        }
        return true;
    }

    public async Task<IEnumerable<NumericTestItemModel>> GetNumericTestsAsync(int? companyId = null, string? search = null)
    {
        var query = new List<string>();
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<NumericTestItemModel>>>($"api/lab-formula-parameters/numeric-tests{queryString}");
        return res?.Data ?? [];
    }
}
