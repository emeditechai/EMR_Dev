using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabAntibioticPanelService
{
    Task<IEnumerable<LabAntibioticPanelListItem>> GetListAsync(bool? status, string? search, int? companyId, int? sample_Type_ID);
    Task<LabAntibioticPanelListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabAntibioticPanelCreateRequest req);
    Task UpdateAsync(LabAntibioticPanelUpdateRequest req);
    Task ToggleStatusAsync(LabAntibioticPanelToggleStatusRequest req);
    Task DeleteAsync(int id, int? userId);
    Task<IEnumerable<LabAntibioticPanelLookupItem>> LookupAntibioticsAsync(int? companyId);
    Task<IEnumerable<LabAntibioticPanelLookupItem>> LookupSampleTypesAsync(int? companyId);
}
