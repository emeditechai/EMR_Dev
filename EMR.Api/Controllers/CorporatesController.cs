using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Corporate Master API</summary>
[ApiController]
[Route("api/corporates")]
[Produces("application/json")]
public class CorporatesController(ICorporateService corporateService) : ControllerBase
{
    /// <summary>Get list of corporates with optional filters</summary>
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<CorporateListItemDto>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId,
        [FromQuery] string? type,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var list = await corporateService.GetListAsync(branchId, type, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<CorporateListItemDto>>.Ok(list));
    }

    /// <summary>Get single corporate by ID</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<CorporateDetailDto>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById([FromRoute] int id)
    {
        var item = await corporateService.GetByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<object>.Fail("Corporate record not found."));

        return Ok(ApiResponse<CorporateDetailDto>.Ok(item));
    }

    /// <summary>Create a new corporate record</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] CorporateSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Corporate_Name))
            return BadRequest(ApiResponse<object>.Fail("Corporate Name is mandatory."));

        if (string.IsNullOrWhiteSpace(request.Contact_No))
            return BadRequest(ApiResponse<object>.Fail("Contact Number is mandatory."));

        if (request.Effective_To < request.Effective_From)
            return BadRequest(ApiResponse<object>.Fail("Effective To date cannot be earlier than Effective From date."));

        try
        {
            var newId = await corporateService.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Corporate record created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Update an existing corporate record</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update([FromRoute] int id, [FromBody] CorporateSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Corporate_Name))
            return BadRequest(ApiResponse<object>.Fail("Corporate Name is mandatory."));

        if (string.IsNullOrWhiteSpace(request.Contact_No))
            return BadRequest(ApiResponse<object>.Fail("Contact Number is mandatory."));

        if (request.Effective_To < request.Effective_From)
            return BadRequest(ApiResponse<object>.Fail("Effective To date cannot be earlier than Effective From date."));

        try
        {
            var updated = await corporateService.UpdateAsync(id, request);
            return Ok(ApiResponse<bool>.Ok(updated, "Corporate record updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Toggle Active/Inactive status of a corporate</summary>
    [HttpPatch("{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> ToggleStatus([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await corporateService.ToggleStatusAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Corporate status updated."));
    }

    /// <summary>Delete a corporate</summary>
    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> Delete([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await corporateService.DeleteAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Corporate deleted successfully."));
    }
}
