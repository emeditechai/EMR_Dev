using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Controllers;

/// <summary>
/// Patient Membership Card: plan master and card distribution (SQLScripts/2224).
/// Business-rule failures of the procedures (THROW 51000..51099) come back as 400 with the message.
/// </summary>
[ApiController]
[Route("api/membership")]
public class MembershipController(IMembershipService service, ILogger<MembershipController> logger) : ControllerBase
{
    // ── Membership Plan master ───────────────────────────────────────────────

    [HttpGet("plans")]
    public Task<IActionResult> GetPlans([FromQuery] int companyId, [FromQuery] bool? status = null, [FromQuery] string? search = null) =>
        Run(async () => Ok(await service.GetPlansAsync(companyId, status, search)));

    [HttpGet("plans/{id:int}")]
    public Task<IActionResult> GetPlan(int id, [FromQuery] int companyId) =>
        Run(async () =>
        {
            var plan = await service.GetPlanAsync(id, companyId);
            return plan == null ? NotFound() : Ok(plan);
        });

    [HttpGet("plans/benefit-scopes")]
    public Task<IActionResult> GetBenefitScopes([FromQuery] int companyId) =>
        Run(async () => Ok(await service.GetBenefitScopesAsync(companyId)));

    [HttpPost("plans")]
    public Task<IActionResult> SavePlan([FromBody] MembershipPlanSaveRequest request) =>
        Run(async () => Ok(new { id = await service.SavePlanAsync(request) }));

    [HttpDelete("plans/{id:int}")]
    public Task<IActionResult> DeletePlan(int id, [FromQuery] int companyId, [FromQuery] int userId) =>
        Run(async () => Ok(new { removed = await service.DeletePlanAsync(id, companyId, userId) }));

    // ── Membership Cards ─────────────────────────────────────────────────────

    [HttpGet("patients")]
    public Task<IActionResult> SearchPatients([FromQuery] int companyId, [FromQuery] string search) =>
        Run(async () => Ok(await service.SearchPatientsAsync(companyId, search ?? string.Empty)));

    [HttpPost("cards")]
    public Task<IActionResult> IssueCard([FromBody] MembershipCardIssueRequest request) =>
        Run(async () => Ok(await service.IssueCardAsync(request)));

    [HttpGet("cards")]
    public Task<IActionResult> GetCards(
        [FromQuery] int companyId,
        [FromQuery] int? branchId = null,
        [FromQuery] int? planId = null,
        [FromQuery] string? status = null,
        [FromQuery] string? search = null,
        [FromQuery] DateTime? fromDate = null,
        [FromQuery] DateTime? toDate = null) =>
        Run(async () => Ok(await service.GetCardsAsync(companyId, branchId, planId, status, search, fromDate, toDate)));

    [HttpGet("cards/{id:int}")]
    public Task<IActionResult> GetCard(int id, [FromQuery] int companyId) =>
        Run(async () =>
        {
            var card = await service.GetCardAsync(id, companyId);
            return card == null ? NotFound() : Ok(card);
        });

    [HttpPost("cards/{id:int}/members")]
    public Task<IActionResult> AddMember(int id, [FromBody] MembershipCardAddMemberRequest request) =>
        Run(async () =>
        {
            await service.AddMemberAsync(id, request);
            return NoContent();
        });

    [HttpPost("cards/{id:int}/status")]
    public Task<IActionResult> SetStatus(int id, [FromBody] MembershipCardStatusRequest request) =>
        Run(async () =>
        {
            await service.SetCardStatusAsync(id, request);
            return NoContent();
        });

    [HttpPost("cards/{id:int}/printed")]
    public Task<IActionResult> MarkPrinted(int id, [FromBody] MembershipCardMarkRequest request) =>
        Run(async () =>
        {
            await service.MarkPrintedAsync(id, request.CompanyId, request.UserId);
            return NoContent();
        });

    [HttpPost("cards/{id:int}/sent")]
    public Task<IActionResult> MarkSent(int id, [FromBody] MembershipCardMarkRequest request) =>
        Run(async () =>
        {
            await service.MarkSentAsync(id, request.CompanyId, request.Channel ?? string.Empty);
            return NoContent();
        });

    private async Task<IActionResult> Run(Func<Task<IActionResult>> action)
    {
        try
        {
            return await action();
        }
        catch (SqlException ex) when (ex.Number is >= 51000 and <= 51099)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Membership API error");
            return StatusCode(500, new { message = "Internal server error" });
        }
    }
}
