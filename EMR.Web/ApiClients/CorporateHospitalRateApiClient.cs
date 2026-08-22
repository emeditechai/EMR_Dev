using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class CorporateHospitalRateApiClient(IHttpClientFactory factory) : ICorporateHospitalRateApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<IEnumerable<CorporateHospitalRateListItemViewModel>> GetListAsync(
        int? corporateId = null,
        int? branchId = null,
        string? rateServiceType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        var queryParams = new List<string>();
        if (corporateId.HasValue && corporateId.Value > 0) queryParams.Add($"corporateId={corporateId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (!string.IsNullOrWhiteSpace(rateServiceType)) queryParams.Add($"rateServiceType={Uri.EscapeDataString(rateServiceType)}");
        if (status.HasValue) queryParams.Add($"status={status.Value.ToString().ToLowerInvariant()}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/corporate-rates" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<CorporateHospitalRateListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<CorporateHospitalRateListItemViewModel?> GetByIdAsync(int id)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<CorporateHospitalRateListItemViewModel>>($"api/corporate-rates/{id}");
        return response?.Data;
    }

    public async Task<int> CreateAsync(CorporateHospitalRateFormViewModel model, int? userId = null)
    {
        var request = new
        {
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            Corporate_ID = model.Corporate_ID,
            RateServiceType = model.RateServiceType,
            ReferenceMaster_ID = model.ReferenceMaster_ID,
            RateType = model.RateType,
            Rate = model.Rate,
            DiscountPercent = model.DiscountPercent,
            Effective_From = model.Effective_From,
            Effective_To = model.Effective_To,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PostAsJsonAsync("api/corporate-rates", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Corporate rate rule.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(int id, CorporateHospitalRateFormViewModel model, int? userId = null)
    {
        var request = new
        {
            CorpRate_ID = id,
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            Corporate_ID = model.Corporate_ID,
            RateServiceType = model.RateServiceType,
            ReferenceMaster_ID = model.ReferenceMaster_ID,
            RateType = model.RateType,
            Rate = model.Rate,
            DiscountPercent = model.DiscountPercent,
            Effective_From = model.Effective_From,
            Effective_To = model.Effective_To,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PutAsJsonAsync($"api/corporate-rates/{id}", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Corporate rate rule.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        var response = await _http.PatchAsync($"api/corporate-rates/{id}/toggle-status?userId={userId}", null);
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
        var response = await _http.DeleteAsync($"api/corporate-rates/{id}?userId={userId}");
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete corporate rate rule.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<IEnumerable<MasterServiceItemViewModel>> GetMasterItemsAsync(string? rateServiceType = null, int? branchId = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (!string.IsNullOrWhiteSpace(rateServiceType)) queryParams.Add($"serviceType={Uri.EscapeDataString(rateServiceType)}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/corporate-rates/master-items" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<MasterServiceItemViewModel>>>(url);
        return response?.Data ?? [];
    }
}
