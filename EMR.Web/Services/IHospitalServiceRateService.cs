using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IHospitalServiceRateService
{
    Task<HospitalServiceRateMaster?> GetByIdAsync(int id);
    Task<HospitalServiceRateFormViewModel?> GetFormModelByIdAsync(int id);
    Task<int> CreateAsync(HospitalServiceRateFormViewModel model, int? userId);
    Task<bool> UpdateAsync(HospitalServiceRateFormViewModel model, int? userId);
    Task<bool> ToggleActiveAsync(int id, int? userId);
    Task<bool> DeleteAsync(int id, int? userId);
    Task<bool> HasActiveRateAsync(int branchId, int tariffCategoryId, int hospitalServiceId, int? excludeId = null);
    Task<List<SelectListItem>> GetTariffCategoryOptionsAsync(int? selectedId = null, int? companyId = null, int? branchId = null);
    Task<List<SelectListItem>> GetHospitalServiceOptionsAsync(int? selectedId = null, int? branchId = null);
}
