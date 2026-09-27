using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabBreakpointService
{
    Task<IEnumerable<LabBreakpointListItem>> GetListAsync(bool? status, string? search, int? companyId, int? organism_ID, int? antibiotic_ID);
    Task<LabBreakpointListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabBreakpointCreateRequest req);
    Task UpdateAsync(LabBreakpointUpdateRequest req);
    Task ToggleStatusAsync(LabBreakpointToggleStatusRequest req);
    Task DeleteAsync(int id, int? userId);
    Task<IEnumerable<LabBreakpointLookupItem>> LookupOrganismsAsync(int? companyId);
    Task<IEnumerable<LabBreakpointLookupItem>> LookupAntibioticsAsync(int? companyId);
}
