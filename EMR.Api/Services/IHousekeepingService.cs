using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IHousekeepingService
{
    // Location Master
    Task<IEnumerable<HKLocationListItemDto>> GetLocationsAsync(
        int? branchId = null,
        string? locationType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<HKLocationDetailDto?> GetLocationByIdAsync(int id);
    Task<int> CreateLocationAsync(HKLocationSaveRequest request);
    Task<bool> UpdateLocationAsync(int id, HKLocationSaveRequest request);
    Task<bool> ToggleLocationStatusAsync(int id, int? userId = null);
    Task<bool> DeleteLocationAsync(int id, int? userId = null);
    Task<IEnumerable<HKPhysicalMasterItemDto>> GetPhysicalMasterItemsAsync(string locationType, int? branchId = null);

    // Cleaning Master
    Task<IEnumerable<HKCleaningListItemDto>> GetCleaningsAsync(
        int? branchId = null,
        string? cleaningType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<HKCleaningDetailDto?> GetCleaningByIdAsync(int id);
    Task<int> CreateCleaningAsync(HKCleaningSaveRequest request);
    Task<bool> UpdateCleaningAsync(int id, HKCleaningSaveRequest request);
    Task<bool> ToggleCleaningStatusAsync(int id, int? userId = null);
    Task<bool> DeleteCleaningAsync(int id, int? userId = null);

    // HK Staff Master
    Task<IEnumerable<HKStaffListItemDto>> GetStaffListAsync(
        int? branchId = null,
        int? shiftId = null,
        int? locationId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<HKStaffDetailDto?> GetStaffByIdAsync(int id);
    Task<int> CreateStaffAsync(HKStaffSaveRequest request);
    Task<bool> UpdateStaffAsync(int id, HKStaffSaveRequest request);
    Task<bool> ToggleStaffStatusAsync(int id, int? userId = null);
    Task<bool> DeleteStaffAsync(int id, int? userId = null);

    // Checklist Templates
    Task<IEnumerable<HKChecklistTemplateDto>> GetChecklistTemplatesAsync(int? branchId = null);
}
