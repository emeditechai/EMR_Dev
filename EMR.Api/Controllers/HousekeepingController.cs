using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Housekeeping Masters API</summary>
[ApiController]
[Route("api/housekeeping")]
[Produces("application/json")]
public class HousekeepingController(IHousekeepingService hkService) : ControllerBase
{
    // ── Location Master ──────────────────────────────────────────────────────
    [HttpGet("locations")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<HKLocationListItemDto>>), 200)]
    public async Task<IActionResult> GetLocations(
        [FromQuery] int? branchId,
        [FromQuery] string? locationType,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var list = await hkService.GetLocationsAsync(branchId, locationType, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<HKLocationListItemDto>>.Ok(list));
    }

    [HttpGet("locations/{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<HKLocationDetailDto>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetLocationById([FromRoute] int id)
    {
        var item = await hkService.GetLocationByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<object>.Fail("Housekeeping location not found."));

        return Ok(ApiResponse<HKLocationDetailDto>.Ok(item));
    }

    [HttpPost("locations")]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> CreateLocation([FromBody] HKLocationSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.LocationCode))
            return BadRequest(ApiResponse<object>.Fail("Location Code is mandatory."));

        if (string.IsNullOrWhiteSpace(request.LocationName))
            return BadRequest(ApiResponse<object>.Fail("Location Name is mandatory."));

        if (string.IsNullOrWhiteSpace(request.LocationType))
            return BadRequest(ApiResponse<object>.Fail("Location Type is mandatory."));

        try
        {
            var newId = await hkService.CreateLocationAsync(request);
            return CreatedAtAction(nameof(GetLocationById), new { id = newId }, ApiResponse<int>.Ok(newId, "Location created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("locations/{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> UpdateLocation([FromRoute] int id, [FromBody] HKLocationSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.LocationCode))
            return BadRequest(ApiResponse<object>.Fail("Location Code is mandatory."));

        if (string.IsNullOrWhiteSpace(request.LocationName))
            return BadRequest(ApiResponse<object>.Fail("Location Name is mandatory."));

        try
        {
            var updated = await hkService.UpdateLocationAsync(id, request);
            return Ok(ApiResponse<bool>.Ok(updated, "Location updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPatch("locations/{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> ToggleLocationStatus([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await hkService.ToggleLocationStatusAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Location status updated."));
    }

    [HttpDelete("locations/{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> DeleteLocation([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await hkService.DeleteLocationAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Location deleted successfully."));
    }

    [HttpGet("physical-master-items")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<HKPhysicalMasterItemDto>>), 200)]
    public async Task<IActionResult> GetPhysicalMasterItems([FromQuery] string locationType, [FromQuery] int? branchId)
    {
        var list = await hkService.GetPhysicalMasterItemsAsync(locationType ?? "Ward", branchId);
        return Ok(ApiResponse<IEnumerable<HKPhysicalMasterItemDto>>.Ok(list));
    }

    // ── Cleaning Master ──────────────────────────────────────────────────────
    [HttpGet("cleanings")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<HKCleaningListItemDto>>), 200)]
    public async Task<IActionResult> GetCleanings(
        [FromQuery] int? branchId,
        [FromQuery] string? cleaningType,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var list = await hkService.GetCleaningsAsync(branchId, cleaningType, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<HKCleaningListItemDto>>.Ok(list));
    }

    [HttpGet("cleanings/{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<HKCleaningDetailDto>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetCleaningById([FromRoute] int id)
    {
        var item = await hkService.GetCleaningByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<object>.Fail("Cleaning protocol not found."));

        return Ok(ApiResponse<HKCleaningDetailDto>.Ok(item));
    }

    [HttpPost("cleanings")]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> CreateCleaning([FromBody] HKCleaningSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.CleaningType))
            return BadRequest(ApiResponse<object>.Fail("Cleaning Type is mandatory."));

        if (string.IsNullOrWhiteSpace(request.Frequency))
            return BadRequest(ApiResponse<object>.Fail("Frequency is mandatory."));

        try
        {
            var newId = await hkService.CreateCleaningAsync(request);
            return CreatedAtAction(nameof(GetCleaningById), new { id = newId }, ApiResponse<int>.Ok(newId, "Cleaning protocol created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("cleanings/{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> UpdateCleaning([FromRoute] int id, [FromBody] HKCleaningSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.CleaningType))
            return BadRequest(ApiResponse<object>.Fail("Cleaning Type is mandatory."));

        try
        {
            var updated = await hkService.UpdateCleaningAsync(id, request);
            return Ok(ApiResponse<bool>.Ok(updated, "Cleaning protocol updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPatch("cleanings/{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> ToggleCleaningStatus([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await hkService.ToggleCleaningStatusAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Cleaning protocol status updated."));
    }

    [HttpDelete("cleanings/{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> DeleteCleaning([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await hkService.DeleteCleaningAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Cleaning protocol deleted successfully."));
    }

    // ── HK Staff Master ──────────────────────────────────────────────────────
    [HttpGet("staff")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<HKStaffListItemDto>>), 200)]
    public async Task<IActionResult> GetStaffList(
        [FromQuery] int? branchId,
        [FromQuery] int? shiftId,
        [FromQuery] int? locationId,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var list = await hkService.GetStaffListAsync(branchId, shiftId, locationId, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<HKStaffListItemDto>>.Ok(list));
    }

    [HttpGet("staff/{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<HKStaffDetailDto>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetStaffById([FromRoute] int id)
    {
        var item = await hkService.GetStaffByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<object>.Fail("Housekeeping staff allocation not found."));

        return Ok(ApiResponse<HKStaffDetailDto>.Ok(item));
    }

    [HttpPost("staff")]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> CreateStaff([FromBody] HKStaffSaveRequest request)
    {
        if (request.Staff_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Staff selection is mandatory."));

        if (request.ShiftMaster_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Shift selection is mandatory."));

        if (request.AreaAllocation_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Area Allocation is mandatory."));

        try
        {
            var newId = await hkService.CreateStaffAsync(request);
            return CreatedAtAction(nameof(GetStaffById), new { id = newId }, ApiResponse<int>.Ok(newId, "Staff allocation created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("staff/{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> UpdateStaff([FromRoute] int id, [FromBody] HKStaffSaveRequest request)
    {
        if (request.Staff_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Staff selection is mandatory."));

        if (request.ShiftMaster_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Shift selection is mandatory."));

        if (request.AreaAllocation_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Area Allocation is mandatory."));

        try
        {
            var updated = await hkService.UpdateStaffAsync(id, request);
            return Ok(ApiResponse<bool>.Ok(updated, "Staff allocation updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPatch("staff/{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> ToggleStaffStatus([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await hkService.ToggleStaffStatusAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Staff status updated."));
    }

    [HttpDelete("staff/{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> DeleteStaff([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await hkService.DeleteStaffAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Staff allocation deleted successfully."));
    }

    // ── Checklist Templates ─────────────────────────────────────────────────
    [HttpGet("checklist-templates")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<HKChecklistTemplateDto>>), 200)]
    public async Task<IActionResult> GetChecklistTemplates([FromQuery] int? branchId)
    {
        var list = await hkService.GetChecklistTemplatesAsync(branchId);
        return Ok(ApiResponse<IEnumerable<HKChecklistTemplateDto>>.Ok(list));
    }
}
