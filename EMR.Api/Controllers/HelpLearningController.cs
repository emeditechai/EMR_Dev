using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// Utility > Help Center > Help insights (SQLScripts/2301): how the Help Assistant is doing day by day and what it has
/// learned; administrators teach it the right topic for a question or make it forget a learned one. Mapped to the Help
/// Center page (EMR.Web lets only administrators use it).
/// </summary>
[ApiController]
[Route("api/help/learning")]
public class HelpLearningController(IHelpService service) : ControllerBase
{
    [HttpGet("stats")]
    public async Task<IActionResult> Stats([FromQuery] int companyId) => Ok(await service.LearningStatsAsync(companyId));

    [HttpPost("teach")]
    public async Task<IActionResult> Teach([FromBody] HelpTeachRequest request)
    {
        if (request is null || request.CompanyId <= 0 || string.IsNullOrWhiteSpace(request.Question) || string.IsNullOrWhiteSpace(request.TargetCode))
            return BadRequest(new { message = "The question and the right topic are required." });
        await service.TeachAsync(request);
        return Ok(new { saved = true });
    }

    [HttpPost("forget/{learnedId:int}")]
    public async Task<IActionResult> Forget(int learnedId, [FromQuery] int companyId, [FromQuery] int? userId) =>
        await service.ForgetAsync(companyId, learnedId, userId) ? Ok(new { saved = true }) : NotFound(new { message = "Not found." });
}
