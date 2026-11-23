using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabReportDispatchService
{
    Task<LabReportDispatchResult> GetDashboardAsync(
        int branchId, DateTime? fromDate, DateTime? toDate, string? dateBasis,
        string? search, string? dispatchStatus, string? clientType, int? createdBy = null);

    Task<IEnumerable<LabReportDispatchTestDto>> GetBillTestsAsync(int labOrderId);

    /// <summary>SQLScripts/2465: "print with due" state of each bill.</summary>
    Task<List<LabDuePrintStateDto>> GetDuePrintStatesAsync(IEnumerable<int> labOrderIds);

    /// <summary>SQLScripts/2465: asks the Due Report Print approvers to allow printing a bill with a due.</summary>
    Task<LabDuePrintSubmitResult> SubmitDuePrintAsync(LabDuePrintSubmitRequest request);
}
