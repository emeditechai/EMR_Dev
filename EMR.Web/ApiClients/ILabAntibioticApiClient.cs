using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabAntibioticApiClient
{
    Task<IEnumerable<LabAntibioticModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null);
    Task<LabAntibioticModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabAntibioticCreateRequestModel req);
    Task<bool> UpdateAsync(LabAntibioticUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabAntibioticToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id, int? userId = null);
}
