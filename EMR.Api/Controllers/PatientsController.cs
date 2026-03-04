using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Patient Master API</summary>
[ApiController]
[Route("api/[controller]")]
[Produces("application/json")]
public class PatientsController(IPatientService patientService) : ControllerBase
{
    // ── GET /api/patients?branchId=1&page=1&pageSize=20&search=john ──────────

    /// <summary>Get patients by branch with optional search and paging.</summary>
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<PagedResult<PatientListItem>>), 200)]
    public async Task<IActionResult> GetByBranch(
        [FromQuery] int?   branchId,
        [FromQuery] int    page     = 1,
        [FromQuery] int    pageSize = 20,
        [FromQuery] string? search  = null)
    {
        var data = await patientService.GetByBranchAsync(branchId, page, pageSize, search);
        return Ok(ApiResponse<PagedResult<PatientListItem>>.Ok(data));
    }

    // ── GET /api/patients/13 ─────────────────────────────────────────────────

    /// <summary>Get a single patient by ID with full detail.</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<PatientDetail>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById(int id)
    {
        var data = await patientService.GetByIdAsync(id);
        if (data is null)
            return NotFound(ApiResponse<object>.Fail($"Patient {id} not found."));
        return Ok(ApiResponse<PatientDetail>.Ok(data));
    }

    // ── POST /api/patients ───────────────────────────────────────────────────

    /// <summary>Register a new patient.</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<object>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] PatientCreateRequest request)
    {
        if (!ModelState.IsValid)
            return BadRequest(ApiResponse<object>.Fail("Invalid request data."));

        var newId = await patientService.CreateAsync(request);
        return CreatedAtAction(nameof(GetById), new { id = newId },
            ApiResponse<object>.Ok(new { PatientId = newId }, "Patient registered successfully."));
    }

    // ── PUT /api/patients/13 ─────────────────────────────────────────────────

    /// <summary>Update an existing patient.</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<object>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> Update(int id, [FromBody] PatientUpdateRequest request)
    {
        if (id != request.PatientId)
            return BadRequest(ApiResponse<object>.Fail("Route id and body PatientId must match."));

        var updated = await patientService.UpdateAsync(request);
        if (!updated)
            return NotFound(ApiResponse<object>.Fail($"Patient {id} not found."));

        return Ok(ApiResponse<object>.Ok(new { PatientId = id }, "Patient updated successfully."));
    }
}
