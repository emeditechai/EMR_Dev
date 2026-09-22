using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// Pathologist Dashboard: the bills awaiting a pathologist's sign-off, scoped by their branch, department access,
/// test categories and the Pathologist Approval Flow. Shared by the web app and (later) the mobile app.
/// </summary>
[ApiController]
[Route("api/pathologist-dashboard")]
public class PathologistDashboardController(IPathologistDashboardService service) : ControllerBase
{
    [HttpGet("access")]
    public async Task<IActionResult> GetAccess([FromQuery] int userId, [FromQuery] int branchId)
    {
        if (userId <= 0 || branchId <= 0) return BadRequest(new { message = "UserId and BranchId are required." });
        return Ok(await service.GetAccessAsync(userId, branchId));
    }

    [HttpGet("headers")]
    public async Task<IActionResult> GetHeaders(
        [FromQuery] int userId,
        [FromQuery] int branchId,
        [FromQuery] DateTime? fromDate,
        [FromQuery] DateTime? toDate,
        [FromQuery] string? dateBasis = "BookingDate",
        [FromQuery] string? search = null,
        [FromQuery] int? departmentId = null,
        [FromQuery] int? categoryId = null,
        [FromQuery] string? statusFilter = "PENDING")
    {
        if (userId <= 0 || branchId <= 0) return BadRequest(new { message = "UserId and BranchId are required." });

        var access = await service.GetAccessAsync(userId, branchId);
        if (access.Profile is not { IsPathologist: true, HasBranchAccess: true })
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "This dashboard is only available to a pathologist of this branch." });

        return Ok(await service.GetHeaderListAsync(userId, branchId, fromDate, toDate, dateBasis, search, departmentId, categoryId, statusFilter));
    }

    [HttpGet("detail/{labOrderId:int}")]
    public async Task<IActionResult> GetDetail(int labOrderId, [FromQuery] int userId, [FromQuery] int branchId)
    {
        if (labOrderId <= 0 || userId <= 0 || branchId <= 0)
            return BadRequest(new { message = "LabOrderId, UserId and BranchId are required." });

        var access = await service.GetAccessAsync(userId, branchId);
        if (access.Profile is not { IsPathologist: true, HasBranchAccess: true })
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "This dashboard is only available to a pathologist of this branch." });

        var result = await service.GetDetailAsync(labOrderId, userId, branchId);
        return result.Bill == null ? NotFound(new { message = "Lab order not found." }) : Ok(result);
    }

    [HttpPost("approve")]
    public async Task<IActionResult> Approve([FromBody] PathologistApproveRequest request)
    {
        if (request == null || request.LabOrderId <= 0 || request.SamplecollectionIds.Count == 0
            || request.UserId <= 0 || request.BranchId <= 0)
            return BadRequest(new { message = "LabOrderId, at least one test, UserId and BranchId are required." });

        var access = await service.GetAccessAsync(request.UserId, request.BranchId);
        if (access.Profile is not { IsPathologist: true, HasBranchAccess: true })
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "This dashboard is only available to a pathologist of this branch." });

        try
        {
            return Ok(await service.ApproveAsync(request));
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
    }
}
