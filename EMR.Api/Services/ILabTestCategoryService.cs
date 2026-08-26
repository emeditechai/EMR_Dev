using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabTestCategoryService
{
    Task<IEnumerable<LabTestCategoryListItem>> GetListAsync(int? departmentId, bool? status, string? search, int? companyId);
    Task<LabTestCategoryListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabTestCategoryCreateRequest req);
    Task UpdateAsync(LabTestCategoryUpdateRequest req);
    Task ToggleStatusAsync(LabTestCategoryToggleStatusRequest req);
    Task DeleteAsync(int id);
}
