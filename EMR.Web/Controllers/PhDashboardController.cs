using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Inventory > Pharmacy Dashboard (PHARMACY.DASHBOARD, SQLScripts/2349).</summary>
public class PhDashboardController(IPharmacyInventoryService inventory, INotificationService n, IAuditLogService a) : PharmacyInventoryControllerBase(inventory, n, a)
{
    [HttpGet]
    public async Task<IActionResult> Index() => View("~/Views/PharmacyInventory/Dashboard.cshtml", await Inventory.DashboardAsync(CompanyId, BranchId));
}
