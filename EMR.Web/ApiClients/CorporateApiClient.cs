using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class CorporateApiClient(IHttpClientFactory factory) : ICorporateApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<IEnumerable<CorporateListItemViewModel>> GetListAsync(
        int? branchId = null,
        string? type = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (!string.IsNullOrWhiteSpace(type)) queryParams.Add($"type={Uri.EscapeDataString(type)}");
        if (status.HasValue) queryParams.Add($"status={status.Value.ToString().ToLowerInvariant()}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/corporates" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<CorporateListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<CorporateListItemViewModel?> GetByIdAsync(int id)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<CorporateListItemViewModel>>($"api/corporates/{id}");
        return response?.Data;
    }

    public async Task<int> CreateAsync(CorporateFormViewModel model, int? userId = null)
    {
        var request = new
        {
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            Corporate_Code = model.Corporate_Code,
            Corporate_Name = model.Corporate_Name,
            Corporate_Type = model.Corporate_Type,
            Effective_From = model.Effective_From,
            Effective_To = model.Effective_To,
            Credit_Limit = model.Credit_Limit,
            Credit_Days = model.Credit_Days,
            BillingCycle = model.BillingCycle,
            Contact_No = model.Contact_No,
            Email = model.Email,
            Address = model.Address,
            Pincode = model.Pincode,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PostAsJsonAsync("api/corporates", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Corporate record.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(int id, CorporateFormViewModel model, int? userId = null)
    {
        var request = new
        {
            Corporate_ID = id,
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            Corporate_Code = model.Corporate_Code,
            Corporate_Name = model.Corporate_Name,
            Corporate_Type = model.Corporate_Type,
            Effective_From = model.Effective_From,
            Effective_To = model.Effective_To,
            Credit_Limit = model.Credit_Limit,
            Credit_Days = model.Credit_Days,
            BillingCycle = model.BillingCycle,
            Contact_No = model.Contact_No,
            Email = model.Email,
            Address = model.Address,
            Pincode = model.Pincode,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PutAsJsonAsync($"api/corporates/{id}", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Corporate record.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        var response = await _http.PatchAsync($"api/corporates/{id}/toggle-status?userId={userId}", null);
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
        var response = await _http.DeleteAsync($"api/corporates/{id}?userId={userId}");
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete corporate record.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }
}
