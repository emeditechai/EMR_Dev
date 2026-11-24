using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Settings > Notification Languages (SETTINGS.NOTIFYTEMPLATES, SQLScripts/2543): the WhatsApp / e-mail texts of patient
/// notifications per language (company default or a branch's own). A patient whose language has no text gets the message as
/// before (English). First notification: LAB B2C bill. Web -> EMR.Api api/notify-templates -> procedures.
/// </summary>
[Authorize]
public class NotifyTemplatesController(NotifyTemplateApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService audit, ILogger<NotifyTemplatesController> logger) : Controller
{
    private const string Page = "SETTINGS.NOTIFYTEMPLATES";
    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewData["CanEDIT"] = await permissionGuard.AllowsAsync(HttpContext, Page, "EDIT");
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> Data()
    {
        try
        {
            var lookups = await api.GetAsync("/lookups");
            var sets = lookups.ValueKind == JsonValueKind.Array ? lookups.EnumerateArray().ToList() : [];
            var rows = await api.GetAsync();
            return Json(new
            {
                success = true,
                data = new { events = sets.ElementAtOrDefault(0), languages = sets.ElementAtOrDefault(1), branches = sets.ElementAtOrDefault(2), templates = rows }
            });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Notification templates API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromBody] JsonElement body)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, "EDIT")) return Fail(PermissionFilter.DeniedMessage);
        try
        {
            var row = await api.PostAsync(body);
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "Not saved.");
            await audit.LogActivityAsync(eventType: "Settings", actionName: "NotifyTemplate.Save",
                description: $"Notification text saved: {body.S("eventCode")} {body.S("channel")} language {body.S("languageId")}",
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "SETTINGS", referenceId: row.I("TemplateId"));
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Notification templates API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved."); }
    }
}
