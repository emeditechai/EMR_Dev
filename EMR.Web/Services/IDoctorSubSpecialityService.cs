using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IDoctorSubSpecialityService
{
    Task<IEnumerable<DoctorSubSpecialityListItemViewModel>> GetAllAsync(int? specialityId = null, int? companyId = null, int? branchId = null);
    Task<DoctorSubSpecialityMaster?> GetByIdAsync(int id);
    Task<DoctorSubSpecialityDetailsViewModel?> GetDetailsByIdAsync(int id);
    Task<IEnumerable<DoctorSubSpecialityMaster>> GetBySpecialityIdAsync(int specialityId);
    Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null);
    Task<bool> NameExistsAsync(string name, int specialityId, int? excludeId = null, int? companyId = null);
    Task<int> CreateAsync(DoctorSubSpecialityMaster model, int? userId);
    Task UpdateAsync(DoctorSubSpecialityMaster model, int? userId);
    Task<bool> DeleteAsync(int id);
    Task<IEnumerable<SelectListItem>> GetSpecialityOptionsAsync(int? selectedId = null);
}
