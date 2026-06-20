using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class RoomDoctorAssignmentController(
    IRoomDoctorAssignmentService assignmentService,
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId == null) return RedirectToAction("SelectBranch", "Account");

        var rooms = await assignmentService.GetRoomAssignmentsAsync(branchId.Value);
        var opdDoctors = await assignmentService.GetOPDDoctorsAsync(branchId.Value);

        ViewBag.OpdDoctors = opdDoctors;
        return View(rooms);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AssignDoctor([FromBody] RoomDoctorAssignmentPostDto dto)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId == null) return Unauthorized();

        if (dto.DoctorId <= 0 || dto.RoomId <= 0)
        {
            return BadRequest("Invalid Doctor or Room ID.");
        }

        try
        {
            await assignmentService.AssignDoctorAsync(dto.RoomId, dto.DoctorId, User.GetUserId());
            
            await auditLogService.LogAsync(
                "Assign", 
                "RoomDoctorAssignment", 
                $"Assigned Doctor {dto.DoctorId} to Room {dto.RoomId}", 
                User.GetUserId(), 
                branchId.Value);

            return Ok(new { success = true, message = "Doctor assigned successfully to the room." });
        }
        catch (Exception)
        {
            return StatusCode(500, new { success = false, message = "An error occurred while assigning the doctor." });
        }
    }
}
