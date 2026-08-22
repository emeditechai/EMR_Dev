using System.Net.Http.Json;
using System.Text.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class GovernmentSchemeApiClient(IHttpClientFactory factory) : IGovernmentSchemeApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<IEnumerable<GovernmentSchemeListItemViewModel>> GetListAsync(
        int? branchId = null,
        string? schemeType = null,
        bool? isActive = null,
        string? search = null,
        int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (!string.IsNullOrWhiteSpace(schemeType)) queryParams.Add($"schemeType={Uri.EscapeDataString(schemeType)}");
        if (isActive.HasValue) queryParams.Add($"isActive={isActive.Value.ToString().ToLowerInvariant()}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/government-schemes" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<GovernmentSchemeListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<GovernmentSchemeListItemViewModel?> GetByIdAsync(int id)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<GovernmentSchemeListItemViewModel>>($"api/government-schemes/{id}");
        return response?.Data;
    }

    public async Task<int> CreateAsync(GovernmentSchemeFormViewModel model, int? userId = null)
    {
        var request = new
        {
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            SchemeCode = model.SchemeCode,
            SchemeName = model.SchemeName,
            SchemeType = model.SchemeType,
            AuthorityName = model.AuthorityName,
            RuleConfigJSON = model.RuleConfigJSON,
            Effective_From = model.Effective_From,
            Effective_To = model.Effective_To,
            IsActive = model.IsActive,
            UserId = userId
        };

        var response = await _http.PostAsJsonAsync("api/government-schemes", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Government Scheme.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(int id, GovernmentSchemeFormViewModel model, int? userId = null)
    {
        var request = new
        {
            Scheme_ID = id,
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            SchemeCode = model.SchemeCode,
            SchemeName = model.SchemeName,
            SchemeType = model.SchemeType,
            AuthorityName = model.AuthorityName,
            RuleConfigJSON = model.RuleConfigJSON,
            Effective_From = model.Effective_From,
            Effective_To = model.Effective_To,
            IsActive = model.IsActive,
            UserId = userId
        };

        var response = await _http.PutAsJsonAsync($"api/government-schemes/{id}", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Government Scheme.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        var response = await _http.PatchAsync($"api/government-schemes/{id}/toggle-status?userId={userId}", null);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> DeleteAsync(int id, int? userId = null)
    {
        var response = await _http.DeleteAsync($"api/government-schemes/{id}?userId={userId}");
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Government Scheme.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }
}
