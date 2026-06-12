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
        IPatientService patientService) : Controller
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

            // Get all specialties
            var specialties = await patientService.GetOpdDepartmentsAsync();
            ViewBag.Specialties = specialties;
            
            return View();
        }

        [HttpGet("DoctorRoster/GetDoctorSchedulesTest")]
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

        [HttpGet]
        public async Task<IActionResult> GetDoctorsBySpecialty(int? departmentId)
        {
            var branchId = User.GetCurrentBranchId() ?? 1; // Fallback to 1 (HO)
            var doctors = await patientService.GetOpdDoctorsAsync(branchId, departmentId);
            return Json(doctors.Select(d => new { id = d.DoctorId, name = d.FullName }));
        }

        [HttpGet]
        public async Task<IActionResult> GetDoctorSchedules(int? doctorId, int? departmentId)
        {
            var branchId = User.GetCurrentBranchId() ?? 1; // Fallback to 1 (HO) if claim is missing from old cookie
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

        [HttpGet]
        public async Task<IActionResult> GetDateBookings(int doctorId, string date)
        {
            var branchId = User.GetCurrentBranchId() ?? 1; // Fallback to 1 (HO)
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
