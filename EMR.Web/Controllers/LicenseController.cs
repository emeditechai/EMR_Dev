using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using EMR.Web.Services.Licensing;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Options;

namespace EMR.Web.Controllers;

/// <summary>
/// eCare360 licence pages: registration with a vendor-approved OTP, the blocked page (retry, hardware renewal with an
/// OTP), and Settings > Licence for administrators. Outside the licence gate; each action re-checks the licence and
/// acts only in the state it is meant for (register only when Unregistered, renew only on HardwareMismatch).
/// Public (anonymous) actions are marked one by one; Settings > Licence needs a signed-in administrator.
/// </summary>
[Authorize]
public class LicenseController(
    ILicensingService licensing,
    IOptions<LicensingOptions> options,
    IAdministratorCheck administratorCheck,
    IAuditLogService auditLog) : Controller
{
    public const string OtpRateLimit = "license-otp";
    private readonly LicensingOptions _o = options.Value;

    [AllowAnonymous]
    [HttpGet]
    public async Task<IActionResult> Register()
    {
        if (!licensing.Enabled) return RedirectToAction("Login", "Account");
        var gate = await licensing.EvaluateAccessAsync(HttpContext);
        if (gate.IsAllowed) return RedirectToAction("Login", "Account");
        if (gate.Status != LicenseGateStatus.Unregistered) return RedirectToAction(nameof(Blocked), new { status = gate.Status });
        var fp = licensing.Machine;
        return View(new LicenseRegisterViewModel
        {
            ProductName = _o.ProductDisplayName, AppUrl = licensing.AppUrl(HttpContext), ServerName = Environment.MachineName,
            ServerMacID = fp.ServerMacID, HardDiskNumber = fp.HardDiskNumber, MotherboardNumber = fp.MotherboardNumber,
            DefaultEndDate = DateTime.Today.AddDays(_o.DefaultTermDays), MaxEndDate = DateTime.Today.AddDays(_o.MaxTermDays),
            OtpLength = _o.OtpLength, OtpLifetimeSeconds = _o.OtpLifetimeSeconds,
            MovedClientCode = gate.MovedClientCode, MovedAppUrl = gate.MovedAppUrl, VendorContact = _o.VendorContact
        });
    }

    [AllowAnonymous]
    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting(OtpRateLimit)]
    public async Task<IActionResult> StartRegistrationOtp([FromBody] LicenseRegisterInput input)
    {
        if (input is null || input.EndDate is null) return Json(new { success = false, message = "Fill in the client details and the licence end date." });
        var (ok, message) = await licensing.StartRegistrationOtpAsync(HttpContext, new RegistrationRequest
        {
            ClientName = input.ClientName ?? string.Empty, ContactNumber = input.ContactNumber ?? string.Empty, EmailID = input.EmailID,
            EndDate = input.EndDate.Value, AmcDate = input.AmcDate
        });
        return Json(new { success = ok, message });
    }

    [AllowAnonymous]
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> VerifyRegistrationOtp([FromBody] LicenseOtpInput input)
    {
        var (ok, message) = await licensing.VerifyRegistrationOtpAsync(HttpContext, input?.Otp ?? string.Empty);
        if (ok) await AuditAsync("License.Registered", message);
        return Json(new { success = ok, message, redirect = ok ? Url.Action("Login", "Account") : null });
    }

    [AllowAnonymous]
    [HttpGet]
    public async Task<IActionResult> Blocked(string? status)
    {
        if (!licensing.Enabled) return RedirectToAction("Login", "Account");
        var gate = await licensing.EvaluateAccessAsync(HttpContext);
        if (gate.IsAllowed) return RedirectToAction("Login", "Account");
        if (gate.Status == LicenseGateStatus.Unregistered) return RedirectToAction(nameof(Register));
        var vm = Describe(gate.Status, gate.Reason);
        vm.LastCheck = await licensing.LastCheckAsync();
        return View(vm);
    }

    [AllowAnonymous]
    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting(AccountController.SignInRateLimit)]
    public async Task<IActionResult> RetryValidation() => await RevalidateAndRouteAsync();

    /// <summary>"Re-validate licence" on the login page: checks every value with the licence server now, then opens the
    /// login page again (valid), the registration form (vendor OTP) or the Blocked page (renewal OTP, vendor action).</summary>
    [AllowAnonymous]
    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting(AccountController.SignInRateLimit)]
    public async Task<IActionResult> Revalidate() => await RevalidateAndRouteAsync();

    private async Task<IActionResult> RevalidateAndRouteAsync()
    {
        if (!licensing.Enabled) return RedirectToAction("Login", "Account");
        var gate = await licensing.RevalidateAsync(HttpContext);
        await AuditAsync("License.Revalidated", $"Licence re-validated with the licence server: {gate.Status}.");
        if (gate.IsAllowed)
        {
            TempData["LicenseMessage"] = gate.OfflineGrace
                ? $"The licence server could not be reached; offline grace: {gate.OfflineGraceDaysLeft} day(s) left."
                : $"Licence validated with the licence server at {DateTime.Now:hh:mm tt}.";
            return RedirectToAction("Login", "Account");
        }
        return gate.Status == LicenseGateStatus.Unregistered ? RedirectToAction(nameof(Register)) : RedirectToAction(nameof(Blocked), new { status = gate.Status });
    }

    [AllowAnonymous]
    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting(OtpRateLimit)]
    public async Task<IActionResult> StartRenewalOtp([FromBody] LicenseOtpInput input)
    {
        var (ok, message) = await licensing.StartRenewalOtpAsync(HttpContext, input?.LicenseKey ?? string.Empty);
        return Json(new { success = ok, message });
    }

    [AllowAnonymous]
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> VerifyRenewalOtp([FromBody] LicenseOtpInput input)
    {
        var (ok, message) = await licensing.VerifyRenewalOtpAsync(HttpContext, input?.Otp ?? string.Empty);
        if (ok) await AuditAsync("License.HardwareRenewed", message);
        return Json(new { success = ok, message, redirect = ok ? Url.Action("Login", "Account") : null });
    }

    // ── Settings > Licence (administrators) ──────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        if (!await administratorCheck.IsSuperAdminOrAdministratorAsync(HttpContext)) return RedirectToAction("AccessDenied", "Account");
        ViewBag.ExpiryWarningDays = _o.ExpiryWarningDays;
        ViewBag.OfflineGraceDays = _o.OfflineGraceDays;
        return View(await licensing.GetOverviewAsync(HttpContext));
    }

    /// <summary>Clears the in-memory licence and hardware caches and checks with the licence server now. Deletes nothing.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ClearCache()
    {
        if (!await administratorCheck.IsSuperAdminOrAdministratorAsync(HttpContext)) return RedirectToAction("AccessDenied", "Account");
        licensing.ClearCaches(HttpContext);
        var gate = await licensing.EvaluateAccessAsync(HttpContext, force: true);
        await AuditAsync("License.Rechecked", $"Licence re-checked with the licence server: {gate.Status}.");
        if (gate.IsAllowed)
        {
            TempData["SuccessMessage"] = gate.OfflineGrace
                ? $"The licence server could not be reached; offline grace keeps the application running for {gate.OfflineGraceDaysLeft} more day(s)."
                : "Licence checked with the licence server: valid.";
            return RedirectToAction(nameof(Index));
        }
        // the licence server could not be reached, but today's earlier validation still stands: say so instead of blocking
        licensing.ClearCaches(HttpContext);   // the refusal just cached must not answer the next question
        if (gate.Status == LicenseGateStatus.RemoteUnavailable && (await licensing.EvaluateAccessAsync(HttpContext)).IsAllowed)
        {
            TempData["ErrorMessage"] = "The licence server could not be reached. The licence was validated earlier today, so the application keeps working until tomorrow's check; restore the connection before then.";
            return RedirectToAction(nameof(Index));
        }
        return RedirectToAction(nameof(Blocked), new { status = gate.Status });
    }

    private LicenseBlockedViewModel Describe(LicenseGateStatus status, string? reason)
    {
        var vm = new LicenseBlockedViewModel
        {
            ProductName = _o.ProductDisplayName, Status = status, Detail = reason, VendorContact = _o.VendorContact,
            AppUrl = licensing.AppUrl(HttpContext), ServerName = Environment.MachineName, OtpLength = _o.OtpLength
        };
        (vm.Title, vm.Message) = status switch
        {
            LicenseGateStatus.PendingActivation => ("Licence pending activation", "The licence is registered but not yet activated by the vendor."),
            LicenseGateStatus.Inactive => ("Client deactivated", "This licence has been deactivated by the vendor. Contact the vendor to reactivate it."),
            LicenseGateStatus.Expired => ("Software expired", "The licence period has ended. Contact the vendor to renew it."),
            LicenseGateStatus.DataMismatch => ("Licence details do not match", "The licence on this server differs from the licence server. Retry, or contact the vendor."),
            LicenseGateStatus.HardwareMismatch => ("Server hardware changed", "This server's hardware differs from the registered licence. Re-new the licence for this server with your licence key and a vendor OTP."),
            LicenseGateStatus.RemoteNotFound => ("Licence not found", "The licence no longer exists on the licence server. Contact the vendor."),
            LicenseGateStatus.RemoteUnavailable => ("Licence server unreachable", "The licence could not be checked because the licence server cannot be reached. Check the network and retry."),
            LicenseGateStatus.ConfigurationMissing => ("Licensing not configured", "The licence server settings are missing on this server. Contact your administrator."),
            _ => ("Licence check failed", "The licence could not be checked. Retry, or contact the vendor.")
        };
        vm.CanRetry = status is LicenseGateStatus.RemoteUnavailable or LicenseGateStatus.UnknownError or LicenseGateStatus.DataMismatch
                      or LicenseGateStatus.Expired or LicenseGateStatus.Inactive or LicenseGateStatus.PendingActivation or LicenseGateStatus.RemoteNotFound;
        vm.CanRenew = status == LicenseGateStatus.HardwareMismatch;
        return vm;
    }

    private async Task AuditAsync(string action, string description)
    {
        try
        {
            await auditLog.LogActivityAsync(eventType: "Licensing", actionName: action, description: description,
                userId: User.Identity?.IsAuthenticated == true ? User.GetUserIdOrNull() : null, moduleCode: "ADMIN");
        }
        catch { /* audit only */ }
    }
}

internal static class LicenseUserExtensions
{
    public static int? GetUserIdOrNull(this System.Security.Claims.ClaimsPrincipal user) =>
        int.TryParse(user.FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier)?.Value, out var id) ? id : null;
}
