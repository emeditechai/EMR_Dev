using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/doctor-ip-commission")]
[Produces("application/json")]
public class DoctorIpCommissionController(IDoctorIpCommissionService service) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetList([FromQuery] int? branchId, [FromQuery] int? doctorId,
        [FromQuery] DateTime? fromDate, [FromQuery] DateTime? toDate, [FromQuery] int? companyId)
        => Ok(ApiResponse<IEnumerable<DoctorIpCommissionListItem>>.Ok(
            await service.GetListAsync(branchId, doctorId, fromDate, toDate, companyId)));

    [HttpGet("{id:long}")]
    public async Task<IActionResult> GetDetail(long id)
    {
        var item = await service.GetDetailAsync(id);
        return item == null
            ? NotFound(ApiResponse<object>.Fail("Commission record not found."))
            : Ok(ApiResponse<DoctorIpCommissionDetail>.Ok(item));
    }

    [HttpGet("pending")]
    public async Task<IActionResult> GetPending([FromQuery] int branchId, [FromQuery] int? doctorId,
        [FromQuery] DateTime? fromDate, [FromQuery] DateTime? toDate, [FromQuery] int? companyId)
        => Ok(ApiResponse<IEnumerable<DoctorIpCommissionPendingItem>>.Ok(
            await service.GetPendingAsync(branchId, doctorId, fromDate, toDate, companyId)));

    [HttpPost("calculate")]
    public async Task<IActionResult> Calculate([FromBody] DoctorIpCommissionCalculateRequest req)
    {
        try
        {
            var results = await service.CalculateAsync(req);
            return Ok(ApiResponse<IEnumerable<DoctorIpCommissionCalculateResult>>.Ok(results, "Commission calculated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpGet("due-schedules")]
    public async Task<IActionResult> GetDueSchedules([FromQuery] DateTime? today, [FromQuery] int? branchId)
        => Ok(ApiResponse<IEnumerable<DoctorIpCommissionDueSchedule>>.Ok(
            await service.GetDueSchedulesAsync(today ?? DateTime.Today, branchId)));
}
