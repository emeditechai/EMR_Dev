using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Pharmacy > Purchase > Auto Reorder (PHARMACY.AUTOREORDER, SQLScripts/2403): sales-based order suggestions
/// (Hospital Settings > MED > Auto Reorder) and one draft purchase order per supplier from the ticked lines.
/// </summary>
[Authorize]
public class PhAutoReorderController(IPharmacyPurchaseService purchase, IPharmacyMasterService masters, IAuditLogService audit) : Controller
{
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();
    private int UserId => User.GetUserId();

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Suppliers = await purchase.SuppliersAsync(CompanyId);
        ViewBag.Categories = (await masters.ItemLookupsAsync(CompanyId)).Categories;
        return View("~/Views/PharmacyPurchase/AutoReorder.cshtml");
    }

    [HttpGet]
    public async Task<IActionResult> Data(int? supplierId, int? categoryId, bool showAll = false)
    {
        var (settings, rows) = await purchase.AutoReorderAsync(CompanyId, BranchId, supplierId, categoryId, showAll);
        return Json(new { settings, rows });
    }

    [HttpGet]
    public async Task<IActionResult> SchemeFree(int supplierId, int itemId, decimal qty) =>
        Json(supplierId > 0 && itemId > 0 && qty > 0 ? await purchase.SchemeFreeAsync(CompanyId, BranchId, supplierId, itemId, qty) : new PhSchemeFree());

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CreatePos([FromForm] string? json)
    {
        List<PhReorderLine>? lines;
        try { lines = System.Text.Json.JsonSerializer.Deserialize<List<PhReorderLine>>(json ?? "[]", new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true }); }
        catch (System.Text.Json.JsonException) { return Json(new { success = false, message = "The list could not be read." }); }
        var (created, error) = await purchase.AutoReorderCreatePosAsync(CompanyId, BranchId, lines ?? [], UserId);
        if (error != null) return Json(new { success = false, message = error });
        await audit.LogAsync("PHARMACY", "PHARMACY.AutoReorderPosCreated",
            $"Auto reorder: {created.Count} draft purchase order(s) - " + string.Join(", ", created.Select(c => $"#{c.PoId} {c.SupplierName} ({c.Lines} items, {c.NetAmount:N2})")), UserId);
        return Json(new { success = true, created });
    }
}
