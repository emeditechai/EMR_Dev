using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;
using System.Security.Claims;

namespace EMR.Web.Controllers
{
    [Authorize]
    public class DoctorSchedulesController : Controller
    {
        private readonly IDoctorScheduleApiClient _scheduleApiClient;
        private readonly IDoctorApiClient _doctorApiClient;
        
        public DoctorSchedulesController(
            IDoctorScheduleApiClient scheduleApiClient,
            IDoctorApiClient doctorApiClient)
        {
            _scheduleApiClient = scheduleApiClient;
            _doctorApiClient = doctorApiClient;
        }

        private int GetCurrentUserId()
        {
            return int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var id) ? id : 0;
        }

        private int GetCurrentBranchId()
        {
            return int.TryParse(User.FindFirstValue("BranchId"), out var id) ? id : 0;
        }

        [HttpGet]
        public async Task<IActionResult> Configure(int doctorId)
        {
            var branchId = GetCurrentBranchId();
            var doctor = await _doctorApiClient.GetByIdAsync(doctorId, branchId);
            
            if (doctor == null)
            {
                TempData["ErrorMessage"] = "Doctor not found or you do not have access.";
                return RedirectToAction("Index", "Doctors");
            }

            var schedules = await _scheduleApiClient.GetByDoctorAsync(doctorId, branchId);
            var exceptions = await _scheduleApiClient.GetExceptionsAsync(doctorId, branchId);

            // Create SelectList for Days of Week
            var days = new List<SelectListItem>
            {
                new() { Value = "1", Text = "Monday" },
                new() { Value = "2", Text = "Tuesday" },
                new() { Value = "3", Text = "Wednesday" },
                new() { Value = "4", Text = "Thursday" },
                new() { Value = "5", Text = "Friday" },
                new() { Value = "6", Text = "Saturday" },
                new() { Value = "7", Text = "Sunday" }
            };

            var model = new DoctorScheduleIndexViewModel
            {
                DoctorId = doctorId,
                DoctorName = doctor.FullName,
                Schedules = schedules,
                Exceptions = exceptions,
                DayOfWeekOptions = new SelectList(days, "Value", "Text")
                // RoomOptions can be added if you have a RoomApiClient or similar
            };

            return View(model);
        }

        [HttpGet]
        public async Task<IActionResult> GetSchedules(int doctorId)
        {
            var branchId = GetCurrentBranchId();
            var schedules = await _scheduleApiClient.GetByDoctorAsync(doctorId, branchId);
            return Json(schedules);
        }

        [HttpGet]
        public async Task<IActionResult> GetExceptions(int doctorId)
        {
            var branchId = GetCurrentBranchId();
            var exceptions = await _scheduleApiClient.GetExceptionsAsync(doctorId, branchId);
            return Json(exceptions);
        }

        public class DoctorScheduleMultiUpsertRequest : DoctorScheduleUpsertRequest
        {
            public List<byte> DaysOfWeek { get; set; } = new List<byte>();
        }

        [HttpPost]
        public async Task<IActionResult> SaveSchedule([FromBody] DoctorScheduleMultiUpsertRequest request)
        {
            try
            {
                request.BranchId = GetCurrentBranchId();
                request.RequestedByUserId = GetCurrentUserId();

                var daysToProcess = request.DaysOfWeek != null && request.DaysOfWeek.Any() 
                    ? request.DaysOfWeek 
                    : new List<byte> { request.DayOfWeek };

                bool allSuccess = true;
                string lastError = "";

                foreach (var day in daysToProcess)
                {
                    request.DayOfWeek = day;
                    // If multiple days are selected, we must be creating new records (ScheduleId = 0)
                    // If ScheduleId > 0, we only process the first/single day.
                    var reqToSent = new DoctorScheduleUpsertRequest
                    {
                        ScheduleId = daysToProcess.Count > 1 ? 0 : request.ScheduleId,
                        DoctorId = request.DoctorId,
                        BranchId = request.BranchId,
                        RoomId = request.RoomId,
                        DayOfWeek = request.DayOfWeek,
                        StartTime = request.StartTime,
                        EndTime = request.EndTime,
                        SlotDurationMinutes = request.SlotDurationMinutes,
                        MaxPatientsPerSlot = request.MaxPatientsPerSlot,
                        MaxPatientsPerSession = request.MaxPatientsPerSession,
                        ScheduleType = request.ScheduleType,
                        EffectiveFrom = request.EffectiveFrom,
                        EffectiveTo = request.EffectiveTo,
                        RequestedByUserId = request.RequestedByUserId
                    };

                    var newId = await _scheduleApiClient.UpsertAsync(reqToSent);
                    if (!newId.HasValue)
                    {
                        allSuccess = false;
                        lastError = $"Failed to save schedule for day {day}. Ensure times don't overlap.";
                    }
                }

                if (allSuccess)
                {
                    return Json(new { success = true, message = "Schedule saved successfully." });
                }
                return Json(new { success = false, message = lastError });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, message = ex.Message });
            }
        }

        [HttpPost]
        public async Task<IActionResult> DeleteSchedule(int id)
        {
            var deletedBy = GetCurrentUserId();
            var result = await _scheduleApiClient.DeleteAsync(id, deletedBy);
            
            if (result.Success)
            {
                return Json(new { success = true, message = result.Warning ?? "Schedule deleted." });
            }
            
            return Json(new { success = false, message = "Failed to delete schedule." });
        }

        public class DoctorScheduleMultiExceptionRequest : DoctorScheduleExceptionUpsertRequest
        {
            public DateTime ExceptionDateFrom { get; set; }
            public DateTime ExceptionDateTo { get; set; }
        }

        [HttpPost]
        public async Task<IActionResult> SaveException([FromBody] DoctorScheduleMultiExceptionRequest request)
        {
            try
            {
                request.BranchId = GetCurrentBranchId();
                request.RequestedByUserId = GetCurrentUserId();

                var startDate = request.ExceptionDateFrom.Date;
                var endDate = request.ExceptionDateTo.Date;

                if (endDate < startDate)
                {
                    endDate = startDate; // fallback
                }

                bool allSuccess = true;

                for (var date = startDate; date <= endDate; date = date.AddDays(1))
                {
                    var reqToSent = new DoctorScheduleExceptionUpsertRequest
                    {
                        ExceptionId = request.ExceptionId, // Note: For multi-day, this would ideally be 0 to create new ones, but we leave it as is. If it's > 0, they are editing a single date.
                        DoctorId = request.DoctorId,
                        BranchId = request.BranchId,
                        ExceptionDate = date,
                        ExceptionType = request.ExceptionType,
                        Reason = request.Reason,
                        RequestedByUserId = request.RequestedByUserId
                    };
                    
                    // If creating multi-day exceptions, ensure new records
                    if (startDate != endDate)
                    {
                        reqToSent.ExceptionId = 0; 
                    }

                    var newId = await _scheduleApiClient.UpsertExceptionAsync(reqToSent);
                    if (!newId.HasValue)
                    {
                        allSuccess = false;
                    }
                }

                if (allSuccess)
                {
                    return Json(new { success = true, message = "Exception(s) saved successfully." });
                }
                return Json(new { success = false, message = "Failed to save some or all exceptions." });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, message = ex.Message });
            }
        }

        [HttpPost]
        public async Task<IActionResult> DeleteException(int id)
        {
            var deletedBy = GetCurrentUserId();
            var success = await _scheduleApiClient.DeleteExceptionAsync(id, deletedBy);
            
            if (success)
            {
                return Json(new { success = true, message = "Exception deleted." });
            }
            
            return Json(new { success = false, message = "Failed to delete exception." });
        }
    }
}
