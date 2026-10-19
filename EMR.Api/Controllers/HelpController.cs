using EMR.Api.Models;
using EMR.Api.Services;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// Utility > Help Center (SQLScripts/2300): the user guide for every signed-in user - home, modules, articles, help for
/// a page, the Help Assistant and feedback. Open to every caller with a token (no page permission needed).
/// </summary>
[ApiController]
[Route("api/help")]
[PublicEndpoint]
public class HelpController(IHelpService service) : ControllerBase
{
    [HttpGet("home")]
    public async Task<IActionResult> Home([FromQuery] int companyId) => Ok(await service.HomeAsync(companyId));

    [HttpGet("module/{module}")]
    public async Task<IActionResult> Module(string module, [FromQuery] int companyId) =>
        await service.ModuleAsync(companyId, module.ToUpperInvariant()) is { } m ? Ok(m) : NotFound(new { message = "Module not found." });

    [HttpGet("article/{code}")]
    public async Task<IActionResult> Article(string code, [FromQuery] int companyId) =>
        await service.ArticleAsync(companyId, code) is { } a ? Ok(a) : NotFound(new { message = "Help topic not found." });

    [HttpGet("page")]
    public async Task<IActionResult> Page([FromQuery] int companyId, [FromQuery] string? pageCode, [FromQuery] string? controller, [FromQuery] string? action) =>
        await service.PageAsync(companyId, pageCode, controller, action) is { } p ? Ok(p) : NotFound(new { message = "No help for this page yet." });

    [HttpPost("ask")]
    public async Task<IActionResult> Ask([FromBody] HelpAskRequest request) =>
        request is null || string.IsNullOrWhiteSpace(request.Question) ? BadRequest(new { message = "Type a question." }) : Ok(await service.AskAsync(request));

    [HttpPost("feedback")]
    public async Task<IActionResult> Feedback([FromBody] HelpFeedbackRequest request)
    {
        if (request is null || request.CompanyId <= 0) return BadRequest(new { message = "CompanyId is required." });
        await service.FeedbackAsync(request);
        return Ok(new { saved = true });
    }

    [HttpGet("feedback")]
    public async Task<IActionResult> FeedbackList([FromQuery] int companyId) => Ok(await service.FeedbackListAsync(companyId));
}
