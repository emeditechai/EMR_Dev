using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Doctor Master API</summary>
[ApiController]
[Route("api/[controller]")]
[Produces("application/json")]
public class DoctorsController(IDoctorService doctorService) : ControllerBase
{
    // ── GET /api/doctors?branchId=1 ──────────────────────────────────────────

    /// <summary>Get all doctors, optionally filtered by branch.</summary>
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<DoctorListItem>>), 200)]
    public async Task<IActionResult> GetList([FromQuery] int? branchId)
    {
        var data = await doctorService.GetListAsync(branchId);
        return Ok(ApiResponse<IEnumerable<DoctorListItem>>.Ok(data));
    }

    // ── GET /api/doctors/5 ───────────────────────────────────────────────────

    /// <summary>Get a single doctor by ID.</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<DoctorDetail>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById(int id, [FromQuery] int? branchId)
    {
        var data = await doctorService.GetByIdAsync(id, branchId);
        if (data is null)
            return NotFound(ApiResponse<object>.Fail($"Doctor {id} not found."));
        return Ok(ApiResponse<DoctorDetail>.Ok(data));
    }

    // ── POST /api/doctors ────────────────────────────────────────────────────

    /// <summary>Create a new doctor.</summary>
    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<object>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] DoctorCreateRequest request)
    {
        if (!ModelState.IsValid)
            return BadRequest(ApiResponse<object>.Fail("Invalid request data."));

        var newId = await doctorService.CreateAsync(request);
        return CreatedAtAction(nameof(GetById), new { id = newId },
            ApiResponse<object>.Ok(new { DoctorId = newId }, "Doctor created successfully."));
    }

    // ── PUT /api/doctors/5 ───────────────────────────────────────────────────

    /// <summary>Update an existing doctor.</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<object>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> Update(int id, [FromBody] DoctorUpdateRequest request)
    {
        if (id != request.DoctorId)
            return BadRequest(ApiResponse<object>.Fail("Route id and body DoctorId must match."));

        var updated = await doctorService.UpdateAsync(request);
        if (!updated)
            return NotFound(ApiResponse<object>.Fail($"Doctor {id} not found."));

        return Ok(ApiResponse<object>.Ok(new { DoctorId = id }, "Doctor updated successfully."));
    }
}
