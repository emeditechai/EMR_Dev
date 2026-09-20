using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients;

public interface ILabReportDispatchApiClient
{
    Task<LabReportDispatchResult> GetDashboardAsync(
        int branchId, DateTime? fromDate, DateTime? toDate, string dateBasis,
        string? search, string dispatchStatus, string clientType);

    Task<IEnumerable<LabReportDispatchTestDto>> GetBillTestsAsync(int labOrderId);
}
