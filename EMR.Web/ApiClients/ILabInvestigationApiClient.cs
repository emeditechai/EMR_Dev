using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabInvestigationApiClient
{
    Task<IEnumerable<LabInvestigationModel>> GetListAsync(int? departmentId = null, int? categoryId = null, bool? status = null, string? search = null, int? companyId = null);
    Task<LabInvestigationModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabInvestigationCreateRequestModel req);
    Task UpdateAsync(int id, LabInvestigationUpdateRequestModel req);
    Task ToggleStatusAsync(LabInvestigationToggleStatusRequestModel req);
    Task DeleteAsync(int id);
}
