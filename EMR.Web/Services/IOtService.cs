using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IOtService
{
    Task<OtMaster?> GetByIdAsync(int id);
    Task<OtFormViewModel?> GetFormModelByIdAsync(int id);
    Task<int> CreateAsync(OtFormViewModel model, int? userId);
    Task<bool> UpdateAsync(OtFormViewModel model, int? userId);
    Task<bool> ToggleActiveAsync(int id, int? userId);
    Task<bool> DeleteAsync(int id, int? userId);
    Task<bool> IsCodeExistsAsync(string code, int branchId, int? excludeId = null);
    Task<List<SelectListItem>> GetFloorOptionsAsync(int? selectedId = null, int? branchId = null);
    List<SelectListItem> GetOtTypeOptions(string? selectedType = null);
    Task<List<OtEquipmentMaster>> GetEquipmentsByOtIdAsync(int otId);
    Task<List<OtTariffMaster>> GetTariffsByOtIdAsync(int otId);
}
