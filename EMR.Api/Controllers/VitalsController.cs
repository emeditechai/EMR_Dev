using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Patient Vitals API</summary>
[ApiController]
[Route("api/vitals")]
[Produces("application/json")]
public class VitalsController(IVitalService vitalService) : ControllerBase
{
    // ── GET /api/vitals?patientId=X&page=1&pageSize=10 ────────────────────────
    /// <summary>Get paged vital history for a patient.</summary>
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<VitalHistoryResult>), 200)]
    public async Task<IActionResult> GetHistory(
        [FromQuery] int patientId,
        [FromQuery] int page     = 1,
        [FromQuery] int pageSize = 10)
    {
        if (patientId <= 0)
            return BadRequest(ApiResponse<object>.Fail("patientId is required."));

        if (page < 1)      page     = 1;
        if (pageSize is < 1 or > 100) pageSize = 10;

        var result = await vitalService.GetHistoryAsync(patientId, page, pageSize);
        return Ok(ApiResponse<VitalHistoryResult>.Ok(result));
    }

    // ── GET /api/vitals/{id} ──────────────────────────────────────────────────
    /// <summary>Get a single vital record by ID.</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<VitalRow>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById(int id)
    {
        var row = await vitalService.GetByIdAsync(id);
        if (row is null)
            return NotFound(ApiResponse<object>.Fail($"Vital record {id} not found."));
        return Ok(ApiResponse<VitalRow>.Ok(row));
    }

    // ── GET /api/vitals/latest/{patientId} ────────────────────────────────────
    /// <summary>Get the latest vital record for a patient.</summary>
    [HttpGet("latest/{patientId:int}")]
    [ProducesResponseType(typeof(ApiResponse<VitalRow>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetLatest(int patientId)
    {
        var row = await vitalService.GetLatestAsync(patientId);
        if (row is null)
            return NotFound(ApiResponse<object>.Fail("No vital records found."));
        return Ok(ApiResponse<VitalRow>.Ok(row));
    }

    // ── GET /api/vitals/print/{patientId}?branchId=X ─────────────────────────
    /// <summary>Get all data needed to render the vital print page.</summary>
    [HttpGet("print/{patientId:int}")]
    [ProducesResponseType(typeof(ApiResponse<VitalPrintData>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetPrintData(int patientId, [FromQuery] int? branchId = null)
    {
        var data = await vitalService.GetPrintDataAsync(patientId, branchId);
        if (data is null)
            return NotFound(ApiResponse<object>.Fail($"Patient {patientId} not found."));
        return Ok(ApiResponse<VitalPrintData>.Ok(data));
    }

    // ── POST /api/vitals ──────────────────────────────────────────────────────
    /// <summary>Create a new vital record. BMI is auto-calculated server-side.</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<object>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] VitalCreateRequest request)
    {
        if (request.PatientId <= 0)
            return BadRequest(ApiResponse<object>.Fail("PatientId is required."));

        var newId = await vitalService.CreateAsync(request);
        return CreatedAtAction(nameof(GetById), new { id = newId },
            ApiResponse<object>.Ok(new { PatientVitalId = newId }, "Vital recorded successfully."));
    }

    // ── PUT /api/vitals/{id} ──────────────────────────────────────────────────
    /// <summary>Update an existing vital record. BMI is re-calculated server-side.</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<object>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update(int id, [FromBody] VitalUpdateRequest request)
    {
        if (id != request.PatientVitalId)
            return BadRequest(ApiResponse<object>.Fail("Route id and body PatientVitalId must match."));

        await vitalService.UpdateAsync(request);
        return Ok(ApiResponse<object>.Ok(new { PatientVitalId = id }, "Vital updated successfully."));
    }

    // ── DELETE /api/vitals/{id}?deletedByUserId=X ─────────────────────────────
    /// <summary>Soft-delete a vital record.</summary>
    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<object>), 200)]
    public async Task<IActionResult> Delete(int id, [FromQuery] int deletedByUserId = 0)
    {
        await vitalService.DeleteAsync(id, deletedByUserId);
        return Ok(ApiResponse<object>.Ok(new { PatientVitalId = id }, "Vital record deleted."));
    }
}
