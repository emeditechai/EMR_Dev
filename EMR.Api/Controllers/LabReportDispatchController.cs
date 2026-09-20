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
        [FromQuery] string? clientType = "ALL")
    {
        if (branchId <= 0) return BadRequest(new { message = "BranchId is required." });

        var result = await service.GetDashboardAsync(branchId, fromDate, toDate, dateBasis, search, dispatchStatus, clientType);
        return Ok(result);
    }

    [HttpGet("bill-tests/{labOrderId:int}")]
    public async Task<IActionResult> GetBillTests(int labOrderId)
    {
        if (labOrderId <= 0) return BadRequest(new { message = "Valid LabOrderId is required." });

        return Ok(await service.GetBillTestsAsync(labOrderId));
    }
}
