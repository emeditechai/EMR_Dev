using System.Reflection;
using System.Security.Claims;
using System.Threading.Channels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.ActionConstraints;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace EMR.Shared.Security;

/// <summary>Reads the subject from the signed-in principal. The web cookie and (later) the API token carry the same claims.</summary>
public static class PermissionSubjectReader
{
    public static PermissionSubject? FromPrincipal(ClaimsPrincipal user)
    {
        if (user.Identity?.IsAuthenticated != true) return null;
        if (!int.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var userId) || userId <= 0) return null;
        _ = int.TryParse(user.FindFirstValue("BranchId"), out var branchId);
        var companyId = int.TryParse(user.FindFirstValue("CompanyId"), out var c) && c > 0 ? c : 1;
        return new PermissionSubject(userId, branchId, companyId, user.FindFirstValue("ActiveRole"));
    }
}

/// <summary>
/// The enforcement point for every MVC action, registered once globally. Anything that is not
/// public and not mapped to a page is refused once enforcement is on, so a new screen cannot ship
/// unprotected by accident. In Audit mode it decides and logs, and never blocks.
/// </summary>
public sealed class PermissionFilter(
    IPermissionService permissions,
    IDecisionLogWriter log,
    IOptionsMonitor<EmrAuthorizationOptions> options,
    EmrAuthorizationApp app) : IAsyncAuthorizationFilter
{
    public const string DeniedMessage = "You do not have permission to perform this action.";

    public async Task OnAuthorizationAsync(AuthorizationFilterContext context)
    {
        var opts = options.CurrentValue;
        if (context.ActionDescriptor is not ControllerActionDescriptor action) return;
        var alwaysEnforce = context.ActionDescriptor.EndpointMetadata.OfType<AlwaysEnforceAttribute>().Any()
                            || action.ControllerTypeInfo.GetCustomAttribute<AlwaysEnforceAttribute>(true) != null;
        if (opts.Mode == AuthorizationMode.Off && !alwaysEnforce) return;

        // Public and anonymous endpoints are outside the model; unauthenticated requests are left to [Authorize].
        if (IsPublic(context, action)) return;
        var subject = PermissionSubjectReader.FromPrincipal(context.HttpContext.User);
        if (subject is null) return;

        var explicitTargets = DeclaredTargets(action);

        var decision = await permissions.AuthorizeEndpointAsync(
            subject, app.Name, context.HttpContext.Request.Method, action.ControllerName, action.ActionName,
            HasVerbConstraint(action), explicitTargets);

        context.HttpContext.Items["EmrAuthorization.Decision"] = decision;
        if (decision.IsAllowed) return;

        var enforce = alwaysEnforce || ShouldEnforce(opts, decision);
        log.Enqueue(new DecisionLogEntry
        {
            App = app.Name,
            Mode = enforce ? "ENFORCE" : "AUDIT",
            Outcome = decision.Outcome.ToString().ToUpperInvariant(),
            UserId = subject.UserId,
            BranchId = subject.BranchId,
            HttpMethod = context.HttpContext.Request.Method,
            Controller = action.ControllerName,
            Action = action.ActionName,
            Path = context.HttpContext.Request.Path + context.HttpContext.Request.QueryString,
            PageCode = decision.PageCode,
            ControlCode = decision.ControlCode,
            DecidedAtScope = decision.DecidedAtScope,
            DecidedBy = decision.DecidedBy
        });

        if (!enforce) return;
        context.Result = BuildRefusal(context, decision, app);
    }

    private static bool ShouldEnforce(EmrAuthorizationOptions opts, EndpointDecision decision)
    {
        if (opts.Mode != AuthorizationMode.Enforce) return false;
        return decision.Outcome switch
        {
            EndpointOutcome.Inactive => true,
            EndpointOutcome.Unmapped => opts.EnforceUnmapped,
            // An endpoint shared by screens of several modules is refused only when every one of them refuses it:
            // its module is enforced, or someone set a Deny there (an explicit deny works even in an audit module).
            _ => decision.CandidatePages.Count > 0
                 ? decision.CandidatePages.All(p => opts.IsEnforced(p) || decision.ExplicitlyDeniedPages.Contains(p, StringComparer.OrdinalIgnoreCase))
                 : decision.PageCode is { } p && (opts.IsEnforced(p) || decision.ExplicitlyDeniedPages.Count > 0)
        };
    }

    private static IActionResult BuildRefusal(AuthorizationFilterContext context, EndpointDecision decision, EmrAuthorizationApp app)
    {
        var request = context.HttpContext.Request;
        var accept = request.Headers.Accept.ToString();
        var wantsJson = app.AlwaysJson
                        || request.Headers.XRequestedWith == "XMLHttpRequest"
                        || (accept.Contains("application/json", StringComparison.OrdinalIgnoreCase) && !accept.Contains("text/html", StringComparison.OrdinalIgnoreCase))
                        || (context.ActionDescriptor is ControllerActionDescriptor a && a.ActionName.EndsWith("Json", StringComparison.OrdinalIgnoreCase));

        if (wantsJson)
        {
            return new ObjectResult(new
            {
                success = false,
                code = decision.Outcome == EndpointOutcome.Inactive ? "ACCOUNT_INACTIVE" : "FORBIDDEN",
                message = decision.Outcome == EndpointOutcome.Inactive ? "Your account is not active." : DeniedMessage,
                page = decision.PageCode,
                control = decision.ControlCode
            }) { StatusCode = StatusCodes.Status403Forbidden };
        }

        var returnUrl = request.Path + request.QueryString;
        return new RedirectToActionResult(app.AccessDeniedAction, app.AccessDeniedController, new { returnUrl, page = decision.PageCode, control = decision.ControlCode });
    }

    private static bool IsPublic(AuthorizationFilterContext context, ControllerActionDescriptor action)
        => context.ActionDescriptor.EndpointMetadata.Any(m => m is PublicEndpointAttribute or IAllowAnonymous)
           || action.ControllerTypeInfo.GetCustomAttribute<PublicEndpointAttribute>(true) != null;

    /// <summary>[RequiresPermission] on the action wins over the controller's; several on one level mean "any of these".</summary>
    public static List<(string PageCode, string ControlCode)> DeclaredTargets(ControllerActionDescriptor action)
    {
        var onAction = action.MethodInfo.GetCustomAttributes<RequiresPermissionAttribute>(true).ToList();
        var attrs = onAction.Count > 0 ? onAction : action.ControllerTypeInfo.GetCustomAttributes<RequiresPermissionAttribute>(true).ToList();
        return attrs.Select(a => (a.PageCode, a.ControlCode)).ToList();
    }

    internal static bool HasVerbConstraint(ControllerActionDescriptor action)
        => action.ActionConstraints?.OfType<HttpMethodActionConstraint>().Any() == true;
}

/// <summary>Which application is enforcing, and how it answers a refusal.</summary>
public sealed class EmrAuthorizationApp
{
    public string Name { get; init; } = "WEB";
    public bool AlwaysJson { get; init; }
    public string AccessDeniedController { get; init; } = "Account";
    public string AccessDeniedAction { get; init; } = "AccessDenied";
}

public interface IDecisionLogWriter
{
    void Enqueue(DecisionLogEntry entry);
}

/// <summary>
/// Batches refusals into the decision log off the request path. The same user hitting the same
/// refused endpoint is recorded once per 10 minutes, so audit mode cannot flood the table.
/// </summary>
public sealed class DecisionLogWriter(IPermissionDataSource data, ILogger<DecisionLogWriter> logger) : BackgroundService, IDecisionLogWriter
{
    private readonly Channel<DecisionLogEntry> _queue = Channel.CreateBounded<DecisionLogEntry>(
        new BoundedChannelOptions(5000) { FullMode = BoundedChannelFullMode.DropOldest });
    private readonly Dictionary<string, DateTime> _recent = new();
    private readonly object _gate = new();

    public void Enqueue(DecisionLogEntry entry)
    {
        var key = $"{entry.UserId}|{entry.HttpMethod}|{entry.Controller}|{entry.Action}|{entry.Outcome}|{entry.Mode}";
        lock (_gate)
        {
            if (_recent.TryGetValue(key, out var last) && DateTime.UtcNow - last < TimeSpan.FromMinutes(10)) return;
            _recent[key] = DateTime.UtcNow;
            if (_recent.Count > 20000) _recent.Clear();
        }
        _queue.Writer.TryWrite(entry);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var batch = new List<DecisionLogEntry>(100);
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                if (!await _queue.Reader.WaitToReadAsync(stoppingToken)) break;
                await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
                while (batch.Count < 500 && _queue.Reader.TryRead(out var e)) batch.Add(e);
                await data.WriteDecisionLogAsync(batch);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "[AUTHZ] Could not write {Count} decision log row(s).", batch.Count);
            }
            finally { batch.Clear(); }
        }
    }
}
