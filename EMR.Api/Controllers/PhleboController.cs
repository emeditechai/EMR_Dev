using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Controllers;

/// <summary>
/// The phlebotomist app. Sign-in is api/auth. Access follows the user's Is Phlebotomist switch, not a role permission,
/// so a phlebotomist works in every branch they are mapped to whatever their role there: the routes skip the page
/// check ([PublicEndpoint]) and usp_Phlebo_Guard refuses anyone who is not an active phlebotomist. The routes stay
/// mapped to LAB.PHLEBOAPP (SQLScripts/2373) for Settings > Security listings.
/// The user comes from the token and the phone from the X-Device-Id header, never from the body.
/// </summary>
[ApiController]
[PublicEndpoint]
[Route("api/phlebo")]
[Produces("application/json")]
public sealed class PhleboController(IPhleboService phlebo, ILogger<PhleboController> logger) : ControllerBase
{
    private const string DeviceHeader = "X-Device-Id";

    // ── session and device ───────────────────────────────────────────────
    [HttpGet("session")]
    public Task<IActionResult> Session() => Run(requireDevice: false, async c =>
    {
        var code = await phlebo.GuardAsync(c);
        return Ok(new { success = true, code, session = await phlebo.SessionAsync(c) });
    });

    [HttpPost("device/register")]
    public Task<IActionResult> RegisterDevice([FromBody] PhleboDeviceRequest request) => Run(requireDevice: false, async c =>
        Ok(new { success = true, status = await phlebo.RegisterDeviceAsync(c, request) }));

    // ── attendance and location ──────────────────────────────────────────
    [HttpPost("attendance/photo")]
    [RequestSizeLimit(9 * 1024 * 1024)]
    public Task<IActionResult> AttendancePhoto([FromForm] string docType, IFormFile file) => Run(async c =>
        Ok(new { success = true, documentId = await phlebo.SaveDocumentAsync(c, null, docType, file, null) }));

    [HttpPost("attendance/punch")]
    public Task<IActionResult> Punch([FromBody] PhleboPunchRequest request) => Run(async c =>
        BadEvent(request.ClientEventId) ?? Ok(new { success = true, attendance = await phlebo.PunchAsync(c, request) }));

    [HttpPost("location/batch")]
    public Task<IActionResult> LocationBatch([FromBody] List<PhleboLocationPoint> points) => Run(async c =>
        points.Count > 500 ? Refuse("Send at most 500 points at a time.")
                           : Ok(new { success = true, saved = await phlebo.SaveLocationAsync(c, points) }));

    // ── visits ───────────────────────────────────────────────────────────
    [HttpGet("visits")]
    public Task<IActionResult> Visits([FromQuery] DateTime? date) => Run(async c =>
        Ok(new { success = true, visits = await phlebo.VisitsAsync(c, date) }));

    [HttpGet("visits/{id:int}")]
    public Task<IActionResult> Visit(int id) => Run(async c => Ok(new { success = true, data = await phlebo.VisitAsync(c, id) }));

    [HttpPost("visits/{id:int}/events")]
    public Task<IActionResult> VisitEvent(int id, [FromBody] PhleboEventRequest request) => Run(async c =>
        BadEvent(request.ClientEventId) ?? Ok(new { success = true, visit = await phlebo.VisitEventAsync(c, id, request) }));

    [HttpPost("visits/{id:int}/verify")]
    public Task<IActionResult> Verify(int id, [FromBody] PhleboVerifyRequest request) => Run(async c =>
    {
        switch (request.Action)
        {
            case "SEND":
                await phlebo.SendOtpAsync(c, id);
                return Ok(new { success = true, message = "Code sent to the patient on WhatsApp." });
            case "CHECK" or "ID_PROOF":
                await phlebo.VerifyAsync(c, id, request);
                return Ok(new { success = true, message = "Patient verified." });
            default:
                return Refuse("Action must be SEND, CHECK or ID_PROOF.");
        }
    });

    [HttpPost("visits/{id:int}/samples")]
    public Task<IActionResult> Samples(int id, [FromBody] PhleboSamplesRequest request) => Run(async c =>
        BadEvent(request.ClientEventId) ?? Ok(new { success = true, visit = await phlebo.SamplesAsync(c, id, request) }));

    [HttpPost("visits/{id:int}/payment")]
    public Task<IActionResult> Payment(int id, [FromBody] PhleboPaymentRequest request) => Run(async c =>
        BadEvent(request.ClientEventId) ?? Ok(new { success = true, payment = await phlebo.PaymentAsync(c, id, request) }));

    [HttpPost("visits/{id:int}/documents")]
    [RequestSizeLimit(9 * 1024 * 1024)]
    public Task<IActionResult> Documents(int id, [FromForm] string docType, IFormFile file, [FromForm] string? remarks) => Run(async c =>
        Ok(new { success = true, documentId = await phlebo.SaveDocumentAsync(c, id, docType, file, remarks) }));

    // the in-app map: the road route from the phone's position to the patient
    [HttpGet("visits/{id:int}/route")]
    public Task<IActionResult> Route(int id, [FromQuery] double lat, [FromQuery] double lng) => Run(async c =>
        Ok(new { success = true, route = await phlebo.RouteAsync(c, id, lat, lng) }));

    [HttpGet("visits/{id:int}/tests")]
    public Task<IActionResult> SearchTests(int id, [FromQuery] string search) => Run(async c =>
        Ok(new { success = true, tests = await phlebo.SearchTestsAsync(c, id, search ?? "") }));

    // ── bill change, handover, day summary ───────────────────────────────
    [HttpPost("bill-changes")]
    public Task<IActionResult> CreateBillChange([FromBody] PhleboBillChangeRequest request) => Run(async c =>
        BadEvent(request.ClientEventId) ?? Ok(new { success = true, request = await phlebo.CreateBillChangeAsync(c, request) }));

    [HttpGet("bill-changes")]
    public Task<IActionResult> BillChanges([FromQuery] int? visitId) => Run(async c =>
        Ok(new { success = true, requests = await phlebo.BillChangesAsync(c, visitId) }));

    [HttpPost("handover")]
    public Task<IActionResult> Handover([FromBody] PhleboHandoverRequest request) => Run(async c =>
        BadEvent(request.ClientEventId) ?? Ok(new { success = true, handover = await phlebo.HandoverAsync(c, request) }));

    [HttpGet("summary")]
    public Task<IActionResult> Summary() => Run(async c => Ok(new { success = true, summary = await phlebo.SummaryAsync(c) }));

    // ── helpers ──────────────────────────────────────────────────────────
    private Task<IActionResult> Run(Func<PhleboCaller, Task<IActionResult>> action) => Run(requireDevice: true, action);

    /// <summary>Every route: an app sign-in only; the guard refuses a non-phlebotomist or a phone that is not approved.</summary>
    private async Task<IActionResult> Run(bool requireDevice, Func<PhleboCaller, Task<IActionResult>> action)
    {
        if (User.FindFirstValue(TokenUse.ClaimType) != TokenUse.Access
            || !int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var userId)
            || !int.TryParse(User.FindFirstValue("CompanyId"), out var companyId)
            || !int.TryParse(User.FindFirstValue("BranchId"), out var branchId))
            return StatusCode(403, new { success = false, code = "FORBIDDEN", message = "Sign in through the phlebotomist app." });

        var deviceId = Request.Headers[DeviceHeader].ToString().Trim();
        if (deviceId.Length is 0 or > 100) return Refuse("This phone did not send its device id.", "DEVICE_REQUIRED");
        var caller = new PhleboCaller(userId, companyId, branchId, deviceId);

        try
        {
            // every route needs an active phlebotomist; most also need an approved phone and a shift and zone
            var code = await phlebo.GuardAsync(caller);
            if (code == "NOT_PHLEBOTOMIST" || (requireDevice && code != "OK"))
                return StatusCode(403, new { success = false, code, message = GuardMessage(code) });
            return await action(caller);
        }
        catch (PhleboRuleException ex)
        {
            return Refuse(ex.Message);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            return Refuse(ex.Message);
        }
        catch (SqlException ex)
        {
            logger.LogError(ex, "[PHLEBO] Database error for user {UserId}", userId);
            return StatusCode(500, new { success = false, code = "SERVER_ERROR", message = "Something went wrong. Try again." });
        }
    }

    private IActionResult? BadEvent(string? clientEventId) =>
        string.IsNullOrWhiteSpace(clientEventId) || clientEventId.Length > 50 ? Refuse("A valid ClientEventId is required.") : null;

    private BadRequestObjectResult Refuse(string message, string code = "RULE") => BadRequest(new { success = false, code, message });

    private static string GuardMessage(string code) => code switch
    {
        "NOT_PHLEBOTOMIST" => "This login is not set up as a phlebotomist.",
        "NO_SHIFT" => "Your shift or zone is not set. Contact your supervisor.",
        "DEVICE_NEW" => "Register this phone first.",
        "DEVICE_PENDING" => "This phone is waiting for your supervisor's approval.",
        "DEVICE_REVOKED" => "This phone has been blocked. Contact your supervisor.",
        _ => "You cannot use the app right now."
    };
}
