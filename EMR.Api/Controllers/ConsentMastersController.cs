using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/consent-masters")]
[Produces("application/json")]
public class ConsentMastersController(IConsentMasterService service) : ControllerBase
{
    /// <summary>Retrieves Consent Masters list with optional filters.</summary>
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<ConsentMasterListItemDto>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId = null,
        [FromQuery] string? type = null,
        [FromQuery] string? consentType = null,
        [FromQuery] string? language = null,
        [FromQuery] int? procedureId = null,
        [FromQuery] bool? status = null,
        [FromQuery] string? search = null,
        [FromQuery] int? companyId = null)
    {
        var list = await service.GetListAsync(branchId, type, consentType, language, procedureId, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<ConsentMasterListItemDto>>.Ok(list));
    }

    /// <summary>Retrieves a single Consent Master by ID.</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<ConsentMasterDetailDto>), 200)]
    [ProducesResponseType(404)]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<ConsentMasterDetailDto>.Fail($"Consent Master with ID {id} not found."));

        return Ok(ApiResponse<ConsentMasterDetailDto>.Ok(item));
    }

    /// <summary>Creates a new Consent Master template.</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(400)]
    public async Task<IActionResult> Create([FromBody] ConsentMasterSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.ConsentType))
            return BadRequest(ApiResponse<int>.Fail("ConsentType is required."));

        if (string.IsNullOrWhiteSpace(request.Type))
            return BadRequest(ApiResponse<int>.Fail("Type is required."));

        if (string.IsNullOrWhiteSpace(request.ConsentTemplateContent))
            return BadRequest(ApiResponse<int>.Fail("ConsentTemplateContent is required."));

        var newId = await service.CreateAsync(request);
        return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Consent Master created successfully."));
    }

    /// <summary>Updates an existing Consent Master template.</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(400)]
    [ProducesResponseType(404)]
    public async Task<IActionResult> Update(int id, [FromBody] ConsentMasterSaveRequest request)
    {
        request.Consent_ID = id;

        if (string.IsNullOrWhiteSpace(request.ConsentType))
            return BadRequest(ApiResponse<bool>.Fail("ConsentType is required."));

        if (string.IsNullOrWhiteSpace(request.Type))
            return BadRequest(ApiResponse<bool>.Fail("Type is required."));

        if (string.IsNullOrWhiteSpace(request.ConsentTemplateContent))
            return BadRequest(ApiResponse<bool>.Fail("ConsentTemplateContent is required."));

        var updated = await service.UpdateAsync(request);
        if (!updated)
            return NotFound(ApiResponse<bool>.Fail($"Consent Master with ID {id} not found."));

        return Ok(ApiResponse<bool>.Ok(true, "Consent Master updated successfully."));
    }

    /// <summary>Toggles Active/Inactive status of a Consent Master.</summary>
    [HttpPost("{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(404)]
    public async Task<IActionResult> ToggleStatus(int id, [FromQuery] int? userId = null)
    {
        var toggled = await service.ToggleStatusAsync(id, userId);
        if (!toggled)
            return NotFound(ApiResponse<bool>.Fail($"Consent Master with ID {id} not found."));

        return Ok(ApiResponse<bool>.Ok(true, "Consent Master status updated successfully."));
    }

    /// <summary>Deletes a Consent Master record.</summary>
    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(404)]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await service.DeleteAsync(id);
        if (!deleted)
            return NotFound(ApiResponse<bool>.Fail($"Consent Master with ID {id} not found."));

        return Ok(ApiResponse<bool>.Ok(true, "Consent Master deleted successfully."));
    }

    /// <summary>Retrieves procedure options for dropdown.</summary>
    [HttpGet("procedure-options")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<ConsentProcedureOptionDto>>), 200)]
    public async Task<IActionResult> GetProcedureOptions([FromQuery] int? branchId = null)
    {
        var options = await service.GetProcedureOptionsAsync(branchId);
        return Ok(ApiResponse<IEnumerable<ConsentProcedureOptionDto>>.Ok(options));
    }
}
