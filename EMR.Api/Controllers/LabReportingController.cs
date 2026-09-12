using System;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Mvc;
using EMR.Api.Models;
using EMR.Api.Services;

namespace EMR.Api.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class LabReportingController(ILabReportingService labReportingService) : ControllerBase
    {
        [HttpGet("headers")]
        public async Task<IActionResult> GetHeaderList(
            [FromQuery] int branchId,
            [FromQuery] DateTime? fromDate,
            [FromQuery] DateTime? toDate,
            [FromQuery] string? dateFilterType = "BookingDate",
            [FromQuery] string? statusFilter = "All",
            [FromQuery] string? search = null,
            [FromQuery] int? departmentId = null,
            [FromQuery] int? categoryId = null,
            [FromQuery] int? subCategoryId = null)
        {
            if (branchId <= 0) return BadRequest("BranchId is required.");

            if (toDate.HasValue && toDate.Value.TimeOfDay == TimeSpan.Zero)
            {
                toDate = toDate.Value.Date.AddDays(1).AddSeconds(-1);
            }

            var result = await labReportingService.GetHeaderListAsync(
                branchId, fromDate, toDate, dateFilterType, statusFilter, search, departmentId, categoryId, subCategoryId);
            return Ok(result);
        }

        [HttpGet("detail/{labOrderId}")]
        public async Task<IActionResult> GetDetail(int labOrderId)
        {
            if (labOrderId <= 0) return BadRequest("Valid LabOrderId is required.");

            var result = await labReportingService.GetDetailAsync(labOrderId);
            if (result == null) return NotFound("Lab Order reporting details not found.");

            return Ok(result);
        }

        [HttpGet("statuses")]
        public async Task<IActionResult> GetStatuses()
        {
            var result = await labReportingService.GetStatusesAsync();
            return Ok(result);
        }

        [HttpPost("save-entry")]
        public async Task<IActionResult> SaveEntry([FromBody] SaveLabReportingRequestDto request)
        {
            if (request.LabOrderId <= 0)
                return BadRequest("Valid LabOrderId is required.");
            if (request.ReportStatusId <= 0)
                return BadRequest("Valid ReportStatusId is required.");

            var userIdClaim = User.FindFirst("UserId")?.Value;
            int userId = int.TryParse(userIdClaim, out var uid) ? uid : 1;

            try
            {
                int count = await labReportingService.SaveEntryAsync(request, userId);
                return Ok(new { isSuccess = true, count });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { isSuccess = false, message = ex.Message });
            }
        }
    }
}
