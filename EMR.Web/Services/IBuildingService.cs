using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IBuildingService
{
    Task<IEnumerable<BuildingListItemViewModel>> GetAllAsync(int? companyId = null, int? branchId = null);
    Task<BuildingMaster?> GetByIdAsync(int id);
    Task<BuildingDetailsViewModel?> GetDetailsByIdAsync(int id);
    Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null);
    Task<int> CreateAsync(BuildingMaster building, int? userId);
    Task UpdateAsync(BuildingMaster building, int? userId);
    Task<IEnumerable<SelectListItem>> GetBuildingOptionsAsync(int? companyId = null, int? selectedId = null);
}
