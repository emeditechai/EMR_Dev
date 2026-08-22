using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IHousekeepingApiClient
{
    // Location Master
    Task<IEnumerable<HKLocationItemViewModel>> GetLocationsAsync(
        int? branchId = null,
        string? locationType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<HKLocationItemViewModel?> GetLocationByIdAsync(int id);
    Task<int> CreateLocationAsync(HKLocationFormModel model, int? userId = null);
    Task<bool> UpdateLocationAsync(int id, HKLocationFormModel model, int? userId = null);
    Task<bool> ToggleLocationStatusAsync(int id, int? userId = null);
    Task<bool> DeleteLocationAsync(int id, int? userId = null);
    Task<IEnumerable<HKPhysicalMasterItemViewModel>> GetPhysicalMasterItemsAsync(string locationType, int? branchId = null);

    // Cleaning Master
    Task<IEnumerable<HKCleaningItemViewModel>> GetCleaningsAsync(
        int? branchId = null,
        string? cleaningType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<HKCleaningItemViewModel?> GetCleaningByIdAsync(int id);
    Task<int> CreateCleaningAsync(HKCleaningFormModel model, int? userId = null);
    Task<bool> UpdateCleaningAsync(int id, HKCleaningFormModel model, int? userId = null);
    Task<bool> ToggleCleaningStatusAsync(int id, int? userId = null);
    Task<bool> DeleteCleaningAsync(int id, int? userId = null);

    // HK Staff Master
    Task<IEnumerable<HKStaffItemViewModel>> GetStaffListAsync(
        int? branchId = null,
        int? shiftId = null,
        int? locationId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<HKStaffItemViewModel?> GetStaffByIdAsync(int id);
    Task<int> CreateStaffAsync(HKStaffFormModel model, int? userId = null);
    Task<bool> UpdateStaffAsync(int id, HKStaffFormModel model, int? userId = null);
    Task<bool> ToggleStaffStatusAsync(int id, int? userId = null);
    Task<bool> DeleteStaffAsync(int id, int? userId = null);

    // Checklist Templates
    Task<IEnumerable<HKChecklistTemplateViewModel>> GetChecklistTemplatesAsync(int? branchId = null);
}
