using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record NotifyTemplateSaveRequest(int? TemplateId, int? BranchId, string EventCode, string Channel, int LanguageId, string? Subject, string? Heading, string Body, bool IsActive);

/// <summary>Notification texts per language (SQLScripts/2543): resolve (used when sending), Settings > Notification Languages.
/// Company and user come from the caller's token.</summary>
[ApiController]
[Route("api/notify-templates")]
[Produces("application/json")]
public class NotifyTemplatesController(INotifyTemplateService service) : ControllerBase
{
    private int CompanyId => int.TryParse(User.FindFirstValue("CompanyId"), out var c) && c > 0 ? c : 1;
    private int UserId => int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var u) ? u : 0;

    [HttpGet("resolve")]
    public async Task<IActionResult> Resolve([FromQuery] int branchId, [FromQuery] string eventCode, [FromQuery] string channel, [FromQuery] int? languageId) =>
        Ok(ApiResponse<object?>.Ok(await service.ResolveAsync(CompanyId, branchId, eventCode, channel, languageId)));

    [HttpGet("lookups")]
    public async Task<IActionResult> Lookups() => Ok(ApiResponse<List<List<IDictionary<string, object?>>>>.Ok(await service.LookupsAsync(CompanyId)));

    [HttpGet]
    public async Task<IActionResult> List([FromQuery] string? eventCode) => Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(await service.ListAsync(CompanyId, eventCode)));

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] NotifyTemplateSaveRequest r) =>
        Ok(ApiResponse<IDictionary<string, object?>?>.Ok(await service.SaveAsync(new
        {
            CompanyId, UserId, r.TemplateId, r.BranchId, r.EventCode, r.Channel, r.LanguageId, r.Subject, r.Heading, r.Body, r.IsActive
        })));
}
