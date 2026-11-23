using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Lab Report Dispatch dashboard: bill wise report readiness / print status.</summary>
[ApiController]
[Route("api/lab-report-dispatch")]
public class LabReportDispatchController(ILabReportDispatchService service) : ControllerBase
{
    [HttpGet("dashboard")]
    public async Task<IActionResult> GetDashboard(
        [FromQuery] int branchId,
        [FromQuery] DateTime? fromDate,
        [FromQuery] DateTime? toDate,
        [FromQuery] string? dateBasis = "BillingDate",
        [FromQuery] string? search = null,
        [FromQuery] string? dispatchStatus = "ALL",
        [FromQuery] string? clientType = "ALL",
        [FromQuery] int? createdBy = null)
    {
        if (branchId <= 0) return BadRequest(new { message = "BranchId is required." });

        var result = await service.GetDashboardAsync(branchId, fromDate, toDate, dateBasis, search, dispatchStatus, clientType, createdBy);
        return Ok(result);
    }

    [HttpGet("bill-tests/{labOrderId:int}")]
    public async Task<IActionResult> GetBillTests(int labOrderId)
    {
        if (labOrderId <= 0) return BadRequest(new { message = "Valid LabOrderId is required." });

        return Ok(await service.GetBillTestsAsync(labOrderId));
    }

    /// <summary>SQLScripts/2465: "print with due" state of bills (ids comma-separated).</summary>
    [HttpGet("due-print/states")]
    public async Task<IActionResult> GetDuePrintStates([FromQuery] string? ids)
    {
        var list = (ids ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries)
            .Select(s => int.TryParse(s, out var v) ? v : 0).Where(v => v > 0);
        return Ok(await service.GetDuePrintStatesAsync(list));
    }

    /// <summary>SQLScripts/2465: request approval to print the report of a bill with a due.</summary>
    [HttpPost("due-print/submit")]
    public async Task<IActionResult> SubmitDuePrint([FromBody] LabDuePrintSubmitRequest request)
    {
        if (request.LabOrderId <= 0 || request.UserId <= 0) return BadRequest(new { message = "LabOrderId and UserId are required." });
        return Ok(await service.SubmitDuePrintAsync(request));
    }
}
