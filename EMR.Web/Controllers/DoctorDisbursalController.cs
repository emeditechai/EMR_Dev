using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class DoctorDisbursalController(
    IDoctorCommissionApiClient apiClient,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService) : Controller
{
    private static readonly string[] ApprovalStatuses = ["NOT_ELIGIBLE", "ELIGIBLE", "CALCULATED", "SUBMITTED", "APPROVED", "ON_HOLD", "REJECTED", "ADJUSTED"];
    private static readonly string[] PaymentStatuses = ["Pending", "Paid", "Adjusted", "Reversed"];

    [HttpGet]
    public async Task<IActionResult> Index(int? doctorId, string? period, string? approvalStatus, string? paymentStatus, DateTime? fromDate, DateTime? toDate, string? search)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var companyId = User.GetCompanyId();

        try
        {
            var items = await apiClient.GetDisbursalsAsync(branchId, doctorId, period, approvalStatus, paymentStatus, fromDate, toDate, search, companyId);

            var vm = new DoctorDisbursalIndexViewModel
            {
                Items = items,
                SelectedDoctorId = doctorId,
                SelectedPeriod = period,
                SelectedApprovalStatus = approvalStatus,
                SelectedPaymentStatus = paymentStatus,
                FromDate = fromDate,
                ToDate = toDate,
                SearchTerm = search,
                DoctorOptions = await GetDoctorOptionsAsync(doctorId),
                PeriodOptions = GetPeriodOptions(period),
                ApprovalStatusOptions = GetApprovalStatusOptions(approvalStatus),
                PaymentStatusOptions = GetPaymentStatusOptions(paymentStatus)
            };

            return View(vm);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var item = await apiClient.GetDisbursalByIdAsync(id);
        if (item is null) return NotFound();

        return View(item);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Calculate(int? doctorId, DateTime? fromDate, DateTime? toDate, string? settlementPeriod)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var companyId = User.GetCompanyId();
        var userId = User.GetUserId();

        try
        {
            var count = await apiClient.CalculateDisbursalsAsync(branchId, doctorId, fromDate, toDate, settlementPeriod, userId, companyId);

            await auditLogService.LogAsync(
                "Finance",
                "DoctorDisbursal.Calculate",
                $"Calculated OPD doctor commissions. Processed {count} visits.",
                branchId: branchId);

            TempData["SuccessMessage"] = $"Commission calculation complete. {count} visit record(s) processed/refreshed.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = "Failed to calculate commissions: " + ex.Message;
        }

        return RedirectToAction(nameof(Index), new { doctorId, period = settlementPeriod });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AddAdjustment(int disbursalId, string adjustmentType, decimal adjustmentAmount, string reason)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var userId = User.GetUserId();

        if (string.IsNullOrWhiteSpace(reason))
        {
            TempData["ErrorMessage"] = "Adjustment reason is mandatory.";
            return RedirectToAction(nameof(Index));
        }

        try
        {
            var success = await apiClient.UpdateAdjustmentAsync(disbursalId, adjustmentType, adjustmentAmount, reason, userId);
            if (success)
            {
                await auditLogService.LogAsync(
                    "Finance",
                    "DoctorDisbursal.Adjustment",
                    $"Added adjustment {adjustmentType} of ₹{adjustmentAmount} to Disbursal #{disbursalId}. Reason: {reason}",
                    branchId: branchId);

                TempData["SuccessMessage"] = "Adjustment added successfully.";
            }
            else
            {
                TempData["ErrorMessage"] = "Could not apply adjustment.";
            }
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = "Adjustment error: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> UpdateStatus(int disbursalId, string approvalStatus, string? disbursalNotes)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var userId = User.GetUserId();

        try
        {
            var success = await apiClient.UpdateStatusAsync(disbursalId, approvalStatus, disbursalNotes, userId);
            if (success)
            {
                await auditLogService.LogAsync(
                    "Finance",
                    "DoctorDisbursal.UpdateStatus",
                    $"Updated Disbursal #{disbursalId} status to {approvalStatus}.",
                    branchId: branchId);

                TempData["SuccessMessage"] = $"Disbursal #{disbursalId} marked as {approvalStatus}.";
            }
            else
            {
                TempData["ErrorMessage"] = "Failed to update status.";
            }
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = "Status update error: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> BulkApprove(string disbursalIds)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var userId = User.GetUserId();

        if (string.IsNullOrWhiteSpace(disbursalIds))
        {
            TempData["ErrorMessage"] = "No disbursal records selected.";
            return RedirectToAction(nameof(Index));
        }

        try
        {
            var success = await apiClient.BulkApproveAsync(disbursalIds, userId);
            if (success)
            {
                await auditLogService.LogAsync(
                    "Finance",
                    "DoctorDisbursal.BulkApprove",
                    $"Approved disbursals: {disbursalIds}",
                    branchId: branchId);

                TempData["SuccessMessage"] = "Selected disbursal records approved successfully.";
            }
            else
            {
                TempData["ErrorMessage"] = "Failed to bulk approve disbursals.";
            }
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = "Bulk approve error: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ProcessPayout(int disbursalId, string paymentMethod, string paymentReference, DateTime? paidDate, string? disbursalNotes)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var userId = User.GetUserId();

        if (string.IsNullOrWhiteSpace(paymentReference))
        {
            TempData["ErrorMessage"] = "Payment Reference / Transaction ID is required.";
            return RedirectToAction(nameof(Index));
        }

        try
        {
            var success = await apiClient.ProcessPayoutAsync(disbursalId, paymentMethod, paymentReference, paidDate, disbursalNotes, userId);
            if (success)
            {
                await auditLogService.LogAsync(
                    "Finance",
                    "DoctorDisbursal.Payout",
                    $"Disbursed payout for Disbursal #{disbursalId} via {paymentMethod} (Ref: {paymentReference})",
                    branchId: branchId);

                TempData["SuccessMessage"] = $"Payout recorded successfully for Disbursal #{disbursalId}. Marked as PAID.";
            }
            else
            {
                TempData["ErrorMessage"] = "Failed to process payout.";
            }
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = "Payout error: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
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

    private static List<SelectListItem> GetApprovalStatusOptions(string? selected = null)
    {
        var list = ApprovalStatuses.Select(s => new SelectListItem { Value = s, Text = s, Selected = s == selected }).ToList();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- All Approval Statuses --" });
        return list;
    }

    private static List<SelectListItem> GetPaymentStatusOptions(string? selected = null)
    {
        var list = PaymentStatuses.Select(s => new SelectListItem { Value = s, Text = s, Selected = s == selected }).ToList();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- All Payment Statuses --" });
        return list;
    }
}
