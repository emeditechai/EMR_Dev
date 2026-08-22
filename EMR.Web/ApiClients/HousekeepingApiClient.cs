using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class HousekeepingApiClient(IHttpClientFactory factory) : IHousekeepingApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    // ── Location Master ──────────────────────────────────────────────────────
    public async Task<IEnumerable<HKLocationItemViewModel>> GetLocationsAsync(
        int? branchId = null,
        string? locationType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (!string.IsNullOrWhiteSpace(locationType)) queryParams.Add($"locationType={Uri.EscapeDataString(locationType)}");
        if (status.HasValue) queryParams.Add($"status={status.Value.ToString().ToLowerInvariant()}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/housekeeping/locations" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<HKLocationItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<HKLocationItemViewModel?> GetLocationByIdAsync(int id)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<HKLocationItemViewModel>>($"api/housekeeping/locations/{id}");
        return response?.Data;
    }

    public async Task<int> CreateLocationAsync(HKLocationFormModel model, int? userId = null)
    {
        var request = new
        {
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            LocationType = model.LocationType,
            Reference_ID = model.Reference_ID,
            LocationCode = model.LocationCode,
            LocationName = model.LocationName,
            Floor_ID = model.Floor_ID,
            Building_ID = model.Building_ID,
            RiskLevel = model.RiskLevel,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PostAsJsonAsync("api/housekeeping/locations", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Housekeeping Location.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateLocationAsync(int id, HKLocationFormModel model, int? userId = null)
    {
        var request = new
        {
            Location_ID = id,
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            LocationType = model.LocationType,
            Reference_ID = model.Reference_ID,
            LocationCode = model.LocationCode,
            LocationName = model.LocationName,
            Floor_ID = model.Floor_ID,
            Building_ID = model.Building_ID,
            RiskLevel = model.RiskLevel,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PutAsJsonAsync($"api/housekeeping/locations/{id}", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Housekeeping Location.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> ToggleLocationStatusAsync(int id, int? userId = null)
    {
        var response = await _http.PatchAsync($"api/housekeeping/locations/{id}/toggle-status?userId={userId}", null);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> DeleteLocationAsync(int id, int? userId = null)
    {
        var response = await _http.DeleteAsync($"api/housekeeping/locations/{id}?userId={userId}");
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Location.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<IEnumerable<HKPhysicalMasterItemViewModel>> GetPhysicalMasterItemsAsync(string locationType, int? branchId = null)
    {
        var url = $"api/housekeeping/physical-master-items?locationType={Uri.EscapeDataString(locationType)}&branchId={branchId}";
        var response = await _http.GetFromJsonAsync<ApiResponse<List<HKPhysicalMasterItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── Cleaning Master ──────────────────────────────────────────────────────
    public async Task<IEnumerable<HKCleaningItemViewModel>> GetCleaningsAsync(
        int? branchId = null,
        string? cleaningType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (!string.IsNullOrWhiteSpace(cleaningType)) queryParams.Add($"cleaningType={Uri.EscapeDataString(cleaningType)}");
        if (status.HasValue) queryParams.Add($"status={status.Value.ToString().ToLowerInvariant()}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/housekeeping/cleanings" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<HKCleaningItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<HKCleaningItemViewModel?> GetCleaningByIdAsync(int id)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<HKCleaningItemViewModel>>($"api/housekeeping/cleanings/{id}");
        return response?.Data;
    }

    public async Task<int> CreateCleaningAsync(HKCleaningFormModel model, int? userId = null)
    {
        var request = new
        {
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            CleaningType = model.CleaningType,
            Frequency = model.Frequency,
            ChecklistTemplate_ID = model.ChecklistTemplate_ID,
            ChemicalUsed = model.ChemicalUsed,
            EquipmentUsed = model.EquipmentUsed,
            SLA_Minutes = model.SLA_Minutes,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PostAsJsonAsync("api/housekeeping/cleanings", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Cleaning Protocol.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateCleaningAsync(int id, HKCleaningFormModel model, int? userId = null)
    {
        var request = new
        {
            Cleaning_ID = id,
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            CleaningType = model.CleaningType,
            Frequency = model.Frequency,
            ChecklistTemplate_ID = model.ChecklistTemplate_ID,
            ChemicalUsed = model.ChemicalUsed,
            EquipmentUsed = model.EquipmentUsed,
            SLA_Minutes = model.SLA_Minutes,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PutAsJsonAsync($"api/housekeeping/cleanings/{id}", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Cleaning Protocol.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> ToggleCleaningStatusAsync(int id, int? userId = null)
    {
        var response = await _http.PatchAsync($"api/housekeeping/cleanings/{id}/toggle-status?userId={userId}", null);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> DeleteCleaningAsync(int id, int? userId = null)
    {
        var response = await _http.DeleteAsync($"api/housekeeping/cleanings/{id}?userId={userId}");
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Cleaning Protocol.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    // ── HK Staff Master ──────────────────────────────────────────────────────
    public async Task<IEnumerable<HKStaffItemViewModel>> GetStaffListAsync(
        int? branchId = null,
        int? shiftId = null,
        int? locationId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (shiftId.HasValue) queryParams.Add($"shiftId={shiftId.Value}");
        if (locationId.HasValue) queryParams.Add($"locationId={locationId.Value}");
        if (status.HasValue) queryParams.Add($"status={status.Value.ToString().ToLowerInvariant()}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/housekeeping/staff" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<HKStaffItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<HKStaffItemViewModel?> GetStaffByIdAsync(int id)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<HKStaffItemViewModel>>($"api/housekeeping/staff/{id}");
        return response?.Data;
    }

    public async Task<int> CreateStaffAsync(HKStaffFormModel model, int? userId = null)
    {
        var request = new
        {
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            Staff_ID = model.Staff_ID,
            ShiftMaster_ID = model.ShiftMaster_ID,
            Supervisor_ID = model.Supervisor_ID,
            AreaAllocation_ID = model.AreaAllocation_ID,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PostAsJsonAsync("api/housekeeping/staff", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Staff Allocation.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateStaffAsync(int id, HKStaffFormModel model, int? userId = null)
    {
        var request = new
        {
            HKStaff_ID = id,
            CompanyId = model.CompanyId,
            Branch_ID = model.Branch_ID ?? 1,
            Staff_ID = model.Staff_ID,
            ShiftMaster_ID = model.ShiftMaster_ID,
            Supervisor_ID = model.Supervisor_ID,
            AreaAllocation_ID = model.AreaAllocation_ID,
            Status = model.Status,
            UserId = userId
        };

        var response = await _http.PutAsJsonAsync($"api/housekeeping/staff/{id}", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Staff Allocation.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> ToggleStaffStatusAsync(int id, int? userId = null)
    {
        var response = await _http.PatchAsync($"api/housekeeping/staff/{id}/toggle-status?userId={userId}", null);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    public async Task<bool> DeleteStaffAsync(int id, int? userId = null)
    {
        var response = await _http.DeleteAsync($"api/housekeeping/staff/{id}?userId={userId}");
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Staff Allocation.");
        }

        var result = await response.Content.ReadFromJsonAsync<ApiResponse<bool>>();
        return result?.Data ?? true;
    }

    // ── Checklist Templates ─────────────────────────────────────────────────
    public async Task<IEnumerable<HKChecklistTemplateViewModel>> GetChecklistTemplatesAsync(int? branchId = null)
    {
        var url = $"api/housekeeping/checklist-templates?branchId={branchId}";
        var response = await _http.GetFromJsonAsync<ApiResponse<List<HKChecklistTemplateViewModel>>>(url);
        return response?.Data ?? [];
    }
}
