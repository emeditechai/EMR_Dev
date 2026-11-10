using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Controllers;

/// <summary>
/// The marketing executive side of the phlebotomist app (SQLScripts/2446). Sign-in is api/auth, branch change is
/// api/auth/switch-branch. Like api/phlebo, access follows the user's Is_MarketingExecutive switch and the executive the login
/// belongs to, not a role permission: the routes skip the page check ([PublicEndpoint]) and usp_Mkt_Guard refuses everyone else.
/// The user and branch come from the token and the phone from the X-Device-Id header, never from the body.
/// </summary>
[ApiController]
[PublicEndpoint]
[Route("api/marketing")]
[Produces("application/json")]
public sealed class MarketingController(IMarketingService marketing, ILogger<MarketingController> logger) : ControllerBase
{
    private const string DeviceHeader = "X-Device-Id";

    /// <summary>Which app the login opens; asked right after sign-in, before any phone check.</summary>
    [HttpGet("app-mode")]
    public async Task<IActionResult> AppMode()
    {
        if (User.FindFirstValue(TokenUse.ClaimType) != TokenUse.Access || !int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var userId))
            return StatusCode(403, new { success = false, code = "FORBIDDEN", message = "Sign in through the app." });
        return Ok(new { success = true, mode = await marketing.AppModeAsync(userId) });
    }

    // ── session and device ───────────────────────────────────────────────
    [HttpGet("session")]
    public Task<IActionResult> Session() => Run(requireDevice: false, async c =>
        Ok(new { success = true, code = await marketing.GuardAsync(c), session = await marketing.SessionAsync(c) }));

    [HttpPost("device/register")]
    public Task<IActionResult> RegisterDevice([FromBody] PhleboDeviceRequest request) => Run(requireDevice: false, async c =>
        Ok(new { success = true, status = await marketing.RegisterDeviceAsync(c, request) }));

    [HttpGet("branches")]
    public Task<IActionResult> Branches() => Run(requireDevice: false, async c => Ok(new { success = true, branches = await marketing.BranchesAsync(c) }));

    [HttpGet("specialities")]
    public Task<IActionResult> Specialities() => Run(async c => Ok(new { success = true, specialities = await marketing.SpecialitiesAsync(c) }));

    [HttpGet("summary")]
    public Task<IActionResult> Summary() => Run(async c => Ok(new { success = true, summary = await marketing.SummaryAsync(c) }));

    // ── leads (forecast doctors) ─────────────────────────────────────────
    [HttpGet("leads")]
    public Task<IActionResult> Leads([FromQuery] string? stage, [FromQuery] string? search) => Run(async c =>
        Ok(new { success = true, leads = await marketing.LeadsAsync(c, stage, search) }));

    [HttpGet("leads/{id:int}")]
    public Task<IActionResult> Lead(int id) => Run(async c => Ok(new { success = true, data = await marketing.LeadAsync(c, id) }));

    [HttpPost("leads")]
    public Task<IActionResult> SaveLead([FromBody] MarketingLeadRequest request) => Run(async c =>
        Ok(new { success = true, forecastDoctorId = await marketing.SaveLeadAsync(c, null, request) }));

    [HttpPut("leads/{id:int}")]
    public Task<IActionResult> UpdateLead(int id, [FromBody] MarketingLeadRequest request) => Run(async c =>
        Ok(new { success = true, forecastDoctorId = await marketing.SaveLeadAsync(c, id, request) }));

    [HttpPost("leads/{id:int}/pin")]
    public Task<IActionResult> SetPin(int id, [FromBody] MarketingPinRequest request) => Run(async c =>
    {
        await marketing.SetPinAsync(c, id, request);
        return Ok(new { success = true, message = "Clinic location saved." });
    });

    [HttpPost("leads/{id:int}/stage")]
    public Task<IActionResult> SetStage(int id, [FromBody] MarketingStageRequest request) => Run(async c =>
        Ok(new { success = true, stage = await marketing.SetStageAsync(c, id, request) }));

    /// <summary>Move to Trial: the lead joins Doctor Master as a referral doctor, switched off until the office approves it.</summary>
    [HttpPost("leads/{id:int}/promote")]
    public Task<IActionResult> Promote(int id, [FromBody] MarketingPromoteRequest request) => Run(async c =>
        Ok(new { success = true, doctor = await marketing.PromoteAsync(c, id, request) }));

    [HttpPost("leads/{id:int}/visits")]
    public Task<IActionResult> CreateVisit(int id, [FromBody] MarketingVisitRequest request) => Run(async c =>
        string.IsNullOrWhiteSpace(request.ClientEventId) || request.ClientEventId.Length > 50
            ? Refuse("A valid ClientEventId is required.")
            : Ok(new { success = true, visit = await marketing.CreateVisitAsync(c, id, request) }));

    // ── field day and tracking ───────────────────────────────────────────
    [HttpPost("field-day")]
    public Task<IActionResult> FieldDay([FromBody] MarketingFieldDayRequest request) => Run(async c =>
        Ok(new { success = true, day = await marketing.FieldDayAsync(c, request) }));

    [HttpPost("location/batch")]
    public Task<IActionResult> LocationBatch([FromBody] List<PhleboLocationPoint> points) => Run(async c =>
        points.Count > 500 ? Refuse("Send at most 500 points at a time.")
                           : Ok(new { success = true, saved = await marketing.SaveLocationAsync(c, points) }));

    // ── helpers ──────────────────────────────────────────────────────────
    private Task<IActionResult> Run(Func<MarketingCaller, Task<IActionResult>> action) => Run(requireDevice: true, action);

    /// <summary>Every route: an app sign-in only; the guard refuses a non-executive, and most routes also a phone that is not approved.</summary>
    private async Task<IActionResult> Run(bool requireDevice, Func<MarketingCaller, Task<IActionResult>> action)
    {
        if (User.FindFirstValue(TokenUse.ClaimType) != TokenUse.Access
            || !int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var userId)
            || !int.TryParse(User.FindFirstValue("CompanyId"), out var companyId)
            || !int.TryParse(User.FindFirstValue("BranchId"), out var branchId))
            return StatusCode(403, new { success = false, code = "FORBIDDEN", message = "Sign in through the app." });

        var deviceId = Request.Headers[DeviceHeader].ToString().Trim();
        if (deviceId.Length is 0 or > 100) return Refuse("This phone did not send its device id.", "DEVICE_REQUIRED");
        var caller = new MarketingCaller(userId, companyId, branchId, deviceId);

        try
        {
            var code = await marketing.GuardAsync(caller);
            if (code is "NOT_MARKETING" or "NO_EXECUTIVE" || (requireDevice && code != "OK"))
                return StatusCode(403, new { success = false, code, message = GuardMessage(code) });
            return await action(caller);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            return Refuse(ex.Message);
        }
        catch (SqlException ex)
        {
            logger.LogError(ex, "[MARKETING] Database error for user {UserId}", userId);
            return StatusCode(500, new { success = false, code = "SERVER_ERROR", message = "Something went wrong. Try again." });
        }
    }

    private BadRequestObjectResult Refuse(string message, string code = "RULE") => BadRequest(new { success = false, code, message });

    private static string GuardMessage(string code) => code switch
    {
        "NOT_MARKETING" => "This login is not set up as a marketing executive.",
        "NO_EXECUTIVE" => "No active marketing executive uses this login. Contact the office.",
        "DEVICE_NEW" => "Register this phone first.",
        "DEVICE_PENDING" => "This phone is waiting for your supervisor's approval.",
        "DEVICE_REVOKED" => "This phone has been blocked. Contact your supervisor.",
        _ => "You cannot use the app right now."
    };
}
