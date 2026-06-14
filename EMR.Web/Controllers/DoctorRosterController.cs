using System;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;

namespace EMR.Web.Controllers
{
    [Authorize]
    public class DoctorRosterController(
        IDoctorScheduleApiClient scheduleApiClient,
        IPatientService patientService,
        IDoctorSpecialityService specialityService) : Controller
    {
        public async Task<IActionResult> Index()
        {
            var branchId = User.GetCurrentBranchId();
            if (branchId == null)
            {
                return RedirectToAction("SelectBranch", "Account");
            }
            
            // Get all active OPD doctors for the branch
            var doctors = await patientService.GetOpdDoctorsAsync(branchId.Value);
            ViewBag.Doctors = doctors;

            // Get all active specialities from DoctorSpecialityMaster
            var specialities = await specialityService.GetActiveAsync();
            ViewBag.Specialities = specialities;
            
            return View();
        }

        [HttpGet(("DoctorRoster/GetDoctorSchedulesTest"))]
        [AllowAnonymous]
        public async Task<IActionResult> GetDoctorSchedulesTest(int? doctorId, int? departmentId)
        {
            var branchId = 1; // force branch 1
            try
            {
                var schedules = await scheduleApiClient.GetByDoctorAsync(doctorId, branchId, departmentId);
                var exceptions = await scheduleApiClient.GetExceptionsAsync(doctorId, branchId, null, null, departmentId);
                
                return Json(new { schedules, exceptions });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { error = ex.Message });
            }
        }

        /// <summary>
        /// Returns doctors filtered by DoctorSpecialityMaster (PrimarySpecialityId).
        /// Used by the Speciality dropdown AJAX call on the Roster page.
        /// </summary>
        [HttpGet]
        public async Task<IActionResult> GetDoctorsBySpecialty(int? specialityId)
        {
            var branchId = User.GetCurrentBranchId() ?? 1;
            var doctors = await patientService.GetOpdDoctorsAsync(branchId, specialityId: specialityId);
            return Json(doctors.Select(d => new { id = d.DoctorId, name = d.FullName }));
        }

        [HttpGet]
        public async Task<IActionResult> GetDoctorSchedules(int? doctorId, int? departmentId, int? specialityId)
        {
            var branchId = User.GetCurrentBranchId() ?? 1;
            try
            {
                // If filtering by speciality (no specific doctor), load all doctors for that
                // speciality and merge their schedules + exceptions in parallel.
                if (specialityId.HasValue && !doctorId.HasValue)
                {
                    var doctors = await patientService.GetOpdDoctorsAsync(branchId, specialityId: specialityId);
                    var doctorIds = doctors.Select(d => d.DoctorId).ToList();

                    if (!doctorIds.Any())
                        return Json(new { schedules = new List<object>(), exceptions = new List<object>() });

                    var tasks = doctorIds.Select(async dId =>
                    {
                        var s = await scheduleApiClient.GetByDoctorAsync(dId, branchId);
                        var e = await scheduleApiClient.GetExceptionsAsync(dId, branchId);
                        return (schedules: s, exceptions: e);
                    });

                    var results = await Task.WhenAll(tasks);
                    var allSchedules  = results.SelectMany(r => r.schedules).ToList();
                    var allExceptions = results.SelectMany(r => r.exceptions).ToList();
                    return Json(new { schedules = allSchedules, exceptions = allExceptions });
                }

                // Default: single doctor (or all doctors with no filter)
                var schedules  = await scheduleApiClient.GetByDoctorAsync(doctorId, branchId, departmentId);
                var exceptions = await scheduleApiClient.GetExceptionsAsync(doctorId, branchId, null, null, departmentId);
                return Json(new { schedules, exceptions });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { error = ex.Message });
            }
        }

        [HttpGet]
        public async Task<IActionResult> GetDateBookings(int doctorId, string date)
        {
            var branchId = User.GetCurrentBranchId() ?? 1;
            try
            {
                if (!DateOnly.TryParse(date, out var dateOnly))
                    return BadRequest(new { error = "Invalid date" });

                var bookings = await patientService.GetBookingsByDoctorDateAsync(doctorId, dateOnly, branchId);
                return Json(new { bookings });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { error = ex.Message });
            }
        }
    }
}
