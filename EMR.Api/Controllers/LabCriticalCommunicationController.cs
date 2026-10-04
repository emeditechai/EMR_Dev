using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// Critical value communication record (SQLScripts/2202): the Critical / Panic results of a bill with their
/// communication state, and saving who was informed. Branch access is checked by the procedures.
/// </summary>
[ApiController]
[Route("api/lab-critical")]
public class LabCriticalCommunicationController(ILabCriticalCommunicationService service) : ControllerBase
{
    private static readonly string[] Contexts = ["SIGNOFF", "ENTRY", "REGISTER"];

    [HttpGet("pending")]
    public async Task<IActionResult> GetPending([FromQuery] int branchId, [FromQuery] int labOrderId, [FromQuery] string? sampleIds,
        [FromQuery] string? context, [FromQuery] int userId, [FromQuery] bool isSuperAdmin = false)
    {
        if (branchId <= 0 || labOrderId <= 0 || userId <= 0)
            return BadRequest(new { message = "BranchId, LabOrderId and UserId are required." });
        var ctx = (context ?? "REGISTER").Trim().ToUpperInvariant();
        if (!Contexts.Contains(ctx)) return BadRequest(new { message = "Unknown context." });

        var ids = string.IsNullOrWhiteSpace(sampleIds) ? null
            : sampleIds.Split(',', StringSplitOptions.RemoveEmptyEntries).Select(v => long.TryParse(v.Trim(), out var id) ? id : 0).Where(id => id > 0).ToList();
        try
        {
            return Ok(await service.GetPendingAsync(branchId, labOrderId, ids, ctx, userId, isSuperAdmin));
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50010 or 50011)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new { message = ex.Message });
        }
    }

    [HttpPost("record")]
    public async Task<IActionResult> Record([FromBody] LabCriticalRecordRequest request)
    {
        if (request == null || request.BranchId <= 0 || request.LabOrderId <= 0 || request.UserId <= 0 || request.Items.Count == 0)
            return BadRequest(new { message = "BranchId, LabOrderId, UserId and at least one result are required." });
        try
        {
            return Ok(await service.RecordAsync(request));
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50010 or 50011)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new { message = ex.Message });
        }
    }

    /// <summary>The sign-off check alone: { blocked, message } for the given results.</summary>
    [HttpGet("signoff-check")]
    public async Task<IActionResult> SignoffCheck([FromQuery] int branchId, [FromQuery] int labOrderId, [FromQuery] string? sampleIds,
        [FromQuery] string? context, [FromQuery] int userId, [FromQuery] bool isSuperAdmin = false)
    {
        if (branchId <= 0 || labOrderId <= 0 || userId <= 0 || string.IsNullOrWhiteSpace(sampleIds))
            return BadRequest(new { message = "BranchId, LabOrderId, UserId and the results are required." });
        var ctx = (context ?? "ENTRY").Trim().ToUpperInvariant();
        if (!Contexts.Contains(ctx)) return BadRequest(new { message = "Unknown context." });
        var ids = sampleIds.Split(',', StringSplitOptions.RemoveEmptyEntries).Select(v => long.TryParse(v.Trim(), out var id) ? id : 0).Where(id => id > 0);
        try
        {
            var message = await service.GetSignoffBlockAsync(branchId, labOrderId, ids, ctx, userId, isSuperAdmin);
            return Ok(new { blocked = message != null, message });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50010 or 50011)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new { message = ex.Message });
        }
    }
}
