using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/opd-masters")]
[Produces("application/json")]
public class OpdMastersController(IOpdMasterService opdService) : ControllerBase
{
    [HttpGet("services")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<ServiceListItem>>), 200)]
    public async Task<IActionResult> GetServices([FromQuery] int branchId)
    {
        var result = await opdService.GetServicesAsync(branchId);
        return Ok(ApiResponse<IEnumerable<ServiceListItem>>.Ok(result));
    }

    [HttpGet("doctor-rooms")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<DoctorRoomListItem>>), 200)]
    public async Task<IActionResult> GetDoctorRooms([FromQuery] int branchId)
    {
        var result = await opdService.GetDoctorRoomsAsync(branchId);
        return Ok(ApiResponse<IEnumerable<DoctorRoomListItem>>.Ok(result));
    }

    [HttpGet("room-doctor-assignments")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<RoomDoctorAssignmentListItem>>), 200)]
    public async Task<IActionResult> GetRoomDoctorAssignments([FromQuery] int branchId)
    {
        var result = await opdService.GetRoomDoctorAssignmentsAsync(branchId);
        return Ok(ApiResponse<IEnumerable<RoomDoctorAssignmentListItem>>.Ok(result));
    }

    [HttpGet("opd-doctors")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<OPDDoctorOptionDto>>), 200)]
    public async Task<IActionResult> GetOPDDoctors([FromQuery] int branchId)
    {
        var result = await opdService.GetOPDDoctorsAsync(branchId);
        return Ok(ApiResponse<IEnumerable<OPDDoctorOptionDto>>.Ok(result));
    }

    [HttpGet("emr-investigations")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<EmrInvestigationListItem>>), 200)]
    public async Task<IActionResult> GetEmrInvestigations([FromQuery] string? search)
    {
        var result = await opdService.GetEmrInvestigationsAsync(search);
        return Ok(ApiResponse<IEnumerable<EmrInvestigationListItem>>.Ok(result));
    }

    [HttpGet("emr-medications")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<EmrMedicationListItem>>), 200)]
    public async Task<IActionResult> GetEmrMedications([FromQuery] string? search)
    {
        var result = await opdService.GetEmrMedicationsAsync(search);
        return Ok(ApiResponse<IEnumerable<EmrMedicationListItem>>.Ok(result));
    }
}
