using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/doctor-visit-process-configs")]
[Produces("application/json")]
public class DoctorVisitProcessConfigsController(IDoctorCommissionService service) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<DoctorVisitProcessConfigDto>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId = null,
        [FromQuery] int? specialityId = null,
        [FromQuery] int? doctorId = null,
        [FromQuery] string? visitType = null,
        [FromQuery] bool? isActive = null,
        [FromQuery] string? search = null,
        [FromQuery] int? companyId = null)
    {
        var list = await service.GetProcessConfigsAsync(branchId, specialityId, doctorId, visitType, isActive, search, companyId);
        return Ok(ApiResponse<IEnumerable<DoctorVisitProcessConfigDto>>.Ok(list));
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<DoctorVisitProcessConfigDto>), 200)]
    [ProducesResponseType(404)]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetProcessConfigByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<DoctorVisitProcessConfigDto>.Fail($"Process Config #{id} not found."));

        return Ok(ApiResponse<DoctorVisitProcessConfigDto>.Ok(item));
    }

    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    public async Task<IActionResult> Save([FromBody] DoctorVisitProcessConfigSaveRequest request)
    {
        var id = await service.SaveProcessConfigAsync(request);
        return CreatedAtAction(nameof(GetById), new { id }, ApiResponse<int>.Ok(id, "Process Configuration saved successfully."));
    }

    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await service.DeleteProcessConfigAsync(id);
        if (!deleted)
            return NotFound(ApiResponse<bool>.Fail($"Process Config #{id} not found."));

        return Ok(ApiResponse<bool>.Ok(true, "Process Configuration deleted successfully."));
    }
}
