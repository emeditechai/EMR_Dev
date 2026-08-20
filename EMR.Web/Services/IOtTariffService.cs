using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IOtTariffService
{
    Task<OtTariffMaster?> GetByIdAsync(int id);
    Task<OtTariffFormViewModel?> GetFormModelByIdAsync(int id);
    Task<int> CreateAsync(OtTariffFormViewModel model, int? userId);
    Task<bool> UpdateAsync(OtTariffFormViewModel model, int? userId);
    Task<bool> ToggleActiveAsync(int id, int? userId);
    Task<bool> DeleteAsync(int id, int? userId);
    Task<bool> HasActiveTariffAsync(int branchId, int tariffCategoryId, int otId, int? excludeId = null);
    Task<List<SelectListItem>> GetTariffCategoryOptionsAsync(int? selectedId = null, int? companyId = null, int? branchId = null);
    Task<List<SelectListItem>> GetOtOptionsAsync(int? selectedId = null, int? branchId = null);
}
