using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// One bill per booking (SQLScripts/2310): the booking request key of LAB B2C booking / OPD registration with payment.
/// Mapped to the pages that save those bills.
/// </summary>
[ApiController]
[Route("api/billing-submissions")]
public class BillingSubmissionsController(IBillingSubmissionService service) : ControllerBase
{
    private static readonly string[] Modules = ["LAB", "OPD"];

    [HttpPost("claim")]
    public async Task<IActionResult> Claim([FromBody] BillingSubmissionClaimRequest request)
    {
        if (request is null || request.RequestKey == Guid.Empty || !Modules.Contains(request.ModuleCode?.Trim().ToUpperInvariant()))
            return BadRequest(new { message = "A booking request key and module are required." });
        return Ok(await service.ClaimAsync(request));
    }

    [HttpPost("update")]
    public async Task<IActionResult> Update([FromBody] BillingSubmissionUpdateRequest request)
    {
        if (request is null || request.RequestKey == Guid.Empty || request.ModuleRefId <= 0
            || request.Stage?.Trim().ToUpperInvariant() is not ("CREATED" or "READY"))
            return BadRequest(new { message = "Invalid booking request update." });
        await service.UpdateAsync(request);
        return Ok(new { success = true });
    }

    [HttpPost("release")]
    public async Task<IActionResult> Release([FromBody] BillingSubmissionReleaseRequest request)
    {
        if (request is null || request.RequestKey == Guid.Empty) return BadRequest(new { message = "A booking request key is required." });
        await service.ReleaseAsync(request.RequestKey);
        return Ok(new { success = true });
    }
}
