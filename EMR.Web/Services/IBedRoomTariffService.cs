using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IBedRoomTariffService
{
    Task<IEnumerable<BedRoomTariffListItemViewModel>> GetAllAsync(
        int? wardId = null, int? roomId = null, int? bedCategoryId = null, 
        int? tariffCategoryId = null, int? companyId = null, int? branchId = null);

    Task<BedRoomTariffMaster?> GetByIdAsync(int id);
    Task<BedRoomTariffDetailsViewModel?> GetDetailsByIdAsync(int id);
    Task<IEnumerable<BedRoomTariffHistoryItemViewModel>> GetHistoryByTariffIdAsync(int bedRateId);

    Task<bool> HasOverlappingDatesAsync(
        int branchId, int wardId, int roomId, int bedCategoryId, int tariffCategoryId,
        DateTime effectiveFrom, DateTime? effectiveTo, int? excludeId = null);

    Task<int> CreateAsync(BedRoomTariffMaster model, int? userId, string? changeReason = null);
    Task UpdateAsync(BedRoomTariffMaster model, int? userId, string? changeReason = null);
    Task<bool> DeleteAsync(int id, int? userId);

    Task<IEnumerable<SelectListItem>> GetWardOptionsAsync(int? selectedWardId = null);
    Task<IEnumerable<SelectListItem>> GetRoomOptionsAsync(int? wardId = null, int? selectedRoomId = null);
    Task<IEnumerable<SelectListItem>> GetBedCategoryOptionsAsync(int? selectedCategoryId = null);
    Task<IEnumerable<SelectListItem>> GetTariffCategoryOptionsAsync(int? selectedTariffId = null);
}
