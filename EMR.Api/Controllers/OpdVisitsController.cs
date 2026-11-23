using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// OPD Dashboard > visit Audit History (SQLScripts/2304): the visit's activity and its workflow from booking to the end
/// of the consultation. Read-only; mapped to the OPD Dashboard page.
/// </summary>
[ApiController]
[Route("api/opd-visits")]
public class OpdVisitsController(IOpdVisitHistoryService service) : ControllerBase
{
    [HttpGet("{opdServiceId:int}/activity")]
    public async Task<IActionResult> Activity(int opdServiceId) =>
        opdServiceId <= 0 ? BadRequest(new { message = "A valid OPD visit is required." }) : Ok(await service.ActivityAsync(opdServiceId));

    [HttpGet("{opdServiceId:int}/workflow")]
    public async Task<IActionResult> Workflow(int opdServiceId) =>
        opdServiceId <= 0 ? BadRequest(new { message = "A valid OPD visit is required." }) : Ok(await service.WorkflowAsync(opdServiceId));
}
