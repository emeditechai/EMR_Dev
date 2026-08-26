using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabTestSubCategoryService
{
    Task<IEnumerable<LabTestSubCategoryListItem>> GetListAsync(int? categoryId, bool? status, string? search, int? companyId);
    Task<LabTestSubCategoryListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabTestSubCategoryCreateRequest req);
    Task UpdateAsync(LabTestSubCategoryUpdateRequest req);
    Task ToggleStatusAsync(LabTestSubCategoryToggleStatusRequest req);
    Task DeleteAsync(int id);
}
