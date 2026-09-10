using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabSampleRejectionApiClient
{
    Task<IEnumerable<LabSampleRejectionModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null);
    Task<LabSampleRejectionModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabSampleRejectionCreateRequestModel req);
    Task<bool> UpdateAsync(LabSampleRejectionUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabSampleRejectionToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id);
}
