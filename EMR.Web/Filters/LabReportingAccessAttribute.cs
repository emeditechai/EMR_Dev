using EMR.Web.Data;
using EMR.Web.Extensions;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Mvc.ViewFeatures;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Filters;

/// <summary>
/// Lab Reporting Entry (LabReporting/Index, Entry and their data / save calls) is open only to
///   - a super admin (full access, no department restriction), or
///   - an active user flagged "Is Pathologist" or "Is Lab Technician" in User Master.
/// Everyone else gets the Access Denied page, or a 403 JSON for the page's AJAX calls.
/// Print / print-log / audit-history actions of the same controller are shared with other screens and are not gated.
/// </summary>
[AttributeUsage(AttributeTargets.Method | AttributeTargets.Class)]
public sealed class LabReportingAccessAttribute : Attribute, IAsyncActionFilter
{
    public const string DeniedMessage =
        "Lab Reporting Entry is available only to users marked as Pathologist or Lab Technician in User Master.";

    public async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        var user = context.HttpContext.User;
        if (user.IsSuperAdmin())
        {
            await next();
            return;
        }

        var db = context.HttpContext.RequestServices.GetRequiredService<ApplicationDbContext>();
        var userId = user.GetUserId();
        var profile = await db.Users.AsNoTracking()
            .Where(u => u.Id == userId)
            .Select(u => new { u.FullName, u.IsActive, u.IsPathologist, u.IsLabTechnician })
            .FirstOrDefaultAsync();

        if (profile is { IsActive: true } && (profile.IsPathologist || profile.IsLabTechnician))
        {
            await next();
            return;
        }

        var action = context.ActionDescriptor.RouteValues.TryGetValue("action", out var a) ? a ?? string.Empty : string.Empty;
        bool wantsJson = action.EndsWith("Json", StringComparison.OrdinalIgnoreCase)
                         || action.EndsWith("ForDropdown", StringComparison.OrdinalIgnoreCase)
                         || context.HttpContext.Request.Headers.XRequestedWith == "XMLHttpRequest";
        if (wantsJson)
        {
            context.Result = new JsonResult(new { success = false, message = DeniedMessage }) { StatusCode = StatusCodes.Status403Forbidden };
            return;
        }

        var controller = context.Controller as Controller;
        context.Result = new ViewResult
        {
            ViewName = "AccessDenied",
            StatusCode = StatusCodes.Status403Forbidden,
            ViewData = new ViewDataDictionary(controller?.ViewData ?? new ViewDataDictionary(
                    new Microsoft.AspNetCore.Mvc.ModelBinding.EmptyModelMetadataProvider(), context.ModelState))
            {
                Model = new LabReportingDeniedViewModel { UserName = profile?.FullName ?? user.Identity?.Name ?? "You" }
            }
        };
    }
}

public class LabReportingDeniedViewModel
{
    public string UserName { get; set; } = string.Empty;
}
