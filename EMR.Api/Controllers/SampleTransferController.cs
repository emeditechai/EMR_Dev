using System;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Mvc;
using EMR.Api.Models;
using EMR.Api.Services;

namespace EMR.Api.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class SampleTransferController(ISampleTransferService sampleTransferService) : ControllerBase
    {
        [HttpGet("eligible")]
        public async Task<IActionResult> GetEligibleSamples(
            [FromQuery] int sourceBranchId,
            [FromQuery] DateTime? fromDate,
            [FromQuery] DateTime? toDate,
            [FromQuery] string? dateFilterType = "CollectionDate",
            [FromQuery] string? transferStatusFilter = "Ready",
            [FromQuery] string? search = null,
            [FromQuery] int? departmentId = null,
            [FromQuery] int? categoryId = null,
            [FromQuery] int? subCategoryId = null)
        {
            if (sourceBranchId <= 0)
                return BadRequest("Valid sourceBranchId is required.");

            if (toDate.HasValue && toDate.Value.TimeOfDay == TimeSpan.Zero)
            {
                toDate = toDate.Value.Date.AddDays(1).AddSeconds(-1);
            }

            var result = await sampleTransferService.GetEligibleSamplesAsync(
                sourceBranchId, fromDate, toDate, dateFilterType, transferStatusFilter, search, departmentId, categoryId, subCategoryId);

            return Ok(result);
        }

        [HttpPost("execute")]
        public async Task<IActionResult> ExecuteTransfer([FromBody] ExecuteSampleTransferRequestDto request)
        {
            if (request == null || request.SampleCollectionIds == null || request.SampleCollectionIds.Count == 0)
                return BadRequest("No samples selected for transfer.");

            if (request.SourceBranchId <= 0 || request.TargetBranchId <= 0)
                return BadRequest("Source and target branches are required.");

            if (request.SourceBranchId == request.TargetBranchId)
                return BadRequest("Source and target branch cannot be the same.");

            var userIdClaim = User.FindFirst("UserId")?.Value;
            int userId = request.UserId ?? (int.TryParse(userIdClaim, out var uid) ? uid : 1);

            try
            {
                var result = await sampleTransferService.ExecuteTransferAsync(request, userId);
                return Ok(result);
            }
            catch (Exception ex)
            {
                return StatusCode(500, new ExecuteSampleTransferResponseDto
                {
                    IsSuccess = false,
                    Message = ex.Message
                });
            }
        }

        [HttpGet("history")]
        public async Task<IActionResult> GetTransferHistory(
            [FromQuery] int branchId,
            [FromQuery] string? mode = "Outgoing",
            [FromQuery] DateTime? fromDate = null,
            [FromQuery] DateTime? toDate = null,
            [FromQuery] string? search = null)
        {
            if (branchId <= 0)
                return BadRequest("Valid branchId is required.");

            if (toDate.HasValue && toDate.Value.TimeOfDay == TimeSpan.Zero)
            {
                toDate = toDate.Value.Date.AddDays(1).AddSeconds(-1);
            }

            var list = await sampleTransferService.GetTransferHistoryAsync(
                branchId, mode, fromDate, toDate, search);

            return Ok(list);
        }

        [HttpGet("target-branches")]
        public async Task<IActionResult> GetTargetBranches([FromQuery] int currentBranchId = 0)
        {
            var list = await sampleTransferService.GetTargetBranchesAsync(currentBranchId);
            return Ok(list);
        }

        [HttpGet("receivable")]
        public async Task<IActionResult> GetReceivableSamples(
            [FromQuery] int targetBranchId,
            [FromQuery] DateTime? fromDate,
            [FromQuery] DateTime? toDate,
            [FromQuery] string? dateFilterType = "ReceivedDate",
            [FromQuery] string? receiveStatusFilter = "Pending",
            [FromQuery] string? search = null,
            [FromQuery] int? departmentId = null,
            [FromQuery] int? categoryId = null,
            [FromQuery] int? subCategoryId = null)
        {
            if (targetBranchId <= 0)
                return BadRequest("Valid targetBranchId is required.");

            if (toDate.HasValue && toDate.Value.TimeOfDay == TimeSpan.Zero)
            {
                toDate = toDate.Value.Date.AddDays(1).AddSeconds(-1);
            }

            var result = await sampleTransferService.GetReceivableSamplesAsync(
                targetBranchId, fromDate, toDate, dateFilterType, receiveStatusFilter, search, departmentId, categoryId, subCategoryId);

            return Ok(result);
        }

        [HttpGet("worksheet-data")]
        public async Task<IActionResult> GetWorksheetData([FromQuery] string sampleCollectionIds)
        {
            if (string.IsNullOrWhiteSpace(sampleCollectionIds))
                return BadRequest("sampleCollectionIds is required.");

            try
            {
                var result = await sampleTransferService.GetWorksheetDataAsync(sampleCollectionIds);
                return Ok(result);
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { message = ex.Message });
            }
        }

        [HttpPost("receive")]
        public async Task<IActionResult> ExecuteReceive([FromBody] ReceiveSampleTransferRequestDto request)
        {
            if (request == null || request.SampleCollectionIds == null || request.SampleCollectionIds.Count == 0)
                return BadRequest("No samples selected for receiving.");

            if (request.TargetBranchId <= 0)
                return BadRequest("Target branch is required.");

            var userIdClaim = User.FindFirst("UserId")?.Value;
            int userId = request.UserId ?? (int.TryParse(userIdClaim, out var uid) ? uid : 1);

            try
            {
                var result = await sampleTransferService.ReceiveSamplesAsync(request, userId);
                return Ok(result);
            }
            catch (Exception ex)
            {
                return StatusCode(500, new ReceiveSampleTransferResponseDto
                {
                    IsSuccess = false,
                    Message = ex.Message
                });
            }
        }
    }
}
