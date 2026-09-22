using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients;

public interface ILabUnapproveApiClient
{
    Task<LabUnapproveListResult> GetHeadersAsync(int branchId, DateTime? fromDate, DateTime? toDate, string dateBasis, string? search, string approvalType);
    Task<LabUnapproveDetailResult?> GetDetailAsync(int labOrderId);
    /// <summary>Returns (count, null) on success or (0, message) when the API refused the request.</summary>
    Task<(int Count, string? Error)> UnapproveAsync(LabUnapproveRequest request);
}
