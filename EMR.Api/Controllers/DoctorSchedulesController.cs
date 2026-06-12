using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Security.Claims;
using Microsoft.AspNetCore.Mvc;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class DoctorSchedulesController(IDoctorScheduleService scheduleService) : ControllerBase
    {
        [HttpGet]
        public async Task<ActionResult<ApiResponse<IEnumerable<DoctorScheduleListItem>>>> GetList(
            [FromQuery] int doctorId,
            [FromQuery] int? branchId)
        {
            try
            {
                var schedules = await scheduleService.GetByDoctorAsync(doctorId, branchId);
                return Ok(ApiResponse<IEnumerable<DoctorScheduleListItem>>.Ok(schedules));
            }
            catch (Exception ex)
            {
                return StatusCode(500, ApiResponse<IEnumerable<DoctorScheduleListItem>>.Fail(ex.Message));
            }
        }

        [HttpGet("{id}")]
        public async Task<ActionResult<ApiResponse<DoctorScheduleDetail>>> GetById(int id)
        {
            try
            {
                var schedule = await scheduleService.GetByIdAsync(id);
                if (schedule == null)
                    return NotFound(ApiResponse<DoctorScheduleDetail>.Fail("Schedule not found."));
                
                return Ok(ApiResponse<DoctorScheduleDetail>.Ok(schedule));
            }
            catch (Exception ex)
            {
                return StatusCode(500, ApiResponse<DoctorScheduleDetail>.Fail(ex.Message));
            }
        }

        [HttpPost]
        public async Task<ActionResult<ApiResponse<int>>> Create([FromBody] DoctorScheduleUpsertRequest request)
        {
            try
            {
                request.ScheduleId = 0;
                var id = await scheduleService.UpsertAsync(request);
                return Ok(ApiResponse<int>.Ok(id, "Schedule created successfully."));
            }
            catch (SqlException ex) when (ex.Message.Contains("overlaps") || ex.Message.Contains("must be less than"))
            {
                return BadRequest(ApiResponse<int>.Fail(ex.Message));
            }
            catch (Exception ex)
            {
                return StatusCode(500, ApiResponse<int>.Fail(ex.Message));
            }
        }

        [HttpPut("{id}")]
        public async Task<ActionResult<ApiResponse<int>>> Update(int id, [FromBody] DoctorScheduleUpsertRequest request)
        {
            if (id != request.ScheduleId)
                return BadRequest(ApiResponse<int>.Fail("ID mismatch."));

            try
            {
                var updatedId = await scheduleService.UpsertAsync(request);
                return Ok(ApiResponse<int>.Ok(updatedId, "Schedule updated successfully."));
            }
            catch (SqlException ex) when (ex.Message.Contains("overlaps") || ex.Message.Contains("must be less than"))
            {
                return BadRequest(ApiResponse<int>.Fail(ex.Message));
            }
            catch (Exception ex)
            {
                return StatusCode(500, ApiResponse<int>.Fail(ex.Message));
            }
        }

        [HttpDelete("{id}")]
        public async Task<ActionResult<ApiResponse<object>>> Delete(int id, [FromQuery] int deletedBy)
        {
            try
            {
                var (success, warning) = await scheduleService.DeleteAsync(id, deletedBy);
                if (!success)
                    return NotFound(ApiResponse<object>.Fail("Schedule not found."));

                var message = string.IsNullOrEmpty(warning) ? "Schedule deleted successfully." : warning;
                return Ok(ApiResponse<object>.Ok(new { Warning = warning }, message));
            }
            catch (Exception ex)
            {
                return StatusCode(500, ApiResponse<object>.Fail(ex.Message));
            }
        }

        [HttpGet("availableslots")]
        public async Task<ActionResult<ApiResponse<AvailableSlotsResult>>> GetAvailableSlots(
            [FromQuery] int doctorId,
            [FromQuery] int branchId,
            [FromQuery] DateTime date)
        {
            try
            {
                var result = await scheduleService.GetAvailableSlotsAsync(doctorId, branchId, date);
                return Ok(ApiResponse<AvailableSlotsResult>.Ok(result));
            }
            catch (Exception ex)
            {
                return StatusCode(500, ApiResponse<AvailableSlotsResult>.Fail(ex.Message));
            }
        }

        [HttpGet("exceptions")]
        public async Task<ActionResult<ApiResponse<IEnumerable<DoctorScheduleExceptionListItem>>>> GetExceptions(
            [FromQuery] int doctorId,
            [FromQuery] int? branchId,
            [FromQuery] DateTime? from,
            [FromQuery] DateTime? to)
        {
            try
            {
                var exceptions = await scheduleService.GetExceptionsByDoctorAsync(doctorId, branchId, from, to);
                return Ok(ApiResponse<IEnumerable<DoctorScheduleExceptionListItem>>.Ok(exceptions));
            }
            catch (Exception ex)
            {
                return StatusCode(500, ApiResponse<IEnumerable<DoctorScheduleExceptionListItem>>.Fail(ex.Message));
            }
        }

        [HttpPost("exceptions")]
        public async Task<ActionResult<ApiResponse<int>>> CreateException([FromBody] DoctorScheduleExceptionUpsertRequest request)
        {
            try
            {
                request.ExceptionId = 0;
                var id = await scheduleService.UpsertExceptionAsync(request);
                return Ok(ApiResponse<int>.Ok(id, "Exception added successfully."));
            }
            catch (SqlException ex) when (ex.Message.Contains("already exists"))
            {
                return BadRequest(ApiResponse<int>.Fail(ex.Message));
            }
            catch (Exception ex)
            {
                return StatusCode(500, ApiResponse<int>.Fail(ex.Message));
            }
        }

        [HttpDelete("exceptions/{id}")]
        public async Task<ActionResult<ApiResponse<object>>> DeleteException(int id, [FromQuery] int deletedBy)
        {
            try
            {
                var success = await scheduleService.DeleteExceptionAsync(id, deletedBy);
                if (!success)
                    return NotFound(ApiResponse<object>.Fail("Exception not found."));

                return Ok(ApiResponse<object>.Ok(new object(), "Exception removed successfully."));
            }
            catch (Exception ex)
            {
                return StatusCode(500, ApiResponse<object>.Fail(ex.Message));
            }
        }
    }
}
