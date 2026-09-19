using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-reference-ranges")]
[Produces("application/json")]
public class LabReferenceRangeController(ILabReferenceRangeService service) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<LabReferenceRangeListItem>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? testId,
        [FromQuery] string? gender,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var data = await service.GetListAsync(testId, gender, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<LabReferenceRangeListItem>>.Ok(data));
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<LabReferenceRangeDetail>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById(int id, [FromQuery] int? companyId)
    {
        var item = await service.GetByIdAsync(id, companyId);
        if (item == null)
            return NotFound(ApiResponse<object>.Fail("Reference Range record not found."));

        return Ok(ApiResponse<LabReferenceRangeDetail>.Ok(item));
    }

    [HttpGet("numeric-tests")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<LabNumericTestOption>>), 200)]
    public async Task<IActionResult> GetNumericTests([FromQuery] int? companyId)
    {
        var data = await service.GetNumericTestsAsync(companyId ?? 1);
        return Ok(ApiResponse<IEnumerable<LabNumericTestOption>>.Ok(data));
    }

    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] LabReferenceRangeCreateRequest req)
    {
        try
        {
            var newId = await service.CreateAsync(req);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Reference Range created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPost("bulk-save")]
    [ProducesResponseType(typeof(ApiResponse<int>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> BulkSave([FromBody] LabReferenceRangeBulkSaveRequest req)
    {
        try
        {
            var count = await service.BulkSaveAsync(req);
            return Ok(ApiResponse<int>.Ok(count, $"{count} Reference Range(s) saved successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update(int id, [FromBody] LabReferenceRangeUpdateRequest req)
    {
        if (id != req.RefRange_ID)
            return BadRequest(ApiResponse<object>.Fail("Reference Range ID mismatch."));

        try
        {
            await service.UpdateAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Reference Range updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Delete(int id, [FromQuery] int companyId = 1, [FromQuery] int? userId = null)
    {
        try
        {
            await service.DeleteAsync(id, companyId, userId);
            return Ok(ApiResponse<bool>.Ok(true, "Reference Range deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPost("toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> ToggleStatus([FromBody] LabReferenceRangeToggleStatusRequest req)
    {
        try
        {
            var newStatus = await service.ToggleStatusAsync(req.RefRange_ID, req.CompanyId, req.UserId);
            return Ok(ApiResponse<bool>.Ok(newStatus, $"Reference Range status changed to {(newStatus ? "Active" : "Inactive")}."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }
}
