using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabInvestigationProfileApiClient
{
    Task<IEnumerable<LabInvestigationProfileHeaderModel>> GetListAsync(int? branchId = null, string? profileType = null, bool? status = null, string? search = null, int? companyId = null);
    Task<LabInvestigationProfileFullDetailModel?> GetByIdAsync(int id);
    Task<int> SaveAsync(LabInvestigationProfileSaveRequestModel req);
    Task ToggleStatusAsync(LabInvestigationProfileToggleStatusRequestModel req);
    Task DeleteAsync(int id);
}
