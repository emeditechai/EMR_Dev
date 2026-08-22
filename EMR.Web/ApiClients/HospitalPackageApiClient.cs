using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class HospitalPackageApiClient(IHttpClientFactory factory) : IHospitalPackageApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<IEnumerable<HospitalPackageItemViewModel>> GetListAsync(
        int? branchId = null, string? packageType = null, bool? status = null, string? search = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (!string.IsNullOrWhiteSpace(packageType)) queryParams.Add($"packageType={Uri.EscapeDataString(packageType)}");
        if (status.HasValue) queryParams.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/hospital-packages" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<HospitalPackageItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<HospitalPackageSaveViewModel?> GetByIdAsync(int id)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<HospitalPackageSaveViewModel>>($"api/hospital-packages/{id}");
        return response?.Data;
    }

    public async Task<int> CreateAsync(HospitalPackageSaveViewModel model, int userId)
    {
        var payload = new
        {
            model.HospitalPackage_ID,
            model.CompanyId,
            model.Branch_ID,
            model.Package_Code,
            model.Package_Name,
            model.Package_Type,
            model.ValidFrom,
            model.ValidTo,
            model.TotalPackageAmount,
            model.Description,
            model.Status,
            UserId = userId,
            model.Details
        };

        var response = await _http.PostAsJsonAsync("api/hospital-packages", payload);
        response.EnsureSuccessStatusCode();

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(int id, HospitalPackageSaveViewModel model, int userId)
    {
        var payload = new
        {
            model.HospitalPackage_ID,
            model.CompanyId,
            model.Branch_ID,
            model.Package_Code,
            model.Package_Name,
            model.Package_Type,
            model.ValidFrom,
            model.ValidTo,
            model.TotalPackageAmount,
            model.Description,
            model.Status,
            UserId = userId,
            model.Details
        };

        var response = await _http.PutAsJsonAsync($"api/hospital-packages/{id}", payload);
        response.EnsureSuccessStatusCode();

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> ToggleStatusAsync(int id, int userId)
    {
        var response = await _http.PatchAsync($"api/hospital-packages/{id}/toggle-status?userId={userId}", null);
        response.EnsureSuccessStatusCode();

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> DeleteAsync(int id, int userId)
    {
        var response = await _http.DeleteAsync($"api/hospital-packages/{id}?userId={userId}");
        response.EnsureSuccessStatusCode();

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<IEnumerable<MasterLookupItemViewModel>> GetMasterLookupsAsync(int? branchId = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/hospital-packages/lookups" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<MasterLookupItemViewModel>>>(url);
        return response?.Data ?? [];
    }
}
