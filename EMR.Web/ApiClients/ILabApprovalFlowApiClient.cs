using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabApprovalFlowApiClient
{
    /// <param name="branchScope">null = all, 0 = company-wide only, &gt;0 = that branch only.</param>
    Task<IEnumerable<LabApprovalFlowModel>> GetListAsync(int? companyId = null, int? branchScope = null, int? departmentId = null, int? categoryId = null, bool? status = null, string? search = null);
    Task<LabApprovalFlowDetailModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabApprovalFlowCreateRequestModel request);
    Task UpdateAsync(LabApprovalFlowUpdateRequestModel request);
    Task ToggleStatusAsync(LabApprovalFlowToggleStatusRequestModel request);
    Task DeleteAsync(int id, int? userId = null);
    /// <param name="categoryIds">The approver must cover every one of these categories.</param>
    /// <param name="includeIneligible">Also return the pathologists that do not match, flagged with the reason.</param>
    Task<IEnumerable<LabApprovalEligibleApproverModel>> GetEligibleApproversAsync(int companyId, int? branchId = null, int? departmentId = null, IEnumerable<int>? categoryIds = null, bool includeIneligible = false);
}
