using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.AspNetCore.Mvc.ViewFeatures;
using Microsoft.AspNetCore.Razor.TagHelpers;
using Microsoft.Extensions.Options;

namespace EMR.Shared.Security;

/// <summary>
/// <c>&lt;emr-permission-script /&gt;</c> in the layout gives scripts <c>emrCan("LAB.LABUNAPPROVE", "UNAUTHORIZE")</c>,
/// the script-side twin of <c>asp-permission</c> for buttons drawn by JavaScript. It carries only the non-VIEW
/// controls the user holds (an allow-list: anything not listed is refused) and the ones explicitly denied; a module
/// still in audit answers true except for an explicit deny. A courtesy only: the endpoint behind the button is still checked on the server.
/// </summary>
[HtmlTargetElement("emr-permission-script", TagStructure = TagStructure.WithoutEndTag)]
public sealed class PermissionScriptTagHelper(IPermissionService permissions, IOptionsMonitor<EmrAuthorizationOptions> options) : TagHelper
{
    [ViewContext, HtmlAttributeNotBound]
    public ViewContext ViewContext { get; set; } = default!;

    public override async Task ProcessAsync(TagHelperContext context, TagHelperOutput output)
    {
        output.TagName = "script";
        output.TagMode = TagMode.StartTagAndEndTag;

        var opts = options.CurrentValue;
        var subject = PermissionSubjectReader.FromPrincipal(ViewContext.HttpContext.User);
        var set = subject is null ? null : await permissions.GetPermissionSetAsync(subject);

        var state = new
        {
            enforce = opts.Mode == AuthorizationMode.Enforce,
            modules = opts.EnforceModules,
            bypass = set?.IsBypass ?? false,
            allowed = set is null || set.IsBypass
                ? Array.Empty<string>()
                : set.Rows.Where(r => r.Permission == "A" && r.Control_Code != PermissionControls.View)
                          .Select(r => r.Page_Code + ":" + r.Control_Code).ToArray(),
            // refused by a Deny someone set: hidden even while the module is still in audit
            denied = set is null || set.IsBypass
                ? Array.Empty<string>()
                : set.Rows.Where(r => r.Control_Code != PermissionControls.View && set.IsExplicitDeny(r.Page_Code, r.Control_Code))
                          .Select(r => r.Page_Code + ":" + r.Control_Code).ToArray()
        };

        output.Content.SetHtmlContent(
            "(function(s){var a=new Set(s.allowed.map(function(x){return x.toUpperCase();})),d=new Set(s.denied.map(function(x){return x.toUpperCase();}));" +
            "window.emrCan=function(page,control){control=(control||'VIEW').toUpperCase();" +
            "if(!s.enforce||s.bypass||control==='VIEW')return true;" +
            "if(d.has((String(page)+':'+control).toUpperCase()))return false;" +
            "var m=String(page).split('.')[0].toUpperCase();" +
            "if(s.modules.length&&s.modules.map(function(x){return x.toUpperCase();}).indexOf(m)<0)return true;" +
            "return a.has((String(page)+':'+control).toUpperCase());};})(" +
            JsonSerializer.Serialize(state).Replace("</", "<\\/") + ");");
    }
}
