using System;
using System.Threading.Tasks;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace EMR.Web.Controllers;

[Authorize]
public class BillCancellationController(
    ICancellationService cancellationService,
    IAuditLogService auditLogService,
    IActionPermissionGuard permissionGuard) : Controller
{
    // One screen serves both modules (LAB / OPD Bill Cancellation pages), so every action is also checked against
    // the page of the module it works on - the endpoint map alone would let the LAB page's rights reach OPD bills.
    public override async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        var action = context.ActionDescriptor.RouteValues["action"];
        string? moduleCode = context.ActionArguments.TryGetValue("moduleCode", out var m) ? m as string : null;
        if (context.ActionArguments.TryGetValue("request", out var r))
            moduleCode = (r as BillCancellationRequestDto)?.ModuleCode ?? (r as BillRefundRequestDto)?.ModuleCode ?? moduleCode;

        var page = string.Equals(moduleCode, "OPD", StringComparison.OrdinalIgnoreCase) ? "OPD.BILLCANCELLATION.OPD" : "LAB.BILLCANCELLATION.LAB";
        var control = action switch
        {
            nameof(CancelBill) => PermissionControls.Cancel,
            nameof(ProcessRefund) => PermissionControls.Refund,
            _ => PermissionControls.View
        };

        if (!await permissionGuard.AllowsAsync(HttpContext, page, control))
        {
            context.Result = action == nameof(Index)
                ? RedirectToAction("AccessDenied", "Account", new { returnUrl = Request.Path + Request.QueryString, page, control })
                : new ObjectResult(new { success = false, code = "FORBIDDEN", error = PermissionFilter.DeniedMessage, message = PermissionFilter.DeniedMessage, page, control })
                  { StatusCode = StatusCodes.Status403Forbidden };
            return;
        }

        await next();
    }

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
                var modCode = string.IsNullOrWhiteSpace(request.ModuleCode) ? "BILLING" : request.ModuleCode.ToUpperInvariant();
                await auditLogService.LogActivityAsync(
                    eventType: "Bill Cancellation",
                    actionName: $"{modCode}.BillCancelled",
                    description: $"Cancelled {result.CancellationType} {modCode} Bill (Ref #{request.ModuleRefId}) → Cancellation No: {result.CancellationNo}, Amount: ₹{result.CancelledAmount:F2}, Reason: {request.Reason}.",
                    userId: userId,
                    branchId: branchId,
                    moduleCode: modCode,
                    referenceNo: result.CancellationNo ?? request.ModuleRefId.ToString(),
                    referenceId: request.ModuleRefId,
                    metadata: new {
                        ModuleCode = modCode,
                        request.ModuleRefId,
                        result.CancellationNo,
                        result.CancelledAmount,
                        result.CancellationType,
                        request.Reason,
                        request.AcknowledgeLabWarnings
                    }
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
                var modCode = string.IsNullOrWhiteSpace(request.ModuleCode) ? "BILLING" : request.ModuleCode.ToUpperInvariant();
                await auditLogService.LogActivityAsync(
                    eventType: "Bill Refund",
                    actionName: $"{modCode}.BillRefunded",
                    description: $"Processed refund for {modCode} Bill (Ref #{request.ModuleRefId}): ₹{result.RefundAmount:F2} via {result.RefundMode ?? request.RefundMode}. Notes: {request.Notes ?? "Standard Refund"}.",
                    userId: userId,
                    branchId: User.GetCurrentBranchId(),
                    moduleCode: modCode,
                    referenceNo: request.ModuleRefId.ToString(),
                    referenceId: request.ModuleRefId,
                    metadata: new {
                        ModuleCode = modCode,
                        request.ModuleRefId,
                        result.RefundAmount,
                        result.RefundMode,
                        request.Notes
                    }
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
