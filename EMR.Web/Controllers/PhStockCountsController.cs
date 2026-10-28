using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Inventory > Physical Stock Verification (PHARMACY.STOCKCOUNT, SQLScripts/2349):
/// freeze -> blind count sheet by rack -> enter counts -> variance -> submit -> approve (differences adjusted and posted).</summary>
public class PhStockCountsController(IPharmacyInventoryService inventory, IPharmacyMasterService masters, IPharmacyPurchaseService purchase, INotificationService n, IAuditLogService a)
    : PharmacyInventoryControllerBase(inventory, n, a)
{
    private const string Module = "PHARMACY.STOCKCOUNT";

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Categories = (await masters.ItemLookupsAsync(CompanyId)).Categories;
        return View("~/Views/PharmacyInventory/Counts.cshtml", await Inventory.CountsAsync(CompanyId, BranchId));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(string? rack, int? categoryId, bool includeZero, string? remarks)
    {
        var (id, err) = await Inventory.CreateCountAsync(CompanyId, BranchId, rack, categoryId, includeZero, remarks, UserId);
        if (err != null) { TempData["Error"] = err; return RedirectToAction(nameof(Index)); }
        await LogAsync("CountCreate", $"Physical stock verification #{id} started (stock frozen)");
        return Back(null, "Stock frozen. Print the count sheet, count and enter the quantities.", new { id });
    }

    [HttpGet]
    public async Task<IActionResult> Form(int id)
    {
        var d = await Inventory.GetCountAsync(CompanyId, BranchId, id);
        if (d == null) return NotFound();
        ViewBag.UserId = UserId;
        return View("~/Views/PharmacyInventory/CountForm.cshtml", d);
    }

    [HttpGet]
    public async Task<IActionResult> Sheet(int id)
    {
        var d = await Inventory.GetCountAsync(CompanyId, BranchId, id);
        if (d == null) return NotFound();
        ViewBag.Header = await purchase.BranchHeaderAsync(BranchId);
        return View("~/Views/PharmacyInventory/CountSheet.cshtml", d);
    }

    [HttpGet] public IActionResult Variance(int id) => RedirectToAction(nameof(Form), new { id, variance = true });

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveCounts(int id, Dictionary<int, string?>? count)
    {
        var parsed = (count ?? []).ToDictionary(k => k.Key, v => decimal.TryParse(v.Value, out var q) ? q : (decimal?)null);
        return Back(await Inventory.SaveCountsAsync(CompanyId, BranchId, id, parsed, UserId), "Counts saved.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Submit(int id)
    {
        var err = await Inventory.CountActionAsync(CompanyId, BranchId, id, "submit", null, UserId);
        if (err == null) await NotifyApproversAsync(Module, "Physical stock verification to approve", $"{User.Identity?.Name} submitted a pharmacy stock count for approval.", Url.Action(nameof(Form), new { id })!, id);
        return Back(err, "Submitted for approval.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Approve(int id, string? remarks)
    {
        var err = await ApproverCheckAsync(Module) ?? await Inventory.CountActionAsync(CompanyId, BranchId, id, "approve", remarks, UserId);
        if (err == null) await LogAsync("CountApprove", $"Physical stock verification #{id} approved: differences adjusted");
        return Back(err, "Approved: the differences are adjusted in stock and posted to the books.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Reject(int id, string? remarks) =>
        Back(await ApproverCheckAsync(Module) ?? await Inventory.CountActionAsync(CompanyId, BranchId, id, "reject", remarks, UserId), "Sent back for recount.", new { id });

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id, string? remarks) => Back(await Inventory.CountActionAsync(CompanyId, BranchId, id, "cancel", remarks, UserId), "Verification cancelled.", new { id });
}
