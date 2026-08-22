using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Hospital Package Master API</summary>
[ApiController]
[Route("api/hospital-packages")]
[Produces("application/json")]
public class HospitalPackagesController(IHospitalPackageService packageService) : ControllerBase
{
    /// <summary>Get list of hospital packages with optional filters</summary>
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<HospitalPackageListItemDto>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId,
        [FromQuery] string? packageType,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var list = await packageService.GetListAsync(branchId, packageType, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<HospitalPackageListItemDto>>.Ok(list));
    }

    /// <summary>Get single hospital package with its dynamic details by ID</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<HospitalPackageHeaderDto>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById([FromRoute] int id)
    {
        var item = await packageService.GetByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<object>.Fail("Hospital Package not found."));

        return Ok(ApiResponse<HospitalPackageHeaderDto>.Ok(item));
    }

    /// <summary>Create a new hospital package along with dynamic details</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] HospitalPackageSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Package_Code) || string.IsNullOrWhiteSpace(request.Package_Name))
            return BadRequest(ApiResponse<object>.Fail("Package Code and Package Name are required."));

        try
        {
            var newId = await packageService.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Hospital Package created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Update an existing hospital package and its dynamic details</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update([FromRoute] int id, [FromBody] HospitalPackageSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Package_Code) || string.IsNullOrWhiteSpace(request.Package_Name))
            return BadRequest(ApiResponse<object>.Fail("Package Code and Package Name are required."));

        try
        {
            var updated = await packageService.UpdateAsync(id, request);
            return Ok(ApiResponse<bool>.Ok(updated, "Hospital Package updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Toggle Active/Inactive status of a package</summary>
    [HttpPatch("{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> ToggleStatus([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await packageService.ToggleStatusAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Hospital Package status updated."));
    }

    /// <summary>Delete a hospital package</summary>
    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> Delete([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await packageService.DeleteAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Hospital Package deleted successfully."));
    }

    /// <summary>Get master reference lookups for Bed, Room, Procedure, Doctor fee, Nursing, OT, Anaesthesia, Consumables, Equipment, Services</summary>
    [HttpGet("lookups")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<MasterLookupItemDto>>), 200)]
    public async Task<IActionResult> GetMasterLookups([FromQuery] int? branchId, [FromQuery] int? companyId)
    {
        var list = await packageService.GetMasterLookupsAsync(branchId, companyId);
        return Ok(ApiResponse<IEnumerable<MasterLookupItemDto>>.Ok(list));
    }
}
