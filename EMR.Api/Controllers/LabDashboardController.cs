using System;
using System.Threading.Tasks;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
public class LabDashboardController(ILabDashboardService labDashboardService) : ControllerBase
{
    [HttpGet("stats")]
    public async Task<ActionResult<LabDashboardData>> GetStats([FromQuery] int branchId, [FromQuery] string? date)
    {
        if (branchId <= 0)
        {
            return BadRequest("Valid BranchId is required.");
        }

        var filterDate = DateTime.TryParse(date, out var d) ? d : DateTime.Today;
        var data = await labDashboardService.GetDashboardStatsAsync(branchId, filterDate);
        return Ok(data);
    }
}
