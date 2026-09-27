using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabParameterOptionApiClient
{
    Task<IEnumerable<LabParameterOptionModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null, int? test_ID = null);
    Task<LabParameterOptionModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabParameterOptionCreateRequestModel req);
    Task<bool> UpdateAsync(LabParameterOptionUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabParameterOptionToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id, int? userId = null);
    Task<IEnumerable<LabParameterOptionLookupModel>> LookupTestsAsync(int? companyId);
}
