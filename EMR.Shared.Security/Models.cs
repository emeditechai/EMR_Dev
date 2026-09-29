namespace EMR.Shared.Security;

public enum AuthorizationMode
{
    /// <summary>No evaluation at all.</summary>
    Off,
    /// <summary>Every request is evaluated; would-be refusals are logged, nothing is blocked.</summary>
    Audit,
    /// <summary>Refusals are enforced (optionally only for the modules listed in EnforceModules).</summary>
    Enforce
}

public sealed class EmrAuthorizationOptions
{
    public const string SectionName = "Authorization";

    public AuthorizationMode Mode { get; set; } = AuthorizationMode.Audit;

    /// <summary>
    /// With Mode = Enforce: when non-empty, only pages whose code starts with one of these modules
    /// (LAB, OPD, MASTER, ...) are blocked; everything else stays in audit. Empty = enforce everything.
    /// </summary>
    public List<string> EnforceModules { get; set; } = new();

    /// <summary>With Mode = Enforce: refuse endpoints that have no page mapping. Keep false until the unmapped list is zero.</summary>
    public bool EnforceUnmapped { get; set; }

    /// <summary>How long a user's Permission_Version / active flag is trusted before it is re-read.</summary>
    public int VersionCheckSeconds { get; set; } = 30;

    /// <summary>Record every controller action on start-up (the endpoint inventory).</summary>
    public bool ScanEndpointsOnStartup { get; set; } = true;

    /// <summary>Render the navigation bar from MenuMaster/PageMaster instead of the markup in _Layout.</summary>
    public bool DatabaseNavigation { get; set; }

    /// <summary>True when a refusal on this page blocks (Enforce, and the page's module is enforced), false while it is only audited.</summary>
    public bool IsEnforced(string pageCode)
    {
        if (Mode != AuthorizationMode.Enforce) return false;
        var module = pageCode.Split('.')[0];
        return EnforceModules.Count == 0 || EnforceModules.Contains(module, StringComparer.OrdinalIgnoreCase);
    }
}

/// <summary>Who is asking: the signed-in user in their current branch and active role.</summary>
public sealed record PermissionSubject(int UserId, int BranchId, int CompanyId, string? ActiveRoleName);

public sealed class EffectivePermissionRow
{
    public string Page_Code { get; set; } = string.Empty;
    public int Page_ID { get; set; }
    public string Control_Code { get; set; } = string.Empty;
    public int Control_ID { get; set; }
    public string Permission { get; set; } = "D";
    public int Decided_At_Scope { get; set; }
    public string Decided_By { get; set; } = "NONE";
}

public sealed class EndpointMapRow
{
    public string App { get; set; } = "WEB";
    public string Http_Method { get; set; } = "GET";
    public string Controller { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
    public string? Page_Code { get; set; }
    public string? Control_Code { get; set; }
    public bool Is_Public { get; set; }
}

public sealed class UserSecurityState
{
    public int Permission_Version { get; set; }
    public bool IsSuperAdmin { get; set; }
    public bool IsActive { get; set; }
}

/// <summary>A user's complete, resolved permission set for one branch and role. Decisions are dictionary lookups.</summary>
public sealed class PermissionSet
{
    private readonly Dictionary<string, EffectivePermissionRow> _rows;

    public PermissionSet(IEnumerable<EffectivePermissionRow> rows, bool isSuperAdmin, int version)
    {
        _rows = new Dictionary<string, EffectivePermissionRow>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in rows) _rows[Key(r.Page_Code, r.Control_Code)] = r;
        IsBypass = isSuperAdmin || (_rows.Count > 0 && _rows.Values.All(r => r.Decided_By == "BYPASS"));
        Version = version;
    }

    /// <summary>Super admin (Users.IsSuperAdmin) only: allowed everything, including pages nobody has mapped yet.</summary>
    public bool IsBypass { get; }
    public int Version { get; }
    public IReadOnlyCollection<EffectivePermissionRow> Rows => _rows.Values;

    public bool Can(string pageCode, string controlCode = PermissionControls.View)
    {
        if (IsBypass) return true;
        return _rows.TryGetValue(Key(pageCode, controlCode), out var r) && r.Permission == "A";
    }

    public EffectivePermissionRow? Explain(string pageCode, string controlCode = PermissionControls.View)
        => _rows.TryGetValue(Key(pageCode, controlCode), out var r) ? r : null;

    /// <summary>
    /// Refused by a row someone set (a deny on the control, its page or a menu above, for this user or a role) - as
    /// opposed to refused only because nothing was granted yet.
    /// </summary>
    public bool IsExplicitDeny(string pageCode, string controlCode = PermissionControls.View)
    {
        if (IsBypass) return false;
        var row = Explain(pageCode, controlCode);
        if (row is null || row.Permission != "D") return false;
        if (row.Decided_By is "USER" or "ROLE") return true;
        // a control refused because its page is refused: explicit when the page's refusal is
        return row.Decided_By == "PAGE" && controlCode != PermissionControls.View && IsExplicitDeny(pageCode, PermissionControls.View);
    }

    /// <summary>
    /// Whether a refusal blocks. In Enforce mode an explicit deny always blocks; a page nobody granted blocks only
    /// once its module is enforced (Authorization:EnforceModules) - so switching a module on is what turns
    /// "not granted" into "refused", while a Deny ticked on the Security screens works at once.
    /// </summary>
    public bool Blocks(EmrAuthorizationOptions options, string pageCode, string controlCode = PermissionControls.View)
        => !Can(pageCode, controlCode) && options.Mode == AuthorizationMode.Enforce
           && (options.IsEnforced(pageCode) || IsExplicitDeny(pageCode, controlCode));

    public IEnumerable<string> AllowedPages()
        => IsBypass
            ? _rows.Values.Select(r => r.Page_Code).Distinct(StringComparer.OrdinalIgnoreCase)
            : _rows.Values.Where(r => r.Control_Code == PermissionControls.View && r.Permission == "A").Select(r => r.Page_Code);

    private static string Key(string page, string control) => page + "|" + control;
}

public enum EndpointOutcome { Allowed, Public, Denied, Unmapped, Inactive }

public sealed class EndpointDecision
{
    public EndpointOutcome Outcome { get; init; }
    public string? PageCode { get; init; }
    public string? ControlCode { get; init; }
    public int? DecidedAtScope { get; init; }
    public string? DecidedBy { get; init; }
    public bool IsAllowed => Outcome is EndpointOutcome.Allowed or EndpointOutcome.Public;

    /// <summary>The module a page belongs to: the first segment of its code (LAB, OPD, MASTER...).</summary>
    public string? Module => PageCode is { Length: > 0 } p ? p.Split('.')[0] : null;

    /// <summary>Every page the endpoint is placed on (a refusal checked all of them). Empty when not from the map.</summary>
    public IReadOnlyList<string> CandidatePages { get; init; } = Array.Empty<string>();

    /// <summary>Candidate pages refused by a deny someone set (these block even while their module is in audit).</summary>
    public IReadOnlyList<string> ExplicitlyDeniedPages { get; init; } = Array.Empty<string>();
}
