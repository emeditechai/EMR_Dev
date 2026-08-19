using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IBedService
{
    Task<IEnumerable<BedListItemViewModel>> GetAllAsync(
        int? buildingId = null, int? wardId = null, int? roomId = null, 
        int? bedCategoryId = null, string? bedStatus = null, 
        int? companyId = null, int? branchId = null);

    Task<BedMaster?> GetByIdAsync(int id);
    Task<BedDetailsViewModel?> GetDetailsByIdAsync(int id);
    Task<bool> BedNumberExistsAsync(string bedNumber, int? excludeId = null, int? companyId = null);
    Task<int> CreateAsync(BedMaster model, int? userId);
    Task UpdateAsync(BedMaster model, int? userId);
    Task<bool> DeleteAsync(int id);

    Task<IEnumerable<SelectListItem>> GetBuildingOptionsAsync(int? selectedBuildingId = null);
    Task<IEnumerable<SelectListItem>> GetWardOptionsAsync(int? buildingId = null, int? selectedWardId = null);
    Task<IEnumerable<SelectListItem>> GetRoomOptionsAsync(int? wardId = null, int? selectedRoomId = null);
    Task<IEnumerable<SelectListItem>> GetBedCategoryOptionsAsync(int? selectedCategoryId = null);

    Task<IEnumerable<WardOptionByBuildingDto>> GetWardsByBuildingAsync(int buildingId);
    Task<IEnumerable<RoomOptionByWardDto>> GetRoomsByWardAsync(int wardId);

    IEnumerable<SelectListItem> GetBedStatusOptions(string? selectedStatus = null);
}
