using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.Extensions;
using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Inventory pages (SQLScripts/2349): branch / user helpers and the maker-checker rule - with an Approval
/// Matrix for the module only its approvers may approve or reject; without one, the page's APPROVE / REJECT control
/// (checked by the endpoint map) is enough. The maker is refused in the service.</summary>
[Authorize]
public abstract class PharmacyInventoryControllerBase(IPharmacyInventoryService inventory, INotificationService notifications, IAuditLogService audit) : Controller
{
    protected static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
    protected IPharmacyInventoryService Inventory => inventory;
    protected int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    protected int CompanyId => User.GetCompanyId();
    protected int UserId => User.GetUserId();

    /// <summary>Null when the user may decide; else the reason.</summary>
    protected async Task<string?> ApproverCheckAsync(string module)
    {
        var approvers = await inventory.MatrixApproversAsync(CompanyId, module, BranchId);
        return approvers.Count == 0 || approvers.Contains(UserId) || User.IsSuperAdmin() ? null
            : "Only the approvers named in the Approval Matrix for this document can approve or reject it.";
    }

    protected async Task NotifyApproversAsync(string module, string title, string message, string link, long refId)
    {
        var to = (await inventory.MatrixApproversAsync(CompanyId, module, BranchId)).Where(u => u != UserId).ToList();
        if (to.Count > 0)
            await notifications.NotifyUsersAsync(to, "PHARMACY_APPROVAL", "INFO", title, message, link, "PHARMACY", refId, $"{module}:{refId}:{DateTime.Now:yyyyMMddHHmmss}", BranchId, UserId);
    }

    protected Task LogAsync(string action, string text) => audit.LogAsync("PharmacyInventory", action, text, UserId, BranchId);

    protected IActionResult Back(string? error, string ok, object route, string action = "Form")
    {
        if (error != null) TempData["Error"] = error; else TempData["Success"] = ok;
        return RedirectToAction(action, route);
    }
}
