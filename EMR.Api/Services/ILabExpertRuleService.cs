using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabExpertRuleService
{
    Task<IEnumerable<LabExpertRuleListItem>> GetListAsync(bool? status, string? search, int? companyId, int? organism_ID, int? antibiotic_ID);
    Task<LabExpertRuleListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabExpertRuleCreateRequest req);
    Task UpdateAsync(LabExpertRuleUpdateRequest req);
    Task ToggleStatusAsync(LabExpertRuleToggleStatusRequest req);
    Task DeleteAsync(int id, int? userId);
    Task<IEnumerable<LabExpertRuleLookupItem>> LookupOrganismsAsync(int? companyId);
    Task<IEnumerable<LabExpertRuleLookupItem>> LookupAntibioticsAsync(int? companyId);
}
