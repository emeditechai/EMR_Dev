using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-antibiotic-panels")]
[Produces("application/json")]
public class LabAntibioticPanelController(ILabAntibioticPanelService service) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetList(
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId,
        [FromQuery] int? sample_Type_ID)
    {
        var data = await service.GetListAsync(status, search, companyId, sample_Type_ID);
        return Ok(ApiResponse<IEnumerable<LabAntibioticPanelListItem>>.Ok(data));
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        if (item == null)
            return NotFound(ApiResponse<object>.Fail("Antibiotic Panel not found."));
        return Ok(ApiResponse<LabAntibioticPanelListItem>.Ok(item));
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] LabAntibioticPanelCreateRequest req)
    {
        try
        {
            var newId = await service.CreateAsync(req);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Antibiotic Panel created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] LabAntibioticPanelUpdateRequest req)
    {
        if (id != req.Panel_ID)
            return BadRequest(ApiResponse<object>.Fail("ID mismatch."));
        try
        {
            await service.UpdateAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Antibiotic Panel updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPost("{id:int}/toggle-status")]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabAntibioticPanelToggleStatusRequest req)
    {
        if (id != req.Panel_ID)
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
            return Ok(ApiResponse<bool>.Ok(true, "Antibiotic Panel deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpGet("lookup/antibiotics")]
    public async Task<IActionResult> LookupAntibiotics([FromQuery] int? companyId)
    {
        var data = await service.LookupAntibioticsAsync(companyId);
        return Ok(ApiResponse<IEnumerable<LabAntibioticPanelLookupItem>>.Ok(data));
    }

    [HttpGet("lookup/sample-types")]
    public async Task<IActionResult> LookupSampleTypes([FromQuery] int? companyId)
    {
        var data = await service.LookupSampleTypesAsync(companyId);
        return Ok(ApiResponse<IEnumerable<LabAntibioticPanelLookupItem>>.Ok(data));
    }
}
