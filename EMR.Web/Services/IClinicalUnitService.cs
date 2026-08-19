using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IClinicalUnitService
{
    Task<IEnumerable<ClinicalUnitListItemViewModel>> GetAllAsync(int? departmentId = null, int? specialityId = null, int? companyId = null, int? branchId = null);
    Task<ClinicalUnitMaster?> GetByIdAsync(int id);
    Task<ClinicalUnitDetailsViewModel?> GetDetailsByIdAsync(int id);
    Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null);
    Task<int> CreateAsync(ClinicalUnitMaster model, int? userId);
    Task UpdateAsync(ClinicalUnitMaster model, int? userId);
    Task<bool> DeleteAsync(int id);
    Task<IEnumerable<DoctorOptionDto>> GetDoctorsBySpecialityAsync(int? specialityId = null, int? branchId = null);
    Task<IEnumerable<SelectListItem>> GetDepartmentOptionsAsync(int? selectedId = null);
    Task<IEnumerable<SelectListItem>> GetSpecialityOptionsAsync(int? selectedId = null);
    Task<IEnumerable<SelectListItem>> GetDoctorOptionsAsync(int? specialityId = null, int? selectedDoctorId = null, int? branchId = null);
}
