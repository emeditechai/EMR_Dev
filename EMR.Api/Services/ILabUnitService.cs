using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabUnitService
{
    Task<IEnumerable<LabUnitListItem>> GetListAsync(int? branchId, bool? status, string? search, int? companyId);
    Task<LabUnitListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabUnitCreateRequest req);
    Task UpdateAsync(LabUnitUpdateRequest req);
    Task ToggleStatusAsync(LabUnitToggleStatusRequest req);
    Task DeleteAsync(int id);
}
