using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabReferenceRangeApiClient
{
    Task<IEnumerable<LabReferenceRangeModel>> GetListAsync(int? testId = null, string? gender = null, bool? status = null, string? search = null, int? companyId = null);
    Task<LabReferenceRangeModel?> GetByIdAsync(int id, int? companyId = null);
    Task<int> CreateAsync(LabReferenceRangeCreateRequestModel req);
    Task<int> BulkSaveAsync(LabReferenceRangeBulkSaveRequestModel req);
    Task<bool> UpdateAsync(LabReferenceRangeUpdateRequestModel req);
    Task<bool> DeleteAsync(int id, int companyId = 1, int? userId = null);
    Task<bool> ToggleStatusAsync(LabReferenceRangeToggleStatusRequestModel req);
    Task<IEnumerable<LabNumericTestOptionModel>> GetNumericTestsAsync(int companyId = 1);
}
