using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>LAB > Work Sheet (SQLScripts/2477): the numeric tests of one day's bills for the bench hard copy. Company from the token.</summary>
[ApiController]
[Route("api/lab-worksheet")]
[Produces("application/json")]
public class LabWorksheetController(IIpdProcService procs) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> List([FromQuery] int branchId, [FromQuery] string? dateType, [FromQuery] DateTime? date, [FromQuery] string? channel, [FromQuery] string? values)
    {
        if (!int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var userId) || userId <= 0) return BadRequest(ApiResponse.Fail("A signed-in user is needed."));
        if (branchId <= 0) return BadRequest(ApiResponse.Fail("Choose the branch."));
        var companyId = int.TryParse(User.FindFirstValue("CompanyId"), out var c) && c > 0 ? c : 1;
        var rows = await procs.RowsAsync("dbo.usp_Api_LabWorksheet_List",
            new { CompanyId = companyId, BranchId = branchId, DateType = dateType, Date = (date ?? DateTime.Today).Date, Channel = channel, Values = values });
        return Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(rows));
    }
}
