namespace EMR.Shared.Security;

/// <summary>
/// Opts an endpoint out of the permission check: login, logout, error pages, health, anonymous print
/// harness targets. Authentication rules still apply exactly as the controller declares them.
/// </summary>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, Inherited = true)]
public sealed class PublicEndpointAttribute : Attribute
{
}

/// <summary>
/// Pins an action to a page and control when its default endpoint mapping is not what it means,
/// e.g. <c>[RequiresPermission("LAB.LABREPORTING", "APPROVE")]</c>. Takes precedence over PageEndpointMap.
/// </summary>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, Inherited = true, AllowMultiple = true)]
public sealed class RequiresPermissionAttribute(string pageCode, string controlCode = PermissionControls.View) : Attribute
{
    public string PageCode { get; } = pageCode;
    public string ControlCode { get; } = controlCode;
}

/// <summary>
/// Enforced whatever the configured mode (Audit or even Off): for screens that must never be open to
/// everyone while the rest of the application is still in audit mode - the Security screens above all.
/// </summary>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, Inherited = true)]
public sealed class AlwaysEnforceAttribute : Attribute
{
}

/// <summary>The standard control vocabulary, so a permission means the same thing on every screen.</summary>
public static class PermissionControls
{
    public const string View = "VIEW";
    public const string Create = "CREATE";
    public const string Edit = "EDIT";
    public const string Delete = "DELETE";
    public const string Print = "PRINT";
    public const string Export = "EXPORT";
    public const string Approve = "APPROVE";
    public const string Cancel = "CANCEL";
    public const string Settle = "SETTLE";
    public const string Discount = "DISCOUNT";
    public const string Unauthorize = "UNAUTHORIZE";
    public const string Entry = "ENTRY";
    public const string Validate = "VALIDATE";
    public const string Recollect = "RECOLLECT";
    public const string Refund = "REFUND";
}
