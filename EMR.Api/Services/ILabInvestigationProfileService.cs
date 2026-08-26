using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabInvestigationProfileService
{
    Task<IEnumerable<LabInvestigationProfileHeaderListItem>> GetListAsync(string? profileType = null, bool? status = null, string? search = null, int? companyId = null);
    Task<LabInvestigationProfileFullDetail?> GetByIdAsync(int id);
    Task<int> SaveAsync(LabInvestigationProfileSaveRequest req);
    Task ToggleStatusAsync(LabInvestigationProfileToggleStatusRequest req);
    Task DeleteAsync(int id);
}
