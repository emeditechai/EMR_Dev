using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabSampleRejectionReasonApiClient
{
    Task<IEnumerable<LabSampleRejectionReasonModel>> GetListAsync(bool? status = null, int? sampleTypeId = null, string? search = null, int? companyId = null);
    Task<LabSampleRejectionReasonModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabSampleRejectionReasonCreateRequestModel request);
    Task UpdateAsync(LabSampleRejectionReasonUpdateRequestModel request);
    Task ToggleStatusAsync(LabSampleRejectionReasonToggleStatusRequestModel request);
    Task DeleteAsync(int id, int? userId = null);
}
