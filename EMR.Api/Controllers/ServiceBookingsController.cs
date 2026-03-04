using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/servicebookings")]
public class ServiceBookingsController(IServiceBookingService svc) : ControllerBase
{
    // GET /api/servicebookings?branchId=1&fromDate=2026-03-04&toDate=2026-03-04&page=1&pageSize=10&search=
    [HttpGet]
    public async Task<IActionResult> GetPaged(
        [FromQuery] int?    branchId   = null,
        [FromQuery] string? fromDate   = null,
        [FromQuery] string? toDate     = null,
        [FromQuery] int     page       = 1,
        [FromQuery] int     pageSize   = 10,
        [FromQuery] string? search     = null)
    {
        if (page < 1) page = 1;
        if (pageSize is < 1 or > 200) pageSize = 10;

        DateTime? from = DateTime.TryParse(fromDate, out var fd) ? fd : null;
        DateTime? to   = DateTime.TryParse(toDate,   out var td) ? td : null;

        var result = await svc.GetPagedAsync(branchId, from, to, page, pageSize, search?.Trim());
        return Ok(ApiResponse<ServiceBookingPagedResult>.Ok(result));
    }

    // GET /api/servicebookings/{id}
    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        var detail = await svc.GetByIdAsync(id);
        if (detail is null)
            return NotFound(ApiResponse<ServiceBookingDetail>.Fail($"Service booking {id} not found."));

        return Ok(ApiResponse<ServiceBookingDetail>.Ok(detail));
    }
}
