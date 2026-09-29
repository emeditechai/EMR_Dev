using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Options;

namespace EMR.Shared.Security;

/// <summary>
/// For checks that depend on what is being posted, not on which endpoint is called - e.g. a report save
/// that becomes an approval when its status is "Approved". Same rules as <see cref="PermissionFilter"/>:
/// refusals are logged, and only block while the page's module is enforced.
/// </summary>
public interface IActionPermissionGuard
{
    /// <summary>True when the current user may do it, or when the page's module is still in audit.</summary>
    Task<bool> AllowsAsync(HttpContext http, string pageCode, string controlCode);

    /// <summary>
    /// The same, for an action shared by several screens of one module: allowed when the user holds the control on any of them.
    /// </summary>
    Task<bool> AllowsAnyAsync(HttpContext http, IReadOnlyList<string> pageCodes, string controlCode);

    /// <summary>
    /// Whether to offer the button: false only when it would be refused (the module is enforced and the user lacks it).
    /// The script-side twin of <c>asp-permission</c>.
    /// </summary>
    Task<bool> ShowsAsync(HttpContext http, string pageCode, string controlCode);
}

public sealed class ActionPermissionGuard(
    IPermissionService permissions,
    IDecisionLogWriter log,
    IOptionsMonitor<EmrAuthorizationOptions> options,
    EmrAuthorizationApp app) : IActionPermissionGuard
{
    public async Task<bool> ShowsAsync(HttpContext http, string pageCode, string controlCode)
    {
        var subject = PermissionSubjectReader.FromPrincipal(http.User);
        if (subject is null) return !options.CurrentValue.IsEnforced(pageCode);
        return !(await permissions.GetPermissionSetAsync(subject)).Blocks(options.CurrentValue, pageCode, controlCode);
    }

    public Task<bool> AllowsAsync(HttpContext http, string pageCode, string controlCode)
        => AllowsAnyAsync(http, [pageCode], controlCode);

    public async Task<bool> AllowsAnyAsync(HttpContext http, IReadOnlyList<string> pageCodes, string controlCode)
    {
        var opts = options.CurrentValue;
        if (opts.Mode == AuthorizationMode.Off || pageCodes.Count == 0) return true;
        var subject = PermissionSubjectReader.FromPrincipal(http.User);
        var set = subject is null ? null : await permissions.GetPermissionSetAsync(subject);
        if (set is not null && pageCodes.Any(p => set.Can(p, controlCode))) return true;

        var pageCode = pageCodes[0];
        var enforce = set is null ? pageCodes.Any(opts.IsEnforced) : pageCodes.All(p => set.Blocks(opts, p, controlCode));
        var why = set?.Explain(pageCode, controlCode);
        var route = http.Request.RouteValues;
        log.Enqueue(new DecisionLogEntry
        {
            App = app.Name,
            Mode = enforce ? "ENFORCE" : "AUDIT",
            Outcome = "DENIED",
            UserId = subject?.UserId,
            BranchId = subject?.BranchId,
            HttpMethod = http.Request.Method,
            Controller = route.TryGetValue("controller", out var c) ? c?.ToString() ?? string.Empty : string.Empty,
            Action = (route.TryGetValue("action", out var a) ? a?.ToString() ?? string.Empty : string.Empty) + ":" + controlCode,
            Path = http.Request.Path + http.Request.QueryString,
            PageCode = pageCode,
            ControlCode = controlCode,
            DecidedAtScope = why?.Decided_At_Scope ?? 0,
            DecidedBy = why?.Decided_By ?? "NONE"
        });
        return !enforce;
    }
}
