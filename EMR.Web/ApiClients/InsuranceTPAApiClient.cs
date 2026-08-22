using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class InsuranceTPAApiClient(IHttpClientFactory factory) : IInsuranceTPAApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<IEnumerable<InsuranceTPAListItemViewModel>> GetListAsync(
        int? branchId = null,
        string? type = null,
        string? networkCategory = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (!string.IsNullOrWhiteSpace(type)) queryParams.Add($"type={Uri.EscapeDataString(type)}");
        if (!string.IsNullOrWhiteSpace(networkCategory)) queryParams.Add($"networkCategory={Uri.EscapeDataString(networkCategory)}");
        if (status.HasValue) queryParams.Add($"status={status.Value.ToString().ToLowerInvariant()}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/insurances" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<InsuranceTPAListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<InsuranceTPAListItemViewModel?> GetByIdAsync(int id)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<InsuranceTPAListItemViewModel>>($"api/insurances/{id}");
        return response?.Data;
    }

    public async Task<int> CreateAsync(InsuranceTPAFormViewModel model, int? userId = null)
    {
        var request = new
        {
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            Type = model.Type,
            Name = model.Name,
            Code = model.Code,
            SchemeName = model.SchemeName,
            PolicyPrefix = model.PolicyPrefix,
            NetworkCategory = model.NetworkCategory,
            AuthorizationRequired = model.AuthorizationRequired,
            ContactPerson = model.ContactPerson,
            ContactNumber = model.ContactNumber,
            Email = model.Email,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PostAsJsonAsync("api/insurances", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Insurance/TPA record.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(int id, InsuranceTPAFormViewModel model, int? userId = null)
    {
        var request = new
        {
            InsuranceTPA_ID = id,
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            Type = model.Type,
            Name = model.Name,
            Code = model.Code,
            SchemeName = model.SchemeName,
            PolicyPrefix = model.PolicyPrefix,
            NetworkCategory = model.NetworkCategory,
            AuthorizationRequired = model.AuthorizationRequired,
            ContactPerson = model.ContactPerson,
            ContactNumber = model.ContactNumber,
            Email = model.Email,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PutAsJsonAsync($"api/insurances/{id}", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Insurance/TPA record.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        var response = await _http.PatchAsync($"api/insurances/{id}/toggle-status?userId={userId}", null);
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
        var response = await _http.DeleteAsync($"api/insurances/{id}?userId={userId}");
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Insurance/TPA record.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }
}
