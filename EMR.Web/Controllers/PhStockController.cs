using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Inventory > Stock Enquiry (PHARMACY.STOCK, SQLScripts/2349): batch-wise stock with value; movement history.</summary>
public class PhStockController(IPharmacyInventoryService inventory, IPharmacyMasterService masters, INotificationService n, IAuditLogService a) : PharmacyInventoryControllerBase(inventory, n, a)
{
    [HttpGet]
    public async Task<IActionResult> Index(string? search, int? categoryId, string filter = "instock")
    {
        ViewBag.Filter = (search, categoryId, filter);
        ViewBag.Categories = (await masters.ItemLookupsAsync(CompanyId)).Categories;
        return View("~/Views/PharmacyInventory/Stock.cshtml", await Inventory.StockAsync(CompanyId, BranchId, search, categoryId, filter));
    }

    [HttpGet] public async Task<IActionResult> Ledger(int itemId, int? batchId) => Json(await Inventory.LedgerAsync(CompanyId, BranchId, itemId, batchId));

    [HttpGet] public async Task<IActionResult> BatchSearch(string? q) => Json(string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2 ? [] : await Inventory.BatchSearchAsync(CompanyId, BranchId, q.Trim()));
}
