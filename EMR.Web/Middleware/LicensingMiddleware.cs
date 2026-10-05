using EMR.Web.Services.Licensing;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;

namespace EMR.Web.Middleware;

/// <summary>
/// eCare360 licence gate: every request (after authentication) needs a Valid licence, except the licence pages, the
/// sign-in pages, the error page and static files. Unregistered goes to the registration form, any other status signs
/// the user out and goes to the blocked page; an AJAX call gets 403 JSON instead of a redirect.
/// Does nothing while Licensing:Enabled is false.
/// </summary>
public sealed class LicensingMiddleware(RequestDelegate next, ILogger<LicensingMiddleware> logger)
{
    public async Task InvokeAsync(HttpContext context, ILicensingService licensing)
    {
        if (!licensing.Enabled || IsOpen(context))
        {
            await next(context);
            return;
        }

        LicenseGateResult gate;
        try { gate = await licensing.EvaluateAccessAsync(context); }
        catch (Exception ex)
        {
            logger.LogError(ex, "Licence evaluation failed.");
            gate = LicenseGateResult.Of(LicenseGateStatus.UnknownError, "The licence could not be checked.");
        }

        if (gate.IsAllowed)
        {
            await next(context);
            return;
        }

        if (context.User.Identity?.IsAuthenticated == true)
            await context.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);

        var target = gate.Status == LicenseGateStatus.Unregistered
            ? $"{context.Request.PathBase}/License/Register"
            : $"{context.Request.PathBase}/License/Blocked?status={gate.Status}";

        if (IsAjax(context.Request))
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            await context.Response.WriteAsJsonAsync(new { success = false, licensing = true, status = gate.Status.ToString(), message = "The application licence is not valid.", redirect = target });
            return;
        }
        context.Response.Redirect(target);
    }

    /// <summary>
    /// Decided by what the request will actually run (routing has already matched it), never by how the address looks:
    /// a page address ending in ".js" is still the page. Open: the licence and sign-in controllers, the error page,
    /// static files (an endpoint that is not a controller action), and no endpoint at all (404).
    /// </summary>
    private static bool IsOpen(HttpContext context)
    {
        var endpoint = context.GetEndpoint();
        if (endpoint is null) return true;
        var action = endpoint.Metadata.GetMetadata<Microsoft.AspNetCore.Mvc.Controllers.ControllerActionDescriptor>();
        if (action is null) return endpoint.Metadata.GetMetadata<Microsoft.AspNetCore.StaticAssets.StaticAssetDescriptor>() != null
                                   || endpoint.DisplayName?.Contains("static", StringComparison.OrdinalIgnoreCase) == true;
        // the sign-in page itself is gated: nobody reaches login until this server's licence is in place;
        // only signing out stays open
        if (action.ControllerName.Equals("Account", StringComparison.OrdinalIgnoreCase))
            return action.ActionName is "Logout" or "SessionTimeoutLogout" or "AccessDenied";
        return action.ControllerName.Equals("License", StringComparison.OrdinalIgnoreCase)
               || (action.ControllerName.Equals("Home", StringComparison.OrdinalIgnoreCase) && action.ActionName.Equals("Error", StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsAjax(HttpRequest request) =>
        string.Equals(request.Headers.XRequestedWith, "XMLHttpRequest", StringComparison.OrdinalIgnoreCase)
        || (request.Headers.Accept.ToString().Contains("application/json", StringComparison.OrdinalIgnoreCase)
            && !request.Headers.Accept.ToString().Contains("text/html", StringComparison.OrdinalIgnoreCase));
}
