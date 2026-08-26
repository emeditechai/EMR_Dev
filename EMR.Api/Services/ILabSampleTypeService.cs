using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabSampleTypeService
{
    Task<IEnumerable<LabSampleTypeListItem>> GetListAsync(string? containerType, bool? status, string? search, int? companyId);
    Task<LabSampleTypeListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabSampleTypeCreateRequest req);
    Task UpdateAsync(LabSampleTypeUpdateRequest req);
    Task ToggleStatusAsync(LabSampleTypeToggleStatusRequest req);
    Task DeleteAsync(int id);
}
