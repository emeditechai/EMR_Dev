using System;
using System.Threading.Tasks;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class BillCancellationController(
    ICancellationService cancellationService,
    IAuditLogService auditLogService) : Controller
{
    // ── Dashboard Page ─────────────────────────────────────────────────────────
    [HttpGet]
    public IActionResult Index(string moduleCode = "LAB")
    {
        ViewData["Title"] = "Bill Cancellation & Refund";
        ViewBag.ModuleCode = moduleCode;
        return View();
    }

    // ── AJAX: Search Bills ─────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Search(string moduleCode, string q)
    {
        if (string.IsNullOrWhiteSpace(q) || q.Length < 2)
            return Json(new { success = false, error = "Enter at least 2 characters to search." });

        var branchId = User.GetCurrentBranchId();
        if (branchId == null)
            return Json(new { success = false, error = "Please select a branch first." });

        try
        {
            var results = await cancellationService.SearchBillsAsync(moduleCode, branchId.Value, q);
            return Json(new { success = true, data = results });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, error = ex.Message });
        }
    }

    // ── AJAX: Get Cancelled Bills (Default List) ───────────────────────────────
    [HttpGet]
    public async Task<IActionResult> GetCancelledList(string moduleCode, DateTime? fromDate, DateTime? toDate)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId == null)
            return Json(new { success = false, error = "Please select a branch first." });

        var start = fromDate ?? DateTime.Today.AddDays(-30);
        var end = toDate ?? DateTime.Today;

        try
        {
            var results = await cancellationService.GetCancelledListAsync(moduleCode, branchId.Value, start, end);
            return Json(new { success = true, data = results });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, error = ex.Message });
        }
    }

    // ── AJAX: Get Bill Detail ──────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> GetBillDetail(string moduleCode, int id)
    {
        try
        {
            var detail = await cancellationService.GetBillDetailAsync(moduleCode, id);
            if (detail == null)
                return Json(new { success = false, error = "Bill not found." });

            return Json(new { success = true, data = detail });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, error = ex.Message });
        }
    }

    // ── AJAX: Cancel Bill ──────────────────────────────────────────────────────
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CancelBill([FromBody] BillCancellationRequestDto request)
    {
        if (request == null)
            return Json(new { success = false, error = "Invalid request." });

        var branchId  = User.GetCurrentBranchId();
        var userId    = User.GetUserId();
        int companyId = 1; // default

        request.BranchId = branchId ?? request.BranchId;

        try
        {
            var result = await cancellationService.CancelBillAsync(request, userId, companyId);

            if (result.Success)
            {
                await auditLogService.LogAsync(
                    request.ModuleCode,
                    "Bill.Cancel",
                    $"Cancelled {result.CancellationType} bill {request.ModuleCode} #{request.ModuleRefId} → {result.CancellationNo}, Amount: {result.CancelledAmount:N2}"
                );
            }

            return Json(result);
        }
        catch (Exception ex)
        {
            return Json(new BillCancellationResponseDto { Success = false, Error = ex.Message });
        }
    }

    // ── AJAX: Process Refund ───────────────────────────────────────────────────
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ProcessRefund([FromBody] BillRefundRequestDto request)
    {
        if (request == null)
            return Json(new { success = false, error = "Invalid request." });

        var userId = User.GetUserId();

        try
        {
            var result = await cancellationService.ProcessRefundAsync(request, userId);

            if (result.Success)
            {
                await auditLogService.LogAsync(
                    request.ModuleCode,
                    "Bill.Refund",
                    $"Processed refund for {request.ModuleCode} #{request.ModuleRefId}: ₹{result.RefundAmount:N2} via {result.RefundMode}"
                );
            }

            return Json(result);
        }
        catch (Exception ex)
        {
            return Json(new BillRefundResponseDto { Success = false, Error = ex.Message });
        }
    }

    // ── AJAX: Get History ──────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> GetHistory(string moduleCode, int id)
    {
        try
        {
            var history = await cancellationService.GetCancellationHistoryAsync(moduleCode, id);
            return Json(new { success = true, data = history });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, error = ex.Message });
        }
    }
}
