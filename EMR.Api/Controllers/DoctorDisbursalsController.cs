using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/doctor-disbursals")]
[Produces("application/json")]
public class DoctorDisbursalsController(IDoctorCommissionService service) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<DoctorDisbursalDto>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId = null,
        [FromQuery] int? doctorId = null,
        [FromQuery] string? settlementPeriod = null,
        [FromQuery] string? approvalStatus = null,
        [FromQuery] string? paymentStatus = null,
        [FromQuery] DateTime? fromDate = null,
        [FromQuery] DateTime? toDate = null,
        [FromQuery] string? search = null,
        [FromQuery] int? companyId = null)
    {
        var list = await service.GetDisbursalsAsync(branchId, doctorId, settlementPeriod, approvalStatus, paymentStatus, fromDate, toDate, search, companyId);
        return Ok(ApiResponse<IEnumerable<DoctorDisbursalDto>>.Ok(list));
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<DoctorDisbursalDetailDto>), 200)]
    [ProducesResponseType(404)]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetDisbursalByIdAsync(id);
        if (item is null)
            return NotFound(ApiResponse<DoctorDisbursalDetailDto>.Fail($"Disbursal record #{id} not found."));

        return Ok(ApiResponse<DoctorDisbursalDetailDto>.Ok(item));
    }

    [HttpPost("calculate")]
    [ProducesResponseType(typeof(ApiResponse<int>), 200)]
    public async Task<IActionResult> Calculate([FromBody] DoctorDisbursalCalculateRequest request)
    {
        var count = await service.CalculateDisbursalsAsync(request);
        return Ok(ApiResponse<int>.Ok(count, $"Commission calculation completed. {count} new record(s) processed."));
    }

    [HttpPost("adjustment")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> UpdateAdjustment([FromBody] DoctorDisbursalAdjustmentRequest request)
    {
        var success = await service.UpdateAdjustmentAsync(request);
        return Ok(ApiResponse<bool>.Ok(success, "Adjustment recorded successfully."));
    }

    [HttpPost("status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> UpdateStatus([FromBody] DoctorDisbursalStatusRequest request)
    {
        var success = await service.UpdateStatusAsync(request);
        return Ok(ApiResponse<bool>.Ok(success, "Disbursal status updated."));
    }

    [HttpPost("bulk-approve")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> BulkApprove([FromBody] DoctorDisbursalBulkApproveRequest request)
    {
        var success = await service.BulkApproveAsync(request);
        return Ok(ApiResponse<bool>.Ok(success, "Selected disbursals approved successfully."));
    }

    [HttpPost("payout")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    public async Task<IActionResult> ProcessPayout([FromBody] DoctorDisbursalPayoutRequest request)
    {
        var success = await service.ProcessPayoutAsync(request);
        return Ok(ApiResponse<bool>.Ok(success, "Payout processed successfully."));
    }
}
