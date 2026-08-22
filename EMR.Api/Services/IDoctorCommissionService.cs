using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IDoctorCommissionService
{
    // 1. Visit Process Config
    Task<IEnumerable<DoctorVisitProcessConfigDto>> GetProcessConfigsAsync(
        int? branchId = null, int? specialityId = null, int? doctorId = null,
        string? visitType = null, bool? isActive = null, string? search = null, int? companyId = null);
    Task<DoctorVisitProcessConfigDto?> GetProcessConfigByIdAsync(int id);
    Task<int> SaveProcessConfigAsync(DoctorVisitProcessConfigSaveRequest request);
    Task<bool> DeleteProcessConfigAsync(int id);

    // 2. Doctor Commission Config
    Task<IEnumerable<DoctorCommissionConfigDto>> GetCommissionConfigsAsync(
        int? branchId = null, int? doctorId = null, int? specialityId = null,
        string? revenueType = null, bool? isActive = null, string? search = null, int? companyId = null);
    Task<DoctorCommissionConfigDto?> GetCommissionConfigByIdAsync(int id);
    Task<int> SaveCommissionConfigAsync(DoctorCommissionConfigSaveRequest request);
    Task<bool> DeleteCommissionConfigAsync(int id);

    // 3. Doctor Disbursal Workbench
    Task<IEnumerable<DoctorDisbursalDto>> GetDisbursalsAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null,
        string? approvalStatus = null, string? paymentStatus = null,
        DateTime? fromDate = null, DateTime? toDate = null, string? search = null, int? companyId = null);
    Task<DoctorDisbursalDetailDto?> GetDisbursalByIdAsync(int id);
    Task<int> CalculateDisbursalsAsync(DoctorDisbursalCalculateRequest request);
    Task<bool> UpdateAdjustmentAsync(DoctorDisbursalAdjustmentRequest request);
    Task<bool> UpdateStatusAsync(DoctorDisbursalStatusRequest request);
    Task<bool> BulkApproveAsync(DoctorDisbursalBulkApproveRequest request);
    Task<bool> ProcessPayoutAsync(DoctorDisbursalPayoutRequest request);

    // 4. Financial Reports (RPT-01 to RPT-08)
    Task<IEnumerable<VisitPaymentStatusReportItemDto>> GetVisitPaymentStatusReportAsync(
        int? branchId = null, int? doctorId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null);
    Task<IEnumerable<OutstandingByVisitReportItemDto>> GetOutstandingByVisitReportAsync(
        int? branchId = null, int? doctorId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null);
    Task<IEnumerable<DoctorCommissionReportItemDto>> GetDoctorCommissionReportAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null);
    Task<IEnumerable<DoctorDisbursalRegisterItemDto>> GetDoctorDisbursalRegisterAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null, string? paymentStatus = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null);
    Task<IEnumerable<PaymentTransactionReportItemDto>> GetPaymentTransactionsReportAsync(
        int? branchId = null, int? paymentMethodId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null);
    Task<IEnumerable<BillingAdjustmentReportItemDto>> GetBillingAdjustmentsReportAsync(
        int? branchId = null, int? doctorId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null);
    Task<IEnumerable<RefundReversalReportItemDto>> GetRefundReversalsReportAsync(
        int? branchId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null);
    Task<IEnumerable<DoctorSettlementSummaryItemDto>> GetDoctorSettlementSummaryAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null, int? companyId = null);
}
