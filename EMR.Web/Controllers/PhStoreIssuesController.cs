using System.Text.Json;
using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Inventory > Store Issue (PHARMACY.STOREISSUE, SQLScripts/2364): within a branch, the counter asks a godown for stock
/// (REQUEST) -> the godown issues batches (ISSUE, stock leaves the godown) -> the counter receives (RECEIVE, stock arrives; short with a reason).</summary>
public class PhStoreIssuesController(IPharmacyInventoryService inventory, IPharmacyPurchaseService purchase, INotificationService n, IAuditLogService a)
    : PharmacyInventoryControllerBase(inventory, n, a)
{
    [HttpGet]
    public async Task<IActionResult> Index(string? status)
    {
        ViewBag.Status = status;
        return View("~/Views/PharmacyInventory/StoreIssues.cshtml", await Inventory.IssuesAsync(CompanyId, BranchId, status));
    }

    [HttpGet]
    public async Task<IActionResult> Form(int id = 0)
    {
        var stores = await Inventory.StoresAsync(CompanyId, BranchId, "ANY");
        PhIssueDoc? d;
        if (id > 0) d = await Inventory.GetIssueAsync(CompanyId, BranchId, id);
        else
        {
            // usual case: the default receiving store (godown) gives, the default selling store (counter) asks
            var give = (await Inventory.StoresAsync(CompanyId, BranchId, "RECEIVE")).FirstOrDefault();
            var ask = (await Inventory.StoresAsync(CompanyId, BranchId, "SELL")).FirstOrDefault(s => s.StoreId != give?.StoreId);
            d = new PhIssueDoc { FromStoreId = give?.StoreId ?? 0, ToStoreId = ask?.StoreId ?? 0 };
        }
        if (d == null) return NotFound();
        ViewBag.Stores = stores;
        return View("~/Views/PharmacyInventory/StoreIssueForm.cshtml", d);
    }

    [HttpGet] public async Task<IActionResult> ItemSearch(string? q) => Json(string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2 ? [] : await purchase.ItemSearchAsync(CompanyId, BranchId, q.Trim()));
    [HttpGet] public async Task<IActionResult> Batches(int itemId, int storeId) => Json(await Inventory.StoreBatchesAsync(CompanyId, BranchId, storeId, itemId));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string? json, bool submit = false)
    {
        var d = string.IsNullOrWhiteSpace(json) ? null : JsonSerializer.Deserialize<PhIssueDoc>(json, Json);
        if (d == null) return BadRequest();
        var (id, err) = await Inventory.SaveIssueRequestAsync(CompanyId, BranchId, d, submit, UserId);
        if (err != null) { TempData["Error"] = err; return d.Id > 0 ? RedirectToAction(nameof(Form), new { id = d.Id }) : RedirectToAction(nameof(Form)); }
        await LogAsync("StoreIssueRequest", $"Store request #{id} {(submit ? "sent" : "saved")}");
        return Back(null, submit ? "Request sent to the store." : "Request saved as draft.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Issue(int id, string? json, string? remarks)
    {
        var lines = string.IsNullOrWhiteSpace(json) ? [] : JsonSerializer.Deserialize<List<PhIssueLine>>(json, Json) ?? [];
        var err = await Inventory.IssueStockAsync(CompanyId, BranchId, id, lines, remarks, UserId);
        if (err == null) await LogAsync("StoreIssue", $"Store issue #{id} issued");
        return Back(err, "Stock issued: it reaches the counter when received.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Receive(int id, Dictionary<int, decimal>? received, Dictionary<int, string>? reasons, string? remarks)
    {
        var err = await Inventory.ReceiveIssueAsync(CompanyId, BranchId, id, received ?? [], reasons ?? [], remarks, UserId);
        if (err == null) await LogAsync("StoreIssueReceive", $"Store issue #{id} received");
        return Back(err, "Received: stock added to the store.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id) => Back(await Inventory.CancelIssueAsync(CompanyId, BranchId, id, UserId), "Request cancelled.", new { id });

    [HttpGet]
    public async Task<IActionResult> Print(int id)
    {
        var d = await Inventory.GetIssueAsync(CompanyId, BranchId, id);
        if (d == null) return NotFound();
        ViewBag.Stores = await Inventory.StoresAsync(CompanyId, BranchId, "ANY");
        ViewBag.Print = true;
        return View("~/Views/PharmacyInventory/StoreIssueForm.cshtml", d);
    }
}
