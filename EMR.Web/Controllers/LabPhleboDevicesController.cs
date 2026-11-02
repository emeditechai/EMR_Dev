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
/// LAB > Phlebotomist Phones (SQLScripts/2388). The phlebotomist app sends an id it keeps on the phone; a phlebotomist's
/// first phone is approved by itself and any later one waits here. Blocked phones are refused by usp_Phlebo_Guard.
/// </summary>
[Authorize]
public class LabPhleboDevicesController(IDbConnectionFactory db, IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public IActionResult Index()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> Devices()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Fail("Select a branch first.");
        using var con = db.CreateConnection();
        var devices = await con.QueryAsync("dbo.usp_Lab_PhleboDevice_List", new { BranchId = branchId }, commandType: CommandType.StoredProcedure);
        return Json(new { success = true, devices });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Approve(int id, bool blockOthers = true) => Decide("APPROVE", id, blockOthers);

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Block(int id) => Decide("BLOCK", id, false);

    private async Task<IActionResult> Decide(string action, int id, bool blockOthers)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Fail("Select a branch first.");
        try
        {
            using var con = db.CreateConnection();
            await con.ExecuteAsync("dbo.usp_Lab_PhleboDevice_Decide",
                new { PhleboDeviceId = id, BranchId = branchId, UserId = User.GetUserId(), Action = action, BlockOthers = blockOthers },
                commandType: CommandType.StoredProcedure);
        }
        catch (SqlException ex) when (ex.Number >= 50000)
        {
            return Fail(ex.Message);
        }

        await auditLogService.LogAsync("Phlebotomist Phones", action, $"Phone #{id}: {action}{(action == "APPROVE" && blockOthers ? " (other phones blocked)" : "")}",
            User.GetUserId(), branchId.Value);
        return Json(new
        {
            success = true,
            message = action == "BLOCK" ? "Phone blocked." : blockOthers ? "Phone approved. The user's other phones are blocked." : "Phone approved."
        });
    }

    private JsonResult Fail(string message) => Json(new { success = false, message });
}
