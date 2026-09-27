using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabExpertRuleApiClient
{
    Task<IEnumerable<LabExpertRuleModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null, int? organism_ID = null, int? antibiotic_ID = null);
    Task<LabExpertRuleModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabExpertRuleCreateRequestModel req);
    Task<bool> UpdateAsync(LabExpertRuleUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabExpertRuleToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id, int? userId = null);
    Task<IEnumerable<LabExpertRuleLookupModel>> LookupOrganismsAsync(int? companyId);
    Task<IEnumerable<LabExpertRuleLookupModel>> LookupAntibioticsAsync(int? companyId);
}
