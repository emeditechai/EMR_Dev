using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EMR.Web.Controllers;

/// <summary>
/// LAB > Bill Change Approval (SQLScripts/2381). The phlebotomist raises a bill change at the patient's address; the office decides it here.
/// Test changes and discounts are applied to the bill by dbo.usp_Lab_BillChange_Decide. Payment mode and patient details are recorded as
/// approved only, and the office changes them on its usual screen. Any refund stays in Bill Cancellation.
/// </summary>
[Authorize]
public class LabBillChangeApprovalController(IDbConnectionFactory db, IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public IActionResult Index()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> Requests()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Fail("Select a branch first.");
        using var con = db.CreateConnection();
        var requests = await con.QueryAsync("dbo.usp_Lab_BillChange_List", new { BranchId = branchId }, commandType: CommandType.StoredProcedure);
        return Json(new { success = true, requests });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Approve(int id, decimal? discountAmount, string? remarks) => Decide("APPROVE", id, discountAmount, remarks);

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Refuse(int id, string? remarks) => Decide("REFUSE", id, null, remarks);

    private async Task<IActionResult> Decide(string action, int id, decimal? discountAmount, string? remarks)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Fail("Select a branch first.");

        dynamic? result = null;
        try
        {
            using var con = db.CreateConnection();
            using var grid = await con.QueryMultipleAsync("dbo.usp_Lab_BillChange_Decide",
                new { BillChangeId = id, BranchId = branchId, UserId = User.GetUserId(), Action = action, Remarks = remarks, DiscountAmount = discountAmount },
                commandType: CommandType.StoredProcedure);
            while (!grid.IsConsumed) result = (await grid.ReadAsync()).LastOrDefault();
        }
        catch (SqlException ex) when (ex.Number >= 50000)
        {
            return Fail(ex.Message);
        }

        await auditLogService.LogAsync("Bill Change Approval", action, $"Bill change #{id}: {action}", User.GetUserId(), branchId.Value);

        var message = (string?)result?.Status switch
        {
            "REFUSED" => "Request refused.",
            "APPROVED" => "Approved. Make this change on its usual screen.",
            _ => $"Bill updated. New total Rs {result?.NewTotal:N2}, balance due Rs {result?.BalanceDue:N2}."
        };
        if (result?.Refundable > 0m) message += $" Refund Rs {result?.Refundable:N2} from Bill Cancellation.";
        return Json(new { success = true, message });
    }

    private JsonResult Fail(string message) => Json(new { success = false, message });
}
