using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients;

public interface ILabReportDispatchApiClient
{
    Task<LabReportDispatchResult> GetDashboardAsync(
        int branchId, DateTime? fromDate, DateTime? toDate, string dateBasis,
        string? search, string dispatchStatus, string clientType, int? createdBy = null);

    Task<IEnumerable<LabReportDispatchTestDto>> GetBillTestsAsync(int labOrderId);

    /// <summary>SQLScripts/2465: "print with due" state of each bill.</summary>
    Task<List<LabDuePrintStateDto>> GetDuePrintStatesAsync(IEnumerable<int> labOrderIds);

    /// <summary>SQLScripts/2465: asks the Due Report Print approvers to allow printing a bill with a due.</summary>
    Task<LabDuePrintSubmitResult> SubmitDuePrintAsync(int labOrderId, int userId, string? reason);
}
