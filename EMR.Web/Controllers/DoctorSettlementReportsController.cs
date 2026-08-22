using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class DoctorSettlementReportsController(
    IDoctorCommissionApiClient apiClient,
    ApplicationDbContext dbContext) : Controller
{
    [HttpGet]
    public IActionResult Index()
    {
        return View();
    }

    // RPT-01: Visit Payment Status
    [HttpGet]
    public async Task<IActionResult> VisitPaymentStatus(int? doctorId, DateTime? fromDate, DateTime? toDate)
    {
        var branchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();
        fromDate ??= DateTime.Today.AddDays(-30);
        toDate ??= DateTime.Today;

        var data = await apiClient.GetVisitPaymentStatusReportAsync(branchId, doctorId, fromDate, toDate, companyId);
        var vm = new VisitPaymentStatusReportViewModel
        {
            Rows = data,
            SelectedDoctorId = doctorId,
            FromDate = fromDate,
            ToDate = toDate,
            DoctorOptions = await GetDoctorOptionsAsync(doctorId)
        };
        return View(vm);
    }

    // RPT-02: Yet-to-Pay / Outstanding by Visit
    [HttpGet]
    public async Task<IActionResult> OutstandingByVisit(int? doctorId, DateTime? fromDate, DateTime? toDate)
    {
        var branchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();
        fromDate ??= DateTime.Today.AddDays(-90);
        toDate ??= DateTime.Today;

        var data = await apiClient.GetOutstandingByVisitReportAsync(branchId, doctorId, fromDate, toDate, companyId);
        var vm = new OutstandingByVisitReportViewModel
        {
            Rows = data,
            SelectedDoctorId = doctorId,
            FromDate = fromDate,
            ToDate = toDate,
            DoctorOptions = await GetDoctorOptionsAsync(doctorId)
        };
        return View(vm);
    }

    // RPT-03: Doctor Commission
    [HttpGet]
    public async Task<IActionResult> DoctorCommissionReport(int? doctorId, string? period, DateTime? fromDate, DateTime? toDate)
    {
        var branchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();

        var data = await apiClient.GetDoctorCommissionReportAsync(branchId, doctorId, period, fromDate, toDate, companyId);
        var vm = new DoctorCommissionReportViewModel
        {
            Rows = data,
            SelectedDoctorId = doctorId,
            SelectedPeriod = period,
            FromDate = fromDate,
            ToDate = toDate,
            DoctorOptions = await GetDoctorOptionsAsync(doctorId),
            PeriodOptions = GetPeriodOptions(period)
        };
        return View(vm);
    }

    // RPT-04: Doctor Disbursal Register
    [HttpGet]
    public async Task<IActionResult> DisbursalRegister(int? doctorId, string? period, string? paymentStatus, DateTime? fromDate, DateTime? toDate)
    {
        var branchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();

        var data = await apiClient.GetDoctorDisbursalRegisterAsync(branchId, doctorId, period, paymentStatus, fromDate, toDate, companyId);
        var vm = new DoctorDisbursalRegisterReportViewModel
        {
            Rows = data,
            SelectedDoctorId = doctorId,
            SelectedPeriod = period,
            SelectedPaymentStatus = paymentStatus,
            FromDate = fromDate,
            ToDate = toDate,
            DoctorOptions = await GetDoctorOptionsAsync(doctorId),
            PeriodOptions = GetPeriodOptions(period)
        };
        return View(vm);
    }

    // RPT-05: Payment Transactions
    [HttpGet]
    public async Task<IActionResult> PaymentTransactions(int? paymentMethodId, DateTime? fromDate, DateTime? toDate)
    {
        var branchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();
        fromDate ??= DateTime.Today.AddDays(-30);
        toDate ??= DateTime.Today;

        var data = await apiClient.GetPaymentTransactionsReportAsync(branchId, paymentMethodId, fromDate, toDate, companyId);
        var vm = new PaymentTransactionReportViewModel
        {
            Rows = data,
            SelectedPaymentMethodId = paymentMethodId,
            FromDate = fromDate,
            ToDate = toDate,
            PaymentMethodOptions = await GetPaymentMethodOptionsAsync(paymentMethodId)
        };
        return View(vm);
    }

    // RPT-06: Billing Adjustments
    [HttpGet]
    public async Task<IActionResult> BillingAdjustments(int? doctorId, DateTime? fromDate, DateTime? toDate)
    {
        var branchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();
        fromDate ??= DateTime.Today.AddDays(-30);
        toDate ??= DateTime.Today;

        var data = await apiClient.GetBillingAdjustmentsReportAsync(branchId, doctorId, fromDate, toDate, companyId);
        var vm = new BillingAdjustmentReportViewModel
        {
            Rows = data,
            SelectedDoctorId = doctorId,
            FromDate = fromDate,
            ToDate = toDate,
            DoctorOptions = await GetDoctorOptionsAsync(doctorId)
        };
        return View(vm);
    }

    // RPT-07: Refund / Reversal
    [HttpGet]
    public async Task<IActionResult> RefundReversals(DateTime? fromDate, DateTime? toDate)
    {
        var branchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();
        fromDate ??= DateTime.Today.AddDays(-30);
        toDate ??= DateTime.Today;

        var data = await apiClient.GetRefundReversalsReportAsync(branchId, fromDate, toDate, companyId);
        var vm = new RefundReversalReportViewModel
        {
            Rows = data,
            FromDate = fromDate,
            ToDate = toDate
        };
        return View(vm);
    }

    // RPT-08: Doctor Settlement Summary
    [HttpGet]
    public async Task<IActionResult> SettlementSummary(int? doctorId, string? period)
    {
        var branchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();

        var data = await apiClient.GetDoctorSettlementSummaryAsync(branchId, doctorId, period, companyId);
        var vm = new DoctorSettlementSummaryReportViewModel
        {
            Rows = data,
            SelectedDoctorId = doctorId,
            SelectedPeriod = period,
            DoctorOptions = await GetDoctorOptionsAsync(doctorId),
            PeriodOptions = GetPeriodOptions(period)
        };
        return View(vm);
    }

    // ── Dropdown Helpers ──────────────────────────────────────────────────────
    private async Task<List<SelectListItem>> GetDoctorOptionsAsync(int? selected = null)
    {
        var list = await dbContext.DoctorMasters.Where(d => d.IsActive)
            .OrderBy(d => d.FullName)
            .Select(d => new SelectListItem { Value = d.DoctorId.ToString(), Text = d.FullName ?? ("Doctor #" + d.DoctorId), Selected = d.DoctorId == selected })
            .ToListAsync();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- All Doctors --" });
        return list;
    }

    private static List<SelectListItem> GetPeriodOptions(string? selected = null)
    {
        var periods = new List<SelectListItem> { new() { Value = "", Text = "-- All Periods --" } };
        var now = DateTime.Today;
        for (int i = 0; i < 12; i++)
        {
            var p = now.AddMonths(-i).ToString("yyyy-MM");
            var text = now.AddMonths(-i).ToString("MMM yyyy");
            periods.Add(new SelectListItem { Value = p, Text = text, Selected = p == selected });
        }
        return periods;
    }

    private async Task<List<SelectListItem>> GetPaymentMethodOptionsAsync(int? selected = null)
    {
        var list = await dbContext.PaymentMethodMasters.Where(p => p.IsActive)
            .OrderBy(p => p.DisplayOrder)
            .Select(p => new SelectListItem { Value = p.PaymentMethodId.ToString(), Text = p.MethodName, Selected = p.PaymentMethodId == selected })
            .ToListAsync();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- All Payment Modes --" });
        return list;
    }
}
