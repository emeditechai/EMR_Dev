using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabFranchiseService
{
    Task<IEnumerable<LabFranchiseModel>> GetListAsync(bool? status = null, bool? isActive = null, string? search = null, int? companyId = null, int? franchiseType = null, int? parentBranchId = null);
    Task<LabFranchiseModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabFranchiseCreateRequestModel request);
    Task UpdateAsync(LabFranchiseUpdateRequestModel request);
    Task ToggleStatusAsync(LabFranchiseToggleStatusRequestModel request);
    Task ToggleSuspensionAsync(LabFranchiseToggleSuspensionRequestModel request);
    Task DeleteAsync(int id, int? userId = null);
}
