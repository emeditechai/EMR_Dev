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
/// LAB > Home Collection Dispatch (SQLScripts/2380). The first phlebotomist is assigned on the bill page; after the bill is
/// saved, the office sees the branch's home visits here and reassigns, reschedules and closes them. A visit can be changed until the phlebotomist reaches the patient; the rules are in the
/// usp_Lab_HomeDispatch_* procedures. Closing ends the visit only: the bill stays, and cancelling it stays in Bill Cancellation.
/// </summary>
[Authorize]
public class LabHomeDispatchController(IDbConnectionFactory db, IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public IActionResult Index()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> Visits(DateTime? date, string? search)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Fail("Select a branch first.");
        using var con = db.CreateConnection();
        var visits = await con.QueryAsync("dbo.usp_Lab_HomeDispatch_List",
            new { BranchId = branchId, Date = date?.Date, Search = search }, commandType: CommandType.StoredProcedure);
        var phlebotomists = await con.QueryAsync("dbo.usp_Lab_HomeDispatch_Phlebotomists",
            new { BranchId = branchId }, commandType: CommandType.StoredProcedure);
        return Json(new { success = true, visits, phlebotomists });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Assign(int visitId, int phlebotomistId, string? reason) =>
        Run("Assign", visitId, "dbo.usp_Lab_HomeDispatch_Assign", new { PhlebotomistId = phlebotomistId, Reason = reason }, "Visit assigned.");

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Reschedule(int visitId, DateTime? slotAt, int? phlebotomistId, string? reason) =>
        Run("Reschedule", visitId, "dbo.usp_Lab_HomeDispatch_Reschedule",
            new { SlotAt = slotAt, PhlebotomistId = phlebotomistId is > 0 ? phlebotomistId : null, Reason = reason }, "Visit rescheduled.");

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Close(int visitId, string? reason) =>
        Run("Close", visitId, "dbo.usp_Lab_HomeDispatch_Close", new { Reason = reason }, "Visit closed.");

    private async Task<IActionResult> Run(string action, int visitId, string procedure, object values, string done)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Fail("Select a branch first.");

        var args = new DynamicParameters(values);
        args.Add("@VisitId", visitId);
        args.Add("@BranchId", branchId);
        args.Add("@UserId", User.GetUserId());
        try
        {
            using var con = db.CreateConnection();
            await con.ExecuteAsync(procedure, args, commandType: CommandType.StoredProcedure);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            return Fail(ex.Message);
        }

        await auditLogService.LogAsync("Home Collection Dispatch", action, $"Visit #{visitId}: {done}", User.GetUserId(), branchId.Value);
        return Json(new { success = true, message = done });
    }

    private JsonResult Fail(string message) => Json(new { success = false, message });
}
