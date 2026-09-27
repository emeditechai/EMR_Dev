using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabAntibioticPanelApiClient
{
    Task<IEnumerable<LabAntibioticPanelModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null, int? sample_Type_ID = null);
    Task<LabAntibioticPanelModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabAntibioticPanelCreateRequestModel req);
    Task<bool> UpdateAsync(LabAntibioticPanelUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabAntibioticPanelToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id, int? userId = null);
    Task<IEnumerable<LabAntibioticPanelLookupModel>> LookupAntibioticsAsync(int? companyId);
    Task<IEnumerable<LabAntibioticPanelLookupModel>> LookupSampleTypesAsync(int? companyId);
}
