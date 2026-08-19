using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface ITariffCategoryService
{
    Task<IEnumerable<TariffCategoryListItemViewModel>> GetAllAsync(
        string? patientCategory = null, int? companyId = null, int? branchId = null);

    Task<TariffCategoryMaster?> GetByIdAsync(int id);
    Task<TariffCategoryDetailsViewModel?> GetDetailsByIdAsync(int id);
    Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null);
    Task<bool> NameExistsAsync(string name, int? excludeId = null, int? companyId = null);
    Task<int> CreateAsync(TariffCategoryMaster model, int? userId);
    Task UpdateAsync(TariffCategoryMaster model, int? userId);
    Task<bool> DeleteAsync(int id);

    IEnumerable<SelectListItem> GetPatientCategoryOptions(string? selectedCategory = null);
}
