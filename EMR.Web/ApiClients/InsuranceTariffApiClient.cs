using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class InsuranceTariffApiClient(IHttpClientFactory factory) : IInsuranceTariffApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<IEnumerable<InsuranceTariffListItemViewModel>> GetListAsync(
        int? insuranceTpaId = null,
        int? branchId = null,
        string? entitlementType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        var queryParams = new List<string>();
        if (insuranceTpaId.HasValue && insuranceTpaId.Value > 0) queryParams.Add($"insuranceTpaId={insuranceTpaId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (!string.IsNullOrWhiteSpace(entitlementType)) queryParams.Add($"entitlementType={Uri.EscapeDataString(entitlementType)}");
        if (status.HasValue) queryParams.Add($"status={status.Value.ToString().ToLowerInvariant()}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/insurance-tariffs" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<InsuranceTariffListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<InsuranceTariffListItemViewModel?> GetByIdAsync(int id)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<InsuranceTariffListItemViewModel>>($"api/insurance-tariffs/{id}");
        return response?.Data;
    }

    public async Task<int> CreateAsync(InsuranceTariffFormViewModel model, int? userId = null)
    {
        var request = new
        {
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            InsuranceTPA_ID = model.InsuranceTPA_ID,
            EntitlementType = model.EntitlementType,
            Reference_ID = model.Reference_ID,
            DeductionRuleType = model.DeductionRuleType,
            DeductionValue = model.DeductionValue,
            Rate = model.Rate,
            Effective_From = model.Effective_From,
            Effective_To = model.Effective_To,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PostAsJsonAsync("api/insurance-tariffs", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Insurance tariff rule.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(int id, InsuranceTariffFormViewModel model, int? userId = null)
    {
        var request = new
        {
            InsTariff_ID = id,
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            InsuranceTPA_ID = model.InsuranceTPA_ID,
            EntitlementType = model.EntitlementType,
            Reference_ID = model.Reference_ID,
            DeductionRuleType = model.DeductionRuleType,
            DeductionValue = model.DeductionValue,
            Rate = model.Rate,
            Effective_From = model.Effective_From,
            Effective_To = model.Effective_To,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PutAsJsonAsync($"api/insurance-tariffs/{id}", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Insurance tariff rule.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        var response = await _http.PatchAsync($"api/insurance-tariffs/{id}/toggle-status?userId={userId}", null);
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
        var response = await _http.DeleteAsync($"api/insurance-tariffs/{id}?userId={userId}");
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete insurance tariff rule.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<IEnumerable<InsuranceMasterServiceItemViewModel>> GetMasterItemsAsync(string? entitlementType = null, int? branchId = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (!string.IsNullOrWhiteSpace(entitlementType)) queryParams.Add($"entitlementType={Uri.EscapeDataString(entitlementType)}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/insurance-tariffs/master-items" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<InsuranceMasterServiceItemViewModel>>>(url);
        return response?.Data ?? [];
    }
}
