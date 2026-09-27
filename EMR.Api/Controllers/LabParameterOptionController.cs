using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-parameter-options")]
[Produces("application/json")]
public class LabParameterOptionController(ILabParameterOptionService service) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetList(
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId,
        [FromQuery] int? test_ID)
    {
        var data = await service.GetListAsync(status, search, companyId, test_ID);
        return Ok(ApiResponse<IEnumerable<LabParameterOptionListItem>>.Ok(data));
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        if (item == null)
            return NotFound(ApiResponse<object>.Fail("Parameter Option not found."));
        return Ok(ApiResponse<LabParameterOptionListItem>.Ok(item));
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] LabParameterOptionCreateRequest req)
    {
        try
        {
            var newId = await service.CreateAsync(req);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Parameter Option created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] LabParameterOptionUpdateRequest req)
    {
        if (id != req.Option_ID)
            return BadRequest(ApiResponse<object>.Fail("ID mismatch."));
        try
        {
            await service.UpdateAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Parameter Option updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPost("{id:int}/toggle-status")]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabParameterOptionToggleStatusRequest req)
    {
        if (id != req.Option_ID)
            return BadRequest(ApiResponse<object>.Fail("ID mismatch."));
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
    public async Task<IActionResult> Delete(int id, [FromQuery] int? userId)
    {
        try
        {
            await service.DeleteAsync(id, userId);
            return Ok(ApiResponse<bool>.Ok(true, "Parameter Option deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpGet("lookup/tests")]
    public async Task<IActionResult> LookupTests([FromQuery] int? companyId)
    {
        var data = await service.LookupTestsAsync(companyId);
        return Ok(ApiResponse<IEnumerable<LabParameterOptionLookupItem>>.Ok(data));
    }
}
