using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IIcuService
{
    // ICU Configurations
    Task<IcuMaster?> GetIcuByIdAsync(int id);
    Task<IcuConfigurationFormViewModel?> GetIcuFormModelByIdAsync(int id);
    Task<int> CreateIcuAsync(IcuConfigurationFormViewModel model, int? userId);
    Task<bool> UpdateIcuAsync(IcuConfigurationFormViewModel model, int? userId);
    Task<bool> ToggleIcuActiveAsync(int id, int? userId);
    Task<bool> DeleteIcuAsync(int id, int? userId);
    Task<bool> IsIcuCodeExistsAsync(string code, int branchId, int? excludeId = null);

    // Dynamic ICU Tariffs
    Task<IcuTariffMaster?> GetTariffByIdAsync(int id);
    Task<IcuTariffFormViewModel?> GetTariffFormModelByIdAsync(int id);
    Task<int> CreateTariffAsync(IcuTariffFormViewModel model, int? userId);
    Task<bool> UpdateTariffAsync(IcuTariffFormViewModel model, int? userId);
    Task<bool> ToggleTariffActiveAsync(int id, int? userId);
    Task<bool> DeleteTariffAsync(int id, int? userId);
    Task<bool> HasActiveTariffAsync(int branchId, int tariffCategoryId, int icuId, int? excludeId = null);

    // Dropdown helpers
    Task<List<SelectListItem>> GetWardOptionsAsync(int? selectedId = null, int? branchId = null);
    List<SelectListItem> GetIcuTypeOptions(string? selectedType = null);
    Task<List<SelectListItem>> GetTariffCategoryOptionsAsync(int? selectedId = null, int? branchId = null);
    Task<List<SelectListItem>> GetIcuOptionsAsync(int? selectedId = null, int? branchId = null);
}
