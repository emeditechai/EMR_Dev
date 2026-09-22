using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Un-Authorize Report: withdraw the approval of tests so their result can be corrected on the Entry page.</summary>
[ApiController]
[Route("api/lab-unapprove")]
public class LabUnapproveController(ILabUnapproveService service) : ControllerBase
{
    [HttpGet("headers")]
    public async Task<IActionResult> GetHeaders(
        [FromQuery] int branchId,
        [FromQuery] DateTime? fromDate,
        [FromQuery] DateTime? toDate,
        [FromQuery] string? dateBasis = "ApprovedDate",
        [FromQuery] string? search = null,
        [FromQuery] string? approvalType = "ALL")
    {
        if (branchId <= 0) return BadRequest(new { message = "BranchId is required." });
        return Ok(await service.GetHeaderListAsync(branchId, fromDate, toDate, dateBasis, search, approvalType));
    }

    [HttpGet("detail/{labOrderId:int}")]
    public async Task<IActionResult> GetDetail(int labOrderId)
    {
        if (labOrderId <= 0) return BadRequest(new { message = "Valid LabOrderId is required." });
        var result = await service.GetDetailAsync(labOrderId);
        return result.Bill == null ? NotFound(new { message = "Lab order not found." }) : Ok(result);
    }

    [HttpPost("unapprove")]
    public async Task<IActionResult> Unapprove([FromBody] LabUnapproveRequest request)
    {
        if (request == null || request.LabOrderId <= 0 || request.SamplecollectionIds.Count == 0 || request.UserId <= 0)
            return BadRequest(new { message = "LabOrderId, at least one test and UserId are required." });

        if (request.Action != null && !new[] { "RETEST", "RECOLLECT" }.Contains(request.Action.Trim().ToUpperInvariant()))
            return BadRequest(new { message = "Select what the withdrawal is for: Re-Test or Re-Collect." });

        try
        {
            var count = await service.UnapproveAsync(request);
            return Ok(new { count });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
    }
}
