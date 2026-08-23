using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-units")]
[Produces("application/json")]
public class LabUnitController(ILabUnitService service) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<LabUnitListItem>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var data = await service.GetListAsync(branchId, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<LabUnitListItem>>.Ok(data));
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<LabUnitListItem>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        if (item == null)
            return NotFound(ApiResponse<object>.Fail("Unit record not found."));

        return Ok(ApiResponse<LabUnitListItem>.Ok(item));
    }

    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] LabUnitCreateRequest req)
    {
        try
        {
            var newId = await service.CreateAsync(req);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Unit created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update(int id, [FromBody] LabUnitUpdateRequest req)
    {
        if (id != req.Unit_ID)
            return BadRequest(ApiResponse<object>.Fail("Unit ID mismatch."));

        try
        {
            await service.UpdateAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Unit updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPost("{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabUnitToggleStatusRequest req)
    {
        if (id != req.Unit_ID)
            return BadRequest(ApiResponse<object>.Fail("Unit ID mismatch."));

        try
        {
            await service.ToggleStatusAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Status updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Delete(int id)
    {
        try
        {
            await service.DeleteAsync(id);
            return Ok(ApiResponse<bool>.Ok(true, "Unit deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }
}
