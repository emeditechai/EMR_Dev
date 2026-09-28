using System.Security.Claims;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.Extensions.Options;

namespace EMR.Api.Security;

/// <summary>
/// Who may call EMR.Api, applied to every action:
///   - no valid token                  -> 401 (logged only while ApiAuth:Mode = Audit);
///   - a token minted by EMR.Web       -> allowed: the web application has already authorized the user's action
///     (obo = for a signed-in user, service = no staff user, e.g. the patient portal);
///   - an api/auth access token        -> the endpoint must be mapped to a page (Settings > Security, app API) and
///     the user must hold it, exactly like a web screen. Unmapped endpoints are refused.
/// [AllowAnonymous] (sign-in) and [PublicEndpoint] (e.g. api/auth/me) skip the permission step.
/// </summary>
public sealed class ApiCallerFilter(
    IPermissionService permissions,
    IDecisionLogWriter log,
    IOptionsMonitor<ApiAuthOptions> apiAuth,
    ILogger<ApiCallerFilter> logger) : IAsyncAuthorizationFilter
{
    public async Task OnAuthorizationAsync(AuthorizationFilterContext context)
    {
        if (context.ActionDescriptor is not ControllerActionDescriptor action) return;
        if (context.ActionDescriptor.EndpointMetadata.Any(m => m is IAllowAnonymous)) return;

        var http = context.HttpContext;
        var user = http.User;
        var use = user.FindFirstValue(TokenUse.ClaimType);

        if (user.Identity?.IsAuthenticated != true || use is not (TokenUse.OnBehalf or TokenUse.Service or TokenUse.Access))
        {
            if (!apiAuth.CurrentValue.IsEnforced)
            {
                logger.LogWarning("[API-AUTH] Call without a valid token (audit only): {Method} {Path}", http.Request.Method, http.Request.Path);
                return;
            }
            context.Result = new ObjectResult(new { success = false, code = "UNAUTHENTICATED", message = "A valid access token is required." })
                { StatusCode = StatusCodes.Status401Unauthorized };
            http.Response.Headers.WWWAuthenticate = "Bearer";
            return;
        }

        if (use is TokenUse.OnBehalf or TokenUse.Service) return;

        // An outside client (api/auth token): the same permission model as the web screens.
        if (context.ActionDescriptor.EndpointMetadata.Any(m => m is PublicEndpointAttribute)) return;
        var subject = PermissionSubjectReader.FromPrincipal(user);
        if (subject is null)
        {
            context.Result = new ObjectResult(new { success = false, code = "UNAUTHENTICATED", message = "The token has no user." })
                { StatusCode = StatusCodes.Status401Unauthorized };
            return;
        }

        var decision = await permissions.AuthorizeEndpointAsync(subject, "API", http.Request.Method, action.ControllerName, action.ActionName,
            action.ActionConstraints?.OfType<Microsoft.AspNetCore.Mvc.ActionConstraints.HttpMethodActionConstraint>().Any() == true,
            PermissionFilter.DeclaredTargets(action));
        if (decision.IsAllowed) return;

        log.Enqueue(new DecisionLogEntry
        {
            App = "API", Mode = "ENFORCE", Outcome = decision.Outcome.ToString().ToUpperInvariant(),
            UserId = subject.UserId, BranchId = subject.BranchId, HttpMethod = http.Request.Method,
            Controller = action.ControllerName, Action = action.ActionName, Path = http.Request.Path + http.Request.QueryString,
            PageCode = decision.PageCode, ControlCode = decision.ControlCode, DecidedAtScope = decision.DecidedAtScope, DecidedBy = decision.DecidedBy
        });
        context.Result = new ObjectResult(new
        {
            success = false,
            code = decision.Outcome == EndpointOutcome.Inactive ? "ACCOUNT_INACTIVE" : "FORBIDDEN",
            message = decision.Outcome == EndpointOutcome.Unmapped
                ? "This endpoint is not open to API clients yet (map it to a page in Settings > Security)."
                : PermissionFilter.DeniedMessage,
            page = decision.PageCode, control = decision.ControlCode
        }) { StatusCode = StatusCodes.Status403Forbidden };
    }
}

/// <summary>
/// The patient portal's data is served only for the patient the token belongs to (patient_id, set by EMR.Web from the
/// portal session), or to a signed-in staff user. A token with neither is refused, so no one can walk patient ids.
/// </summary>
public sealed class PatientOwnDataAttribute : Attribute, IAuthorizationFilter
{
    public void OnAuthorization(AuthorizationFilterContext context)
    {
        var user = context.HttpContext.User;
        var apiAuth = context.HttpContext.RequestServices.GetRequiredService<IOptionsMonitor<ApiAuthOptions>>().CurrentValue;
        if (user.Identity?.IsAuthenticated != true && !apiAuth.IsEnforced) return;

        if (user.FindFirstValue(ClaimTypes.NameIdentifier) is { Length: > 0 }) return;   // staff (obo / access)
        var own = user.FindFirstValue(TokenUse.PatientIdClaim);
        var asked = context.RouteData.Values.TryGetValue("patientId", out var p) ? p?.ToString() : null;
        if (own is { Length: > 0 } && own == asked) return;

        context.Result = new ObjectResult(new { success = false, code = "FORBIDDEN", message = "You can only see your own records." })
            { StatusCode = StatusCodes.Status403Forbidden };
    }
}
