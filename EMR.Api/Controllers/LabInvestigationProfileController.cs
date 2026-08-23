using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-investigation-profiles")]
[Produces("application/json")]
public class LabInvestigationProfileController(ILabInvestigationProfileService service) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<LabInvestigationProfileHeaderListItem>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId,
        [FromQuery] string? profileType,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var data = await service.GetListAsync(branchId, profileType, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<LabInvestigationProfileHeaderListItem>>.Ok(data));
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<LabInvestigationProfileFullDetail>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        if (item == null)
            return NotFound(ApiResponse<object>.Fail($"Investigation Profile #{id} not found."));

        return Ok(ApiResponse<LabInvestigationProfileFullDetail>.Ok(item));
    }

    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Save([FromBody] LabInvestigationProfileSaveRequest req)
    {
        try
        {
            var id = await service.SaveAsync(req);
            return Ok(ApiResponse<int>.Ok(id, "Investigation Profile saved successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPatch("{id:int}/status")]
    [ProducesResponseType(typeof(ApiResponse<object>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabInvestigationProfileToggleStatusRequest req)
    {
        if (id != req.Profile_ID)
            return BadRequest(ApiResponse<object>.Fail("Mismatched Profile ID."));

        try
        {
            await service.ToggleStatusAsync(req);
            return Ok(ApiResponse<object>.Ok(new { }, "Status updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<object>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Delete(int id)
    {
        try
        {
            await service.DeleteAsync(id);
            return Ok(ApiResponse<object>.Ok(new { }, "Investigation Profile deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }
}
