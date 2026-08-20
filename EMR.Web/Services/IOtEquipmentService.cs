using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IOtEquipmentService
{
    Task<OtEquipmentMaster?> GetByIdAsync(int id);
    Task<OtEquipmentFormViewModel?> GetFormModelByIdAsync(int id);
    Task<int> CreateAsync(OtEquipmentFormViewModel model, int? userId);
    Task<bool> UpdateAsync(OtEquipmentFormViewModel model, int? userId);
    Task<bool> ToggleActiveAsync(int id, int? userId);
    Task<bool> DeleteAsync(int id, int? userId);
    Task<bool> IsCodeExistsAsync(string code, int branchId, int? excludeId = null);
    Task<List<SelectListItem>> GetOtOptionsAsync(int? selectedId = null, int? branchId = null);
    List<SelectListItem> GetEquipmentTypeOptions(string? selectedType = null);
}
