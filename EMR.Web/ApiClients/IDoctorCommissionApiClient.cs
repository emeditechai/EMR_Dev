using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IDoctorCommissionApiClient
{
    // 1. Visit Process Config
    Task<IEnumerable<DoctorVisitProcessConfigListItemViewModel>> GetProcessConfigsAsync(
        int? branchId = null, int? specialityId = null, int? doctorId = null,
        string? visitType = null, bool? isActive = null, string? search = null, int? companyId = null);
    Task<DoctorVisitProcessConfigFormViewModel?> GetProcessConfigByIdAsync(int id);
    Task<int> SaveProcessConfigAsync(DoctorVisitProcessConfigFormViewModel model, int? userId);
    Task<bool> DeleteProcessConfigAsync(int id);

    // 2. Doctor Commission Config
    Task<IEnumerable<DoctorCommissionConfigListItemViewModel>> GetCommissionConfigsAsync(
        int? branchId = null, int? doctorId = null, int? specialityId = null,
        string? revenueType = null, bool? isActive = null, string? search = null, int? companyId = null);
    Task<DoctorCommissionConfigFormViewModel?> GetCommissionConfigByIdAsync(int id);
    Task<int> SaveCommissionConfigAsync(DoctorCommissionConfigFormViewModel model, int? userId);
    Task<bool> DeleteCommissionConfigAsync(int id);

    // 3. Doctor Disbursal Workbench
    Task<IEnumerable<DoctorDisbursalListItemViewModel>> GetDisbursalsAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null,
        string? approvalStatus = null, string? paymentStatus = null,
        DateTime? fromDate = null, DateTime? toDate = null, string? search = null, int? companyId = null);
    Task<DoctorDisbursalDetailsViewModel?> GetDisbursalByIdAsync(int id);
    Task<int> CalculateDisbursalsAsync(int branchId, int? doctorId, DateTime? fromDate, DateTime? toDate, string? settlementPeriod, int? userId, int companyId);
    Task<bool> UpdateAdjustmentAsync(int disbursalId, string adjustmentType, decimal adjustmentAmount, string reason, int? userId);
    Task<bool> UpdateStatusAsync(int disbursalId, string approvalStatus, string? disbursalNotes, int? userId);
    Task<bool> BulkApproveAsync(string disbursalIds, int? userId);
    Task<bool> ProcessPayoutAsync(int disbursalId, string paymentMethod, string paymentReference, DateTime? paidDate, string? disbursalNotes, int? userId);

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
