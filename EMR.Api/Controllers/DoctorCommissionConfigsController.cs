using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/doctor-commission-configs")]
[Produces("application/json")]
public class DoctorCommissionConfigsController(IDoctorCommissionService service) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<DoctorCommissionConfigDto>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId = null,
        [FromQuery] int? doctorId = null,
        [FromQuery] int? specialityId = null,
        [FromQuery] string? revenueType = null,
        [FromQuery] bool? isActive = null,
        [FromQuery] string? search = null,
        [FromQuery] int? companyId = null)
    {
        var list = await service.GetCommissionConfigsAsync(branchId, doctorId, specialityId, revenueType, isActive, search, companyId);
        return Ok(ApiResponse<IEnumerable<DoctorCommissionConfigDto>>.Ok(list));
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<DoctorCommissionConfigDto>), 200)]
    [ProducesResponseType(404)]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetCommissionConfigByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<DoctorCommissionConfigDto>.Fail($"Doctor Commission Config #{id} not found."));

        return Ok(ApiResponse<DoctorCommissionConfigDto>.Ok(item));
    }

    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    public async Task<IActionResult> Save([FromBody] DoctorCommissionConfigSaveRequest request)
    {
        var id = await service.SaveCommissionConfigAsync(request);
        return CreatedAtAction(nameof(GetById), new { id }, ApiResponse<int>.Ok(id, "Doctor Commission Configuration saved successfully."));
    }

    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await service.DeleteCommissionConfigAsync(id);
        if (!deleted)
            return NotFound(ApiResponse<bool>.Fail($"Doctor Commission Config #{id} not found."));

        return Ok(ApiResponse<bool>.Ok(true, "Doctor Commission Configuration deleted successfully."));
    }
}
