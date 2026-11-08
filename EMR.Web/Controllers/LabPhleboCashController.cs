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
/// LAB > Phlebotomist Cash Deposit (SQLScripts/2423). Cash a phlebotomist takes at the door is held by them until they hand it
/// to the counter; the cashier records that hand-over here and Cash held in the app goes down. The rules are in the
/// usp_Lab_PhleboCash_* procedures.
/// </summary>
[Authorize]
public class LabPhleboCashController(IDbConnectionFactory db, IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public IActionResult Index()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> Data(DateTime? fromDate, DateTime? toDate, int? phlebotomistId)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Fail("Select a branch first.");
        try
        {
            using var con = db.CreateConnection();
            var phlebotomists = await con.QueryAsync("dbo.usp_Lab_PhleboCash_List",
                new { BranchId = branchId }, commandType: CommandType.StoredProcedure);
            var deposits = await con.QueryAsync("dbo.usp_Lab_PhleboCash_Deposits",
                new { BranchId = branchId, FromDate = fromDate?.Date, ToDate = toDate?.Date, PhlebotomistId = phlebotomistId is > 0 ? phlebotomistId : null },
                commandType: CommandType.StoredProcedure);
            return Json(new { success = true, phlebotomists, deposits });
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            return Fail(ex.Message);
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Deposit(int phlebotomistId, decimal amount, string? reference)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Fail("Select a branch first.");
        decimal cashHeld;
        try
        {
            using var con = db.CreateConnection();
            cashHeld = await con.ExecuteScalarAsync<decimal>("dbo.usp_Lab_PhleboCash_Deposit",
                new { BranchId = branchId, PhlebotomistId = phlebotomistId, Amount = amount, Reference = reference, UserId = User.GetUserId() },
                commandType: CommandType.StoredProcedure);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            return Fail(ex.Message);
        }

        await auditLogService.LogAsync("Phlebotomist Cash Deposit", "Deposit",
            $"Phlebotomist #{phlebotomistId}: ₹{amount:N2} deposited{(string.IsNullOrWhiteSpace(reference) ? "" : $" ({reference.Trim()})")}", User.GetUserId(), branchId.Value);
        return Json(new { success = true, message = "Deposit recorded.", cashHeld });
    }

    private JsonResult Fail(string message) => Json(new { success = false, message });
}
