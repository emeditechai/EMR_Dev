using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients;

public interface IPathologistDashboardApiClient
{
    Task<PathologistAccessResult> GetAccessAsync(int userId, int branchId);
    Task<PathologistDashboardListResult> GetHeadersAsync(int userId, int branchId, DateTime? fromDate, DateTime? toDate,
        string dateBasis, string? search, int? departmentId, int? categoryId, string statusFilter);
    Task<PathologistDetailResult?> GetDetailAsync(int labOrderId, int userId, int branchId);
    /// <summary>Returns the counts on success, or the rule message the API refused with.</summary>
    Task<(PathologistApproveResult? Result, string? Error)> ApproveAsync(PathologistApproveRequest request);
}
