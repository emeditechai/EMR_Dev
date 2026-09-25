using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// Default lab report signatories per department of a branch, used when Hospital Settings has
/// "Pathologist Approval Required" switched off.
/// </summary>
[ApiController]
[Route("api/lab-default-signatory")]
public class LabDefaultSignatoryController(ILabDefaultSignatoryService service) : ControllerBase
{
    [HttpGet("list")]
    public async Task<IActionResult> GetList([FromQuery] int branchId, [FromQuery] int? companyId = null)
    {
        if (branchId <= 0) return BadRequest(new { message = "BranchId is required." });
        return Ok(await service.GetListAsync(branchId, companyId));
    }

    [HttpPost("save")]
    public async Task<IActionResult> Save([FromBody] LabDefaultSignatorySaveRequest request)
    {
        if (request == null || request.BranchId <= 0)
            return BadRequest(new { message = "BranchId is required." });

        try
        {
            return Ok(new { savedCount = await service.SaveAsync(request) });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
    }
}
