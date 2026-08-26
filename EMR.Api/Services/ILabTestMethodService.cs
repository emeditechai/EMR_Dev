using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabTestMethodService
{
    Task<IEnumerable<LabTestMethodListItem>> GetListAsync(int? departmentId, bool? status, string? search, int? companyId);
    Task<LabTestMethodListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabTestMethodCreateRequest req);
    Task UpdateAsync(LabTestMethodUpdateRequest req);
    Task ToggleStatusAsync(LabTestMethodToggleStatusRequest req);
    Task DeleteAsync(int id);
}
