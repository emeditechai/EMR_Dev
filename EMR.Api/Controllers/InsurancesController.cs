using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Insurance & TPA Master API</summary>
[ApiController]
[Route("api/insurances")]
[Produces("application/json")]
public class InsurancesController(IInsuranceTPAService insuranceService) : ControllerBase
{
    /// <summary>Get list of insurance companies and TPAs with optional filters</summary>
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<InsuranceTPAListItemDto>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId,
        [FromQuery] string? type,
        [FromQuery] string? networkCategory,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var list = await insuranceService.GetListAsync(branchId, type, networkCategory, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<InsuranceTPAListItemDto>>.Ok(list));
    }

    /// <summary>Get single insurance / TPA record by ID</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<InsuranceTPADetailDto>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById([FromRoute] int id)
    {
        var item = await insuranceService.GetByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<object>.Fail("Insurance/TPA record not found."));

        return Ok(ApiResponse<InsuranceTPADetailDto>.Ok(item));
    }

    /// <summary>Create a new insurance or TPA record</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] InsuranceTPASaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Name))
            return BadRequest(ApiResponse<object>.Fail("Name is mandatory."));

        if (string.IsNullOrWhiteSpace(request.Code))
            return BadRequest(ApiResponse<object>.Fail("Code is mandatory."));

        if (string.IsNullOrWhiteSpace(request.Type))
            return BadRequest(ApiResponse<object>.Fail("Type is mandatory."));

        try
        {
            var newId = await insuranceService.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Insurance/TPA record created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Update an existing insurance or TPA record</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update([FromRoute] int id, [FromBody] InsuranceTPASaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Name))
            return BadRequest(ApiResponse<object>.Fail("Name is mandatory."));

        if (string.IsNullOrWhiteSpace(request.Code))
            return BadRequest(ApiResponse<object>.Fail("Code is mandatory."));

        if (string.IsNullOrWhiteSpace(request.Type))
            return BadRequest(ApiResponse<object>.Fail("Type is mandatory."));

        try
        {
            var updated = await insuranceService.UpdateAsync(id, request);
            return Ok(ApiResponse<bool>.Ok(updated, "Insurance/TPA record updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Toggle Active/Inactive status of an Insurance/TPA</summary>
    [HttpPatch("{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> ToggleStatus([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await insuranceService.ToggleStatusAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Insurance/TPA status updated."));
    }

    /// <summary>Delete an Insurance/TPA record</summary>
    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> Delete([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await insuranceService.DeleteAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Insurance/TPA record deleted successfully."));
    }
}
