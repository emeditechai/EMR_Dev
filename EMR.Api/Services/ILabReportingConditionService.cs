using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabReportingConditionService
{
    Task<IEnumerable<LabReportingConditionModel>> GetListAsync(bool? status = null, int? branchScope = null, string? search = null, int? companyId = null);
    Task<LabReportingConditionModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabReportingConditionCreateRequestModel request);
    Task UpdateAsync(LabReportingConditionUpdateRequestModel request);
    Task ToggleStatusAsync(LabReportingConditionToggleStatusRequestModel request);
    Task DeleteAsync(int id, int? userId = null);
    Task<LabReportConditionsForReportModel> GetForReportAsync(int companyId, int? branchId);
}
