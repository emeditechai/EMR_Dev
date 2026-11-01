using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/patientportal")]
[EMR.Api.Security.PatientOwnData]
[Produces("application/json")]
public class PatientPortalApiController(IPatientPortalService portalService, IPharmacyProcService pharmacy) : ControllerBase
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

    /// <summary>The patient's pharmacy bills, each with what was bought (SQLScripts/2368).</summary>
    [HttpGet("{patientId:int}/pharmacy")]
    public async Task<IActionResult> GetPharmacy(int patientId)
    {
        var sets = await pharmacy.SetsAsync("dbo.usp_Api_Portal_PharmacyBills", new { PatientId = patientId }, 2);
        var lines = sets[1].GroupBy(l => Convert.ToInt32(l["SaleId"])).ToDictionary(g => g.Key, g => g.ToList());
        foreach (var b in sets[0]) b["Lines"] = lines.TryGetValue(Convert.ToInt32(b["SaleId"]), out var ls) ? ls : [];
        return Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(sets[0]));
    }
}
