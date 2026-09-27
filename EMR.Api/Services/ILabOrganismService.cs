using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabOrganismService
{
    Task<IEnumerable<LabOrganismListItem>> GetListAsync(bool? status, string? search, int? companyId);
    Task<LabOrganismListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabOrganismCreateRequest req);
    Task UpdateAsync(LabOrganismUpdateRequest req);
    Task ToggleStatusAsync(LabOrganismToggleStatusRequest req);
    Task DeleteAsync(int id, int? userId);
}
