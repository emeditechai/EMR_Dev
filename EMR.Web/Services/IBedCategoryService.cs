using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IBedCategoryService
{
    Task<IEnumerable<BedCategoryListItemViewModel>> GetAllAsync(int? companyId = null, int? branchId = null);
    Task<BedCategoryMaster?> GetByIdAsync(int id);
    Task<BedCategoryDetailsViewModel?> GetDetailsByIdAsync(int id);
    Task<bool> NameExistsAsync(string name, int? excludeId = null, int? companyId = null);
    Task<int> CreateAsync(BedCategoryMaster model, int? userId);
    Task UpdateAsync(BedCategoryMaster model, int? userId);
    Task<bool> DeleteAsync(int id);
}
