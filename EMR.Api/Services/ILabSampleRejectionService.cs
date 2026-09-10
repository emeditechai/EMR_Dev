using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabSampleRejectionService
{
    Task<IEnumerable<LabSampleRejectionListItem>> GetListAsync(bool? status, string? search, int? companyId);
    Task<LabSampleRejectionListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabSampleRejectionCreateRequest req);
    Task UpdateAsync(LabSampleRejectionUpdateRequest req);
    Task ToggleStatusAsync(LabSampleRejectionToggleStatusRequest req);
    Task DeleteAsync(int id);
}
