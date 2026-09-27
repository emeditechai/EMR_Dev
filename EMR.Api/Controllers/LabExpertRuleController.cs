using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-expert-rules")]
[Produces("application/json")]
public class LabExpertRuleController(ILabExpertRuleService service) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetList(
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId,
        [FromQuery] int? organism_ID,
        [FromQuery] int? antibiotic_ID)
    {
        var data = await service.GetListAsync(status, search, companyId, organism_ID, antibiotic_ID);
        return Ok(ApiResponse<IEnumerable<LabExpertRuleListItem>>.Ok(data));
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        if (item == null)
            return NotFound(ApiResponse<object>.Fail("Expert Rule not found."));
        return Ok(ApiResponse<LabExpertRuleListItem>.Ok(item));
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] LabExpertRuleCreateRequest req)
    {
        try
        {
            var newId = await service.CreateAsync(req);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Expert Rule created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] LabExpertRuleUpdateRequest req)
    {
        if (id != req.Rule_ID)
            return BadRequest(ApiResponse<object>.Fail("ID mismatch."));
        try
        {
            await service.UpdateAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Expert Rule updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPost("{id:int}/toggle-status")]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabExpertRuleToggleStatusRequest req)
    {
        if (id != req.Rule_ID)
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
            return Ok(ApiResponse<bool>.Ok(true, "Expert Rule deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpGet("lookup/organisms")]
    public async Task<IActionResult> LookupOrganisms([FromQuery] int? companyId)
    {
        var data = await service.LookupOrganismsAsync(companyId);
        return Ok(ApiResponse<IEnumerable<LabExpertRuleLookupItem>>.Ok(data));
    }

    [HttpGet("lookup/antibiotics")]
    public async Task<IActionResult> LookupAntibiotics([FromQuery] int? companyId)
    {
        var data = await service.LookupAntibioticsAsync(companyId);
        return Ok(ApiResponse<IEnumerable<LabExpertRuleLookupItem>>.Ok(data));
    }
}
