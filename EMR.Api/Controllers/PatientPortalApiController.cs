using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/patientportal")]
[Produces("application/json")]
public class PatientPortalApiController(IPatientPortalService portalService) : ControllerBase
{
    [HttpGet("{patientId:int}/dashboard")]
    public async Task<IActionResult> GetDashboardSummary(int patientId)
    {
        var result = await portalService.GetDashboardSummaryAsync(patientId);
        return Ok(ApiResponse<PortalDashboardSummary>.Ok(result));
    }

    [HttpGet("{patientId:int}/fullprofile")]
    public async Task<IActionResult> GetFullProfile(int patientId)
    {
        var result = await portalService.GetFullProfileAsync(patientId);
        return Ok(ApiResponse<PortalFullProfile>.Ok(result));
    }

    [HttpGet("{patientId:int}/dependents")]
    public async Task<IActionResult> GetDependents(int patientId)
    {
        var result = await portalService.GetDependentsAsync(patientId);
        return Ok(ApiResponse<IEnumerable<PortalDependent>>.Ok(result));
    }

    [HttpGet("{patientId:int}/vitals")]
    public async Task<IActionResult> GetVitals(int patientId)
    {
        var result = await portalService.GetVitalsAsync(patientId);
        return Ok(ApiResponse<IEnumerable<PortalVital>>.Ok(result));
    }

    [HttpGet("{patientId:int}/bookings")]
    public async Task<IActionResult> GetBookings(int patientId)
    {
        var result = await portalService.GetBookingsAsync(patientId);
        return Ok(ApiResponse<IEnumerable<PortalBooking>>.Ok(result));
    }

    [HttpGet("{patientId:int}/prescriptions")]
    public async Task<IActionResult> GetPrescriptions(int patientId)
    {
        var result = await portalService.GetPrescriptionsAsync(patientId);
        return Ok(ApiResponse<IEnumerable<PortalPrescription>>.Ok(result));
    }
}
