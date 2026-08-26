using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabSampleTypeApiClient
{
    Task<IEnumerable<LabSampleTypeModel>> GetListAsync(string? containerType = null, bool? status = null, string? search = null, int? companyId = null);
    Task<LabSampleTypeModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabSampleTypeCreateRequestModel req);
    Task<bool> UpdateAsync(LabSampleTypeUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabSampleTypeToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id);
}
