using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabUnitApiClient
{
    Task<IEnumerable<LabUnitModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null);
    Task<LabUnitModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabUnitCreateRequestModel req);
    Task<bool> UpdateAsync(LabUnitUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabUnitToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id);
}
