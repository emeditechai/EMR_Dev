using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;

namespace EMR.Shared.Security;

/// <summary>
/// The single policy decision point: "may this user do this?". Every enforcement point asks it;
/// none keeps its own copy of the rules.
/// </summary>
public interface IPermissionService
{
    /// <summary>The resolved set for a subject, cached per user + branch + role + Permission_Version.</summary>
    Task<PermissionSet> GetPermissionSetAsync(PermissionSubject subject);

    Task<bool> CanAsync(PermissionSubject subject, string pageCode, string controlCode = PermissionControls.View);

    /// <summary>Decides a request for an endpoint. Explicit targets (from [RequiresPermission]) override the endpoint map.</summary>
    Task<EndpointDecision> AuthorizeEndpointAsync(PermissionSubject subject, string app, string httpMethod, string controller, string action,
        bool actionHasVerbConstraint, IReadOnlyList<(string PageCode, string ControlCode)>? explicitTargets = null);

    /// <summary>Forget what is cached for one user, so the next request re-reads their version and set.</summary>
    void InvalidateUser(int userId);

    /// <summary>Forget the cached endpoint map (after a page / endpoint mapping change).</summary>
    void InvalidateEndpointMap();

    /// <summary>Forget the cached navigation tree (after a menu / page change). Part of the nav cache key.</summary>
    void InvalidateNavigation();
    int NavigationGeneration { get; }
}

public sealed class PermissionService(
    IPermissionDataSource data,
    IMemoryCache cache,
    IOptionsMonitor<EmrAuthorizationOptions> options) : IPermissionService
{
    private static int _endpointMapGeneration;

    public async Task<PermissionSet> GetPermissionSetAsync(PermissionSubject subject)
    {
        var state = await GetUserStateAsync(subject.UserId);
        if (state is null || !state.IsActive)
            return new PermissionSet(Array.Empty<EffectivePermissionRow>(), isSuperAdmin: false, version: -1);

        // Super admin is answered at the very first line: no role rows, no user rows, no lookups.
        if (state.IsSuperAdmin)
        {
            return await cache.GetOrCreateAsync($"authz:set:sa:{subject.CompanyId}:{state.Permission_Version}", async e =>
            {
                e.SlidingExpiration = TimeSpan.FromMinutes(30);
                var rows = await data.GetEffectivePermissionsAsync(subject.UserId, subject.BranchId, subject.CompanyId, null);
                return new PermissionSet(rows, isSuperAdmin: true, state.Permission_Version);
            }) ?? new PermissionSet(Array.Empty<EffectivePermissionRow>(), true, state.Permission_Version);
        }

        var roleId = await ResolveRoleIdAsync(subject.CompanyId, subject.ActiveRoleName);
        var key = $"authz:set:{subject.UserId}:{subject.BranchId}:{roleId?.ToString() ?? "all"}:{state.Permission_Version}";
        return await cache.GetOrCreateAsync(key, async e =>
        {
            e.SlidingExpiration = TimeSpan.FromMinutes(30);
            var rows = await data.GetEffectivePermissionsAsync(subject.UserId, subject.BranchId, subject.CompanyId, roleId);
            return new PermissionSet(rows, isSuperAdmin: false, state.Permission_Version);
        }) ?? new PermissionSet(Array.Empty<EffectivePermissionRow>(), false, state.Permission_Version);
    }

    public async Task<bool> CanAsync(PermissionSubject subject, string pageCode, string controlCode = PermissionControls.View)
        => (await GetPermissionSetAsync(subject)).Can(pageCode, controlCode);

    public async Task<EndpointDecision> AuthorizeEndpointAsync(PermissionSubject subject, string app, string httpMethod, string controller,
        string action, bool actionHasVerbConstraint, IReadOnlyList<(string PageCode, string ControlCode)>? explicitTargets = null)
    {
        var state = await GetUserStateAsync(subject.UserId);
        if (state is null || !state.IsActive)
            return new EndpointDecision { Outcome = EndpointOutcome.Inactive };

        List<(string PageCode, string ControlCode)> targets;
        if (explicitTargets is { Count: > 0 })
        {
            targets = explicitTargets.ToList();
        }
        else
        {
            var map = await GetEndpointMapAsync(app);
            var method = httpMethod.ToUpperInvariant() == "HEAD" ? "GET" : httpMethod.ToUpperInvariant();
            if (!map.TryGetValue(EndpointKey(method, controller, action), out var rows) && !actionHasVerbConstraint)
                map.TryGetValue(EndpointKey("GET", controller, action), out rows);

            if (rows is null || rows.Count == 0)
                return await UnmappedAsync(subject);
            if (rows.Any(r => r.Is_Public))
                return new EndpointDecision { Outcome = EndpointOutcome.Public };

            targets = rows.Where(r => r.Page_Code is { Length: > 0 })
                          .Select(r => (r.Page_Code!, r.Control_Code is { Length: > 0 } c ? c : PermissionControls.View))
                          .Distinct()
                          .ToList();
            if (targets.Count == 0)
                return await UnmappedAsync(subject);
        }

        var set = await GetPermissionSetAsync(subject);

        // An endpoint shared by several page placements is allowed when any one of them allows it.
        foreach (var t in targets)
        {
            if (set.Can(t.PageCode, t.ControlCode))
            {
                var ok = set.Explain(t.PageCode, t.ControlCode);
                return new EndpointDecision
                {
                    Outcome = EndpointOutcome.Allowed, PageCode = t.PageCode, ControlCode = t.ControlCode,
                    DecidedAtScope = set.IsBypass ? 99 : ok?.Decided_At_Scope, DecidedBy = set.IsBypass ? "BYPASS" : ok?.Decided_By
                };
            }
        }

        var first = targets[0];
        var why = set.Explain(first.PageCode, first.ControlCode);
        return new EndpointDecision
        {
            Outcome = EndpointOutcome.Denied, PageCode = first.PageCode, ControlCode = first.ControlCode,
            DecidedAtScope = why?.Decided_At_Scope ?? 0, DecidedBy = why?.Decided_By ?? "NONE",
            CandidatePages = targets.Select(t => t.PageCode).Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
            ExplicitlyDeniedPages = targets.Where(t => set.IsExplicitDeny(t.PageCode, t.ControlCode)).Select(t => t.PageCode)
                                           .Distinct(StringComparer.OrdinalIgnoreCase).ToList()
        };
    }

    public void InvalidateUser(int userId) => cache.Remove($"authz:ver:{userId}");

    public void InvalidateEndpointMap() => Interlocked.Increment(ref _endpointMapGeneration);

    private static int _navigationGeneration;
    public void InvalidateNavigation() => Interlocked.Increment(ref _navigationGeneration);
    public int NavigationGeneration => Volatile.Read(ref _navigationGeneration);

    // Unmapped pages still open for a super admin; everyone else is refused (deny by default).
    private async Task<EndpointDecision> UnmappedAsync(PermissionSubject subject)
    {
        var set = await GetPermissionSetAsync(subject);
        return set.IsBypass
            ? new EndpointDecision { Outcome = EndpointOutcome.Allowed, DecidedAtScope = 99, DecidedBy = "BYPASS" }
            : new EndpointDecision { Outcome = EndpointOutcome.Unmapped };
    }

    private async Task<UserSecurityState?> GetUserStateAsync(int userId)
    {
        if (userId <= 0) return null;
        return await cache.GetOrCreateAsync($"authz:ver:{userId}", async e =>
        {
            e.AbsoluteExpirationRelativeToNow = TimeSpan.FromSeconds(Math.Max(1, options.CurrentValue.VersionCheckSeconds));
            return await data.GetUserStateAsync(userId);
        });
    }

    private async Task<int?> ResolveRoleIdAsync(int companyId, string? roleName)
    {
        if (string.IsNullOrWhiteSpace(roleName)) return null;
        var roles = await cache.GetOrCreateAsync($"authz:roles:{companyId}", async e =>
        {
            e.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(10);
            return await data.GetRoleIdsAsync(companyId);
        });
        // An active role that no longer exists resolves to "no role" (-1), never to "all roles".
        return roles != null && roles.TryGetValue(roleName.Trim(), out var id) ? id : -1;
    }

    private async Task<Dictionary<string, List<EndpointMapRow>>> GetEndpointMapAsync(string app)
    {
        var key = $"authz:endpoints:{app}:{Volatile.Read(ref _endpointMapGeneration)}";
        return await cache.GetOrCreateAsync(key, async e =>
        {
            e.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(5);
            var rows = await data.GetEndpointMapAsync(app);
            return rows.GroupBy(r => EndpointKey(r.Http_Method, r.Controller, r.Action), StringComparer.OrdinalIgnoreCase)
                       .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);
        }) ?? new Dictionary<string, List<EndpointMapRow>>(StringComparer.OrdinalIgnoreCase);
    }

    private static string EndpointKey(string method, string controller, string action) => $"{method}|{controller}|{action}";
}
