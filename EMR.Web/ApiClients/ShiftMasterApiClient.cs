using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class ShiftMasterApiClient(IHttpClientFactory factory) : IShiftMasterApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<IEnumerable<ShiftMasterListItemViewModel>> GetListAsync(
        int? branchId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (status.HasValue) queryParams.Add($"status={status.Value.ToString().ToLowerInvariant()}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/shifts" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<ShiftMasterListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<ShiftMasterListItemViewModel?> GetByIdAsync(int id)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<ShiftMasterListItemViewModel>>($"api/shifts/{id}");
        return response?.Data;
    }

    public async Task<int> CreateAsync(ShiftMasterFormViewModel model, int? userId = null)
    {
        var request = new
        {
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            ShiftCode = model.ShiftCode,
            ShiftName = model.ShiftName,
            StartTime = model.StartTime,
            EndTime = model.EndTime,
            GraceTimeMinutes = model.GraceTimeMinutes,
            BreakDurationMinutes = model.BreakDurationMinutes,
            IsNightShift = model.IsNightShift,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PostAsJsonAsync("api/shifts", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Shift.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(int id, ShiftMasterFormViewModel model, int? userId = null)
    {
        var request = new
        {
            ShiftMaster_ID = id,
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            ShiftCode = model.ShiftCode,
            ShiftName = model.ShiftName,
            StartTime = model.StartTime,
            EndTime = model.EndTime,
            GraceTimeMinutes = model.GraceTimeMinutes,
            BreakDurationMinutes = model.BreakDurationMinutes,
            IsNightShift = model.IsNightShift,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PutAsJsonAsync($"api/shifts/{id}", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Shift.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        var response = await _http.PatchAsync($"api/shifts/{id}/toggle-status?userId={userId}", null);
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
        var response = await _http.DeleteAsync($"api/shifts/{id}?userId={userId}");
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Shift.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }
}
