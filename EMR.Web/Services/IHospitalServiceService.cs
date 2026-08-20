using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IHospitalServiceService
{
    Task<HospitalServiceMaster?> GetByIdAsync(int id);
    Task<List<HospitalServiceRateMaster>> GetRatesByServiceIdAsync(int serviceId);
    Task<HospitalServiceFormViewModel?> GetFormModelByIdAsync(int id);
    Task<int> CreateAsync(HospitalServiceFormViewModel model, int? userId);
    Task<bool> UpdateAsync(HospitalServiceFormViewModel model, int? userId);
    Task<bool> ToggleActiveAsync(int id, int? userId);
    Task<bool> DeleteAsync(int id, int? userId);
    Task<bool> CodeExistsAsync(string code, int branchId, int? excludeId = null);
    Task<List<SelectListItem>> GetDepartmentOptionsAsync(int? selectedId = null);
    List<SelectListItem> GetServiceTypeOptions(string? selectedValue = null);
    List<SelectListItem> GetUomOptions(string? selectedValue = null);
}
