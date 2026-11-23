using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record LabRxLearnRequest(string Items);

/// <summary>
/// LAB > AI Prescription Assist learning (SQLScripts/2439): what users confirm / reject / link is recorded per company and
/// read back by the matcher. Company and user come from the token. Procedures run through the generic procedure runner.
/// </summary>
[ApiController]
[Route("api/lab/rx-learning")]
[Produces("application/json")]
public class LabRxLearningController(IIpdProcService procs) : ControllerBase
{
    private (int CompanyId, int UserId)? Caller()
    {
        if (!int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var userId) || userId <= 0) return null;
        var companyId = int.TryParse(User.FindFirstValue("CompanyId"), out var c) && c > 0 ? c : 1;
        return (companyId, userId);
    }

    [HttpGet]
    public async Task<IActionResult> Learned()
    {
        if (Caller() is not { } c) return BadRequest(ApiResponse.Fail("A signed-in user is needed."));
        return Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(await procs.RowsAsync("dbo.usp_Api_LabRx_Learned", new { c.CompanyId })));
    }

    [HttpPost]
    public async Task<IActionResult> Learn([FromBody] LabRxLearnRequest r)
    {
        if (Caller() is not { } c) return BadRequest(ApiResponse.Fail("A signed-in user is needed."));
        return Ok(ApiResponse<IDictionary<string, object?>?>.Ok(await procs.RowAsync("dbo.usp_Api_LabRx_Learn", new { c.CompanyId, c.UserId, r.Items })));
    }
}
