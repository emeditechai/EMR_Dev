using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>EMR Consultations API</summary>
[ApiController]
[Route("api/[controller]")]
[Produces("application/json")]
public class EmrConsultationsController(IEmrConsultationService emrService) : ControllerBase
{
    // ── GET /api/emrconsultations/{opdServiceId}/doctor/{doctorId} ────────

    /// <summary>Get full EMR Consultation context (Booking, Template, Saved data).</summary>
    [HttpGet("{opdServiceId:int}/doctor/{doctorId:int}")]
    [ProducesResponseType(typeof(ApiResponse<EmrConsultationResponse>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetConsultationData(int opdServiceId, int doctorId)
    {
        var data = await emrService.GetConsultationDataAsync(opdServiceId, doctorId);
        if (data is null)
            return NotFound(ApiResponse<object>.Fail("Consultation setup data not found. Ensure doctor has a template mapped to their primary speciality."));
        return Ok(ApiResponse<EmrConsultationResponse>.Ok(data));
    }

    // ── POST /api/emrconsultations ──────────────────────────────────────────

    /// <summary>Save or update EMR Patient Consultation data.</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<object>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> SaveConsultation([FromBody] SaveConsultationRequest request)
    {
        if (request.OPDServiceId <= 0)
            return BadRequest(ApiResponse<object>.Fail("Invalid OPDServiceId."));

        var success = await emrService.SaveConsultationAsync(request);
        return Ok(ApiResponse<object>.Ok(null, "Consultation saved successfully."));
    }
}
