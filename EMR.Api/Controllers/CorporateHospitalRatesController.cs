using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Corporate Hospital Rate Master API</summary>
[ApiController]
[Route("api/corporate-rates")]
[Produces("application/json")]
public class CorporateHospitalRatesController(ICorporateHospitalRateService rateService) : ControllerBase
{
    /// <summary>Get list of corporate hospital rate rules</summary>
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<CorporateHospitalRateListItemDto>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? corporateId,
        [FromQuery] int? branchId,
        [FromQuery] string? rateServiceType,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var list = await rateService.GetListAsync(corporateId, branchId, rateServiceType, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<CorporateHospitalRateListItemDto>>.Ok(list));
    }

    /// <summary>Get single corporate hospital rate rule by ID</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<CorporateHospitalRateDetailDto>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById([FromRoute] int id)
    {
        var item = await rateService.GetByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<object>.Fail("Corporate rate rule not found."));

        return Ok(ApiResponse<CorporateHospitalRateDetailDto>.Ok(item));
    }

    /// <summary>Create a new corporate hospital rate rule</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] CorporateHospitalRateSaveRequest request)
    {
        if (request.Corporate_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Valid Corporate ID is mandatory."));

        if (string.IsNullOrWhiteSpace(request.RateServiceType))
            return BadRequest(ApiResponse<object>.Fail("Rate Service Type is mandatory."));

        if (request.ReferenceMaster_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Reference Master Service item is mandatory."));

        if (request.Effective_To < request.Effective_From)
            return BadRequest(ApiResponse<object>.Fail("Effective To date cannot be earlier than Effective From date."));

        try
        {
            var newId = await rateService.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Corporate rate rule created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Update an existing corporate hospital rate rule</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update([FromRoute] int id, [FromBody] CorporateHospitalRateSaveRequest request)
    {
        if (request.Corporate_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Valid Corporate ID is mandatory."));

        if (string.IsNullOrWhiteSpace(request.RateServiceType))
            return BadRequest(ApiResponse<object>.Fail("Rate Service Type is mandatory."));

        if (request.ReferenceMaster_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Reference Master Service item is mandatory."));

        if (request.Effective_To < request.Effective_From)
            return BadRequest(ApiResponse<object>.Fail("Effective To date cannot be earlier than Effective From date."));

        try
        {
            var updated = await rateService.UpdateAsync(id, request);
            return Ok(ApiResponse<bool>.Ok(updated, "Corporate rate rule updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Toggle Active/Inactive status of a corporate rate rule</summary>
    [HttpPatch("{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> ToggleStatus([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await rateService.ToggleStatusAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Corporate rate status updated."));
    }

    /// <summary>Delete a corporate rate rule</summary>
    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> Delete([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await rateService.DeleteAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Corporate rate rule deleted successfully."));
    }

    /// <summary>Get dynamic master items by service type (Room, Procedure, OT, ICU, HospitalService, Package)</summary>
    [HttpGet("master-items")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<MasterServiceItemDto>>), 200)]
    public async Task<IActionResult> GetMasterItems(
        [FromQuery] string? serviceType,
        [FromQuery] int? branchId,
        [FromQuery] int? companyId)
    {
        var items = await rateService.GetMasterItemsAsync(serviceType, branchId, companyId);
        return Ok(ApiResponse<IEnumerable<MasterServiceItemDto>>.Ok(items));
    }
}
