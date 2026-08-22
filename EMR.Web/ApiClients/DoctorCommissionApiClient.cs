using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class DoctorCommissionApiClient(IHttpClientFactory factory) : IDoctorCommissionApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    // 1. Visit Process Config
    public async Task<IEnumerable<DoctorVisitProcessConfigListItemViewModel>> GetProcessConfigsAsync(
        int? branchId = null, int? specialityId = null, int? doctorId = null,
        string? visitType = null, bool? isActive = null, string? search = null, int? companyId = null)
    {
        var q = new List<string>();
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (specialityId.HasValue) q.Add($"specialityId={specialityId.Value}");
        if (doctorId.HasValue) q.Add($"doctorId={doctorId.Value}");
        if (!string.IsNullOrWhiteSpace(visitType)) q.Add($"visitType={Uri.EscapeDataString(visitType)}");
        if (isActive.HasValue) q.Add($"isActive={isActive.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) q.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var url = "api/doctor-visit-process-configs" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
        var res = await _http.GetFromJsonAsync<ApiResponse<List<DoctorVisitProcessConfigListItemViewModel>>>(url);
        return res?.Data ?? [];
    }

    public async Task<DoctorVisitProcessConfigFormViewModel?> GetProcessConfigByIdAsync(int id)
    {
        var res = await _http.GetFromJsonAsync<ApiResponse<DoctorVisitProcessConfigFormViewModel>>($"api/doctor-visit-process-configs/{id}");
        return res?.Data;
    }

    public async Task<int> SaveProcessConfigAsync(DoctorVisitProcessConfigFormViewModel model, int? userId)
    {
        var payload = new
        {
            model.ProcessConfigId,
            model.CompanyId,
            model.BranchId,
            model.SpecialityId,
            model.DoctorId,
            model.VisitType,
            model.PaymentTiming,
            model.VitalsRequired,
            model.DiagnosisRequired,
            model.Icd10Required,
            model.ProcedureAllowed,
            model.BillingRequired,
            model.PaymentBeforeClosure,
            model.EffectiveFrom,
            model.EffectiveTo,
            model.IsActive,
            UserId = userId
        };

        var res = await _http.PostAsJsonAsync("api/doctor-visit-process-configs", payload);
        res.EnsureSuccessStatusCode();
        var result = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> DeleteProcessConfigAsync(int id)
    {
        var res = await _http.DeleteAsync($"api/doctor-visit-process-configs/{id}");
        return res.IsSuccessStatusCode;
    }

    // 2. Doctor Commission Config
    public async Task<IEnumerable<DoctorCommissionConfigListItemViewModel>> GetCommissionConfigsAsync(
        int? branchId = null, int? doctorId = null, int? specialityId = null,
        string? revenueType = null, bool? isActive = null, string? search = null, int? companyId = null)
    {
        var q = new List<string>();
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (doctorId.HasValue) q.Add($"doctorId={doctorId.Value}");
        if (specialityId.HasValue) q.Add($"specialityId={specialityId.Value}");
        if (!string.IsNullOrWhiteSpace(revenueType)) q.Add($"revenueType={Uri.EscapeDataString(revenueType)}");
        if (isActive.HasValue) q.Add($"isActive={isActive.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) q.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var url = "api/doctor-commission-configs" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
        var res = await _http.GetFromJsonAsync<ApiResponse<List<DoctorCommissionConfigListItemViewModel>>>(url);
        return res?.Data ?? [];
    }

    public async Task<DoctorCommissionConfigFormViewModel?> GetCommissionConfigByIdAsync(int id)
    {
        var res = await _http.GetFromJsonAsync<ApiResponse<DoctorCommissionConfigFormViewModel>>($"api/doctor-commission-configs/{id}");
        return res?.Data;
    }

    public async Task<int> SaveCommissionConfigAsync(DoctorCommissionConfigFormViewModel model, int? userId)
    {
        var payload = new
        {
            model.CommissionConfigId,
            model.CompanyId,
            model.BranchId,
            model.DoctorId,
            model.SpecialityId,
            model.RevenueType,
            model.CalculationType,
            model.CommissionBasis,
            model.DoctorShare,
            model.ProcedureId,
            model.ServiceId,
            model.CorporateId,
            model.InsuranceTPAId,
            model.ApprovalRequired,
            model.EffectiveFrom,
            model.EffectiveTo,
            model.IsActive,
            UserId = userId
        };

        var res = await _http.PostAsJsonAsync("api/doctor-commission-configs", payload);
        res.EnsureSuccessStatusCode();
        var result = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> DeleteCommissionConfigAsync(int id)
    {
        var res = await _http.DeleteAsync($"api/doctor-commission-configs/{id}");
        return res.IsSuccessStatusCode;
    }

    // 3. Doctor Disbursal Workbench
    public async Task<IEnumerable<DoctorDisbursalListItemViewModel>> GetDisbursalsAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null,
        string? approvalStatus = null, string? paymentStatus = null,
        DateTime? fromDate = null, DateTime? toDate = null, string? search = null, int? companyId = null)
    {
        var q = new List<string>();
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (doctorId.HasValue) q.Add($"doctorId={doctorId.Value}");
        if (!string.IsNullOrWhiteSpace(settlementPeriod)) q.Add($"settlementPeriod={Uri.EscapeDataString(settlementPeriod)}");
        if (!string.IsNullOrWhiteSpace(approvalStatus)) q.Add($"approvalStatus={Uri.EscapeDataString(approvalStatus)}");
        if (!string.IsNullOrWhiteSpace(paymentStatus)) q.Add($"paymentStatus={Uri.EscapeDataString(paymentStatus)}");
        if (fromDate.HasValue) q.Add($"fromDate={fromDate.Value:yyyy-MM-dd}");
        if (toDate.HasValue) q.Add($"toDate={toDate.Value:yyyy-MM-dd}");
        if (!string.IsNullOrWhiteSpace(search)) q.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var url = "api/doctor-disbursals" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
        var res = await _http.GetFromJsonAsync<ApiResponse<List<DoctorDisbursalListItemViewModel>>>(url);
        return res?.Data ?? [];
    }

    public async Task<DoctorDisbursalDetailsViewModel?> GetDisbursalByIdAsync(int id)
    {
        var res = await _http.GetFromJsonAsync<ApiResponse<DoctorDisbursalDetailsViewModel>>($"api/doctor-disbursals/{id}");
        return res?.Data;
    }

    public async Task<int> CalculateDisbursalsAsync(int branchId, int? doctorId, DateTime? fromDate, DateTime? toDate, string? settlementPeriod, int? userId, int companyId)
    {
        var payload = new
        {
            BranchId = branchId,
            DoctorId = doctorId,
            FromDate = fromDate,
            ToDate = toDate,
            SettlementPeriod = settlementPeriod,
            UserId = userId,
            CompanyId = companyId
        };

        var res = await _http.PostAsJsonAsync("api/doctor-disbursals/calculate", payload);
        res.EnsureSuccessStatusCode();
        var result = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateAdjustmentAsync(int disbursalId, string adjustmentType, decimal adjustmentAmount, string reason, int? userId)
    {
        var payload = new
        {
            DisbursalId = disbursalId,
            AdjustmentType = adjustmentType,
            AdjustmentAmount = adjustmentAmount,
            Reason = reason,
            UserId = userId
        };

        var res = await _http.PostAsJsonAsync("api/doctor-disbursals/adjustment", payload);
        return res.IsSuccessStatusCode;
    }

    public async Task<bool> UpdateStatusAsync(int disbursalId, string approvalStatus, string? disbursalNotes, int? userId)
    {
        var payload = new
        {
            DisbursalId = disbursalId,
            ApprovalStatus = approvalStatus,
            DisbursalNotes = disbursalNotes,
            UserId = userId
        };

        var res = await _http.PostAsJsonAsync("api/doctor-disbursals/status", payload);
        return res.IsSuccessStatusCode;
    }

    public async Task<bool> BulkApproveAsync(string disbursalIds, int? userId)
    {
        var payload = new
        {
            DisbursalIds = disbursalIds,
            UserId = userId
        };

        var res = await _http.PostAsJsonAsync("api/doctor-disbursals/bulk-approve", payload);
        return res.IsSuccessStatusCode;
    }

    public async Task<bool> ProcessPayoutAsync(int disbursalId, string paymentMethod, string paymentReference, DateTime? paidDate, string? disbursalNotes, int? userId)
    {
        var payload = new
        {
            DisbursalId = disbursalId,
            PaymentMethod = paymentMethod,
            PaymentReference = paymentReference,
            PaidDate = paidDate,
            DisbursalNotes = disbursalNotes,
            UserId = userId
        };

        var res = await _http.PostAsJsonAsync("api/doctor-disbursals/payout", payload);
        return res.IsSuccessStatusCode;
    }

    // 4. Financial Reports (RPT-01 to RPT-08)
    public async Task<IEnumerable<VisitPaymentStatusReportItemDto>> GetVisitPaymentStatusReportAsync(
        int? branchId = null, int? doctorId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        var q = new List<string>();
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (doctorId.HasValue) q.Add($"doctorId={doctorId.Value}");
        if (fromDate.HasValue) q.Add($"fromDate={fromDate.Value:yyyy-MM-dd}");
        if (toDate.HasValue) q.Add($"toDate={toDate.Value:yyyy-MM-dd}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var url = "api/reports/doctor-settlement/visit-payment-status" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
        var res = await _http.GetFromJsonAsync<ApiResponse<List<VisitPaymentStatusReportItemDto>>>(url);
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<OutstandingByVisitReportItemDto>> GetOutstandingByVisitReportAsync(
        int? branchId = null, int? doctorId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        var q = new List<string>();
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (doctorId.HasValue) q.Add($"doctorId={doctorId.Value}");
        if (fromDate.HasValue) q.Add($"fromDate={fromDate.Value:yyyy-MM-dd}");
        if (toDate.HasValue) q.Add($"toDate={toDate.Value:yyyy-MM-dd}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var url = "api/reports/doctor-settlement/outstanding-by-visit" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
        var res = await _http.GetFromJsonAsync<ApiResponse<List<OutstandingByVisitReportItemDto>>>(url);
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<DoctorCommissionReportItemDto>> GetDoctorCommissionReportAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        var q = new List<string>();
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (doctorId.HasValue) q.Add($"doctorId={doctorId.Value}");
        if (!string.IsNullOrWhiteSpace(settlementPeriod)) q.Add($"settlementPeriod={Uri.EscapeDataString(settlementPeriod)}");
        if (fromDate.HasValue) q.Add($"fromDate={fromDate.Value:yyyy-MM-dd}");
        if (toDate.HasValue) q.Add($"toDate={toDate.Value:yyyy-MM-dd}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var url = "api/reports/doctor-settlement/doctor-commission" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
        var res = await _http.GetFromJsonAsync<ApiResponse<List<DoctorCommissionReportItemDto>>>(url);
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<DoctorDisbursalRegisterItemDto>> GetDoctorDisbursalRegisterAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null, string? paymentStatus = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        var q = new List<string>();
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (doctorId.HasValue) q.Add($"doctorId={doctorId.Value}");
        if (!string.IsNullOrWhiteSpace(settlementPeriod)) q.Add($"settlementPeriod={Uri.EscapeDataString(settlementPeriod)}");
        if (!string.IsNullOrWhiteSpace(paymentStatus)) q.Add($"paymentStatus={Uri.EscapeDataString(paymentStatus)}");
        if (fromDate.HasValue) q.Add($"fromDate={fromDate.Value:yyyy-MM-dd}");
        if (toDate.HasValue) q.Add($"toDate={toDate.Value:yyyy-MM-dd}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var url = "api/reports/doctor-settlement/disbursal-register" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
        var res = await _http.GetFromJsonAsync<ApiResponse<List<DoctorDisbursalRegisterItemDto>>>(url);
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<PaymentTransactionReportItemDto>> GetPaymentTransactionsReportAsync(
        int? branchId = null, int? paymentMethodId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        var q = new List<string>();
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (paymentMethodId.HasValue) q.Add($"paymentMethodId={paymentMethodId.Value}");
        if (fromDate.HasValue) q.Add($"fromDate={fromDate.Value:yyyy-MM-dd}");
        if (toDate.HasValue) q.Add($"toDate={toDate.Value:yyyy-MM-dd}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var url = "api/reports/doctor-settlement/payment-transactions" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
        var res = await _http.GetFromJsonAsync<ApiResponse<List<PaymentTransactionReportItemDto>>>(url);
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<BillingAdjustmentReportItemDto>> GetBillingAdjustmentsReportAsync(
        int? branchId = null, int? doctorId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        var q = new List<string>();
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (doctorId.HasValue) q.Add($"doctorId={doctorId.Value}");
        if (fromDate.HasValue) q.Add($"fromDate={fromDate.Value:yyyy-MM-dd}");
        if (toDate.HasValue) q.Add($"toDate={toDate.Value:yyyy-MM-dd}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var url = "api/reports/doctor-settlement/billing-adjustments" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
        var res = await _http.GetFromJsonAsync<ApiResponse<List<BillingAdjustmentReportItemDto>>>(url);
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<RefundReversalReportItemDto>> GetRefundReversalsReportAsync(
        int? branchId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        var q = new List<string>();
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (fromDate.HasValue) q.Add($"fromDate={fromDate.Value:yyyy-MM-dd}");
        if (toDate.HasValue) q.Add($"toDate={toDate.Value:yyyy-MM-dd}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var url = "api/reports/doctor-settlement/refund-reversals" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
        var res = await _http.GetFromJsonAsync<ApiResponse<List<RefundReversalReportItemDto>>>(url);
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<DoctorSettlementSummaryItemDto>> GetDoctorSettlementSummaryAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null, int? companyId = null)
    {
        var q = new List<string>();
        if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
        if (doctorId.HasValue) q.Add($"doctorId={doctorId.Value}");
        if (!string.IsNullOrWhiteSpace(settlementPeriod)) q.Add($"settlementPeriod={Uri.EscapeDataString(settlementPeriod)}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var url = "api/reports/doctor-settlement/settlement-summary" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
        var res = await _http.GetFromJsonAsync<ApiResponse<List<DoctorSettlementSummaryItemDto>>>(url);
        return res?.Data ?? [];
    }
}
