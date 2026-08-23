using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-sample-types")]
[Produces("application/json")]
public class LabSampleTypeController(ILabSampleTypeService service) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<LabSampleTypeListItem>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId,
        [FromQuery] string? containerType,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var data = await service.GetListAsync(branchId, containerType, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<LabSampleTypeListItem>>.Ok(data));
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<LabSampleTypeListItem>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        if (item == null)
            return NotFound(ApiResponse<object>.Fail("Lab Sample Type record not found."));

        return Ok(ApiResponse<LabSampleTypeListItem>.Ok(item));
    }

    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] LabSampleTypeCreateRequest req)
    {
        try
        {
            var newId = await service.CreateAsync(req);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Lab Sample Type created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update(int id, [FromBody] LabSampleTypeUpdateRequest req)
    {
        if (id != req.Sample_Type_ID)
            return BadRequest(ApiResponse<object>.Fail("Sample Type ID mismatch."));

        try
        {
            await service.UpdateAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Lab Sample Type updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPost("{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabSampleTypeToggleStatusRequest req)
    {
        if (id != req.Sample_Type_ID)
            return BadRequest(ApiResponse<object>.Fail("Sample Type ID mismatch."));

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
            return Ok(ApiResponse<bool>.Ok(true, "Lab Sample Type deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }
}
