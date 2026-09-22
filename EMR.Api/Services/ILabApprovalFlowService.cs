using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabApprovalFlowService
{
    /// <param name="branchScope">null = all, 0 = company-wide only, &gt;0 = that branch only.</param>
    Task<IEnumerable<LabApprovalFlowModel>> GetListAsync(int? companyId, int? branchScope, int? departmentId, int? categoryId, bool? status, string? search);
    Task<LabApprovalFlowDetailModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabApprovalFlowCreateRequestModel request);
    Task UpdateAsync(LabApprovalFlowUpdateRequestModel request);
    Task ToggleStatusAsync(LabApprovalFlowToggleStatusRequestModel request);
    Task DeleteAsync(int id, int? userId);
    /// <param name="categoryIds">Comma-separated category ids; an approver must cover every one of them.</param>
    /// <param name="includeIneligible">Also return the pathologists that do not match, with the reason.</param>
    Task<IEnumerable<LabApprovalEligibleApproverModel>> GetEligibleApproversAsync(int companyId, int? branchId, int? departmentId, string? categoryIds, bool includeIneligible = false);
    Task<LabApprovalFlowResolvedModel> ResolveAsync(int companyId, int? branchId, int? departmentId, int? categoryId);
}
