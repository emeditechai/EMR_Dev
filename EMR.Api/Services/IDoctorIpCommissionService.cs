using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IDoctorIpCommissionService
{
    Task<IEnumerable<DoctorIpCommissionPendingItem>> GetPendingAsync(int branchId, int? doctorId, DateTime? fromDate, DateTime? toDate, int? companyId);
    Task<IEnumerable<DoctorIpCommissionCalculateResult>> CalculateAsync(DoctorIpCommissionCalculateRequest req);
    Task<IEnumerable<DoctorIpCommissionListItem>> GetListAsync(int? branchId, int? doctorId, DateTime? fromDate, DateTime? toDate, int? companyId);
    Task<DoctorIpCommissionDetail?> GetDetailAsync(long commissionHdrId);
    Task<IEnumerable<DoctorIpCommissionDueSchedule>> GetDueSchedulesAsync(DateTime today, int? branchId = null);
    Task<IEnumerable<DoctorIpCommissionDueBranch>> GetDueBranchesAsync(DateTime now);
    Task<long?> StartRunAsync(int branchId, DateTime runDate);
    Task FinishRunAsync(long runId, int schedulesDue, int itemsComputed, decimal totalCommission, int failedCount, string? message);
}
