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
using EMR.Web.Services;
using System.Security.Claims;

namespace EMR.Web.Controllers
{
    [Authorize]
    public class DoctorSchedulesController : Controller
    {
        private readonly IDoctorScheduleApiClient _scheduleApiClient;
        private readonly IDoctorApiClient _doctorApiClient;
        // OPD Doctor Roster Notification (SQLScripts/2528): a roster change is sent to the doctor and the chosen users
        private readonly IDoctorRosterNotificationService _rosterNotify;

        public DoctorSchedulesController(
            IDoctorScheduleApiClient scheduleApiClient,
            IDoctorApiClient doctorApiClient,
            IDoctorRosterNotificationService rosterNotify)
        {
            _scheduleApiClient = scheduleApiClient;
            _doctorApiClient = doctorApiClient;
            _rosterNotify = rosterNotify;
        }

        private string? ActorName => User.FindFirstValue("DisplayName") ?? User.Identity?.Name;

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
            try
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
                    new() { Value = "0", Text = "Sunday" }
                };

                var model = new DoctorScheduleIndexViewModel
                {
                    DoctorId = doctorId,
                    DoctorName = doctor.FullName,
                    Schedules = schedules,
                    Exceptions = exceptions,
                    DayOfWeekOptions = new SelectList(days, "Value", "Text")
                };

                return View(model);
            }
            catch (HttpRequestException)
            {
                ViewData["PageName"] = "Doctor Schedule Configuration";
                return View("ApiDown");
            }
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
                var savedDays = new List<byte>();

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
                    else savedDays.Add(day);
                }

                // 2528: the roster changed - the doctor and the chosen users are told (when the daily roster is on)
                if (savedDays.Count > 0)
                {
                    var edited = daysToProcess.Count == 1 && request.ScheduleId > 0;
                    var times = $"{DateTime.Today.Add(request.StartTime):hh:mm tt} - {DateTime.Today.Add(request.EndTime):hh:mm tt}";
                    var change = (edited ? "Session changed: " : "New session: ")
                                 + string.Join(", ", savedDays.OrderBy(d => d == 0 ? 7 : d).Select(RosterItem.DayName)) + " " + times;
                    _rosterNotify.QueueRosterChange(request.DoctorId, request.BranchId, change, ActorName, request.RequestedByUserId);
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
            var item = await _rosterNotify.GetRosterItemAsync(id, null);   // 2528: what is removed, for the message
            var result = await _scheduleApiClient.DeleteAsync(id, deletedBy);

            if (result.Success)
            {
                if (item is not null)
                    _rosterNotify.QueueRosterChange(item.DoctorId, item.BranchId, "Session deactivated: " + item.Describe(), ActorName, deletedBy);
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
                bool anySaved = false;

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
                    else anySaved = true;
                }

                // 2528: leave added / changed - the doctor and the chosen users are told (when the daily roster is on)
                if (anySaved)
                {
                    var kind = string.IsNullOrWhiteSpace(request.ExceptionType) ? "Leave" : request.ExceptionType;
                    var change = $"{kind} {(request.ExceptionId > 0 && startDate == endDate ? "changed" : "added")}: {RosterItem.Dates(startDate, endDate)}"
                                 + (string.IsNullOrWhiteSpace(request.Reason) ? "" : $" ({request.Reason.Trim()})");
                    _rosterNotify.QueueRosterChange(request.DoctorId, request.BranchId, change, ActorName, request.RequestedByUserId);
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
            var item = await _rosterNotify.GetRosterItemAsync(null, id);   // 2528: what is removed, for the message
            var success = await _scheduleApiClient.DeleteExceptionAsync(id, deletedBy);

            if (success)
            {
                if (item is not null)
                    _rosterNotify.QueueRosterChange(item.DoctorId, item.BranchId, "Leave removed: " + item.Describe(), ActorName, deletedBy);
                return Json(new { success = true, message = "Exception deleted." });
            }
            
            return Json(new { success = false, message = "Failed to delete exception." });
        }
    }
}
