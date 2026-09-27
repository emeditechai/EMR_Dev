using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabBreakpointApiClient
{
    Task<IEnumerable<LabBreakpointModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null, int? organism_ID = null, int? antibiotic_ID = null);
    Task<LabBreakpointModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabBreakpointCreateRequestModel req);
    Task<bool> UpdateAsync(LabBreakpointUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabBreakpointToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id, int? userId = null);
    Task<IEnumerable<LabBreakpointLookupModel>> LookupOrganismsAsync(int? companyId);
    Task<IEnumerable<LabBreakpointLookupModel>> LookupAntibioticsAsync(int? companyId);
}
