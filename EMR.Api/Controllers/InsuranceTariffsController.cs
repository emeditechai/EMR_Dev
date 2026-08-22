using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Insurance Tariff Configuration API</summary>
[ApiController]
[Route("api/insurance-tariffs")]
[Produces("application/json")]
public class InsuranceTariffsController(IInsuranceTariffService tariffService) : ControllerBase
{
    /// <summary>Get list of insurance tariff rules</summary>
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<InsuranceTariffListItemDto>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? insuranceTpaId,
        [FromQuery] int? branchId,
        [FromQuery] string? entitlementType,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var list = await tariffService.GetListAsync(insuranceTpaId, branchId, entitlementType, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<InsuranceTariffListItemDto>>.Ok(list));
    }

    /// <summary>Get single insurance tariff rule by ID</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<InsuranceTariffDetailDto>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById([FromRoute] int id)
    {
        var item = await tariffService.GetByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<object>.Fail("Insurance tariff rule not found."));

        return Ok(ApiResponse<InsuranceTariffDetailDto>.Ok(item));
    }

    /// <summary>Create a new insurance tariff rule</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] InsuranceTariffSaveRequest request)
    {
        if (request.InsuranceTPA_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Valid Insurance / TPA ID is mandatory."));

        if (string.IsNullOrWhiteSpace(request.EntitlementType))
            return BadRequest(ApiResponse<object>.Fail("Entitlement Type is mandatory."));

        if (request.Reference_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Reference Master Service item is mandatory."));

        if (request.Effective_To < request.Effective_From)
            return BadRequest(ApiResponse<object>.Fail("Effective To date cannot be earlier than Effective From date."));

        try
        {
            var newId = await tariffService.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Insurance tariff rule created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Update an existing insurance tariff rule</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update([FromRoute] int id, [FromBody] InsuranceTariffSaveRequest request)
    {
        if (request.InsuranceTPA_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Valid Insurance / TPA ID is mandatory."));

        if (string.IsNullOrWhiteSpace(request.EntitlementType))
            return BadRequest(ApiResponse<object>.Fail("Entitlement Type is mandatory."));

        if (request.Reference_ID <= 0)
            return BadRequest(ApiResponse<object>.Fail("Reference Master Service item is mandatory."));

        if (request.Effective_To < request.Effective_From)
            return BadRequest(ApiResponse<object>.Fail("Effective To date cannot be earlier than Effective From date."));

        try
        {
            var updated = await tariffService.UpdateAsync(id, request);
            return Ok(ApiResponse<bool>.Ok(updated, "Insurance tariff rule updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    /// <summary>Toggle Active/Inactive status of an insurance tariff rule</summary>
    [HttpPatch("{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> ToggleStatus([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await tariffService.ToggleStatusAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Insurance tariff status updated."));
    }

    /// <summary>Delete an insurance tariff rule</summary>
    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> Delete([FromRoute] int id, [FromQuery] int? userId)
    {
        var result = await tariffService.DeleteAsync(id, userId);
        return Ok(ApiResponse<bool>.Ok(result, "Insurance tariff rule deleted successfully."));
    }

    /// <summary>Get dynamic master items by entitlement type (Room, Package, Procedure, HospitalService, NonPayableItem)</summary>
    [HttpGet("master-items")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<InsuranceMasterServiceItemDto>>), 200)]
    public async Task<IActionResult> GetMasterItems(
        [FromQuery] string? entitlementType,
        [FromQuery] int? branchId,
        [FromQuery] int? companyId)
    {
        var items = await tariffService.GetMasterItemsAsync(entitlementType, branchId, companyId);
        return Ok(ApiResponse<IEnumerable<InsuranceMasterServiceItemDto>>.Ok(items));
    }
}
