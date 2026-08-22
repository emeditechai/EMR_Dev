using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Government Scheme Master API</summary>
[ApiController]
[Route("api/government-schemes")]
[Produces("application/json")]
public class GovernmentSchemesController(IGovernmentSchemeService schemeService) : ControllerBase
{
    /// <summary>Get list of government schemes</summary>
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<GovernmentSchemeListItemDto>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId,
        [FromQuery] string? schemeType,
        [FromQuery] bool? isActive,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var list = await schemeService.GetListAsync(branchId, schemeType, isActive, search, companyId);
        return Ok(ApiResponse<IEnumerable<GovernmentSchemeListItemDto>>.Ok(list));
    }

    /// <summary>Get single government scheme by ID</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<GovernmentSchemeDetailDto>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById([FromRoute] int id)
    {
        var item = await schemeService.GetByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<object>.Fail("Government scheme not found."));

        return Ok(ApiResponse<GovernmentSchemeDetailDto>.Ok(item));
    }

    /// <summary>Create a new government scheme</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] GovernmentSchemeSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.SchemeCode))
            return BadRequest(ApiResponse<object>.Fail("Scheme Code is mandatory."));

        if (string.IsNullOrWhiteSpace(request.SchemeName))
            return BadRequest(ApiResponse<object>.Fail("Scheme Name is mandatory."));

        if (string.IsNullOrWhiteSpace(request.SchemeType))
            return BadRequest(ApiResponse<object>.Fail("Scheme Type is mandatory."));

        if (string.IsNullOrWhiteSpace(request.AuthorityName))
            return BadRequest(ApiResponse<object>.Fail("Authority / Ministry Name is mandatory."));

        if (request.Effective_To < request.Effective_From)
            return BadRequest(ApiResponse<object>.Fail("Effective To date cannot be earlier than Effective From date."));

        try
        {
            var newId = await schemeService.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Government Scheme created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Update an existing government scheme</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update([FromRoute] int id, [FromBody] GovernmentSchemeSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.SchemeCode))
            return BadRequest(ApiResponse<object>.Fail("Scheme Code is mandatory."));

        if (string.IsNullOrWhiteSpace(request.SchemeName))
            return BadRequest(ApiResponse<object>.Fail("Scheme Name is mandatory."));

        if (string.IsNullOrWhiteSpace(request.SchemeType))
            return BadRequest(ApiResponse<object>.Fail("Scheme Type is mandatory."));

        if (string.IsNullOrWhiteSpace(request.AuthorityName))
            return BadRequest(ApiResponse<object>.Fail("Authority / Ministry Name is mandatory."));

        if (request.Effective_To < request.Effective_From)
            return BadRequest(ApiResponse<object>.Fail("Effective To date cannot be earlier than Effective From date."));

        try
        {
            var updated = await schemeService.UpdateAsync(id, request);
            return Ok(ApiResponse<bool>.Ok(updated, "Government Scheme updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Toggle Active/Inactive status</summary>
    [HttpPatch("{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> ToggleStatus([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await schemeService.ToggleStatusAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Government Scheme status updated."));
    }

    /// <summary>Delete a government scheme</summary>
    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> Delete([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await schemeService.DeleteAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Government Scheme deleted successfully."));
    }
}
