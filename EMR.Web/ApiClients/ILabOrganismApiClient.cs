using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabOrganismApiClient
{
    Task<IEnumerable<LabOrganismModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null);
    Task<LabOrganismModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabOrganismCreateRequestModel req);
    Task<bool> UpdateAsync(LabOrganismUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabOrganismToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id, int? userId = null);
}
