using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Shift Master API</summary>
[ApiController]
[Route("api/shifts")]
[Produces("application/json")]
public class ShiftsController(IShiftMasterService shiftService) : ControllerBase
{
    /// <summary>Get list of shifts</summary>
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<ShiftMasterListItemDto>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var list = await shiftService.GetListAsync(branchId, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<ShiftMasterListItemDto>>.Ok(list));
    }

    /// <summary>Get single shift by ID</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<ShiftMasterDetailDto>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById([FromRoute] int id)
    {
        var item = await shiftService.GetByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<object>.Fail("Shift not found."));

        return Ok(ApiResponse<ShiftMasterDetailDto>.Ok(item));
    }

    /// <summary>Create a new shift</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] ShiftMasterSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.ShiftCode))
            return BadRequest(ApiResponse<object>.Fail("Shift Code is mandatory."));

        if (string.IsNullOrWhiteSpace(request.ShiftName))
            return BadRequest(ApiResponse<object>.Fail("Shift Name is mandatory."));

        try
        {
            var newId = await shiftService.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Shift created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Update an existing shift</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update([FromRoute] int id, [FromBody] ShiftMasterSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.ShiftCode))
            return BadRequest(ApiResponse<object>.Fail("Shift Code is mandatory."));

        if (string.IsNullOrWhiteSpace(request.ShiftName))
            return BadRequest(ApiResponse<object>.Fail("Shift Name is mandatory."));

        try
        {
            var updated = await shiftService.UpdateAsync(id, request);
            return Ok(ApiResponse<bool>.Ok(updated, "Shift updated successfully."));
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
        var result = await shiftService.ToggleStatusAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Shift status updated."));
    }

    /// <summary>Delete a shift</summary>
    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> Delete([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await shiftService.DeleteAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Shift deleted successfully."));
    }
}
