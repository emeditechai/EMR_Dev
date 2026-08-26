using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabInvestigationService
{
    Task<IEnumerable<LabInvestigationListItem>> GetListAsync(int? departmentId, int? categoryId, bool? status, string? search, int? companyId);
    Task<LabInvestigationListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabInvestigationCreateRequest req);
    Task UpdateAsync(LabInvestigationUpdateRequest req);
    Task ToggleStatusAsync(LabInvestigationToggleStatusRequest req);
    Task DeleteAsync(int id);
}
