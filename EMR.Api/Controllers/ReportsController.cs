using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[Route("api/[controller]")]
[ApiController]
public class ReportsController : ControllerBase
{
    private readonly IReportService _reportService;

    public ReportsController(IReportService reportService)
    {
        _reportService = reportService;
    }

    [HttpGet("daily-collection")]
    public async Task<IActionResult> GetDailyCollectionRegister(
        [FromQuery] int branchId,
        [FromQuery] DateTime fromDate,
        [FromQuery] DateTime toDate,
        [FromQuery] bool isDetailed = false)
    {
        var result = await _reportService.GetDailyCollectionRegisterAsync(branchId, fromDate, toDate, isDetailed);
        return Ok(result);
    }

    [HttpGet("patient-register")]
    public async Task<IActionResult> GetPatientRegister(
        [FromQuery] int branchId,
        [FromQuery] DateTime fromDate,
        [FromQuery] DateTime toDate,
        [FromQuery] bool dependentOnly = false)
    {
        var result = await _reportService.GetPatientRegisterAsync(branchId, fromDate, toDate, dependentOnly);
        return Ok(result);
    }
}
