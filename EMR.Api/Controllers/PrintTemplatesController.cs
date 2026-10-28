using EMR.Api.Models;
using EMR.Api.Services;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Controllers;

/// <summary>
/// Utility > Print Templates (SQLScripts/2324), page UTILITY.PRINTTEMPLATES. Resolve is used by every bill and lab report
/// print (any signed-in user may print), so it is open to all; the rest follows the page's permissions.
/// A rule broken in a procedure (THROW 54000+) comes back as 400 with its message.
/// </summary>
[ApiController]
[Route("api/print-templates")]
public class PrintTemplatesController(IPrintTemplateService service) : ControllerBase
{
    private static string? Rule(Exception ex) => ex is SqlException { Number: >= 50000 } s ? s.Message : null;

    private async Task<IActionResult> Run(Func<Task<object?>> action)
    {
        try { return Ok(await action() ?? new { saved = true }); }
        catch (Exception ex) when (Rule(ex) is { } msg) { return BadRequest(new { message = msg }); }
    }

    [HttpGet]
    public async Task<IActionResult> List([FromQuery] int companyId) => Ok(await service.ListAsync(companyId));

    [HttpGet("{id:int}")]
    public async Task<IActionResult> Get(int id, [FromQuery] int companyId) =>
        await service.GetAsync(companyId, id) is { } t ? Ok(t) : NotFound();

    [HttpGet("assignments")]
    public async Task<IActionResult> Assignments([FromQuery] int companyId) => Ok(await service.AssignmentsAsync(companyId));

    [HttpGet("resolve")]
    [PublicEndpoint]
    public async Task<IActionResult> Resolve([FromQuery] int branchId, [FromQuery] string kind) =>
        await service.ResolveAsync(branchId, (kind ?? "").ToUpperInvariant()) is { } t ? Ok(t) : NoContent();

    [HttpPost("save")]
    public Task<IActionResult> Save([FromBody] PrintTemplateSaveRequest r) => Run(async () => new { templateId = await service.SaveAsync(r) });

    [HttpPost("publish")]
    public Task<IActionResult> Publish([FromBody] PrintTemplateActionRequest r) => Run(async () => new { version = await service.PublishAsync(r) });

    [HttpPost("restore")]
    public Task<IActionResult> Restore([FromBody] PrintTemplateActionRequest r) => Run(async () => { await service.RestoreAsync(r); return null; });

    [HttpPost("delete")]
    public Task<IActionResult> Delete([FromBody] PrintTemplateActionRequest r) => Run(async () => { await service.DeleteAsync(r); return null; });

    [HttpPost("assign")]
    public Task<IActionResult> Assign([FromBody] PrintTemplateAssignRequest r) => Run(async () => { await service.AssignAsync(r); return null; });
}
