using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// Settings > Company Master > New Company wizard (SQLScripts/2306): templates to copy from, availability checks and
/// the one-step onboarding. Mapped to the Company Master page; EMR.Web lets only Super Admin use the wizard.
/// </summary>
[ApiController]
[Route("api/company-onboarding")]
public class CompanyOnboardingController(ICompanyOnboardingService service) : ControllerBase
{
    [HttpGet("templates")]
    public async Task<IActionResult> Templates() => Ok(await service.TemplatesAsync());

    [HttpGet("check")]
    public async Task<IActionResult> Check([FromQuery] string? companyCode, [FromQuery] string? branchCode, [FromQuery] string? username) =>
        Ok(await service.CheckAsync(companyCode, branchCode, username));

    [HttpPost]
    public async Task<IActionResult> Onboard([FromBody] CompanyOnboardRequest request)
    {
        if (request is null || request.TemplateCompanyId <= 0) return BadRequest(new { message = "Choose the company to copy the menus from." });
        var (result, error) = await service.OnboardAsync(request);
        return error is null ? Ok(result) : BadRequest(new { message = error });
    }
}
