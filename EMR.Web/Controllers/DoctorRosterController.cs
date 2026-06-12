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
            
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> GetDoctorSchedules(int doctorId)
        {
            var branchId = User.GetCurrentBranchId() ?? 0;
            try
            {
                var schedules = await scheduleApiClient.GetByDoctorAsync(doctorId, branchId);
                var exceptions = await scheduleApiClient.GetExceptionsAsync(doctorId, branchId);
                
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
            var branchId = User.GetCurrentBranchId() ?? 0;
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
