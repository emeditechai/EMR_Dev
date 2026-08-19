using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IWardService
{
    Task<IEnumerable<WardListItemViewModel>> GetAllAsync(int? floorId = null, int? departmentId = null, string? wardType = null, int? companyId = null, int? branchId = null);
    Task<WardMaster?> GetByIdAsync(int id);
    Task<WardDetailsViewModel?> GetDetailsByIdAsync(int id);
    Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null);
    Task<int> CreateAsync(WardMaster model, int? userId);
    Task UpdateAsync(WardMaster model, int? userId);
    Task<bool> DeleteAsync(int id);
    Task<IEnumerable<SelectListItem>> GetFloorOptionsAsync(int? selectedId = null);
    Task<IEnumerable<SelectListItem>> GetIpdDepartmentOptionsAsync(int? selectedId = null);
    IEnumerable<SelectListItem> GetWardTypeOptions(string? selectedType = null);
    IEnumerable<SelectListItem> GetGenderOptions(string? selectedGender = null);
}
