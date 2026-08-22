using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/reports/doctor-settlement")]
[Produces("application/json")]
public class DoctorSettlementReportsController(IDoctorCommissionService service) : ControllerBase
{
    // RPT-01: Visit Payment Status
    [HttpGet("visit-payment-status")]
    public async Task<IActionResult> GetVisitPaymentStatus(
        [FromQuery] int? branchId = null,
        [FromQuery] int? doctorId = null,
        [FromQuery] DateTime? fromDate = null,
        [FromQuery] DateTime? toDate = null,
        [FromQuery] int? companyId = null)
    {
        var data = await service.GetVisitPaymentStatusReportAsync(branchId, doctorId, fromDate, toDate, companyId);
        return Ok(ApiResponse<IEnumerable<VisitPaymentStatusReportItemDto>>.Ok(data));
    }

    // RPT-02: Yet-to-Pay / Outstanding by Visit
    [HttpGet("outstanding-by-visit")]
    public async Task<IActionResult> GetOutstandingByVisit(
        [FromQuery] int? branchId = null,
        [FromQuery] int? doctorId = null,
        [FromQuery] DateTime? fromDate = null,
        [FromQuery] DateTime? toDate = null,
        [FromQuery] int? companyId = null)
    {
        var data = await service.GetOutstandingByVisitReportAsync(branchId, doctorId, fromDate, toDate, companyId);
        return Ok(ApiResponse<IEnumerable<OutstandingByVisitReportItemDto>>.Ok(data));
    }

    // RPT-03: Doctor Commission
    [HttpGet("doctor-commission")]
    public async Task<IActionResult> GetDoctorCommission(
        [FromQuery] int? branchId = null,
        [FromQuery] int? doctorId = null,
        [FromQuery] string? settlementPeriod = null,
        [FromQuery] DateTime? fromDate = null,
        [FromQuery] DateTime? toDate = null,
        [FromQuery] int? companyId = null)
    {
        var data = await service.GetDoctorCommissionReportAsync(branchId, doctorId, settlementPeriod, fromDate, toDate, companyId);
        return Ok(ApiResponse<IEnumerable<DoctorCommissionReportItemDto>>.Ok(data));
    }

    // RPT-04: Doctor Disbursal Register
    [HttpGet("disbursal-register")]
    public async Task<IActionResult> GetDisbursalRegister(
        [FromQuery] int? branchId = null,
        [FromQuery] int? doctorId = null,
        [FromQuery] string? settlementPeriod = null,
        [FromQuery] string? paymentStatus = null,
        [FromQuery] DateTime? fromDate = null,
        [FromQuery] DateTime? toDate = null,
        [FromQuery] int? companyId = null)
    {
        var data = await service.GetDoctorDisbursalRegisterAsync(branchId, doctorId, settlementPeriod, paymentStatus, fromDate, toDate, companyId);
        return Ok(ApiResponse<IEnumerable<DoctorDisbursalRegisterItemDto>>.Ok(data));
    }

    // RPT-05: Payment Transactions
    [HttpGet("payment-transactions")]
    public async Task<IActionResult> GetPaymentTransactions(
        [FromQuery] int? branchId = null,
        [FromQuery] int? paymentMethodId = null,
        [FromQuery] DateTime? fromDate = null,
        [FromQuery] DateTime? toDate = null,
        [FromQuery] int? companyId = null)
    {
        var data = await service.GetPaymentTransactionsReportAsync(branchId, paymentMethodId, fromDate, toDate, companyId);
        return Ok(ApiResponse<IEnumerable<PaymentTransactionReportItemDto>>.Ok(data));
    }

    // RPT-06: Billing Adjustments
    [HttpGet("billing-adjustments")]
    public async Task<IActionResult> GetBillingAdjustments(
        [FromQuery] int? branchId = null,
        [FromQuery] int? doctorId = null,
        [FromQuery] DateTime? fromDate = null,
        [FromQuery] DateTime? toDate = null,
        [FromQuery] int? companyId = null)
    {
        var data = await service.GetBillingAdjustmentsReportAsync(branchId, doctorId, fromDate, toDate, companyId);
        return Ok(ApiResponse<IEnumerable<BillingAdjustmentReportItemDto>>.Ok(data));
    }

    // RPT-07: Refund / Reversal
    [HttpGet("refund-reversals")]
    public async Task<IActionResult> GetRefundReversals(
        [FromQuery] int? branchId = null,
        [FromQuery] DateTime? fromDate = null,
        [FromQuery] DateTime? toDate = null,
        [FromQuery] int? companyId = null)
    {
        var data = await service.GetRefundReversalsReportAsync(branchId, fromDate, toDate, companyId);
        return Ok(ApiResponse<IEnumerable<RefundReversalReportItemDto>>.Ok(data));
    }

    // RPT-08: Doctor Settlement Summary
    [HttpGet("settlement-summary")]
    public async Task<IActionResult> GetSettlementSummary(
        [FromQuery] int? branchId = null,
        [FromQuery] int? doctorId = null,
        [FromQuery] string? settlementPeriod = null,
        [FromQuery] int? companyId = null)
    {
        var data = await service.GetDoctorSettlementSummaryAsync(branchId, doctorId, settlementPeriod, companyId);
        return Ok(ApiResponse<IEnumerable<DoctorSettlementSummaryItemDto>>.Ok(data));
    }
}
