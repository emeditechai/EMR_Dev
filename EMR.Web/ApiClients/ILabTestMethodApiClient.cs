using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabTestMethodApiClient
{
    Task<IEnumerable<LabTestMethodModel>> GetListAsync(int? departmentId = null, bool? status = null, string? search = null, int? companyId = null);
    Task<LabTestMethodModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabTestMethodCreateRequestModel req);
    Task<bool> UpdateAsync(LabTestMethodUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabTestMethodToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id);
}
