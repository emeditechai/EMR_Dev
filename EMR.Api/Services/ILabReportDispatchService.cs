using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabReportDispatchService
{
    Task<LabReportDispatchResult> GetDashboardAsync(
        int branchId, DateTime? fromDate, DateTime? toDate, string? dateBasis,
        string? search, string? dispatchStatus, string? clientType, int? createdBy = null);

    Task<IEnumerable<LabReportDispatchTestDto>> GetBillTestsAsync(int labOrderId);
}
