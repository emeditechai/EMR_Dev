using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// Utility > Campaigns (SQLScripts/2299): campaigns, their audiences and templates for EMR.Web, and the calls of its
/// background sender (sender/*, made with the service token). The emails themselves are sent by EMR.Web with the
/// mail settings of each campaign's "send from" branch.
/// </summary>
[ApiController]
[Route("api/campaigns")]
public class CampaignsController(ICampaignService service) : ControllerBase
{
    [HttpGet("list")]
    public async Task<IActionResult> List([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] bool allBranches = false) =>
        companyId <= 0 ? BadRequest(new { message = "CompanyId is required." }) : Ok(await service.ListAsync(companyId, branchId, allBranches));

    [HttpGet("{campaignId:int}")]
    public async Task<IActionResult> Get(int campaignId, [FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] bool allBranches = false) =>
        await service.GetAsync(campaignId, companyId, branchId, allBranches) is { } c ? Ok(c) : NotFound(new { message = "Campaign not found." });

    [HttpGet("options")]
    public async Task<IActionResult> Options([FromQuery] int companyId) => Ok(await service.OptionsAsync(companyId));

    [HttpPost("audience")]
    public async Task<IActionResult> Audience([FromBody] CampaignAudienceRequest request) =>
        request is null || request.CompanyId <= 0 ? BadRequest(new { message = "CompanyId is required." }) : Ok(await service.AudienceAsync(request));

    [HttpGet("audience/search")]
    public async Task<IActionResult> AudienceSearch([FromQuery] int companyId, [FromQuery] string audienceType, [FromQuery] string? term) =>
        Ok(await service.SearchAsync(companyId, audienceType, term));

    [HttpPost("save")]
    public async Task<IActionResult> Save([FromBody] CampaignSaveRequest request)
    {
        if (request is null || request.CompanyId <= 0 || request.UserId <= 0) return BadRequest(new { message = "CompanyId and UserId are required." });
        try { return Ok(await service.SaveAsync(request)); }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpGet("{campaignId:int}/recipients")]
    public async Task<IActionResult> Recipients(int campaignId, [FromQuery] int companyId, [FromQuery] string? status, [FromQuery] string? search) =>
        Ok(await service.RecipientsAsync(campaignId, companyId, status, search));

    [HttpPost("action")]
    public async Task<IActionResult> Action([FromBody] CampaignActionRequest request)
    {
        if (request is null || request.Action.ToUpperInvariant() is not ("CANCEL" or "RETRY" or "DELETE")) return BadRequest(new { message = "Unknown action." });
        return Ok(new { affected = await service.ActionAsync(request) });
    }

    [HttpGet("templates/{templateId:int}")]
    public async Task<IActionResult> TemplateGet(int templateId, [FromQuery] int companyId) =>
        await service.TemplateGetAsync(templateId, companyId) is { } t ? Ok(t) : NotFound(new { message = "Template not found." });

    [HttpGet("templates")]
    public async Task<IActionResult> TemplateList([FromQuery] int companyId, [FromQuery] string audienceType) =>
        Ok(await service.TemplateListAsync(companyId, audienceType));

    [HttpPost("templates")]
    public async Task<IActionResult> TemplateSave([FromBody] CampaignTemplateDto template)
    {
        if (template is null || template.CompanyId <= 0) return BadRequest(new { message = "CompanyId is required." });
        try { return Ok(new { templateId = await service.TemplateSaveAsync(template) }); }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPost("templates/{templateId:int}/delete")]
    public async Task<IActionResult> TemplateDelete(int templateId, [FromQuery] int companyId) =>
        Ok(new { affected = await service.TemplateDeleteAsync(templateId, companyId) });

    // ── the sender (EMR.Web background service) ──
    [HttpGet("sender/running")]
    public async Task<IActionResult> SenderRunning() => Ok(await service.SenderRunningAsync());

    [HttpGet("sender/{campaignId:int}/next")]
    public async Task<IActionResult> SenderNext(int campaignId, [FromQuery] int batch = 25) => Ok(await service.SenderNextAsync(campaignId, batch));

    [HttpPost("sender/mark")]
    public async Task<IActionResult> SenderMark([FromBody] CampaignMarkRequest request) =>
        Ok(new { stillSending = await service.SenderMarkAsync(request) });

    [HttpPost("sender/{campaignId:int}/finish")]
    public async Task<IActionResult> SenderFinish(int campaignId)
    {
        await service.SenderFinishAsync(campaignId);
        return Ok(new { done = true });
    }

    [HttpPost("opt-out")]
    public async Task<IActionResult> OptOut([FromBody] CampaignOptOutRequest request)
    {
        if (request is null || request.CompanyId <= 0 || string.IsNullOrWhiteSpace(request.Email)) return BadRequest(new { message = "CompanyId and Email are required." });
        await service.OptOutAsync(request);
        return Ok(new { done = true });
    }
}
