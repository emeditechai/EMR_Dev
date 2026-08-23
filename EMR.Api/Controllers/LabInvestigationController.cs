using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-investigations")]
[Produces("application/json")]
public class LabInvestigationController(ILabInvestigationService service) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<LabInvestigationListItem>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId,
        [FromQuery] int? departmentId,
        [FromQuery] int? categoryId,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var data = await service.GetListAsync(branchId, departmentId, categoryId, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<LabInvestigationListItem>>.Ok(data));
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<LabInvestigationListItem>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        if (item == null)
            return NotFound(ApiResponse<object>.Fail($"Investigation record #{id} not found."));

        return Ok(ApiResponse<LabInvestigationListItem>.Ok(item));
    }

    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] LabInvestigationCreateRequest req)
    {
        try
        {
            var id = await service.CreateAsync(req);
            return CreatedAtAction(nameof(GetById), new { id }, ApiResponse<int>.Ok(id, "Investigation created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<object>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update(int id, [FromBody] LabInvestigationUpdateRequest req)
    {
        if (id != req.Test_ID)
            return BadRequest(ApiResponse<object>.Fail("Mismatched Test ID."));

        try
        {
            await service.UpdateAsync(req);
            return Ok(ApiResponse<object>.Ok(new { }, "Investigation updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPatch("{id:int}/status")]
    [ProducesResponseType(typeof(ApiResponse<object>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabInvestigationToggleStatusRequest req)
    {
        if (id != req.Test_ID)
            return BadRequest(ApiResponse<object>.Fail("Mismatched Test ID."));

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
            return Ok(ApiResponse<object>.Ok(new { }, "Investigation deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }
}
