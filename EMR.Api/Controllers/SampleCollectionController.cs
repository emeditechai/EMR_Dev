using System;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Mvc;
using EMR.Api.Models;
using EMR.Api.Services;

namespace EMR.Api.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class SampleCollectionController(ISampleCollectionService sampleCollectionService) : ControllerBase
    {
        [HttpGet("headers")]
        public async Task<IActionResult> GetHeaderList(
            [FromQuery] int branchId,
            [FromQuery] DateTime? fromDate,
            [FromQuery] DateTime? toDate,
            [FromQuery] string? dateFilterType = "BookingDate",
            [FromQuery] string? statusFilter = "All",
            [FromQuery] string? search = null)
        {
            if (branchId <= 0) return BadRequest("BranchId is required.");

            if (toDate.HasValue && toDate.Value.TimeOfDay == TimeSpan.Zero)
            {
                toDate = toDate.Value.Date.AddDays(1).AddSeconds(-1);
            }

            var result = await sampleCollectionService.GetHeaderListAsync(
                branchId, fromDate, toDate, dateFilterType, statusFilter, search);
            return Ok(result);
        }

        [HttpGet("detail/{labOrderId}")]
        public async Task<IActionResult> GetDetail(int labOrderId)
        {
            if (labOrderId <= 0) return BadRequest("Valid LabOrderId is required.");

            var result = await sampleCollectionService.GetDetailAsync(labOrderId);
            if (result == null) return NotFound("Lab Order sample details not found.");

            return Ok(result);
        }

        [HttpPost("update-status")]
        public async Task<IActionResult> UpdateStatus([FromBody] UpdateSampleCollectionStatusRequestDto request)
        {
            if (request.SampleCollectionId <= 0 || request.CollectionstatusID <= 0)
                return BadRequest("Valid SampleCollectionId and CollectionstatusID are required.");

            var userIdClaim = User.FindFirst("UserId")?.Value;
            int userId = int.TryParse(userIdClaim, out var uid) ? uid : 1;

            try
            {
                bool success = await sampleCollectionService.UpdateStatusAsync(request, userId);
                return Ok(new { isSuccess = success });
            }
            catch (Exception ex)
            {
                return BadRequest(new { isSuccess = false, message = ex.Message });
            }
        }

        [HttpPost("update-profile-status")]
        public async Task<IActionResult> UpdateProfileStatus([FromBody] UpdateProfileSampleCollectionStatusRequestDto request)
        {
            if (request.LabOrderId <= 0 || request.CollectionstatusID <= 0 || (request.ProfileId == null && string.IsNullOrEmpty(request.ProfileName)))
                return BadRequest("Valid LabOrderId, Profile identifier, and CollectionstatusID are required.");

            var userIdClaim = User.FindFirst("UserId")?.Value;
            int userId = int.TryParse(userIdClaim, out var uid) ? uid : 1;

            try
            {
                int count = await sampleCollectionService.UpdateProfileStatusAsync(request, userId);
                return Ok(new { isSuccess = true, count = count });
            }
            catch (Exception ex)
            {
                return BadRequest(new { isSuccess = false, message = ex.Message });
            }
        }

        [HttpPost("collect-all")]
        public async Task<IActionResult> CollectAll([FromBody] CollectAllSamplesRequestDto request)
        {
            if (request.LabOrderId <= 0)
                return BadRequest("Valid LabOrderId is required.");

            var userIdClaim = User.FindFirst("UserId")?.Value;
            int userId = int.TryParse(userIdClaim, out var uid) ? uid : 1;

            try
            {
                int updatedCount = await sampleCollectionService.CollectAllAsync(request.LabOrderId, userId);
                return Ok(new { isSuccess = true, count = updatedCount });
            }
            catch (Exception ex)
            {
                return BadRequest(new { isSuccess = false, message = ex.Message });
            }
        }

        [HttpPost("auto-collect-if-not-mandatory")]
        public async Task<IActionResult> AutoCollectIfNotMandatory([FromBody] CollectAllSamplesRequestDto request)
        {
            if (request.LabOrderId <= 0)
                return BadRequest("Valid LabOrderId is required.");

            var userIdClaim = User.FindFirst("UserId")?.Value;
            int userId = int.TryParse(userIdClaim, out var uid) ? uid : 1;

            try
            {
                int updatedCount = await sampleCollectionService.AutoCollectIfNotMandatoryAsync(request.LabOrderId, userId);
                return Ok(new { isSuccess = true, count = updatedCount });
            }
            catch (Exception ex)
            {
                return BadRequest(new { isSuccess = false, message = ex.Message });
            }
        }

        [HttpGet("statuses")]
        public async Task<IActionResult> GetStatuses()
        {
            var result = await sampleCollectionService.GetStatusesAsync();
            return Ok(result);
        }
    }
}
