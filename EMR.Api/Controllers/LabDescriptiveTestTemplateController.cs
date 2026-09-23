using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-descriptive-test-templates")]
[Produces("application/json")]
public class LabDescriptiveTestTemplateController(ILabDescriptiveTestTemplateService service) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<LabDescriptiveTestTemplateListItem>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? testId,
        [FromQuery] int? companyId)
    {
        var data = await service.GetListAsync(status, search, testId, companyId);
        return Ok(ApiResponse<IEnumerable<LabDescriptiveTestTemplateListItem>>.Ok(data));
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<LabDescriptiveTestTemplateListItem>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        if (item == null)
            return NotFound(ApiResponse<object>.Fail("Descriptive Test Template record not found."));

        return Ok(ApiResponse<LabDescriptiveTestTemplateListItem>.Ok(item));
    }

    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] LabDescriptiveTestTemplateCreateRequest req)
    {
        try
        {
            var newId = await service.CreateAsync(req);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Descriptive Test Template created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPost("batch")]
    [ProducesResponseType(typeof(ApiResponse<List<int>>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> BatchCreate([FromBody] LabDescriptiveTestTemplateBatchCreateRequest req)
    {
        try
        {
            if (req.Sections == null || req.Sections.Count == 0)
                return BadRequest(ApiResponse<object>.Fail("At least one section is required."));

            var ids = await service.BatchCreateAsync(req);
            return CreatedAtAction(nameof(GetList), ApiResponse<List<int>>.Ok(ids, $"{ids.Count} template section(s) created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update(int id, [FromBody] LabDescriptiveTestTemplateUpdateRequest req)
    {
        if (id != req.Template_ID)
            return BadRequest(ApiResponse<object>.Fail("Template ID mismatch."));

        try
        {
            await service.UpdateAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Descriptive Test Template updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPost("{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabDescriptiveTestTemplateToggleStatusRequest req)
    {
        if (id != req.Template_ID)
            return BadRequest(ApiResponse<object>.Fail("Template ID mismatch."));

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
            return Ok(ApiResponse<bool>.Ok(true, "Descriptive Test Template deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpGet("radiology-tests")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<RadiologyTestItem>>), 200)]
    public async Task<IActionResult> GetRadiologyTests(
        [FromQuery] int? companyId,
        [FromQuery] string? search)
    {
        var data = await service.GetRadiologyTestsAsync(companyId, search);
        return Ok(ApiResponse<IEnumerable<RadiologyTestItem>>.Ok(data));
    }
}
