using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.AspNetCore.Mvc.ViewFeatures;
using Microsoft.AspNetCore.Razor.TagHelpers;
using Microsoft.Extensions.Options;

namespace EMR.Shared.Security;

/// <summary>
/// <c>asp-permission="LAB.LABREPORTING:APPROVE"</c> (or a comma list, any of which will do) on any element removes it when the user may not
/// perform that action, so the screen matches what the server will allow. A courtesy only: the
/// endpoint behind the button is still checked by <see cref="PermissionFilter"/>.
/// With <c>asp-permission-mode="hide"</c> the element stays in the page (for scripts that read it), hidden and
/// disabled, followed by a short "no permission" note.
/// While a module is in audit mode nothing is hidden, so staff see no change before switch-on.
/// </summary>
[HtmlTargetElement(Attributes = AttributeName)]
public sealed class PermissionTagHelper(IPermissionService permissions, IOptionsMonitor<EmrAuthorizationOptions> options) : TagHelper
{
    private const string AttributeName = "asp-permission";

    [HtmlAttributeName(AttributeName)]
    public string Permission { get; set; } = string.Empty;

    /// <summary>"remove" (default) or "hide".</summary>
    [HtmlAttributeName("asp-permission-mode")]
    public string Mode { get; set; } = "remove";

    [ViewContext, HtmlAttributeNotBound]
    public ViewContext ViewContext { get; set; } = default!;

    public override async Task ProcessAsync(TagHelperContext context, TagHelperOutput output)
    {
        // "PAGE:CONTROL", or several separated by commas meaning "any of these" (an action placed on more than one page).
        var targets = Permission.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(t => t.Split(':', 2, StringSplitOptions.TrimEntries))
            .Select(p => (Page: p[0], Control: p.Length > 1 && p[1].Length > 0 ? p[1] : PermissionControls.View))
            .ToList();
        if (targets.Count == 0) return;

        // Hidden when every target is refused and that refusal blocks: its module is enforced, or a Deny was set.
        var opts = options.CurrentValue;
        var subject = PermissionSubjectReader.FromPrincipal(ViewContext.HttpContext.User);
        if (subject is null)
        {
            if (!targets.Any(t => opts.IsEnforced(t.Page))) return;
        }
        else
        {
            var set = await permissions.GetPermissionSetAsync(subject);
            if (!targets.All(t => set.Blocks(opts, t.Page, t.Control))) return;
        }

        if (!string.Equals(Mode, "hide", StringComparison.OrdinalIgnoreCase))
        {
            output.SuppressOutput();
            return;
        }

        var cls = output.Attributes.TryGetAttribute("class", out var c) ? c.Value?.ToString() : null;
        output.Attributes.SetAttribute("class", string.IsNullOrWhiteSpace(cls) ? "d-none" : cls + " d-none");
        output.Attributes.SetAttribute("disabled", "disabled");
        output.Attributes.SetAttribute("aria-hidden", "true");
        output.PostElement.AppendHtml(
            "<span class=\"text-muted small emr-no-permission\"><i class=\"bi bi-lock-fill me-1\"></i>You do not have permission for this action.</span>");
    }
}
